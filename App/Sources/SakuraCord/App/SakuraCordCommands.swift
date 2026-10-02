import AppKit
import SwiftUI

struct SakuraCordCommands: Commands {
    @FocusedValue(\.shortcutCommandContext) private var commandContext
    let updateController: AppUpdateController

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About SakuraCord") {
                NSApp.orderFrontStandardAboutPanel(options: [
                    .applicationVersion:
                        AboutVersionInformation().semanticVersionDisplay,
                    .version: "",
                ])
            }

            Divider()

            CheckForUpdatesCommand(updateController: updateController)
        }

        CommandGroup(replacing: .sidebar) {
            ShortcutCommandButton(action: .toggleChannelSidebar)
            ShortcutCommandButton(
                action: .toggleMemberList,
                title: LocalizedStringResource("Toggle Right Sidebar", bundle: #bundle)
            )
            Divider()
            ShortcutCommandButton(action: .togglePins)
            Divider()
            ShortcutCommandButton(
                action: .navigateBack,
                title: LocalizedStringResource("Back", bundle: #bundle)
            )
            ShortcutCommandButton(
                action: .navigateForward,
                title: LocalizedStringResource("Forward", bundle: #bundle)
            )
            ShortcutCommandButton(action: .previousTextChannel)

            Divider()

            ShortcutCommandButton(action: .previousConversation)
            ShortcutCommandButton(action: .nextConversation)
            ShortcutCommandButton(action: .previousUnread)
            ShortcutCommandButton(action: .nextUnread)

            Divider()

            ShortcutCommandButton(action: .previousMention)
            ShortcutCommandButton(action: .nextMention)

            Divider()

            ShortcutCommandButton(action: .previousServer)
            ShortcutCommandButton(action: .nextServer)
            ShortcutCommandButton(action: .toggleDirectMessages)
        }

        CommandMenu("Navigate") {
            ShortcutCommandButton(action: .quickSwitch)
            ShortcutCommandButton(action: .messageSearch)
            ShortcutCommandButton(action: .currentCall)

            Divider()

            Button("Direct Messages") {
                commandContext?.navigate(to: 1)
            }
            .disabled(commandContext?.allowsWorkspaceNavigation != true)
            .keyboardShortcut("1")

            ForEach(2 ... 9, id: \.self) { shortcutNumber in
                Button("Server \(shortcutNumber - 1)") {
                    commandContext?.navigate(to: shortcutNumber)
                }
                .disabled(commandContext?.allowsWorkspaceNavigation != true)
                .keyboardShortcut(
                    KeyEquivalent(Character(String(shortcutNumber)))
                )
            }
        }

        CommandMenu("Message") {
            ShortcutCommandButton(action: .upload)
            ShortcutCommandButton(action: .copyChannelLink)

            Divider()

            ShortcutCommandButton(
                action: .searchCurrentConversation
            )
            ShortcutCommandButton(action: .markServerRead)
            Divider()
            ShortcutCommandButton(action: .toggleEmojiPicker)
            ShortcutCommandButton(action: .toggleGIFPicker)
            ShortcutCommandButton(action: .toggleStickerPicker)
            Divider()
            ShortcutCommandButton(action: .translateDraft)
        }

        CommandMenu("Voice") {
            ShortcutCommandButton(action: .startCall)
            ShortcutCommandButton(action: .answerCall)
            ShortcutCommandButton(action: .toggleSoundboard)
            Divider()
            ShortcutCommandButton(action: .toggleMute)
            ShortcutCommandButton(action: .toggleDeafen)
            ShortcutCommandButton(action: .toggleCamera)
            ShortcutCommandButton(action: .toggleScreenShare)

            Divider()

            ShortcutCommandButton(action: .leaveCall)
        }
    }
}

private struct ShortcutCommandButton: View {
    let action: KeyboardShortcutAction
    var title: LocalizedStringResource?
    @FocusedValue(\.shortcutCommandContext) private var commandContext
    private let shortcuts = KeyboardShortcutSettingsStore.shared

    var body: some View {
        Button(title ?? action.title) {
            commandContext?.perform(action)
        }
        .disabled(commandContext?.isEnabled(action) != true)
        .keyboardShortcut(
            shortcuts.shortcut(for: action)?.swiftUIShortcut
        )
    }
}

private struct CheckForUpdatesCommand: View {
    @ObservedObject var updateController: AppUpdateController

    var body: some View {
        Button("Check for Updates…") {
            updateController.checkForUpdates()
        }
        .disabled(!updateController.canCheckForUpdates)
        .help(updateController.availabilityDescription)
    }
}
