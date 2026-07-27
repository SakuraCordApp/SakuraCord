import Foundation

extension Notification.Name {
    static let sakuracordQuickSwitcher = Notification.Name("dev.sakuracord.quick-switcher")
    static let sakuracordToggleInspector = Notification.Name("dev.sakuracord.toggle-inspector")
    static let sakuracordFocusComposer = Notification.Name("dev.sakuracord.focus-composer")
    static let sakuracordNotificationDeepLink = Notification.Name(
        "dev.sakuracord.notification-deep-link"
    )
    static let sakuracordMessageRowsDidChange = Notification.Name(
        "dev.sakuracord.message-rows-did-change"
    )
}
