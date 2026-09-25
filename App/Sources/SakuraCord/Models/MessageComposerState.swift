import Foundation
import Observation
import SakuraCordModels
import SakuraCordPersistence

/// Owns both composers and their pending local writes for the installed account.
/// The model coordinates navigation and delivery; this owner resets as a unit.
@MainActor
@Observable
final class MessageComposerState {
    let slowmode = SlowmodeState()
    var draft = "" { didSet { draftRevision &+= 1 } }
    var threadDraft = "" { didSet { threadDraftRevision &+= 1 } }
    @ObservationIgnored private(set) var draftRevision: UInt64 = 0
    @ObservationIgnored private(set) var threadDraftRevision: UInt64 = 0
    var replyingTo: Message?
    var threadReplyingTo: Message?
    var replyMentionsAuthor = true
    var threadReplyMentionsAuthor = true
    var channelAttachments: [ForumPostAttachment] = []
    var threadAttachments: [ForumPostAttachment] = []
    @ObservationIgnored var outbox = OutgoingMessageState()
    @ObservationIgnored private var draftWriteTask: Task<Void, Never>?

    func persistDraft(_ value: String, channelID: ChannelID, database: SakuraCordDatabase?) {
        guard let database else { return }
        let previousWrite = draftWriteTask
        draftWriteTask = Task {
            // Capture the original database and serialize edits before reset.
            await previousWrite?.value
            try? await database.saveDraft(value, channelID: channelID)
        }
    }

    func storedDraft(in channelID: ChannelID, database: SakuraCordDatabase) async throws -> String {
        let previousWrite = draftWriteTask
        let read = Task {
            await previousWrite?.value
            return try await database.draft(channelID: channelID)
        }
        draftWriteTask = Task { _ = try? await read.value }
        return try await read.value
    }

    func flushDraftOperations() async {
        await draftWriteTask?.value
    }

    func restoreDraft(_ value: String, ifUnchangedSince revision: UInt64) {
        // Check at publication, since clearing can invalidate even a completed read.
        guard draftRevision == revision, draft.isEmpty else { return }
        draft = value
    }

    func clearDrafts(in database: SakuraCordDatabase) async throws {
        let previousDraft = draft
        let previousThreadDraft = threadDraft
        draft = ""
        threadDraft = ""
        let clearedDraftRevision = draftRevision
        let clearedThreadRevision = threadDraftRevision
        let previousWrite = draftWriteTask
        let deletion = Task {
            await previousWrite?.value
            try await database.clearDrafts()
        }
        // Later edits queue after deletion, while earlier accepted edits drain
        // before it. Reset and account switching also wait for this barrier.
        draftWriteTask = Task { _ = try? await deletion.value }
        do {
            try await deletion.value
        } catch {
            if draftRevision == clearedDraftRevision { draft = previousDraft }
            if threadDraftRevision == clearedThreadRevision { threadDraft = previousThreadDraft }
            throw error
        }
    }

    func reset() async {
        let pendingWrite = draftWriteTask
        draftWriteTask = nil
        draft = ""
        threadDraft = ""
        replyingTo = nil
        threadReplyingTo = nil
        replyMentionsAuthor = true
        threadReplyMentionsAuthor = true
        channelAttachments = []
        threadAttachments = []
        outbox.reset()
        slowmode.reset()
        await pendingWrite?.value
    }
}

struct OutgoingMessageState {
    var draftsByNonce: [String: SendMessageDraft] = [:]
    var stickerUploadSourceURLByNonce: [String: URL] = [:]
    private var nextOptimisticMessageRawValue = UInt64.max

    mutating func nextOptimisticMessageID() -> MessageID {
        defer { nextOptimisticMessageRawValue &-= 1 }
        return MessageID(rawValue: nextOptimisticMessageRawValue)
    }

    mutating func reset() {
        draftsByNonce.removeAll(keepingCapacity: false)
        stickerUploadSourceURLByNonce.removeAll(keepingCapacity: false)
        nextOptimisticMessageRawValue = UInt64.max
    }
}
