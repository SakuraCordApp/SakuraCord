import SwiftUI

struct SakuraCordCommands: Commands {
    let model: AppModel
    let updateController: AppUpdateController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesCommand(updateController: updateController)
        }

        CommandGroup(replacing: .appSettings) {
            SettingsShortcutCommand()
        }

        CommandGroup(replacing: .sidebar) {
            ShortcutCommandButton(
                action: .toggleChannelSidebar,
                model: model
            )
        }

        CommandMenu("Navigate") {
            ShortcutCommandButton(action: .quickSwitch, model: model)
            ShortcutCommandButton(action: .messageSearch, model: model)

            Divider()

            ShortcutCommandButton(action: .previousConversation, model: model)
            ShortcutCommandButton(action: .nextConversation, model: model)
            ShortcutCommandButton(action: .previousUnread, model: model)
            ShortcutCommandButton(action: .nextUnread, model: model)
            ShortcutCommandButton(action: .currentCall, model: model)

            Divider()

            Button("Direct Messages") {
                model.navigateUsingShortcut(1)
            }
            .keyboardShortcut("1")

            ForEach(2 ... 9, id: \.self) { shortcutNumber in
                Button("Server \(shortcutNumber - 1)") {
                    model.navigateUsingShortcut(shortcutNumber)
                }
                .keyboardShortcut(
                    KeyEquivalent(Character(String(shortcutNumber)))
                )
            }

            Divider()

            ShortcutCommandButton(action: .toggleMemberList, model: model)
        }

        CommandMenu("Message") {
            ShortcutCommandButton(action: .focusComposer, model: model)
            ShortcutCommandButton(action: .editLastMessage, model: model)
            ShortcutCommandButton(action: .reply, model: model)
            ShortcutCommandButton(action: .upload, model: model)

            Divider()

            ShortcutCommandButton(
                action: .searchCurrentConversation,
                model: model
            )
            ShortcutCommandButton(action: .markRead, model: model)
        }

        CommandMenu("Voice") {
            ShortcutCommandButton(action: .toggleMute, model: model)
            ShortcutCommandButton(action: .toggleDeafen, model: model)
            ShortcutCommandButton(action: .toggleCamera, model: model)
            ShortcutCommandButton(action: .toggleScreenShare, model: model)

            Divider()

            ShortcutCommandButton(action: .leaveCall, model: model)
        }
    }
}

private struct ShortcutCommandButton: View {
    let action: KeyboardShortcutAction
    let model: AppModel
    private let shortcuts = KeyboardShortcutSettingsStore.shared

    var body: some View {
        Button(action.title) {
            model.performKeyboardShortcutAction(action)
        }
        .disabled(!model.keyboardShortcutActionIsEnabled(action))
        .keyboardShortcut(
            action.registersMenuShortcut
                ? shortcuts.shortcut(for: action)?.swiftUIShortcut
                : nil
        )
    }
}

private struct SettingsShortcutCommand: View {
    @Environment(\.openSettings) private var openSettings
    private let shortcuts = KeyboardShortcutSettingsStore.shared

    var body: some View {
        Button(KeyboardShortcutAction.openSettings.title) {
            openSettings()
        }
        .keyboardShortcut(
            shortcuts.shortcut(for: .openSettings)?.swiftUIShortcut
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
