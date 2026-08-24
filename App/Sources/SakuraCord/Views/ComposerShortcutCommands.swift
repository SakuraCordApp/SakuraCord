import SwiftUI

extension View {
    func composerShortcutCommands(
        conversation: MessageComposerDestination,
        focus: @escaping () -> Void,
        editLatest: @escaping () -> Void,
        chooseAttachment: @escaping () -> Void
    ) -> some View {
        onReceive(
            NotificationCenter.default.publisher(
                for: .sakuracordFocusComposer
            )
        ) { notification in
            if Self.targets(notification, conversation: conversation) {
                focus()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .sakuracordEditLastMessage
            )
        ) { notification in
            if Self.targets(notification, conversation: conversation) {
                editLatest()
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
