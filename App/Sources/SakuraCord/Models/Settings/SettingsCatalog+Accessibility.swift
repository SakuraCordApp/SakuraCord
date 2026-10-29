import Foundation

nonisolated extension SettingsCatalog {
    static let accessibilityPage = page(
        .accessibility, group: .preferences, title: "Accessibility", image: "accessibility",
        help: "Choose motion, cosmetic, link, role colour, and VoiceOver preferences.",
        keywords: ["cosmetics", "profiles", "VoiceOver", "links", "role colors"]
    )

    static let accessibilityControls: [SettingsControlMetadata] = [
        control(
            .accessibilityDisableSendAnimations, page: .accessibility,
            section: .accessibilityMotion, label: "Disable message sending animations",
            help: "Show sent messages immediately in both bubble and normal appearance. macOS Reduce Motion also disables these animations.",
            keywords: ["motion", "send", "animation", "bubbles", "attachments"], scope: .appWideLocal
        ),
        control(
            .accessibilityDisableAllAnimations, page: .accessibility,
            section: .accessibilityMotion, label: "Disable all animations",
            help: "Show every SakuraCord animation as an instant change.",
            keywords: ["motion", "animation", "reduce motion", "instant"], scope: .appWideLocal
        ),
        control(
            .accessibilityDisableSidebarAnimations, page: .accessibility,
            section: .accessibilityMotion, label: "Disable sidebar and member list animations",
            help: "Show or hide the channel sidebar, member list, and search results without animation.",
            keywords: ["motion", "animation", "sidebar", "members", "inspector", "search results"], scope: .appWideLocal
        ),
        control(
            .accessibilityDisableSideChatAnimations, page: .accessibility,
            section: .accessibilityMotion, label: "Disable side chat and full width animations",
            help: "Open, close, and widen side chats without animation.",
            keywords: ["motion", "animation", "threads", "side chat", "pane", "full width"], scope: .appWideLocal
        ),
        control(
            .accessibilityDisableOverlayAnimations, page: .accessibility,
            section: .accessibilityMotion, label: "Disable search, popover and overlay animations",
            help: "Show search, popovers, menus, and overlays without animation.",
            keywords: ["motion", "animation", "search", "popover", "modal", "menu", "dropdown"], scope: .appWideLocal
        ),
        control(
            .accessibilityDisableProfileEffects, page: .accessibility,
            section: .accessibilityCosmetics, label: "Profile effects",
            help: "Hide profile effects in SakuraCord.",
            keywords: ["disable cosmetics", "profile"], scope: .appWideLocal
        ),
        control(
            .accessibilityDisableNameplates, page: .accessibility,
            section: .accessibilityCosmetics, label: "Nameplates",
            help: "Hide nameplates in SakuraCord.",
            keywords: ["disable cosmetics", "profile"], scope: .appWideLocal
        ),
        control(
            .accessibilityDisableAvatarDecorations, page: .accessibility,
            section: .accessibilityCosmetics, label: "Avatar decorations",
            help: "Hide avatar decorations in SakuraCord.",
            keywords: ["disable cosmetics", "profile"], scope: .appWideLocal
        ),
        control(
            .accessibilityDisableProfileFrames, page: .accessibility,
            section: .accessibilityCosmetics, label: "Profile frames",
            help: "Hide profile frames in SakuraCord.",
            keywords: ["disable cosmetics", "profile"], scope: .appWideLocal
        ),
        control(
            .accessibilityDisableNameStyles, page: .accessibility,
            section: .accessibilityCosmetics, label: "Name styles",
            help: "Hide name styles in SakuraCord.",
            keywords: ["disable cosmetics", "profile"], scope: .appWideLocal
        ),
        control(
            .accessibilityDisableProfileGradients, page: .accessibility,
            section: .accessibilityCosmetics, label: "Nitro profile gradients",
            help: "Hide nitro profile gradients in SakuraCord.",
            keywords: ["disable cosmetics", "profile"], scope: .appWideLocal
        ),
        control(
            .accessibilityDisableServerTags, page: .accessibility,
            section: .accessibilityCosmetics, label: "Server tags",
            help: "Hide server tags in SakuraCord.",
            keywords: ["disable cosmetics", "profile", "guild tag", "clan tag", "badge"], scope: .appWideLocal
        ),
        control(
            .accessibilityDisableOwnCosmetics, page: .accessibility,
            section: .accessibilityCosmetics, label: "Disable own",
            help: "Apply the selected cosmetic restrictions to your own profile too.",
            keywords: ["disable cosmetics", "own profile"], scope: .appWideLocal
        ),
        control(
            .underlineLinks, page: .accessibility, section: .accessibilityReadability,
            label: "Underline links", help: "Always use the hover underline for message links.",
            keywords: ["links", "URL", "readability"], scope: .appWideLocal
        ),
        control(
            .roleColorDisplay, page: .accessibility, section: .accessibilityReadability,
            label: "Role colours", help: "Show role colours in names, next to names, or hide them.",
            keywords: ["roles", "color", "colour", "names"], scope: .appWideLocal
        ),
        control(
            .accessibilityAnnounceTimestamp, page: .accessibility,
            section: .accessibilityVoiceOver, label: "Include timestamps",
            help: "Include each message timestamp in its VoiceOver row summary.",
            keywords: ["VoiceOver", "time", "message metadata"], scope: .appWideLocal
        ),
        control(
            .accessibilityAnnounceEdited, page: .accessibility,
            section: .accessibilityVoiceOver, label: "Include edited status",
            help: "Announce when a message has been edited.",
            keywords: ["VoiceOver", "modified", "message metadata"], scope: .appWideLocal
        ),
        control(
            .accessibilityAnnounceReactions, page: .accessibility,
            section: .accessibilityVoiceOver, label: "Include reaction counts",
            help: "Include the total reaction count in a message's VoiceOver row summary.",
            keywords: ["VoiceOver", "emoji", "reaction metadata"], scope: .appWideLocal
        ),
        control(
            .accessibilityAnnounceAttachmentTypes, page: .accessibility,
            section: .accessibilityVoiceOver, label: "Include attachment types",
            help: "Summarize image, video, audio, and file attachment types for VoiceOver.",
            keywords: ["VoiceOver", "media", "file type"], scope: .appWideLocal
        ),
        control(
            .accessibilityAnnounceNewMessages, page: .accessibility,
            section: .accessibilityVoiceOver, label: "Announce new messages",
            help: "While VoiceOver is running, announce grouped incoming-message counts without speaking message content or sender identity.",
            keywords: ["VoiceOver", "live messages", "privacy", "throttle"], scope: .appWideLocal
        ),

        control(
            .accessibilityReset, page: .accessibility,
            section: .accessibilityLocalData, label: "Reset Accessibility Settings",
            help: "Restore SakuraCord accessibility preferences without changing macOS accessibility settings.",
            keywords: ["defaults", "restore", "system settings"], scope: .appWideLocal,
            persistence: .appPreferences, reset: .categoryAction
        ),
    ]
}
