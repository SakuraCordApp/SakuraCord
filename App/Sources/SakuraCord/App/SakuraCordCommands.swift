import SwiftUI

struct SakuraCordCommands: Commands {
    let updateController: AppUpdateController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesCommand(updateController: updateController)
        }

        CommandMenu("Navigate") {
            Button("Quick Switcher") { NotificationCenter.default.post(name: .sakuracordQuickSwitcher, object: nil) }
                .keyboardShortcut("k")
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
