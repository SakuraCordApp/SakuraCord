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
    value.disablesMessageSendingAnimations = true
    value.disablesAllAnimations = true
    value.disablesSidebarAnimations = true
    value.disablesSideChatAnimations = true
    value.disablesOverlayAnimations = true
    value.disablesProfileEffects = true
    value.disablesNameplates = true
    value.disablesAvatarDecorations = true
    value.disablesProfileFrames = true
    value.disablesNameStyles = true
    value.disablesProfileGradients = true
    value.disablesServerTags = true
    value.disablesOwnCosmetics = true
    value.announcesNewMessages = true
    store.save(value)

    #expect(store.load() == value)
    let export = preferences.export(scope: .appWide, page: .accessibility)
    #expect(
        export.values[SettingsControlID.accessibilityDisableProfileEffects.rawValue]
            == .bool(true)
    )
    #expect(
        export.values[SettingsControlID.accessibilityDisableServerTags.rawValue]
            == .bool(true)
    )
    #expect(
        export.values[SettingsControlID.accessibilityAnnounceNewMessages.rawValue]
            == .bool(true)
    )
    #expect(export.values[SettingsControlID.smartQuotes.rawValue] == nil)

    preferences.reset(scope: .appWide, page: .accessibility)
    #expect(store.load() == .defaults)
}

@MainActor
@Test func `Motion categories snap when disabled by their switch or the master`() {
    var settings = AccessibilitySettingsSnapshot.defaults
    #expect(AppMotionPolicy.animates([.sidebar, .sideChats, .overlays], settings: settings, reducesMotion: false))
    #expect(!AppMotionPolicy.animates([.sidebar], settings: settings, reducesMotion: true))

    settings.disablesSideChatAnimations = true
    #expect(AppMotionPolicy.animates([.sidebar], settings: settings, reducesMotion: false))
    #expect(!AppMotionPolicy.animates([.sidebar, .sideChats], settings: settings, reducesMotion: false))

    settings = .defaults
    settings.disablesAllAnimations = true
    #expect(!AppMotionPolicy.animates([.overlays], settings: settings, reducesMotion: false))
}

@Test func `Cosmetic restrictions preserve own profile except disabled server tags`() throws {
    let ownID = UserID(rawValue: 1)
    let otherID = UserID(rawValue: 2)
    let decoration = try #require(URL(string: "https://example.com/decoration.png"))
    let serverTag = PrimaryGuildIdentity(guildID: GuildID(rawValue: 3), tag: "TAG")
    let user = User(id: otherID, username: "fixture", displayName: "Fixture",
                    avatarDecorationURL: decoration, primaryGuild: serverTag,
                    displayNameStyle: DisplayNameStyle(fontID: 1))
    var settings = AccessibilitySettingsSnapshot.defaults
    #expect(!settings.disablesOwnCosmetics)
    var policy = ProfileCosmeticPolicy(settings: settings, currentUserID: ownID)
    #expect(policy.user(user) == user)
    settings.disablesAvatarDecorations = true
    settings.disablesNameStyles = true
    settings.disablesServerTags = true
    policy.settings = settings
    #expect(policy.user(user).avatarDecorationURL == nil)
    #expect(policy.user(user).displayNameStyle == nil)
    #expect(policy.user(user).primaryGuild == nil)
    #expect(policy.member(Member(user: user, roleName: "Member", status: .online)).user.primaryGuild == nil)
    #expect(user.avatarDecorationURL == decoration)
    #expect(user.primaryGuild == serverTag)
    #expect(policy.user(user).username == user.username)
    policy.currentUserID = otherID
    var ownPresentation = user
    ownPresentation.primaryGuild = nil
    #expect(policy.user(user) == ownPresentation)
    policy.settings.disablesOwnCosmetics = true
    #expect(policy.user(user).avatarDecorationURL == nil)
    #expect(policy.user(user).displayNameStyle == nil)
    policy.settings.disablesAvatarDecorations = false
    #expect(policy.user(user).avatarDecorationURL == decoration)
    #expect(policy.user(user).displayNameStyle == nil)
    policy.settings.disablesServerTags = false
    #expect(policy.user(user).primaryGuild == serverTag)
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
