import SwiftUI

extension View {
    func composerShortcutCommands(
        conversation: MessageComposerDestination,
        focus: @escaping (NSRange?) -> Void,
        chooseAttachment: @escaping () -> Void,
        togglePicker: @escaping (KeyboardShortcutAction) -> Void
    ) -> some View {
        onReceive(
            NotificationCenter.default.publisher(
                for: .sakuracordFocusComposer
            )
        ) { notification in
            if Self.targets(notification, conversation: conversation) {
                focus(notification.userInfo?["selection"] as? NSRange)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .sakuracordChooseComposerAttachment
            )
        ) { notification in
            if Self.targets(notification, conversation: conversation) {
                chooseAttachment()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sakuracordComposerPicker)) { notification in
            if Self.targets(notification, conversation: conversation),
               let action = notification.userInfo?["action"] as? KeyboardShortcutAction {
                togglePicker(action)
            }
        }
    }

    private static func targets(
        _ notification: Notification,
        conversation: MessageComposerDestination
    ) -> Bool {
        guard let destination = notification.object as? MessageComposerDestination else {
            return true
        }
        return destination == conversation
    }
}
