import SwiftUI
import AppKit

private enum ChatPanePalette {
    static let readableColumnWidth: CGFloat = 780
    static let canvas = AppTheme.dynamicColor(
        light: NSColor(calibratedRed: 0.955, green: 0.960, blue: 0.970, alpha: 1),
        dark: NSColor(calibratedRed: 0.145, green: 0.165, blue: 0.195, alpha: 1)
    )
}

struct ChatPaneView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let model = appModel.activeConversationModel, appModel.selectedSessionID != nil {
                header
                Divider()
                PiConversationView(
                    model: model,
                    modelSettings: appModel.modelSettings,
                    onSelectFavorites: { appModel.presentModelSettings() },
                    onInterrupt: { appModel.interruptSelectedConversation() }
                )
                .id(ObjectIdentifier(model))
            } else {
                NewChatStartView(
                    selectedProjectName: appModel.selectedProject?.name,
                    onChooseProject: { appModel.addProjectWithFolderPicker() },
                    onClearProject: { appModel.clearNewChatProjectSelection() },
                    onSubmit: { appModel.sendNewChatPrompt($0) }
                )
            }
        }
        .background(ChatPanePalette.canvas)
        .task(id: appModel.selectedSessionID) {
            await appModel.checkPiHealthIfNeeded()
            appModel.startActiveConversationIfNeeded()
            await appModel.refreshModelCatalog()
            if appModel.canSignInToOutfitter && appModel.modelSettings.preferredConversationModel == nil {
                appModel.presentModelSettings()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let project = appModel.selectedProject {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appModel.selectedSession?.name ?? "No Session")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("chat.title")
                    Text(project.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            } else if let session = appModel.selectedSession {
                Text(appModel.selectedSession?.name ?? "No Session")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("chat.title")

                Spacer(minLength: 12)

                PromoteProjectSubtitle {
                    appModel.presentPromoteToProject(session: session)
                }
            } else {
                Text("No Session")
                    .font(.system(size: 15, weight: .semibold))

                Spacer(minLength: 0)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 30)
        .frame(maxWidth: ChatPanePalette.readableColumnWidth, minHeight: 44, maxHeight: 44, alignment: .leading)
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .center)
        .background(ChatPanePalette.canvas)
    }
}

/// Subtitle slot for project-less chats: a prominent call-to-action for
/// turning a planning chat into a real implementation project.
private struct PromoteProjectSubtitle: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Promote to Project")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.30), in: Capsule())
            .overlay {
                Capsule().stroke(Color.accentColor.opacity(0.70), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.promoteProjectLink")
        .help("Promote this planning chat into a durable project")
    }
}
