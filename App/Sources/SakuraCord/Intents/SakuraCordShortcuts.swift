import AppIntents
import Foundation

nonisolated struct SakuraCordShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenConversationIntent(),
            phrases: [
                "Open \(.applicationName) conversation",
                "Open conversation in \(.applicationName)",
                "Show \(.applicationName) conversation"
            ],
            shortTitle: "Open Conversation",
            systemImageName: "bubble.left"
        )
        AppShortcut(
            intent: SetStatusIntent(),
            phrases: [
                "Set my \(.applicationName) status",
                "Change my \(.applicationName) status"
            ],
            shortTitle: "Set Status",
            systemImageName: "circle.circle"
        )
        AppShortcut(
            intent: ToggleVoiceMuteIntent(),
            phrases: [
                "Toggle \(.applicationName) mute",
                "Mute on \(.applicationName)"
            ],
            shortTitle: "Toggle Mute",
            systemImageName: "mic"
        )
        AppShortcut(
            intent: ToggleVoiceDeafenIntent(),
            phrases: [
                "Toggle \(.applicationName) deafen",
                "Deafen on \(.applicationName)"
            ],
            shortTitle: "Toggle Deafen",
            systemImageName: "headphones"
        )
    }
}
