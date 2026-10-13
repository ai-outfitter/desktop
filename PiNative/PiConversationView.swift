import SwiftUI
import AppKit
import UniformTypeIdentifiers

private enum ChatTypography {
    static let bodySize: CGFloat = 17
    static let codeSize: CGFloat = 14
    static let captionSize: CGFloat = 12
    static let microSize: CGFloat = 11
    static let calloutSize: CGFloat = 15
    static let subheadlineSize: CGFloat = 15
    static let title3Size: CGFloat = 20

    static func serif(size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        let base = Font.custom("Georgia", size: size)
        return italic ? base.weight(weight).italic() : base.weight(weight)
    }

    static func serifBody(weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        serif(size: bodySize, weight: weight, italic: italic)
    }

    static func serifNSFont(size: CGFloat = bodySize) -> NSFont {
        NSFont(name: "Georgia", size: size) ?? NSFont.systemFont(ofSize: size)
    }

    static func sansBody(weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        let base = Font.system(size: bodySize, weight: weight)
        return italic ? base.italic() : base
    }

    static func sansNSFont(size: CGFloat = bodySize, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func body(weight: NSFont.Weight = .regular, italic: Bool = false) -> Font {
        MapleFont.swiftUIFont(size: bodySize, weight: weight, italic: italic)
    }

    static func caption(weight: NSFont.Weight = .regular, italic: Bool = false) -> Font {
        MapleFont.swiftUIFont(size: captionSize, weight: weight, italic: italic)
    }

    static func micro(weight: NSFont.Weight = .regular, italic: Bool = false) -> Font {
        MapleFont.swiftUIFont(size: microSize, weight: weight, italic: italic)
    }

    static func callout(weight: NSFont.Weight = .regular, italic: Bool = false) -> Font {
        MapleFont.swiftUIFont(size: calloutSize, weight: weight, italic: italic)
    }

    static func subheadline(weight: NSFont.Weight = .regular, italic: Bool = false) -> Font {
        MapleFont.swiftUIFont(size: subheadlineSize, weight: weight, italic: italic)
    }

    static func title3(weight: NSFont.Weight = .regular, italic: Bool = false) -> Font {
        MapleFont.swiftUIFont(size: title3Size, weight: weight, italic: italic)
    }
}

private enum ChatLayout {
    static let readableColumnWidth: CGFloat = 780
    static let composerReservedHeight: CGFloat = 176
    static let composerBottomChromeInset: CGFloat = 0
}

enum ChatComposerInteractivity {
    /// Session loading deliberately does not disable selectors; only an
    /// unrecoverable RPC failure makes the composer unavailable.
    static func modelAndEffortControlsEnabled(isCatastrophicRPCFailure: Bool, isLoadingSession _: Bool) -> Bool {
        !isCatastrophicRPCFailure
    }
}

private enum ChatPalette {
    /// Soft silver-white in light mode, existing blue-gray in dark mode.
    static let canvas = AppTheme.dynamicColor(
        light: NSColor(calibratedRed: 0.955, green: 0.960, blue: 0.970, alpha: 1),
        dark: NSColor(calibratedRed: 0.145, green: 0.165, blue: 0.195, alpha: 1)
    )
    static let composerFill = AppTheme.dynamicColor(
        light: NSColor(calibratedWhite: 1.0, alpha: 0.72),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.075)
    )
    static let primaryText = AppTheme.dynamicColor(
        light: NSColor(calibratedWhite: 0.12, alpha: 1),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.84)
    )
    static let codeText = AppTheme.dynamicColor(
        light: NSColor(calibratedWhite: 0.14, alpha: 1),
        dark: NSColor(calibratedWhite: 1.0, alpha: 0.82)
    )
    static let quoteRule = AppTheme.dynamicColor(
        light: NSColor.separatorColor,
        dark: NSColor.separatorColor
    )
    static let linkText = Color.accentColor
    static let nsPrimaryText = AppTheme.dynamicNSColor(
        light: NSColor(calibratedWhite: 0.12, alpha: 1),
        dark: NSColor(calibratedWhite: 0.84, alpha: 1)
    )
}

struct PiConversationView: View {
    @ObservedObject var model: PiConversationModel
    @ObservedObject var modelSettings: ModelSettingsModel
    let onSelectFavorites: () -> Void
    let onInterrupt: () -> Void
    @State private var expandedGroupIDs: Set<UUID> = []
    @State private var isModelPickerPresented = false
    @State private var isEffortPickerPresented = false
    private let transcriptBottomID = "transcript-bottom"
    private var selectionReady: Bool { model.currentModel != nil && model.currentThinkingLevel != nil }

    init(
        model: PiConversationModel,
        modelSettings: ModelSettingsModel,
        onSelectFavorites: @escaping () -> Void,
        onInterrupt: @escaping () -> Void = {}
    ) {
        self.model = model
        self.modelSettings = modelSettings
        self.onSelectFavorites = onSelectFavorites
        self.onInterrupt = onInterrupt
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 20) {
                            if let notice = model.sessionLoadNotice {
                                Text(notice)
                                    .font(ChatTypography.caption())
                                    .foregroundStyle(model.isCatastrophicRPCFailure ? AppTheme.dangerText : Color.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .accessibilityIdentifier("chat.rpcStatus")
                            }

                            if model.isLoadingSession && model.items.isEmpty && model.sessionLoadNotice == nil {
                                LoadingChatRow(startedAt: model.runningStartedAt)
                            }

                            ForEach(model.items) { item in
                                transcriptItem(item)
                                    .id(item.id)
                            }

                            ForEach(model.pendingSteering) { message in
                                PendingSteeringRow(message: message, onRetry: { model.retrySteering(message.id) })
                                    .id(message.id)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }

                            if !model.items.isEmpty || !model.pendingSteering.isEmpty {
                                PiNativeTranscriptEndMark(isRunning: model.isRunning, startedAt: model.runningStartedAt)
                            }
                        }
                        .padding(.horizontal, 30)
                        .padding(.vertical, 28)
                        .frame(maxWidth: ChatLayout.readableColumnWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)

                        Color.clear
                            .frame(height: ChatLayout.composerReservedHeight)
                            .id(transcriptBottomID)
                            .frame(maxWidth: ChatLayout.readableColumnWidth)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Transcript bottom")
                            .accessibilityIdentifier("chat.transcriptBottom")
                    }
                }
                .onAppear {
                    scrollToBottom(proxy, animated: false)
                }
                .onChange(of: transcriptContentID) { _, _ in
                    guard !model.items.isEmpty || !model.pendingSteering.isEmpty else { return }
                    scrollToBottom(proxy, animated: true)
                }
            }

            VStack(spacing: 0) {
                Divider()
                composer
            }
            .padding(.bottom, ChatLayout.composerBottomChromeInset)
            .background(ChatPalette.canvas)
        }
        .background(ChatPalette.canvas)
        .onExitCommand(perform: onInterrupt)
    }

    private var transcriptContentID: String {
        let itemFingerprint = model.items.map { "\($0.id.uuidString):\($0.hashValue)" }.joined(separator: ",")
        let steeringFingerprint = model.pendingSteering.map { "\($0.id.uuidString):\($0.hashValue)" }.joined(separator: ",")
        return "\(itemFingerprint)|steering:\(steeringFingerprint)|running:\(model.isRunning)|loading:\(model.isLoadingSession)|notice:\(model.sessionLoadNotice ?? "")"
    }

    @ViewBuilder
    private func transcriptItem(_ item: TranscriptItem) -> some View {
        switch item {
        case .user(_, let payload):
            HStack {
                Spacer(minLength: 80)
                MessageBubble(payload: payload)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistantText(_, let text):
            AssistantTextBlock(text: text, onCopy: { model.copyToPasteboard(text) })
                .frame(maxWidth: .infinity, alignment: .leading)
        case .activity(let group):
            ActivityGroupRow(
                group: group,
                isExpanded: expandedGroupIDs.contains(group.id),
                onToggle: { toggleExpansion(group.id) }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        case .notice(_, let text):
            Text(text)
                .font(ChatTypography.caption(weight: item.isInterruptionNotice ? .semibold : .regular))
                .foregroundStyle(item.isInterruptionNotice ? AppTheme.dangerText : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityLabel(text)
                .accessibilityIdentifier("chat.notice")
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        Task { @MainActor in
            await Task.yield()
            scrollToBottomNow(proxy, animated: animated)
            try? await Task.sleep(nanoseconds: 60_000_000)
            scrollToBottomNow(proxy, animated: false)
        }
    }

    private func scrollToBottomNow(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(transcriptBottomID, anchor: .bottom) }
        } else {
            proxy.scrollTo(transcriptBottomID, anchor: .bottom)
        }
    }

    private func toggleExpansion(_ id: UUID) {
        // View-local, deliberately not part of `model.items` — see
        // implementation plan §D: putting expansion state in the published
        // model would fire the transcript's onChange/scroll-to-bottom when
        // expanding an old group.
        if expandedGroupIDs.contains(id) {
            expandedGroupIDs.remove(id)
        } else {
            expandedGroupIDs.insert(id)
        }
    }

    private var composer: some View {
        let modelAndEffortControlsEnabled = ChatComposerInteractivity.modelAndEffortControlsEnabled(
            isCatastrophicRPCFailure: model.isCatastrophicRPCFailure,
            isLoadingSession: model.isLoadingSession
        )

        return AttachmentComposerShell(
            draft: $model.draft,
            attachments: $model.draftAttachments,
            promptHistory: model.promptHistory,
            placeholder: "",
            statusMessage: nil,
            focusRequest: model.isCatastrophicRPCFailure ? nil : model.composerFocusRequest,
            textIdentity: ObjectIdentifier(model),
            interactionEnabled: !model.isCatastrophicRPCFailure,
            sendDisabled: model.isCatastrophicRPCFailure || (!model.isRunning && (!selectionReady || PromptAttachmentAssembler.prepare(draft: model.draft, attachments: model.draftAttachments) == nil)),
            isRunning: model.isRunning,
            onAddAttachments: { model.addDraftAttachments($0) },
            onRemoveAttachment: { model.removeDraftAttachment($0) },
            onSubmit: { model.sendDraft() },
            onStop: onInterrupt,
            onEscape: onInterrupt
        ) {
            Spacer()

            HStack(spacing: 8) {
                ModelPickerButton(
                    currentModel: selectionReady ? model.currentModel : nil,
                    favoriteModels: modelSettings.availableFavorites,
                    isEnabled: modelAndEffortControlsEnabled,
                    isPresented: $isModelPickerPresented,
                    onSelectModel: { model.selectModel($0) },
                    onSelectFavorites: onSelectFavorites
                )

                EffortPickerButton(
                    currentEffort: selectionReady ? model.currentThinkingLevel : nil,
                    availableEfforts: model.availableThinkingLevels,
                    isEnabled: modelAndEffortControlsEnabled,
                    isPresented: $isEffortPickerPresented,
                    onSelectEffort: { model.selectThinkingLevel($0) }
                )
            }

        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.composer")
        .disabled(!modelAndEffortControlsEnabled)
        .allowsHitTesting(modelAndEffortControlsEnabled)
        .frame(maxWidth: ChatLayout.readableColumnWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 26)
    }

}

/// Shared "clearly disabled" treatment for composer controls that aren't
/// functional yet: dimmed well below the secondary-text level and fully
/// non-interactive, so they read as placeholders instead of broken buttons.
private extension View {
    func disabledComposerControl() -> some View {
        self
            .foregroundStyle(.tertiary)
            .opacity(0.5)
            .allowsHitTesting(false)
            .help("Coming soon")
    }
}

private struct ModelPickerButton: View {
    let currentModel: PiModelOption?
    let favoriteModels: [PiModelOption]
    let isEnabled: Bool
    @Binding var isPresented: Bool
    let onSelectModel: (PiModelOption) -> Void
    let onSelectFavorites: () -> Void

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ComposerPickerLabel(title: currentModel?.name ?? "Model", isEnabled: isEnabled)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .fixedSize()
        .accessibilityLabel("Model")
        .accessibilityValue(currentModel?.name ?? "Unavailable")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ModelPickerPopover(
                currentModel: currentModel,
                favoriteModels: favoriteModels,
                onSelectModel: { option in
                    onSelectModel(option)
                    isPresented = false
                },
                onSelectFavorites: {
                    isPresented = false
                    onSelectFavorites()
                }
            )
        }
        .accessibilityIdentifier("composer.modelPicker")
        .disabled(!isEnabled)
        .allowsHitTesting(isEnabled)
    }
}

private struct EffortPickerButton: View {
    let currentEffort: PiThinkingLevel?
    let availableEfforts: [PiThinkingLevel]
    let isEnabled: Bool
    @Binding var isPresented: Bool
    let onSelectEffort: (PiThinkingLevel) -> Void

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ComposerPickerLabel(title: currentEffort?.label ?? "Effort", isEnabled: isEnabled)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .fixedSize()
        .accessibilityLabel("Effort")
        .accessibilityValue(currentEffort?.label ?? "Unavailable")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            EffortPickerPopover(
                currentEffort: currentEffort,
                availableEfforts: availableEfforts,
                onSelectEffort: { effort in
                    onSelectEffort(effort)
                    isPresented = false
                }
            )
        }
        .accessibilityIdentifier("composer.effortPicker")
        .disabled(!isEnabled)
        .allowsHitTesting(isEnabled)
    }
}

private struct ComposerPickerLabel: View {
    let title: String
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 7) {
            Text(title)
                .font(ChatTypography.caption(weight: .medium))
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isEnabled ? .secondary : .tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(isEnabled ? 0.055 : 0.028), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .opacity(isEnabled ? 1 : 0.62)
    }
}

private struct ModelPickerPopover: View {
    let currentModel: PiModelOption?
    let favoriteModels: [PiModelOption]
    let onSelectModel: (PiModelOption) -> Void
    let onSelectFavorites: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if favoriteModels.isEmpty {
                Text("No favorite models")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(favoriteModels, id: \.stableID) { option in
                            PickerSelectionRow(
                                title: option.name,
                                isSelected: option == currentModel,
                                accessibilityIdentifier: "composer.modelFavorite.\(option.stableID)"
                            ) {
                                onSelectModel(option)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            Divider().padding(.horizontal, 16)
            PickerActionRow(title: "Select Favorites…", accessibilityIdentifier: "composer.selectFavorites") {
                onSelectFavorites()
            }
        }
        .frame(minWidth: 230, idealWidth: 280, maxWidth: 340, alignment: .leading)
        .fixedSize(horizontal: false, vertical: false)
        .padding(.vertical, 7)
    }
}

private struct EffortPickerPopover: View {
    let currentEffort: PiThinkingLevel?
    let availableEfforts: [PiThinkingLevel]
    let onSelectEffort: (PiThinkingLevel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if availableEfforts.isEmpty {
                Text("Effort unavailable")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            } else {
                ForEach(availableEfforts) { effort in
                    PickerSelectionRow(
                        title: effort.label,
                        isSelected: effort == currentEffort,
                        accessibilityIdentifier: "composer.effort.\(effort.rawValue)"
                    ) {
                        onSelectEffort(effort)
                    }
                }
            }
        }
        .frame(minWidth: 150, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.vertical, 7)
    }
}

private struct PickerActionRow: View {
    let title: String
    let accessibilityIdentifier: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.clear)
                    .frame(width: 16, alignment: .center)
                Text(title)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 16)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isHovering ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityIdentifier(accessibilityIdentifier)
        .padding(.horizontal, 7)
        .onHover { isHovering = $0 }
    }
}

private struct PickerSelectionRow: View {
    let title: String
    let isSelected: Bool
    var accessibilityIdentifier: String? = nil
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? AppTheme.skyAccent : Color.clear)
                    .frame(width: 16, alignment: .center)
                Text(title)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 160, maxWidth: 310, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isHovering ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityIdentifier(accessibilityIdentifier ?? title)
        .padding(.horizontal, 7)
        .onHover { isHovering = $0 }
    }
}

struct AttachmentComposerShell<AccessoryContent: View>: View {
    @Binding var draft: String
    @Binding var attachments: [ComposerAttachment]
    var promptHistory: [ComposerPromptHistoryEntry] = []
    var placeholder: String
    var statusMessage: String? = nil
    var focusRequest: UUID? = nil
    var textIdentity: AnyHashable? = nil
    var interactionEnabled: Bool = true
    var sendDisabled: Bool
    var isRunning: Bool
    var onAddAttachments: ([ComposerAttachment]) -> Void
    var onRemoveAttachment: (ComposerAttachment.ID) -> Void
    var onSubmit: () -> Void
    var onStop: () -> Void
    var onEscape: () -> Void = {}
    var editorHeight: CGFloat = 30
    @ViewBuilder var accessoryContent: () -> AccessoryContent

    @State private var isDropTargeted = false
    @State private var attachmentError: AttachmentImportError?
    @State private var historyNavigator = ComposerPromptHistoryNavigator()
    @State private var historyTextUpdateRequest = UUID()
    @StateObject private var dictation = VoiceDictationController()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AttachmentChipStrip(attachments: attachments) { id in
                historyNavigator.userDidEdit()
                onRemoveAttachment(id)
            }

            if let attachmentError {
                Text(attachmentError.localizedDescription)
                    .font(ChatTypography.caption())
                    .foregroundStyle(.orange)
            }

            if let dictationStatus = dictation.statusMessage {
                Text(dictationStatus)
                    .font(ChatTypography.caption())
                    .foregroundStyle(.orange)
            }

            PasteAwareTextView(
                text: $draft,
                placeholder: placeholder,
                font: ChatTypography.sansNSFont(),
                textColor: ChatPalette.nsPrimaryText,
                focusRequest: focusRequest,
                textIdentity: textIdentity,
                textUpdateRequest: historyTextUpdateRequest,
                onSubmit: submit,
                onEscape: onEscape,
                onHistoryOlder: navigateToOlderPrompt,
                onHistoryNewer: navigateToNewerPrompt,
                onUserEdit: {
                    // A manual edit means the user is taking over from
                    // dictation; stop it so live results no longer overwrite
                    // what they just typed.
                    if dictation.isActive { dictation.cancel() }
                    historyNavigator.userDidEdit()
                },
                onPasteAttachments: handleImportedAttachments,
                onDragTargeted: { isDropTargeted = $0 }
            )
            // Keep the AppKit-backed editor from greedily expanding the
            // composer. It scrolls internally for longer drafts; attachment
            // chips live above it and should add only their own height.
            .frame(height: editorHeight)
            .allowsHitTesting(interactionEnabled)

            HStack(spacing: 10) {
                Button(action: openAttachmentPicker) {
                    Image(systemName: "plus")
                        .font(ChatTypography.callout())
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .padding(.leading, 13)
                .accessibilityLabel("Attach files")
                .help("Attach files")
                .disabled(!interactionEnabled)

                accessoryContent()

                ComposerDictationButton(
                    state: dictation.state,
                    isEnabled: interactionEnabled,
                    onToggle: toggleDictation
                )

                ComposerSendButton(
                    isRunning: isRunning,
                    isDisabled: sendDisabled,
                    onSubmit: submit,
                    onStop: onStop
                )
            }
            .font(ChatTypography.caption())
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(ChatPalette.composerFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isDropTargeted ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.10), lineWidth: isDropTargeted ? 1.5 : 0.8)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 14, x: 0, y: 8)
        .onChange(of: textIdentity) { _, _ in
            dictation.cancel()
            historyNavigator.chatDidChange()
        }
        .onChange(of: interactionEnabled) { _, isEnabled in
            // The dictation button is disabled along with the composer, so a
            // recording in flight when interaction stops would otherwise keep
            // the mic live with no way to stop it from the UI.
            if !isEnabled { dictation.cancel() }
        }
        .onChange(of: dictation.liveDraft) { _, liveDraft in
            guard let liveDraft else { return }
            draft = liveDraft
            historyTextUpdateRequest = UUID()
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard interactionEnabled else { return false }
            let group = DispatchGroup()
            var urls: [URL] = []
            for provider in providers {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    if let data = item as? Data,
                       let string = String(data: data, encoding: .utf8),
                       let url = URL(string: string) {
                        urls.append(url)
                    } else if let url = item as? URL {
                        urls.append(url)
                    }
                }
            }
            group.notify(queue: .main) {
                let result = AttachmentClassifier.attachments(from: urls)
                handleImportedAttachments(result.attachments, result.errors)
            }
            return true
        }
    }

    private func openAttachmentPicker() {
        guard interactionEnabled else { return }
        let panel = NSOpenPanel()
        panel.title = "Attach Files"
        panel.prompt = "Attach"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let result = AttachmentClassifier.attachments(from: panel.urls)
        handleImportedAttachments(result.attachments, result.errors)
    }

    private func handleImportedAttachments(_ attachments: [ComposerAttachment], _ errors: [AttachmentImportError]) {
        guard interactionEnabled else { return }
        if !attachments.isEmpty {
            historyNavigator.userDidEdit()
            onAddAttachments(attachments)
        }
        attachmentError = errors.first
    }

    private func navigateToOlderPrompt() -> Bool {
        let didNavigate = historyNavigator.navigateOlder(
            in: promptHistory,
            draft: &draft,
            attachments: &attachments
        )
        if didNavigate { historyTextUpdateRequest = UUID() }
        return didNavigate
    }

    private func navigateToNewerPrompt() -> Bool {
        let didNavigate = historyNavigator.navigateNewer(
            in: promptHistory,
            draft: &draft,
            attachments: &attachments
        )
        if didNavigate { historyTextUpdateRequest = UUID() }
        return didNavigate
    }

    private func submit() {
        dictation.cancel()
        historyNavigator.endBrowsing()
        onSubmit()
    }

    private func toggleDictation() {
        guard interactionEnabled else { return }
        if dictation.isActive {
            dictation.stop()
        } else {
            historyNavigator.endBrowsing()
            dictation.start(baseDraft: draft)
        }
    }
}

struct ComposerPromptHistoryEntry: Equatable {
    var id: UUID
    var payload: UserMessagePayload
}

struct ComposerPromptHistoryNavigator {
    private(set) var selectedEntryID: UUID?

    var isBrowsing: Bool { selectedEntryID != nil }

    mutating func navigateOlder(
        in entries: [ComposerPromptHistoryEntry],
        draft: inout String,
        attachments: inout [ComposerAttachment]
    ) -> Bool {
        guard !entries.isEmpty else {
            endBrowsing()
            return false
        }

        if let selectedEntryID {
            guard let index = entries.firstIndex(where: { $0.id == selectedEntryID }) else {
                endBrowsing()
                return false
            }
            let olderIndex = max(entries.startIndex, index - 1)
            self.selectedEntryID = entries[olderIndex].id
            apply(entries[olderIndex].payload, draft: &draft, attachments: &attachments)
            return true
        }

        guard draft.isEmpty, attachments.isEmpty, let newest = entries.last else { return false }
        selectedEntryID = newest.id
        apply(newest.payload, draft: &draft, attachments: &attachments)
        return true
    }

    mutating func navigateNewer(
        in entries: [ComposerPromptHistoryEntry],
        draft: inout String,
        attachments: inout [ComposerAttachment]
    ) -> Bool {
        guard let selectedEntryID,
              let index = entries.firstIndex(where: { $0.id == selectedEntryID })
        else {
            endBrowsing()
            return false
        }

        let newerIndex = index + 1
        guard newerIndex < entries.endIndex else {
            endBrowsing()
            draft = ""
            attachments = []
            return true
        }
        self.selectedEntryID = entries[newerIndex].id
        apply(entries[newerIndex].payload, draft: &draft, attachments: &attachments)
        return true
    }

    mutating func endBrowsing() {
        selectedEntryID = nil
    }

    mutating func userDidEdit() {
        endBrowsing()
    }

    mutating func chatDidChange() {
        endBrowsing()
    }

    private func apply(
        _ payload: UserMessagePayload,
        draft: inout String,
        attachments: inout [ComposerAttachment]
    ) {
        draft = payload.text
        attachments = payload.attachments
    }
}

private struct ComposerDictationButton: View {
    let state: VoiceDictationState
    let isEnabled: Bool
    let onToggle: () -> Void

    @State private var isPulsing = false

    private var isRecording: Bool { state == .recording }

    private var iconColor: Color {
        if isRecording { return AppTheme.stopAccent }
        if !isEnabled || state == .starting { return .secondary.opacity(0.5) }
        return .secondary
    }

    private var accessibilityValueText: String {
        switch state {
        case .idle: "Not recording"
        case .starting: "Preparing"
        case .recording: "Recording"
        }
    }

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: "mic.fill")
                .font(ChatTypography.callout())
                .foregroundStyle(iconColor)
                .frame(width: 24, height: 24)
                .opacity(isPulsing ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(isRecording ? "Stop dictation" : "Start dictation")
        .accessibilityValue(accessibilityValueText)
        .accessibilityIdentifier("composer.dictationButton")
        .help(isRecording ? "Stop dictation" : "Dictate")
        .onAppear {
            updatePulse(for: state)
        }
        .onChange(of: state) { _, newState in
            updatePulse(for: newState)
        }
    }

    private func updatePulse(for state: VoiceDictationState) {
        if state == .recording {
            guard !isPulsing else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        } else if isPulsing {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isPulsing = false
            }
        }
    }
}

private struct ComposerSendButton: View {
    let isRunning: Bool
    let isDisabled: Bool
    let onSubmit: () -> Void
    let onStop: () -> Void

    private var iconName: String { isRunning ? "stop.fill" : "arrow.up" }

    private var fillColor: Color {
        if isDisabled { return Color.primary.opacity(0.09) }
        if isRunning { return AppTheme.stopAccent }
        return .accentColor
    }

    private var iconColor: Color { isDisabled ? .secondary : .white }

    var body: some View {
        Button {
            if isRunning { onStop() } else { onSubmit() }
        } label: {
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(iconColor)
                .frame(width: 36, height: 36)
                .background(fillColor, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(isRunning ? "Stop" : "Send")
        .accessibilityIdentifier(isRunning ? "composer.stopButton" : "composer.sendButton")
        .help(isRunning ? "Stop the running turn" : "Send")
    }
}

private struct PendingSteeringRow: View {
    let message: SteeringMessage
    let onRetry: () -> Void

    private var stateLabel: String {
        switch message.state {
        case .submitting: "Queueing"
        case .accepted: "Steering"
        case .replaying: "Sending after Stop"
        case .failed: "Steering failed"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(stateLabel):")
                    .font(ChatTypography.caption(weight: .semibold))
                Text(message.prepared.summaryText)
                    .font(ChatTypography.caption())
                    .lineLimit(2)
                    .truncationMode(.tail)
            }

            if !message.prepared.displayAttachments.isEmpty {
                HStack(spacing: 8) {
                    ForEach(message.prepared.displayAttachments) { attachment in
                        Label(attachment.displayName, systemImage: "paperclip")
                            .lineLimit(1)
                    }
                }
                .font(ChatTypography.micro())
            }

            if message.state == .failed {
                Button("Retry", action: onRetry)
                    .buttonStyle(.plain)
                    .font(ChatTypography.caption(weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.72))
            }
        }
        .foregroundStyle(Color.secondary.opacity(0.82))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(stateLabel): \(message.prepared.summaryText)")
        .accessibilityIdentifier("transcript.pendingSteering")
    }
}

/// Right-aligned, dark, rounded bubble with **no avatar/role label** —
/// matches the reference layout's user-turn treatment exactly (found by
/// adversarial review: the original version had a "You" label and a light
/// blue tint, which the milestone doc explicitly specifies against).
private struct MessageBubble: View {
    let payload: UserMessagePayload

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AttachmentChipStrip(attachments: payload.attachments)
            if !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                InlineCodeText(text: payload.text, proseFont: ChatTypography.sansBody())
                    .textSelection(.enabled)
            }
        }
        .accessibilityIdentifier("transcript.userMessage")
        .padding(12)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.12))
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct InlineCodeText: View {
    let text: String
    var proseFont: Font = ChatTypography.serifBody()

    var body: some View {
        Text(Self.attributed(text, proseFont: proseFont))
            .lineSpacing(2)
            .foregroundStyle(ChatPalette.primaryText)
    }

    private static func attributed(_ text: String, proseFont: Font) -> AttributedString {
        var result = AttributedString()
        var remaining = text[...]
        var isCode = false

        while let tick = remaining.firstIndex(of: "`") {
            let prefix = String(remaining[..<tick])
            append(prefix, isCode: isCode, proseFont: proseFont, to: &result)
            remaining = remaining[remaining.index(after: tick)...]
            isCode.toggle()
        }

        append(String(remaining), isCode: isCode, proseFont: proseFont, to: &result)
        return result
    }

    private static func append(_ string: String, isCode: Bool, proseFont: Font, to result: inout AttributedString) {
        guard !string.isEmpty else { return }
        var segment = AttributedString(string)
        segment.font = isCode ? MapleFont.swiftUIFont(size: ChatTypography.bodySize - 1) : proseFont
        if isCode {
            segment.inlinePresentationIntent = .code
        }
        result.append(segment)
    }
}

/// Plain, bubble-free rendering for assistant text (per implementation plan
/// Phase 3 step 2 — only user messages keep the bubble treatment).
private struct AssistantTextBlock: View {
    let text: String
    let onCopy: () -> Void

    var body: some View {
        MarkdownAssistantText(text: text)
            .accessibilityIdentifier("transcript.assistantMessage")
            .frame(maxWidth: 760, alignment: .leading)
    }
}

/// User-facing progress notes for hidden tool activity. Technical tool names,
/// command strings, raw arguments, and outputs stay out of the default chat
/// transcript; this row gives non-expert users a lightweight sense of what
/// happened without asking them to parse implementation details.
private struct ActivityGroupRow: View {
    let group: ActivityGroup
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ChatMessageLayout.activitySummarySpacing) {
            ForEach(Array(summaryLines.enumerated()), id: \.offset) { offset, line in
                Text(line)
                    .font(MapleFont.swiftUIFont(size: 13, weight: .semibold, italic: true))
                    .foregroundStyle(.secondary)
                    .lineSpacing(ChatMessageLayout.activityWrappedLineSpacing)
                    .lineLimit(2)
                    .accessibilityIdentifier("transcript.activitySummary.\(offset)")
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var summaryLines: [String] {
        let lines = group.tools.map(Self.summary(for:))
        return lines.isEmpty ? [group.isRunning ? "Working through the request" : "Finished checking the request"] : lines
    }

    private static func summary(for tool: ToolTranscriptItem) -> String {
        switch tool.name {
        case "edit":
            if let path = value(for: "path", in: tool.args) {
                return "Updating \(displayPath(path))"
            }
            return "Updating the requested files"
        case "write":
            if let path = value(for: "path", in: tool.args) {
                return "Writing \(displayPath(path))"
            }
            return "Writing the requested changes"
        case "read":
            if let path = value(for: "path", in: tool.args) {
                return "Reviewing \(displayPath(path))"
            }
            return "Reviewing the relevant files"
        case "update_changelog":
            return "Updating the changelog"
        case "bash":
            return summaryForCommand(value(for: "command", in: tool.args) ?? "")
        default:
            return tool.status == .running ? "Working through the next step" : "Completed a project step"
        }
    }

    private static func summaryForCommand(_ command: String) -> String {
        let lowered = command.lowercased()
        if lowered.contains("xcodebuild") { return "Building the app to verify the changes" }
        if lowered.contains("pkill") || lowered.contains(" open ") || lowered.hasPrefix("open ") { return "Relaunching the app with the latest changes" }
        if lowered.contains("rg ") || lowered.hasPrefix("rg ") { return "Searching the codebase for the right place to update" }
        if lowered.contains("npx rfc2119") { return "Checking project requirements" }
        if lowered.contains("git ") || lowered.hasPrefix("git ") { return "Checking project changes" }
        if lowered.contains("swift test") || lowered.contains("xctest") { return "Running tests" }
        return "Running a project check"
    }

    private static func value(for key: String, in args: String) -> String? {
        guard let data = args.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key] as? String,
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func displayPath(_ path: String) -> String {
        if path.hasPrefix("/Users/") {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return path
    }
}

private struct PiNativeIconMark: View {
    let size: CGFloat

    var body: some View {
        if let icon = NSImage(named: "AppIcon") {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.75, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: size, height: size)
        }
    }
}

private struct PiNativeTranscriptEndMark: View {
    let isRunning: Bool
    let startedAt: Date

    var body: some View {
        Group {
            if isRunning {
                TimelineView(.animation) { context in
                    PiNativeIconMark(size: 38)
                        .opacity(0.82 + 0.18 * pulse(for: context.date))
                        .scaleEffect(0.96 + 0.07 * pulse(for: context.date))
                        .rotationEffect(.degrees(rotation(for: context.date)))
                }
            } else {
                PiNativeIconMark(size: 38)
                    .opacity(0.82)
            }
        }
        .frame(width: 42, height: 42)
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.top, 10)
        .offset(x: -6)
        .accessibilityLabel(isRunning ? "Working" : "End of chat")
    }

    private func pulse(for date: Date) -> Double {
        (sin(date.timeIntervalSince(startedAt) * 2.2) + 1) / 2
    }

    private func rotation(for date: Date) -> Double {
        date.timeIntervalSince(startedAt).truncatingRemainder(dividingBy: 1.8) / 1.8 * 360
    }
}

private struct LoadingChatRow: View {
    let startedAt: Date

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.animation) { context in
                PiNativeIconMark(size: 22)
                    .opacity(0.72 + 0.22 * pulse(for: context.date))
                    .scaleEffect(0.94 + 0.08 * pulse(for: context.date))
                    .rotationEffect(.degrees(rotation(for: context.date)))
            }
            .frame(width: 24, height: 24)

            Text("Loading chat…")
                .font(ChatTypography.caption(weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading chat")
    }

    private func pulse(for date: Date) -> Double {
        (sin(date.timeIntervalSince(startedAt) * 2.2) + 1) / 2
    }

    private func rotation(for date: Date) -> Double {
        date.timeIntervalSince(startedAt).truncatingRemainder(dividingBy: 1.8) / 1.8 * 360
    }
}

private struct SpinningGearIcon: View {
    let size: Font

    var body: some View {
        TimelineView(.animation) { context in
            Image(systemName: "gearshape.2")
                .font(size)
                .rotationEffect(.degrees(rotation(for: context.date)))
        }
    }

    private func rotation(for date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4 * 360
    }
}

private struct MarkdownAssistantText: View {
    let text: String

    private var document: ChatMarkdownDocument {
        ChatMarkdownParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ChatMarkdownBlock) -> some View {
        if let list = block.list {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(list.style == .ordered ? "\(list.ordinal)." : "•")
                    .font(ChatTypography.serifBody(weight: .semibold))
                    .frame(width: 24, alignment: .trailing)
                quotedContent(block)
            }
            .padding(.leading, CGFloat(list.depth) * 18)
        } else {
            quotedContent(block)
        }
    }

    @ViewBuilder
    private func quotedContent(_ block: ChatMarkdownBlock) -> some View {
        if block.quoteDepth > 0 {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(ChatPalette.quoteRule)
                    .frame(width: 3)
                roleContent(block)
            }
            .padding(.leading, CGFloat(max(block.quoteDepth - 1, 0)) * 14)
        } else {
            roleContent(block)
        }
    }

    @ViewBuilder
    private func roleContent(_ block: ChatMarkdownBlock) -> some View {
        switch block.role {
        case .paragraph:
            markdownText(block.content, font: ChatTypography.serifBody())
        case .heading(let level):
            markdownText(block.content, font: headingFont(level: level))
                .padding(.top, level <= 2 ? 4 : 0)
        case .code(let language):
            CodeBlockView(
                language: language,
                text: String(block.content.characters).trimmingCharacters(in: .newlines)
            )
        case .thematicBreak:
            Divider()
                .padding(.vertical, 4)
        }
    }

    private func markdownText(_ content: AttributedString, font: Font) -> some View {
        Text(Self.styledInlineContent(content, proseFont: font))
            .lineSpacing(2)
            .foregroundStyle(ChatPalette.primaryText)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: ChatTypography.serif(size: 26, weight: .bold).leading(.tight)
        case 2: ChatTypography.serif(size: 22, weight: .semibold)
        case 3: ChatTypography.serif(size: 19, weight: .semibold)
        default: ChatTypography.serifBody(weight: .semibold)
        }
    }

    private static func styledInlineContent(_ content: AttributedString, proseFont: Font) -> AttributedString {
        var styled = content
        for run in styled.runs {
            let intent = run.inlinePresentationIntent ?? []
            if run.link != nil {
                styled[run.range].foregroundColor = ChatPalette.linkText
            }
            if intent.contains(.code) {
                styled[run.range].font = MapleFont.swiftUIFont(size: ChatTypography.bodySize - 1)
            } else {
                styled[run.range].font = proseFont
                if intent.contains(.stronglyEmphasized) {
                    styled[run.range].font = proseFont.bold()
                }
                if intent.contains(.emphasized) {
                    styled[run.range].font = (styled[run.range].font ?? proseFont).italic()
                }
            }
        }
        return styled
    }
}

private struct CodeBlockView: View {
    let language: String?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language, language.lowercased() != "text" {
                Text(language)
                    .font(ChatTypography.micro(weight: .semibold))
                    .foregroundStyle(.green.opacity(0.75))
            }
            ScrollView(.horizontal) {
                Text(text)
                    .font(MapleFont.swiftUIFont(size: ChatTypography.codeSize))
                    .foregroundStyle(ChatPalette.codeText)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .greenCodeContainer()
    }
}

private struct ToolCallCard: View {
    let tool: ToolTranscriptItem
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if !tool.args.isEmpty {
                    LabeledCodeBlock(label: "Arguments", text: tool.args)
                }
                LabeledCodeBlock(label: "Output", text: tool.output.isEmpty ? "No output yet." : tool.output)
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(ChatTypography.callout())
                    .foregroundStyle(iconColor)
                Text(tool.name)
                    .font(ChatTypography.subheadline(weight: .semibold))
                Text(summary)
                    .font(ChatTypography.caption())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(tool.status.label)
                    .font(ChatTypography.micro(weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(iconColor.opacity(0.12), in: Capsule())
            }
        }
    }

    private var summary: String {
        if tool.name == "bash", let command = Self.extractCommand(from: tool.args) {
            return command
        }
        return tool.args.replacingOccurrences(of: "\n", with: " ")
    }

    private var iconName: String {
        switch tool.status {
        case .running: "gearshape.2"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private var iconColor: Color {
        switch tool.status {
        case .running: .orange
        case .succeeded: .green
        case .failed: .red
        }
    }

    static func extractCommand(from args: String) -> String? {
        guard let data = args.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? String
        else { return nil }
        return command
    }
}

private extension View {
    func greenCodeContainer() -> some View {
        self
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.green.opacity(0.18), lineWidth: 1)
            }
    }
}

private struct LabeledCodeBlock: View {
    let label: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(ChatTypography.caption(weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                Text(text)
                    .font(MapleFont.swiftUIFont(size: ChatTypography.codeSize))
                    .foregroundStyle(ChatPalette.codeText)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .greenCodeContainer()
        }
    }
}
