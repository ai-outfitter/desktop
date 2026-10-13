import AppKit
import Darwin
import Foundation
import Vision
import SwiftUI
import XCTest
@testable import PiNative

final class OutfitterRuntimeTests: XCTestCase {
    @MainActor
    func testLegacyTurnWaitsDuringRetryAndSettlesAfterCompaction() async throws {
        let fixture = try RPCFixture(mode: .healthy)
        defer { fixture.remove() }
        let conversation = PiConversationModel(piCommand: PiRPCClient.rpcCommand(from: fixture.expectedCommand))
        conversation.start(workingDirectory: fixture.directory.path, sessionPath: nil)
        let deadline = Date().addingTimeInterval(3)
        while conversation.isLoadingSession && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        func event(_ json: String) throws { conversation.handleEventForTesting(try JSONDecoder().decode(RPCEnvelope.self, from: Data(json.utf8))) }
        try event(#"{"type":"agent_start"}"#)
        try event(#"{"type":"agent_end","willRetry":true}"#)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(conversation.isRunning, "Idle engine state during retry backoff must not finish the turn")
        try event(#"{"type":"agent_start"}"#)
        try event(#"{"type":"agent_end","willRetry":false}"#)
        try event(#"{"type":"compaction_start"}"#)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(conversation.isRunning, "Compaction must keep the turn active")
        try event(#"{"type":"compaction_end"}"#)
        while conversation.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let settled = !conversation.isRunning
        await conversation.stopAndWaitForTesting()
        XCTAssertTrue(settled, "Compaction completion must recheck idle state after the original probe window")
    }

    @MainActor
    func testLiveOutfitterFirstMessageCompletesThroughConversationModel() async throws {
        try await assertLiveExistingConversation(modelID: "GLM-5.3-Flash-EXL3")
    }

    @MainActor
    func testLiveExistingConversationUsesCredentialsApprovedAfterProcessStart() async throws {
        try await assertLiveExistingConversation(modelID: "GLM-5.3-Flash-EXL3")
    }

    @MainActor
    func testLiveExistingSolConversationUsesCanonicalModelAfterSignIn() async throws {
        try await assertLiveExistingConversation(modelID: "gpt-6-sol")
    }

    @MainActor
    func testLiveExistingLunaConversationUsesCanonicalModelAfterSignIn() async throws {
        try await assertLiveExistingConversation(modelID: "gpt-6-luna")
    }

    @MainActor
    func testLiveRetainedProjectPromptUsesRealPreAndPostApprovalCatalog() async throws {
        try await assertLiveExistingConversation(modelID: "GLM-5.3-Flash-EXL3", retainedPrompt: true)
    }

    @MainActor
    private func assertLiveExistingConversation(modelID: String, retainedPrompt: Bool = false) async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: repo.appendingPathComponent(".local/live-test-enabled").path) else {
            throw XCTSkip("Enable explicitly with an authenticated disposable test state.")
        }
        let fixtureAuth = repo.appendingPathComponent(".local/live-test-auth.json")
        guard FileManager.default.fileExists(atPath: fixtureAuth.path) else {
            throw XCTSkip("Provide a separately approved disposable device session for this live regression.")
        }
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureAuth)) as? [String: [String: Any]]
        let expires = fixture?["outfitter"]?["expires"] as? Double ?? 0
        guard expires > Date().timeIntervalSince1970 * 1000 + 30000 else {
            throw XCTSkip("Refresh the disposable device fixture before running live inference.")
        }
        let deadline = Date().addingTimeInterval(25)
        let root = try temporaryDirectory(named: "OutfitterRelogin")
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state")
        let authDirectory = state.appendingPathComponent(".pi/agent")
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("outfitter")
        let starts = root.appendingPathComponent("starts")
        try makeExecutable(at: executable, contents: """
        #!/bin/sh
        umask 077
        export OUTFITTER_DESKTOP_STATE_DIRECTORY='\(state.path)'
        export OUTFITTER_DESKTOP_ORIGIN=http://localhost:4482
        export OUTFITTER_USER_HOME='\(state.path)'
        /opt/homebrew/bin/node '\(repo.path)/scripts/configure-outfitter-state.mjs'
        if [ "$1" = login ]; then
          cp '\(fixtureAuth.path)' '\(authDirectory.path)/auth.json'
          exit 0
        fi
        echo run >> '\(starts.path)'
        exec '\(ProcessInfo.processInfo.environment["OUTFITTER_LIVE_CLI"] ?? repo.appendingPathComponent(".local/cli/bin/outfitter").path)' "$@"
        """)
        let spark = PiModelOption(provider: "outfitter", id: modelID, name: modelID)
        let restore = withOutfitterEnvironment(executable.path)
        defer { restore() }
        setenv("OUTFITTER_DESKTOP_AGENT", "desktop", 1)
        let app = AppModel(modelFavoritesStorage: isolatedOutfitterFavorites(),
            piHealthCheck: { .healthy(PiCommand(executable: "/usr/bin/true", arguments: [])) },
            conversationModelFactory: { settings in
                PiConversationModel(piCommand: PiRPCClient.rpcCommand(from: PiCommand(executable: executable.path,
                    arguments: ["run", "desktop", "--harness", "pi", "--"]), disablesTools: true), modelSettings: settings)
            })
        defer { app.stopAllRuntimes() }
        app.modelSettings.updateCatalog([spark])
        app.modelSettings.setFavorite(true, for: spark)
        if retainedPrompt {
            app.projects = [Project(name: "Live retained", path: root.path, sessions: [])]
            app.standaloneSessions = []
            app.selectedProjectID = app.projects[0].id
            app.selectedSessionID = nil
            app.modelSettings.setFavorite(false, for: spark)
            let missing = PiModelOption(provider: "outfitter", id: "unavailable-test-model", name: "Unavailable")
            app.modelSettings.setFavorite(true, for: missing)
            // Obtain the pre-approval catalog from the real credential-free CLI.
            await app.refreshModelCatalog(force: true)
            XCTAssertTrue(app.modelSettings.catalog.isEmpty)
            XCTAssertNil(app.modelSettings.preferredConversationModel)
            app.sendNewChatPrompt(PreparedPrompt(message: "Reply only with retained message delivered. Do not use tools.", images: [], displayAttachments: []))
            XCTAssertTrue(app.isSettingsPresented)
            XCTAssertEqual(app.settingsSection, .models)
            XCTAssertTrue(app.projects[0].sessions.isEmpty)
            app.signInToOutfitter(command: PiCommand(executable: executable.path, arguments: []))
            var replied = false
            while Date() < deadline {
                replied = app.activeConversationModel?.items.contains { if case .assistantText(_, let text) = $0 { return !text.isEmpty }; return false } == true
                if replied && app.activeConversationModel?.isRunning == false { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertTrue(app.modelSettings.catalog.contains { $0.stableID == spark.stableID })
            XCTAssertEqual(app.projects[0].sessions.count, 1)
            XCTAssertTrue(replied, "Real CLI must deliver the retained message after approved credentials produce a newly refreshed catalog")
            XCTAssertNil(app.activeConversationModel?.errorMessage)
            XCTAssertFalse(app.activeConversationModel?.isRunning ?? true)
            let sessionPath = try XCTUnwrap(app.projects[0].sessions[0].filePath)
            let userMessages = try String(contentsOfFile: sessionPath, encoding: .utf8).split(separator: "\n").compactMap {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }.filter { ($0["message"] as? [String: Any])?["role"] as? String == "user" }
            XCTAssertEqual(userMessages.count, 1, "The real session must contain the retained user message exactly once")
            if let conversation = app.activeConversationModel { await conversation.stopAndWaitForTesting() }
            return
        }
        let session = Session(name: "Opened before login", status: .idle)
        app.standaloneSessions = [session]
        app.select(sessionID: session.id, in: nil)
        let conversation = try XCTUnwrap(app.activeConversationModel)
        conversation.startProcessIfNeeded()
        while conversation.isLoadingSession && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(conversation.isProcessStarted)
        conversation.draft = "Reply only with credentials connected. Do not use tools."
        app.modelSettings.updateCatalog([])
        app.signInToOutfitter(command: PiCommand(executable: executable.path, arguments: []))
        while app.isSigningInToOutfitter && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        // Catalog refresh and runtime adoption finish after the process callback.
        while Date() < deadline {
            let processCount = (try? String(contentsOf: starts, encoding: .utf8).split(separator: "\n").count) ?? 0
            if processCount >= 3 && app.modelSettings.catalog.contains(where: { $0.stableID == spark.stableID }) && conversation.isProcessStarted && !conversation.isLoadingSession { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(app.modelSettings.catalog.contains { $0.stableID == spark.stableID }, "Real catalog producer must deliver the requested canonical model after credential approval")
        XCTAssertTrue(app.activeConversationModel === conversation)
        XCTAssertEqual(conversation.draft, "Reply only with credentials connected. Do not use tools.")
        while conversation.isLoadingSession && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let initialRuntimeModel = try await conversation.selectedRuntimeModelForTesting()
        while conversation.currentModel?.stableID != initialRuntimeModel?.stableID && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        conversation.selectModel(spark)
        var selected = try await conversation.selectedRuntimeModelForTesting()
        while selected?.stableID != spark.stableID && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            selected = try await conversation.selectedRuntimeModelForTesting()
        }
        XCTAssertEqual(selected?.stableID, spark.stableID)
        guard selected?.stableID == spark.stableID else {
            await conversation.stopAndWaitForTesting()
            return
        }
        conversation.sendDraft()
        var replied = false
        while Date() < deadline {
            replied = conversation.items.contains { if case .assistantText(_, let text) = $0 { return !text.isEmpty }; return false }
            if replied && !conversation.isRunning { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(replied, "The pre-login conversation must send through real Pi using the approved credential: \(conversation.errorMessage ?? conversation.sessionLoadNotice ?? "no reply")")
        XCTAssertFalse(conversation.isRunning)
        XCTAssertNil(conversation.errorMessage)
        let afterReply = try await conversation.selectedRuntimeModelForTesting()
        XCTAssertEqual(afterReply?.stableID, spark.stableID)
        await conversation.stopAndWaitForTesting()
    }

    @MainActor
    func testLoginPreservesBusyRuntimesAndFailurePreservesIdleRuntime() async throws {
        for state in ["running", "loading", "pending", "failed"] {
            let fixture = try RPCFixture(mode: .healthy)
            defer { fixture.remove() }
            var refreshes = 0
            let app = AppModel(modelFavoritesStorage: isolatedOutfitterFavorites(),
                modelCatalogLoader: { refreshes += 1; return [] },
                piHealthCheck: { .healthy(PiCommand(executable: "/usr/bin/true", arguments: [])) },
                conversationModelFactory: { _ in PiConversationModel(piCommand: PiRPCClient.rpcCommand(from: fixture.expectedCommand)) })
            defer { app.stopAllRuntimes() }
            let session = Session(name: state, status: .idle)
            app.standaloneSessions = [session]
            app.select(sessionID: session.id, in: nil)
            let conversation = try XCTUnwrap(app.activeConversationModel)
            conversation.startProcessIfNeeded()
            let deadline = Date().addingTimeInterval(3)
            while (conversation.isLoadingSession || ((try? String(contentsOf: fixture.commandsFile, encoding: .utf8))?.contains("get_available_thinking_levels") != true)) && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertTrue(conversation.isProcessStarted)
            conversation.draft = "keep draft"
            if state == "running" { conversation.handleEventForTesting(try JSONDecoder().decode(RPCEnvelope.self, from: Data(#"{"type":"agent_start"}"#.utf8))) }
            if state == "loading" { conversation.isLoadingSession = true }
            if state == "pending" { conversation.configureSession(workingDirectory: nil, sessionPath: nil, initialPrompt: PreparedPrompt(message: "waiting", images: [], displayAttachments: [])) }
            let before = try String(contentsOf: fixture.commandsFile, encoding: .utf8)
            app.signInToOutfitter(command: PiCommand(executable: state == "failed" ? "/usr/bin/false" : "/usr/bin/true", arguments: []))
            while app.isSigningInToOutfitter && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            while state != "failed" && refreshes == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(app.isSigningInToOutfitter, state)
            XCTAssertEqual(refreshes, state == "failed" ? 0 : 1, state)
            XCTAssertEqual(app.isConnectedToOutfitter, state != "failed", state)
            XCTAssertEqual(app.outfitterSignInStatus?.hasPrefix("Signed in."), state != "failed", state)
            XCTAssertEqual(try String(contentsOf: fixture.commandsFile, encoding: .utf8), before, state)
            XCTAssertTrue(conversation.isProcessStarted, state)
            XCTAssertEqual(conversation.draft, "keep draft", state)
            if state == "running" { XCTAssertTrue(conversation.isRunning) }
            if state == "loading" { XCTAssertTrue(conversation.isLoadingSession) }
            if state == "pending" { XCTAssertTrue(conversation.hasPendingPrompt) }
            await conversation.stopAndWaitForTesting()
        }
    }

    @MainActor
    func testSendBeforeLoginRetainsPromptAndOnlyResumesWhenModelIsAvailable() async throws {
        var hasModel = false
        let model = AppModel(
            modelFavoritesStorage: isolatedOutfitterFavorites(),
            modelCatalogLoader: { hasModel ? [PiModelOption(provider: "outfitter", id: "spark", name: "Spark")] : [] },
            outfitterRuntimeConfigured: true,
            piHealthCheck: { .healthy(PiCommand(executable: "/usr/bin/true", arguments: [])) }
        )
        model.automaticallyStartsPendingRuntimes = false
        model.projects = []
        model.standaloneSessions = []
        model.selectedProjectID = nil
        model.selectedSessionID = nil
        model.modelSettings.updateCatalog([])
        model.sendNewChatPrompt(PreparedPrompt(message: "keep this message", images: [], displayAttachments: []))
        XCTAssertTrue(model.isSettingsPresented)
        XCTAssertEqual(model.settingsSection, .models)
        XCTAssertTrue(model.standaloneSessions.isEmpty)
        model.signInToOutfitter(command: PiCommand(executable: "/usr/bin/true", arguments: []))
        let deadline = Date().addingTimeInterval(3)
        while model.isSigningInToOutfitter && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        // No model after login: retained prompt must not become a spinning chat.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.standaloneSessions.isEmpty)
        hasModel = true
        model.signInToOutfitter(command: PiCommand(executable: "/usr/bin/true", arguments: []))
        while model.standaloneSessions.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.standaloneSessions.count, 1)
        XCTAssertEqual(model.standaloneSessions.first?.pendingInitialPrompt?.message, "keep this message")
        model.signInToOutfitter(command: PiCommand(executable: "/usr/bin/true", arguments: []))
        while model.isSigningInToOutfitter && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.standaloneSessions.count, 1)
        model.stopAllRuntimes()
    }

    @MainActor
    func testShutdownTerminatesPendingOutfitterLogin() async throws {
        let root = try temporaryDirectory(named: "OutfitterShutdown")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("login")
        let pidFile = root.appendingPathComponent("pid")
        try makeExecutable(at: executable, contents: "#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec /bin/sleep 10\n")
        let model = AppModel()
        model.signInToOutfitter(command: PiCommand(executable: executable.path, arguments: []))
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: pidFile.path) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        model.stopAllRuntimes()
        while Darwin.kill(pid, 0) == 0 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isSigningInToOutfitter)
        XCTAssertNotEqual(Darwin.kill(pid, 0), 0)
        XCTAssertEqual(model.outfitterSignInStatus, "Sign-in cancelled.")
    }

    @MainActor
    func testLoginRefreshesCatalogAfterAnOverlappingPreLoginRefresh() async throws {
        var loads = 0
        var firstLoad: CheckedContinuation<[PiModelOption], Error>?
        let model = AppModel(
            modelFavoritesStorage: isolatedOutfitterFavorites(),
            modelCatalogLoader: {
                loads += 1
                if loads == 1 { return try await withCheckedThrowingContinuation { firstLoad = $0 } }
                return [PiModelOption(provider: "outfitter", id: "spark", name: "Spark")]
            },
            piHealthCheck: { .healthy(PiCommand(executable: "/usr/bin/true", arguments: [])) }
        )
        let refresh = Task { await model.refreshModelCatalog(force: true) }
        let deadline = Date().addingTimeInterval(3)
        while firstLoad == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        model.signInToOutfitter(command: PiCommand(executable: "/usr/bin/true", arguments: []))
        while model.isSigningInToOutfitter && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        firstLoad?.resume(returning: [])
        await refresh.value
        while loads < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(model.modelSettings.catalog.first?.provider, "outfitter")
    }

    @MainActor
    func testOutfitterBrowserLoginCompletionRefreshesCatalogAndFailureDoesNot() async throws {
        let root = try temporaryDirectory(named: "OutfitterDesktopLogin")
        defer { try? FileManager.default.removeItem(at: root) }
        for exitCode in [0, 1] {
            let executable = root.appendingPathComponent("login-\(exitCode)")
            let argumentsFile = root.appendingPathComponent("arguments-\(exitCode)")
            try makeExecutable(at: executable, contents: "#!/bin/sh\n/usr/bin/printf '%s' \"$1\" > '\(argumentsFile.path)'\nexit \(exitCode)\n")
            var refreshes = 0
            let model = AppModel(
            modelFavoritesStorage: isolatedOutfitterFavorites(),
                modelCatalogLoader: { refreshes += 1; return [] },
                piHealthCheck: { .healthy(PiCommand(executable: "/usr/bin/true", arguments: [])) }
            )
            model.signInToOutfitter(command: PiCommand(executable: executable.path, arguments: ["run", "--"]))
            XCTAssertTrue(model.isSigningInToOutfitter)
            let deadline = Date().addingTimeInterval(3)
            while model.isSigningInToOutfitter && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            // Catalog work follows process completion asynchronously.
            while exitCode == 0 && refreshes == 0 && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(model.isSigningInToOutfitter)
            XCTAssertEqual(try String(contentsOf: argumentsFile, encoding: .utf8), "login")
            XCTAssertEqual(refreshes, exitCode == 0 ? 1 : 0)
            XCTAssertEqual(model.outfitterSignInStatus?.hasPrefix("Signed in."), exitCode == 0)
            XCTAssertEqual(model.isConnectedToOutfitter, exitCode == 0)
        }
    }

    func testConfiguredOutfitterForwardsAgentCommandsAndInteractiveRecovery() throws {
        let root = try temporaryDirectory(named: "OutfitterDesktop")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("outfitter-dev")
        try makeExecutable(at: executable, contents: "#!/bin/sh\nexit 0\n")
        let environment = [
            "PATH": "/usr/bin:/bin",
            "OUTFITTER_DESKTOP_CLI": executable.path,
            "OUTFITTER_DESKTOP_AGENT": "desktop"
        ]
        let base = try XCTUnwrap(PiRPCClient.resolvedPiCommand(environment: environment))
        let prefix = ["run", "desktop", "--harness", "pi", "--"]
        XCTAssertEqual(base.executable, executable.path)
        XCTAssertEqual(base.arguments, prefix)
        XCTAssertEqual(PiRPCClient.rpcCommand(from: base).arguments, prefix + ["--mode", "rpc"])
        XCTAssertEqual(PiRPCClient.modelListCommand(from: base).arguments, prefix + ["--list-models"])
        XCTAssertEqual(PiHealthChecker.probeCommand(from: base).arguments, prefix + PiRPCClient.isolatedRPCArguments)
        let recovery = PiTerminalRecovery.script(command: base, homeDirectory: root, shell: "/bin/zsh")
        XCTAssertTrue(recovery.contains("exec '\(executable.path)' 'run' 'desktop' '--harness' 'pi' '--'"))
        XCTAssertFalse(recovery.contains("'--mode' 'rpc'"))
        XCTAssertEqual(base.environmentPath?.split(separator: ":").first.map(String.init), root.path)
    }

    func testInvalidExplicitOutfitterDoesNotFallBackToPi() async throws {
        let root = try temporaryDirectory(named: "OutfitterDesktopMissing")
        defer { try? FileManager.default.removeItem(at: root) }
        try makeExecutable(at: root.appendingPathComponent("pi"), contents: "#!/bin/sh\nexit 0\n")
        let environment = ["PATH": root.path, "OUTFITTER_DESKTOP_CLI": root.appendingPathComponent("missing").path]
        XCTAssertNil(PiExecutableResolver(environment: environment, loginShellResolution: { nil }).resolve())
        let commands = [
            PiRPCClient.defaultPiCommand(environment: environment),
            PiRPCClient.defaultModelListCommand(environment: environment),
            PiRPCClient.isolatedRPCCommand(environment: environment)
        ]
        XCTAssertTrue(commands.allSatisfy { $0.executable == environment["OUTFITTER_DESKTOP_CLI"] })
        XCTAssertFalse(commands.contains { $0.executable == "/usr/bin/env" })
        let health = await PiHealthChecker.check(environment: environment)
        guard case .needsAttention(let issue) = health else {
            return XCTFail("A broken explicit Outfitter installation must require attention")
        }
        XCTAssertTrue(issue.message.contains("Outfitter CLI could not be found"))
    }

    @MainActor
    func testConfiguredRuntimeAtActualProcessBoundaries() async throws {
        let fixture = try ConfiguredOutfitterFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let restore = withOutfitterEnvironment(fixture.executable.path)
        defer { restore() }
        let option = PiModelOption(provider: "outfitter", id: "gpt-6-sol", name: "Sol")
        try fixture.setModels([option])
        let conversation = PiConversationModel()
        conversation.start(workingDirectory: fixture.root.path, sessionPath: nil)
        try await waitUntil { conversation.isProcessStarted && !conversation.isLoadingSession }
        _ = try await conversation.selectedRuntimeModelForTesting()
        await conversation.stopAndWaitForTesting()
        let app = AppModel(modelFavoritesStorage: isolatedOutfitterFavorites())
        defer { app.stopAllRuntimes() }
        await app.refreshModelCatalog(force: true)
        XCTAssertEqual(app.modelSettings.catalog.map(\.stableID), [option.stableID])
        await app.checkPiHealth()
        XCTAssertNil(app.piHealthIssue)
        let invocations = try fixture.records().compactMap { $0["argv"] as? [String] }
        let prefix = ["run", "desktop-test", "--harness", "pi", "--"]
        XCTAssertTrue(invocations.contains(prefix + ["--mode", "rpc"]))
        XCTAssertTrue(invocations.contains(prefix + PiRPCClient.isolatedRPCArguments), "Startup must use an isolated probe")
        XCTAssertTrue(invocations.contains(PiRPCClient.defaultPiCommand(disablesTools: true).arguments), "Catalog must launch the configured producer without tools")
        XCTAssertTrue(invocations.allSatisfy { Array($0.prefix(prefix.count)) == prefix })
    }

    @MainActor
    func testUnavailableExplicitRuntimePublishesStartupIssue() async throws {
        let root = try temporaryDirectory(named: "UnavailableOutfitter")
        defer { try? FileManager.default.removeItem(at: root) }
        let nonExecutable = root.appendingPathComponent("not-executable")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: nonExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: nonExecutable.path)
        for path in [root.appendingPathComponent("missing").path, nonExecutable.path] {
            let restore = withOutfitterEnvironment(path)
            let app = AppModel(modelFavoritesStorage: isolatedOutfitterFavorites())
            await app.checkPiHealth()
            XCTAssertTrue(app.piHealthIssue?.message.contains("Outfitter CLI could not be found") == true,
                          "The app must publish the explicit runtime error: \(path)")
            app.stopAllRuntimes()
            restore()
        }
    }

    @MainActor
    func testRecoveryOpensTerminalAndConsumesInteractiveLoginInput() async throws {
        let fixture = try ConfiguredOutfitterFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let restore = withOutfitterEnvironment(fixture.executable.path)
        defer { restore() }
        let workspace = OutfitterTerminalWorkspace()
        try Data().write(to: fixture.root.appendingPathComponent("fail-health"))
        let app = AppModel(modelFavoritesStorage: isolatedOutfitterFavorites(), piTerminalRecovery: { command in
            try await PiTerminalRecovery.open(command: command, environment: [:], workspace: workspace)
        })
        defer { app.stopAllRuntimes() }
        await app.checkPiHealth()
        XCTAssertNotNil(app.piHealthIssue)
        await app.openPiInTerminal()
        XCTAssertEqual(workspace.application?.lastPathComponent, "Terminal.app")
        let script = try XCTUnwrap(workspace.urls.first)
        XCTAssertEqual(workspace.urls.count, 1)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/sh", script.path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = output
        try process.run()
        try await waitUntil { (try? fixture.records().contains { $0["argv"] as? [String] == ["run", "desktop-test", "--harness", "pi", "--"] }) == true }
        try input.fileHandleForWriting.write(contentsOf: Data("login\n".utf8))
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(String(decoding: result, as: UTF8.self).contains("LOGIN_COMPLETED"))
        let records = try fixture.records()
        XCTAssertEqual(records.compactMap { $0["argv"] as? [String] }.last, ["run", "desktop-test", "--harness", "pi", "--"])
        XCTAssertEqual(records.compactMap { $0["interactive"] as? String }, ["login"])
        XCTAssertEqual(records.compactMap { $0["tty"] as? Bool }, [true])
    }

    @MainActor
    func testLoginRefreshesRealCatalogAndSubmitsRetainedPromptOnce() async throws {
        for inProject in [false, true] {
            let fixture = try ConfiguredOutfitterFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let restore = withOutfitterEnvironment(fixture.executable.path)
            defer { restore() }
            let app = AppModel(modelFavoritesStorage: isolatedOutfitterFavorites())
            defer { app.stopAllRuntimes() }
            app.projects = inProject ? [Project(name: "Test", path: fixture.root.path, sessions: [])] : []
            app.standaloneSessions = []
            app.selectedProjectID = app.projects.first?.id
            app.selectedSessionID = nil
            await app.refreshModelCatalog(force: true)
            XCTAssertTrue(app.modelSettings.catalog.isEmpty)
            app.sendNewChatPrompt(PreparedPrompt(message: "retained payload", images: [], displayAttachments: []))
            app.signInToOutfitter()
            try await waitUntil { !app.isSigningInToOutfitter && app.modelSettings.catalogState != .loading }
            XCTAssertTrue(app.standaloneSessions.isEmpty)
            XCTAssertTrue(app.projects.allSatisfy { $0.sessions.isEmpty })
            let option = PiModelOption(provider: "outfitter", id: "gpt-6-luna", name: "Luna")
            try fixture.setModels([option])
            app.signInToOutfitter()
            try await waitUntil { (try? fixture.records().filter { $0["type"] as? String == "prompt" }.count) == 1 }
            XCTAssertEqual(app.modelSettings.catalog.map(\.stableID), [option.stableID])
            XCTAssertEqual(app.activeConversationModel?.availableModels.map(\.stableID), [option.stableID])
            XCTAssertEqual(app.standaloneSessions.count, inProject ? 0 : 1)
            XCTAssertEqual(app.projects.first?.sessions.count ?? 0, inProject ? 1 : 0)
            let prompts = try fixture.records().filter { $0["type"] as? String == "prompt" && ($0["message"] as? String)?.hasSuffix("retained payload") == true }
            XCTAssertEqual(prompts.count, 1)
            XCTAssertTrue((prompts.first?["message"] as? String)?.hasSuffix("retained payload") == true)
            app.signInToOutfitter()
            try await waitUntil { !app.isSigningInToOutfitter }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(try fixture.records().filter { $0["type"] as? String == "prompt" && ($0["message"] as? String)?.hasSuffix("retained payload") == true }.count, 1)
            if let conversation = app.activeConversationModel { await conversation.stopAndWaitForTesting() }
        }
    }

    @MainActor
    func testSendWithoutPreferredModelDoesNotCreateProjectOrStandaloneRuntime() async throws {
        for inProject in [false, true] {
            for nonempty in [false, true] {
                let fixture = try ConfiguredOutfitterFixture()
                defer { try? FileManager.default.removeItem(at: fixture.root) }
                let restore = withOutfitterEnvironment(fixture.executable.path)
                defer { restore() }
                let app = AppModel(modelFavoritesStorage: isolatedOutfitterFavorites())
                defer { app.stopAllRuntimes() }
                let missing = PiModelOption(provider: "outfitter", id: "missing", name: "Missing")
                app.modelSettings.setFavorite(true, for: missing)
                try fixture.setModels(nonempty ? [PiModelOption(provider: "outfitter", id: "gpt-6-sol", name: "Sol")] : [])
                app.projects = inProject ? [Project(name: "Test", path: fixture.root.path, sessions: [])] : []
                app.standaloneSessions = []
                app.selectedProjectID = app.projects.first?.id
                app.selectedSessionID = nil
                await app.refreshModelCatalog(force: true)
                XCTAssertNil(app.modelSettings.preferredConversationModel)
                let before = try fixture.records().count
                app.sendNewChatPrompt(PreparedPrompt(message: "waiting payload", images: [], displayAttachments: []))
                XCTAssertTrue(app.isSettingsPresented)
                XCTAssertEqual(app.settingsSection, .models)
                XCTAssertTrue(app.standaloneSessions.isEmpty)
                XCTAssertTrue(app.projects.allSatisfy { $0.sessions.isEmpty })
                XCTAssertEqual(try fixture.records().count, before, "Send must not start a runtime")
                XCTAssertTrue(app.outfitterSignInStatus?.contains("Your message is waiting") == true)
                let available = PiModelOption(provider: "outfitter", id: "gpt-6-sol", name: "Sol")
                try fixture.setModels([available])
                app.signInToOutfitter()
                try await waitUntil { (try? fixture.records().contains { $0["type"] as? String == "prompt" && ($0["message"] as? String)?.hasSuffix("waiting payload") == true }) == true }
                XCTAssertEqual(app.selectedProjectID, inProject ? app.projects.first?.id : nil)
                if let conversation = app.activeConversationModel { await conversation.stopAndWaitForTesting() }
            }
        }
    }

    @MainActor
    func testOffscreenSignInControlInvokesConfiguredCLIAndDisplaysResult() async throws {
        // This hosts only a test view in memory. It never opens a window, launches
        // the user's app, or sends input to the desktop/browser.
        let fixture = try ConfiguredOutfitterFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let restore = withOutfitterEnvironment(fixture.executable.path)
        defer { restore() }
        let app = AppModel(modelFavoritesStorage: isolatedOutfitterFavorites())
        defer { app.stopAllRuntimes() }
        app.settingsSection = .models
        func renderedText() throws -> String {
            let renderer = ImageRenderer(content: SettingsModalView(initialSection: .models, onClose: {}).environmentObject(app).background(Color.white))
            let image = try XCTUnwrap(renderer.nsImage)
            var bounds = CGRect(origin: .zero, size: image.size)
            let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &bounds, context: nil, hints: nil))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        }
        let initialText = try renderedText()
        XCTAssertTrue(initialText.contains("Sign in with Outfitter"), initialText)
        // Inspect the actual SwiftUI Button stored in the production view tree;
        // invoke its action without synthesizing an OS event or showing a window.
        func buttons(_ value: Any, depth: Int = 0) -> [Button<Text>] {
            if let button = value as? Button<Text> { return [button] }
            guard depth < 30 else { return [] }
            return Mirror(reflecting: value).children.flatMap { buttons($0.value, depth: depth + 1) }
        }
        let button = try XCTUnwrap(buttons(OutfitterConnectionControls(appModel: app).body).first)
        func findAction(_ value: Any, depth: Int = 0) -> Any? {
            // SwiftUI's pre-Swift-6 non-Sendable actor closure cannot dynamically
            // cast to Swift 6's implicitly Sendable global-actor closure type.
            if String(reflecting: type(of: value)) == "@Swift.MainActor () -> ()" ||
               String(describing: type(of: value)) == "@MainActor () -> ()" { return value }
            guard depth < 5 else { return nil }
            return Mirror(reflecting: value).children.compactMap { findAction($0.value, depth: depth + 1) }.first
        }
        let storedAction = try XCTUnwrap(findAction(button))
        func invoke<Action>(_ action: Action) {
            precondition(MemoryLayout<Action>.size == MemoryLayout<() -> Void>.size)
            unsafeBitCast(action, to: (@MainActor () -> Void).self)()
        }
        _openExistential(storedAction, do: invoke)
        try await waitUntil { !app.isSigningInToOutfitter && app.outfitterSignInStatus?.hasPrefix("Signed in.") == true }
        XCTAssertTrue(try fixture.records().contains { $0["argv"] as? [String] == ["login"] })
        try await Task.sleep(for: .milliseconds(50))
        let signedInText = try renderedText()
        XCTAssertTrue(signedInText.contains("Connected"), signedInText)
        XCTAssertTrue(signedInText.contains("Signed in."), signedInText)
        app.signInToOutfitter(command: PiCommand(executable: "/usr/bin/false", arguments: []))
        try await waitUntil { !app.isSigningInToOutfitter }
        XCTAssertEqual(app.outfitterSignInStatus, "Sign-in did not complete. Try again and approve access in your browser.")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(try renderedText().contains("Sign-in did not complete"))
    }

    @MainActor
    func testLiveConfiguredCLIBrowserApprovalReportsCompletion() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: repo.appendingPathComponent(".local/live-browser-login-enabled").path) else {
            throw XCTSkip("Manual opt-in only: requires immediate permission to open browser and approve a disposable device session.")
        }
        let restore = withOutfitterEnvironment(ProcessInfo.processInfo.environment["OUTFITTER_LIVE_CLI"] ?? repo.appendingPathComponent(".local/cli/bin/outfitter").path)
        defer { restore() }
        setenv("OUTFITTER_DESKTOP_AGENT", "desktop", 1)
        let app = AppModel(modelFavoritesStorage: isolatedOutfitterFavorites())
        defer { app.stopAllRuntimes() }
        app.signInToOutfitter()
        XCTAssertTrue(app.isSigningInToOutfitter)
        let deadline = Date().addingTimeInterval(25)
        while app.isSigningInToOutfitter && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(app.isSigningInToOutfitter, "Approve the disposable request in the browser within this bounded manual test")
        XCTAssertTrue(app.isConnectedToOutfitter)
        XCTAssertEqual(app.outfitterSignInStatus, "Signed in. Choose an Outfitter model in a new chat.")
    }

    @MainActor
    func testLegacyTurnRejectsStreamingCompactionAndQueuedStates() async throws {
        for state in [#"{"isStreaming":true,"isCompacting":false,"pendingMessageCount":0}"#,
                      #"{"isStreaming":false,"isCompacting":true,"pendingMessageCount":0}"#,
                      #"{"isStreaming":false,"isCompacting":false,"pendingMessageCount":1}"#] {
            let fixture = try RPCFixture(mode: .healthy)
            defer { fixture.remove() }
            let stateFile = fixture.directory.appendingPathComponent("state.json")
            try Data(state.utf8).write(to: stateFile)
            let conversation = PiConversationModel(piCommand: PiRPCClient.rpcCommand(from: fixture.expectedCommand))
            conversation.start(workingDirectory: fixture.directory.path, sessionPath: nil)
            try await waitUntil { !conversation.isLoadingSession }
            conversation.handleEventForTesting(try JSONDecoder().decode(RPCEnvelope.self, from: Data(#"{"type":"agent_start"}"#.utf8)))
            conversation.handleEventForTesting(try JSONDecoder().decode(RPCEnvelope.self, from: Data(#"{"type":"agent_end","willRetry":false}"#.utf8)))
            try await Task.sleep(for: .milliseconds(650))
            XCTAssertTrue(conversation.isRunning, state)
            try Data(#"{"isStreaming":false,"isCompacting":false,"pendingMessageCount":0}"#.utf8).write(to: stateFile)
            conversation.handleEventForTesting(try JSONDecoder().decode(RPCEnvelope.self, from: Data(#"{"type":"agent_end","willRetry":false}"#.utf8)))
            try await waitUntil { !conversation.isRunning }
            await conversation.stopAndWaitForTesting()
        }
    }

    @MainActor
    func testInstalledCLISharesDesktopHomeAcrossRPCLoginAndRecovery() async throws {
        let fixture = try ConfiguredOutfitterFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let restore = withOutfitterEnvironment(fixture.executable.path)
        defer { restore() }
        let previous = getenv("OUTFITTER_DESKTOP_STATE_DIRECTORY").map { String(cString: $0) }
        setenv("OUTFITTER_DESKTOP_STATE_DIRECTORY", fixture.root.path, 1)
        defer {
            if let previous { setenv("OUTFITTER_DESKTOP_STATE_DIRECTORY", previous, 1) }
            else { unsetenv("OUTFITTER_DESKTOP_STATE_DIRECTORY") }
        }
        let client = PiRPCClient(workingDirectory: fixture.root)
        try await client.start()
        _ = try await client.getState()
        await client.stop()
        let app = AppModel(modelFavoritesStorage: isolatedOutfitterFavorites())
        defer { app.stopAllRuntimes() }
        app.signInToOutfitter()
        try await waitUntil { !app.isSigningInToOutfitter }
        XCTAssertTrue(app.isConnectedToOutfitter)
        let records = try fixture.records().filter { $0["argv"] != nil }
        XCTAssertTrue(records.contains { $0["argv"] as? [String] == ["login"] })
        XCTAssertTrue(records.allSatisfy { $0["home"] as? String == fixture.root.path })
        let command = try XCTUnwrap(PiRPCClient.resolvedPiCommand())
        let recovery = PiTerminalRecovery.script(command: command, homeDirectory: fixture.root, shell: "/bin/sh")
        XCTAssertTrue(recovery.contains("export OUTFITTER_USER_HOME='\(fixture.root.path)'"))
        XCTAssertEqual(PiRPCClient.runtimeEnvironment(["OUTFITTER_DESKTOP_STATE_DIRECTORY": "ignored", "OUTFITTER_USER_HOME": "existing"])["OUTFITTER_USER_HOME"], "existing")
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), "Timed out waiting for fixture process")
    }

}

private struct RPCFixture {
    enum Mode: String, CustomStringConvertible {
        case healthy
        case exits
        case stalls
        case rpcFailure
        case attention
        case attentionStalls
        var description: String { rawValue }
    }

    let directory: URL
    let executable: URL
    let argumentsFile: URL
    let commandsFile: URL
    let mode: Mode

    init(mode: Mode) throws {
        self.mode = mode
        directory = try temporaryDirectory(named: "PiNativeHealthRPC-\(mode.rawValue)")
        executable = directory.appendingPathComponent("fake-pi.py")
        argumentsFile = directory.appendingPathComponent("arguments.txt")
        commandsFile = directory.appendingPathComponent("commands.txt")
        let script = """
        #!/usr/bin/python3
        import json, os, sys, time
        mode = sys.argv[1]
        open(sys.argv[2], "w").write("\\n".join(sys.argv[4:]))
        open(sys.argv[3], "w").write("")
        if mode == "exits":
            sys.exit(42)
        for line in sys.stdin:
            request = json.loads(line)
            with open(sys.argv[3], "a") as commands:
                commands.write(request["type"] + "\\n")
            if mode == "stalls":
                time.sleep(2)
                continue
            if mode in ["attention", "attentionStalls"]:
                print(json.dumps({"type":"extension_ui_request","id":"setup","method":"confirm","title":"Finish setup","message":"Open Pi interactively"}), flush=True)
                if mode == "attentionStalls":
                    time.sleep(2)
                    continue
            success = mode != "rpcFailure"
            state_file=os.path.join(os.path.dirname(sys.argv[2]),'state.json')
            data=json.load(open(state_file)) if os.path.exists(state_file) else {"sessionFile":None,"isStreaming":False,"isCompacting":False,"pendingMessageCount":0}
            print(json.dumps({"type":"response","id":request["id"],"command":request["type"],"success":success,"data":data}), flush=True)
        """
        try makeExecutable(at: executable, contents: script)
    }

    var environment: [String: String] {
        var value = ProcessInfo.processInfo.environment
        value["PI_NATIVE_TEST_PI_EXECUTABLE"] = executable.path
        value["PI_NATIVE_TEST_PI_ARGUMENTS"] = String(
            data: try! JSONEncoder().encode([mode.rawValue, argumentsFile.path, commandsFile.path]),
            encoding: .utf8
        )!
        value.removeValue(forKey: "PI_NATIVE_RESET_PROJECTS")
        return value
    }

    var expectedCommand: PiCommand {
        PiCommand(
            executable: executable.path,
            arguments: [mode.rawValue, argumentsFile.path, commandsFile.path],
            environmentPath: environment["PATH"]
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func makeExecutable(at url: URL, contents: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func temporaryDirectory(named prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func isolatedOutfitterFavorites() -> UserDefaultsModelFavoritesStorage {
    UserDefaultsModelFavoritesStorage(defaults: UserDefaults(suiteName: "OutfitterTest-\(UUID().uuidString)")!)
}

private struct ConfiguredOutfitterFixture {
    let root: URL
    let executable: URL
    let calls: URL
    let models: URL
    init() throws {
        root = try temporaryDirectory(named: "ConfiguredOutfitter")
        executable = root.appendingPathComponent("outfitter")
        calls = root.appendingPathComponent("calls.jsonl")
        models = root.appendingPathComponent("models.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let callPath = String(data: try encoder.encode(calls.path), encoding: .utf8)!
        let modelPath = String(data: try encoder.encode(models.path), encoding: .utf8)!
        let sessionPath = String(data: try encoder.encode(root.appendingPathComponent("session.jsonl").path), encoding: .utf8)!
        try makeExecutable(at: executable, contents: """
        #!/usr/bin/python3
        import sys,json,os
        calls=\(callPath)
        models=\(modelPath)
        session=\(sessionPath)
        def log(value):
            with open(calls,'a') as f: f.write(json.dumps(value)+'\\n')
        log({'argv':sys.argv[1:],'home':os.environ.get('OUTFITTER_USER_HOME')})
        if sys.argv[1:]==['login']:
            print('LOGIN_READY',flush=True)
            sys.exit(0)
        if '--mode' not in sys.argv:
            print('INTERACTIVE_READY',flush=True)
            line=sys.stdin.readline().strip()
            log({'interactive':line,'tty':os.isatty(0)})
            print('LOGIN_COMPLETED' if line=='login' else 'MISSING_LOGIN',flush=True)
            sys.exit(0)
        def emit(value): print(json.dumps(value),flush=True)
        for line in sys.stdin:
            request=json.loads(line); log(request)
            available=json.load(open(models)) if os.path.exists(models) else []
            model=available[0] if available else None
            data={}
            if request['type']=='get_available_models': data={'models':available}
            if request['type']=='get_available_thinking_levels': data={'levels':['off']}
            if request['type']=='get_state': data={'model':model,'thinkingLevel':'off','sessionFile':session,'isStreaming':False,'isCompacting':False,'pendingMessageCount':0}
            if request['type']=='new_session':
                open(session,'a').close(); data={'sessionFile':session}
            if request['type']=='get_messages': data={'messages':[]}
            emit({'id':request['id'],'type':'response','success':not (request['type']=='get_state' and os.path.exists(os.path.join(os.path.dirname(calls),'fail-health'))),'data':data})
            if request['type']=='prompt':
                emit({'type':'agent_start'})
                emit({'type':'message_update','assistantMessageEvent':{'type':'text_delta','delta':'fixture reply'}})
                emit({'type':'agent_settled'})
        """)
    }
    func setModels(_ values: [PiModelOption]) throws {
        try JSONEncoder().encode(values).write(to: models)
    }
    func records() throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: calls.path) else { return [] }
        return try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
    }
}

@MainActor
private final class OutfitterTerminalWorkspace: PiTerminalWorkspace {
    var urls: [URL] = []
    var application: URL?
    func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL? {
        bundleIdentifier == "com.apple.Terminal" ? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app") : nil
    }
    func open(_ urls: [URL], withApplicationAt applicationURL: URL, configuration: NSWorkspace.OpenConfiguration,
              completionHandler: (@Sendable (NSRunningApplication?, (any Error)?) -> Void)?) {
        self.urls = urls; application = applicationURL; completionHandler?(nil,nil)
    }
}

private func withOutfitterEnvironment(_ path: String) -> () -> Void {
    let keys = ["OUTFITTER_DESKTOP_CLI", "OUTFITTER_DESKTOP_AGENT"]
    let previous = keys.map { getenv($0).map { String(cString: $0) } }
    setenv(keys[0], path, 1); setenv(keys[1], "desktop-test", 1)
    return {
        for (key, value) in zip(keys, previous) {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
    }
}
