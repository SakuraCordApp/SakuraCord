import SwiftUI

struct SakuraCordCommands: Commands {
    let model: AppModel
    let updateController: AppUpdateController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesCommand(updateController: updateController)
        }

        CommandMenu("Navigate") {
            Button("Quick Switch…") {
                model.presentQuickSwitcher()
            }
            .keyboardShortcut("k")

            Button("Search Messages…") {
                model.presentMessageSearch()
            }
            .keyboardShortcut("f")

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

            Button("Toggle Member Inspector") { NotificationCenter.default.post(name: .sakuracordToggleInspector, object: nil) }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Focus Composer") { NotificationCenter.default.post(name: .sakuracordFocusComposer, object: nil) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
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
