import Foundation

nonisolated extension SettingsCatalog {
    static let interfacePage = page(
        .interface, group: .preferences, title: "Appearance", image: "circle.lefthalf.filled",
        help: "Choose interface size, message appearance, input bar icons, and timestamps.",
        keywords: ["messages", "bubbles", "density", "composer", "input bar", "clock", "timestamp", "zoom", "size"]
    )

    static let interfaceControls: [SettingsControlMetadata] = [
        control(
            .interfaceSize,
            page: .interface,
            section: .interfaceSize,
            label: "Interface size",
            help: "Make text, icons, and controls throughout SakuraCord smaller or larger.",
            keywords: ["zoom", "scale", "text size", "font size", "larger", "smaller", "readability"],
            scope: .appWideLocal
        ),
        control(
            .messageAppearance,
            page: .interface,
            section: .interfaceMessages,
            label: "Server channels",
            help: "Choose the message layout for server channels and threads.",
            keywords: ["messages", "bubbles", "iMessage", "chat", "layout", "default"],
            scope: .appWideLocal
        ),
        control(
            .directMessageAppearance, page: .interface, section: .interfaceMessages,
            label: "Direct messages", help: "Choose the message layout for one-to-one conversations.",
            keywords: ["DM", "private", "bubbles", "default", "layout"], scope: .appWideLocal
        ),
        control(
            .groupMessageAppearance, page: .interface, section: .interfaceMessages,
            label: "Group chats", help: "Choose the message layout for group direct messages.",
            keywords: ["group DM", "bubbles", "default", "layout"], scope: .appWideLocal
        ),
        control(
            .messageFontSize,
            page: .interface,
            section: .interfaceMessages,
            label: "Font size",
            help: "Make message text smaller or larger without changing the rest of the interface.",
            keywords: ["messages", "font size", "text", "larger", "smaller", "readability"],
            scope: .appWideLocal
        ),
        control(
            .messageDensity,
            page: .interface,
            section: .interfaceMessages,
            label: "Density",
            help: "Adjust the vertical spacing between messages.",
            keywords: ["messages", "density", "spacing", "compact", "comfortable"],
            scope: .appWideLocal
        ),
        control(
            .composerBarAppearance,
            page: .interface,
            section: .interfaceInputBar,
            label: "Input bar",
            help: "Choose the current split input bar or SakuraCord's legacy unified input bar.",
            keywords: ["composer", "message input", "default", "legacy", "pill"],
            scope: .appWideLocal
        ),
        control(
            .resetMessageAppearance,
            page: .interface,
            section: .interfaceMessages,
            label: "Reset to Defaults",
            help: "Restore the default message layout, font size, and density without changing other Appearance settings.",
            keywords: ["messages", "defaults", "restore", "reset", "font size", "density"],
            scope: .appWideLocal,
            reset: .categoryAction
        ),
        control(
            .timestampFormat,
            page: .interface,
            section: .interfaceTime,
            label: "Timestamp format",
            help: "Use the locale-aware system clock or an explicit 12- or 24-hour clock.",
            keywords: ["clock", "time", "12 hour", "24 hour", "timestamp"],
            scope: .appWideLocal
        ),
        control(
            .timestampSeconds,
            page: .interface,
            section: .interfaceTime,
            label: "Show seconds",
            help: "Include seconds in message timestamps, including grouped messages.",
            keywords: ["clock seconds", "precise time", "grouped timestamp"],
            scope: .appWideLocal
        ),
        control(
            .alwaysShowTimestamps, page: .interface, section: .interfaceTime,
            label: "Always show timestamps", help: "Keep grouped message timestamps visible without hovering.",
            keywords: ["time", "hover", "grouped"], scope: .appWideLocal
        ),
        control(
            .composerIcons, page: .interface, section: .interfaceInputBar,
            label: "Input bar icons", help: "Drag icons to reorder them.",
            keywords: ["composer", "GIF", "sticker", "emoji", "reorder"], scope: .appWideLocal
        ),
    ]
}
