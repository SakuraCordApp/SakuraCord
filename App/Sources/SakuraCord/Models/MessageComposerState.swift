import Foundation
import Observation
import SakuraCordModels
import SakuraCordPersistence

/// Owns both composers and their pending local writes for the installed account.
/// The model coordinates navigation and delivery; account reset preserves the
/// app-wide reply preference while clearing pending account work.
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
    /// Shared across both composers and accounts. Self-replies suppress the
    /// effective ping without changing the user's persisted choice.
    private(set) var replyMentionsAuthorChoice: Bool
    @ObservationIgnored private let preferences: SettingsPreferenceStore?
    var channelAttachments: [ForumPostAttachment] = []
    var threadAttachments: [ForumPostAttachment] = []
    var isSendQueueFullAlertPresented = false
    @ObservationIgnored var outbox = OutgoingMessageState()
    @ObservationIgnored private var draftWriteTask: Task<Void, Never>?
    /// Staged files whose privacy and size check is still running. They show
    /// in the composer at once but cannot be sent until it finishes.
    var checkingAttachmentIDs: Set<UUID> = []
    @ObservationIgnored private var animatedResizeUptimes: [MessageComposerDestination: TimeInterval] = [:]

    init(preferences: SettingsPreferenceStore? = nil) {
        self.preferences = preferences
        if case let .bool(choice) = preferences?.value(for: .replyMentionsAuthor) {
            replyMentionsAuthorChoice = choice
        } else {
            replyMentionsAuthorChoice = true
        }
    }

    func rememberReplyMentionsAuthor(_ choice: Bool) {
        replyMentionsAuthorChoice = choice
        preferences?.set(.bool(choice), for: .replyMentionsAuthor)
    }

    /// Records that a composer began animating to a new height, so the
    /// timeline above it glides along instead of jumping.
    func noteAnimatedResize(
        of destination: MessageComposerDestination,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        animatedResizeUptimes[destination] = now
    }

    func isAnimatingResize(
        of destination: MessageComposerDestination,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        animatedResizeUptimes[destination].map {
            now - $0 <= ComposerResizeMotion.signalLifetime
        } ?? false
    }

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
        channelAttachments = []
        threadAttachments = []
        checkingAttachmentIDs = []
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

    var draftsByNonce: [String: SendMessageDraft] = [:] {
        didSet {
            statesByNonce = statesByNonce.filter { retainsState(nonce: $0.key) }
        }
    }
    // History windows can evict optimistic rows while a failed draft or active
    // send still exists. Delivery status belongs to that outbox lifetime.
    private struct DeliveryState {
        let channelID: ChannelID
        let state: OutboxState
    }

    private var statesByNonce: [String: DeliveryState] = [:]
    private var deliveryNonces: Set<String> = []
    private var retainedReceiptNonces: Set<String> = []
    var stickerUploadSourceURLByNonce: [String: URL] = [:]
    private var nextOptimisticMessageRawValue = UInt64.max
    private var deliveryTail: Task<Void, Never>?
    private var waitingNonces: Set<String> = []
    private var withdrawnNonces: Set<String> = []
    private var submissionReservations: [UUID: String] = [:]
    private var deliveryGeneration: UInt64 = 0

    var waitingDeliveryCount: Int { waitingNonces.count + submissionReservations.count }

    var isDeliveryQueueFull: Bool {
        waitingDeliveryCount >= Self.maximumWaitingDeliveries
    }

    /// Holds capacity while a submission prepares its destination.
    mutating func reserveSubmission(nonce: String? = nil) -> UUID? {
        guard !isDeliveryQueueFull, nonce.map({ !hasPendingDelivery(nonce: $0) }) ?? true else { return nil }
        let reservation = UUID()
        submissionReservations[reservation] = nonce ?? ""
        return reservation
    }

    mutating func releaseSubmission(_ reservation: UUID) {
        submissionReservations[reservation] = nil
    }

    func hasPendingDelivery(nonce: String) -> Bool {
        deliveryNonces.contains(nonce) || submissionReservations.values.contains(nonce)
    }

    func state(nonce: String, channelID: ChannelID) -> OutboxState? {
        guard let value = statesByNonce[nonce], value.channelID == channelID else { return nil }
        return value.state
    }

    mutating func updateState(_ state: OutboxState, nonce: String, channelID: ChannelID) {
        statesByNonce[nonce] = DeliveryState(channelID: channelID, state: state)
    }

    /// A quick-message field retains an ambiguous send's receipt until its
    /// unchanged nonce is consumed, edited or dismissed, independently of history.
    mutating func retainReceipt(nonce: String) {
        retainedReceiptNonces.insert(nonce)
    }

    mutating func releaseReceipt(nonce: String) {
        retainedReceiptNonces.remove(nonce)
        if !retainsState(nonce: nonce) { statesByNonce[nonce] = nil }
    }

    private func retainsState(nonce: String) -> Bool {
        draftsByNonce[nonce] != nil || deliveryNonces.contains(nonce) || retainedReceiptNonces.contains(nonce)
    }

    /// Reserves the next position in the account's single delivery order.
    mutating func reserveDeliveryTurn(nonce: String) -> DeliveryTurn {
        waitingNonces.insert(nonce)
        deliveryNonces.insert(nonce)
        return DeliveryTurn(nonce: nonce, previous: deliveryTail, generation: deliveryGeneration)
    }

    /// Remembers an authoritative receipt even when history cannot show it.
    mutating func noteConfirmation(nonce: String, channelID: ChannelID) {
        if retainsState(nonce: nonce) {
            updateState(.confirmed, nonce: nonce, channelID: channelID)
        }
    }

    mutating func setDeliveryTail(_ delivery: Task<Void, Never>, for turn: DeliveryTurn) {
        guard turn.generation == deliveryGeneration else { return }
        deliveryTail = delivery
    }

    /// A send withdrawn before its turn frees its queue position at once and
    /// delivers nothing when the turn arrives. Returns whether it was waiting.
    mutating func withdrawWaitingDelivery(nonce: String) -> Bool {
        guard waitingNonces.remove(nonce) != nil else { return false }
        withdrawnNonces.insert(nonce)
        return true
    }

    func isWithdrawn(nonce: String) -> Bool {
        withdrawnNonces.contains(nonce)
    }

    /// Leaves the waiting set; returns whether the send was confirmed meanwhile.
    mutating func beginDelivery(for turn: DeliveryTurn) -> Bool {
        guard turn.generation == deliveryGeneration else { return false }
        waitingNonces.remove(turn.nonce)
        return statesByNonce[turn.nonce]?.state == .confirmed
    }

    mutating func finishDelivery(for turn: DeliveryTurn) {
        guard turn.generation == deliveryGeneration else { return }
        deliveryNonces.remove(turn.nonce)
        withdrawnNonces.remove(turn.nonce)
        if !retainsState(nonce: turn.nonce) { statesByNonce[turn.nonce] = nil }
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
        withdrawnNonces.removeAll()
        submissionReservations.removeAll()
        statesByNonce.removeAll()
        retainedReceiptNonces.removeAll()
        deliveryNonces.removeAll()
        deliveryGeneration &+= 1
    }
}
