import AppKit
import Foundation
import XCTest
@testable import PiNative

final class PiStartupHealthTests: XCTestCase {
    func testLoginShellResolutionSupportsEveryDocumentedGlobalPackageManagerLayout() throws {
        let root = try temporaryDirectory(named: "PiNativeShellResolvers")
        defer { try? FileManager.default.removeItem(at: root) }
        let relativeDirectories = [
            ".npm-global/bin",
            ".local/share/pnpm",
            ".yarn/bin",
            ".bun/bin"
        ]

        for relativeDirectory in relativeDirectories {
            let bin = root.appendingPathComponent(relativeDirectory, isDirectory: true)
            let executable = bin.appendingPathComponent("pi")
            try makeExecutable(at: executable, contents: "#!/bin/sh\nexit 0\n")
            let resolver = PiExecutableResolver(
                environment: ["PATH": root.appendingPathComponent("empty").path],
                homeDirectory: root,
                loginShellResolution: {
                    PiShellResolution(executable: executable.path, path: "\(bin.path):/usr/bin:/bin")
                }
            )

            let command = try XCTUnwrap(resolver.resolve(), "Failed to resolve \(relativeDirectory)")
            XCTAssertEqual(command.executable, executable.path)
            XCTAssertEqual(command.environmentPath?.split(separator: ":").first.map(String.init), bin.path)
        }
    }

    // 2119: REQ-011.1.2
    func testRealLoginShellDiscoversPiOutsideFinderPath() throws {
        let root = try temporaryDirectory(named: "PiNativeRealLoginShell")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent(".bun/bin", isDirectory: true)
        let executable = bin.appendingPathComponent("pi")
        try makeExecutable(at: executable, contents: "#!/bin/sh\nexit 0\n")
        let zDotDirectory = root.appendingPathComponent("zsh", isDirectory: true)
        try FileManager.default.createDirectory(at: zDotDirectory, withIntermediateDirectories: true)
        try "export PATH='\(bin.path):/usr/bin:/bin'\n".write(
            to: zDotDirectory.appendingPathComponent(".zshrc"),
            atomically: true,
            encoding: .utf8
        )

        let resolver = PiExecutableResolver(
            environment: [
                "SHELL": "/bin/zsh",
                "PATH": "/usr/bin:/bin",
                "ZDOTDIR": zDotDirectory.path
            ],
            homeDirectory: root
        )
        let command = try XCTUnwrap(resolver.resolve())

        XCTAssertEqual(command.executable, executable.path)
        XCTAssertEqual(command.environmentPath?.split(separator: ":").first.map(String.init), bin.path)
    }

    // 2119: REQ-011.1.3
    func testOfficialInstallerFallbacksResolveUserLocalAndStandaloneNodeInstalls() throws {
        for usesStandaloneNode in [false, true] {
            let root = try temporaryDirectory(named: "PiNativeOfficialInstaller")
            defer { try? FileManager.default.removeItem(at: root) }
            let executable = usesStandaloneNode
                ? root.appendingPathComponent(".local/share/pi-node/current/bin/pi")
                : root.appendingPathComponent(".local/bin/pi")
            try makeExecutable(at: executable, contents: "#!/bin/sh\nexit 0\n")
            let resolver = PiExecutableResolver(
                environment: ["PATH": root.appendingPathComponent("empty").path],
                homeDirectory: root,
                loginShellResolution: { nil }
            )

            let command = try XCTUnwrap(resolver.resolve())
            XCTAssertEqual(command.executable, executable.path)
            XCTAssertEqual(command.environmentPath?.split(separator: ":").first.map(String.init), executable.deletingLastPathComponent().path)
        }
    }

    // 2119: REQ-011.1.4
    func testNVMFallbackStartsPiWithTheMatchingNodeRuntime() async throws {
        let root = try temporaryDirectory(named: "PiNativeNVMResolver")
        defer { try? FileManager.default.removeItem(at: root) }
        let olderBin = root.appendingPathComponent(".nvm/versions/node/v22.19.0/bin", isDirectory: true)
        try makeExecutable(at: olderBin.appendingPathComponent("pi"), contents: "#!/bin/sh\nexit 42\n")

        let newestBin = root.appendingPathComponent(".nvm/versions/node/v24.6.0/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: newestBin, withIntermediateDirectories: true)
        try makeExecutable(
            at: newestBin.appendingPathComponent("node"),
            contents: "#!/bin/sh\nexec /usr/bin/python3 \"$@\"\n"
        )
        try makeExecutable(at: newestBin.appendingPathComponent("pi"), contents: """
        #!/usr/bin/env node
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            print(json.dumps({"type":"response","id":request["id"],"command":request["type"],"success":True,"data":{}}), flush=True)
        """)
        let resolver = PiExecutableResolver(
            environment: ["PATH": root.appendingPathComponent("empty").path],
            homeDirectory: root,
            loginShellResolution: { nil }
        )

        let command = try XCTUnwrap(resolver.resolve())
        let expectedBin = newestBin.standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertEqual(URL(fileURLWithPath: command.executable).resolvingSymlinksInPath().path, expectedBin + "/pi")
        let resolvedPath = command.environmentPath?.split(separator: ":").first.map(String.init)
        XCTAssertEqual(resolvedPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, expectedBin)

        let client = PiRPCClient(
            piCommand: PiRPCClient.isolatedRPCCommand(from: command),
            workingDirectory: root
        )
        try await client.start()
        let response = try await client.getState(timeoutSeconds: 1)
        await client.stop()
        XCTAssertEqual(response.success, true)
    }

    func testInstalledOutfitterCLIResolvesWithoutEnvironmentAndBeatsPATHPi() throws {
        let root = try temporaryDirectory(named: "PiNativeManagedOutfitter")
        defer { try? FileManager.default.removeItem(at: root) }
        // A `pi` on PATH must not win: Outfitter is PiNative's only backend and
        // resolves itself from its managed install without any environment.
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try makeExecutable(at: bin.appendingPathComponent("pi"), contents: "#!/bin/sh\nexit 0\n")
        let installed = root.appendingPathComponent("Library/Application Support/PiNative/Outfitter/cli/bin/outfitter")
        try makeExecutable(at: installed, contents: "#!/bin/sh\nexit 0\n")

        let resolver = PiExecutableResolver(
            environment: ["PATH": bin.path, "HOME": root.path],
            homeDirectory: root,
            loginShellResolution: { nil }
        )
        let command = try XCTUnwrap(resolver.resolve())
        XCTAssertEqual(command.executable, installed.path)
        XCTAssertEqual(command.arguments, ["run", "desktop", "--harness", "pi", "--"])
    }

    func testPiDependentCommandsPreserveTheResolvedExecutableAndRuntimePath() throws {
        let base = PiCommand(
            executable: "/tmp/custom-pi/bin/pi",
            arguments: ["--custom"],
            environmentPath: "/tmp/custom-pi/bin:/usr/bin"
        )
        let commands = [
            PiRPCClient.rpcCommand(from: base),
            PiRPCClient.modelListCommand(from: base),
            PiRPCClient.isolatedRPCCommand(from: base),
            PiHealthChecker.probeCommand(from: base)
        ]
        XCTAssertTrue(commands.allSatisfy { $0.executable == base.executable })
        XCTAssertTrue(commands.allSatisfy { $0.environmentPath == base.environmentPath })
        XCTAssertTrue(commands.allSatisfy { $0.arguments.starts(with: base.arguments) })

        let recoveryScript = PiTerminalRecovery.script(
            command: base,
            homeDirectory: URL(fileURLWithPath: "/tmp"),
            shell: "/bin/zsh"
        )
        XCTAssertTrue(recoveryScript.contains("exec '/tmp/custom-pi/bin/pi' '--custom'"))
        XCTAssertTrue(recoveryScript.contains("export PATH='/tmp/custom-pi/bin:/usr/bin'"))
    }

    // 2119: REQ-011.1.1
    func testHealthResolutionIsReusedByProductionFeatureEntryPoints() async throws {
        let root = try temporaryDirectory(named: "PiNativeSharedResolution")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let executable = bin.appendingPathComponent("pi")
        try makeExecutable(at: executable, contents: """
        #!/usr/bin/python3
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            print(json.dumps({"type":"response","id":request["id"],"command":request["type"],"success":True,"data":{}}), flush=True)
        """)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(bin.path):/usr/bin:/bin"
        environment["SHELL"] = "/usr/bin/false"
        // Pin HOME to the fixture root so Outfitter CLI self-resolution (which
        // prefers an installed Application Support copy) does not pick up a real
        // install on the test machine; this exercises the legacy Pi discovery.
        environment["HOME"] = root.path
        environment.removeValue(forKey: "OUTFITTER_DESKTOP_CLI")
        environment.removeValue(forKey: "PI_NATIVE_TEST_PI_EXECUTABLE")
        environment.removeValue(forKey: "PI_NATIVE_RESET_PROJECTS")
        PiInvocationCache.shared.resetForTesting()
        defer { PiInvocationCache.shared.resetForTesting() }

        let health = await PiHealthChecker.check(environment: environment, timeoutSeconds: 1)
        guard case .healthy(let resolved) = health else {
            return XCTFail("Expected health check to resolve fixture Pi")
        }
        let productionCommands = [
            PiRPCClient.defaultPiCommand(),
            PiRPCClient.defaultModelListCommand(),
            PiRPCClient.isolatedRPCCommand()
        ]
        XCTAssertEqual(resolved.executable, executable.path)
        XCTAssertTrue(productionCommands.allSatisfy { $0.executable == resolved.executable })
        XCTAssertTrue(productionCommands.allSatisfy { $0.environmentPath == resolved.environmentPath })
        let recoveryScript = PiTerminalRecovery.script(command: resolved, homeDirectory: root, shell: "/bin/zsh")
        XCTAssertTrue(recoveryScript.contains("exec '\(executable.path)'"))
    }

    // 2119: REQ-011.2.1
    func testHealthCheckUsesOnlyNonDestructiveStateRPCAndAcceptsResponse() async throws {
        let fixture = try RPCFixture(mode: .healthy)
        defer { fixture.remove() }
        let result = await PiHealthChecker.check(environment: fixture.environment, timeoutSeconds: 1)

        guard case .healthy(let command) = result else {
            return XCTFail("Expected healthy result, got \(result)")
        }
        XCTAssertEqual(command.executable, fixture.executable.path)
        let launchedArguments = try String(contentsOf: fixture.argumentsFile, encoding: .utf8)
        for argument in PiRPCClient.isolatedRPCArguments {
            XCTAssertTrue(launchedArguments.split(separator: "\n").contains(Substring(argument)))
        }
        XCTAssertEqual(try String(contentsOf: fixture.commandsFile, encoding: .utf8), "get_state\n")
    }

    // 2119: REQ-011.2.1
    // 2119: REQ-011.2.2
    func testHealthCheckSurfacesExitTimeoutRPCFailureAndInteractiveAttention() async throws {
        for mode in [RPCFixture.Mode.exits, .stalls, .rpcFailure, .attention, .attentionStalls] {
            let fixture = try RPCFixture(mode: mode)
            defer { fixture.remove() }
            let result = await PiHealthChecker.check(environment: fixture.environment, timeoutSeconds: 0.5)
            guard case .needsAttention(let issue) = result else {
                XCTFail("Expected recovery issue for \(mode), got \(result)")
                continue
            }
            let expectedMessage: String
            switch mode {
            case .exits:
                expectedMessage = "Pi could not start: process exited with status 42"
            case .stalls:
                expectedMessage = "Pi could not start: pi request 1 timed out."
            case .rpcFailure:
                expectedMessage = "Pi reported an RPC startup failure."
            case .attention, .attentionStalls:
                expectedMessage = "Finish setup: Open Pi interactively"
            case .healthy:
                return XCTFail("Healthy mode is not part of the failure fixture set")
            }
            XCTAssertEqual(issue, PiHealthIssue(message: expectedMessage, command: fixture.expectedCommand))
        }
    }

    // 2119: REQ-011.2.2
    func testHealthCheckSurfacesUnresolvedAndUnlaunchablePi() async {
        let unresolved = await PiHealthChecker.check(resolveCommand: { nil })
        guard case .needsAttention(let unresolvedIssue) = unresolved else {
            return XCTFail("Expected unresolved Pi to need attention")
        }
        XCTAssertEqual(
            unresolvedIssue,
            PiHealthIssue(
                message: "Pi could not be found. Install Pi or make it available in your shell.",
                command: nil
            )
        )

        let missingCommand = PiCommand(executable: "/tmp/pinative-definitely-missing-pi", arguments: [])
        let unlaunchable = await PiHealthChecker.check(
            timeoutSeconds: 0.5,
            resolveCommand: { missingCommand }
        )
        guard case .needsAttention(let launchIssue) = unlaunchable else {
            return XCTFail("Expected unlaunchable Pi to need attention")
        }
        XCTAssertEqual(launchIssue.command, missingCommand)
        XCTAssertTrue(launchIssue.message.hasPrefix("Pi could not start: "))
        XCTAssertFalse(launchIssue.message.dropFirst("Pi could not start: ".count).isEmpty)
    }

    func testTerminalRecoveryUsesResolvedInvocationAndLoginShellFallback() {
        let command = PiCommand(
            executable: "/Users/me/.bun/bin/pi",
            arguments: ["argument with spaces", "it's-safe"],
            environmentPath: "/Users/me/.bun/bin:/usr/bin"
        )
        let exactScript = PiTerminalRecovery.script(
            command: command,
            homeDirectory: URL(fileURLWithPath: "/Users/me/My Work"),
            shell: "/bin/zsh"
        )
        XCTAssertTrue(exactScript.contains("export PATH='/Users/me/.bun/bin:/usr/bin'"))
        XCTAssertTrue(exactScript.contains("exec '/Users/me/.bun/bin/pi' 'argument with spaces' 'it'\"'\"'s-safe'"))
        XCTAssertTrue(exactScript.contains("rm -f \"$0\""))

        let fallbackScript = PiTerminalRecovery.script(
            command: nil,
            homeDirectory: URL(fileURLWithPath: "/Users/me"),
            shell: "/bin/zsh"
        )
        XCTAssertTrue(fallbackScript.contains("exec '/bin/zsh' -l -i -c 'pi'"))
    }

    @MainActor
    // 2119: REQ-011.3.2
    func testTerminalRecoveryOpensTerminalWithResolvedAndFallbackScripts() async throws {
        let workspace = RecordingTerminalWorkspace()
        let command = PiCommand(
            executable: "/Users/me/.bun/bin/pi",
            arguments: ["--version"],
            environmentPath: "/Users/me/.bun/bin:/usr/bin"
        )
        try await PiTerminalRecovery.open(
            command: command,
            environment: ["SHELL": "/bin/zsh"],
            workspace: workspace
        )
        try await PiTerminalRecovery.open(
            command: nil,
            environment: ["SHELL": "/bin/zsh"],
            workspace: workspace
        )
        defer { workspace.openedURLs.flatMap { $0 }.forEach { try? FileManager.default.removeItem(at: $0) } }

        XCTAssertEqual(workspace.requestedBundleIdentifiers, ["com.apple.Terminal", "com.apple.Terminal"])
        XCTAssertEqual(workspace.applicationURLs, [workspace.terminalURL, workspace.terminalURL])
        XCTAssertEqual(workspace.openedURLs.count, 2)
        let resolvedScript = try String(contentsOf: try XCTUnwrap(workspace.openedURLs[0].first), encoding: .utf8)
        let fallbackScript = try String(contentsOf: try XCTUnwrap(workspace.openedURLs[1].first), encoding: .utf8)
        XCTAssertTrue(resolvedScript.contains("export PATH='/Users/me/.bun/bin:/usr/bin'"))
        XCTAssertTrue(resolvedScript.contains("exec '/Users/me/.bun/bin/pi' '--version'"))
        XCTAssertTrue(fallbackScript.contains("exec '/bin/zsh' -l -i -c 'pi'"))
    }

    @MainActor
    // 2119: REQ-011.2.3
    func testRealHealthResultsPreserveAttentionThenClearAfterHealthyStateResponse() async throws {
        let attention = try RPCFixture(mode: .attention)
        let healthy = try RPCFixture(mode: .healthy)
        defer {
            attention.remove()
            healthy.remove()
        }
        var environments = [attention.environment, healthy.environment]
        let appModel = AppModel(piHealthCheck: {
            await PiHealthChecker.check(environment: environments.removeFirst(), timeoutSeconds: 1)
        })

        await appModel.checkPiHealthIfNeeded()
        XCTAssertTrue(appModel.piHealthIssue?.message.contains("Finish setup") == true)
        await appModel.checkPiHealth()
        XCTAssertNil(appModel.piHealthIssue)
    }

    @MainActor
    // 2119: REQ-011.2.4
    func testLiveConversationAttentionPublishesGlobalRecoveryAndPreservesOriginatingChatExplanation() async throws {
        let root = try temporaryDirectory(named: "PiNativeRuntimeAttention")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstSession = Session(name: "background chat", status: .idle, cachedTranscript: [.user(UserMessagePayload(text: "background"))])
        let secondSession = Session(name: "selected chat", status: .idle, cachedTranscript: [.user(UserMessagePayload(text: "selected"))])
        let project = Project(name: "Attention", path: root.path, sessions: [firstSession, secondSession], diffStats: nil)
        let command = PiCommand(executable: "/tmp/resolved-pi", arguments: ["--custom"], environmentPath: "/tmp:/usr/bin")
        let appModel = AppModel(piHealthCheck: { .healthy(command) })
        appModel.automaticallyStartsPendingRuntimes = false
        appModel.projects = [project]

        await appModel.checkPiHealthIfNeeded()
        appModel.select(sessionID: firstSession.id, in: project.id)
        let backgroundModel = try XCTUnwrap(appModel.activeConversationModel)
        appModel.select(sessionID: secondSession.id, in: project.id)
        let selectedModel = try XCTUnwrap(appModel.activeConversationModel)
        let event = try JSONDecoder().decode(RPCEnvelope.self, from: Data(#"{"type":"extension_ui_request","id":"runtime-setup","method":"confirm","title":"Finish Pi setup","message":"Resolve the interactive question"}"#.utf8))

        backgroundModel.handleEventForTesting(event)

        XCTAssertTrue(appModel.activeConversationModel === selectedModel)
        XCTAssertEqual(appModel.piHealthIssue?.command, command)
        XCTAssertTrue(appModel.piHealthIssue?.message.contains("Finish Pi setup") == true)
        XCTAssertTrue(backgroundModel.rpcStatusMessage?.contains("Resolve the interactive question") == true)
        XCTAssertTrue(backgroundModel.items.contains { item in
            if case .notice(_, let text) = item {
                return text.contains("Finish Pi setup") && text.contains("Resolve the interactive question")
            }
            return false
        })
        XCTAssertFalse(selectedModel.items.contains { item in
            if case .notice(_, let text) = item { return text.contains("Finish Pi setup") }
            return false
        })
    }

    @MainActor
    func testRuntimeAttentionWinsOverOlderInFlightHealthyCheckWithoutLosingRecoveryCommand() async throws {
        let root = try temporaryDirectory(named: "PiNativeRuntimeAttentionRace")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(name: "attention chat", status: .idle, cachedTranscript: [.user(UserMessagePayload(text: "attention"))])
        let project = Project(name: "Attention", path: root.path, sessions: [session], diffStats: nil)
        let command = PiCommand(executable: "/tmp/race-resolved-pi", arguments: [], environmentPath: "/tmp:/usr/bin")
        let healthGate = DeferredPiHealthResult()
        let recoveryRecorder = PiRecoveryCommandRecorder()
        let appModel = AppModel(
            piHealthCheck: { await healthGate.run() },
            piTerminalRecovery: { await recoveryRecorder.record($0) }
        )
        appModel.automaticallyStartsPendingRuntimes = false
        appModel.projects = [project]
        appModel.select(sessionID: session.id, in: project.id)
        let model = try XCTUnwrap(appModel.activeConversationModel)
        let event = try JSONDecoder().decode(RPCEnvelope.self, from: Data(#"{"type":"extension_ui_request","id":"runtime-race","method":"input","title":"Pi needs input","message":"Answer in Terminal"}"#.utf8))

        let checkTask = Task { await appModel.checkPiHealthIfNeeded() }
        await healthGate.waitUntilStarted()
        model.handleEventForTesting(event)
        await healthGate.complete(with: .healthy(command))
        await checkTask.value

        XCTAssertTrue(appModel.piHealthIssue?.message.contains("Pi needs input") == true)
        await appModel.openPiInTerminal()
        let recoveredCommand = await recoveryRecorder.command()
        XCTAssertEqual(recoveredCommand, command)
    }

    @MainActor
    // 2119: REQ-011.3.3
    func testSuccessfulTerminalRecoveryArmsOneHealthRecheckThatClearsResolvedIssue() async {
        var checkCount = 0
        var terminalOpenCount = 0
        let appModel = AppModel(
            piHealthCheck: {
                checkCount += 1
                if checkCount == 1 {
                    return .needsAttention(PiHealthIssue(message: "Pi needs setup", command: nil))
                }
                return .healthy(PiCommand(executable: "/tmp/pi", arguments: []))
            },
            piTerminalRecovery: { _ in terminalOpenCount += 1 }
        )

        await appModel.checkPiHealthIfNeeded()
        await appModel.openPiInTerminal()

        XCTAssertNotNil(appModel.piHealthIssue)
        let didRecheck = await appModel.checkPiHealthAfterRecoveryIfNeeded()
        XCTAssertTrue(didRecheck)
        XCTAssertNil(appModel.piHealthIssue)
        XCTAssertEqual(checkCount, 2)
        XCTAssertEqual(terminalOpenCount, 1)
        let didRecheckAgain = await appModel.checkPiHealthAfterRecoveryIfNeeded()
        XCTAssertFalse(didRecheckAgain)
        XCTAssertEqual(checkCount, 2)
    }

    @MainActor
    // 2119: REQ-011.3.3
    // 2119: REQ-011.3.4
    func testFailedTerminalRecoveryDoesNotArmHealthRecheck() async {
        var checkCount = 0
        let appModel = AppModel(
            piHealthCheck: {
                checkCount += 1
                if checkCount == 1 {
                    return .needsAttention(PiHealthIssue(message: "Pi needs setup", command: nil))
                }
                return .healthy(PiCommand(executable: "/tmp/pi", arguments: []))
            },
            piTerminalRecovery: { _ in throw CocoaError(.executableNotLoadable) }
        )

        await appModel.checkPiHealthIfNeeded()
        await appModel.openPiInTerminal()
        let issueAfterFailedOpen = appModel.piHealthIssue
        let didRecheck = await appModel.checkPiHealthAfterRecoveryIfNeeded()

        XCTAssertFalse(didRecheck)
        XCTAssertEqual(appModel.piHealthIssue, issueAfterFailedOpen)
        XCTAssertTrue(appModel.piHealthIssue?.message.contains("Terminal could not be opened") == true)
        XCTAssertEqual(checkCount, 1)
    }

    @MainActor
    // 2119: REQ-011.3.4
    func testNewerAttentionInvalidatesRecoveryRecheckArmedForPriorIssue() async throws {
        let root = try temporaryDirectory(named: "PiNativeStaleRecoveryArm")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(name: "attention chat", status: .idle, cachedTranscript: [.user(UserMessagePayload(text: "attention"))])
        let project = Project(name: "Attention", path: root.path, sessions: [session], diffStats: nil)
        var checkCount = 0
        let appModel = AppModel(
            piHealthCheck: {
                checkCount += 1
                if checkCount == 1 {
                    return .needsAttention(PiHealthIssue(message: "Initial recovery issue", command: nil))
                }
                return .healthy(PiCommand(executable: "/tmp/pi", arguments: []))
            },
            piTerminalRecovery: { _ in }
        )
        appModel.automaticallyStartsPendingRuntimes = false
        appModel.projects = [project]
        appModel.select(sessionID: session.id, in: project.id)
        let model = try XCTUnwrap(appModel.activeConversationModel)

        await appModel.checkPiHealthIfNeeded()
        await appModel.openPiInTerminal()
        let event = try JSONDecoder().decode(RPCEnvelope.self, from: Data(#"{"type":"extension_ui_request","id":"new-attention","method":"confirm","title":"New recovery issue","message":"Resolve the newer issue"}"#.utf8))
        model.handleEventForTesting(event)
        let didRecheck = await appModel.checkPiHealthAfterRecoveryIfNeeded()

        XCTAssertFalse(didRecheck)
        XCTAssertTrue(appModel.piHealthIssue?.message.contains("New recovery issue") == true)
        XCTAssertEqual(checkCount, 1)
    }

    @MainActor
    // 2119: REQ-011.3.4
    func testActivationWithoutTerminalRecoveryLeavesIssueVisible() async {
        var checkCount = 0
        let appModel = AppModel(piHealthCheck: {
            checkCount += 1
            return .needsAttention(PiHealthIssue(message: "Unresolved config changes", command: nil))
        })

        await appModel.checkPiHealthIfNeeded()

        let didRecheck = await appModel.checkPiHealthAfterRecoveryIfNeeded()
        XCTAssertFalse(didRecheck)
        XCTAssertEqual(appModel.piHealthIssue?.message, "Unresolved config changes")
        XCTAssertEqual(checkCount, 1)
    }

    @MainActor
    // 2119: REQ-011.2.2
    func testAppModelPublishesFailureAndClearsItAfterSuccessfulRecheck() async {
        var checkCount = 0
        let appModel = AppModel(piHealthCheck: {
            checkCount += 1
            if checkCount == 1 {
                return .needsAttention(PiHealthIssue(message: "Pi needs setup", command: nil))
            }
            return .healthy(PiCommand(executable: "/tmp/pi", arguments: []))
        })

        await appModel.checkPiHealthIfNeeded()
        XCTAssertEqual(appModel.piHealthIssue?.message, "Pi needs setup")

        await appModel.checkPiHealth()
        XCTAssertNil(appModel.piHealthIssue)
        XCTAssertEqual(checkCount, 2)
    }
}

private actor PiRecoveryCommandRecorder {
    private var recordedCommand: PiCommand?

    func record(_ command: PiCommand?) {
        recordedCommand = command
    }

    func command() -> PiCommand? { recordedCommand }
}

private actor DeferredPiHealthResult {
    private var resultContinuation: CheckedContinuation<PiHealthCheckResult, Never>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var hasStarted = false

    func run() async -> PiHealthCheckResult {
        await withCheckedContinuation { continuation in
            resultContinuation = continuation
            hasStarted = true
            let continuations = startContinuations
            startContinuations.removeAll()
            continuations.forEach { $0.resume() }
        }
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { startContinuations.append($0) }
    }

    func complete(with result: PiHealthCheckResult) {
        resultContinuation?.resume(returning: result)
        resultContinuation = nil
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
            print(json.dumps({"type":"response","id":request["id"],"command":request["type"],"success":success,"data":{"sessionFile":None}}), flush=True)
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

@MainActor
private final class RecordingTerminalWorkspace: PiTerminalWorkspace {
    let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    var requestedBundleIdentifiers: [String] = []
    var openedURLs: [[URL]] = []
    var applicationURLs: [URL] = []

    func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL? {
        requestedBundleIdentifiers.append(bundleIdentifier)
        return terminalURL
    }

    func open(
        _ urls: [URL],
        withApplicationAt applicationURL: URL,
        configuration: NSWorkspace.OpenConfiguration,
        completionHandler: (@Sendable (NSRunningApplication?, (any Error)?) -> Void)?
    ) {
        openedURLs.append(urls)
        applicationURLs.append(applicationURL)
        completionHandler?(nil, nil)
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
