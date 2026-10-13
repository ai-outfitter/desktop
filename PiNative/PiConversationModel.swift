import Foundation
import SwiftUI

@MainActor
final class PiConversationModel: ObservableObject {
    @Published var items: [TranscriptItem] = [] {
        didSet { onItemsChanged?(items) }
    }
    @Published var draft = ""
    @Published var draftAttachments: [ComposerAttachment] = []
    @Published var isRunning = false
    @Published var runningStartedAt = Date()
    @Published var errorMessage: String?
    @Published var sessionLoadNotice: String?
    @Published var rpcStatusMessage: String?
    @Published var isCatastrophicRPCFailure = false
    @Published var isLoadingSession = false
    @Published var composerFocusRequest = UUID()
    @Published var currentModel: PiModelOption?
    @Published var availableModels: [PiModelOption] = []
    @Published var currentThinkingLevel: PiThinkingLevel?
    @Published var availableThinkingLevels: [PiThinkingLevel] = []
    @Published private(set) var pendingSteering: [SteeringMessage] = []

    var onSessionPathResolved: ((String) -> Void)?
    var onUserMessageSent: ((String) -> Void)?
    var onPromptSubmitted: (() -> Void)?
    var onPiLoadFailed: ((PiLoadFailure) -> Void)?
    var onHandledPiOperationFailure: ((HandledPiOperationFailure) -> Void)?
    var onInteractiveAttention: ((String) -> Void)?
    var onItemsChanged: (([TranscriptItem]) -> Void)?
    var onAgentSettled: (([TranscriptItem]) -> Void)?
    var onAgentRunAbandoned: (() -> Void)?

    private var client: PiRPCClient?
    private var assistantBufferID: UUID?
    /// The activity group currently accumulating tool calls for the in-
    /// progress turn, if any. Per implementation plan §D: this stays open
    /// across interleaved assistant text within the same turn and is only
    /// closed by `agent_end` or the next user message — not by every
    /// `tool_execution_end`.
    private var currentActivityGroupID: UUID?
    private var toolCallIDToGroupID: [String: UUID] = [:]
    private var currentSessionPath: String?
    private var currentWorkingDirectory: String?
    private var lastStartKey: ConversationStartKey?
    private var isSessionReady = false
    private var pendingPrompt: PendingPrompt?
    private var interactiveAttentionNotice: String?
    private var isPlanningMode = false
    private var activeLocalTurnID: UUID?
    private var isAwaitingInitialPromptUserEvent = false
    /// True after the user presses Stop until the next prompt starts. Pi may
    /// still emit a few late events while abort/termination races the active
    /// turn; suppress those so a stopped turn cannot keep appending output or
    /// flip the composer back into running state.
    private var isSuppressingStoppedTurnEvents = false
    private var mockResponse: String? {
#if DEBUG
        if let mockResponseOverrideForTesting { return mockResponseOverrideForTesting }
        if !usesMockResponseEnvironmentForTesting { return nil }
#endif
        return ProcessInfo.processInfo.environment["PI_NATIVE_MOCK_RPC_RESPONSE"]
    }
    private var mockResponseDelayNanoseconds: UInt64 {
        let milliseconds = UInt64(ProcessInfo.processInfo.environment["PI_NATIVE_MOCK_RPC_RESPONSE_DELAY_MS"] ?? "300") ?? 300
        return milliseconds * 1_000_000
    }
    private var shouldStallRPCForTesting: Bool {
#if DEBUG
        if let shouldStallRPCOverrideForTesting { return shouldStallRPCOverrideForTesting }
#endif
        return ProcessInfo.processInfo.environment["PI_NATIVE_TEST_RPC_STALL"] == "1"
    }
    private var shouldFailRPCForTesting: Bool {
#if DEBUG
        if let shouldFailRPCOverrideForTesting { return shouldFailRPCOverrideForTesting }
#endif
        return ProcessInfo.processInfo.environment["PI_NATIVE_TEST_RPC_CATASTROPHIC_FAILURE"] == "1"
    }
    private let piCommandOverride: PiCommand?
    private let modelSettings: ModelSettingsModel?
    private var pendingModelSelection: PiModelOption?
    private var modelBeforePendingSelection: PiModelOption?
    private var pendingThinkingLevelSelection: PiThinkingLevel?
    private var thinkingLevelBeforePendingSelection: PiThinkingLevel?
    private var selectionMutationTask: Task<Void, Never>?
    private var steeringSubmissionTask: Task<Void, Never>?
    private var steeringOperationGeneration = 0
    private var shouldReplaySteeringAfterStop = false
    /// Holds process startup while Stop clears server-side queued input,
    /// aborts the turn, and fully terminates the old RPC process.
    private var isRestartingAfterStop = false
#if DEBUG
    var shouldStallRPCOverrideForTesting: Bool?
    var shouldFailRPCOverrideForTesting: Bool?
    var mockResponseOverrideForTesting: String?
    var usesMockResponseEnvironmentForTesting = true
    var onSteeringRPCForTesting: ((String) -> Void)?
    var onPromptRPCForTesting: ((String) -> Void)?
    var onAbortRPCForTesting: (() -> Void)?
    var onStopCompletionForTesting: (() -> Void)?
    var onRPCEventReceivedForTesting: ((RPCEnvelope, Bool) -> Void)?
#endif
    private static let defaultThinkingLevels: [PiThinkingLevel] = [.low, .medium, .high]

    init(piCommand: PiCommand? = nil, modelSettings: ModelSettingsModel? = nil) {
        self.piCommandOverride = piCommand
        self.modelSettings = modelSettings
        self.currentModel = modelSettings?.preferredConversationModel
        if let testLevels = ProcessInfo.processInfo.environment["PI_NATIVE_TEST_THINKING_LEVELS"] {
            availableThinkingLevels = testLevels.split(separator: ",").compactMap { PiThinkingLevel(rawValue: String($0)) }
            hydrateThinkingLevelIfPossible()
        }
    }

    var blocksConversationSelection: Bool {
        isRunning || pendingPrompt != nil
    }

    var hasPendingPrompt: Bool { pendingPrompt != nil }
    var isProcessStarted: Bool { client != nil || mockResponse != nil }

    var promptHistory: [ComposerPromptHistoryEntry] {
        items.compactMap { item in
            guard case .user(let id, let payload) = item else { return nil }
            return ComposerPromptHistoryEntry(id: id, payload: payload)
        }
    }

    private static func displayableCachedItems(from items: [TranscriptItem]) -> [TranscriptItem] {
        items.filter { item in
            guard case .notice(_, let text) = item else { return true }
            return !text.hasPrefix("Failed to load session:")
                && !text.hasPrefix("Failed to start pi:")
                && !text.hasPrefix("Failed to start pi RPC:")
                && text != "Pi requested unsupported UI interaction: setTitle."
        }
    }

    /// Bumped on every session-switch request; async work (session hydration,
    /// startup failure handling) checks this before mutating `items` so a
    /// slow/stale request can't clobber a newer selection's state. Found by
    /// adversarial review — rapid session switching could otherwise hydrate
    /// the wrong transcript.
    private var sessionGeneration = 0
    private var processGeneration = 0
    private var agentActivityRevision = 0
    private var awaitingLegacySettlement = false

    func configureSession(workingDirectory: String?, sessionPath: String?, initialPrompt: PreparedPrompt? = nil, cachedItems: [TranscriptItem] = [], planningMode: Bool = false) {
        let previousSessionPath = currentSessionPath
        currentWorkingDirectory = workingDirectory
        currentSessionPath = sessionPath
        isPlanningMode = planningMode
        sessionLoadNotice = nil
        rpcStatusMessage = nil
        interactiveAttentionNotice = nil
        isCatastrophicRPCFailure = false
        isSessionReady = true
        isLoadingSession = false
        composerFocusRequest = UUID()
        let displayableCachedItems = Self.displayableCachedItems(from: cachedItems)
        if !displayableCachedItems.isEmpty || items.isEmpty || previousSessionPath != sessionPath {
            items = displayableCachedItems
        }
        if let initialPrompt, !initialPrompt.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingPrompt = PendingPrompt(prepared: initialPrompt, shouldAppendUserMessage: true)
        }
    }

    func startProcessIfNeeded() {
        guard !isRestartingAfterStop else { return }
        guard client == nil || mockResponse != nil else {
            if isSessionReady {
                flushPendingPromptIfNeeded()
            }
            return
        }
        start(
            workingDirectory: currentWorkingDirectory,
            sessionPath: currentSessionPath,
            initialPrompt: nil,
            cachedItems: items,
            planningMode: isPlanningMode
        )
    }

    func start(workingDirectory: String?, sessionPath: String?, initialPrompt: PreparedPrompt? = nil, cachedItems: [TranscriptItem] = [], planningMode: Bool = false) {
        let startKey = ConversationStartKey(workingDirectory: workingDirectory, sessionPath: sessionPath, planningMode: planningMode)
        if lastStartKey == startKey, isSessionReady, pendingPrompt == nil, client != nil || mockResponse != nil {
            let displayableCachedItems = Self.displayableCachedItems(from: cachedItems)
            if !displayableCachedItems.isEmpty, displayableCachedItems != items {
                items = displayableCachedItems
                composerFocusRequest = UUID()
            }
            return
        }
        let previousSessionPath = currentSessionPath
        lastStartKey = startKey
        currentSessionPath = sessionPath
        isPlanningMode = planningMode
        sessionGeneration += 1
        let generation = sessionGeneration
        isSessionReady = false
        sessionLoadNotice = nil
        rpcStatusMessage = nil
        interactiveAttentionNotice = nil
        isCatastrophicRPCFailure = false
        isLoadingSession = true
        composerFocusRequest = UUID()
        let displayableCachedItems = Self.displayableCachedItems(from: cachedItems)
        if !displayableCachedItems.isEmpty || items.isEmpty || previousSessionPath != sessionPath {
            items = displayableCachedItems
        }
        if let initialPrompt, !initialPrompt.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingPrompt = PendingPrompt(prepared: initialPrompt, shouldAppendUserMessage: true)
        } else if initialPrompt != nil {
            pendingPrompt = nil
        }

        if mockResponse != nil {
            currentWorkingDirectory = workingDirectory
            isSessionReady = true
            isLoadingSession = false
            rpcStatusMessage = nil
            if cachedItems.isEmpty {
                items = []
            }
            if currentModel == nil {
                let mockModel = PiModelOption(provider: "mock", id: "mock", name: "Mock Model")
                currentModel = mockModel
                availableModels = [mockModel]
            }
            if availableThinkingLevels.isEmpty,
               ProcessInfo.processInfo.environment["PI_NATIVE_TEST_THINKING_LEVELS"] == nil {
                currentThinkingLevel = .medium
                availableThinkingLevels = [.low, .medium, .high]
            }
            flushPendingPromptIfNeeded()
            return
        }


        if shouldStallRPCForTesting {
            currentWorkingDirectory = workingDirectory
            return
        }

        if shouldFailRPCForTesting {
            currentWorkingDirectory = workingDirectory
            pendingPrompt = nil
            onAgentRunAbandoned?()
            isRunning = false
            isLoadingSession = false
            reportPiLoadFailure(stage: .sessionLoad, error: PiRPCClient.ClientError.processExited)
            let notice = "Failed to load session: pi process exited unexpectedly."
            sessionLoadNotice = notice
            rpcStatusMessage = notice
            isCatastrophicRPCFailure = true
            return
        }

        if client != nil {
            if workingDirectory != currentWorkingDirectory {
                // The project changed under an existing client. This is
                // unreachable in the current single-project UI, but a client
                // is scoped to one working directory server-side, so honor a
                // change if one ever occurs rather than silently keep
                // talking to the old directory.
                stop()
            } else {
                Task { await switchToSession(sessionPath, generation: generation) }
                return
            }
        }

        currentWorkingDirectory = workingDirectory
        let directory = URL(fileURLWithPath: workingDirectory ?? FileManager.default.currentDirectoryPath)
        let client = PiRPCClient(piCommand: piCommandOverride, workingDirectory: directory, disablesTools: planningMode)
        self.client = client
        let processGeneration = self.processGeneration

        Task {
            await client.setOnEvent { [weak self, processGeneration] event in
                await self?.handle(event, processGeneration: processGeneration)
            }
            do {
                try await client.start()
                await self.switchToSession(sessionPath, generation: generation)
            } catch {
                guard generation == self.sessionGeneration, processGeneration == self.processGeneration else { return }
                // Don't leave a dead-but-non-nil client behind: a later call
                // would see `client != nil` and try to switch sessions on a
                // client that never started, instead of retrying start().
                self.client = nil
                self.pendingPrompt = nil
                self.onAgentRunAbandoned?()
                self.isRunning = false
                self.isLoadingSession = false
                self.errorMessage = error.localizedDescription
                self.reportPiLoadFailure(stage: .processStart, error: error)
                let notice = self.rpcFailureNotice("Failed to start pi", error: error)
                self.failReplayingSteeringIfNeeded(notice)
                self.sessionLoadNotice = notice
                self.rpcStatusMessage = notice
                self.isCatastrophicRPCFailure = true
            }
        }
    }

    func updateSessionPath(_ sessionPath: String?) {
        guard sessionPath != currentSessionPath else { return }
        currentSessionPath = sessionPath
        sessionLoadNotice = nil
        rpcStatusMessage = nil
        interactiveAttentionNotice = nil
        isCatastrophicRPCFailure = false
        isSessionReady = false
        isLoadingSession = true
        composerFocusRequest = UUID()
        sessionGeneration += 1
        let generation = sessionGeneration
        Task { await switchToSession(sessionPath, generation: generation) }
    }

    func stop() {
        let oldClient = detachClientForStop()
        // Capture the client into a local before clearing the property —
        // `client?.stop()` inside the Task would otherwise always read `nil`,
        // since the synchronous assignment above runs before the Task body
        // gets a chance to execute.
        Task { await oldClient?.stop() }
    }

    private func detachClientForStop() -> PiRPCClient? {
        steeringOperationGeneration += 1
        steeringSubmissionTask?.cancel()
        steeringSubmissionTask = nil
        let oldClient = client
        client = nil
        processGeneration += 1
        lastStartKey = nil
        pendingPrompt = nil
        isRunning = false
        isRestartingAfterStop = false
        return oldClient
    }

#if DEBUG
    func selectedRuntimeModelForTesting() async throws -> PiModelOption? {
        await selectionMutationTask?.value
        guard let client else { throw PiRPCClient.ClientError.processNotRunning }
        let state = try await client.getState()
        return PiModelOption(json: state.data?.objectValue?["model"])
    }

    func stopAndWaitForTesting() async {
        let oldClient = detachClientForStop()
        await oldClient?.stop()
    }
#endif

    private var canSubmitWithSelection: Bool { currentModel != nil && currentThinkingLevel != nil }

    func sendDraft() {
        guard canSubmitWithSelection else { return }
        guard let prepared = PromptAttachmentAssembler.prepare(draft: draft, attachments: draftAttachments) else { return }
        let submittedDraft = draft
        let submittedAttachments = draftAttachments
        draft = ""
        draftAttachments = []
        onPromptSubmitted?()
        if isRunning {
            queueSteering(prepared, composerText: submittedDraft, composerAttachments: submittedAttachments)
            return
        }
        guard isSessionReady, client != nil || mockResponse != nil else {
            pendingPrompt = PendingPrompt(prepared: prepared, shouldAppendUserMessage: false)
            appendUserMessage(for: prepared)
            startProcessIfNeeded()
            return
        }
        send(prepared, shouldAppendUserMessage: true)
    }

    func addDraftAttachments(_ attachments: [ComposerAttachment]) {
        guard !attachments.isEmpty else { return }
        var combined = draftAttachments
        for attachment in attachments {
            if case .fileReference(let file) = attachment.kind,
               combined.contains(where: { existing in
                   if case .fileReference(let existingFile) = existing.kind {
                       return existingFile.url.standardizedFileURL.path == file.url.standardizedFileURL.path
                   }
                   return false
               }) {
                continue
            }
            combined.append(attachment)
        }
        draftAttachments = combined
    }

    func removeDraftAttachment(_ id: ComposerAttachment.ID) {
        draftAttachments.removeAll { $0.id == id }
    }

    func retrySteering(_ id: UUID) {
        guard let index = pendingSteering.firstIndex(where: { $0.id == id }),
              pendingSteering[index].state == .failed
        else { return }
        if isRunning {
            pendingSteering[index].state = .submitting
            scheduleSteeringSubmission()
        } else {
            pendingSteering[index].state = .replaying
            shouldReplaySteeringAfterStop = true
            if !isSessionReady, client == nil, mockResponse == nil {
                shouldReplaySteeringAfterStop = false
                failPendingSteeringReplay("Couldn’t resume steering after Stop: pi is not running.")
                return
            }
            replaySteeringAfterStopIfNeeded()
        }
    }

    /// Interrupts the active turn from the user's perspective immediately,
    /// then clears queued server input, aborts the turn, and performs process
    /// recovery. Stop and Escape both enter through this method so their
    /// lifecycle cannot diverge.
    @discardableResult
    func interruptActiveTurn() -> Bool {
        guard isRunning || pendingPrompt != nil else { return false }
        steeringOperationGeneration += 1
        steeringSubmissionTask?.cancel()
        steeringSubmissionTask = nil
        shouldReplaySteeringAfterStop = !pendingSteering.isEmpty
        for index in pendingSteering.indices {
            pendingSteering[index].state = .replaying
        }
        pendingPrompt = nil
        isRunning = false
        activeLocalTurnID = nil
        isAwaitingInitialPromptUserEvent = false
        isSuppressingStoppedTurnEvents = true
        onAgentRunAbandoned?()
        assistantBufferID = nil
        closeCurrentActivityGroup()
        items.append(.notice(TranscriptItem.interruptionNoticeText))
        composerFocusRequest = UUID()

        let clientToAbort = client
#if DEBUG
        onAbortRPCForTesting?()
#endif

        if mockResponse == nil {
            client = nil
            isSessionReady = false
            isRestartingAfterStop = clientToAbort != nil
            processGeneration += 1
            lastStartKey = nil
        }
        let interruptedGeneration = processGeneration
        let workingDirectory = currentWorkingDirectory
        let sessionPath = currentSessionPath
        let cachedItems = items
        let planningMode = isPlanningMode
        Task {
            if let clientToAbort {
                // Pi continues accepted queue entries after interruption unless
                // they are cleared first. Keep the local queue as the replay
                // source of truth, then wait for full process termination before
                // a replacement can start.
                let queueWasCleared = (try? await clientToAbort.clearQueue(timeoutSeconds: 1.25)) != nil
                if queueWasCleared {
                    _ = try? await clientToAbort.abort(timeoutSeconds: 1.25)
                }
                await clientToAbort.stop()
            }
            await MainActor.run {
                self.isRestartingAfterStop = false
#if DEBUG
                self.onStopCompletionForTesting?()
#endif
                if self.mockResponse != nil {
                    self.isSuppressingStoppedTurnEvents = false
                    self.replaySteeringAfterStopIfNeeded()
                    return
                }
                guard clientToAbort != nil else {
                    self.failReplayingSteeringIfNeeded("Couldn’t resume steering after Stop: pi is not running.")
                    return
                }
                guard self.processGeneration == interruptedGeneration, self.client == nil else { return }
                self.start(
                    workingDirectory: workingDirectory,
                    sessionPath: sessionPath,
                    cachedItems: cachedItems,
                    planningMode: planningMode
                )
                self.replaySteeringAfterStopIfNeeded()
            }
        }
        return true
    }

    /// Compatibility entry point for existing lifecycle tests. Product Stop
    /// and Escape actions use `interruptActiveTurn()` directly.
    func stopActiveTurn() {
        _ = interruptActiveTurn()
    }

    /// Copies the given assistant message text to the clipboard. Wired for
    /// real (per implementation plan Phase 3 step 2 — unlike the other
    /// per-message action icons, which are visual-only this milestone).
    func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func switchToSession(_ sessionPath: String?, generation: Int, hasRetriedAfterRestart: Bool = false) async {
        let requestProcessGeneration = processGeneration
        guard let client else {
            if generation == sessionGeneration { isLoadingSession = false }
            return
        }
        assistantBufferID = nil
        currentActivityGroupID = nil
        toolCallIDToGroupID.removeAll()

        do {
            if let sessionPath, !sessionPath.isEmpty {
                _ = try await client.switchSession(sessionPath)
                let messages = try await client.getMessages()
                // A newer switch/start request may have begun (and possibly
                // already finished) while these two awaits were in flight;
                // if so, this response is stale and must not clobber
                // whatever the newer request already wrote to `items`.
                guard generation == sessionGeneration, requestProcessGeneration == processGeneration else { return }
                let pendingUserMessage = pendingPrompt?.shouldAppendUserMessage == false ? pendingPrompt?.prepared.summaryText : nil
                hydrateTranscript(from: messages)
                if let pendingUserMessage, !containsUserMessage(pendingUserMessage) {
                    items.append(.user(UserMessagePayload(text: pendingUserMessage)))
                }
            } else {
                _ = try await client.newSession()
                let state = try await client.getState()
                let resolvedSessionPath = state.data?.objectValue?["sessionFile"]?.stringValue
                guard generation == sessionGeneration, requestProcessGeneration == processGeneration else { return }
                if let resolvedSessionPath, !resolvedSessionPath.isEmpty {
                    currentSessionPath = resolvedSessionPath
                    onSessionPathResolved?(resolvedSessionPath)
                }
                if items.isEmpty {
                    items = []
                }
            }
            await applyPendingSelections(using: client, processGeneration: requestProcessGeneration)
            guard generation == sessionGeneration, requestProcessGeneration == processGeneration else { return }
            isSessionReady = true
            isLoadingSession = false
            sessionLoadNotice = nil
            rpcStatusMessage = nil
            restoreInteractiveAttentionNoticeIfNeeded()
            isCatastrophicRPCFailure = false
            flushPendingPromptIfNeeded()
            replaySteeringAfterStopIfNeeded()
        } catch {
            guard generation == sessionGeneration, requestProcessGeneration == processGeneration else { return }
            if !hasRetriedAfterRestart, shouldRestartClient(after: error) {
                await restartClientAndSwitchToSession(sessionPath, generation: generation)
                return
            }
            pendingPrompt = nil
            onAgentRunAbandoned?()
            isRunning = false
            isSessionReady = false
            isLoadingSession = false
            reportPiLoadFailure(stage: .sessionLoad, error: error)
            let notice = rpcFailureNotice("Failed to load session", error: error)
            failReplayingSteeringIfNeeded(notice)
            sessionLoadNotice = notice
            rpcStatusMessage = notice
            isCatastrophicRPCFailure = true
        }
        // Best-effort either way: the model list isn't session-dependent, so
        // a failed/slow session load shouldn't leave the picker empty.
        await refreshModelState(using: client)
        guard generation == sessionGeneration, requestProcessGeneration == processGeneration, self.client === client else { return }
        flushPendingPromptIfNeeded()
    }

    private func shouldRestartClient(after error: Error) -> Bool {
        guard let clientError = error as? PiRPCClient.ClientError else { return false }
        switch clientError {
        case .processExited, .processNotRunning:
            return true
        default:
            return false
        }
    }

    private func restartClientAndSwitchToSession(_ sessionPath: String?, generation: Int) async {
        let oldClient = client
        client = nil
        processGeneration += 1
        let replacementProcessGeneration = processGeneration
        await oldClient?.stop()

        guard generation == sessionGeneration, replacementProcessGeneration == processGeneration else { return }
        let directory = URL(fileURLWithPath: currentWorkingDirectory ?? FileManager.default.currentDirectoryPath)
        let replacementClient = PiRPCClient(piCommand: piCommandOverride, workingDirectory: directory, disablesTools: isPlanningMode)
        client = replacementClient
        await replacementClient.setOnEvent { [weak self, replacementProcessGeneration] event in
            await self?.handle(event, processGeneration: replacementProcessGeneration)
        }

        do {
            try await replacementClient.start()
            await switchToSession(sessionPath, generation: generation, hasRetriedAfterRestart: true)
        } catch {
            guard generation == sessionGeneration, replacementProcessGeneration == processGeneration else { return }
            client = nil
            pendingPrompt = nil
            onAgentRunAbandoned?()
            isRunning = false
            isSessionReady = false
            isLoadingSession = false
            reportPiLoadFailure(stage: .sessionLoad, error: error)
            let notice = rpcFailureNotice("Failed to load session", error: error)
            failReplayingSteeringIfNeeded(notice)
            sessionLoadNotice = notice
            rpcStatusMessage = notice
            isCatastrophicRPCFailure = true
        }
    }

    private func reportPiLoadFailure(stage: PiLoadFailureStage, error: Error) {
        onPiLoadFailed?(PiLoadFailure(stage: stage, error: error))
    }

    private func reportHandledPiOperationFailure(area: PiOperationArea, error: Error) {
        onHandledPiOperationFailure?(HandledPiOperationFailure(area: area, error: error))
    }

    private func rpcFailureNotice(_ prefix: String, error: Error) -> String {
        "\(prefix): \(Self.userVisibleErrorMessage(error.localizedDescription))"
    }

    private static func userVisibleErrorMessage(_ message: String) -> String {
        message
            .replacingOccurrences(of: "Pi RPC", with: "pi")
            .replacingOccurrences(of: "pi RPC", with: "pi")
            .replacingOccurrences(of: "RPC", with: "pi")
            .replacingOccurrences(of: "Pi rpc", with: "pi")
            .replacingOccurrences(of: "pi rpc", with: "pi")
            .replacingOccurrences(of: "rpc", with: "pi")
    }

    /// Loads the current model and the full available-model list from pi.
    /// Best-effort: a failure here just leaves the picker showing its
    /// previous state (or a generic "Model" label) rather than surfacing an
    /// error into the transcript.
    private func refreshModelState(using expectedClient: PiRPCClient? = nil) async {
        guard let client = expectedClient ?? self.client, self.client === client else { return }
        if let state = try? await client.getState() {
            guard self.client === client else { return }
            let data = state.data?.objectValue
            if let model = PiModelOption(json: data?["model"]) {
                currentModel = model
            }
            currentThinkingLevel = data?["thinkingLevel"]?.stringValue.flatMap(PiThinkingLevel.init(rawValue:))
        }
        if let modelSettings {
            await modelSettings.refreshCatalogIfNeeded(using: client)
            guard self.client === client else { return }
            availableModels = modelSettings.catalog
        } else if let response = try? await client.getAvailableModels() {
            guard self.client === client else { return }
            if let models = response.data?.objectValue?["models"]?.arrayValue {
                let parsedModels = models.compactMap { PiModelOption(json: $0) }
                if !parsedModels.isEmpty { availableModels = parsedModels }
            }
        }
        if let currentModel,
           let hydratedModel = availableModels.first(where: { $0.stableID == currentModel.stableID }) {
            self.currentModel = hydratedModel
        } else if currentModel == nil,
                  let preferredModel = modelSettings?.preferredConversationModel {
            self.currentModel = preferredModel
        }
        if currentModel == nil, availableModels.isEmpty, pendingPrompt != nil {
            if draft.isEmpty, let prepared = pendingPrompt?.prepared {
                draft = prepared.message
                draftAttachments = prepared.displayAttachments
            }
            pendingPrompt = nil
            onAgentRunAbandoned?()
            sessionLoadNotice = "Connect Outfitter in Settings → Models before sending a message."
        }
        if let response = try? await client.getAvailableThinkingLevels() {
            guard self.client === client else { return }
            let levels = response.data?.objectValue?["levels"]?.arrayValue ?? []
            availableThinkingLevels = levels.compactMap { $0.stringValue.flatMap(PiThinkingLevel.init(rawValue:)) }
            hydrateThinkingLevelIfPossible()
        } else {
            guard self.client === client else { return }
            availableThinkingLevels = []
            if currentModel == nil { currentThinkingLevel = nil }
        }
    }

    private func hydrateThinkingLevelIfPossible() {
        guard canSubmitWithSelection else {
            currentThinkingLevel = nil
            return
        }
        guard currentThinkingLevel == nil else { return }
        currentThinkingLevel = availableThinkingLevels.contains(.medium) ? .medium : availableThinkingLevels.first
    }

    /// Switches pi to the given model via the real `set_model` RPC command.
    func selectModel(_ option: PiModelOption) {
        guard option != currentModel else { return }
        if mockResponse != nil {
            currentModel = option
            hydrateThinkingLevelIfPossible()
            return
        }
        if pendingModelSelection == nil {
            modelBeforePendingSelection = currentModel
        }
        pendingModelSelection = option
        currentModel = option
        hydrateThinkingLevelIfPossible()
        applyPendingSelectionsOrStartProcess()
    }

    /// Switches pi to the given thinking/effort level via the real RPC command.
    func selectThinkingLevel(_ level: PiThinkingLevel) {
        guard level != currentThinkingLevel else { return }
        if mockResponse != nil {
            currentThinkingLevel = level
            return
        }
        if pendingThinkingLevelSelection == nil {
            thinkingLevelBeforePendingSelection = currentThinkingLevel
        }
        pendingThinkingLevelSelection = level
        currentThinkingLevel = level
        applyPendingSelectionsOrStartProcess()
    }

    private func applyPendingSelectionsOrStartProcess() {
        guard let client, isSessionReady else {
            startProcessIfNeeded()
            return
        }
        guard selectionMutationTask == nil else { return }
        let selectionProcessGeneration = processGeneration
        selectionMutationTask = Task {
            await applyPendingSelections(using: client, processGeneration: selectionProcessGeneration)
            selectionMutationTask = nil
            if pendingModelSelection != nil || pendingThinkingLevelSelection != nil {
                applyPendingSelectionsOrStartProcess()
            } else {
                await refreshModelState()
                flushPendingPromptIfNeeded()
            }
        }
    }

    private func applyPendingSelections(using client: PiRPCClient, processGeneration: Int) async {
        while pendingModelSelection != nil || pendingThinkingLevelSelection != nil {
            guard processGeneration == self.processGeneration else { return }
            if let desiredModel = pendingModelSelection {
                let previousModel = modelBeforePendingSelection
                do {
                    _ = try await client.setModel(provider: desiredModel.provider, modelId: desiredModel.id)
                    if pendingModelSelection == desiredModel {
                        pendingModelSelection = nil
                        modelBeforePendingSelection = nil
                    } else {
                        modelBeforePendingSelection = desiredModel
                    }
                } catch {
                    guard processGeneration == self.processGeneration else { return }
                    if pendingModelSelection == desiredModel {
                        pendingModelSelection = nil
                        modelBeforePendingSelection = nil
                        currentModel = previousModel
                        reportHandledPiOperationFailure(area: .modelSelection, error: error)
                        items.append(.notice("Couldn’t switch model: \(Self.userVisibleErrorMessage(error.localizedDescription))"))
                    }
                }
            }

            if let desiredLevel = pendingThinkingLevelSelection {
                let previousLevel = thinkingLevelBeforePendingSelection
                do {
                    _ = try await client.setThinkingLevel(desiredLevel.rawValue)
                    if pendingThinkingLevelSelection == desiredLevel {
                        pendingThinkingLevelSelection = nil
                        thinkingLevelBeforePendingSelection = nil
                    } else {
                        thinkingLevelBeforePendingSelection = desiredLevel
                    }
                } catch {
                    guard processGeneration == self.processGeneration else { return }
                    if pendingThinkingLevelSelection == desiredLevel {
                        pendingThinkingLevelSelection = nil
                        thinkingLevelBeforePendingSelection = nil
                        currentThinkingLevel = previousLevel
                        reportHandledPiOperationFailure(area: .effortSelection, error: error)
                        items.append(.notice("Couldn’t switch effort: \(Self.userVisibleErrorMessage(error.localizedDescription))"))
                    }
                }
            }
        }
    }

    private func flushPendingPromptIfNeeded() {
        guard canSubmitWithSelection, let pendingPrompt else { return }
        self.pendingPrompt = nil
        send(pendingPrompt.prepared, shouldAppendUserMessage: pendingPrompt.shouldAppendUserMessage)
    }

    private func appendUserMessage(for prepared: PreparedPrompt) {
        items.append(.user(UserMessagePayload(text: prepared.summaryText, attachments: prepared.displayAttachments)))
        onUserMessageSent?(prepared.summaryText)
    }

    private func queueSteering(_ prepared: PreparedPrompt, composerText: String, composerAttachments: [ComposerAttachment]) {
        let message = SteeringMessage(
            prepared: prepared,
            composerText: composerText,
            composerAttachments: composerAttachments,
            state: .submitting
        )
        pendingSteering.append(message)

        if mockResponse != nil {
            setSteeringState(id: message.id, state: .accepted)
        } else {
            scheduleSteeringSubmission()
        }
    }

    /// Serializes steer RPC calls so rapid Return presses reach Pi in the same
    /// order as the visible inline queue.
    private func scheduleSteeringSubmission() {
        guard steeringSubmissionTask == nil else { return }
        let generation = steeringOperationGeneration
        steeringSubmissionTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  generation == self.steeringOperationGeneration,
                  let next = self.pendingSteering.first(where: { $0.state == .submitting }) {
                do {
#if DEBUG
                    self.onSteeringRPCForTesting?(next.prepared.summaryText)
#endif
                    guard let client = self.client else { throw PiRPCClient.ClientError.processNotRunning }
                    _ = try await client.steer(self.promptMessage(for: next.prepared), images: next.prepared.images)
                    guard generation == self.steeringOperationGeneration else { break }
                    self.setSteeringState(id: next.id, state: .accepted)
                } catch is CancellationError {
                    break
                } catch {
                    guard generation == self.steeringOperationGeneration else { break }
                    self.rejectSteering(id: next.id, error: error)
                }
            }
            guard generation == self.steeringOperationGeneration else { return }
            self.steeringSubmissionTask = nil
        }
    }

    private func setSteeringState(id: UUID, state: SteeringMessage.State) {
        guard let index = pendingSteering.firstIndex(where: { $0.id == id }) else { return }
        pendingSteering[index].state = state
    }

    private func rejectSteering(id: UUID, error: Error) {
        guard let index = pendingSteering.firstIndex(where: { $0.id == id }) else { return }
        let rejected = pendingSteering.remove(at: index)
        let currentDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let rejectedDraft = rejected.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = [rejectedDraft, currentDraft].filter { !$0.isEmpty }.joined(separator: "\n\n")
        addDraftAttachments(rejected.composerAttachments)
        let notice = rpcFailureNotice("Couldn’t queue steering", error: error)
        errorMessage = error.localizedDescription
        items.append(.notice(notice))
    }

    private func consumeDeliveredSteeringIfPresent() {
        guard !pendingSteering.isEmpty else { return }
        let delivered = pendingSteering.removeFirst()
        closeCurrentActivityGroup()
        appendUserMessage(for: delivered.prepared)
    }

    private func send(_ prepared: PreparedPrompt?, shouldAppendUserMessage: Bool) {
        guard canSubmitWithSelection, let prepared else { return }
        if client == nil, mockResponse == nil {
            pendingPrompt = PendingPrompt(prepared: prepared, shouldAppendUserMessage: shouldAppendUserMessage)
            startProcessIfNeeded()
            return
        }
        closeCurrentActivityGroup()
        if shouldAppendUserMessage {
            appendUserMessage(for: prepared)
        }
        runningStartedAt = Date()
        isRunning = true
        isAwaitingInitialPromptUserEvent = true
        let localTurnID = UUID()
        activeLocalTurnID = localTurnID

        if let mockResponse {
            let response = mockResponse
            let delay = mockResponseDelayNanoseconds
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: delay)
                guard self.isRunning, self.activeLocalTurnID == localTurnID else { return }
                self.isSuppressingStoppedTurnEvents = false
                self.items.append(.assistantText(text: response))
                self.isRunning = false
                self.activeLocalTurnID = nil
                self.onAgentSettled?(self.items)
            }
            return
        }

        guard let client else { return }
        let requestProcessGeneration = processGeneration
        Task {
            do {
                _ = try await client.prompt(self.promptMessage(for: prepared), images: prepared.images)
            } catch {
                let notice = self.rpcFailureNotice("Prompt failed", error: error)
                await MainActor.run {
                    guard requestProcessGeneration == self.processGeneration else { return }
                    self.errorMessage = error.localizedDescription
                    self.reportHandledPiOperationFailure(area: .promptSubmission, error: error)
                    self.items.append(.notice(notice))
                    self.onAgentRunAbandoned?()
                    self.isRunning = false
                    self.activeLocalTurnID = nil
                }
            }
        }
    }

    private func promptMessage(for prepared: PreparedPrompt) -> String {
        guard isPlanningMode else { return prepared.message }
        return """
        You are in PiNative planning mode for a projectless Quick Chat. Do not create, edit, delete, or run files or commands. Help the user explore and refine the product/project idea. If implementation is needed, explain that the chat should be promoted to a project first.

        User message:
        \(prepared.message)
        """
    }

    private func containsUserMessage(_ text: String) -> Bool {
        items.contains { item in
            if case .user(_, let payload) = item {
                return payload.text == text
            }
            return false
        }
    }

    private func hydrateTranscript(from envelope: RPCEnvelope) {
        guard let messages = envelope.data?.objectValue?["messages"]?.arrayValue else {
            if !items.contains(where: Self.isInterruptionItem) {
                items = [.notice("No messages in this session yet.")]
            }
            return
        }

        let hydrated = Self.buildTranscript(from: messages)
        let baseItems = hydrated.isEmpty ? [.notice("No messages in this session yet.")] : hydrated
        items = transcriptPreservingLatestInterruption(from: baseItems)
    }

    /// Pi's message history cannot contain app-local interruption markers and
    /// may include output persisted after an abort raced the interrupted turn.
    /// Keep the cached transcript through the latest interruption authoritative,
    /// then accept hydrated content only from the next user turn onward.
    private func transcriptPreservingLatestInterruption(from hydrated: [TranscriptItem]) -> [TranscriptItem] {
        guard let interruptionIndex = items.lastIndex(where: Self.isInterruptionItem) else {
            return hydrated
        }
        let cachedItems = items
        let cachedPrefix = Array(cachedItems[...interruptionIndex])
        let interruptedUserTurnCount = cachedPrefix.reduce(into: 0) { count, item in
            if case .user = item { count += 1 }
        }

        var hydratedUserTurnCount = 0
        let laterTurnIndex = hydrated.firstIndex { item in
            guard case .user = item else { return false }
            hydratedUserTurnCount += 1
            return hydratedUserTurnCount > interruptedUserTurnCount
        }
        guard let laterTurnIndex else {
            // Hydration has not caught up to any locally cached later turn.
            // Retaining the cache avoids both losing that work and admitting
            // uncertain output from the interrupted turn.
            return cachedItems
        }
        return cachedPrefix + Array(hydrated[laterTurnIndex...])
    }

    private static func isInterruptionItem(_ item: TranscriptItem) -> Bool {
        item.isInterruptionNotice
    }

    /// Stateful reducer over the full message history — not a per-message
    /// `flatMap`. Saved sessions store a `toolCall`'s arguments inside the
    /// assistant message's `content` array, but the matching `toolResult`
    /// (output only) arrives as a separate, later top-level message, so
    /// reconciling them by `callID` requires carrying state across messages.
    /// See implementation plan §D.
    private static func buildTranscript(from messages: [JSONValue]) -> [TranscriptItem] {
        // First pass: every toolResult, keyed by callID, regardless of where
        // it falls relative to its toolCall.
        var resultsByCallID: [String: (output: String, isError: Bool)] = [:]
        for value in messages {
            guard let message = value.objectValue, message["role"]?.stringValue == "toolResult" else { continue }
            let callID = message["toolCallId"]?.stringValue ?? ""
            resultsByCallID[callID] = (
                message["content"]?.toolTextContent ?? "",
                message["isError"]?.boolValue ?? false
            )
        }

        var items: [TranscriptItem] = []
        // The one open activity group for the turn currently being replayed.
        // Only a "user" message closes it — interleaved assistant text within
        // the same turn does not, matching the live-event grouping rule.
        var openGroupID: UUID?

        for value in messages {
            guard let message = value.objectValue, let role = message["role"]?.stringValue else { continue }

            switch role {
            case "user":
                openGroupID = nil
                if let payload = userPayload(from: message["content"]) {
                    items.append(.user(payload))
                }

            case "assistant":
                for block in message["content"]?.arrayValue ?? [] {
                    guard let object = block.objectValue, let type = object["type"]?.stringValue else { continue }
                    switch type {
                    case "text":
                        if let text = object["text"]?.stringValue, !text.isEmpty {
                            items.append(.assistantText(text: text))
                        }
                    case "toolCall":
                        let callID = object["id"]?.stringValue ?? UUID().uuidString
                        let name = object["name"]?.stringValue ?? "tool"
                        let args = object["arguments"]?.prettyPrinted ?? ""
                        let result = resultsByCallID[callID]
                        let tool = ToolTranscriptItem(
                            id: UUID(),
                            callID: callID,
                            name: name,
                            args: args,
                            output: result?.output ?? "No result recorded (session may have been interrupted).",
                            status: result == nil ? .failed : (result!.isError ? .failed : .succeeded)
                        )

                        if let openGroupID, let index = items.firstIndex(where: { $0.id == openGroupID }), case .activity(var group) = items[index] {
                            group.tools.append(tool)
                            items[index] = .activity(group)
                        } else {
                            let groupID = UUID()
                            let group = ActivityGroup(id: groupID, tools: [tool], isRunning: false, startedAt: .distantPast, finishedAt: .distantPast)
                            items.append(.activity(group))
                            openGroupID = groupID
                        }
                    default:
                        break
                    }
                }

            default:
                break
            }
        }

        return items
    }

    private static func userPayload(from value: JSONValue?) -> UserMessagePayload? {
        if let text = value?.stringValue { return UserMessagePayload(text: text) }
        guard let blocks = value?.arrayValue else { return nil }
        var textBlocks: [String] = []
        var attachments: [ComposerAttachment] = []
        for block in blocks {
            guard let object = block.objectValue else { continue }
            switch object["type"]?.stringValue {
            case "text":
                if let text = object["text"]?.stringValue, !text.isEmpty { textBlocks.append(text) }
            case "image":
                guard let dataString = object["data"]?.stringValue,
                      let data = Data(base64Encoded: dataString)
                else { continue }
                let mimeType = object["mimeType"]?.stringValue ?? "image/png"
                let pixelSize = NSImage(data: data)?.pixelSize
                attachments.append(ComposerAttachment(kind: .image(ImageAttachment(
                    data: data,
                    mimeType: mimeType,
                    displayName: "Image",
                    sourceURL: nil,
                    pixelWidth: pixelSize.map { Double($0.width) },
                    pixelHeight: pixelSize.map { Double($0.height) }
                ))))
            default:
                continue
            }
        }
        let text = textBlocks.joined(separator: "\n")
        guard !text.isEmpty || !attachments.isEmpty else { return nil }
        return UserMessagePayload(text: text, attachments: attachments)
    }

#if DEBUG
    func handleEventForTesting(_ event: RPCEnvelope) {
        handle(event)
    }

    func hydrateTranscriptForTesting(_ envelope: RPCEnvelope) {
        hydrateTranscript(from: envelope)
    }
#endif

    private func handle(_ event: RPCEnvelope, processGeneration: Int? = nil) {
        let belongsToCurrentProcess = processGeneration.map { $0 == self.processGeneration } ?? true
#if DEBUG
        onRPCEventReceivedForTesting?(event, belongsToCurrentProcess)
#endif
        guard belongsToCurrentProcess else { return }
        guard let type = event.type else { return }
        if type == "extension_ui_request" {
            handleExtensionUIRequest(event)
            return
        }
        if isLoadingSession && !isSessionReady && pendingPrompt == nil && Self.isTurnEvent(type) {
            return
        }
        if isSuppressingStoppedTurnEvents && Self.isTurnEvent(type) {
            guard type == "agent_start" else { return }
            isSuppressingStoppedTurnEvents = false
        }
        switch type {
        case "agent_start":
            awaitingLegacySettlement = false
            agentActivityRevision += 1
            runningStartedAt = Date()
            isRunning = true
        case "agent_end":
            assistantBufferID = nil
            closeCurrentActivityGroup()
            // Older Pi runtimes emit agent_end but no agent_settled. Confirm
            // the engine is idle before finishing, since queued steering can
            // start another turn immediately after agent_end.
            awaitingLegacySettlement = event["willRetry"]?.boolValue != true
            if awaitingLegacySettlement { scheduleLegacySettlementCheck() }
        case "agent_settled":
            finishAgentRun()
        case "turn_end":
            assistantBufferID = nil
            closeCurrentActivityGroup()
        case "message_start":
            if event["message"]?.objectValue?["role"]?.stringValue == "user" {
                if isAwaitingInitialPromptUserEvent {
                    isAwaitingInitialPromptUserEvent = false
                } else {
                    consumeDeliveredSteeringIfPresent()
                }
            }
        case "message_update":
            handleMessageUpdate(event)
        case "message_end":
            handleMessageEnd(event)
        case "tool_execution_start":
            handleToolStart(event)
        case "tool_execution_update":
            handleToolUpdate(event)
        case "tool_execution_end":
            handleToolEnd(event)
        case "compaction_start":
            agentActivityRevision += 1
            items.append(.notice("Compacting session…"))
        case "compaction_end":
            items.append(.notice("Compaction finished."))
            if awaitingLegacySettlement { scheduleLegacySettlementCheck() }
        case "extension_ui_request":
            handleExtensionUIRequest(event)
        default:
            break
        }
    }

    private func scheduleLegacySettlementCheck() {
        if let client {
                let revision = agentActivityRevision
                let generation = self.processGeneration
                Task { @MainActor [weak self] in
                    for _ in 0..<5 {
                        guard let self, self.client === client,
                              self.processGeneration == generation,
                              self.agentActivityRevision == revision,
                              self.isRunning else { return }
                        if let state = try? await client.getState(timeoutSeconds: 2),
                           self.agentActivityRevision == revision,
                           self.processGeneration == generation,
                           self.client === client,
                           state.data?.objectValue?["isStreaming"]?.boolValue == false,
                           state.data?.objectValue?["pendingMessageCount"] == .number(0),
                           state.data?.objectValue?["isCompacting"]?.boolValue != true,
                           self.steeringSubmissionTask == nil {
                            self.finishAgentRun()
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
    }

    private func finishAgentRun() {
        guard isRunning else { return }
        awaitingLegacySettlement = false
        isRunning = false
        activeLocalTurnID = nil
        isAwaitingInitialPromptUserEvent = false
        assistantBufferID = nil
        closeCurrentActivityGroup()
        onAgentSettled?(items)
    }

    private static func isTurnEvent(_ type: String) -> Bool {
        switch type {
        case "agent_start", "agent_end", "agent_settled", "turn_end", "message_start", "message_end", "message_update", "tool_execution_start", "tool_execution_update", "tool_execution_end", "compaction_start", "compaction_end", "extension_ui_request":
            return true
        default:
            return false
        }
    }

    private func replaySteeringAfterStopIfNeeded() {
        guard shouldReplaySteeringAfterStop, isSessionReady, !pendingSteering.isEmpty else { return }
        shouldReplaySteeringAfterStop = false
        let generation = steeringOperationGeneration

        if mockResponse != nil {
            let first = pendingSteering.removeFirst()
#if DEBUG
            onPromptRPCForTesting?(first.prepared.summaryText)
#endif
            send(first.prepared, shouldAppendUserMessage: true)
            for index in pendingSteering.indices {
#if DEBUG
                onSteeringRPCForTesting?(pendingSteering[index].prepared.summaryText)
#endif
                pendingSteering[index].state = .accepted
            }
            return
        }

        guard client != nil else {
            failPendingSteeringReplay("Couldn’t resume steering after Stop: pi is not running.")
            return
        }

        runningStartedAt = Date()
        isRunning = true
        isAwaitingInitialPromptUserEvent = true
        activeLocalTurnID = UUID()

        Task { [weak self] in
            guard let self, let client = self.client, let first = self.pendingSteering.first else { return }
            do {
#if DEBUG
                self.onPromptRPCForTesting?(first.prepared.summaryText)
#endif
                _ = try await client.prompt(self.promptMessage(for: first.prepared), images: first.prepared.images)
                guard generation == self.steeringOperationGeneration else { return }
                if self.pendingSteering.first?.id == first.id {
                    self.pendingSteering.removeFirst()
                    self.appendUserMessage(for: first.prepared)
                }

                let remainingIDs = self.pendingSteering.map(\.id)
                for id in remainingIDs {
                    guard generation == self.steeringOperationGeneration,
                          let entry = self.pendingSteering.first(where: { $0.id == id })
                    else { return }
                    _ = try await client.steer(self.promptMessage(for: entry.prepared), images: entry.prepared.images)
                    guard generation == self.steeringOperationGeneration else { return }
                    self.setSteeringState(id: id, state: .accepted)
                }
            } catch {
                guard generation == self.steeringOperationGeneration else { return }
                self.isRunning = false
                self.isAwaitingInitialPromptUserEvent = false
                self.activeLocalTurnID = nil
                self.failReplayingSteeringIfNeeded(self.rpcFailureNotice("Couldn’t resume steering after Stop", error: error))
            }
        }
    }

    private func failReplayingSteeringIfNeeded(_ notice: String) {
        guard shouldReplaySteeringAfterStop || pendingSteering.contains(where: { $0.state == .replaying }) else { return }
        shouldReplaySteeringAfterStop = false
        failPendingSteeringReplay(notice)
    }

    private func failPendingSteeringReplay(_ notice: String) {
        for index in pendingSteering.indices where pendingSteering[index].state == .replaying {
            pendingSteering[index].state = .failed
        }
        items.append(.notice(notice))
    }

    private func handleExtensionUIRequest(_ event: RPCEnvelope) {
        guard let requestID = event["id"]?.stringValue,
              let method = event["method"]?.stringValue
        else { return }

        switch method {
        case "confirm", "select", "input", "editor":
            let notice = extensionUIPromptNotice(from: event, method: method)
            interactiveAttentionNotice = notice
            rpcStatusMessage = notice
            if !items.contains(where: { item in
                if case .notice(_, let text) = item { return text == notice }
                return false
            }) {
                items.append(.notice(notice))
            }
            onInteractiveAttention?(PiInteractiveAttention.message(from: event))
            sendExtensionUIResponse(id: requestID, fields: ["cancelled": .bool(true)])
        case "notify":
            if let message = event["message"]?.stringValue {
                rpcStatusMessage = message
                items.append(.notice(message))
            }
        case "setStatus", "setTitle":
            // Transient extension chrome updates are not user prompts. PiNative does
            // not yet render dedicated status/title surfaces, so keep them out of the
            // chat transcript.
            break
        default:
            items.append(.notice("Pi requested unsupported UI interaction: \(method)."))
        }
    }

    private func restoreInteractiveAttentionNoticeIfNeeded() {
        guard let interactiveAttentionNotice else { return }
        rpcStatusMessage = interactiveAttentionNotice
        if !items.contains(where: { item in
            if case .notice(_, let text) = item { return text == interactiveAttentionNotice }
            return false
        }) {
            items.append(.notice(interactiveAttentionNotice))
        }
    }

    private func extensionUIPromptNotice(from event: RPCEnvelope, method: String) -> String {
        let title = event["title"]?.stringValue ?? "Pi requested input"
        let message = event["message"]?.stringValue ?? event["placeholder"]?.stringValue ?? ""
        let options = event["options"]?.arrayValue?.compactMap(\.stringValue) ?? []
        var lines = ["Pi needs attention: \(title)"]
        if !message.isEmpty { lines.append(message) }
        if !options.isEmpty { lines.append("Options: " + options.joined(separator: ", ")) }
        lines.append("PiNative does not handle interactive \(method) prompts yet. Resolve this in Pi, then retry.")
        return lines.joined(separator: "\n")
    }

    private func sendExtensionUIResponse(id: String, fields: [String: JSONValue]) {
        let responseProcessGeneration = processGeneration
        Task {
            do {
                try await client?.extensionUIResponse(id: id, fields: fields)
            } catch {
                await MainActor.run {
                    guard responseProcessGeneration == self.processGeneration else { return }
                    self.reportHandledPiOperationFailure(area: .extensionUIResponse, error: error)
                    self.items.append(.notice("Failed to dismiss Pi prompt: \(Self.userVisibleErrorMessage(error.localizedDescription))"))
                }
            }
        }
    }

    private func handleMessageUpdate(_ event: RPCEnvelope) {
        guard
            let assistantEvent = event["assistantMessageEvent"]?.objectValue,
            let eventType = assistantEvent["type"]?.stringValue
        else { return }

        if eventType == "text_delta", let delta = assistantEvent["delta"]?.stringValue {
            appendAssistant(delta)
        }
    }

    private func handleMessageEnd(_ event: RPCEnvelope) {
        guard let message = event["message"]?.objectValue,
              message["role"]?.stringValue == "assistant"
        else { return }
        let finalText = (message["content"]?.arrayValue ?? []).compactMap { block -> String? in
            guard let object = block.objectValue,
                  object["type"]?.stringValue == "text"
            else { return nil }
            return object["text"]?.stringValue
        }.joined()
        guard !finalText.isEmpty else {
            assistantBufferID = nil
            return
        }

        if let assistantBufferID,
           let index = items.firstIndex(where: { $0.id == assistantBufferID }),
           case .assistantText(let id, _) = items[index] {
            items[index] = .assistantText(id: id, text: finalText)
        } else {
            items.append(.assistantText(text: finalText))
        }
        assistantBufferID = nil
    }

    private func handleToolStart(_ event: RPCEnvelope) {
        let callID = event["toolCallId"]?.stringValue ?? UUID().uuidString
        let name = event["toolName"]?.stringValue ?? "tool"
        let args = event["args"]?.prettyPrinted ?? ""
        let tool = ToolTranscriptItem(id: UUID(), callID: callID, name: name, args: args, output: "", status: .running)

        if let groupID = currentActivityGroupID,
           let index = items.firstIndex(where: { $0.id == groupID }),
           case .activity(var group) = items[index] {
            group.tools.append(tool)
            items[index] = .activity(group)
            toolCallIDToGroupID[callID] = groupID
        } else {
            let groupID = UUID()
            let group = ActivityGroup(id: groupID, tools: [tool], isRunning: true, startedAt: Date(), finishedAt: nil)
            items.append(.activity(group))
            currentActivityGroupID = groupID
            toolCallIDToGroupID[callID] = groupID
            // A new activity group is opening: any further text in this turn
            // belongs in a fresh bubble, not merged into whatever text came
            // before this tool call.
            assistantBufferID = nil
        }
    }

    private func handleToolUpdate(_ event: RPCEnvelope) {
        guard let callID = event["toolCallId"]?.stringValue else { return }
        updateTool(callID: callID) { tool in
            tool.output = event["partialResult"]?.toolTextContent ?? tool.output
        }
    }

    private func handleToolEnd(_ event: RPCEnvelope) {
        guard let callID = event["toolCallId"]?.stringValue else { return }
        let isError = event["isError"]?.boolValue ?? false
        updateTool(callID: callID) { tool in
            tool.output = event["result"]?.toolTextContent ?? tool.output
            tool.status = isError ? .failed : .succeeded
        }
    }

    private func appendAssistant(_ delta: String) {
        if let assistantBufferID, let index = items.firstIndex(where: { $0.id == assistantBufferID }) {
            if case .assistantText(let id, let text) = items[index] {
                items[index] = .assistantText(id: id, text: text + delta)
            }
        } else {
            let id = UUID()
            assistantBufferID = id
            items.append(.assistantText(id: id, text: delta))
        }
    }

    func fetchSessionName(timeoutSeconds: TimeInterval = 2) async -> String? {
        guard mockResponse == nil, let client,
              let state = try? await client.getState(timeoutSeconds: timeoutSeconds),
              let name = state.data?.objectValue?["sessionName"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return nil }
        return name
    }

    func syncSessionName(_ name: String) {
        guard mockResponse == nil else { return }
        Task { _ = try? await client?.setSessionName(name) }
    }

    private func updateTool(callID: String, mutate: (inout ToolTranscriptItem) -> Void) {
        guard let groupID = toolCallIDToGroupID[callID],
              let itemIndex = items.firstIndex(where: { $0.id == groupID }),
              case .activity(var group) = items[itemIndex],
              let toolIndex = group.tools.firstIndex(where: { $0.callID == callID })
        else { return }
        mutate(&group.tools[toolIndex])
        items[itemIndex] = .activity(group)
    }

    /// Closes the currently-open activity group (if any): stops its live
    /// timer and marks it finished. Called on `agent_end` (turn boundary)
    /// and when the user sends a new message — the two closing triggers per
    /// implementation plan §D. Interleaved assistant text does *not* call
    /// this.
    private func closeCurrentActivityGroup() {
        defer { currentActivityGroupID = nil }
        guard let groupID = currentActivityGroupID,
              let index = items.firstIndex(where: { $0.id == groupID }),
              case .activity(var group) = items[index]
        else { return }
        group.isRunning = false
        group.finishedAt = Date()
        items[index] = .activity(group)
        // Drop this group's callID mappings now that it's closed — otherwise
        // this dictionary grows for as long as the app stays open.
        for tool in group.tools {
            toolCallIDToGroupID.removeValue(forKey: tool.callID)
        }
    }
}

private struct ConversationStartKey: Equatable {
    var workingDirectory: String?
    var sessionPath: String?
    var planningMode: Bool
}

private struct PendingPrompt {
    var prepared: PreparedPrompt
    var shouldAppendUserMessage: Bool
}

struct SteeringMessage: Identifiable, Hashable {
    enum State: Hashable {
        case submitting
        case accepted
        case replaying
        case failed
    }

    var id = UUID()
    var prepared: PreparedPrompt
    var composerText: String
    var composerAttachments: [ComposerAttachment]
    var state: State
}

struct UserMessagePayload: Hashable, Codable {
    var text: String
    var attachments: [ComposerAttachment]

    init(text: String, attachments: [ComposerAttachment] = []) {
        self.text = text
        self.attachments = attachments
    }
}

enum TranscriptItem: Identifiable, Hashable, Codable {
    static let interruptionNoticeText = "Stopped."

    case user(id: UUID = UUID(), UserMessagePayload)
    case assistantText(id: UUID = UUID(), text: String)
    case activity(ActivityGroup)
    case notice(id: UUID = UUID(), String)

    private enum CaseKeys: String, CodingKey {
        case user, assistantText, activity, notice
    }

    private enum AssociatedKeys: String, CodingKey {
        case id, text, _0, _1
    }

    var isInterruptionNotice: Bool {
        guard case .notice(_, let text) = self else { return false }
        return text == Self.interruptionNoticeText
    }

    var id: UUID {
        switch self {
        case .user(let id, _): id
        case .assistantText(let id, _): id
        case .activity(let group): group.id
        case .notice(let id, _): id
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CaseKeys.self)
        if container.contains(.user) {
            let nested = try container.nestedContainer(keyedBy: AssociatedKeys.self, forKey: .user)
            let id = try nested.decodeIfPresent(UUID.self, forKey: .id) ?? nested.decodeIfPresent(UUID.self, forKey: ._0) ?? UUID()
            if let payload = try? nested.decode(UserMessagePayload.self, forKey: ._1) {
                self = .user(id: id, payload)
            } else {
                let text = (try? nested.decode(String.self, forKey: ._1)) ?? ""
                self = .user(id: id, UserMessagePayload(text: text))
            }
        } else if container.contains(.assistantText) {
            let nested = try container.nestedContainer(keyedBy: AssociatedKeys.self, forKey: .assistantText)
            let id = try nested.decodeIfPresent(UUID.self, forKey: .id) ?? nested.decodeIfPresent(UUID.self, forKey: ._0) ?? UUID()
            let text = (try? nested.decode(String.self, forKey: .text)) ?? (try? nested.decode(String.self, forKey: ._1)) ?? ""
            self = .assistantText(id: id, text: text)
        } else if container.contains(.activity) {
            self = .activity(try container.decode(ActivityGroup.self, forKey: .activity))
        } else if container.contains(.notice) {
            let nested = try container.nestedContainer(keyedBy: AssociatedKeys.self, forKey: .notice)
            let id = try nested.decodeIfPresent(UUID.self, forKey: .id) ?? nested.decodeIfPresent(UUID.self, forKey: ._0) ?? UUID()
            let text = (try? nested.decode(String.self, forKey: ._1)) ?? ""
            self = .notice(id: id, text)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown transcript item case"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CaseKeys.self)
        switch self {
        case .user(let id, let payload):
            var nested = container.nestedContainer(keyedBy: AssociatedKeys.self, forKey: .user)
            try nested.encode(id, forKey: .id)
            try nested.encode(payload, forKey: ._1)
        case .assistantText(let id, let text):
            var nested = container.nestedContainer(keyedBy: AssociatedKeys.self, forKey: .assistantText)
            try nested.encode(id, forKey: .id)
            try nested.encode(text, forKey: .text)
        case .activity(let group):
            try container.encode(group, forKey: .activity)
        case .notice(let id, let text):
            var nested = container.nestedContainer(keyedBy: AssociatedKeys.self, forKey: .notice)
            try nested.encode(id, forKey: .id)
            try nested.encode(text, forKey: ._1)
        }
    }
}

struct ActivityGroup: Identifiable, Hashable, Codable {
    var id: UUID
    var tools: [ToolTranscriptItem]
    var isRunning: Bool
    var startedAt: Date
    var finishedAt: Date?
}

struct ToolTranscriptItem: Identifiable, Hashable, Codable {
    var id: UUID
    var callID: String
    var name: String
    var args: String
    var output: String
    var status: ToolStatus
}

enum ToolStatus: String, Hashable, Codable {
    case running
    case succeeded
    case failed

    var label: String {
        switch self {
        case .running: "Running"
        case .succeeded: "Done"
        case .failed: "Failed"
        }
    }
}

private extension JSONValue {
    var boolValue: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    var prettyPrinted: String? {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: prettyData, encoding: .utf8)
        else { return nil }
        return string
    }

    /// Tolerant text extraction from a tool result/partial-result payload.
    /// Confirmed live-event shape is `{content: [{type, text}, ...]}`, but
    /// hydration reads this from a saved session's top-level `content`
    /// field, whose exact on-disk shape wasn't verified against a real
    /// persisted session this milestone (see docs/native-shell-architecture.md).
    /// Handle the plausible shapes defensively rather than silently
    /// returning empty output for anything that isn't the exact live shape:
    /// a bare string, an array of `{text}` blocks directly, or the nested
    /// `{content: [{text}]}` envelope.
    var toolTextContent: String? {
        if let text = stringValue { return text }

        if let blocks = arrayValue {
            let text = blocks.compactMap { $0.objectValue?["text"]?.stringValue }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        }

        guard let object = objectValue else { return nil }
        if let content = object["content"]?.arrayValue {
            let text = content.compactMap { $0.objectValue?["text"]?.stringValue }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
        return object["text"]?.stringValue
    }
}

/// A selectable model as exposed by pi's RPC `get_available_models` /
/// `get_state` commands.
enum PiThinkingLevel: String, Identifiable, CaseIterable, Hashable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Off"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra Hard"
        case .max: "Max"
        }
    }
}

struct PiModelOption: Identifiable, Hashable, Codable, Sendable {
    var provider: String
    var id: String
    var name: String

    var stableID: String { "\(provider)/\(id)" }

    init(provider: String, id: String, name: String) {
        self.provider = provider
        self.id = id
        self.name = name
    }

    init?(json: JSONValue?) {
        guard let object = json?.objectValue,
              let id = object["id"]?.stringValue,
              let provider = object["provider"]?.stringValue
        else { return nil }
        self.provider = provider
        self.id = id
        self.name = object["name"]?.stringValue ?? id
    }
}
