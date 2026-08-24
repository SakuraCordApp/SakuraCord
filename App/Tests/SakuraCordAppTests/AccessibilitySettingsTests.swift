@testable import SakuraCord
import Foundation
import SakuraCordModels
import Testing

@MainActor
private final class VoiceOverAnnouncementTestState {
    var isEnabled = false
    var announcements: [String] = []
}

@MainActor
@Test func `Accessibility preferences persist export and reset by category`() {
    let defaults = InMemoryPreferences()
    let preferences = SettingsPreferenceStore(defaults: defaults)
    let store = AccessibilitySettingsStore(preferences: preferences)

    var value = store.load()
    #expect(value == .defaults)
    value.motionOverride = .alwaysReduce
    value.reducesAnimatedEmoji = true
    value.increasesContrast = true
    value.announcesNewMessages = true
    store.save(value)

    #expect(store.load() == value)
    let export = preferences.export(scope: .appWide, page: .accessibility)
    #expect(
        export.values[SettingsControlID.accessibilityMotionOverride.rawValue]
            == .string(AccessibilityMotionOverride.alwaysReduce.rawValue)
    )
    #expect(
        export.values[SettingsControlID.accessibilityAnnounceNewMessages.rawValue]
            == .bool(true)
    )
    #expect(export.values[SettingsControlID.chatAutoplayGIFs.rawValue] == nil)

    preferences.reset(scope: .appWide, page: .accessibility)
    #expect(store.load() == .defaults)
}

@Test func `Accessibility motion policy only strengthens system choices`() {
    var settings = AccessibilitySettingsSnapshot.defaults
    #expect(!settings.reducesAnimation(.gif, systemReduceMotion: false))
    #expect(settings.reducesAnimation(.gif, systemReduceMotion: true))

    settings.reducesAnimatedEmoji = true
    #expect(settings.reducesAnimation(.emoji, systemReduceMotion: false))
    #expect(!settings.reducesAnimation(.sticker, systemReduceMotion: false))

    settings.reducesAnimatedContent = true
    for category in [
        AccessibilityAnimationCategory.emoji,
        .sticker,
        .gif,
        .avatar,
        .decoration,
        .transition,
    ] {
        #expect(settings.reducesAnimation(category, systemReduceMotion: false))
    }

    settings.reducesAnimatedContent = false
    settings.motionOverride = .alwaysReduce
    #expect(settings.reducesAllOptionalMotion(systemReduceMotion: false))
}

@Test func `VoiceOver metadata follows each configured field`() throws {
    let url = try #require(URL(string: "https://example.com/file"))
    let message = Message(
        id: MessageID(rawValue: 1),
        channelID: ChannelID(rawValue: 2),
        author: User(
            id: UserID(rawValue: 3),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: "Private message text must not enter metadata summaries.",
        editedTimestamp: .now,
        attachments: [
            Attachment(
                id: "image",
                filename: "image.png",
                url: url,
                mediaType: "image/png"
            ),
            Attachment(
                id: "audio",
                filename: "audio.m4a",
                url: url,
                mediaType: "audio/mp4"
            ),
        ],
        reactions: [Reaction(emoji: "✅", count: 3)]
    )

    let complete = AccessibilityMessageMetadataPolicy.summary(
        for: message,
        timestamp: "10:30 AM",
        settings: .defaults
    )
    #expect(complete == [
        "10:30 AM",
        "edited",
        "3 reactions",
        "1 image attachment",
        "1 audio attachment",
    ])
    #expect(!complete.joined().contains(message.content))

    var minimal = AccessibilitySettingsSnapshot.defaults
    minimal.announcesTimestamps = false
    minimal.announcesEditedStatus = false
    minimal.announcesReactionCounts = false
    minimal.announcesAttachmentTypes = false
    #expect(
        AccessibilityMessageMetadataPolicy.summary(
            for: message,
            timestamp: "10:30 AM",
            settings: minimal
        ).isEmpty
    )
}

@MainActor
@Test func `VoiceOver new message announcements are generic grouped and gated`() {
    let state = VoiceOverAnnouncementTestState()
    let announcer = AccessibilityMessageAnnouncer(
        isVoiceOverEnabled: { state.isEnabled },
        post: { state.announcements.append($0) }
    )

    announcer.enqueue()
    announcer.flush()
    #expect(state.announcements.isEmpty)

    state.isEnabled = true
    announcer.enqueue()
    announcer.enqueue()
    announcer.enqueue()
    announcer.flush()
    #expect(state.announcements == ["3 new messages"])

    announcer.enqueue()
    announcer.flush()
    #expect(state.announcements == ["3 new messages", "New message"])

    announcer.enqueue()
    state.isEnabled = false
    announcer.flush()
    #expect(state.announcements == ["3 new messages", "New message"])
}

@Test func `Larger message action targets preserve control count geometry`() {
    let normal = HoverActionPillMetrics.size(controlCount: 4)
    let enlarged = HoverActionPillMetrics.size(
        controlCount: 4,
        enlarged: true
    )
    #expect(normal.height == 36)
    #expect(enlarged.height == 44)
    #expect(enlarged.width - normal.width == 32)
}

@Test func `Timeline animation roles map to accessibility categories`() {
    #expect(
        NativeTimelineCanvasView.AnimatedMediaOverlayRole.authorAvatar
            .accessibilityCategory == .avatar
    )
    #expect(
        NativeTimelineCanvasView.AnimatedMediaOverlayRole.authorAvatarDecoration
            .accessibilityCategory == .decoration
    )
    #expect(
        NativeTimelineCanvasView.AnimatedMediaOverlayRole.messageEmoji(0)
            .accessibilityCategory == .emoji
    )
    #expect(
        NativeTimelineCanvasView.AnimatedMediaOverlayRole.sticker("1")
            .accessibilityCategory == .sticker
    )
    #expect(
        NativeTimelineCanvasView.AnimatedMediaOverlayRole.attachment("1")
            .accessibilityCategory == .gif
    )
}
