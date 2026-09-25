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
            ShortcutCommandButton(
                action: .toggleChannelSidebar
            )
        }

        CommandMenu("Navigate") {
            ShortcutCommandButton(action: .quickSwitch)
            ShortcutCommandButton(action: .messageSearch)

            Divider()

            ShortcutCommandButton(action: .previousConversation)
            ShortcutCommandButton(action: .nextConversation)
            ShortcutCommandButton(action: .previousUnread)
            ShortcutCommandButton(action: .nextUnread)
            ShortcutCommandButton(action: .previousMention)
            ShortcutCommandButton(action: .nextMention)
            ShortcutCommandButton(action: .previousServer)
            ShortcutCommandButton(action: .nextServer)
            ShortcutCommandButton(action: .currentCall)
            ShortcutCommandButton(action: .navigateBack)
            ShortcutCommandButton(action: .navigateForward)
            ShortcutCommandButton(action: .previousTextChannel)
            ShortcutCommandButton(action: .toggleDirectMessages)

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

            Divider()

            ShortcutCommandButton(action: .toggleMemberList)
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
            ShortcutCommandButton(action: .togglePins)
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
    @FocusedValue(\.shortcutCommandContext) private var commandContext
    private let shortcuts = KeyboardShortcutSettingsStore.shared

    var body: some View {
        Button(action.title) {
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
