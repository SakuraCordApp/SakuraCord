@testable import SakuraCord
import Foundation
import MessageRendering
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

    let externalURL = try #require(URL(string: "https://example.com/path"))
    #expect(MessageLinkActivator.activate(
        externalURL,
        model: model,
        displayedText: "Example",
        confirmExternal: { confirmations.append($0) }
    ))
    #expect(confirmations.map(\.url) == [externalURL])
}

@MainActor
@Test func `Privacy preference persists resets exports and excludes unregistered secrets`() throws {
    let defaults = InMemoryPreferences()
    defaults.set("credential-secret", forKey: "unregistered.credential")
    let preferences = SettingsPreferenceStore(defaults: defaults)
    let store = PrivacySafetySettingsStore(preferences: preferences)

    var value = store.load()
    #expect(value == .defaults)
    #expect(value.removesMediaMetadata)
    value.removesMediaMetadata = false
    value.anonymisesFileNames = true
    value.externalLinkConfirmationPolicy = .allLinks
    value.trustedDomains = ["Example.COM", "sub.example.com", "example.com"]
    store.save(value)
    let reloaded = store.load()
    #expect(!reloaded.removesMediaMetadata)
    #expect(reloaded.anonymisesFileNames)
    #expect(reloaded.externalLinkConfirmationPolicy == .allLinks)
    #expect(reloaded.trustedDomains == ["example.com", "sub.example.com"])

    let export = preferences.export(scope: .appWide, page: .privacySafety)
    #expect(export.values == [
        SettingsControlID.removeMediaMetadata.rawValue: .bool(false),
        SettingsControlID.anonymiseFileNames.rawValue: .bool(true),
        SettingsControlID.privacyTypingIndicators.rawValue: .bool(true),
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

@Test func `Trusted hosts cannot suppress suspicious link and direct download warnings`() throws {
    let trusted = ["github.com", "www.github.com", "*.example.com"]
    for address in [
        "http://github.com/owner/repo",
        "https://someone@github.com/owner/repo",
        "https://github.com/owner/repo/releases/download/v1/tool.zip",
        "https://github.com/owner/repo/releases/latest/download/tool.zip",
        "https://github.com/owner/repo/raw/main/tool.sh",
        "https://github.com/owner/repo/zipball/main",
        "https://github.com/owner/repo/tarball/main",
        "https://github.com/owner/repo/archive/refs/heads/main.zip",
        "https://github.com/owner/repo/files/123/tool.zip",
        "https://github.com/user-attachments/files/123/tool.zip",
        "https://github.com/owner/repo/blob/main/tool.sh?raw=true",
        "https://github.com/owner/repo/blob/main/tool.sh?raw=anything",
        "https://github.com/owner/repo/blob/main/tool.sh?raw%5B%5D=true",
        "https://github.com/owner/repo/blob/main/tool.sh?raw",
        "https://www.github.com/owner/repo/blob/main/tool.sh?raw=1",
        "https://github.com./owner/repo/%72aw/main/tool.sh",
        "http://sub.example.com/path",
    ] {
        let assessment = ExternalLinkSafetyPolicy.assess(try #require(URL(string: address)))
        #expect(assessment.isSuspicious, "Expected a warning for \(address)")
        #expect(ExternalLinkConfirmationPolicy.untrustedDomains.requiresConfirmation(
            for: assessment, trustedDomains: trusted
        ))
        #expect(!ExternalLinkConfirmationPolicy.noLinks.requiresConfirmation(
            for: assessment, trustedDomains: trusted
        ))
    }
    let url = try #require(URL(string: "https://github.com/owner/repo"))
    let disguised = ExternalLinkSafetyPolicy.assess(url, displayedText: "https://apple.com")
    #expect(ExternalLinkConfirmationPolicy.untrustedDomains.requiresConfirmation(
        for: disguised, trustedDomains: trusted
    ))
    for address in [
        "https://github.com/owner/repo",
        "https://github.com/owner/repo/releases/tag/v1",
        "https://github.com/owner/repo/blob/main/tool.sh",
        "https://github.com/owner/repo/issues/1",
        "https://github.com/owner/repo/blob/main/releases/download/example.md",
    ] {
        let assessment = ExternalLinkSafetyPolicy.assess(try #require(URL(string: address)))
        #expect(!assessment.isSuspicious)
        #expect(!ExternalLinkConfirmationPolicy.untrustedDomains.requiresConfirmation(
            for: assessment, trustedDomains: trusted
        ))
        #expect(ExternalLinkConfirmationPolicy.allLinks.requiresConfirmation(
            for: assessment, trustedDomains: trusted
        ))
    }
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

    settings.externalLinkConfirmationPolicy = .untrustedDomains
    settings.trustedDomains = ["example.com"]
    store.save(settings)
    openedURLs = []
    presenter.present(ExternalLinkSafetyPolicy.assess(url, displayedText: "https://apple.com"))
    #expect(openedURLs.isEmpty)
    presenter.present(ExternalLinkSafetyPolicy.assess(url))
    #expect(openedURLs == [url])

    var selectedApplicationURLs: [URL] = []
    let selectedApplicationOpener: (URL) -> Void = { selectedApplicationURLs.append($0) }
    presenter.present(
        ExternalLinkSafetyPolicy.assess(url, displayedText: "https://apple.com"),
        opener: selectedApplicationOpener
    )
    #expect(selectedApplicationURLs.isEmpty)
    presenter.present(ExternalLinkSafetyPolicy.assess(url), opener: selectedApplicationOpener)
    #expect(selectedApplicationURLs == [url])
    let unsupportedURL = try #require(URL(string: "javascript:alert(1)"))
    presenter.present(ExternalLinkSafetyPolicy.assess(unsupportedURL), opener: selectedApplicationOpener)
    #expect(selectedApplicationURLs == [url])
    #expect(openedURLs == [url])
}

@MainActor
@Test func `Local activity preserves pending synchronized emoji usage`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let channelID = try #require(model.selectedChannelID)

    model.messageSearch.queryText = "private query"
    model.messageSearch.isPresented = true
    model.forwardDestinationHistory = [channelID]
    model.recordMessageEmojiUsage("👋")
    let pending = model.emojiFrecency.pendingUsages
    model.discordFavoriteEmojiKeys = ["wave"]

    try await model.clearLocalActivity()

    #expect(model.messageSearch.queryText == "private query")
    #expect(model.messageSearch.isPresented)
    #expect(model.forwardDestinationHistory.isEmpty)
    #expect(model.emojiFrecency.pendingUsages == pending)
    #expect(model.discordFavoriteEmojiKeys == ["wave"])
}

@MainActor
@Test func `Privacy catalog exposes one searchable control for every behavior`() {
    let expected: Set<SettingsControlID> = [
        .privacyTypingIndicators, .anonymiseFileNames, .removeMediaMetadata,
        .externalLinkProtection, .trustedDomains,
        .clearLocalActivity, .ignoredAccounts, .blockedAccounts,
    ]
    let controls = SettingsCatalog.foundation.controls.filter {
        $0.destination.page == .privacySafety
    }
    #expect(Set(controls.map(\.id)) == expected)

    let state = SettingsViewState()
    for (term, control) in [
        ("ignored accounts", SettingsControlID.ignoredAccounts),
        ("unblock", .blockedAccounts),
        ("phishing", SettingsControlID.externalLinkProtection),
        ("allow list", .trustedDomains),
        ("randomise", .anonymiseFileNames),
        ("GPS", .removeMediaMetadata),
        ("forward history", .clearLocalActivity),
        ("recent emoji", .clearLocalActivity),
    ] {
        state.searchText = term
        #expect(state.searchResults.contains { $0.id == control })
    }
}

@MainActor
@Test func `Privacy disabling typing cancels pending signals and prevents new ones`() async throws {
    let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    let store = PrivacySafetySettingsStore(preferences: preferences)
    let model = AppModel(launchMode: .offlineTesting, privacySafetySettingsStore: store)
    await model.start()
    model.scheduleLocalTyping(for: "draft")
    let pendingSignal = try #require(model.localTypingTask)
    var settings = model.privacySafetySettings
    settings.sendsTypingIndicators = false
    model.applyPrivacySafetySettings(settings)
    #expect(pendingSignal.isCancelled)
    #expect(model.localTypingTask == nil)
    model.scheduleLocalTyping(for: "draft")
    #expect(model.localTypingTask == nil)
}

@MainActor
@Test func `Attachment confirmations preserve complete masked host warnings`() async throws {
    let url = try #require(URL(string: "https://cdn.discordapp.com/attachments/1/2/example.com?ex=ffffffff"))
    let masked = DiscordMarkdown.appKitAttributed("[https://dis**cord**.com](\(url.absoluteString))")
    let label = MessageLinkActivator.safetyDisplayedText(in: masked, at: 12)
    #expect(label == "https://discord.com")
    let model = AppModel(launchMode: .offlineTesting)
    let assessment = await withCheckedContinuation { continuation in
        _ = MessageLinkActivator.activate(
            url,
            model: model,
            displayedText: label,
            confirmExternal: { continuation.resume(returning: $0) }
        )
    }
    #expect(assessment.warnings.contains {
        $0.contains("discord.com") && $0.contains("cdn.discordapp.com")
    })
}
