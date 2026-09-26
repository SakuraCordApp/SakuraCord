import Foundation

nonisolated extension SettingsCatalog {
    static let featuresPage = page(
        .features, group: .preferences, title: "Features", image: "square.stack.3d.up.fill",
        help: "Manage hidden channels, FakeNitro, and attachments.",
        keywords: ["channels", "hidden", "FakeNitro", "emoji", "stickers", "soundboard", "stream", "uploads"]
    )

    static let featuresControls: [SettingsControlMetadata] = [
        control(
            .channelManagement, page: .features, section: .featuresChannels,
            label: "Channel customization", help: "Choose which channels appear in each server through Channels & Roles.",
            keywords: ["onboarding", "channels", "roles", "default channels"], scope: .appWideLocal
        ),
        control(
            .showHiddenChannels, page: .features, section: .featuresChannels,
            label: "Show hidden channels", help: "Show channels you cannot access, including their available metadata.",
            keywords: ["features", "hidden channels"], scope: .appWideLocal
        ),
        control(
            .fakeNitroEmojis, page: .features, section: .featuresFakeNitro,
            label: "FakeNitro emojis", help: "Send unavailable custom emojis as image links.",
            keywords: ["features", "FakeNitro"], scope: .appWideLocal
        ),
        control(
            .fakeNitroStickers, page: .features, section: .featuresFakeNitro,
            label: "FakeNitro stickers", help: "Send stickers from other servers as image uploads.",
            keywords: ["features", "FakeNitro"], scope: .appWideLocal
        ),
        control(
            .fakeNitroSoundboard, page: .features, section: .featuresFakeNitro,
            label: "FakeNitro soundboard", help: "Play sounds from other servers through your outgoing audio.",
            keywords: ["features", "FakeNitro"], scope: .appWideLocal
        ),
        control(
            .fakeNitroStreamQuality, page: .features, section: .featuresFakeNitro,
            label: "FakeNitro stream quality", help: "Use higher stream resolutions and frame rates without Nitro.",
            keywords: ["features", "FakeNitro"], scope: .appWideLocal
        ),
        control(
            .attachmentCompactionPrompt, page: .features, section: .featuresAttachments,
            label: "Compress oversized images and videos",
            help: "Choose whether to compress oversized images and videos automatically, ask first, or never compress.",
            keywords: ["attachment", "compression", "compaction", "upload", "file size"], scope: .appWideLocal
        ),
        control(
            .attachmentExternalUploadPrompt, page: .features, section: .featuresAttachments,
            label: "Upload files that still exceed Discord’s limit",
            help: "Uploads to a third-party host and adds a link to your draft.",
            keywords: ["attachment", "compression", "compaction", "upload", "file size"], scope: .appWideLocal
        ),
        control(
            .attachmentExternalProvider, page: .features, section: .featuresAttachments,
            label: "File host", help: "Choose the third-party host for automatic oversized uploads.",
            keywords: ["catbox", "litterbox", "upload"], scope: .appWideLocal
        ),
        control(
            .attachmentCompactionQuality, page: .features, section: .featuresAttachments,
            label: "Compression quality",
            help: "Choose between higher quality, balanced compression, and smaller files.",
            keywords: ["attachment", "compression", "compaction", "upload", "file size"], scope: .appWideLocal
        ),
    ]
}
