import DiscordProtocol
import Foundation
import Observation
import SakuraCordModels

/// Commands as typed, read when their indicator's popover opens.
@Observable
final class MessageInteractionDataStore {
    enum Entry {
        case loading
        case loaded(MessageInteractionData)
        case failed
    }

    var entries: [MessageID: Entry] = [:]

    func reset() {
        entries = [:]
    }
}

extension AppModel {
    func loadMessageInteractionData(for message: Message) {
        let store = messageInteractionData
        guard !accountTransitionIsActive else { return }
        switch store.entries[message.id] {
        case .loading, .loaded: return
        case .failed, nil: break
        }
        store.entries[message.id] = .loading
        startAccountChildTask(account: accountSession()) { model, account in
            let entry: MessageInteractionDataStore.Entry
            do {
                entry = try await .loaded(
                    account.provider.messageInteractionData(channelID: message.channelID, messageID: message.id)
                )
            } catch {
                entry = .failed
            }
            let store = model.messageInteractionData
            guard model.isCurrentAccountSession(account), !Task.isCancelled else {
                // A discarded read must not leave the pill loading for good;
                // the next open reads again.
                if case .loading? = store.entries[message.id] { store.entries[message.id] = nil }
                return
            }
            store.entries[message.id] = entry
        }
    }
}
