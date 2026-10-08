import Foundation

nonisolated extension SettingsControlID {
    static let notificationMessageSound = Self(rawValue: "notifications.message-sound")
    static let notificationCallRingtone = Self(rawValue: "notifications.call-ringtone")
}

nonisolated extension SettingsCatalog {
    static let notificationsPage = page(
        .notifications, group: .preferences, title: "Notifications", image: "bell",
        help: "Narrow local macOS notification delivery while preserving Discord server and channel settings.",
        keywords: ["alerts", "sound", "badge", "permission", "preview"]
    )

    static let notificationsControls: [SettingsControlMetadata] = [
        control(
            .notificationPermission,
            page: .notifications,
            section: .notificationDelivery,
            label: "macOS permission",
            help: "Show or request the current macOS notification authorization.",
            keywords: ["allow", "denied", "System Settings"],
            owner: .macOS,
            scope: .appWideLocal,
            persistence: .systemManaged,
            reset: .notApplicable
        ),
        control(
            .notificationEnabled,
            page: .notifications,
            section: .notificationDelivery,
            label: "Desktop notifications",
            help: "Allow eligible Discord events to appear as local macOS notifications.",
            keywords: ["alerts", "master"],
            scope: .appWideLocal
        ),
        control(
            .notificationPreview,
            page: .notifications,
            section: .notificationDelivery,
            label: "Notification previews",
            help: "Choose how much message information appears in notifications.",
            keywords: ["sender", "hidden", "privacy"],
            scope: .appWideLocal
        ),
        control(
            .notificationSound,
            page: .notifications,
            section: .notificationDelivery,
            label: "Notification sound",
            help: "Play the Discord message sound with desktop alerts, or through SakuraCord when desktop notifications are off.",
            keywords: ["audio", "alert", "Focus"],
            scope: .appWideLocal
        ),
        control(
            .notificationMessageSound,
            page: .notifications,
            section: .notificationDelivery,
            label: "Message sound",
            help: "Choose the sound played for message notifications.",
            keywords: ["audio", "alert", "custom"],
            scope: .appWideLocal
        ),
        control(
            .notificationCallRingtone,
            page: .notifications,
            section: .notificationDelivery,
            label: "Call ringtone",
            help: "Choose the sound played for incoming calls.",
            keywords: ["ring", "audio", "custom"],
            scope: .appWideLocal
        ),
        control(
            .notificationDockBadge,
            page: .notifications,
            section: .notificationDelivery,
            label: "Dock badge",
            help: "Show unread mentions, reliably projected unread conversations, or no Dock badge.",
            keywords: ["badge", "mentions", "unread conversations", "off"],
            scope: .appWideLocal
        ),

        control(
            .notificationDirectMessages, page: .notifications, section: .notificationEvents,
            label: "Direct messages", help: "Allow one-to-one direct messages, including mentions and replies.",
            keywords: ["DM", "private message"], scope: .appWideLocal
        ),
        control(
            .notificationGroupDirectMessages, page: .notifications,
            section: .notificationEvents, label: "Group messages",
            help: "Allow group direct messages, including mentions and replies.",
            keywords: ["group DM", "private group"], scope: .appWideLocal
        ),
        control(
            .notificationMentions, page: .notifications, section: .notificationEvents,
            label: "Server mentions", help: "Allow eligible direct, role, and everyone mentions in servers.",
            keywords: ["@mention", "role", "everyone"], scope: .appWideLocal
        ),
        control(
            .notificationReplies, page: .notifications, section: .notificationEvents,
            label: "Server replies", help: "Allow eligible replies to your messages in servers.",
            keywords: ["reply", "response"], scope: .appWideLocal
        ),
        control(
            .notificationIncomingCalls, page: .notifications, section: .notificationEvents,
            label: "Incoming calls", help: "Allow native alerts for newly ringing private calls.",
            keywords: ["call", "ring", "voice"], scope: .appWideLocal
        ),
        control(
            .notificationServerActivity, page: .notifications, section: .notificationEvents,
            label: "Server messages", help: "Allow ordinary server messages already eligible under Discord's notification settings.",
            keywords: ["guild", "all messages", "server"], scope: .appWideLocal
        ),
        control(
            .notificationSuppressCurrent, page: .notifications,
            section: .notificationEvents, label: "Skip the conversation I’m reading",
            help: "Do not alert for a conversation already presented at its newest message.",
            keywords: ["open channel", "visible", "current chat"], scope: .appWideLocal
        ),
        control(
            .notificationGroupBursts, page: .notifications,
            section: .notificationEvents, label: "Group notifications by conversation",
            help: "Assign a native Notification Center thread to each account and conversation.",
            keywords: ["thread", "stack", "deduplicate", "group"], scope: .appWideLocal
        ),
        control(
            .notificationClearWhenRead, page: .notifications,
            section: .notificationEvents, label: "Clear notifications when read",
            help: "Remove delivered and pending message notifications when their conversation is acknowledged.",
            keywords: ["dismiss", "mark read", "remove delivered"], scope: .appWideLocal
        ),
        control(
            .notificationReset, page: .notifications,
            section: .notificationLocalData, label: "Reset Notification Settings",
            help: "Restore SakuraCord's local Notification preferences without changing macOS authorization or Discord settings.",
            keywords: ["defaults", "restore", "clear preferences"], scope: .appWideLocal,
            persistence: .appPreferences, reset: .categoryAction
        ),
    ]
}
