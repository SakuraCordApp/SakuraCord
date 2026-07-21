import SwiftUI

struct SakuraCordCommands: Commands {
    var body: some Commands {
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
