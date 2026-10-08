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
    var isSendQueueFullAlertPresented = false
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
        isSendQueueFullAlertPresented = false
        outbox.reset()
        slowmode.reset()
        await pendingWrite?.value
    }
}

struct OutgoingMessageState {
    /// The first-party client refuses a new message while this many sends wait
    /// behind the one in flight.
    static let maximumWaitingDeliveries = 5

    struct DeliveryTurn {
        let nonce: String
        let previous: Task<Void, Never>?
        let generation: UInt64
    }

    var draftsByNonce: [String: SendMessageDraft] = [:]
    var stickerUploadSourceURLByNonce: [String: URL] = [:]
    private var nextOptimisticMessageRawValue = UInt64.max
    private var deliveryTail: Task<Void, Never>?
    private var waitingNonces: Set<String> = []
    private var confirmedWaitingNonces: Set<String> = []
    private var submissionReservations: Set<UUID> = []
    private var deliveryGeneration: UInt64 = 0

    var waitingDeliveryCount: Int { waitingNonces.count + submissionReservations.count }

    var isDeliveryQueueFull: Bool {
        waitingDeliveryCount >= Self.maximumWaitingDeliveries
    }

    /// Holds capacity while a submission prepares its destination, before it has a send nonce.
    mutating func reserveSubmission() -> UUID? {
        guard !isDeliveryQueueFull else { return nil }
        let reservation = UUID()
        submissionReservations.insert(reservation)
        return reservation
    }

    mutating func releaseSubmission(_ reservation: UUID) {
        submissionReservations.remove(reservation)
    }

    /// Reserves the next position in the account's single delivery order.
    mutating func reserveDeliveryTurn(nonce: String) -> DeliveryTurn {
        waitingNonces.insert(nonce)
        return DeliveryTurn(nonce: nonce, previous: deliveryTail, generation: deliveryGeneration)
    }

    /// Remembers a confirmation for a send still waiting for its turn, even
    /// when the visible history window cannot show it.
    mutating func noteConfirmation(nonce: String) {
        if waitingNonces.contains(nonce) { confirmedWaitingNonces.insert(nonce) }
    }

    mutating func setDeliveryTail(_ delivery: Task<Void, Never>, for turn: DeliveryTurn) {
        guard turn.generation == deliveryGeneration else { return }
        deliveryTail = delivery
    }

    /// Leaves the waiting set; returns whether the send was confirmed meanwhile.
    mutating func beginDelivery(for turn: DeliveryTurn) -> Bool {
        guard turn.generation == deliveryGeneration else { return false }
        waitingNonces.remove(turn.nonce)
        return confirmedWaitingNonces.remove(turn.nonce) != nil
    }

    mutating func nextOptimisticMessageID() -> MessageID {
        defer { nextOptimisticMessageRawValue &-= 1 }
        return MessageID(rawValue: nextOptimisticMessageRawValue)
    }

    mutating func reset() {
        draftsByNonce.removeAll(keepingCapacity: false)
        stickerUploadSourceURLByNonce.removeAll(keepingCapacity: false)
        nextOptimisticMessageRawValue = UInt64.max
        deliveryTail = nil
        waitingNonces.removeAll()
        confirmedWaitingNonces.removeAll()
        submissionReservations.removeAll()
        deliveryGeneration &+= 1
    }
}
