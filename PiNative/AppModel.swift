import AppKit
import Combine
import Foundation
import SwiftUI

enum AppTheme {
    static let skyAccent = Color(red: 0.31, green: 0.62, blue: 0.92)
    static let skyAccentNSColor = NSColor(calibratedRed: 0.31, green: 0.62, blue: 0.92, alpha: 1)
    static let insertionPointNSColor = dynamicNSColor(
        light: NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.78, alpha: 1),
        dark: NSColor(calibratedRed: 0.47, green: 0.72, blue: 1.00, alpha: 1)
    )
    static let dangerText = dynamicColor(
        light: NSColor(calibratedRed: 0.47, green: 0.07, blue: 0.11, alpha: 1),
        dark: NSColor(calibratedRed: 0.94, green: 0.30, blue: 0.32, alpha: 1)
    )
    static let stopAccent = dangerText
    static let recoveryAccent = Color(nsColor: .systemOrange)
    static let recoveryBackground = dynamicColor(
        light: NSColor(calibratedRed: 1.0, green: 0.91, blue: 0.72, alpha: 1),
        dark: NSColor(calibratedRed: 0.24, green: 0.15, blue: 0.06, alpha: 1)
    )
    static let recoveryBorder = dynamicColor(
        light: NSColor(calibratedRed: 0.78, green: 0.48, blue: 0.10, alpha: 0.48),
        dark: NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.18, alpha: 0.42)
    )
    static let recoveryActionBackground = dynamicColor(
        light: NSColor(calibratedRed: 0.82, green: 0.91, blue: 1.0, alpha: 1),
        dark: NSColor(calibratedRed: 0.10, green: 0.25, blue: 0.40, alpha: 1)
    )
    static let recoveryActionBorder = dynamicColor(
        light: NSColor(calibratedRed: 0.31, green: 0.62, blue: 0.92, alpha: 0.66),
        dark: NSColor(calibratedRed: 0.47, green: 0.72, blue: 1.0, alpha: 0.58)
    )

    static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: dynamicNSColor(light: light, dark: dark))
    }

    static func dynamicNSColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua ? light : dark
        }
    }
}

enum ShellPalette {
    // Shared shell chrome for the titlebar, sidebars, and pane headers.
    static let chrome = AppTheme.dynamicColor(
        light: NSColor(calibratedRed: 0.845, green: 0.853, blue: 0.868, alpha: 1),
        dark: NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.10, alpha: 1)
    )
    static let chromeNSColor = AppTheme.dynamicNSColor(
        light: NSColor(calibratedRed: 0.845, green: 0.853, blue: 0.868, alpha: 1),
        dark: NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.10, alpha: 1)
    )
    static let separator = Color.clear
    static let internalSeparator = AppTheme.dynamicColor(
        light: NSColor(calibratedWhite: 0.62, alpha: 0.70),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.07)
    )
    static let activeSeparator = Color.clear
}

enum RightPaneMode: String, Identifiable {
    case review, browser, plugins, archivedChats
    var id: String { rawValue }

    static let availableModes: [RightPaneMode] = [.review, .browser, .plugins]
}

struct BlockedNavigationAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

struct ConversationKey: Hashable, Codable, Sendable {
    var projectID: Project.ID?
    var sessionID: Session.ID
}

struct ConversationRuntimeState: Equatable {
    var isRunning = false
    var isLoadingSession = false
    var hasPendingPrompt = false
    var isProcessStarted = false
    var lastUsedAt = Date()
    var lastErrorSummary: String?
}

@MainActor
private final class ConversationRuntime {
    let key: ConversationKey
    let model: PiConversationModel
    var stateCancellables: Set<AnyCancellable> = []
    var titleTask: Task<Void, Never>?

    init(key: ConversationKey, model: PiConversationModel) {
        self.key = key
        self.model = model
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "display"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

private struct ModelCatalogCommandError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var projects: [Project]
    @Published var standaloneSessions: [Session]
    @Published var selectedProjectID: Project.ID?
    @Published var selectedSessionID: Session.ID?
    @Published var reviewProjectID: Project.ID?
    @Published var isCommandKeyHeld = false
    @Published var blockedNavigationAlert: BlockedNavigationAlert?
    @Published private(set) var piHealthIssue: PiHealthIssue?
    @Published private(set) var isCheckingPiHealth = false
    @Published var isSettingsPresented = false
    @Published var settingsSection: SettingsSection = .general
    @Published private(set) var isSigningInToOutfitter = false
    @Published private(set) var outfitterSignInStatus: String?
    @Published private(set) var isConnectedToOutfitter = false
    private var outfitterLoginProcess: Process?
    private var pendingOutfitterPrompt: (prompt: PreparedPrompt, projectID: Project.ID?)?
    private let outfitterRuntimeConfigured: Bool?
    var canSignInToOutfitter: Bool { outfitterRuntimeConfigured ?? (ProcessInfo.processInfo.environment["OUTFITTER_DESKTOP_CLI"] != nil) }
    let modelSettings: ModelSettingsModel
    private let analytics: any AnalyticsControlling
    @Published var analyticsEnabled: Bool {
        didSet { analytics.setEnabled(analyticsEnabled) }
    }
    @Published var appearance: AppAppearance = .system {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey)
            Self.applyAppKitAppearance(appearance)
        }
    }
    @Published var promoteDefaultCodeFolder: String {
        didSet { UserDefaults.standard.set(promoteDefaultCodeFolder, forKey: Self.promoteDefaultCodeFolderKey) }
    }
    @Published var promoteOptions: PromoteToProjectOptions {
        didSet { Self.storePromoteOptions(promoteOptions) }
    }

    private var localModifierMonitor: Any?
    private var globalModifierMonitor: Any?
    private let modelCatalogLoaderOverride: (() async throws -> [PiModelOption])?
    private let chatTitleGenerator: any ChatTitleGenerating
    private let conversationModelFactory: (ModelSettingsModel) -> PiConversationModel
    private let piHealthCheckOperation: () async -> PiHealthCheckResult
    private let piTerminalRecoveryOperation: (PiCommand?) async throws -> Void
    private var hasCompletedPiHealthCheck = false
    private var piHealthCheckTask: Task<PiHealthCheckResult, Never>?
    private var piHealthCheckGeneration: UUID?
    private var piHealthCheckStartingRevision: Int?
    private var piHealthStateRevision = 0
    private var piRecoveryCommand: PiCommand?
    private var piRecoveryRecheckRevision: Int?

    // MARK: - Shell layout state

    @Published var isLeftPaneVisible: Bool {
        didSet { UserDefaults.standard.set(isLeftPaneVisible, forKey: Self.leftPaneVisibleKey) }
    }
    @Published var leftPaneWidth: CGFloat {
        didSet { UserDefaults.standard.set(Double(leftPaneWidth), forKey: Self.leftPaneWidthKey) }
    }
    /// Not persisted across launches: the right pane always starts closed.
    @Published var isRightPaneOpen: Bool = false
    /// Not persisted across launches; nil = picker showing (pane open, no mode chosen yet).
    @Published var rightPaneMode: RightPaneMode? = nil

    /// Non-nil while the "Promote to Project" placeholder modal is up.
    /// Holds the chat being promoted so the modal can reference it by name
    /// (and so the real implementation has its target when it lands).
    @Published var promoteCandidateSession: Session? = nil
    @Published var rightPaneWidth: CGFloat {
        didSet { UserDefaults.standard.set(Double(rightPaneWidth), forKey: Self.rightPaneWidthKey) }
    }
    /// The conversation model currently visible in the center pane. Runtime
    /// ownership is per conversation; this remains as a compatibility bridge
    /// for existing views that render the selected runtime.
    @Published var activeConversationModel: PiConversationModel?
    @Published var activeConversationIsRunning = false
    @Published private(set) var conversationRuntimeStates: [ConversationKey: ConversationRuntimeState] = [:]
    var automaticallyStartsPendingRuntimes = true
    private var conversationRuntimes: [ConversationKey: ConversationRuntime] = [:]

    /// Lazily created, kept alive for the app's lifetime once first opened, so
    /// navigation state survives switching the right pane away and back.
    @Published var browserModel: BrowserModel?

    /// Lazily created, same lifecycle rationale as `browserModel`.
    @Published var diffModel: DiffModel?

    /// Callers must not invoke this from inside a SwiftUI `body`/`@ViewBuilder`
    /// evaluation — assigning `@Published browserModel` there triggers
    /// "Publishing changes from within view updates" undefined behavior.
    /// Use `selectRightPaneMode(_:)` (which calls this eagerly, outside of
    /// view evaluation, before setting `rightPaneMode`) instead of reaching
    /// for this directly from a view. Found by adversarial review.
    @discardableResult
    private func browserModelInstance() -> BrowserModel {
        if let browserModel { return browserModel }
        let model = BrowserModel()
        browserModel = model
        return model
    }

    @discardableResult
    private func diffModelInstance() -> DiffModel {
        if let diffModel { return diffModel }
        let model = DiffModel()
        diffModel = model
        return model
    }

    private static let leftPaneVisibleKey = "shell.leftPaneVisible"
    private static let leftPaneWidthKey = "shell.leftPaneWidth"
    private static let rightPaneWidthKey = "shell.rightPaneWidth"
    private static let appearanceKey = "app.appearance"
    static let defaultProjectFolderPath = "~/Projects"

    private static let promoteDefaultCodeFolderKey = "promote.defaultCodeFolder"
    private static let promoteInitializeGitRepoKey = "promote.initializeGitRepo"
    private static let promoteSeedProjectMemoryKey = "promote.seedProjectMemory"
    private static let promoteAddAgentInstructionsKey = "promote.addAgentInstructions"
    private static let previousDefaultLeftPaneWidth: CGFloat = 260
    private static let defaultLeftPaneWidth: CGFloat = 320
    private static let projectPathsKey = "projects.paths"
    private static let selectedProjectPathKey = "projects.selectedPath"
    private static let projectSessionsKeyPrefix = "projects.sessions."
    private static let standaloneSessionsKey = "sessions.standalone"

    init(
        modelFavoritesStorage: ModelFavoritesStorage? = nil,
        modelCatalogLoader: (() async throws -> [PiModelOption])? = nil,
        chatTitleGenerator: (any ChatTitleGenerating)? = nil,
        analytics: any AnalyticsControlling = AppAnalytics.shared,
        outfitterRuntimeConfigured: Bool? = nil,
        piHealthCheck: (() async -> PiHealthCheckResult)? = nil,
        piTerminalRecovery: ((PiCommand?) async throws -> Void)? = nil,
        conversationModelFactory: ((ModelSettingsModel) -> PiConversationModel)? = nil
    ) {
        self.analytics = analytics
        self.outfitterRuntimeConfigured = outfitterRuntimeConfigured
        self.analyticsEnabled = analytics.isEnabled
        self.piHealthCheckOperation = piHealthCheck ?? { await PiHealthChecker.check() }
        self.piTerminalRecoveryOperation = piTerminalRecovery ?? { command in
            try await PiTerminalRecovery.open(command: command)
        }
        let defaults = UserDefaults.standard
        let environment = ProcessInfo.processInfo.environment
        let storage = modelFavoritesStorage ?? FileModelFavoritesStorage(fileURL: FileModelFavoritesStorage.defaultLocation(environment: environment))
        self.modelCatalogLoaderOverride = modelCatalogLoader
        self.chatTitleGenerator = chatTitleGenerator ?? PiChatTitleService.shared
        self.modelSettings = ModelSettingsModel(
            storage: storage,
            configuredDefaultModel: ModelSettingsModel.configuredDefaultModel(environment: environment)
        )
        self.conversationModelFactory = conversationModelFactory ?? { PiConversationModel(modelSettings: $0) }
        let isResettingForUITests = environment["PI_NATIVE_RESET_PROJECTS"] == "1"
        self.isLeftPaneVisible = isResettingForUITests ? true : (defaults.object(forKey: Self.leftPaneVisibleKey) as? Bool ?? true)
        let defaultCodeFolder = environment["PI_NATIVE_TEST_PROMOTE_CODE_FOLDER"] ?? defaults.string(forKey: Self.promoteDefaultCodeFolderKey) ?? Self.defaultProjectFolderPath
        self.promoteDefaultCodeFolder = defaultCodeFolder
        Self.ensureProjectFolderExists(at: defaultCodeFolder)
        self.promoteOptions = Self.loadPromoteOptions(defaults: defaults)
        let storedLeftWidth = defaults.object(forKey: Self.leftPaneWidthKey) as? Double
        let storedRightWidth = defaults.object(forKey: Self.rightPaneWidthKey) as? Double
        // Clamp restored values to the same bounds ResizableDividerView
        // enforces during a live drag — a corrupt/stale UserDefaults value
        // (e.g. from an older build with different bounds) shouldn't be able
        // to restore an impossible layout on launch. Bounds duplicated from
        // MainWindowView's ResizableDividerView call sites.
        let restoredLeftWidth = storedLeftWidth.map { CGFloat($0) }
        let leftWidth = restoredLeftWidth == Self.previousDefaultLeftPaneWidth ? Self.defaultLeftPaneWidth : (restoredLeftWidth ?? Self.defaultLeftPaneWidth)
        self.leftPaneWidth = min(max(leftWidth, 200), 400)
        self.rightPaneWidth = min(max(storedRightWidth.map { CGFloat($0) } ?? 340, 280), 480)

        let storedPaths: [String]
        if isResettingForUITests {
            storedPaths = [
                environment["PI_NATIVE_TEST_PROJECT_PATH"],
                environment["PI_NATIVE_TEST_OTHER_PROJECT_PATH"]
            ].compactMap { $0 }
        } else {
            storedPaths = defaults.stringArray(forKey: Self.projectPathsKey) ?? []
        }
        let projectPaths = Self.normalizedUniqueProjectPaths(storedPaths)
        var initializedProjects = projectPaths.map(Self.makeProject(path:)).map(Self.sanitizedProject)
        if isResettingForUITests, let seedTitle = environment["PI_NATIVE_TEST_SEEDED_CHAT_TITLE"], let firstProjectIndex = initializedProjects.indices.first {
            let now = Date()
            var seededSessions = [
                Session(
                    name: seedTitle,
                    status: .idle,
                    filePath: "/tmp/pinative-ui-newest-visible.jsonl",
                    updatedAt: now,
                    messageCount: 1,
                    cachedTranscript: Self.testCachedTranscript(title: seedTitle, environment: environment)
                )
            ]
            if let olderTitle = environment["PI_NATIVE_TEST_SEEDED_OLDER_CHAT_TITLE"] {
                seededSessions.insert(Session(
                    name: olderTitle,
                    status: .idle,
                    filePath: "/tmp/pinative-ui-older-visible.jsonl",
                    updatedAt: now.addingTimeInterval(-60),
                    messageCount: 1,
                    cachedTranscript: Self.testCachedTranscript(title: olderTitle, environment: environment)
                ), at: 0)
            }
            if let archivedTitle = environment["PI_NATIVE_TEST_SEEDED_ARCHIVED_CHAT_TITLE"] {
                seededSessions.append(Session(
                    name: archivedTitle,
                    status: .idle,
                    filePath: "/tmp/pinative-ui-archived.jsonl",
                    updatedAt: now.addingTimeInterval(60),
                    messageCount: 1,
                    isArchived: true,
                    cachedTranscript: [.user(UserMessagePayload(text: archivedTitle))]
                ))
            }
            if let pinnedTitle = environment["PI_NATIVE_TEST_SEEDED_PINNED_CHAT_TITLE"] {
                seededSessions.append(Session(
                    name: pinnedTitle,
                    status: .idle,
                    filePath: "/tmp/pinative-ui-pinned.jsonl",
                    updatedAt: now.addingTimeInterval(120),
                    messageCount: 1,
                    isPinned: true,
                    cachedTranscript: [.user(UserMessagePayload(text: pinnedTitle))]
                ))
            }
            initializedProjects[firstProjectIndex].sessions = seededSessions

            if initializedProjects.indices.contains(firstProjectIndex + 1),
               let otherProjectTitle = environment["PI_NATIVE_TEST_OTHER_PROJECT_CHAT_TITLE"] {
                initializedProjects[firstProjectIndex + 1].sessions = [Session(
                    name: otherProjectTitle,
                    status: .idle,
                    filePath: "/tmp/pinative-ui-other-project.jsonl",
                    updatedAt: now.addingTimeInterval(180),
                    messageCount: 1,
                    cachedTranscript: Self.testCachedTranscript(title: otherProjectTitle, environment: environment)
                )]
            }
        }
        self.projects = initializedProjects
        if isResettingForUITests {
            let quickChatTitles = environment["PI_NATIVE_TEST_STANDALONE_CHAT_TITLES"]?
                .split(separator: "|")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []
            let now = Date()
            self.standaloneSessions = quickChatTitles.enumerated().map { index, title in
                Session(
                    name: title,
                    status: .idle,
                    filePath: "/tmp/pinative-ui-standalone-\(index).jsonl",
                    updatedAt: now.addingTimeInterval(TimeInterval(-index * 60)),
                    messageCount: 1,
                    cachedTranscript: [.user(UserMessagePayload(text: title))]
                )
            }
        } else {
            self.standaloneSessions = Self.loadStandaloneSessions().map(Self.sanitizedSession)
        }
        if !isResettingForUITests {
            defaults.set(projectPaths, forKey: Self.projectPathsKey)
        }

        let selectedPath = defaults.string(forKey: Self.selectedProjectPathKey)
        let selectedProject = projects.first { $0.path == selectedPath } ?? projects.first
        self.selectedProjectID = selectedProject?.id
        self.selectedSessionID = selectedProject?.sessions.first?.id
        self.appearance = AppAppearance(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
        Self.applyAppKitAppearance(self.appearance)

        syncActiveConversationModelToSelection()
        refreshProjectDiffStats()
    }

    var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    var reviewProject: Project? {
        if let reviewProjectID,
           let project = projects.first(where: { $0.id == reviewProjectID }) {
            return project
        }
        return selectedProject
    }

    var pinnedSessions: [(projectID: Project.ID?, session: Session)] {
        let projectPins = projects.flatMap { project in
            project.sessions
                .filter { $0.isPinned && !$0.isArchived }
                .map { (projectID: Optional(project.id), session: $0) }
        }
        let standalonePins = standaloneSessions
            .filter { $0.isPinned && !$0.isArchived }
            .map { (projectID: Optional<Project.ID>.none, session: $0) }
        return (projectPins + standalonePins).sorted { $0.session.updatedAt > $1.session.updatedAt }
    }

    var selectedSession: Session? {
        if let selectedProject {
            return selectedProject.sessions.first { $0.id == selectedSessionID }
        }
        return standaloneSessions.first { $0.id == selectedSessionID }
    }

    var selectedConversationKey: ConversationKey? {
        guard let selectedSessionID else { return nil }
        return ConversationKey(projectID: selectedProjectID, sessionID: selectedSessionID)
    }

    func runtime(for key: ConversationKey) -> PiConversationModel? {
        conversationRuntimes[key]?.model
    }

    func isConversationRunning(sessionID: Session.ID, projectID: Project.ID?) -> Bool {
        conversationRuntimeStates[ConversationKey(projectID: projectID, sessionID: sessionID)]?.isRunning == true
    }

    func isConversationWorking(sessionID: Session.ID, projectID: Project.ID?) -> Bool {
        let key = ConversationKey(projectID: projectID, sessionID: sessionID)
        if let runtime = conversationRuntimes[key], runtime.model.blocksConversationSelection {
            return true
        }
        let state = conversationRuntimeStates[key]
        return state?.isRunning == true || state?.hasPendingPrompt == true
    }

    var archivedChats: [(projectID: Project.ID?, projectName: String?, session: Session)] {
        let projectChats = projects.flatMap { project in
            project.sessions
                .filter(\.isArchived)
                .map { (projectID: Optional(project.id), projectName: Optional(project.name), session: $0) }
        }
        let quickChats = standaloneSessions
            .filter(\.isArchived)
            .map { (projectID: Optional<Project.ID>.none, projectName: Optional<String>.none, session: $0) }
        return (projectChats + quickChats).sorted { $0.session.updatedAt > $1.session.updatedAt }
    }

    var visibleSessionShortcuts: [(projectID: Project.ID?, session: Session, shortcutIndex: Int)] {
        // Ordered to match the sidebar's display order: pinned chats first,
        // then project chats (nested under their projects, top to bottom),
        // then standalone chats in the "Quick Chats" section.
        let pinned = pinnedSessions.map { (projectID: $0.projectID, session: $0.session, shortcutIndex: 0) }
        let projectSessions = projects.flatMap { project in
            project.sessions.filter { !$0.isArchived && !$0.isPinned }.map { session in (projectID: Optional(project.id), session: session, shortcutIndex: 0) }
        }
        let standalone = standaloneSessions.filter { !$0.isArchived && !$0.isPinned }.map { session in (projectID: Optional<Project.ID>.none, session: session, shortcutIndex: 0) }
        return Array((pinned + projectSessions + standalone).prefix(9).enumerated()).map { index, item in
            (projectID: item.projectID, session: item.session, shortcutIndex: index + 1)
        }
    }

    /// Archives a chat: it disappears from the sidebar but its session file
    /// and cached transcript are retained. If the archived chat was selected,
    /// selection moves to the next visible chat (or the new-chat screen).
    func archiveSession(sessionID: Session.ID, in projectID: Project.ID?) {
        if isConversationWorking(sessionID: sessionID, projectID: projectID) {
            NSSound.beep()
            blockedNavigationAlert = BlockedNavigationAlert(
                title: "Chat is working",
                message: "Wait for this chat to finish, or press Stop while it is selected, before archiving it."
            )
            return
        }
        cleanupRuntime(for: ConversationKey(projectID: projectID, sessionID: sessionID))
        if let projectID,
           let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
           let sessionIndex = projects[projectIndex].sessions.firstIndex(where: { $0.id == sessionID }) {
            projects[projectIndex].sessions[sessionIndex].isArchived = true
            persistProjectSessions(projectIndex: projectIndex)
        } else if let sessionIndex = standaloneSessions.firstIndex(where: { $0.id == sessionID }) {
            standaloneSessions[sessionIndex].isArchived = true
            persistStandaloneSessions()
        }

        guard selectedSessionID == sessionID else { return }
        if let next = visibleSessionShortcuts.first {
            select(sessionID: next.session.id, in: next.projectID)
        } else {
            startNewChat()
        }
    }

    func unarchiveSession(sessionID: Session.ID, in projectID: Project.ID?) {
        if let projectID,
           let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
           let sessionIndex = projects[projectIndex].sessions.firstIndex(where: { $0.id == sessionID }) {
            projects[projectIndex].sessions[sessionIndex].isArchived = false
            projects[projectIndex].sessions[sessionIndex].updatedAt = .now
            persistProjectSessions(projectIndex: projectIndex)
        } else if projectID == nil,
                  let sessionIndex = standaloneSessions.firstIndex(where: { $0.id == sessionID }) {
            standaloneSessions[sessionIndex].isArchived = false
            standaloneSessions[sessionIndex].updatedAt = .now
            persistStandaloneSessions()
        }
    }

    func startCommandKeyTracking() {
        guard localModifierMonitor == nil, globalModifierMonitor == nil else { return }
        localModifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.updateCommandKeyState(from: event)
            return event
        }
        globalModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.updateCommandKeyState(from: event)
        }
    }

    func stopCommandKeyTracking() {
        if let localModifierMonitor {
            NSEvent.removeMonitor(localModifierMonitor)
        }
        if let globalModifierMonitor {
            NSEvent.removeMonitor(globalModifierMonitor)
        }
        localModifierMonitor = nil
        globalModifierMonitor = nil
        isCommandKeyHeld = false
    }

    private func updateCommandKeyState(from event: NSEvent) {
        isCommandKeyHeld = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
    }

    func selectSession(shortcutIndex: Int) {
        guard let target = visibleSessionShortcuts.first(where: { $0.shortcutIndex == shortcutIndex }) else { return }
        select(sessionID: target.session.id, in: target.projectID)
    }

    func select(projectID: Project.ID, sessionID: Session.ID? = nil) {
        selectedProjectID = projectID
        if let sessionID {
            selectedSessionID = sessionID
        } else {
            selectedSessionID = projects.first { $0.id == projectID }?
                .sessions
                .filter { !$0.isArchived && !$0.isPinned }
                .sorted { $0.updatedAt > $1.updatedAt }
                .first?
                .id
        }
        persistSelectedProjectPath()
        syncActiveConversationModelToSelection()
    }

    func select(sessionID: Session.ID, in projectID: Project.ID?) {
        selectedProjectID = projectID
        selectedSessionID = sessionID
        persistSelectedProjectPath()
        syncActiveConversationModelToSelection()
    }

    func clearNewChatProjectSelection() {
        selectedProjectID = nil
        selectedSessionID = nil
        persistSelectedProjectPath()
        syncActiveConversationModelToSelection()
    }

    func startNewChat() {
        analytics.track(.chatStarted)
        selectedProjectID = nil
        selectedSessionID = nil
        persistSelectedProjectPath()
        syncActiveConversationModelToSelection()
    }

    func startNewChat(in projectID: Project.ID) {
        analytics.track(.chatStarted)
        selectedProjectID = projectID
        selectedSessionID = nil
        persistSelectedProjectPath()
        syncActiveConversationModelToSelection()
    }

    func addSessionToSelectedProject(initialPrompt: PreparedPrompt? = nil) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == selectedProjectID }) else {
            addProjectWithFolderPicker()
            return
        }
        let session = Session(
            name: initialPrompt.map { ChatTitleFormatting.fallback(from: $0.message) } ?? "New Chat",
            status: .idle,
            titleSource: initialPrompt == nil ? .placeholder : .fallback,
            automaticTitleState: .waitingForFirstResponse,
            pendingInitialPrompt: initialPrompt
        )
        projects[projectIndex].sessions.insert(session, at: 0)
        persistProjectSessions(projectIndex: projectIndex)
        selectedSessionID = session.id
        syncActiveConversationModelToSelection()
    }

    func sendNewChatPrompt(_ prompt: PreparedPrompt) {
        guard !prompt.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if canSignInToOutfitter && modelSettings.preferredConversationModel == nil {
            pendingOutfitterPrompt = (prompt, selectedProjectID)
            outfitterSignInStatus = "Connect Outfitter to send your message. Your message is waiting here."
            presentModelSettings()
            return
        }
        if selectedProjectID == nil {
            addStandaloneSession(initialPrompt: prompt)
        } else {
            addSessionToSelectedProject(initialPrompt: prompt)
        }
        analytics.track(.promptSubmitted)
    }

    private func addStandaloneSession(initialPrompt: PreparedPrompt? = nil) {
        let session = Session(
            name: initialPrompt.map { ChatTitleFormatting.fallback(from: $0.message) } ?? "New Chat",
            status: .idle,
            titleSource: initialPrompt == nil ? .placeholder : .fallback,
            automaticTitleState: .waitingForFirstResponse,
            pendingInitialPrompt: initialPrompt
        )
        standaloneSessions.insert(session, at: 0)
        persistStandaloneSessions()
        selectedProjectID = nil
        selectedSessionID = session.id
        syncActiveConversationModelToSelection()
    }

    func addProjectWithFolderPicker() {
        let panel = NSOpenPanel()
        panel.title = "Add Project Folder"
        panel.prompt = "Add Project"
        panel.message = "Choose a folder to bookmark as a Pi project."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        addProject(path: url.path)
    }

    func addProject(path: String) {
        _ = addOrSelectProjectReturningID(path: path)
    }

    @discardableResult
    private func addOrSelectProjectReturningID(path: String) -> Project.ID {
        let projectID = addOrRegisterProjectReturningID(path: path)
        select(projectID: projectID)
        return projectID
    }

    @discardableResult
    private func addOrRegisterProjectReturningID(path: String) -> Project.ID {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if let existingProject = projects.first(where: { $0.path == normalizedPath }) {
            return existingProject.id
        }

        let project = Self.makeProject(path: normalizedPath)
        projects.insert(project, at: 0)
        persistProjectPaths()
        refreshProjectDiffStats(projectID: project.id)
        return project.id
    }

    func refreshSelectedProjectSessions() {
        guard let projectIndex = projects.firstIndex(where: { $0.id == selectedProjectID }) else { return }
        let path = projects[projectIndex].path
        let sessions = Self.mergedSessions(projectPath: path)
        projects[projectIndex].sessions = sessions
        persistProjectSessions(projectIndex: projectIndex)
        selectedSessionID = projects[projectIndex].sessions.first?.id
        syncActiveConversationModelToSelection()
    }

    // MARK: - Pi health and recovery

    func signInToOutfitter(command: PiCommand? = nil) {
        guard !isSigningInToOutfitter else { return }
        guard let invocation = command ?? (canSignInToOutfitter ? PiRPCClient.resolvedPiCommand() : nil) else {
            outfitterSignInStatus = "The configured Outfitter CLI is unavailable."
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = ["login"]
        var environment = ProcessInfo.processInfo.environment
        if let path = invocation.environmentPath { environment["PATH"] = path }
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        // The CLI opens the browser and owns credentials. Never collect or persist
        // its output in the native app's transcript or diagnostics.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.outfitterLoginProcess === finished else { return }
                self.outfitterLoginProcess = nil
                self.isSigningInToOutfitter = false
                if finished.terminationStatus == 0 {
                    self.isConnectedToOutfitter = true
                    self.outfitterSignInStatus = "Signed in. Choose an Outfitter model in a new chat."
                    await self.checkPiHealth()
                    await self.modelSettings.finishPendingCatalogRefresh()
                    await self.refreshModelCatalog(force: true)
                    self.refreshIdleRuntimesAfterOutfitterSignIn()
                    if self.modelSettings.preferredConversationModel == nil,
                       let spark = self.modelSettings.catalog.first(where: { $0.provider == "outfitter" }) {
                        self.modelSettings.setFavorite(true, for: spark)
                    }
                    if let retained = self.pendingOutfitterPrompt, self.modelSettings.preferredConversationModel != nil {
                        if retained.projectID == nil || self.projects.contains(where: { $0.id == retained.projectID }) {
                            self.pendingOutfitterPrompt = nil
                            self.selectedProjectID = retained.projectID
                            self.selectedSessionID = nil
                            self.isSettingsPresented = false
                            self.sendNewChatPrompt(retained.prompt)
                        } else {
                            self.outfitterSignInStatus = "Signed in. Your message is waiting, but its original project is no longer available."
                        }
                    }
                } else {
                    self.outfitterSignInStatus = "Sign-in did not complete. Try again and approve access in your browser."
                }
            }
        }
        outfitterSignInStatus = "Waiting for browser approval…"
        isSigningInToOutfitter = true
        outfitterLoginProcess = process
        do {
            try process.run()
        } catch {
            outfitterLoginProcess = nil
            isSigningInToOutfitter = false
            outfitterSignInStatus = "Outfitter sign-in could not start. Check the configured CLI."
        }
    }

    func cancelOutfitterSignIn() {
        let process = outfitterLoginProcess
        outfitterLoginProcess = nil
        isSigningInToOutfitter = false
        outfitterSignInStatus = "Sign-in cancelled."
        if process?.isRunning == true { process?.terminate() }
    }

    func checkPiHealthIfNeeded() async {
        guard !hasCompletedPiHealthCheck else { return }
        await checkPiHealth()
    }

    func checkPiHealth() async {
        let task: Task<PiHealthCheckResult, Never>
        let generation: UUID
        let startingRevision: Int
        if let existingTask = piHealthCheckTask,
           let existingGeneration = piHealthCheckGeneration,
           let existingStartingRevision = piHealthCheckStartingRevision {
            task = existingTask
            generation = existingGeneration
            startingRevision = existingStartingRevision
        } else {
            generation = UUID()
            startingRevision = piHealthStateRevision
            task = Task { await piHealthCheckOperation() }
            piHealthCheckTask = task
            piHealthCheckGeneration = generation
            piHealthCheckStartingRevision = startingRevision
            isCheckingPiHealth = true
        }

        let result = await task.value
        guard piHealthCheckGeneration == generation else { return }
        isCheckingPiHealth = false
        hasCompletedPiHealthCheck = true
        piHealthCheckTask = nil
        piHealthCheckGeneration = nil
        piHealthCheckStartingRevision = nil
        switch result {
        case .healthy(let command):
            piRecoveryCommand = command
        case .needsAttention(let issue):
            if let command = issue.command { piRecoveryCommand = command }
        }
        guard startingRevision == piHealthStateRevision else {
            if let currentIssue = piHealthIssue,
               currentIssue.command == nil,
               let piRecoveryCommand {
                piHealthIssue = PiHealthIssue(message: currentIssue.message, command: piRecoveryCommand)
            }
            return
        }
        switch result {
        case .healthy:
            piHealthIssue = nil
        case .needsAttention(let issue):
            piHealthIssue = issue
        }
    }

    func openPiInTerminal() async {
        let command = piHealthIssue?.command
        do {
            try await piTerminalRecoveryOperation(command)
            if piHealthIssue != nil {
                piRecoveryRecheckRevision = piHealthStateRevision
            }
        } catch {
            piRecoveryRecheckRevision = nil
            piHealthIssue = PiHealthIssue(
                message: "Terminal could not be opened: \(error.localizedDescription)",
                command: command
            )
        }
    }

    @discardableResult
    func checkPiHealthAfterRecoveryIfNeeded() async -> Bool {
        guard piHealthIssue != nil,
              piRecoveryRecheckRevision == piHealthStateRevision
        else { return false }
        piRecoveryRecheckRevision = nil
        await checkPiHealth()
        return true
    }

    // MARK: - Shell layout actions

    func toggleLeftPane() {
        withAnimation(.easeInOut(duration: 0.24)) {
            isLeftPaneVisible.toggle()
        }
    }

    func presentSettings(section: SettingsSection = .general) {
        analytics.track(.settingsOpened)
        settingsSection = section
        isSettingsPresented = true
    }

    func presentModelSettings() {
        presentSettings(section: .models)
    }

    func startActiveConversationIfNeeded() {
        guard selectedSessionID != nil, automaticallyStartsPendingRuntimes else { return }
        activeConversationModel?.startProcessIfNeeded()
    }

    @discardableResult
    func interruptSelectedConversation() -> Bool {
        guard selectedSessionID != nil else { return false }
        return activeConversationModel?.interruptActiveTurn() ?? false
    }

    func refreshModelCatalog(force: Bool = false) async {
        let workingDirectory = URL(
            fileURLWithPath: ((selectedProject?.path ?? NSHomeDirectory()) as NSString).expandingTildeInPath,
            isDirectory: true
        )
        if let modelCatalogLoaderOverride {
            if force {
                await modelSettings.refreshCatalog(loadModels: modelCatalogLoaderOverride)
            } else {
                await modelSettings.refreshCatalogIfNeeded(loadModels: modelCatalogLoaderOverride)
            }
            hydrateActiveConversationModelFromCatalog()
            return
        }

        let loader = {
            try await Self.loadModelCatalogFromPi(workingDirectory: workingDirectory)
        }
        if force {
            await modelSettings.refreshProvisionalCatalog(loadModels: loader)
        } else {
            await modelSettings.refreshProvisionalCatalogIfNeeded(loadModels: loader)
        }
        hydrateActiveConversationModelFromCatalog()
    }

    private func hydrateActiveConversationModelFromCatalog() {
        if modelSettings.catalog.contains(where: { $0.provider == "outfitter" }) {
            isConnectedToOutfitter = true
        }
        guard let activeConversationModel else { return }
        if let currentModel = activeConversationModel.currentModel,
           let hydratedModel = modelSettings.catalog.first(where: { $0.stableID == currentModel.stableID }) {
            activeConversationModel.currentModel = hydratedModel
        } else if activeConversationModel.currentModel == nil,
                  let preferredModel = modelSettings.preferredConversationModel {
            activeConversationModel.currentModel = preferredModel
        }

        guard activeConversationModel.currentModel != nil else {
            activeConversationModel.currentThinkingLevel = nil
            return
        }
        if activeConversationModel.currentThinkingLevel == nil {
            let levels = activeConversationModel.availableThinkingLevels
            activeConversationModel.currentThinkingLevel = levels.contains(.medium) ? .medium : levels.first
        }
    }

    private static func loadModelCatalogFromPi(workingDirectory: URL) async throws -> [PiModelOption] {
        let testCapturePath = ProcessInfo.processInfo.environment["PI_NATIVE_TEST_MODEL_CATALOG_CAPTURE_FILE"]
        let client = PiRPCClient(workingDirectory: workingDirectory, disablesTools: true)
        try await client.start()
        defer { Task { await client.stop() } }

        let response = try await client.getAvailableModels(timeoutSeconds: 30)
        guard let models = response.data?.objectValue?["models"]?.arrayValue else {
            throw ModelCatalogCommandError(message: "Pi model catalog response did not include models.")
        }
        let parsedModels = models.compactMap { PiModelOption(json: $0) }
        if let testCapturePath,
           let data = try? JSONEncoder().encode(parsedModels) {
            try? data.write(to: URL(fileURLWithPath: testCapturePath), options: .atomic)
        }
        return parsedModels
    }

    nonisolated private static func parseModelListOutput(_ output: String) -> [PiModelOption] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 6,
                  columns[0] != "provider",
                  ["yes", "no"].contains(String(columns[4])),
                  ["yes", "no"].contains(String(columns[5]))
            else { return nil }
            let provider = String(columns[0])
            let modelID = String(columns[1])
            return PiModelOption(provider: provider, id: modelID, name: modelID)
        }
    }

    static func ensureProjectFolderExists(at path: String, fileManager: FileManager = .default) {
        let expandedPath = expandedProjectFolderPath(path)
        guard expandedPath.hasPrefix("/") else { return }
        try? fileManager.createDirectory(atPath: expandedPath, withIntermediateDirectories: true)
    }

    private static func expandedProjectFolderPath(_ path: String) -> String {
        if path == "~" || path.hasPrefix("~/"),
           let testHome = ProcessInfo.processInfo.environment["PI_NATIVE_TEST_HOME"],
           !testHome.isEmpty {
            let suffix = path == "~" ? "" : String(path.dropFirst(2))
            return URL(fileURLWithPath: testHome).appendingPathComponent(suffix).standardizedFileURL.path
        }
        return (path as NSString).expandingTildeInPath
    }

    private static func loadPromoteOptions(defaults: UserDefaults) -> PromoteToProjectOptions {
        PromoteToProjectOptions(
            initializeGitRepo: defaults.object(forKey: promoteInitializeGitRepoKey) as? Bool ?? true,
            seedProjectMemory: defaults.object(forKey: promoteSeedProjectMemoryKey) as? Bool ?? true,
            addAgentInstructions: defaults.object(forKey: promoteAddAgentInstructionsKey) as? Bool ?? true
        )
    }

    private static func storePromoteOptions(_ options: PromoteToProjectOptions) {
        let defaults = UserDefaults.standard
        defaults.set(options.initializeGitRepo, forKey: promoteInitializeGitRepoKey)
        defaults.set(options.seedProjectMemory, forKey: promoteSeedProjectMemoryKey)
        defaults.set(options.addAgentInstructions, forKey: promoteAddAgentInstructionsKey)
    }

    private static func applyAppKitAppearance(_ appearance: AppAppearance) {
        switch appearance {
        case .system:
            NSApplication.shared.appearance = nil
        case .light:
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
        for window in NSApplication.shared.windows {
            window.backgroundColor = ShellPalette.chromeNSColor
        }
    }

    func toggleRightPane() {
        withAnimation(.easeInOut(duration: 0.24)) {
            isRightPaneOpen.toggle()
        }
    }

    /// Opens the right pane directly to a specific mode.
    func openRightPane(_ mode: RightPaneMode) {
        withAnimation(.easeInOut(duration: 0.24)) {
            isRightPaneOpen = true
        }
        selectRightPaneMode(mode)
    }

    /// "Show Pending Changes" context-menu action: always *opens* the diff pane
    /// for the chat's project (unlike the sidebar pill, which toggles). This
    /// deliberately does not switch the selected conversation; doing that from
    /// a row context-menu action can tear down/reload the active chat while the
    /// menu is dismissing, which is a plausible crash path.
    func showPendingChanges(projectID: Project.ID) {
        reviewProjectID = projectID
        openRightPane(.review)
    }

    func setSessionPinned(_ isPinned: Bool, sessionID: Session.ID, in projectID: Project.ID?) {
        if let projectID,
           let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
           let sessionIndex = projects[projectIndex].sessions.firstIndex(where: { $0.id == sessionID }) {
            projects[projectIndex].sessions[sessionIndex].isPinned = isPinned
            persistProjectSessions(projectIndex: projectIndex)
        } else if let sessionIndex = standaloneSessions.firstIndex(where: { $0.id == sessionID }) {
            standaloneSessions[sessionIndex].isPinned = isPinned
            persistStandaloneSessions()
        }
    }

    /// Entry point for the Plan → Project / Promote to Project feature.
    /// Currently presents the placeholder modal; the real promotion flow
    /// will replace the modal's contents.
    func presentPromoteToProject(session: Session) {
        promoteCandidateSession = session
    }

    func completePromotion(projectPath: String) -> Project.ID {
        let promotedSession = promoteCandidateSession
        activeConversationModel?.stop()
        activeConversationModel = nil
        activeConversationIsRunning = false
        let projectID = addOrRegisterProjectReturningID(path: projectPath)
        selectedProjectID = projectID
        persistSelectedProjectPath()
        addSessionToSelectedProject(initialPrompt: Self.promotedProjectInitialPrompt(sourceSession: promotedSession, projectPath: projectPath))
        if let promotedSession {
            archivePromotedStandaloneSession(id: promotedSession.id)
        }
        promoteCandidateSession = nil
        return projectID
    }

    private func archivePromotedStandaloneSession(id sessionID: Session.ID) {
        cleanupRuntime(for: ConversationKey(projectID: nil, sessionID: sessionID))
        guard let sessionIndex = standaloneSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        standaloneSessions[sessionIndex].isArchived = true
        persistStandaloneSessions()
    }

    private static func promotedProjectInitialPrompt(sourceSession: Session?, projectPath: String) -> PreparedPrompt {
        let sourceName = sourceSession?.name ?? "the planning chat"
        let transcriptContext = sourceSession.map(promotedTranscriptContext) ?? "No cached transcript was available at handoff time."
        let message = """
        This project was just promoted from the Quick Chat planning conversation “\(sourceName)”. The promoted project is scoped to this folder:
        \(URL(fileURLWithPath: projectPath).standardizedFileURL.path)

        Start from the promoted planning context below. Also use `promoted-chat.md` in the project root as the durable provenance copy of the source chat.

        \(transcriptContext)
        """
        return PreparedPrompt(message: message, images: [], displayAttachments: [])
    }

    private static func promotedTranscriptContext(_ session: Session) -> String {
        guard !session.cachedTranscript.isEmpty else {
            return "No cached transcript was available at handoff time."
        }
        let lines = session.cachedTranscript.map { item -> String in
            switch item {
            case .user(_, let payload):
                let text = payload.text.isEmpty ? "(No text)" : payload.text
                return "User: \(text)"
            case .assistantText(_, let text):
                return "Assistant: \(text)"
            case .activity(let group):
                let names = group.tools.map(\.name).joined(separator: ", ")
                return "Activity: \(names)"
            case .notice(_, let text):
                return "Notice: \(text)"
            }
        }
        return lines.joined(separator: "\n")
    }

    func revealProjectInFinder(projectID: Project.ID) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
    }

    func toggleProjectDiffPane(projectID: Project.ID) {
        reviewProjectID = projectID
        select(projectID: projectID)
        if isRightPaneOpen && rightPaneMode == .review {
            toggleRightPane()
        } else {
            openRightPane(.review)
        }
    }

    /// The only place `rightPaneMode` should be set to `.browser` — ensures
    /// `browserModel` exists *before* `rightPaneMode` changes and
    /// `RightPaneView` re-renders, rather than lazily creating (and
    /// publishing) it from inside that view's `body`. Found by adversarial
    /// review.
    func selectRightPaneMode(_ mode: RightPaneMode) {
        if mode == .browser {
            browserModelInstance()
        } else if mode == .review {
            diffModelInstance()
        }
        rightPaneMode = mode
        analytics.track(.rightPaneOpened(mode))
    }

    private func canChangeConversationSelection() -> Bool {
        guard activeConversationModel?.blocksConversationSelection == true else { return true }
        NSSound.beep()
        blockedNavigationAlert = BlockedNavigationAlert(
            title: "Response in progress",
            message: "Wait for Pi to finish, or press Stop, before switching chats or starting a new chat."
        )
        return false
    }

    // MARK: - Conversation runtime lifecycle

    private func syncActiveConversationModelToSelection() {
        guard let key = selectedConversationKey else {
            activeConversationModel = nil
            activeConversationIsRunning = false
            return
        }
        let model = ensureRuntime(for: key).model
        activeConversationModel = model
        activeConversationIsRunning = model.isRunning
    }

    @discardableResult
    private func ensureRuntime(for key: ConversationKey) -> ConversationRuntime {
        if let runtime = conversationRuntimes[key] {
            conversationRuntimeStates[key, default: ConversationRuntimeState()].lastUsedAt = .now
            if !runtime.model.blocksConversationSelection {
                configure(runtime: runtime)
            }
            return runtime
        }

        let model = conversationModelFactory(modelSettings)
        let runtime = ConversationRuntime(key: key, model: model)
        conversationRuntimes[key] = runtime
        conversationRuntimeStates[key] = ConversationRuntimeState()
        configure(runtime: runtime)
        installRuntimeCallbacks(for: runtime)
        installRuntimeStateSubscriptions(for: runtime)
        consumeInterruptedTitleAttempt(for: runtime.key)
        let session = session(for: key)
        let needsLiveStartup = session?.pendingInitialPrompt != nil || (session?.filePath?.isEmpty == false && session?.cachedTranscript.isEmpty == true)
        if automaticallyStartsPendingRuntimes, needsLiveStartup {
            model.startProcessIfNeeded()
        }
        return runtime
    }

    private func configure(runtime: ConversationRuntime) {
        let key = runtime.key
        let session = session(for: key)
        let workingDirectory = project(for: key.projectID)?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        runtime.model.configureSession(
            workingDirectory: workingDirectory,
            sessionPath: session?.filePath,
            initialPrompt: session?.pendingInitialPrompt,
            cachedItems: session?.cachedTranscript ?? [],
            planningMode: key.projectID == nil
        )
        updateRuntimeState(for: key)
    }

    private func installRuntimeCallbacks(for runtime: ConversationRuntime) {
        let key = runtime.key
        runtime.model.onSessionPathResolved = { [weak self, key] sessionPath in
            self?.resolveSessionPath(sessionPath, projectID: key.projectID, sessionID: key.sessionID)
        }
        runtime.model.onUserMessageSent = { [weak self, key] message in
            self?.updateSessionSummary(from: message, projectID: key.projectID, sessionID: key.sessionID)
        }
        runtime.model.onPromptSubmitted = { [weak self] in
            self?.analytics.track(.promptSubmitted)
        }
        runtime.model.onPiLoadFailed = { [weak self, key] failure in
            self?.analytics.track(.piLoadFailed(failure, isProjectChat: key.projectID != nil))
        }
        runtime.model.onHandledPiOperationFailure = { [weak self] failure in
            self?.analytics.track(.handledException(failure))
        }
        runtime.model.onInteractiveAttention = { [weak self] message in
            guard let self else { return }
            self.piHealthStateRevision += 1
            self.piHealthIssue = PiHealthIssue(message: message, command: self.piRecoveryCommand)
        }
        runtime.model.onItemsChanged = { [weak self, key] items in
            self?.updateSessionTranscript(items, projectID: key.projectID, sessionID: key.sessionID)
        }
        runtime.model.onAgentSettled = { [weak self, weak runtime] items in
            guard let self, let runtime else { return }
            self.handleFirstAgentSettled(items, for: runtime)
        }
        runtime.model.onAgentRunAbandoned = { [weak self, key] in
            self?.abandonAutomaticTitle(for: key)
        }
    }

    private func installRuntimeStateSubscriptions(for runtime: ConversationRuntime) {
        let key = runtime.key
        runtime.model.$isRunning
            .removeDuplicates()
            .sink { [weak self] isRunning in self?.updateRuntimeState(for: key, isRunning: isRunning) }
            .store(in: &runtime.stateCancellables)
        runtime.model.$isLoadingSession
            .removeDuplicates()
            .sink { [weak self] isLoadingSession in self?.updateRuntimeState(for: key, isLoadingSession: isLoadingSession) }
            .store(in: &runtime.stateCancellables)
        runtime.model.$errorMessage
            .removeDuplicates()
            .sink { [weak self] errorMessage in self?.updateRuntimeState(for: key, lastErrorSummary: errorMessage) }
            .store(in: &runtime.stateCancellables)
    }

    private func updateRuntimeState(
        for key: ConversationKey,
        isRunning: Bool? = nil,
        isLoadingSession: Bool? = nil,
        lastErrorSummary: String? = nil
    ) {
        guard let runtime = conversationRuntimes[key] else { return }
        let previous = conversationRuntimeStates[key]
        let nextIsRunning = isRunning ?? runtime.model.isRunning
        conversationRuntimeStates[key] = ConversationRuntimeState(
            isRunning: nextIsRunning,
            isLoadingSession: isLoadingSession ?? runtime.model.isLoadingSession,
            hasPendingPrompt: runtime.model.hasPendingPrompt,
            isProcessStarted: runtime.model.isProcessStarted,
            lastUsedAt: previous?.lastUsedAt ?? .now,
            lastErrorSummary: lastErrorSummary ?? runtime.model.errorMessage
        )
        if key == selectedConversationKey {
            activeConversationIsRunning = nextIsRunning
        }
    }

    func stopAllRuntimes() {
        cancelOutfitterSignIn()
        let runtimes = Array(conversationRuntimes.values)
        conversationRuntimes.removeAll()
        conversationRuntimeStates.removeAll()
        for runtime in runtimes {
            finishAutomaticTitleAttempt(for: runtime.key)
            runtime.titleTask?.cancel()
            runtime.stateCancellables.removeAll()
            runtime.model.stop()
        }
        activeConversationModel = nil
        activeConversationIsRunning = false
    }

    private func refreshIdleRuntimesAfterOutfitterSignIn() {
        // Outfitter projects credentials when a chat process starts. Keep the
        // conversation and its draft, but discard pre-login process snapshots.
        var restartActive = false
        for (key, runtime) in conversationRuntimes {
            guard !runtime.model.blocksConversationSelection,
                  !runtime.model.isLoadingSession else { continue }
            runtime.model.stop()
            if key == selectedConversationKey { restartActive = true }
        }
        if restartActive { startActiveConversationIfNeeded() }
    }

    private func cleanupRuntime(for key: ConversationKey) {
        guard let runtime = conversationRuntimes.removeValue(forKey: key) else {
            conversationRuntimeStates.removeValue(forKey: key)
            return
        }
        finishAutomaticTitleAttempt(for: key)
        runtime.titleTask?.cancel()
        runtime.stateCancellables.removeAll()
        runtime.model.stop()
        conversationRuntimeStates.removeValue(forKey: key)
        if key == selectedConversationKey {
            activeConversationModel = nil
            activeConversationIsRunning = false
        }
    }

    private func project(for projectID: Project.ID?) -> Project? {
        guard let projectID else { return nil }
        return projects.first { $0.id == projectID }
    }

    private func session(for key: ConversationKey) -> Session? {
        if let projectID = key.projectID {
            return projects.first { $0.id == projectID }?.sessions.first { $0.id == key.sessionID }
        }
        return standaloneSessions.first { $0.id == key.sessionID }
    }

    private func updateSessionSummary(from message: String, projectID: Project.ID?, sessionID: Session.ID) {
        if let projectID,
           let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
           let sessionIndex = projects[projectIndex].sessions.firstIndex(where: { $0.id == sessionID }) {
            if projects[projectIndex].sessions[sessionIndex].automaticTitleState == .waitingForFirstResponse,
               projects[projectIndex].sessions[sessionIndex].titleSource == .placeholder {
                projects[projectIndex].sessions[sessionIndex].name = ChatTitleFormatting.fallback(from: message)
                projects[projectIndex].sessions[sessionIndex].titleSource = .fallback
            }
            projects[projectIndex].sessions[sessionIndex].updatedAt = .now
            projects[projectIndex].sessions[sessionIndex].pendingInitialPrompt = nil
            persistProjectSessions(projectIndex: projectIndex)
        } else if projectID == nil,
                  let sessionIndex = standaloneSessions.firstIndex(where: { $0.id == sessionID }) {
            if standaloneSessions[sessionIndex].automaticTitleState == .waitingForFirstResponse,
               standaloneSessions[sessionIndex].titleSource == .placeholder {
                standaloneSessions[sessionIndex].name = ChatTitleFormatting.fallback(from: message)
                standaloneSessions[sessionIndex].titleSource = .fallback
            }
            standaloneSessions[sessionIndex].updatedAt = .now
            standaloneSessions[sessionIndex].pendingInitialPrompt = nil
            persistStandaloneSessions()
        }
    }

    private func handleFirstAgentSettled(_ items: [TranscriptItem], for runtime: ConversationRuntime) {
        guard session(for: runtime.key)?.automaticTitleState == .waitingForFirstResponse,
              let snapshot = Self.firstExchangeSnapshot(from: items)
        else { return }

        startTitleGeneration(snapshot: snapshot, for: runtime)
    }

    private func abandonAutomaticTitle(for key: ConversationKey) {
        guard let state = session(for: key)?.automaticTitleState else { return }
        switch state {
        case .waitingForFirstResponse:
            setAutomaticTitleState(.complete, for: key)
        case .pending:
            setAutomaticTitleState(.complete, for: key)
            conversationRuntimes[key]?.titleTask?.cancel()
        case .ineligible, .complete:
            return
        }
    }

    private static func firstExchangeSnapshot(from items: [TranscriptItem]) -> FirstExchangeSnapshot? {
        var userPrompt: String?
        var assistantParts: [String] = []
        for item in items {
            switch item {
            case .user(_, let payload):
                if let userPrompt {
                    return FirstExchangeSnapshot(userPrompt: userPrompt, assistantText: assistantParts.joined(separator: "\n\n"))
                }
                guard !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                userPrompt = payload.text
            case .assistantText(_, let text):
                if userPrompt != nil, !text.isEmpty { assistantParts.append(text) }
            case .activity, .notice:
                continue
            }
        }
        guard let userPrompt else { return nil }
        return FirstExchangeSnapshot(userPrompt: userPrompt, assistantText: assistantParts.joined(separator: "\n\n"))
    }

    private func consumeInterruptedTitleAttempt(for key: ConversationKey) {
        finishAutomaticTitleAttempt(for: key)
    }

    private func startTitleGeneration(snapshot: FirstExchangeSnapshot, for runtime: ConversationRuntime) {
        guard runtime.titleTask == nil,
              session(for: runtime.key)?.automaticTitleState == .waitingForFirstResponse
        else { return }
        let key = runtime.key
        let workingDirectory = project(for: key.projectID)?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        setAutomaticTitleState(.pending(snapshot), for: key)

        runtime.titleTask = Task { [weak self, weak runtime] in
            guard let self, let runtime else { return }
            defer {
                runtime.titleTask = nil
                finishAutomaticTitleAttempt(snapshotID: snapshot.id, for: key)
            }
            do {
                if let authoritativeName = await runtime.model.fetchSessionName() {
                    acceptAuthoritativeTitle(authoritativeName, snapshotID: snapshot.id, for: key)
                    return
                }
                try Task.checkCancellation()
                let output = try await chatTitleGenerator.generateTitle(for: snapshot, workingDirectory: workingDirectory)
                try Task.checkCancellation()
                if let authoritativeName = await runtime.model.fetchSessionName() {
                    acceptAuthoritativeTitle(authoritativeName, snapshotID: snapshot.id, for: key)
                    return
                }
                guard let title = ChatTitleFormatting.semanticTitle(from: output, firstUserPrompt: snapshot.userPrompt) else { return }
                acceptGeneratedTitle(title, snapshotID: snapshot.id, for: key)
            } catch {
                // The deterministic fallback remains visible and the deferred
                // transition permanently consumes this chat's title attempt.
            }
        }
    }

    #if DEBUG
    func waitForAutomaticTitleAttemptForTesting(sessionID: Session.ID, projectID: Project.ID? = nil) async -> Bool {
        let key = ConversationKey(projectID: projectID, sessionID: sessionID)
        guard let task = conversationRuntimes[key]?.titleTask else { return false }
        await task.value
        return true
    }
    #endif

    private func finishAutomaticTitleAttempt(snapshotID: UUID? = nil, for key: ConversationKey) {
        guard case .pending(let snapshot)? = session(for: key)?.automaticTitleState,
              snapshotID == nil || snapshot.id == snapshotID
        else { return }
        setAutomaticTitleState(.complete, for: key)
    }

    private func setAutomaticTitleState(_ state: AutomaticTitleState, for key: ConversationKey) {
        if let projectID = key.projectID,
           let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
           let sessionIndex = projects[projectIndex].sessions.firstIndex(where: { $0.id == key.sessionID }) {
            projects[projectIndex].sessions[sessionIndex].automaticTitleState = state
            persistProjectSessions(projectIndex: projectIndex)
        } else if key.projectID == nil,
                  let sessionIndex = standaloneSessions.firstIndex(where: { $0.id == key.sessionID }) {
            standaloneSessions[sessionIndex].automaticTitleState = state
            persistStandaloneSessions()
        }
    }

    private func acceptAuthoritativeTitle(_ title: String, snapshotID: UUID, for key: ConversationKey) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if let projectID = key.projectID,
           let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
           let sessionIndex = projects[projectIndex].sessions.firstIndex(where: { $0.id == key.sessionID }),
           case .pending(let snapshot) = projects[projectIndex].sessions[sessionIndex].automaticTitleState,
           snapshot.id == snapshotID {
            projects[projectIndex].sessions[sessionIndex].name = title
            projects[projectIndex].sessions[sessionIndex].titleSource = .authoritative
            projects[projectIndex].sessions[sessionIndex].automaticTitleState = .complete
            persistProjectSessions(projectIndex: projectIndex)
        } else if key.projectID == nil,
                  let sessionIndex = standaloneSessions.firstIndex(where: { $0.id == key.sessionID }),
                  case .pending(let snapshot) = standaloneSessions[sessionIndex].automaticTitleState,
                  snapshot.id == snapshotID {
            standaloneSessions[sessionIndex].name = title
            standaloneSessions[sessionIndex].titleSource = .authoritative
            standaloneSessions[sessionIndex].automaticTitleState = .complete
            persistStandaloneSessions()
        }
    }

    private func acceptGeneratedTitle(_ title: String, snapshotID: UUID, for key: ConversationKey) {
        if let projectID = key.projectID,
           let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
           let sessionIndex = projects[projectIndex].sessions.firstIndex(where: { $0.id == key.sessionID }),
           case .pending(let snapshot) = projects[projectIndex].sessions[sessionIndex].automaticTitleState,
           snapshot.id == snapshotID,
           (projects[projectIndex].sessions[sessionIndex].titleSource != .authoritative || projects[projectIndex].sessions[sessionIndex].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            projects[projectIndex].sessions[sessionIndex].name = title
            projects[projectIndex].sessions[sessionIndex].titleSource = .generated
            projects[projectIndex].sessions[sessionIndex].automaticTitleState = .complete
            persistProjectSessions(projectIndex: projectIndex)
        } else if key.projectID == nil,
                  let sessionIndex = standaloneSessions.firstIndex(where: { $0.id == key.sessionID }),
                  case .pending(let snapshot) = standaloneSessions[sessionIndex].automaticTitleState,
                  snapshot.id == snapshotID,
                  (standaloneSessions[sessionIndex].titleSource != .authoritative || standaloneSessions[sessionIndex].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            standaloneSessions[sessionIndex].name = title
            standaloneSessions[sessionIndex].titleSource = .generated
            standaloneSessions[sessionIndex].automaticTitleState = .complete
            persistStandaloneSessions()
        } else {
            return
        }
        conversationRuntimes[key]?.model.syncSessionName(title)
    }

    private func updateSessionTranscript(_ items: [TranscriptItem], projectID: Project.ID?, sessionID: Session.ID) {
        let persistableItems = Self.persistableTranscriptItems(from: items)
        if let projectID,
           let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
           let sessionIndex = projects[projectIndex].sessions.firstIndex(where: { $0.id == sessionID }) {
            let transcriptChanged = projects[projectIndex].sessions[sessionIndex].cachedTranscript != persistableItems
            projects[projectIndex].sessions[sessionIndex].cachedTranscript = persistableItems
            projects[projectIndex].sessions[sessionIndex].messageCount = persistableItems.count
            if transcriptChanged {
                projects[projectIndex].sessions[sessionIndex].updatedAt = .now
            }
            persistProjectSessions(projectIndex: projectIndex)
        } else if projectID == nil,
                  let sessionIndex = standaloneSessions.firstIndex(where: { $0.id == sessionID }) {
            let transcriptChanged = standaloneSessions[sessionIndex].cachedTranscript != persistableItems
            standaloneSessions[sessionIndex].cachedTranscript = persistableItems
            standaloneSessions[sessionIndex].messageCount = persistableItems.count
            if transcriptChanged {
                standaloneSessions[sessionIndex].updatedAt = .now
            }
            persistStandaloneSessions()
        }
    }

    private static func persistableTranscriptItems(from items: [TranscriptItem]) -> [TranscriptItem] {
        items.filter { item in
            guard case .notice(_, let text) = item else { return true }
            return !text.hasPrefix("Failed to load session:")
                && !text.hasPrefix("Failed to start pi:")
                && !text.hasPrefix("Failed to start pi RPC:")
        }
    }

    private func resolveSessionPath(_ sessionPath: String, projectID: Project.ID?, sessionID: Session.ID) {
        let parsedSession = Self.parsePiSession(fileURL: URL(fileURLWithPath: sessionPath))
        if let projectID,
           let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
           let sessionIndex = projects[projectIndex].sessions.firstIndex(where: { $0.id == sessionID }) {
            projects[projectIndex].sessions[sessionIndex].filePath = sessionPath
            projects[projectIndex].sessions[sessionIndex].updatedAt = parsedSession?.updatedAt ?? .now
            projects[projectIndex].sessions[sessionIndex].messageCount = parsedSession?.messageCount ?? projects[projectIndex].sessions[sessionIndex].messageCount
            if let parsedSession, projects[projectIndex].sessions[sessionIndex].name == "New Session" {
                projects[projectIndex].sessions[sessionIndex].name = parsedSession.name
            }
            persistProjectSessions(projectIndex: projectIndex)
        } else if projectID == nil,
                  let sessionIndex = standaloneSessions.firstIndex(where: { $0.id == sessionID }) {
            standaloneSessions[sessionIndex].filePath = sessionPath
            standaloneSessions[sessionIndex].updatedAt = parsedSession?.updatedAt ?? .now
            standaloneSessions[sessionIndex].messageCount = parsedSession?.messageCount ?? standaloneSessions[sessionIndex].messageCount
            if let parsedSession, standaloneSessions[sessionIndex].name == "New Session" {
                standaloneSessions[sessionIndex].name = parsedSession.name
            }
            persistStandaloneSessions()
        }
    }

    func refreshProjectDiffStats(projectID: Project.ID? = nil) {
        if let testStats = Self.testDiffStatsFromEnvironment() {
            for index in projects.indices where projectID == nil || projects[index].id == projectID {
                projects[index].diffStats = testStats
            }
            return
        }

        let targets = projects.filter { projectID == nil || $0.id == projectID }
        for project in targets {
            Task { [path = project.path, id = project.id] in
                let stats = await Self.gitDiffStats(projectPath: path)
                guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
                projects[index].diffStats = stats
            }
        }
    }

    private static func testCachedTranscript(title: String, environment: [String: String]) -> [TranscriptItem] {
        if environment["PI_NATIVE_TEST_EMPTY_SEEDED_TRANSCRIPT"] == "1" {
            return []
        }
        if environment["PI_NATIVE_TEST_CHAT_FORMATTING_FIXTURE"] == "1" {
            let markdown = """
            # Markdown that reads naturally

            Assistant prose supports *emphasis*, **strong emphasis**, [helpful links](https://example.com), and `inline code`.

            - Clear unordered item
            - A second item with enough text to demonstrate comfortable wrapping in the readable transcript column

            1. First ordered step
            2. Second ordered step

            > Quoted guidance stays visually distinct from the surrounding answer.

            ```swift
            let greeting = "Hello from PiNative"
            print(greeting)
            ```
            """
            let tools = [
                ToolTranscriptItem(id: UUID(), callID: "format-read", name: "read", args: #"{"path":"PiNative/PiConversationView.swift"}"#, output: "", status: .succeeded),
                ToolTranscriptItem(id: UUID(), callID: "format-edit", name: "edit", args: #"{"path":"PiNative/ChatMarkdownParser.swift"}"#, output: "", status: .succeeded),
                ToolTranscriptItem(id: UUID(), callID: "format-test", name: "bash", args: #"{"command":"swift test"}"#, output: "", status: .succeeded)
            ]
            return [
                .user(UserMessagePayload(text: title)),
                .assistantText(text: markdown),
                .assistantText(text: "**Streaming emphasis remains readable"),
                .activity(ActivityGroup(id: UUID(), tools: tools, isRunning: false, startedAt: Date(), finishedAt: Date()))
            ]
        }
        guard environment["PI_NATIVE_TEST_LONG_TRANSCRIPT"] == "1" else {
            return [.user(UserMessagePayload(text: title))]
        }
        var items: [TranscriptItem] = (1...36).map { index in
            .user(UserMessagePayload(text: "Older transcript line \(index) for \(title)"))
        }
        items.append(.assistantText(text: "Latest restored content for \(title)"))
        return items
    }

    private static func testDiffStatsFromEnvironment() -> DiffStats? {
        guard let rawValue = ProcessInfo.processInfo.environment["PI_NATIVE_TEST_DIFF_STATS"] else { return nil }
        let parts = rawValue.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return nil }
        return DiffStats(additions: parts[0], deletions: parts[1])
    }

    private func persistProjectPaths() {
        UserDefaults.standard.set(projects.map(\.path), forKey: Self.projectPathsKey)
    }

    private func persistSelectedProjectPath() {
        if let path = selectedProject?.path {
            UserDefaults.standard.set(path, forKey: Self.selectedProjectPathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedProjectPathKey)
        }
    }

    private func persistStandaloneSessions() {
        let sessions = standaloneSessions.map(PersistedSession.init(session:))
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: Self.standaloneSessionsKey)
        }
    }

    private func persistProjectSessions(projectIndex: Int) {
        let project = projects[projectIndex]
        let sessions = project.sessions.map(PersistedSession.init(session:))
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: Self.projectSessionsKey(for: project.path))
        }
    }

    private static func sanitizedProject(_ project: Project) -> Project {
        var project = project
        project.sessions = project.sessions.map(sanitizedSession)
        return project
    }

    private static func sanitizedSession(_ session: Session) -> Session {
        var session = session
        session.cachedTranscript = persistableTranscriptItems(from: session.cachedTranscript)
        session.messageCount = max(session.messageCount, session.cachedTranscript.count)
        return session
    }

    private static func makeProject(path: String) -> Project {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let sessions = mergedSessions(projectPath: normalizedPath)
        return Project(
            name: URL(fileURLWithPath: normalizedPath).lastPathComponent,
            path: normalizedPath,
            sessions: sessions,
            diffStats: nil
        )
    }

    private static func gitDiffStats(projectPath: String) async -> DiffStats? {
        await Task.detached {
            func runGit(_ arguments: [String]) -> String? {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-C", projectPath] + arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do { try process.run() } catch { return nil }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8)
            }

            func addNumstat(_ output: String?, additions: inout Int, deletions: inout Int) {
                guard let output else { return }
                for line in output.split(separator: "\n") {
                    let parts = line.split(separator: "\t")
                    guard parts.count >= 2 else { continue }
                    additions += Int(parts[0]) ?? 0
                    deletions += Int(parts[1]) ?? 0
                }
            }

            var additions = 0
            var deletions = 0
            addNumstat(runGit(["diff", "--numstat"]), additions: &additions, deletions: &deletions)
            addNumstat(runGit(["diff", "--cached", "--numstat"]), additions: &additions, deletions: &deletions)

            if let untrackedOutput = runGit(["ls-files", "--others", "--exclude-standard"]) {
                for relativePath in untrackedOutput.split(separator: "\n") {
                    let fileURL = URL(fileURLWithPath: projectPath).appendingPathComponent(String(relativePath))
                    guard let data = try? Data(contentsOf: fileURL),
                          let text = String(data: data, encoding: .utf8)
                    else {
                        additions += 1
                        continue
                    }
                    additions += max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)
                }
            }

            return additions == 0 && deletions == 0 ? nil : DiffStats(additions: additions, deletions: deletions)
        }.value
    }

    private static func normalizedUniqueProjectPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { path in
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard normalized != "/" else { return nil }
            guard !seen.contains(normalized) else { return nil }
            seen.insert(normalized)
            return normalized
        }
    }

    private static func projectSessionsKey(for projectPath: String) -> String {
        projectSessionsKeyPrefix + projectPath
    }

    private static func mergedSessions(projectPath: String) -> [Session] {
        let diskSessions = loadPiSessions(projectPath: projectPath)
        let persistedSessions = loadPersistedSessions(projectPath: projectPath)
        var usedFilePaths = Set<String>()
        var merged: [Session] = []

        for persisted in persistedSessions {
            if let filePath = persisted.filePath,
               let disk = diskSessions.first(where: { $0.filePath == filePath }) {
                usedFilePaths.insert(filePath)
                let usesAuthoritativeDiskTitle = disk.titleSource == .authoritative
                    && !(persisted.titleSource == .generated && disk.name == persisted.name)
                merged.append(Session(
                    id: persisted.id,
                    name: usesAuthoritativeDiskTitle ? disk.name : persisted.name,
                    status: .idle,
                    filePath: disk.filePath,
                    updatedAt: disk.updatedAt,
                    messageCount: max(disk.messageCount, persisted.cachedTranscript.count),
                    titleSource: usesAuthoritativeDiskTitle ? .authoritative : persisted.titleSource,
                    automaticTitleState: usesAuthoritativeDiskTitle ? .complete : persisted.automaticTitleState,
                    isArchived: persisted.isArchived,
                    isPinned: persisted.isPinned,
                    cachedTranscript: persisted.cachedTranscript
                ))
            } else {
                merged.append(persisted.session)
            }
        }

        merged.append(contentsOf: diskSessions.filter { session in
            guard let filePath = session.filePath else { return true }
            return !usedFilePaths.contains(filePath)
        })

        return merged.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func loadPersistedSessions(projectPath: String) -> [PersistedSession] {
        guard let data = UserDefaults.standard.data(forKey: projectSessionsKey(for: projectPath)),
              let sessions = try? JSONDecoder().decode([PersistedSession].self, from: data)
        else { return [] }
        return sessions
    }

    private static func loadStandaloneSessions() -> [Session] {
        guard let data = UserDefaults.standard.data(forKey: standaloneSessionsKey),
              let sessions = try? JSONDecoder().decode([PersistedSession].self, from: data)
        else { return [] }
        return sessions.map(\.session).sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func loadPiSessions(projectPath: String) -> [Session] {
        let sessionDirectory = piSessionDirectory(for: projectPath)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "jsonl" }
            .compactMap(parsePiSession)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func piSessionDirectory(for projectPath: String) -> URL {
        // Pi's session directory encoding drops the leading slash before
        // replacing path separators with dashes: `/Users/example/repo` becomes
        // `--Users-example-repo--`, not `---Users-example-repo--`.
        let trimmedPath = projectPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedPath = trimmedPath.replacingOccurrences(of: "/", with: "-")
        let homeDirectory = ProcessInfo.processInfo.environment["PI_NATIVE_TEST_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return homeDirectory
            .appendingPathComponent(".pi/agent/sessions/--\(encodedPath)--")
    }

    private static func parsePiSession(fileURL: URL) -> Session? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var displayName: String?
        var firstUserMessage: String?
        var messageCount = 0
        var lastTimestamp: Date?
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let timestamp = object["timestamp"] as? String {
                lastTimestamp = timestampFormatter.date(from: timestamp) ?? lastTimestamp
            }

            switch object["type"] as? String {
            case "session_info":
                if let name = object["name"] as? String, !name.isEmpty {
                    displayName = name
                }
            case "message":
                messageCount += 1
                if firstUserMessage == nil,
                   let message = object["message"] as? [String: Any],
                   message["role"] as? String == "user" {
                    firstUserMessage = contentPreview(message["content"])
                }
            default:
                break
            }
        }

        let fallbackName = fileURL.deletingPathExtension().lastPathComponent
        return Session(
            name: displayName ?? firstUserMessage.map(ChatTitleFormatting.fallback(from:)) ?? fallbackName,
            status: .idle,
            filePath: fileURL.path,
            updatedAt: lastTimestamp ?? fileModificationDate(fileURL) ?? .distantPast,
            messageCount: messageCount,
            titleSource: displayName == nil ? .fallback : .authoritative,
            automaticTitleState: .ineligible
        )
    }

    private static func contentPreview(_ content: Any?) -> String? {
        if let string = content as? String {
            return string.trimmedPreview
        }

        if let blocks = content as? [[String: Any]] {
            let text = blocks.compactMap { block in block["text"] as? String }.joined(separator: " ")
            return text.trimmedPreview
        }

        return nil
    }

    private static func fileModificationDate(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }
}

struct Project: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var path: String
    var sessions: [Session]
    var diffStats: DiffStats?
}

struct DiffStats: Hashable {
    var additions: Int
    var deletions: Int
}

struct Session: Identifiable, Hashable {
    let id: UUID
    var name: String
    var status: SessionStatus
    var filePath: String?
    var updatedAt: Date
    var messageCount: Int
    var titleSource: ChatTitleSource
    var automaticTitleState: AutomaticTitleState
    var pendingInitialPrompt: PreparedPrompt?
    var isArchived: Bool
    var isPinned: Bool
    var cachedTranscript: [TranscriptItem]

    init(
        id: UUID = UUID(),
        name: String,
        status: SessionStatus,
        filePath: String? = nil,
        updatedAt: Date = .now,
        messageCount: Int = 0,
        titleSource: ChatTitleSource? = nil,
        automaticTitleState: AutomaticTitleState = .ineligible,
        pendingInitialPrompt: PreparedPrompt? = nil,
        isArchived: Bool = false,
        isPinned: Bool = false,
        cachedTranscript: [TranscriptItem] = []
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.filePath = filePath
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.titleSource = titleSource ?? ((name == "New Chat" || name == "New Session") ? .placeholder : .fallback)
        self.automaticTitleState = automaticTitleState
        self.pendingInitialPrompt = pendingInitialPrompt
        self.isArchived = isArchived
        self.isPinned = isPinned
        self.cachedTranscript = cachedTranscript
    }
}

private struct PersistedSession: Codable {
    var id: UUID
    var name: String
    var filePath: String?
    var updatedAt: Date
    var messageCount: Int
    var titleSource: ChatTitleSource
    var automaticTitleState: AutomaticTitleState
    var isArchived: Bool
    var isPinned: Bool
    var cachedTranscript: [TranscriptItem]

    init(session: Session) {
        self.id = session.id
        self.name = session.name
        self.filePath = session.filePath
        self.updatedAt = session.updatedAt
        self.messageCount = session.messageCount
        self.titleSource = session.titleSource
        self.automaticTitleState = session.automaticTitleState
        self.isArchived = session.isArchived
        self.isPinned = session.isPinned
        self.cachedTranscript = session.cachedTranscript
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.messageCount = try container.decode(Int.self, forKey: .messageCount)
        self.titleSource = try container.decodeIfPresent(ChatTitleSource.self, forKey: .titleSource) ?? .fallback
        self.automaticTitleState = try container.decodeIfPresent(AutomaticTitleState.self, forKey: .automaticTitleState) ?? .ineligible
        self.isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        self.isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        self.cachedTranscript = try container.decodeIfPresent([TranscriptItem].self, forKey: .cachedTranscript) ?? []
    }

    var session: Session {
        Session(
            id: id,
            name: name,
            status: .idle,
            filePath: filePath,
            updatedAt: updatedAt,
            messageCount: max(messageCount, cachedTranscript.count),
            titleSource: titleSource,
            automaticTitleState: automaticTitleState,
            isArchived: isArchived,
            isPinned: isPinned,
            cachedTranscript: cachedTranscript
        )
    }
}

enum SessionStatus: String, Hashable {
    case idle
    case running
    case error

    var label: String {
        switch self {
        case .idle: "Idle"
        case .running: "Running"
        case .error: "Error"
        }
    }
}

private extension String {
    var trimmedPreview: String? {
        let normalized = replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if normalized.count > 80 {
            return String(normalized.prefix(77)) + "…"
        }
        return normalized
    }
}
