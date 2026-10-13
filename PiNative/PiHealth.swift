import AppKit
import Darwin
import Foundation

struct PiHealthIssue: Equatable, Sendable {
    var message: String
    var command: PiCommand?
}

enum PiHealthCheckResult: Equatable, Sendable {
    case healthy(PiCommand)
    case needsAttention(PiHealthIssue)
}

struct PiShellResolution: Equatable, Sendable {
    var executable: String
    var path: String
}

struct PiExecutableResolver {
    private static let standardPathDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    var environment: [String: String]
    var homeDirectory: URL
    var fileManager: FileManager
    var loginShellResolution: () -> PiShellResolution?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL? = nil,
        fileManager: FileManager = .default,
        loginShellResolution: (() -> PiShellResolution?)? = nil
    ) {
        self.environment = environment
        let resolvedHome = homeDirectory
            ?? environment["HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        self.homeDirectory = resolvedHome
        self.fileManager = fileManager
        self.loginShellResolution = loginShellResolution ?? {
            Self.resolveFromLoginShell(environment: environment, homeDirectory: resolvedHome)
        }
    }

    func resolve() -> PiCommand? {
        let inheritedPath = Self.normalizedPath(environment["PATH"])
        // Outfitter is PiNative's only backend and is shipped with / installed
        // alongside the app, so it resolves itself without a launch environment.
        if let outfitter = outfitterCLIPath() {
            // OUTFITTER_DESKTOP_AGENT is a dev/test override; production uses the
            // bundled "desktop" agent.
            let agent = environment["OUTFITTER_DESKTOP_AGENT"].flatMap { $0.isEmpty ? nil : $0 } ?? "desktop"
            var invocation = command(executable: outfitter, path: inheritedPath)
            invocation.arguments = ["run", agent, "--harness", "pi", "--"]
            return invocation
        }
        if environment["OUTFITTER_DESKTOP_CLI"] != nil {
            // A broken explicit dev override is authoritative; never mask it by
            // falling back to another provider or credential store.
            return nil
        }
        // Legacy Pi discovery, reachable only if no Outfitter CLI is installed.
        if let executable = executableNamedPi(on: inheritedPath) {
            return command(executable: executable, path: inheritedPath)
        }

        if let shell = loginShellResolution(), isExecutable(shell.executable) {
            return command(executable: shell.executable, path: shell.path)
        }

        let fallbackPath = Self.mergedPath(inheritedPath)
        for executable in officialInstallerCandidates() where isExecutable(executable) {
            return command(executable: executable, path: fallbackPath)
        }

        for executable in nvmCandidates() where isExecutable(executable) {
            return command(executable: executable, path: fallbackPath)
        }

        if let executable = executableNamedPi(on: Self.standardPathDirectories.joined(separator: ":")) {
            return command(executable: executable, path: fallbackPath)
        }

        return nil
    }

    /// Resolves the Outfitter CLI without requiring a launch environment: an
    /// explicit `OUTFITTER_DESKTOP_CLI` override wins (the one retained dev/CI
    /// knob; a broken path is authoritative, not masked), then the copy bundled
    /// inside the app, then the installed Application Support copy.
    func outfitterCLIPath() -> String? {
        if let explicit = environment["OUTFITTER_DESKTOP_CLI"] {
            return isExecutable(explicit) ? explicit : nil
        }
        for candidate in Self.managedCLICandidates(homeDirectory: homeDirectory) where isExecutable(candidate) {
            return candidate
        }
        return nil
    }

    /// Whether PiNative can resolve an Outfitter CLI without launching anything.
    /// Gates the sign-in affordances now that Outfitter is the only backend.
    static func hasResolvableOutfitterCLI(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        PiExecutableResolver(environment: environment).outfitterCLIPath() != nil
    }

    /// Managed Outfitter CLI locations, highest priority first: the copy bundled
    /// inside the app, then the installed Application Support copy.
    private static func managedCLICandidates(homeDirectory: URL) -> [String] {
        var candidates: [String] = []
        if let resource = Bundle.main.resourceURL {
            candidates.append(resource.appendingPathComponent("Outfitter/cli/bin/outfitter").path)
        }
        candidates.append(installedCLIPath(homeDirectory: homeDirectory))
        return candidates
    }

    static func installedCLIPath(homeDirectory: URL) -> String {
        homeDirectory.appendingPathComponent("Library/Application Support/PiNative/Outfitter/cli/bin/outfitter").path
    }

    /// The Outfitter Desktop state directory (sign-in, settings) under
    /// Application Support, used when no explicit state directory is set.
    static func managedStateDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/PiNative/Outfitter/state").path
    }

    private func executableNamedPi(on path: String) -> String? {
        for directory in path.split(separator: ":", omittingEmptySubsequences: true).map(String.init) {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("pi").path
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    private func officialInstallerCandidates() -> [String] {
        var candidates = [homeDirectory.appendingPathComponent(".local/bin/pi").path]
        let dataHome = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? homeDirectory.appendingPathComponent(".local/share", isDirectory: true)
        candidates.append(dataHome.appendingPathComponent("pi-node/current/bin/pi").path)
        return candidates
    }

    private func nvmCandidates() -> [String] {
        let versionsDirectory = homeDirectory.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        guard let versions = try? fileManager.contentsOfDirectory(
            at: versionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return versions
            .sorted { Self.compareNodeVersion($0.lastPathComponent, $1.lastPathComponent) == .orderedDescending }
            .map { $0.appendingPathComponent("bin/pi").path }
    }

    private func isExecutable(_ path: String) -> Bool {
        guard path.hasPrefix("/"), fileManager.isExecutableFile(atPath: path) else { return false }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        return !isDirectory.boolValue
    }

    private func command(executable: String, path: String) -> PiCommand {
        let binDirectory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        return PiCommand(
            executable: executable,
            arguments: [],
            environmentPath: Self.prepending(binDirectory, to: Self.mergedPath(path))
        )
    }

    static func resolveFromLoginShell(environment: [String: String], homeDirectory: URL) -> PiShellResolution? {
        let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard shell.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        let marker = "__PINATIVE_PI_ENV_\(UUID().uuidString)__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = [
            "-l", "-i", "-c",
            "/usr/bin/printf '\\n\(marker)_COMMAND\\n'; /usr/bin/which pi 2>/dev/null; /usr/bin/printf '\\n\(marker)_ENV\\n'; /usr/bin/env | /usr/bin/grep -a '^PATH='"
        ]
        process.currentDirectoryURL = homeDirectory
        process.environment = environment
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiNative-Shell-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ),
              let output = try? FileHandle(forWritingTo: outputURL),
              let nullOutput = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        else { return nil }
        defer {
            try? output.close()
            try? nullOutput.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        process.standardOutput = output
        process.standardError = nullOutput

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        guard finished.wait(timeout: .now() + 3) == .success else {
            process.terminate()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return nil
        }
        try? output.synchronize()

        guard let text = try? String(contentsOf: outputURL, encoding: .utf8),
              let commandMarker = text.range(of: "\n\(marker)_COMMAND\n", options: .backwards),
              let environmentMarker = text.range(of: "\n\(marker)_ENV\n", options: .backwards),
              commandMarker.upperBound <= environmentMarker.lowerBound
        else { return nil }

        let executable = text[commandMarker.upperBound..<environmentMarker.lowerBound]
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let environmentOutput = text[environmentMarker.upperBound...]
        let path = environmentOutput
            .split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("PATH=") }
            .map { String($0.dropFirst(5)) } ?? ""
        guard executable.hasPrefix("/"), !path.isEmpty else { return nil }
        return PiShellResolution(executable: executable, path: path)
    }

    private static func normalizedPath(_ path: String?) -> String {
        var directories: [String] = []
        for directory in (path ?? "").split(separator: ":", omittingEmptySubsequences: true).map(String.init) {
            if !directories.contains(directory) { directories.append(directory) }
        }
        return directories.joined(separator: ":")
    }

    private static func mergedPath(_ path: String?) -> String {
        var directories = normalizedPath(path).split(separator: ":").map(String.init)
        for directory in standardPathDirectories where !directories.contains(directory) {
            directories.append(directory)
        }
        return directories.joined(separator: ":")
    }

    private static func prepending(_ directory: String, to path: String) -> String {
        let remainder = path.split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != directory }
        return ([directory] + remainder).joined(separator: ":")
    }

    private static func compareNodeVersion(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }
}

final class PiInvocationCache: @unchecked Sendable {
    static let shared = PiInvocationCache()

    private let lock = NSLock()
    private var hasCachedValue = false
    private var cachedCommand: PiCommand?

    func command(refresh: Bool = false, resolve: () -> PiCommand?) -> PiCommand? {
        lock.lock()
        if hasCachedValue, !refresh {
            let command = cachedCommand
            lock.unlock()
            return command
        }
        lock.unlock()

        let resolvedCommand = resolve()

        lock.lock()
        if refresh || !hasCachedValue {
            cachedCommand = resolvedCommand
            hasCachedValue = true
        }
        let command = cachedCommand
        lock.unlock()
        return command
    }

    func resetForTesting() {
        lock.lock()
        cachedCommand = nil
        hasCachedValue = false
        lock.unlock()
    }
}

enum PiInteractiveAttention {
    static func message(from event: RPCEnvelope) -> String {
        let title = event["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = event["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = [title, message]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ": ")
        return detail.isEmpty ? "Pi needs interactive setup before PiNative can use it." : detail
    }
}

private actor PiHealthObservation {
    private var attentionMessage: String?

    func observe(_ event: RPCEnvelope) {
        guard event.type == "extension_ui_request" else { return }
        attentionMessage = PiInteractiveAttention.message(from: event)
    }

    func message() -> String? { attentionMessage }
}

enum PiHealthChecker {
    static func check(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeoutSeconds: TimeInterval = 8,
        resolveCommand: (@Sendable () async -> PiCommand?)? = nil
    ) async -> PiHealthCheckResult {
        if let sequenceFile = environment["PI_NATIVE_TEST_PI_HEALTH_SEQUENCE_FILE"], !sequenceFile.isEmpty {
            let sequence = environment["PI_NATIVE_TEST_PI_HEALTH_SEQUENCE"]?
                .split(separator: "|", omittingEmptySubsequences: false)
                .map(String.init)
                ?? [environment["PI_NATIVE_TEST_PI_HEALTH_FAILURE"] ?? "Pi needs interactive setup.", "healthy"]
            let index = (try? String(contentsOfFile: sequenceFile, encoding: .utf8)).flatMap(Int.init) ?? 0
            try? String(index + 1).write(toFile: sequenceFile, atomically: true, encoding: .utf8)
            let value = sequence[min(index, sequence.count - 1)]
            if value == "healthy" {
                return .healthy(PiCommand(executable: "/usr/bin/true", arguments: []))
            }
            return .needsAttention(PiHealthIssue(message: value, command: nil))
        }
        if let forcedFailure = environment["PI_NATIVE_TEST_PI_HEALTH_FAILURE"], !forcedFailure.isEmpty {
            return .needsAttention(PiHealthIssue(message: forcedFailure, command: nil))
        }
        if environment["PI_NATIVE_TEST_PI_HEALTHY"] == "1"
            || (environment["PI_NATIVE_RESET_PROJECTS"] == "1" && environment["PI_NATIVE_TEST_PI_EXECUTABLE"] == nil) {
            return .healthy(PiCommand(executable: "/usr/bin/true", arguments: []))
        }

        let baseCommand: PiCommand?
        if let resolveCommand {
            baseCommand = await resolveCommand()
        } else {
            baseCommand = await Task.detached(priority: .userInitiated) {
                PiRPCClient.resolvedPiCommand(refresh: true, environment: environment)
            }.value
        }
        guard let baseCommand else {
            return .needsAttention(PiHealthIssue(
                message: environment["OUTFITTER_DESKTOP_CLI"] != nil
                    ? "The configured Outfitter CLI could not be found. Set OUTFITTER_DESKTOP_CLI to an executable absolute path."
                    : "Pi could not be found. Install Pi or make it available in your shell.",
                command: nil
            ))
        }

        let command = probeCommand(from: baseCommand)
        let client = PiRPCClient(piCommand: command, workingDirectory: FileManager.default.homeDirectoryForCurrentUser)
        let observation = PiHealthObservation()
        await client.setOnEvent { event in await observation.observe(event) }

        do {
            try await client.start()
            let response = try await client.getState(timeoutSeconds: timeoutSeconds)
            await client.stop()
            if response.success == false {
                return .needsAttention(PiHealthIssue(message: "Pi reported an RPC startup failure.", command: baseCommand))
            }
            if let message = await observation.message() {
                return .needsAttention(PiHealthIssue(message: message, command: baseCommand))
            }
            return .healthy(baseCommand)
        } catch {
            let attentionMessage = await observation.message()
            let diagnostics = await client.recentDiagnostics(maxLines: 4)
            await client.stop()
            let detail = diagnostics
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .last {
                    $0.hasPrefix("stderr:")
                        || $0.hasPrefix("process exited")
                        || $0.hasPrefix("decode failed")
                }
            let message = attentionMessage
                ?? detail.map { "Pi could not start: \($0)" }
                ?? "Pi could not start: \(error.localizedDescription)"
            return .needsAttention(PiHealthIssue(message: message, command: baseCommand))
        }
    }

    static func probeCommand(from invocation: PiCommand) -> PiCommand {
        PiRPCClient.isolatedRPCCommand(from: invocation)
    }
}

@MainActor
protocol PiTerminalWorkspace: AnyObject {
    func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL?
    func open(
        _ urls: [URL],
        withApplicationAt applicationURL: URL,
        configuration: NSWorkspace.OpenConfiguration,
        completionHandler: (@Sendable (NSRunningApplication?, (any Error)?) -> Void)?
    )
}

extension NSWorkspace: PiTerminalWorkspace {}

enum PiTerminalRecovery {
    static func script(command: PiCommand?, homeDirectory: URL, shell: String) -> String {
        let launch: String
        if let command {
            let arguments = ([command.executable] + command.arguments).map(shellQuote).joined(separator: " ")
            let exportPath = command.environmentPath.map { "export PATH=\(shellQuote($0))\n" } ?? ""
            let exportHome = PiRPCClient.runtimeEnvironment()["OUTFITTER_USER_HOME"].map { "export OUTFITTER_USER_HOME=\(shellQuote($0))\n" } ?? ""
            launch = "\(exportPath)\(exportHome)exec \(arguments)"
        } else {
            launch = "exec \(shellQuote(shell)) -l -i -c \(shellQuote("pi"))"
        }
        return """
        #!/bin/sh
        rm -f "$0"
        cd \(shellQuote(homeDirectory.path))
        \(launch)
        """
    }

    @MainActor
    static func open(
        command: PiCommand?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workspace: any PiTerminalWorkspace = NSWorkspace.shared
    ) async throws {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let contents = script(command: command, homeDirectory: homeDirectory, shell: shell)

        if let capturePath = environment["PI_NATIVE_TEST_TERMINAL_CAPTURE_FILE"] {
            try contents.write(toFile: capturePath, atomically: true, encoding: .utf8)
            return
        }

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiNative-Recover-\(UUID().uuidString).command")
        guard FileManager.default.createFile(
            atPath: scriptURL.path,
            contents: Data(contents.utf8),
            attributes: [.posixPermissions: 0o700]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard let terminalURL = workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw CocoaError(.executableNotLoadable)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            workspace.open(
                [scriptURL],
                withApplicationAt: terminalURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
