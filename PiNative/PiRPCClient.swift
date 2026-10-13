import Darwin
import Foundation

actor PiRPCClient {
    enum ClientError: Error, LocalizedError {
        case processAlreadyRunning
        case processNotRunning
        case processExited
        case requestTimedOut(Int)
        case requestCancelled(Int)
        case invalidResponse(String)
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .processAlreadyRunning: "pi is already running."
            case .processNotRunning: "pi is not running."
            case .processExited: "pi exited."
            case .requestTimedOut(let id): "pi request \(id) timed out."
            case .requestCancelled(let id): "pi request \(id) was cancelled."
            case .invalidResponse(let line): "Invalid pi response: \(line)"
            case .writeFailed: "Failed to write pi request."
            }
        }
    }

    private struct PendingRequest {
        var command: String
        var continuation: CheckedContinuation<RPCEnvelope, Error>
    }

    private var piCommand: PiCommand?
    private let workingDirectory: URL
    private let disablesTools: Bool
    private let usesIsolatedCommand: Bool
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var nextRequestID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var stdoutReadTask: Task<Void, Never>?
    private var stderrReadTask: Task<Void, Never>?
    private var processExitStream: AsyncStream<Int32>?
    private var isStopping = false
    private(set) var diagnostics: [String] = []
    var onEvent: (@Sendable (RPCEnvelope) async -> Void)?

    init(
        piCommand: PiCommand? = nil,
        workingDirectory: URL,
        disablesTools: Bool = false,
        usesIsolatedCommand: Bool = false
    ) {
        self.piCommand = piCommand
        self.workingDirectory = workingDirectory
        self.disablesTools = disablesTools
        self.usesIsolatedCommand = usesIsolatedCommand
    }

    static func runtimeEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = environment
        // Outfitter Desktop's signed-in state lives under Application Support.
        // The CLI locates its state via OUTFITTER_USER_HOME and has no flag for
        // it, so the app sets this single derived variable on the child it
        // spawns — pointing at the managed state directory by default so a
        // plainly launched app still finds the signed-in runtime. An explicit
        // OUTFITTER_USER_HOME (or dev state directory) is always preserved.
        if result["OUTFITTER_USER_HOME"]?.isEmpty ?? true {
            let state = environment["OUTFITTER_DESKTOP_STATE_DIRECTORY"].flatMap { $0.isEmpty ? nil : $0 }
                ?? PiExecutableResolver.managedStateDirectory(environment: environment)
            result["OUTFITTER_USER_HOME"] = state
        }
        return result
    }

    static let isolatedRPCArguments = [
        "--mode", "rpc",
        "--no-session",
        "--no-tools",
        "--no-extensions",
        "--no-skills",
        "--no-prompt-templates",
        "--no-context-files"
    ]

    private static func unresolvedCommand(environment: [String: String]) -> PiCommand {
        if let configured = environment["OUTFITTER_DESKTOP_CLI"] {
            return PiCommand(
                executable: configured.hasPrefix("/") ? configured : "/__invalid_outfitter_desktop_cli__",
                arguments: ["run", "--harness", "pi", "--"]
            )
        }
        return PiCommand(executable: "/usr/bin/env", arguments: ["pi"])
    }

    static func defaultPiCommand(disablesTools: Bool = false, environment: [String: String] = ProcessInfo.processInfo.environment) -> PiCommand {
        let invocation = resolvedPiCommand(environment: environment) ?? unresolvedCommand(environment: environment)
        return rpcCommand(from: invocation, disablesTools: disablesTools)
    }

    static func rpcCommand(from invocation: PiCommand, disablesTools: Bool = false) -> PiCommand {
        let toolArguments = disablesTools ? ["--no-tools"] : []
        return PiCommand(
            executable: invocation.executable,
            arguments: invocation.arguments + ["--mode", "rpc"] + toolArguments,
            environmentPath: invocation.environmentPath
        )
    }

    static func isolatedRPCCommand(environment: [String: String] = ProcessInfo.processInfo.environment) -> PiCommand {
        if let executable = environment["PI_NATIVE_TEST_TITLE_PI_EXECUTABLE"] {
            let arguments = decodedArguments(environment["PI_NATIVE_TEST_TITLE_PI_ARGUMENTS"])
            return PiCommand(
                executable: executable,
                arguments: arguments + isolatedRPCArguments,
                environmentPath: environment["PATH"]
            )
        }
        let invocation = resolvedPiCommand(usesTestOverride: false, environment: environment)
            ?? unresolvedCommand(environment: environment)
        return isolatedRPCCommand(from: invocation)
    }

    static func isolatedRPCCommand(from invocation: PiCommand) -> PiCommand {
        PiCommand(
            executable: invocation.executable,
            arguments: invocation.arguments + isolatedRPCArguments,
            environmentPath: invocation.environmentPath
        )
    }

    static func defaultModelListCommand(environment: [String: String] = ProcessInfo.processInfo.environment) -> PiCommand {
        let invocation = resolvedPiCommand(environment: environment) ?? unresolvedCommand(environment: environment)
        return modelListCommand(from: invocation)
    }

    static func modelListCommand(from invocation: PiCommand) -> PiCommand {
        PiCommand(
            executable: invocation.executable,
            arguments: invocation.arguments + ["--list-models"],
            environmentPath: invocation.environmentPath
        )
    }

    static func resolvedPiCommand(
        refresh: Bool = false,
        usesTestOverride: Bool = true,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PiCommand? {
        if usesTestOverride, let testExecutable = environment["PI_NATIVE_TEST_PI_EXECUTABLE"] {
            return PiCommand(
                executable: testExecutable,
                arguments: decodedArguments(environment["PI_NATIVE_TEST_PI_ARGUMENTS"]),
                environmentPath: environment["PATH"]
            )
        }
        if environment["OUTFITTER_DESKTOP_CLI"] != nil {
            return PiExecutableResolver(environment: environment).resolve()
        }
        return PiInvocationCache.shared.command(refresh: refresh) {
            PiExecutableResolver(environment: environment).resolve()
        }
    }

    private static func decodedArguments(_ encoded: String?) -> [String] {
        encoded
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }

    deinit {
        process?.terminate()
    }

    func start() throws {
        guard process == nil, !isStopping else { throw ClientError.processAlreadyRunning }

        let command: PiCommand
        if let piCommand {
            command = piCommand
        } else if usesIsolatedCommand {
            command = Self.isolatedRPCCommand()
        } else {
            command = Self.defaultPiCommand(disablesTools: disablesTools)
        }
        piCommand = command

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.currentDirectoryURL = workingDirectory
        var environment = Self.runtimeEnvironment()
        if let resolvedPath = command.environmentPath, !resolvedPath.isEmpty {
            environment["PATH"] = resolvedPath
        } else {
            let existingPath = environment["PATH"] ?? ""
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" + (existingPath.isEmpty ? "" : ":\(existingPath)")
        }
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let (processExitStream, processExitContinuation) = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            processExitContinuation.yield(status)
            processExitContinuation.finish()
            Task { await self?.handleProcessExit(status: status, processID: process.processIdentifier) }
        }

        try process.run()

        self.process = process
        self.processExitStream = processExitStream
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        stdoutReadTask = Self.makeReadTask(handle: stdoutPipe.fileHandleForReading) { [weak self] data in
            await self?.receiveStdout(data)
        }
        stderrReadTask = Self.makeReadTask(handle: stderrPipe.fileHandleForReading) { [weak self] data in
            await self?.receiveStderr(data)
        }
        log("started pi rpc in \(workingDirectory.path)")
    }

    func stop() async {
        guard !isStopping else { return }
        isStopping = true
        let processToStop = process
        let exitStream = processExitStream
        try? stdinPipe?.fileHandleForWriting.close()

        if let processToStop {
            var observedExit = !processToStop.isRunning
            if processToStop.isRunning {
                processToStop.terminate()
                observedExit = await Self.waitForExit(on: exitStream, timeoutNanoseconds: 1_000_000_000)
                if !observedExit, processToStop.isRunning {
                    kill(processToStop.processIdentifier, SIGKILL)
                    observedExit = await Self.waitForExit(on: exitStream, timeoutNanoseconds: 1_000_000_000)
                }
            }
            if observedExit || !processToStop.isRunning {
                processToStop.waitUntilExit()
            }
        }

        try? stdoutPipe?.fileHandleForReading.close()
        try? stderrPipe?.fileHandleForReading.close()
        stdoutReadTask?.cancel()
        stderrReadTask?.cancel()
        stdoutReadTask = nil
        stderrReadTask = nil

        failAllPending(ClientError.processExited)
        process = nil
        processExitStream = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        stdoutBuffer.removeAll(keepingCapacity: false)
        stderrBuffer.removeAll(keepingCapacity: false)
        isStopping = false
        log("stopped pi rpc")
    }

    private nonisolated static func waitForExit(
        on stream: AsyncStream<Int32>?,
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        guard let stream else { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream { return true }
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return false
            }
            let didExit = await group.next() ?? false
            group.cancelAll()
            return didExit
        }
    }

    private nonisolated static func makeReadTask(
        handle: FileHandle,
        receive: @escaping @Sendable (Data) async -> Void
    ) -> Task<Void, Never> {
        Task.detached {
            while !Task.isCancelled {
                let data = handle.availableData
                guard !data.isEmpty else { return }
                await receive(data)
            }
        }
    }

    /// Empirically verified (implementation plan §G): the "prompt" command's
    /// RPC response is an ack-of-receipt, not "turn fully finished" — it
    /// returns quickly even for turns that run well past 15s. `isRunning` in
    /// `PiConversationModel` is correctly driven by the async `agent_start`/
    /// `agent_end` event stream, not by this call resolving. This timeout is
    /// therefore defensive margin against a stalled/unresponsive process, not
    /// a per-turn budget — kept far above the shared 15s default so a slow
    /// ack under load can't masquerade as a failed prompt while the turn is
    /// actually still running server-side.
    func prompt(_ message: String, images: [RPCImageContent] = [], timeoutSeconds: TimeInterval = 120) async throws -> RPCEnvelope {
        try await send(command: "prompt", fields: Self.promptFields(message: message, images: images), timeoutSeconds: timeoutSeconds)
    }

    /// Queue input for the next model turn while the agent is active. The
    /// response acknowledges queueing; Pi owns the actual delivery boundary.
    func steer(_ message: String, images: [RPCImageContent] = [], timeoutSeconds: TimeInterval = 15) async throws -> RPCEnvelope {
        try await send(command: "steer", fields: Self.steerFields(message: message, images: images), timeoutSeconds: timeoutSeconds)
    }

    static func steerFields(message: String, images: [RPCImageContent] = []) -> [String: JSONValue] {
        promptFields(message: message, images: images)
    }

    static func promptFields(message: String, images: [RPCImageContent] = []) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["message": .string(message)]
        if !images.isEmpty {
            fields["images"] = .array(images.map { image in
                .object([
                    "type": .string(image.type),
                    "mimeType": .string(image.mimeType),
                    "data": .string(image.data)
                ])
            })
        }
        return fields
    }

    func getCommands(timeoutSeconds: TimeInterval = 15) async throws -> RPCEnvelope {
        try await send(command: "get_commands", fields: [:], timeoutSeconds: timeoutSeconds)
    }

    func getState(timeoutSeconds: TimeInterval = 15) async throws -> RPCEnvelope {
        try await send(command: "get_state", fields: [:], timeoutSeconds: timeoutSeconds)
    }

    func getMessages(timeoutSeconds: TimeInterval = 15) async throws -> RPCEnvelope {
        try await send(command: "get_messages", fields: [:], timeoutSeconds: timeoutSeconds)
    }

    func switchSession(_ sessionPath: String, timeoutSeconds: TimeInterval = 15) async throws -> RPCEnvelope {
        try await send(command: "switch_session", fields: ["sessionPath": .string(sessionPath)], timeoutSeconds: timeoutSeconds)
    }

    func newSession(timeoutSeconds: TimeInterval = 15) async throws -> RPCEnvelope {
        try await send(command: "new_session", fields: [:], timeoutSeconds: timeoutSeconds)
    }

    /// Remove queued steering and follow-up input before aborting. Pi otherwise
    /// continues accepted queue entries after `abort`, which would race the
    /// client's post-stop replay and risk duplicate delivery.
    func clearQueue(timeoutSeconds: TimeInterval = 15) async throws -> RPCEnvelope {
        let response = try await send(command: "clear_queue", fields: [:], timeoutSeconds: timeoutSeconds)
        guard response.success != false else {
            log("clear_queue rejected; caller must fall back to process termination")
            throw ClientError.invalidResponse(response.error?.stringValue ?? "Pi rejected clear_queue.")
        }
        return response
    }

    /// Genuine server-side turn cancellation (`session.abort()` in pi's RPC
    /// mode) — not a client-side give-up. See implementation plan §G.
    func abort(timeoutSeconds: TimeInterval = 15) async throws -> RPCEnvelope {
        try await send(command: "abort", fields: [:], timeoutSeconds: timeoutSeconds)
    }

    func getAvailableModels(timeoutSeconds: TimeInterval = 15) async throws -> RPCEnvelope {
        try await send(command: "get_available_models", fields: [:], timeoutSeconds: timeoutSeconds)
    }

    func setModel(provider: String, modelId: String, timeoutSeconds: TimeInterval = 15) async throws -> RPCEnvelope {
        try await send(command: "set_model", fields: ["provider": .string(provider), "modelId": .string(modelId)], timeoutSeconds: timeoutSeconds)
    }

    func getAvailableThinkingLevels(timeoutSeconds: TimeInterval = 15) async throws -> RPCEnvelope {
        try await send(command: "get_available_thinking_levels", fields: [:], timeoutSeconds: timeoutSeconds)
    }

    func setThinkingLevel(_ level: String, timeoutSeconds: TimeInterval = 15) async throws -> RPCEnvelope {
        try await send(command: "set_thinking_level", fields: ["level": .string(level)], timeoutSeconds: timeoutSeconds)
    }

    func getLastAssistantText(timeoutSeconds: TimeInterval = 15) async throws -> RPCEnvelope {
        try await send(command: "get_last_assistant_text", fields: [:], timeoutSeconds: timeoutSeconds)
    }

    func setSessionName(_ name: String, timeoutSeconds: TimeInterval = 15) async throws -> RPCEnvelope {
        try await send(command: "set_session_name", fields: ["name": .string(name)], timeoutSeconds: timeoutSeconds)
    }

    func setOnEvent(_ handler: @escaping @Sendable (RPCEnvelope) async -> Void) {
        onEvent = handler
    }

    func extensionUIResponse(id: String, fields: [String: JSONValue]) async throws {
        guard let process, process.isRunning, stdinPipe != nil else {
            throw ClientError.processNotRunning
        }
        var request: [String: JSONValue] = ["type": .string("extension_ui_response"), "id": .string(id)]
        for (key, value) in fields { request[key] = value }
        var data = try JSONEncoder().encode(JSONValue.object(request))
        data.append(0x0A)
        do {
            try stdinPipe?.fileHandleForWriting.write(contentsOf: data)
            log("--> extension_ui_response \(id)")
        } catch {
            throw ClientError.writeFailed
        }
    }

    func recentDiagnostics(maxLines: Int = 12) -> String {
        diagnostics.suffix(maxLines).joined(separator: "\n")
    }

    private func send(command: String, fields: [String: JSONValue], timeoutSeconds: TimeInterval) async throws -> RPCEnvelope {
        guard let process, process.isRunning, stdinPipe != nil else {
            throw ClientError.processNotRunning
        }

        let id = nextRequestID
        nextRequestID += 1

        return try await withThrowingTaskGroup(of: RPCEnvelope.self) { group in
            group.addTask { [weak self] in
                try await self?.performSend(id: id, command: command, fields: fields) ?? { throw ClientError.processNotRunning }()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw ClientError.requestTimedOut(id)
            }

            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                cancelPendingRequest(id: id, error: error)
                throw error
            }
        }
    }

    private func performSend(id: Int, command: String, fields: [String: JSONValue]) async throws -> RPCEnvelope {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = PendingRequest(command: command, continuation: continuation)

                do {
                    var request: [String: JSONValue] = ["id": .number(Double(id)), "type": .string(command)]
                    for (key, value) in fields { request[key] = value }
                    var data = try JSONEncoder().encode(JSONValue.object(request))
                    data.append(0x0A)
                    try stdinPipe?.fileHandleForWriting.write(contentsOf: data)
                    log("--> #\(id) \(command)")
                } catch {
                    pending.removeValue(forKey: id)
                    continuation.resume(throwing: ClientError.writeFailed)
                }
            }
        } onCancel: {
            Task { await self.cancelPendingRequest(id: id, error: ClientError.requestCancelled(id)) }
        }
    }

    private func receiveStdout(_ data: Data) async {
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[..<newline]
            stdoutBuffer.removeSubrange(...newline)
            guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) else { continue }
            await handleStdoutLine(line)
        }
    }

    private func receiveStderr(_ data: Data) {
        stderrBuffer.append(data)
        while let newline = stderrBuffer.firstIndex(of: 0x0A) {
            let lineData = stderrBuffer[..<newline]
            stderrBuffer.removeSubrange(...newline)
            guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) else { continue }
            log("stderr: \(line)")
        }
    }

    private func handleStdoutLine(_ line: String) async {
        log("<-- \(line)")

        do {
            let envelope = try JSONDecoder().decode(RPCEnvelope.self, from: Data(line.utf8))
            if envelope.type == "response", let id = envelope.id, let pendingRequest = pending.removeValue(forKey: id) {
                pendingRequest.continuation.resume(returning: envelope)
            } else if let onEvent {
                await onEvent(envelope)
            }
        } catch {
            log("decode failed: \(error.localizedDescription)")
        }
    }

    private func handleProcessExit(status: Int32, processID: Int32) {
        log("process exited with status \(status)")
        guard process?.processIdentifier == processID else { return }
        failAllPending(ClientError.processExited)
        stdoutReadTask?.cancel()
        stderrReadTask?.cancel()
        stdoutReadTask = nil
        stderrReadTask = nil
        process = nil
        processExitStream = nil
    }

    private func cancelPendingRequest(id: Int, error: Error) {
        guard let pendingRequest = pending.removeValue(forKey: id) else { return }
        pendingRequest.continuation.resume(throwing: error)
    }

    private func failAllPending(_ error: Error) {
        let pendingRequests = pending
        pending.removeAll()
        for (_, request) in pendingRequests {
            request.continuation.resume(throwing: error)
        }
    }

    private func log(_ message: String) {
        diagnostics.append(message)
        if diagnostics.count > 500 {
            diagnostics.removeFirst(diagnostics.count - 500)
        }
    }
}

struct PiCommand: Hashable, Sendable {
    var executable: String
    var arguments: [String]
    var environmentPath: String? = nil
}

struct RPCEnvelope: Codable, Identifiable, Hashable, Sendable {
    var id: Int?
    var type: String?
    var command: String?
    var success: Bool?
    var data: JSONValue?
    var error: JSONValue?
    var raw: [String: JSONValue]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        raw = try container.decode([String: JSONValue].self)
        if case .number(let value)? = raw["id"] {
            id = Int(value)
        }
        type = raw["type"]?.stringValue
        command = raw["command"]?.stringValue
        if case .bool(let value)? = raw["success"] {
            success = value
        }
        data = raw["data"]
        error = raw["error"]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    subscript(_ key: String) -> JSONValue? {
        raw[key]
    }
}

enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { value } else { nil }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { value } else { nil }
    }
}
