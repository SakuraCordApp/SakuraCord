import Foundation
import Observation
import SakuraCordModels

@MainActor
@Observable
final class TranslationState {
    var settings: TranslationSettingsSnapshot
    var drafts: [MessageComposerDestination: DraftTranslation] = [:]
    var draftEditIDs: [MessageComposerDestination: UUID] = [:]
    let coordinator: AppleTranslationCoordinator
    @ObservationIgnored let settingsStore: TranslationSettingsStore
    @ObservationIgnored let translator: any TextTranslating
    @ObservationIgnored let messages = MessageTranslationStore()
    @ObservationIgnored var messageTasks: [MessageID: Task<Void, Never>] = [:]
    @ObservationIgnored var draftTasks: [MessageComposerDestination: Task<Void, Never>] = [:]

    init(settingsStore: TranslationSettingsStore = .shared, translator: (any TextTranslating)? = nil,
         coordinator: AppleTranslationCoordinator = AppleTranslationCoordinator()) {
        self.settingsStore = settingsStore
        settings = settingsStore.load()
        self.coordinator = coordinator
        self.translator = translator ?? coordinator
    }

    func resetDraft(_ destination: MessageComposerDestination) {
        draftTasks.removeValue(forKey: destination)?.cancel()
        drafts[destination] = nil
    }

    func removeMessage(_ id: MessageID) {
        messageTasks.removeValue(forKey: id)?.cancel()
        messages.remove(id)
    }

    func resetAll() {
        for task in messageTasks.values { task.cancel() }
        messageTasks.removeAll()
        for destination in Array(draftTasks.keys) { resetDraft(destination) }
        drafts.removeAll()
        draftEditIDs.removeAll()
        coordinator.cancelAll()
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
    var language: String
    var phase: Phase
    var requestRevision: UInt64 = 0
    var requestID = UUID()
}

nonisolated struct MessageTranslationEntry: Equatable, Sendable {
    nonisolated enum Status: Equatable, Sendable {
        case loading
        case translated(TranslationResult)
        case failed(String)
    }

    var sourceContent: String
    var language: String
    var status: Status
    var isVisible = true
    var requestID = UUID()
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
