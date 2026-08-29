@testable import SakuraCord
import AppKit
import Foundation
import SakuraCordModels
import Testing

@MainActor
@Test func `Chat preferences preserve historical keys and reset only Chat`() {
    let defaults = InMemoryPreferences()
    defaults.set(false, forKey: "sendWithReturn")
    defaults.set(true, forKey: "reduceAnimatedMedia")
    defaults.set("dark", forKey: "emojiSkinTone")
    let preferences = SettingsPreferenceStore(defaults: defaults)
    let store = ChatSettingsStore(preferences: preferences)

    var value = store.load()
    #expect(!value.sendsWithReturn)
    #expect(value.reducesAnimatedMedia)
    #expect(value.emojiSkinTone == .dark)
    value.readAcknowledgementMode = .manual
    value.inlineMediaSize = .compact
    store.save(value)

    #expect(defaults.bool(forKey: "sendWithReturn") == false)
    #expect(defaults.bool(forKey: "reduceAnimatedMedia") == true)
    #expect(defaults.string(forKey: "emojiSkinTone") == "dark")
    #expect(store.load() == value)
    let export = preferences.export(scope: .appWide, page: .chat)
    #expect(export.values[SettingsControlID.sendWithReturn.rawValue] == .bool(false))
    #expect(export.values[SettingsControlID.launchDestination.rawValue] == nil)

    preferences.reset(scope: .appWide, page: .chat)
    #expect(store.load() == .defaults)
}

@Test func `Chat character counter follows Discord effective limits`() {
    #expect(ChatCharacterLimitPolicy.limit(premiumType: nil) == 2_000)
    #expect(ChatCharacterLimitPolicy.limit(premiumType: 0) == 2_000)
    #expect(ChatCharacterLimitPolicy.limit(premiumType: 2) == 4_000)
    #expect(!ChatCharacterLimitPolicy.shouldShowCounter(characterCount: 1_799, limit: 2_000))
    #expect(ChatCharacterLimitPolicy.shouldShowCounter(characterCount: 1_800, limit: 2_000))
    #expect(!ChatCharacterLimitPolicy.isWithinLimit(characterCount: 2_001, premiumType: 0))
}

@MainActor
@Test func `manual read and disabled typing policies schedule no mutation`() {
    let model = AppModel(launchMode: .offlineTesting)
    var settings = model.chatSettings
    settings.readAcknowledgementMode = .manual
    settings.sendsTypingIndicators = false
    model.applyChatSettings(settings, persists: false)

    let channelID = ChannelID(rawValue: 51)
    model.scheduleAutomaticAcknowledgement(
        channelID: channelID,
        messageID: MessageID(rawValue: 52)
    )
    model.scheduleLocalTyping(for: "draft")

    #expect(model.readState.entries[channelID]?.pendingAcknowledgementID == nil)
    #expect(model.localTypingTask == nil)
}

@MainActor
@Test func `Chat embed and link preview settings reach native timeline layout`() throws {
    let sourceURL = try #require(URL(string: "https://example.com/article"))
    let imageURL = try #require(URL(string: "https://cdn.example.com/image.png"))
    let message = Message(
        id: MessageID(rawValue: 61),
        channelID: ChannelID(rawValue: 62),
        author: User(
            id: UserID(rawValue: 63),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: sourceURL.absoluteString,
        embeds: [
            MessageEmbed(
                title: "Article",
                type: "rich",
                url: sourceURL,
                image: MessageEmbedMedia(url: imageURL, width: 1_200, height: 800)
            ),
        ]
    )
    #expect(MessageEmbedPresentation.visibleEmbeds(
        for: message,
        showsAutomaticLinkPreviews: false
    ).isEmpty)
    #expect(MessageEmbedPresentation.visibleMessageContent(
        for: message,
        showsAutomaticLinkPreviews: false
    ) == sourceURL.absoluteString)

    let row = MessageRowPresentation(
        message: message,
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )
    let item = NativeMessageTimelineItem.message(
        row,
        isUnreadBoundary: false,
        isHighlighted: false
    )
    let model = AppModel(launchMode: .offlineTesting)
    var settings = model.chatSettings
    settings.inlineMediaSize = .compact
    model.applyChatSettings(settings, persists: false)
    let compact = NativeTimelineRowLayout.make(item: item, width: 900, model: model)
    #expect(try #require(compact.embedRegions.first).frame.width <= 360)

    settings.expandsEmbedsByDefault = false
    model.applyChatSettings(settings, persists: false)
    let collapsed = NativeTimelineRowLayout.make(item: item, width: 900, model: model)
    #expect(collapsed.embedRegions.isEmpty)
    #expect(collapsed.attributedContent?.string == sourceURL.absoluteString)
}

@MainActor
@Test func `SakuraCord update links replace Discord previews with native actions`() throws {
    let url = try #require(
        URL(string: "https://sakuracord.app/settings/update")
    )
    let message = Message(
        id: MessageID(rawValue: 64),
        channelID: ChannelID(rawValue: 65),
        author: User(
            id: UserID(rawValue: 66),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: "Try [the updater](\(url.absoluteString)).",
        embeds: [
            MessageEmbed(
                title: "Check for Updates in SakuraCord",
                type: "rich",
                description: "This is a SakuraCord settings deeplink.",
                url: url
            ),
        ]
    )
    let row = MessageRowPresentation(
        message: message,
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )
    #expect(row.sakuraCordDeepLink?.action == .checkForUpdates)
    #expect(MessageEmbedPresentation.visibleEmbeds(for: message).isEmpty)

    let item = NativeMessageTimelineItem.message(
        row,
        isUnreadBoundary: false,
        isHighlighted: false
    )
    let model = AppModel(launchMode: .offlineTesting)
    let layout = NativeTimelineRowLayout.make(
        item: item,
        width: 900,
        model: model
    )
    #expect(layout.sakuraCordDeepLinkRegion?.action == .checkForUpdates)
    #expect(layout.embedRegions.isEmpty)

    var settings = model.chatSettings
    settings.showsAutomaticLinkPreviews = false
    model.applyChatSettings(settings, persists: false)
    let hidden = NativeTimelineRowLayout.make(
        item: item,
        width: 900,
        model: model
    )
    #expect(hidden.sakuraCordDeepLinkRegion == nil)
    #expect(hidden.attributedContent?.string.contains("the updater") == true)

    #expect(
        SakuraCordDeepLinkPresentation.first(
            in: "https://sakuracord.app.evil/settings/update"
        ) == nil
    )
    #expect(
        SakuraCordDeepLinkPresentation.first(
            in: "http://sakuracord.app/settings/update"
        ) == nil
    )
}

@MainActor
@Test func `spoiler reveal policy supports modifier assisted and always modes`() {
    #expect(ChatSpoilerRevealMode.click.permitsReveal(modifierFlags: []))
    #expect(!ChatSpoilerRevealMode.optionClick.permitsReveal(modifierFlags: []))
    #expect(ChatSpoilerRevealMode.optionClick.permitsReveal(modifierFlags: [.option]))
    #expect(ChatSpoilerRevealMode.always.permitsReveal(modifierFlags: []))

    let store = NativeTimelineSpoilerRevealStore()
    store.revealMode = .always
    let key = NativeTimelineComponentRevealKey(
        messageID: MessageID(rawValue: 70),
        componentID: "spoiler"
    )
    #expect(store.isMediaRevealed(key))
}

@MainActor
@Test func `local emoji cleanup actions remain independently scoped`() {
    let model = AppModel(launchMode: .offlineTesting)
    model.emojiRecentKeys = ["one", "two"]
    model.emojiUsageCounts = ["one": 4]

    model.clearLocalEmojiRecents()
    #expect(model.emojiRecentKeys.isEmpty)
    #expect(model.emojiUsageCounts == ["one": 4])

    model.emojiRecentKeys = ["two"]
    model.resetLocalEmojiRanking()
    #expect(model.emojiUsageCounts.isEmpty)
    #expect(model.emojiRecentKeys == ["two"])
}

@MainActor
@Test func `Chat catalog exposes production controls and common synonyms`() {
    let expected: Set<SettingsControlID> = [
        .sendWithReturn, .chatSpellCheck, .chatAutomaticCorrection,
        .chatSmartQuotes, .chatSmartDashes, .chatTypingIndicators,
        .chatFocusComposerOnTyping, .chatCharacterCounter,
        .chatDiscardConfirmationLink, .chatReadAcknowledgement,
        .chatEditedMarkers, .chatExpandEmbeds, .chatSpoilerReveal,
        .chatInternalDiscordLinks, .chatAutoplayGIFs,
        .chatAutoplayStickers, .chatAutoplayVideos, .chatLinkPreviews,
        .chatInlineMediaSize, .reduceAnimatedMedia, .chatEmojiSkinTone,
        .chatEmojiSource, .chatEmojiPrivacyLink,
        .chatExport, .chatReset,
    ]
    let controls = SettingsCatalog.foundation.controls.filter {
        $0.destination.page == .chat
    }
    #expect(Set(controls.map(\.id)) == expected)

    let state = SettingsViewState()
    for (term, control) in [
        ("autocorrect", SettingsControlID.chatAutomaticCorrection),
        ("read receipt", .chatReadAcknowledgement),
        ("unfurl", .chatLinkPreviews),
        ("option click", .chatSpoilerReveal),
        ("recent emoji", .chatEmojiPrivacyLink),
    ] {
        state.searchText = term
        #expect(
            state.searchResults.contains { $0.id == control },
            "Missing Chat search result for \(term)"
        )
    }
}
