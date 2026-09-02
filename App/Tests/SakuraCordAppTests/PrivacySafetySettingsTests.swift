@testable import SakuraCord
import Foundation
import SakuraCordModels
import Testing

@Test func `External link assessment explains deterministic suspicious signals`() throws {
    let ordinary = try #require(URL(string: "https://example.com/docs"))
    let ordinaryAssessment = ExternalLinkSafetyPolicy.assess(ordinary)
    #expect(ordinaryAssessment.isAllowed)
    #expect(ordinaryAssessment.domain == "example.com")
    #expect(!ordinaryAssessment.isSuspicious)

    let disguised = try #require(
        URL(string: "http://discord.com.evil.example/login")
    )
    let disguisedAssessment = ExternalLinkSafetyPolicy.assess(
        disguised,
        displayedText: "https://discord.com"
    )
    #expect(disguisedAssessment.isAllowed)
    #expect(disguisedAssessment.isSuspicious)
    #expect(disguisedAssessment.warnings.contains { $0.contains("not encrypted") })
    #expect(disguisedAssessment.warnings.contains { $0.contains("known service") })
    #expect(disguisedAssessment.warnings.contains {
        $0.contains("discord.com") && $0.contains("discord.com.evil.example")
    })

    let unsafe = try #require(URL(string: "javascript:alert(1)"))
    #expect(!ExternalLinkSafetyPolicy.assess(unsafe).isAllowed)
}

@MainActor
@Test func `External links require confirmation while resolvable Discord links stay internal`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let channelID = try #require(model.selectedChannelID)
    let internalURL = try #require(
        URL(string: "https://discord.com/channels/@me/\(channelID)")
    )
    var confirmations: [ExternalLinkSafetyAssessment] = []

    #expect(MessageLinkActivator.activate(
        internalURL,
        model: model,
        confirmExternal: { confirmations.append($0) }
    ))
    #expect(confirmations.isEmpty)

    model.chatSettings.opensDiscordLinksInternally = false
    #expect(MessageLinkActivator.activate(
        internalURL,
        model: model,
        confirmExternal: { confirmations.append($0) }
    ))
    #expect(confirmations.map(\.url) == [internalURL])

    let externalURL = try #require(URL(string: "https://example.com/path"))
    #expect(MessageLinkActivator.activate(
        externalURL,
        model: model,
        displayedText: "Example",
        confirmExternal: { confirmations.append($0) }
    ))
    #expect(confirmations.map(\.url) == [internalURL, externalURL])
}

@MainActor
@Test func `Privacy preference persists resets exports and excludes unregistered secrets`() throws {
    let defaults = InMemoryPreferences()
    defaults.set("credential-secret", forKey: "unregistered.credential")
    let preferences = SettingsPreferenceStore(defaults: defaults)
    let store = PrivacySafetySettingsStore(preferences: preferences)

    var value = store.load()
    #expect(value == .defaults)
    value.externalLinkConfirmationPolicy = .allLinks
    value.trustedDomains = ["Example.COM", "sub.example.com", "example.com"]
    store.save(value)
    let reloaded = store.load()
    #expect(reloaded.externalLinkConfirmationPolicy == .allLinks)
    #expect(reloaded.trustedDomains == ["example.com", "sub.example.com"])

    let export = preferences.export(scope: .appWide, page: .privacySafety)
    #expect(export.values == [
        SettingsControlID.externalLinkProtection.rawValue: .string("allLinks"),
    ])
    let encoded = try export.encodedData()
    let text = try #require(String(data: encoded, encoding: .utf8))
    #expect(!text.contains("credential-secret"))

    preferences.reset(scope: .appWide, page: .privacySafety)
    #expect(store.load() == .defaults)
    #expect(defaults.string(forKey: "unregistered.credential") == "credential-secret")
}

@Test func `Trusted external link domains normalize to exact safe hostnames`() {
    #expect(ExternalLinkTrustedDomain.normalized(" Example.COM ") == "example.com")
    #expect(
        ExternalLinkTrustedDomain.normalized("https://Sub.Example.com/")
            == "sub.example.com"
    )
    #expect(ExternalLinkTrustedDomain.normalized("example.com.") == "example.com")
    #expect(ExternalLinkTrustedDomain.normalized("http://example.com") == nil)
    #expect(ExternalLinkTrustedDomain.normalized("https://example.com/path") == nil)
    #expect(ExternalLinkTrustedDomain.normalized("https://user@example.com") == nil)
    #expect(ExternalLinkTrustedDomain.normalized("localhost") == nil)
    #expect(ExternalLinkTrustedDomain.normalized("-invalid.example") == nil)
}

@Test func `External link confirmation policy trusts exact domains only`() {
    let trustedDomains = ["example.com"]

    #expect(!ExternalLinkConfirmationPolicy.untrustedDomains.requiresConfirmation(
        for: "example.com",
        trustedDomains: trustedDomains
    ))
    #expect(ExternalLinkConfirmationPolicy.untrustedDomains.requiresConfirmation(
        for: "sub.example.com",
        trustedDomains: trustedDomains
    ))
    #expect(ExternalLinkConfirmationPolicy.allLinks.requiresConfirmation(
        for: "example.com",
        trustedDomains: trustedDomains
    ))
    #expect(!ExternalLinkConfirmationPolicy.noLinks.requiresConfirmation(
        for: "unknown.example",
        trustedDomains: trustedDomains
    ))
}

@MainActor
@Test func `External link presenter bypasses prompts according to privacy policy`() throws {
    let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    let store = PrivacySafetySettingsStore(preferences: preferences)
    var settings = store.load()
    settings.externalLinkConfirmationPolicy = .noLinks
    store.save(settings)

    var openedURLs: [URL] = []
    let presenter = ExternalLinkConfirmationPresenter(
        settingsStore: store,
        opener: { openedURLs.append($0) },
        windowProvider: { nil }
    )
    let url = try #require(URL(string: "https://example.com/path"))
    presenter.present(ExternalLinkSafetyPolicy.assess(url))

    #expect(openedURLs == [url])
}

@MainActor
@Test func `Local privacy actions clear only their described state`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let channelID = try #require(model.selectedChannelID)

    model.messageSearch.queryText = "private query"
    model.messageSearch.errorMessage = "fixture"
    model.messageSearch.isPresented = true
    model.clearLocalMessageSearchData()
    #expect(model.messageSearch.queryText.isEmpty)
    #expect(model.messageSearch.errorMessage == nil)
    #expect(!model.messageSearch.isPresented)

    model.forwardDestinationHistory = [channelID]
    model.clearLocalDestinationHistory()
    #expect(model.forwardDestinationHistory.isEmpty)

    model.emojiRecentKeys = ["wave"]
    model.emojiUsageCounts = ["wave": 4]
    model.discordFavoriteEmojiKeys = ["wave"]
    model.clearLocallyLearnedEmojiRanking()
    #expect(model.emojiRecentKeys.isEmpty)
    #expect(model.emojiUsageCounts.isEmpty)
    #expect(model.discordFavoriteEmojiKeys == ["wave"])

    let database = try #require(model.database)
    try await database.saveDraft("unsent", channelID: channelID)
    model.draft = "unsent"
    model.threadDraft = "thread text"
    model.quickSwitcherDraftChannelIDs = [channelID]
    try await model.clearLocalDrafts()
    #expect(try await database.draft(channelID: channelID).isEmpty)
    #expect(model.draft.isEmpty)
    #expect(model.threadDraft.isEmpty)
    #expect(model.quickSwitcherDraftChannelIDs.isEmpty)
}

@MainActor
@Test func `Privacy catalog exposes one searchable control for every behavior`() {
    let expected: Set<SettingsControlID> = [
        .privacyTypingIndicators, .privacyReadAcknowledgements,
        .externalLinkProtection, .trustedDomains,
        .clearMessageSearches, .clearDestinationHistory,
        .clearEmojiRanking, .clearDrafts,
        .privacyNotificationPreviews, .privacyExport, .privacyReset,
    ]
    let controls = SettingsCatalog.foundation.controls.filter {
        $0.destination.page == .privacySafety
    }
    #expect(Set(controls.map(\.id)) == expected)

    let state = SettingsViewState()
    for (term, control) in [
        ("phishing", SettingsControlID.externalLinkProtection),
        ("allow list", .trustedDomains),
        ("forward history", .clearDestinationHistory),
        ("lock screen", .privacyNotificationPreviews),
    ] {
        state.searchText = term
        #expect(state.searchResults.contains { $0.id == control })
    }
}
