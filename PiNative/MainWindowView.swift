import SwiftUI

private enum ShellLayoutMetrics {
    static let titlebarHeight: CGFloat = 44
    static let leftMinWidth: CGFloat = 200
    static let leftMaxWidth: CGFloat = 400
    static let rightMinWidth: CGFloat = 280
    static let rightMaxWidth: CGFloat = 480
    static let polishedPaneAnimation = Animation.easeInOut(duration: 0.24)
}

private enum ShellPaneSide {
    case left
    case right
}

private struct ShellSidePane<Content: View>: View {
    let side: ShellPaneSide
    let isVisible: Bool
    let width: CGFloat
    let content: Content

    init(side: ShellPaneSide, isVisible: Bool, width: CGFloat, @ViewBuilder content: () -> Content) {
        self.side = side
        self.isVisible = isVisible
        self.width = width
        self.content = content()
    }

    private var effectiveWidth: CGFloat { isVisible ? width : 0 }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: ShellLayoutMetrics.titlebarHeight)
            content
        }
        .frame(width: effectiveWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ShellPalette.chrome)
        .clipped()
        .allowsHitTesting(isVisible)
        .animation(ShellLayoutMetrics.polishedPaneAnimation, value: isVisible)
        .animation(ShellLayoutMetrics.polishedPaneAnimation, value: width)
    }
}

private struct ShellCenterRegion<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
    }
}

struct MainWindowView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                ShellPalette.chrome
                    .ignoresSafeArea()

                HStack(alignment: .top, spacing: 0) {
                    ShellSidePane(side: .left, isVisible: appModel.isLeftPaneVisible, width: appModel.leftPaneWidth) {
                        ProjectSidebarView()
                    }
                    .ignoresSafeArea(.container, edges: .top)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("shell.leftPane")

                    if appModel.isLeftPaneVisible {
                        ResizableDividerView(
                            width: $appModel.leftPaneWidth,
                            minWidth: ShellLayoutMetrics.leftMinWidth,
                            maxWidth: ShellLayoutMetrics.leftMaxWidth,
                            edge: .leading,
                            onDoubleClick: { appModel.toggleLeftPane() }
                        )
                        .transition(.opacity)
                    }

                    ShellCenterRegion {
                        ChatPaneView()
                    }

                    if appModel.isRightPaneOpen {
                        ResizableDividerView(
                            width: $appModel.rightPaneWidth,
                            minWidth: ShellLayoutMetrics.rightMinWidth,
                            maxWidth: ShellLayoutMetrics.rightMaxWidth,
                            edge: .trailing,
                            onDoubleClick: { appModel.toggleRightPane() }
                        )
                        .transition(.opacity)
                    }

                    ShellSidePane(side: .right, isVisible: appModel.isRightPaneOpen, width: appModel.rightPaneWidth) {
                        RightPaneView()
                    }
                    .ignoresSafeArea(.container, edges: .top)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("shell.rightPane")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let issue = appModel.piHealthIssue {
                PiRecoveryStatusBar(
                    issue: issue,
                    isChecking: appModel.isCheckingPiHealth,
                    action: { Task { await appModel.openPiInTerminal() } }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appModel.piHealthIssue)
        .background(WindowChromeConfigurator(appModel: appModel).frame(width: 0, height: 0))
        .task { await appModel.checkPiHealthIfNeeded() }
        .preferredColorScheme(appModel.appearance.colorScheme)
        .tint(AppTheme.skyAccent)
        .sheet(isPresented: $appModel.isSettingsPresented) {
            SettingsModalView {
                appModel.isSettingsPresented = false
            }
            .environmentObject(appModel)
        }
        .sheet(item: $appModel.promoteCandidateSession) { session in
            PromoteToProjectModal(
                session: session,
                defaultCodeFolder: appModel.promoteDefaultCodeFolder,
                options: appModel.promoteOptions,
                onCancel: { appModel.promoteCandidateSession = nil },
                onComplete: { appModel.completePromotion(projectPath: $0) }
            )
        }
        .alert(item: $appModel.blockedNavigationAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

}

private struct PiRecoveryStatusBar: View {
    let issue: PiHealthIssue
    let isChecking: Bool
    let action: () -> Void
    @State private var isHoveringAction = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.recoveryAccent)

            Text(issue.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("piHealth.message")

            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                    Text("Resolve in Terminal")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(AppTheme.skyAccent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHoveringAction = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHoveringAction {
                    NSCursor.pop()
                    isHoveringAction = false
                }
            }
            .accessibilityHint("Opens Pi so you can resolve installation, setup, or authentication issues")
            .accessibilityIdentifier("piHealth.openTerminal")

            if isChecking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Checking Pi")
            }

            Spacer(minLength: 16)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(AppTheme.recoveryBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppTheme.recoveryBorder)
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("piHealth.statusBar")
    }
}

struct SettingsModalView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var selectedSection: SettingsSection = .general
    let onClose: () -> Void

    init(initialSection: SettingsSection = .general, onClose: @escaping () -> Void) {
        _selectedSection = State(initialValue: initialSection)
        self.onClose = onClose
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
            Divider()
            settingsPane
        }
        .frame(width: 760, height: 500)
        .onAppear { selectedSection = appModel.settingsSection }
        .background(AppTheme.dynamicColor(
            light: NSColor(calibratedRed: 0.955, green: 0.958, blue: 0.965, alpha: 1),
            dark: NSColor(calibratedRed: 0.145, green: 0.145, blue: 0.135, alpha: 1)
        ))
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 28)
                .padding(.horizontal, 22)
                .padding(.bottom, 18)

            ForEach(SettingsSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    SettingsSidebarRow(title: section.title, systemImage: section.systemImage, isSelected: selectedSection == section)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.horizontal, 14)
            }

            Spacer(minLength: 0)
        }
        .frame(width: 210)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.dynamicColor(
            light: NSColor(calibratedRed: 0.918, green: 0.923, blue: 0.932, alpha: 1),
            dark: NSColor(calibratedWhite: 0.0, alpha: 0.16)
        ))
    }

    private var settingsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingsHeader

            switch selectedSection {
            case .general:
                generalPane
            case .projects:
                projectsPane
            case .models:
                if appModel.canSignInToOutfitter {
                    OutfitterConnectionControls(appModel: appModel)
                }
                ModelSettingsView(model: appModel.modelSettings) { force in
                    Task { await appModel.refreshModelCatalog(force: force) }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var settingsHeader: some View {
        HStack {
            Text(selectedSection.title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(QuietSettingsButtonStyle())
            .focusEffectDisabled()
            .accessibilityLabel("Close Settings")
        }
        .padding(.top, 28)
        .padding(.horizontal, 30)
        .padding(.bottom, 26)
    }

    private var generalPane: some View {
        VStack(spacing: 0) {
            SettingsFormRow(title: "Appearance") {
                AppearanceSegmentedPicker(selection: $appModel.appearance)
            }
            Divider()
            SettingsToggleRow(
                title: "Product analytics",
                subtitle: "Send pseudonymous, content-free interaction data to help improve PiNative.",
                isOn: $appModel.analyticsEnabled
            )
            .accessibilityIdentifier("settings.general.analyticsToggle")
            Divider()
        }
        .padding(.horizontal, 30)
    }

    private var projectsPane: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Project folder")
                    .font(.system(size: 15, weight: .medium))
                TextField(AppModel.defaultProjectFolderPath, text: $appModel.promoteDefaultCodeFolder)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("settings.projects.defaultCodeFolderField")
                Text("Promoted projects are created inside this folder using the project name as the folder slug.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 14)

            Divider()

            SettingsToggleRow(
                title: "Initialize git repository",
                subtitle: "Create a local git repo when the destination is not already in one.",
                isOn: $appModel.promoteOptions.initializeGitRepo
            )
            SettingsToggleRow(
                title: "Seed project memory",
                subtitle: "Create docs/project-plan.md and docs/project-log.md.",
                isOn: $appModel.promoteOptions.seedProjectMemory
            )
            SettingsToggleRow(
                title: "Add agent instructions",
                subtitle: "Create AGENTS.md with minimal instructions for future agent sessions.",
                isOn: $appModel.promoteOptions.addAgentInstructions
            )
        }
        .padding(.horizontal, 30)
    }
}

private struct QuietSettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct SettingsSidebarRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 20)
            Text(title)
                .font(.system(size: 15, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(isSelected ? .primary : .secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .contentShape(Rectangle())
        .background(isSelected ? AppTheme.dynamicColor(
            light: NSColor(calibratedWhite: 1.0, alpha: 0.82),
            dark: NSColor(calibratedWhite: 1.0, alpha: 0.10)
        ) : Color.clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct SettingsFormRow<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
            Spacer(minLength: 24)
            accessory
        }
        .padding(.vertical, 18)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.vertical, 10)
    }
}

private struct AppearanceSegmentedPicker: View {
    @Binding var selection: AppAppearance

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppAppearance.allCases) { option in
                Button {
                    selection = option
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: option.systemImage)
                            .font(.system(size: 14, weight: .medium))
                        Text(option.label)
                            .font(.system(size: 9, weight: .medium))
                    }
                    .frame(width: 46, height: 40)
                    .foregroundStyle(selection == option ? .primary : .secondary)
                    .background(selection == option ? AppTheme.skyAccent.opacity(0.24) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(QuietSettingsButtonStyle())
                .focusEffectDisabled()
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .padding(4)
        .background(AppTheme.dynamicColor(
            light: NSColor(calibratedWhite: 1.0, alpha: 0.72),
            dark: NSColor(calibratedWhite: 1.0, alpha: 0.08)
        ), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct OutfitterConnectionControls: View {
    @ObservedObject var appModel: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Outfitter inference").font(.headline)
                if appModel.isConnectedToOutfitter {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if appModel.isSigningInToOutfitter {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { appModel.cancelOutfitterSignIn() }
                } else {
                    Button(appModel.isConnectedToOutfitter ? "Switch account…" : "Sign in with Outfitter…") { appModel.signInToOutfitter() }
                        .buttonStyle(.borderedProminent)
                }
            }
            Text(appModel.outfitterSignInStatus ?? (appModel.isConnectedToOutfitter ? "Your Outfitter account is connected." : "Connect your account in your browser to use hosted models."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 24)
    }
}
