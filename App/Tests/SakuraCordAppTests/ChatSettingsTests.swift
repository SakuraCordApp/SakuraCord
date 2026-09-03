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
    #expect(row.sakuraCordDeepLinks.map(\.action) == [.checkForUpdates])
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
    #expect(layout.sakuraCordDeepLinkRegions.first?.action == .checkForUpdates)
    #expect(layout.sakuraCordDeepLinkRegions.first?.action.title == "Update SakuraCord")
    #expect(layout.sakuraCordDeepLinkRegions.first?.action.buttonTitle == "Check for Updates")
    #expect(layout.embedRegions.isEmpty)

    var settings = model.chatSettings
    settings.showsAutomaticLinkPreviews = false
    model.applyChatSettings(settings, persists: false)
    let hidden = NativeTimelineRowLayout.make(
        item: item,
        width: 900,
        model: model
    )
    #expect(hidden.sakuraCordDeepLinkRegions.isEmpty)
    #expect(hidden.attributedContent?.string.contains("the updater") == true)

    #expect(
        SakuraCordDeepLinkPresentation.all(
            in: "https://sakuracord.app.evil/settings/update"
        ).isEmpty
    )
    #expect(
        SakuraCordDeepLinkPresentation.all(
            in: "http://sakuracord.app/settings/update"
        ).isEmpty
    )
}

@MainActor
@Test func `SakuraCord theme links replace Discord previews with native theme actions`() throws {
    let sharedTheme = SakuraCordSharedTheme(
        appearance: .dark,
        theme: SakuraCordGradientTheme(
            colors: [
                .init(hue: 0.02, saturation: 0.70),
                .init(hue: 0.34, saturation: 0.72),
                .init(hue: 0.67, saturation: 0.74),
            ],
            intensity: 0.84,
            brightness: 0.76
        )
    )
    let url = try SakuraCordThemeShareCodec.shareURL(for: sharedTheme)
    let message = Message(
        id: MessageID(rawValue: 67),
        channelID: ChannelID(rawValue: 68),
        author: User(
            id: UserID(rawValue: 69),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: "Try [this theme](\(url.absoluteString)).",
        embeds: [
            MessageEmbed(
                title: "SakuraCord Settings Deeplink",
                type: "rich",
                description: "Open it in SakuraCord to use the linked setting.",
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
    guard case let .applyTheme(decodedTheme)? = row.sakuraCordDeepLinks.first?.action else {
        Issue.record("Theme link did not produce an apply action")
        return
    }
    #expect(decodedTheme.appearance == .dark)
    #expect(decodedTheme.theme.activeColorCount == 3)
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
    let region = try #require(layout.sakuraCordDeepLinkRegions.first)
    #expect(region.action == .applyTheme(decodedTheme))
    #expect(region.action.buttonTitle == "Apply Theme")
    #expect(region.paletteFrames.count == 3)
    #expect(region.buttonFrame.height == NativeTimelineComponentButtonMetrics.height)
    #expect(layout.embedRegions.isEmpty)
}

@MainActor
@Test func `Multiple SakuraCord links render ordered independent native cards`() throws {
    let firstThemeURL = try SakuraCordThemeShareCodec.shareURL(for: .init(
        appearance: .dark,
        theme: .defaultTheme
    ))
    let secondThemeURL = try SakuraCordThemeShareCodec.shareURL(for: .init(
        appearance: .light,
        theme: SakuraCordGradientTheme(
            colors: [
                .init(hue: 0.12, saturation: 0.75),
                .init(hue: 0.58, saturation: 0.82),
            ],
            intensity: 0.72,
            brightness: 0.88
        )
    ))
    let updateURL = try #require(
        URL(string: "https://sakuracord.app/settings/update")
    )
    let urls = [firstThemeURL, updateURL, secondThemeURL]
    let message = Message(
        id: MessageID(rawValue: 70),
        channelID: ChannelID(rawValue: 71),
        author: User(
            id: UserID(rawValue: 72),
            username: "fixture",
            displayName: "Fixture"
        ),
        content: urls.map(\.absoluteString).joined(separator: "\n"),
        embeds: urls.map { url in
            MessageEmbed(
                title: "SakuraCord Settings Deeplink",
                type: "rich",
                description: "Open it in SakuraCord to use the linked setting.",
                url: url
            )
        }
    )
    let row = MessageRowPresentation(
        message: message,
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )

    #expect(row.sakuraCordDeepLinks.map(\.url) == urls)
    #expect(row.sakuraCordDeepLinks.count == 3)
    #expect(MessageEmbedPresentation.visibleEmbeds(for: message).isEmpty)

    let layout = NativeTimelineRowLayout.make(
        item: .message(
            row,
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: 900,
        model: AppModel(launchMode: .offlineTesting)
    )
    let regions = layout.sakuraCordDeepLinkRegions
    try #require(regions.count == 3)
    #expect(regions[0].action.title == "Apply Theme")
    #expect(regions[1].action == .checkForUpdates)
    #expect(regions[2].action.title == "Apply Theme")
    #expect(Set(regions.map(\.componentID)).count == 3)
    #expect(regions[0].frame.maxY < regions[1].frame.minY)
    #expect(regions[1].frame.maxY < regions[2].frame.minY)
    #expect(layout.embedRegions.isEmpty)

    for maximumWidth: CGFloat in [280, 360, 560] {
        for (index, deepLink) in row.sakuraCordDeepLinks.enumerated() {
            let region = NativeTimelineSakuraCordDeepLinkLayout.make(
                deepLink,
                componentIndex: index,
                origin: .zero,
                maximumWidth: maximumWidth
            )
            #expect(!region.titleFrame.intersects(region.buttonFrame))
            #expect(!region.symbolBackgroundFrame.intersects(region.buttonFrame))
            #expect(region.paletteFrames.allSatisfy {
                !$0.intersects(region.buttonFrame)
            })
            #expect(region.cardFrame.contains(region.buttonFrame))
        }
    }
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
        .chatEmojiSource,
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
    ] {
        state.searchText = term
        #expect(
            state.searchResults.contains { $0.id == control },
            "Missing Chat search result for \(term)"
        )
    }
}
