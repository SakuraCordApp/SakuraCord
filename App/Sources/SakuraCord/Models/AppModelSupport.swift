import DiscordProtocol
import Foundation
import ImageIO
import MediaPipeline
import MessageRendering
import SakuraCordModels
import SakuraCordPersistence
import UniformTypeIdentifiers

struct AppModelAccountSession {
    let generation: UInt64
    let installedRevision: UInt64
    let allowsTransition: Bool
    let provider: any ChatProvider
    let database: SakuraCordDatabase?
}

struct AppModelVoiceOperationIdentity {
    let generation: Int
    let channelID: ChannelID?
    let session: DiscordVoiceSession?
}

actor AccountTransitionCoordinator {
    private var isAcquired = false

    func acquireIfAvailable() -> Bool {
        guard !isAcquired else { return false }
        isAcquired = true
        return true
    }

    func release() {
        isAcquired = false
    }
}

extension AppModel {
    func accountSession(allowsTransition: Bool = false) -> AppModelAccountSession {
        let isBlockedTransition = accountTransitionIsActive && !allowsTransition
        return AppModelAccountSession(
            generation: accountSessionGeneration,
            installedRevision: installedAccountSessionRevision,
            allowsTransition: allowsTransition,
            provider: isBlockedTransition ? SignedOutChatProvider() : provider,
            database: isBlockedTransition ? nil : database
        )
    }

    func isCurrentAccountSession(_ session: AppModelAccountSession) -> Bool {
        accountSessionGeneration == session.generation
            && installedAccountSessionRevision == session.installedRevision
            && (!accountTransitionIsActive || session.allowsTransition)
    }

    func invalidateAccountSession() {
        accountSessionGeneration &+= 1
    }

    func installAccountSession(
        provider: any ChatProvider,
        database: SakuraCordDatabase?
    ) {
        self.provider = provider
        self.database = database
        installedAccountSessionRevision &+= 1
    }

    @discardableResult
    func startAccountChildTask(
        account: AppModelAccountSession,
        operation: @escaping @MainActor (
            _ model: AppModel,
            _ account: AppModelAccountSession
        ) async -> Void
    ) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            defer { self?.accountChildTasks[id] = nil }
            guard let self,
                  !Task.isCancelled,
                  isCurrentAccountSession(account)
            else { return }
            await operation(self, account)
        }
        accountChildTasks[id] = task
        return task
    }

    func cancelAccountChildTasks() {
        for task in accountChildTasks.values {
            task.cancel()
        }
    }

    func drainAccountChildTasks() async {
        let tasks = Array(accountChildTasks.values)
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
        accountChildTasks.removeAll(keepingCapacity: false)
    }

    func currentVoiceOperationIdentity() -> AppModelVoiceOperationIdentity {
        AppModelVoiceOperationIdentity(
            generation: voiceMigrationGeneration,
            channelID: activeVoiceChannel?.id,
            session: voiceSession
        )
    }

    func isCurrentVoiceOperation(
        _ account: AppModelAccountSession,
        identity: AppModelVoiceOperationIdentity
    ) -> Bool {
        guard isCurrentAccountSession(account),
              voiceMigrationGeneration == identity.generation,
              activeVoiceChannel?.id == identity.channelID
        else { return false }
        if let expectedSession = identity.session {
            return voiceSession === expectedSession
        }
        return voiceSession == nil
    }

    func observePrivateCall(
        in channel: Channel,
        account: AppModelAccountSession
    ) async {
        guard channel.kind == .directMessage || channel.kind == .groupDirectMessage else {
            return
        }
        guard !Task.isCancelled, isCurrentAccountSession(account) else { return }
        do {
            try await account.provider.subscribeToPrivateCall(channelID: channel.id)
            guard !Task.isCancelled, isCurrentAccountSession(account) else { return }
        } catch {
            // Observation is opportunistic while the Gateway is reconnecting.
            // Connection-ready reconciliation will subscribe again.
        }
    }

    func resetAppSounds() {
        resetPrivateCallActions()
        for task in outgoingPrivateCallRingTimeoutTasks.values {
            task.cancel()
        }
        outgoingPrivateCallRingTimeoutTasks = [:]
        locallyStartedOutgoingPrivateCallRings = []
        soundPlayer.stopAll()
    }
}

struct PreparedCreatedMessage: Sendable {
    let message: Message
    let textPlan: NativeTimelineTextPlan?
}

nonisolated enum OptimisticAttachmentPresentation {
    static func attachment(for url: URL, index: Int) -> Attachment {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        let properties = source.flatMap {
            CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
        }
        let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Attachment(
            id: "pending-\(index)",
            filename: url.lastPathComponent,
            url: url,
            mediaType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType,
            width: (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            height: (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            size: resourceValues?.fileSize ?? 0
        )
    }
}

nonisolated enum MessageComposerDestination: Hashable, Sendable {
    case channel
    case thread
}

nonisolated enum MessageReplyNavigationDirection: Equatable, Sendable {
    case older
    case newer
}

nonisolated struct ComponentControlKey: Hashable, Sendable {
    let messageID: MessageID
    let customID: String
}

nonisolated struct MessageNavigationRequest: Equatable, Sendable {
    let requestID: UInt64
    let channelID: ChannelID
    let messageID: MessageID
}

nonisolated struct ConversationNewestRequest: Equatable, Sendable {
    let requestID: UInt64
    let channelID: ChannelID
}

struct ProfilePresentationState {
    let requestID: UUID
    var member: Member
    var profile: UserProfile?
    var isLoading: Bool
    var errorMessage: String?
}

struct ProfileCacheKey: Hashable {
    let userID: UserID
    let guildID: GuildID?
}

enum ProfilePresentationDestination {
    case inspector
    case contextual
}

nonisolated enum UnreadPresentationPublicationPolicy {
    static func shouldPublish(
        snapshot: BootstrapSnapshot,
        channels: [Channel],
        guilds: [Guild]
    ) -> Bool {
        snapshot.channels != channels || snapshot.guilds != guilds
    }
}

nonisolated struct ForumPostPresentation: Sendable {
    var posts: [ForumPost]
    var recentCount: Int

    static func make(
        catalogue: [ForumPost],
        searchText: String,
        selectedTagIDs: Set<ForumTagID>,
        tagMatch: ForumTagMatch,
        sortOrder: ForumSortOrder
    ) -> Self {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var recent: [ForumPost] = []
        var older: [ForumPost] = []
        recent.reserveCapacity(catalogue.count)
        older.reserveCapacity(min(catalogue.count, 64))

        for post in catalogue {
            guard matches(
                post,
                search: search,
                selectedTagIDs: selectedTagIDs,
                tagMatch: tagMatch
            ) else { continue }
            if post.thread.isArchived {
                older.append(post)
            } else {
                recent.append(post)
            }
        }

        recent.sort { areInDisplayOrder($0, $1, sortOrder: sortOrder) }
        older.sort { areInDisplayOrder($0, $1, sortOrder: sortOrder) }
        let recentCount = recent.count
        recent.append(contentsOf: older)
        return Self(posts: recent, recentCount: recentCount)
    }

    func updating(
        _ post: ForumPost,
        searchText: String,
        selectedTagIDs: Set<ForumTagID>,
        tagMatch: ForumTagMatch,
        sortOrder: ForumSortOrder
    ) -> Self {
        var result = self
        if let oldIndex = result.posts.firstIndex(where: { $0.id == post.id }) {
            result.posts.remove(at: oldIndex)
            if oldIndex < result.recentCount { result.recentCount -= 1 }
        }

        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.matches(
            post,
            search: search,
            selectedTagIDs: selectedTagIDs,
            tagMatch: tagMatch
        ) else { return result }

        let range = post.thread.isArchived
            ? result.recentCount ..< result.posts.endIndex
            : result.posts.startIndex ..< result.recentCount
        let insertionIndex = Self.insertionIndex(
            of: post,
            in: result.posts,
            range: range,
            sortOrder: sortOrder
        )
        result.posts.insert(post, at: insertionIndex)
        if !post.thread.isArchived { result.recentCount += 1 }
        return result
    }

    func filtering(
        searchText: String,
        selectedTagIDs: Set<ForumTagID>,
        tagMatch: ForumTagMatch
    ) -> Self {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var filtered: [ForumPost] = []
        filtered.reserveCapacity(posts.count)
        var filteredRecentCount = 0
        for (index, post) in posts.enumerated() where Self.matches(
            post,
            search: search,
            selectedTagIDs: selectedTagIDs,
            tagMatch: tagMatch
        ) {
            filtered.append(post)
            if index < recentCount { filteredRecentCount += 1 }
        }
        return Self(posts: filtered, recentCount: filteredRecentCount)
    }

    private static func matches(
        _ post: ForumPost,
        search: String,
        selectedTagIDs: Set<ForumTagID>,
        tagMatch: ForumTagMatch
    ) -> Bool {
        if !selectedTagIDs.isEmpty {
            guard ForumPostQueryPolicy.matchesTags(
                post,
                selectedTagIDs: selectedTagIDs,
                tagMatch: tagMatch
            ) else { return false }
        }
        return search.isEmpty || post.thread.name.localizedCaseInsensitiveContains(search)
    }

    private static func areInDisplayOrder(
        _ lhs: ForumPost,
        _ rhs: ForumPost,
        sortOrder: ForumSortOrder
    ) -> Bool {
        ForumPostQueryPolicy.areInDisplayOrder(lhs, rhs, sortOrder: sortOrder)
    }

    private static func insertionIndex(
        of post: ForumPost,
        in posts: [ForumPost],
        range: Range<Int>,
        sortOrder: ForumSortOrder
    ) -> Int {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if areInDisplayOrder(post, posts[middle], sortOrder: sortOrder) {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return lower
    }
}

actor ReactionReactorLoadLimiter {
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Never>
    }

    let maximumConcurrentLoads: Int
    private var activeLoadCount = 0
    private var waiters: [Waiter] = []

    init(maximumConcurrentLoads: Int) {
        self.maximumConcurrentLoads = max(1, maximumConcurrentLoads)
    }

    func withPermit<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if activeLoadCount < maximumConcurrentLoads {
            activeLoadCount += 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(Waiter(continuation: continuation))
        }
    }

    private func release() {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume()
        } else {
            activeLoadCount = max(0, activeLoadCount - 1)
        }
    }
}

enum DiscordCustomEmojiCatalog {
    static func ordered(
        emojisByGuild: [GuildID: [DiscordEmoji]],
        guildOrder: [GuildID]
    ) -> [DiscordEmoji] {
        var seenGuilds = Set<GuildID>()
        let orderedGuilds = guildOrder.filter { seenGuilds.insert($0).inserted }
        let remainingGuilds = emojisByGuild.keys
            .filter { seenGuilds.insert($0).inserted }
            .sorted { $0.rawValue > $1.rawValue }
        return (orderedGuilds + remainingGuilds).flatMap { emojisByGuild[$0] ?? [] }
    }

    static func imageURLsByID(from emojis: [DiscordEmoji]) -> [String: URL] {
        emojis.reduce(into: [:]) { urls, emoji in
            if let url = emoji.assetURL ?? emoji.imageURL {
                urls[emoji.id] = url
            }
        }
    }
}

nonisolated enum DiscordEmojiUseCase: Equatable, Sendable {
    case message
    case reaction(guildID: GuildID?)
}

nonisolated enum DiscordEmojiPermissionPolicy {
    static func hasNitro(premiumType: Int) -> Bool {
        premiumType > 0
    }

    static func composerText(
        for emoji: DiscordEmoji,
        currentGuildID: GuildID?,
        premiumType: Int
    ) -> String {
        let requiresNitro = emoji.isAnimated || emoji.guildID != currentGuildID
        return !hasNitro(premiumType: premiumType) && requiresNitro
            ? emoji.linkedImageMarkdown
            : emoji.messageToken
    }

    static func canShow(_ emoji: DiscordEmoji, for useCase: DiscordEmojiUseCase, premiumType: Int)
        -> Bool
    {
        switch useCase {
        case .message:
            true
        case .reaction(let guildID):
            hasNitro(premiumType: premiumType)
                || (!emoji.isAnimated && emoji.guildID == guildID)
        }
    }

    static func canShowGuild(
        _ guildID: GuildID,
        for useCase: DiscordEmojiUseCase,
        premiumType: Int
    ) -> Bool {
        switch useCase {
        case .message:
            true
        case .reaction(let currentGuildID):
            hasNitro(premiumType: premiumType) || guildID == currentGuildID
        }
    }

    static func canToggleReaction(
        _ rawEmoji: String,
        existingReactions: [Reaction],
        currentGuildEmojis: [DiscordEmoji],
        premiumType: Int
    ) -> Bool {
        let reference = EmojiReference(rawToken: rawEmoji)
        guard let emojiID = reference.id else { return true }

        if existingReactions.contains(where: { $0.emojiReference.id == emojiID }) {
            // Discord permits joining an existing reaction even when its
            // custom emoji would not be available in the add-reaction picker.
            return true
        }
        if hasNitro(premiumType: premiumType) {
            return true
        }
        guard !reference.isAnimated else { return false }
        return currentGuildEmojis.contains {
            $0.id == emojiID && !$0.isAnimated && $0.isAvailable
        }
    }
}

@MainActor
struct MessageRowsUpdateHint: Equatable {
    enum Change: Equatable {
        case insert(IndexSet)
        case replace(IndexSet)
        case remove(removedIndexes: IndexSet, changedIndexes: IndexSet)
    }

    let revision: UInt64
    let change: Change
}

struct MessageRowsUpdateRecord: Equatable {
    let revision: UInt64
    let change: MessageRowsUpdateHint.Change?
    let insertedMessageIDs: [MessageID]
    let changedMessageIDs: Set<MessageID>
    let removedMessageIDs: Set<MessageID>
    let invalidatesAllRows: Bool
}

@MainActor
final class MessageRowsUpdateJournal {
    private var storage: [MessageRowsUpdateRecord] = []

    var latestRevision: UInt64? {
        storage.last?.revision
    }

    func append(_ record: MessageRowsUpdateRecord) {
        storage.append(record)
        if storage.count > 4_608 {
            storage.removeFirst(512)
        }
    }

    func records(
        after oldRevision: UInt64,
        through newRevision: UInt64
    ) -> ArraySlice<MessageRowsUpdateRecord>? {
        guard newRevision > oldRevision,
              let firstRevision = storage.first?.revision,
              let lastRevision = storage.last?.revision,
              oldRevision &+ 1 >= firstRevision,
              newRevision <= lastRevision
        else {
            return nil
        }

        let lowerBound = Int(oldRevision &+ 1 - firstRevision)
        let upperBound = Int(newRevision - firstRevision) + 1
        guard storage.indices.contains(lowerBound),
              upperBound <= storage.endIndex
        else {
            return nil
        }
        return storage[lowerBound ..< upperBound]
    }
}

enum MessageRowsUpdateRecordBuilder {
    static func make(
        oldRows: [MessageRowPresentation],
        newRows: [MessageRowPresentation],
        revision: UInt64
    ) -> MessageRowsUpdateRecord {
        let oldIDs = oldRows.map(\.id)
        let newIDs = newRows.map(\.id)
        let oldRowsByID = Dictionary(
            uniqueKeysWithValues: oldRows.map { ($0.id, $0) }
        )
        let changedMessageIDs = Set<MessageID>(
            newRows.lazy.compactMap { row in
                guard let oldRow = oldRowsByID[row.id],
                      oldRow != row
                else { return nil }
                return row.id
            }
        )

        if oldIDs == newIDs {
            return MessageRowsUpdateRecord(
                revision: revision,
                change: .replace(
                    IndexSet(
                        newRows.indices.filter {
                            oldRows[$0] != newRows[$0]
                        }
                    )
                ),
                insertedMessageIDs: [],
                changedMessageIDs: changedMessageIDs,
                removedMessageIDs: [],
                invalidatesAllRows: false
            )
        }

        if let insertedIndexes = insertedIndexes(
            preserving: oldIDs,
            in: newIDs
        ) {
            return MessageRowsUpdateRecord(
                revision: revision,
                change: .insert(insertedIndexes),
                insertedMessageIDs: insertedIndexes.map { newIDs[$0] },
                changedMessageIDs: changedMessageIDs,
                removedMessageIDs: [],
                invalidatesAllRows: false
            )
        }

        if let removedIndexes = removedIndexes(
            preserving: newIDs,
            in: oldIDs
        ) {
            let changedIndexes = IndexSet(
                newRows.indices.filter {
                    changedMessageIDs.contains(newRows[$0].id)
                }
            )
            return MessageRowsUpdateRecord(
                revision: revision,
                change: .remove(
                    removedIndexes: removedIndexes,
                    changedIndexes: changedIndexes
                ),
                insertedMessageIDs: [],
                changedMessageIDs: changedMessageIDs,
                removedMessageIDs: Set(removedIndexes.map { oldIDs[$0] }),
                invalidatesAllRows: false
            )
        }

        return MessageRowsUpdateRecord(
            revision: revision,
            change: nil,
            insertedMessageIDs: [],
            changedMessageIDs: changedMessageIDs,
            removedMessageIDs: [],
            invalidatesAllRows: true
        )
    }

    private static func insertedIndexes(
        preserving oldIDs: [MessageID],
        in newIDs: [MessageID]
    ) -> IndexSet? {
        guard newIDs.count >= oldIDs.count else { return nil }
        var oldIndex = oldIDs.startIndex
        var inserted = IndexSet()
        for newIndex in newIDs.indices {
            if oldIndex < oldIDs.endIndex,
               newIDs[newIndex] == oldIDs[oldIndex]
            {
                oldIndex += 1
            } else {
                inserted.insert(newIndex)
            }
        }
        return oldIndex == oldIDs.endIndex ? inserted : nil
    }

    private static func removedIndexes(
        preserving newIDs: [MessageID],
        in oldIDs: [MessageID]
    ) -> IndexSet? {
        guard oldIDs.count >= newIDs.count else { return nil }
        var newIndex = newIDs.startIndex
        var removed = IndexSet()
        for oldIndex in oldIDs.indices {
            if newIndex < newIDs.endIndex,
               oldIDs[oldIndex] == newIDs[newIndex]
            {
                newIndex += 1
            } else {
                removed.insert(oldIndex)
            }
        }
        return newIndex == newIDs.endIndex ? removed : nil
    }
}

nonisolated enum LocalHistoryMemberResolution {
    static let maximumUserCount = 100

    static func userIDs(in messages: [Message], known: Set<UserID>) -> [UserID] {
        var seen = known
        var result: [UserID] = []

        func append(_ userID: UserID) {
            guard result.count < maximumUserCount, seen.insert(userID).inserted else { return }
            result.append(userID)
        }

        // Prefer the newest visible authors when a long local cache contains
        // more unique people than one bounded Gateway member request permits.
        for message in messages.reversed() {
            append(message.author.id)
            if let replyAuthorID = message.replyPreview?.author.id {
                append(replyAuthorID)
            }
        }
        for message in messages.reversed() {
            for user in message.mentionedUsers {
                append(user.id)
            }
        }
        return result
    }

    static func hydrating(
        _ messages: [Message],
        with membersByID: [UserID: Member]
    ) -> [Message] {
        messages.map { original in
            var message = original
            if let member = membersByID[message.author.id] {
                message.guildMember = MessageGuildMember.merging(
                    incoming: MessageGuildMember(member: member),
                    existing: message.guildMember
                )
            }
            if var preview = message.replyPreview,
               let member = membersByID[preview.author.id]
            {
                preview.guildMember = MessageGuildMember.merging(
                    incoming: MessageGuildMember(member: member),
                    existing: preview.guildMember
                )
                message.replyPreview = preview
            }
            return message
        }
    }

}

nonisolated enum ChannelMessageCachePolicy {
    static let maximumChannelCount = 8
    static let maximumPreparedChannelCount = 3
    static let maximumMessageCountPerChannel = 250

    static func retainedMessages(from messages: [Message]) -> [Message] {
        guard messages.count > maximumMessageCountPerChannel else {
            return messages
        }
        return Array(messages.suffix(maximumMessageCountPerChannel))
    }
}

/// Reduces a live guild-member update to the fields that can actually change
/// pixels or geometry in a message row. Presence, activity, list grouping,
/// and other inspector-only churn must not invalidate the timeline.
nonisolated enum TimelineMemberPresentationImpact {
    struct Signature: Equatable {
        let user: User
        let guildAvatarURL: URL?
        let roleColorHex: UInt32?
    }

    static func changedUserIDs(
        from oldMembers: [UserID: Member],
        to newMembers: [UserID: Member],
        guildRoles: [GuildRole]
    ) -> Set<UserID> {
        let candidates = Set(oldMembers.keys).union(newMembers.keys)
        return Set(candidates.filter { userID in
            signature(for: oldMembers[userID], guildRoles: guildRoles)
                != signature(for: newMembers[userID], guildRoles: guildRoles)
        })
    }

    static func affectedMessageIDs(
        in messages: [Message],
        changedUserIDs: Set<UserID>
    ) -> Set<MessageID> {
        guard !changedUserIDs.isEmpty else { return [] }
        return Set(messages.lazy.compactMap { message in
            guard changedUserIDs.contains(message.author.id)
                    || message.replyPreview.map({
                        changedUserIDs.contains($0.author.id)
                    }) == true
                    || message.mentionedUsers.contains(where: {
                        changedUserIDs.contains($0.id)
                    })
            else { return nil }
            return message.id
        })
    }

    private static func signature(
        for member: Member?,
        guildRoles: [GuildRole]
    ) -> Signature? {
        guard let member else { return nil }
        let roleIDs = Set(member.roleIDs)
        return Signature(
            user: member.user,
            guildAvatarURL: member.guildAvatarURL,
            roleColorHex:
                MessageAuthorPresentation.topRoleColor(in: member.roles)
                    ?? MessageAuthorPresentation.topRoleColor(
                        in: guildRoles.filter { roleIDs.contains($0.id) }
                    )
        )
    }
}
