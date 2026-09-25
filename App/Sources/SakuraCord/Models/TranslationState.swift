import Foundation
import Observation
import SakuraCordModels

/// Owns translation settings, the provider client, API-key storage, and the
/// in-memory results for messages and composer drafts. Nothing here is sent
/// to Discord or written to the account database.
@MainActor
@Observable
final class TranslationState {
    var settings: TranslationSettingsSnapshot
    /// Providers with an API key saved in the Keychain; the keys themselves stay there.
    private(set) var savedAPIKeyProviders: Set<TranslationProvider> = []
    var drafts: [MessageComposerDestination: DraftTranslation] = [:]
    @ObservationIgnored let settingsStore: TranslationSettingsStore
    @ObservationIgnored let translator: any TextTranslating
    @ObservationIgnored let apiKeys: any TranslationAPIKeyStoring
    @ObservationIgnored let messages = MessageTranslationStore()
    @ObservationIgnored var messageTasks: [MessageID: Task<Void, Never>] = [:]
    @ObservationIgnored var draftTasks: [MessageComposerDestination: Task<Void, Never>] = [:]

    init(
        settingsStore: TranslationSettingsStore = .shared,
        translator: any TextTranslating = HTTPTextTranslator(),
        apiKeys: any TranslationAPIKeyStoring = KeychainTranslationAPIKeyStore()
    ) {
        self.settingsStore = settingsStore
        settings = settingsStore.load()
        self.translator = translator
        self.apiKeys = apiKeys
    }

    convenience init(launchMode: AppLaunchMode) {
        self.init(apiKeys: launchMode == .offlineTesting
            ? InMemoryTranslationAPIKeyStore() : KeychainTranslationAPIKeyStore())
    }

    func request(for text: String, into language: TranslationLanguage) async throws -> TranslationRequest {
        let provider = settings.provider
        guard provider != .off else { throw TranslationError.notConfigured }
        let apiKey = try await apiKeys.apiKey(for: provider)
        return TranslationRequest(
            provider: provider,
            text: text,
            targetLanguage: language,
            serverURL: settings.libreTranslateServer,
            apiKey: apiKey
        )
    }

    func refreshSavedAPIKeys() async {
        var saved = Set<TranslationProvider>()
        for provider in TranslationProvider.allCases where provider != .off {
            if (try? await apiKeys.apiKey(for: provider)) != nil { saved.insert(provider) }
        }
        savedAPIKeyProviders = saved
    }

    /// Cached draft translations were made with the previous provider or language.
    func discardCachedDraftTranslations() {
        for (destination, draft) in drafts where draft.phase != .translated {
            draftTasks.removeValue(forKey: destination)?.cancel()
            drafts[destination] = nil
        }
    }

    func resetDraft(_ destination: MessageComposerDestination) {
        draftTasks.removeValue(forKey: destination)?.cancel()
        drafts[destination] = nil
    }

    func resetAll() {
        for task in messageTasks.values { task.cancel() }
        messageTasks.removeAll()
        for destination in Array(draftTasks.keys) { resetDraft(destination) }
        drafts.removeAll()
    }
}

nonisolated struct DraftTranslation: Equatable, Sendable {
    nonisolated enum Phase: Equatable, Sendable {
        case translating
        case translated
        case showingOriginal
        case failed(String)
    }

    var original: String
    var translated: String?
    var language: TranslationLanguage
    var phase: Phase
    var requestRevision: UInt64 = 0
}

nonisolated struct MessageTranslationEntry: Equatable, Sendable {
    nonisolated enum Status: Equatable, Sendable {
        case loading
        case translated(TranslationResult)
        case failed(String)
    }

    var sourceContent: String
    var language: TranslationLanguage
    var status: Status
    var isVisible = true
}

/// Session-wide, bounded message translations keyed by message. A translation
/// is only presented while the message still has the content it was made from.
@MainActor
final class MessageTranslationStore {
    static let capacity = 200

    private var entries: [MessageID: MessageTranslationEntry] = [:]
    private var order: [MessageID] = []

    var isEmpty: Bool { entries.isEmpty }

    subscript(id: MessageID) -> MessageTranslationEntry? {
        entries[id]
    }

    /// Stores an entry and returns messages evicted to stay within capacity.
    @discardableResult
    func set(_ entry: MessageTranslationEntry, for id: MessageID) -> [MessageID] {
        entries[id] = entry
        order.removeAll { $0 == id }
        order.append(id)
        var evicted: [MessageID] = []
        while order.count > Self.capacity {
            let oldest = order.removeFirst()
            entries[oldest] = nil
            evicted.append(oldest)
        }
        return evicted
    }

    func remove(_ id: MessageID) {
        entries[id] = nil
        order.removeAll { $0 == id }
    }

    func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    func visibleEntry(for message: Message) -> MessageTranslationEntry? {
        guard let entry = entries[message.id], entry.isVisible, entry.sourceContent == message.content else {
            return nil
        }
        return entry
    }
}
