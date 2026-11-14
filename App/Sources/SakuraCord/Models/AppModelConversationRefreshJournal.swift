import Foundation
import SakuraCordModels

enum ConversationRefreshMutation {
    case upsert(Message)
    case patch(MessageUpdate)
    case delete
}

struct ConversationRefreshMutations {
    var messages: [MessageID: ConversationRefreshMutation] = [:]
    var updatedUsers: [UserID: User] = [:]
}

struct ConversationRefreshJournal {
    let revision: UInt64
    var mutations = ConversationRefreshMutations()

    mutating func record(_ mutation: ConversationRefreshMutation, messageID: MessageID) {
        if case .patch(let update) = mutation {
            switch mutations.messages[messageID] {
            case .upsert(var message):
                update.apply(to: &message)
                mutations.messages[messageID] = .upsert(message)
            case .patch(var previous):
                previous.merge(update)
                mutations.messages[messageID] = .patch(previous)
            case .delete:
                break
            case nil:
                mutations.messages[messageID] = mutation
            }
        } else {
            mutations.messages[messageID] = mutation
        }
    }

    mutating func recordIdentityUpdate(_ user: User) {
        mutations.updatedUsers[user.id] = user
        // Fold the event into earlier mutations, including messages whose
        // history page has not been published in any retained projection yet.
        for (messageID, mutation) in mutations.messages {
            switch mutation {
            case .upsert(var message):
                message.applyIdentityUpdate(user)
                mutations.messages[messageID] = .upsert(message)
            case .patch(var patch):
                var identity = MessageUpdate(messageID: messageID, channelID: patch.channelID)
                identity.updatedUsers[user.id] = user
                patch.merge(identity)
                mutations.messages[messageID] = .patch(patch)
            case .delete:
                break
            }
        }
    }
}

/// A journal for one in-flight history request, so overlapping requests in
/// the same conversation each reconcile the mutations made during their own
/// flight.
struct ScopedConversationRefreshJournal {
    let channelID: ChannelID
    var journal: ConversationRefreshJournal
}

extension AppModel {
    func beginConversationRefresh(in channelID: ChannelID) -> UInt64 {
        conversationRefreshJournalRevision &+= 1
        let revision = conversationRefreshJournalRevision
        conversationRefreshJournals[channelID] = ConversationRefreshJournal(
            revision: revision
        )
        return revision
    }

    func recordConversationRefreshMutation(
        _ mutation: ConversationRefreshMutation,
        messageID: MessageID,
        channelID: ChannelID
    ) {
        var mutation = mutation
        if case .patch(var update) = mutation, !update.pollUpdates.isEmpty,
           var message = retainedMessage(channelID: channelID, messageID: messageID), message.poll?.results != nil {
            // Preserve an established local tally instead of adding the same
            // vote again if a fetched page already includes it.
            update.apply(to: &message)
            if let poll = pollVoteConfirmedSnapshot(message).poll {
                update.pollUpdates = [.snapshot(poll, preservingSelection: false)]
                mutation = .patch(update)
            }
        }
        conversationRefreshJournals[channelID]?.record(mutation, messageID: messageID)
        for revision in scopedRefreshJournals.keys where scopedRefreshJournals[revision]?.channelID == channelID {
            scopedRefreshJournals[revision]?.journal.record(mutation, messageID: messageID)
        }
        inbox.refreshJournal?.record(mutation, messageID: messageID)
        recordPollRefreshMutation(mutation, messageID: messageID, channelID: channelID)
        if guideResource?.channelID == channelID {
            guideResource?.refreshJournal?.record(mutation, messageID: messageID)
        }
    }

    func conversationRefreshMutations(
        in channelID: ChannelID,
        revision: UInt64
    ) -> ConversationRefreshMutations {
        guard let journal = conversationRefreshJournals[channelID],
              journal.revision == revision
        else { return .init() }
        return journal.mutations
    }

    func endConversationRefresh(
        in channelID: ChannelID,
        revision: UInt64
    ) {
        guard conversationRefreshJournals[channelID]?.revision == revision else {
            return
        }
        conversationRefreshJournals[channelID] = nil
    }

    func cancelConversationRefresh(in channelID: ChannelID) {
        conversationRefreshJournals[channelID] = nil
        scopedRefreshJournals = scopedRefreshJournals.filter { $0.value.channelID != channelID }
    }

    func beginScopedConversationRefresh(in channelID: ChannelID) -> UInt64 {
        conversationRefreshJournalRevision &+= 1
        let revision = conversationRefreshJournalRevision
        scopedRefreshJournals[revision] = ScopedConversationRefreshJournal(
            channelID: channelID,
            journal: ConversationRefreshJournal(revision: revision)
        )
        return revision
    }

    func scopedConversationRefreshMutations(_ revision: UInt64) -> ConversationRefreshMutations {
        guard let journal = scopedRefreshJournals[revision]?.journal else { return .init() }
        return journal.mutations
    }

    func endScopedConversationRefresh(_ revision: UInt64) {
        scopedRefreshJournals[revision] = nil
    }

    @discardableResult
    func journalAuthoritativeMessageUpsert(_ message: Message) -> Message {
        let persistedMessage = pollVoteConfirmedSnapshot(reactionConfirmedSnapshot(message))
        recordConversationRefreshMutation(
            .upsert(persistedMessage),
            messageID: persistedMessage.id,
            channelID: persistedMessage.channelID
        )
        return persistedMessage
    }

    /// - Parameter span: Journaled messages missing from `messages` are
    ///   added only inside it.
    static func applyingConversationRefreshMutations(
        _ mutations: ConversationRefreshMutations,
        to messages: [Message],
        within span: MessageHistorySpan = .unbounded
    ) -> [Message] {
        var byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        // Message mutations already contain identity events that followed them.
        // Apply the conversation-wide fallback first so it cannot overwrite
        // explicit message identity fields received later.
        for messageID in byID.keys {
            for user in mutations.updatedUsers.values { byID[messageID]?.applyIdentityUpdate(user) }
        }
        for (messageID, mutation) in mutations.messages {
            switch mutation {
            case .upsert(let message):
                guard byID[messageID] != nil || span.contains(messageID) else { continue }
                byID[messageID] = message
            case .patch(let update):
                if var message = byID[messageID] {
                    update.applyForRefresh(to: &message)
                    byID[messageID] = message
                }
            case .delete:
                byID[messageID] = nil
            }
        }
        return byID.values.sorted(by: messagePrecedes)
    }
}
