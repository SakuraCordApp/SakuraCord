import Foundation

extension Notification.Name {
    static let marrowchatToggleInspector = Notification.Name("dev.marrowchat.toggle-inspector")
    static let marrowchatFocusComposer = Notification.Name("dev.marrowchat.focus-composer")
    static let marrowchatNotificationDeepLink = Notification.Name(
        "dev.marrowchat.notification-deep-link"
    )
    static let marrowchatMessageRowsDidChange = Notification.Name(
        "dev.marrowchat.message-rows-did-change"
    )
}
