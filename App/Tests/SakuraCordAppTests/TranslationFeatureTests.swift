@testable import SakuraCord
import Foundation
import SakuraCordModels
import Testing

private actor RecordingTranslator: TextTranslating {
    private(set) var requests: [TranslationRequest] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var holdsNextRequest = false

    func holdNextRequest() {
        holdsNextRequest = true
    }

    func releaseHeldRequest() {
        gate?.resume()
        gate = nil
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        requests.append(request)
        if holdsNextRequest {
            holdsNextRequest = false
            await withCheckedContinuation { gate = $0 }
        }
        // Rewrites the words and keeps every protected placeholder in place.
        return TranslationResult(text: "[\(request.targetLanguage.rawValue)] \(request.text)", detectedSourceLanguage: "nl")
    }
}

@MainActor
private func makeTranslationModel(
    provider: TranslationProvider = .libreTranslate,
    translator: RecordingTranslator = RecordingTranslator()
) -> AppModel {
    let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    let state = TranslationState(
        settingsStore: TranslationSettingsStore(preferences: preferences),
        translator: translator,
        apiKeys: InMemoryTranslationAPIKeyStore()
    )
    let model = AppModel(launchMode: .offlineTesting, translation: state)
    var settings = state.settings
    settings.provider = provider
    settings.draftLanguage = TranslationLanguage.englishUS.rawValue
    settings.messageLanguage = TranslationLanguage.dutch.rawValue
    model.applyTranslationSettings(settings)
    return model
}

@MainActor
private func finishDraftTranslation(_ model: AppModel, _ destination: MessageComposerDestination = .channel) async throws {
    let task = try #require(model.translation.draftTasks[destination])
    await task.value
}

@MainActor
@Test func `translation settings persist and exports never contain the API key`() async throws {
    let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    let store = TranslationSettingsStore(preferences: preferences)
    #expect(store.load() == .defaults)
    #expect(!store.load().isEnabled)

    var value = store.load()
    value.provider = .deepL
    value.libreTranslateServer = "https://translate.example.com"
    value.messageLanguage = TranslationLanguage.japanese.rawValue
    value.draftLanguage = TranslationLanguage.german.rawValue
    store.save(value)
    #expect(store.load() == value)

    let keys = InMemoryTranslationAPIKeyStore()
    try await keys.setAPIKey(" deepl-secret:fx ", for: .deepL)
    #expect(try await keys.apiKey(for: .deepL) == "deepl-secret:fx")

    let export = preferences.export(scope: .appWide, page: .features)
    let text = try #require(String(data: try export.encodedData(), encoding: .utf8))
    #expect(text.contains("translation.provider"))
    #expect(!text.contains("deepl-secret"))
    #expect(!SettingsPreferenceRegistry.foundation.registrations.contains { $0.id == .translationAPIKey })

    try await keys.setAPIKey("", for: .deepL)
    #expect(try await keys.apiKey(for: .deepL) == nil)
}

@Test(arguments: [
    (SettingsControlID.translationProvider, "deepl", true),
    (.translationProvider, "google", false),
    (.translationServer, "", true),
    (.translationServer, "https://translate.example.com", true),
    (.translationServer, "http://translate.example.com", false),
    (.translationMessageLanguage, "", true),
    (.translationMessageLanguage, "ja", true),
    (.translationDraftLanguage, "xx", false),
])
func `translation imports are validated`(id: SettingsControlID, raw: String, accepted: Bool) throws {
    let registration = try #require(SettingsPreferenceRegistry.foundation.registrations.first { $0.id == id })
    #expect(SettingsImportValidation.accepts(.string(raw), registration: registration) == accepted)
}

@MainActor
@Test func `draft translation toggles between original and translation without translating twice`() async throws {
    let translator = RecordingTranslator()
    let model = makeTranslationModel(translator: translator)
    model.updateDraft("hoi <@123>, kijk <:sakura:456>")
    #expect(model.canTranslateDraft(in: .channel))

    model.translateDraft(in: .channel)
    #expect(model.draftTranslation(for: .channel)?.phase == .translating)
    try await finishDraftTranslation(model)
    #expect(model.draft == "[en-US] hoi <@123>, kijk <:sakura:456>")
    #expect(model.draftTranslation(for: .channel)?.phase == .translated)
    #expect(model.draftTranslation(for: .channel)?.original == "hoi <@123>, kijk <:sakura:456>")
    let request = try #require(await translator.requests.first)
    #expect(!request.text.contains("<@123>"))
    #expect(request.provider == .libreTranslate)

    model.updateDraft(model.draft + " (edited)")
    model.translateDraft(in: .channel)
    #expect(model.draft == "hoi <@123>, kijk <:sakura:456>")
    #expect(model.draftTranslation(for: .channel)?.phase == .showingOriginal)

    model.translateDraft(in: .channel)
    #expect(model.draft == "[en-US] hoi <@123>, kijk <:sakura:456> (edited)")
    #expect(await translator.requests.count == 1)

    model.dismissDraftTranslation(in: .channel)
    #expect(model.draftTranslation(for: .channel) == nil)
    #expect(model.draft == "[en-US] hoi <@123>, kijk <:sakura:456> (edited)")
}

@MainActor
@Test func `late draft translations never overwrite newer typing`() async throws {
    let translator = RecordingTranslator()
    await translator.holdNextRequest()
    let model = makeTranslationModel(translator: translator)
    model.updateDraft("goedemorgen")
    model.translateDraft(in: .channel)
    let task = try #require(model.translation.draftTasks[.channel])
    while await translator.requests.isEmpty {
        await Task.yield()
    }

    model.updateDraft("goedemorgen allemaal")
    await translator.releaseHeldRequest()
    await task.value

    #expect(model.draft == "goedemorgen allemaal")
    #expect(model.draftTranslation(for: .channel) == nil)
}

@MainActor
@Test(arguments: ["/giphy sakura", "   ", "<@123>"])
func `slash commands and drafts without words are refused`(draft: String) async {
    let translator = RecordingTranslator()
    let model = makeTranslationModel(translator: translator)
    model.updateDraft(draft)

    #expect(!model.canTranslateDraft(in: .channel))
    model.translateDraft(in: .channel)
    guard case .failed = model.draftTranslation(for: .channel)?.phase else {
        Issue.record("Expected an inline refusal")
        return
    }
    #expect(model.draft == draft)
    #expect(await translator.requests.isEmpty)
}

@MainActor
@Test func `sending or switching conversations clears the draft translation`() async throws {
    let model = makeTranslationModel()
    model.updateDraft("tot straks")
    model.translateDraft(in: .channel)
    try await finishDraftTranslation(model)
    #expect(model.draftTranslation(for: .channel) != nil)

    model.selectedChannelID = ChannelID(rawValue: 900)
    #expect(model.draftTranslation(for: .channel) == nil)
}

@MainActor
@Test func `message translations appear below unchanged content and hide again`() async throws {
    let translator = RecordingTranslator()
    let model = makeTranslationModel(translator: translator)
    let channelID = ChannelID(rawValue: 200)
    let author = User(id: UserID(rawValue: 1), username: "author", displayName: "Author")
    let message = Message(id: MessageID(rawValue: 300), channelID: channelID, author: author, content: "goedemorgen <@1>")
    model.selectedChannelID = channelID
    model.replaceSelectedMessages(with: [message])
    #expect(model.messageTranslationMenuTitle(for: message) == "Translate Message")

    let revision = model.messageRowsRevision
    model.toggleMessageTranslation(message)
    #expect(model.messageTranslationPresentation(for: message)?.status == .loading)
    #expect(model.messageRowsRevision != revision || model.timelinePresentationRevision > 0)
    let task = try #require(model.translation.messageTasks[message.id])
    await task.value

    let entry = try #require(model.messageTranslationPresentation(for: message))
    #expect(entry.status == .translated(TranslationResult(text: "[nl] goedemorgen <@1>", detectedSourceLanguage: "nl")))
    #expect(model.messageTranslationMenuTitle(for: message) == "Show Original")

    var edited = message
    edited.content = "goedenavond <@1>"
    #expect(model.messageTranslationPresentation(for: edited) == nil)

    model.toggleMessageTranslation(message)
    #expect(model.messageTranslationPresentation(for: message) == nil)
    model.toggleMessageTranslation(message)
    #expect(model.messageTranslationPresentation(for: message) != nil)
    #expect(await translator.requests.count == 1)
}

@MainActor
@Test func `message translation is unavailable when turned off`() {
    let model = makeTranslationModel(provider: .off)
    let author = User(id: UserID(rawValue: 1), username: "author", displayName: "Author")
    let message = Message(id: MessageID(rawValue: 300), channelID: ChannelID(rawValue: 200), author: author, content: "hoi")
    #expect(model.messageTranslationMenuTitle(for: message) == nil)
    #expect(!model.canTranslateDraft(in: .channel))
}

@Test func `translation menu entries appear only for conversation messages that can be sent again`() throws {
    let translate = NativeTimelineMessageMenuEntry.action(.toggleTranslation, title: "Translate Message", systemImage: "translate")
    let entries = NativeTimelineMessageMenuPolicy.entries(
        canEdit: false, canDelete: false, canRetry: false, canReply: true, translationTitle: "Translate Message"
    )
    let translationIndex = try #require(entries.firstIndex(of: translate))
    let separatorIndex = try #require(entries.firstIndex(of: .separator))
    #expect(translationIndex < separatorIndex)

    let failed = NativeTimelineMessageMenuPolicy.entries(
        canEdit: false, canDelete: true, canRetry: true, canReply: false, translationTitle: "Translate Message"
    )
    #expect(!failed.contains(translate))
    let search = NativeTimelineMessageMenuPolicy.entries(
        canEdit: false, canDelete: false, canRetry: false, canReply: false,
        translationTitle: "Translate Message", context: .searchResult
    )
    #expect(!search.contains(translate))
    #expect(!NativeTimelineMessageMenuPolicy.entries(canEdit: false, canDelete: false, canRetry: false, canReply: true).contains(translate))
}
