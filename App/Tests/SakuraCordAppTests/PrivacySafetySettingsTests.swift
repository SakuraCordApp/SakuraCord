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
    value.externalUploaderOfferPolicy = .never
    store.save(value)
    #expect(store.load().externalUploaderOfferPolicy == .never)

    let export = preferences.export(scope: .appWide, page: .privacySafety)
    #expect(export.values == [
        SettingsControlID.externalUploaderPolicy.rawValue: .string("never"),
    ])
    let encoded = try export.encodedData()
    let text = try #require(String(data: encoded, encoding: .utf8))
    #expect(!text.contains("credential-secret"))

    preferences.reset(scope: .appWide, page: .privacySafety)
    #expect(store.load() == .defaults)
    #expect(defaults.string(forKey: "unregistered.credential") == "credential-secret")
}

@MainActor
@Test func `Never offer policy suppresses oversized third party upload prompts`() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "sakuracord-privacy-upload-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let oversized = directory.appending(path: "oversized.bin")
    FileManager.default.createFile(atPath: oversized.path, contents: nil)
    let handle = try FileHandle(forWritingTo: oversized)
    try handle.truncate(atOffset: UInt64(DiscordAttachmentUploadPolicy.baseLimit + 1))
    try handle.close()

    let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    let privacySafetySettingsStore = PrivacySafetySettingsStore(preferences: preferences)
    var privacySettings = privacySafetySettingsStore.load()
    privacySettings.externalUploaderOfferPolicy = .never
    privacySafetySettingsStore.save(privacySettings)
    let model = AppModel(
        launchMode: .offlineTesting,
        privacySafetySettingsStore: privacySafetySettingsStore
    )
    await model.start()
    model.snapshot?.currentUser.premiumType = 0

    #expect(model.addComposerAttachments([oversized], to: .channel))
    #expect(model.channelComposerAttachments.isEmpty)
    #expect(model.oversizedAttachmentPrompt == nil)
    #expect(model.errorMessage?.contains("Privacy & Safety") == true)
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
        .externalLinkProtection, .privacyInternalDiscordLinks,
        .externalUploaderPolicy, .credentialStorage,
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
        ("third party", .externalUploaderPolicy),
        ("Keychain", .credentialStorage),
        ("forward history", .clearDestinationHistory),
        ("lock screen", .privacyNotificationPreviews),
    ] {
        state.searchText = term
        #expect(state.searchResults.contains { $0.id == control })
    }
}
