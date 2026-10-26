import Foundation

extension Notification.Name {
    static let sakuracordMessageReactionDidChange = Notification.Name("dev.sakuracord.message-reaction-did-change")
    static let sakuracordComposerPicker = Notification.Name("dev.sakuracord.composer-picker")
    static let sakuracordToggleSoundboard = Notification.Name("dev.sakuracord.toggle-soundboard")
    static let sakuracordToggleChannelSidebar = Notification.Name(
        "dev.sakuracord.toggle-channel-sidebar"
    )
    static let sakuracordFocusComposer = Notification.Name("dev.sakuracord.focus-composer")
    static let sakuracordChooseComposerAttachment = Notification.Name(
        "dev.sakuracord.choose-composer-attachment"
    )
    static let sakuracordNotificationDeepLink = Notification.Name(
        "dev.sakuracord.notification-deep-link"
    )
    static let sakuracordMessageRowsDidChange = Notification.Name(
        "dev.sakuracord.message-rows-did-change"
    )
}
