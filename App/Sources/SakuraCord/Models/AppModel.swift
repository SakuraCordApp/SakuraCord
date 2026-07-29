import CoreAudio
import CoreText
import DiscordProtocol
import Foundation
import ImageIO
import MediaPipeline
import MessageRendering
import OSLog
import Observation
import SakuraCordModels
import SakuraCordPersistence
import UniformTypeIdentifiers
import UserNotifications

private final class MessagePersistenceSink: @unchecked Sendable {
    private static let batchInterval: Duration = .milliseconds(100)

    private enum Event: Sendable {
        case save(SakuraCordDatabase, Message)
        case flush
    }

    private struct PendingBatch {
        let database: SakuraCordDatabase
        var messages: [Message] = []
    }

    private let continuation: AsyncStream<Event>.Continuation
    private let worker: Task<Void, Never>

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        self.continuation = continuation
        worker = Task.detached(priority: .background) {
            var batches: [ObjectIdentifier: PendingBatch] = [:]
            var flushScheduled = false
            for await event in stream {
                switch event {
                case let .save(database, message):
                    let key = ObjectIdentifier(database)
                    if batches[key] == nil {
                        batches[key] = PendingBatch(database: database)
                    }
                    batches[key]?.messages.append(message)
                    guard !flushScheduled else { continue }
                    flushScheduled = true
                    Task.detached(priority: .background) {
                        try? await Task.sleep(for: Self.batchInterval)
                        continuation.yield(.flush)
                    }
                case .flush:
                    let pending = Array(batches.values)
                    batches.removeAll(keepingCapacity: true)
                    flushScheduled = false
                    for batch in pending {
                        try? await batch.database.save(messages: batch.messages)
                    }
                }
            }
        }
    }

    deinit {
        continuation.finish()
        worker.cancel()
    }

    func enqueue(_ message: Message, database: SakuraCordDatabase?) {
        guard let database else { return }
        continuation.yield(.save(database, message))
    }
}

private struct PreparedCreatedMessage: Sendable {
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
    fileprivate let requestID: UUID
    var member: Member
    var profile: UserProfile?
    var isLoading: Bool
    var errorMessage: String?
}

private struct ProfileCacheKey: Hashable {
    let userID: UserID
    let guildID: GuildID?
}

private enum ProfilePresentationDestination {
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

@Observable
final class AppModel {
    private enum ThreadErrorScope {
        case initialPage
        case earlierPage
        case action
    }

    private struct CommandMemberQuery: Hashable {
        var guildID: GuildID
        var query: String
    }

    private struct MentionMemberSearchCacheEntry {
        var members: [Member]
        var storedAt: Date
    }

    private struct ReactionReactorLoadKey: Hashable {
        var channelID: ChannelID
        var messageID: MessageID
        var reactionID: String
    }

    private struct ReactionMutationKey: Hashable {
        var channelID: ChannelID
        var messageID: MessageID
        var reactionID: String
    }

    private struct ReactionMutationState {
        var emoji: String
        var confirmedReacted: Bool
        var desiredReacted: Bool
        var generation: UInt64
        var isSending: Bool
    }

    private static let messageSendLogger = Logger(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "MessageSend"
    )
    private static let unreadDiagnosticsLogger = Logger(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "Unread"
    )
    private static let forumPerformanceSignposter = OSSignposter(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "PointsOfInterest"
    )
    nonisolated static let maximumConcurrentReactionReactorLoads = 4
    nonisolated static let reactionMutationDebounce: Duration = .milliseconds(160)

    enum SessionState: Equatable {
        case restoring
        case signedOut
        case connecting
        case workspace
    }

    struct LocalTypingTiming: Sendable {
        var debounce: Duration = .seconds(1.5)
        var throttle: Duration = .seconds(8)
    }

    struct ReadAcknowledgementTiming: Sendable {
        var debounce: Duration = .seconds(1.5)
    }

    private struct ReadStateMutation: Sendable {
        var messageID: MessageID
        var manual: Bool
        var mentionCount: Int?
        var flags: UInt64
        var lastViewed: Int
    }

    private(set) var snapshot: BootstrapSnapshot?
    private(set) var serverRailGuildsByID: [GuildID: Guild] = [:]
    private(set) var serverRailItems: [GuildRailItem] = [] {
        didSet { updateOrderedCustomEmojis() }
    }
    private(set) var visibleChannels: [Channel] = []
    private(set) var selectedChannel: Channel?
    @ObservationIgnored private(set) var messages: [Message] = []
    @ObservationIgnored private(set) var messageRows: [MessageRowPresentation] = []
    @ObservationIgnored private(set) var messageRowsRevision: UInt64 = 0
    private(set) var timelinePresentationRevision: UInt64 = 0
    @ObservationIgnored private(set) var messageRowsUpdateHint:
        MessageRowsUpdateHint?
    @ObservationIgnored let messageRowsUpdateJournal =
        MessageRowsUpdateJournal()
    @ObservationIgnored let timelineSpoilerRevealStore =
        NativeTimelineSpoilerRevealStore()
    @ObservationIgnored private var latestMessageRowsRevision: UInt64 = 0
    @ObservationIgnored private var messageRowsNonAppendRevision: UInt64 = 0
    @ObservationIgnored private var selectedMessageIDs: Set<MessageID> = []
    @ObservationIgnored private var selectedMessageStoredIndexByID:
        [MessageID: Int] = [:]
    /// Stored indexes use a movable origin so prepending a history page does
    /// not rewrite every existing message's dictionary value. A logical array
    /// index is `stored - selectedMessageIndexOrigin`.
    @ObservationIgnored private var selectedMessageIndexOrigin = 0
    @ObservationIgnored private var selectedReplyMessageIDsByTarget:
        [MessageID: Set<MessageID>] = [:]
    private(set) var messageNavigationRequest: MessageNavigationRequest?
    private(set) var conversationNewestRequest: ConversationNewestRequest?
    private(set) var unreadDividerMessageIDs: [ChannelID: MessageID] = [:]
    private(set) var members: [Member] = [] {
        didSet {
            if oldValue != members {
                timelinePresentationRevision &+= 1
            }
            memberSections = MemberSection.make(from: members)
            let indexed = Dictionary(
                members.map { ($0.id, $0) },
                uniquingKeysWith: { _, newer in newer }
            )
            if membersByID != indexed {
                membersByID = indexed
            }
            if let guildID = selectedGuildID,
               let currentUserID = snapshot?.currentUser.id,
               let currentMember = indexed[currentUserID]
            {
                let roleIDs = Set(currentMember.roles.map(\.id))
                currentUserRoleIDsByGuild[guildID] = roleIDs
                readState.updateCurrentUserRoles(roleIDs, guildID: guildID)
            }
            refreshUnreadPresentation()
        }
    }

    private(set) var membersByID: [UserID: Member] = [:]
    private(set) var memberSections: [MemberSection] = []
    private(set) var guildRoles: [GuildRole] = [] {
        didSet {
            if oldValue != guildRoles {
                timelinePresentationRevision &+= 1
            }
            refreshUnreadPresentation()
        }
    }
    private(set) var commandMemberResults: [Member] = []
    private(set) var mentionMemberResults: [Member] = []
    private(set) var mentionAutocompleteMembers: [Member] = []
    private(set) var knownMentionMembers: [UserID: Member] = [:] {
        didSet {
            if oldValue != knownMentionMembers {
                timelinePresentationRevision &+= 1
            }
        }
    }
    private(set) var roleMemberResult: RoleMemberResult?
    private(set) var isLoadingRoleMembers = false
    private(set) var roleMemberErrorMessage: String?
    private(set) var currentStatus: PresenceStatus = .offline
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var isAuthenticated = false
    private(set) var sessionState: SessionState
    let launchMode: AppLaunchMode
    let typingState: TypingStateModel
    let commandComposer = ApplicationCommandComposerModel()
    let readState = AccountReadStateModel()
    let notificationPreferences: NotificationPreferences
    @ObservationIgnored private let notificationService: any NativeNotificationService
    @ObservationIgnored private let soundPlayer: any AppSoundPlaying
    private(set) var isLoading = false
    private(set) var isLoadingMessages = false
    private(set) var hasCompletedInitialMessageLoad = false
    private(set) var isLoadingEarlier = false
    private(set) var hasMoreMessages = false
    private(set) var messageLoadError: String?
    @ObservationIgnored private var messageLoadErrorIsEarlierPage = false
    private(set) var forumPosts: [ForumPost] = []
    private(set) var forumCataloguePosts: [ForumPost] = []
    private var forumCatalogueIndexByID: [ChannelID: Int] = [:]
    private(set) var forumRecentPostCount = 0
    var forumRecentPosts: ArraySlice<ForumPost> { forumPosts.prefix(forumRecentPostCount) }
    var forumOlderPosts: ArraySlice<ForumPost> { forumPosts.dropFirst(forumRecentPostCount) }
    private(set) var isLoadingForumPosts = false
    private(set) var isSearchingForumPosts = false
    private(set) var hasLoadedForumPosts = false
    private(set) var isLoadingMoreForumPosts = false
    private(set) var hasMoreForumPosts = false
    private(set) var forumPostError: String?
    private(set) var forumActionError: String?
    private(set) var forumPaginationError: String?
    private(set) var forumCreateProgress: MessageSendProgress?
    private var forumCreateGeneration: UInt64 = 0
    private(set) var forumSearchText = ""
    var forumSelectedTagIDs: Set<ForumTagID> = []
    var forumSortOrder: ForumSortOrder = .latestActivity
    var forumLayout: ForumLayout = .list
    var forumTagMatch: ForumTagMatch = .matchSome
    private(set) var replyingTo: Message?
    private(set) var presentedInteractionModal: InteractionModal?
    private(set) var interactionModalNonce: String?
    private(set) var interactionErrorMessage: String?
    private(set) var isVoiceChatOpen = false
    private(set) var openThread: MessageThreadSummary?
    private(set) var openThreadStarter: User?
    private(set) var openThreadStartedAt: Date?
    private(set) var threadMessages: [Message] = [] {
        didSet {
            let oldRows = threadMessageRows
            let newRows = MessageGrouping.updating(
                existing: threadMessageRows,
                oldMessages: oldValue,
                newMessages: threadMessages
            )
            let nextRevision = threadMessageRowsRevision &+ 1
            let record = MessageRowsUpdateRecordBuilder.make(
                oldRows: oldRows,
                newRows: newRows,
                revision: nextRevision
            )
            threadMessageRows = newRows
            threadMessageRowsUpdateHint = record.change.map {
                MessageRowsUpdateHint(
                    revision: nextRevision,
                    change: $0
                )
            }
            threadMessageRowsUpdateJournal.append(record)
            threadMessageRowsRevision = nextRevision
            NotificationCenter.default.post(
                name: .sakuracordMessageRowsDidChange,
                object: self
            )
        }
    }
    @ObservationIgnored private(set) var threadMessageRows:
        [MessageRowPresentation] = []
    @ObservationIgnored private(set) var threadMessageRowsUpdateHint:
        MessageRowsUpdateHint?
    @ObservationIgnored let threadMessageRowsUpdateJournal =
        MessageRowsUpdateJournal()
    @ObservationIgnored private(set) var threadMessageRowsRevision: UInt64 = 0
    private(set) var isLoadingThread = false
    private(set) var hasCompletedInitialThreadLoad = false
    private(set) var isLoadingEarlierThread = false
    private(set) var hasMoreThreadMessages = false
    private(set) var threadErrorMessage: String?
    @ObservationIgnored private var threadErrorScope: ThreadErrorScope?
    var canRetryThreadLoad: Bool {
        threadErrorScope == .initialPage
            || threadErrorScope == .earlierPage
    }
    private var outgoingDraftsByNonce: [String: SendMessageDraft] = [:]
    private(set) var gifResults: [GIFSearchResult] = []
    private(set) var isLoadingGIFs = false
    private(set) var gifErrorMessage: String?
    private(set) var stickersByGuild: [GuildID: [MessageSticker]] = [:]
    private(set) var supportedCapabilities: Set<ChatCapability> = []
    private(set) var pendingComponentControls: Set<ComponentControlKey> = []
    private(set) var componentErrors: [ComponentControlKey: String] = [:]
    private(set) var inspectorProfilePresentation:
        ProfilePresentationState?
    private(set) var contextualProfilePresentation:
        ProfilePresentationState?
    private(set) var isInspectorProfilePresented = false
    var selectedMember: Member? {
        inspectorProfilePresentation?.member
    }
    var selectedProfile: UserProfile? {
        inspectorProfilePresentation?.profile
    }
    var isLoadingProfile: Bool {
        inspectorProfilePresentation?.isLoading ?? false
    }
    var profileErrorMessage: String? {
        inspectorProfilePresentation?.errorMessage
    }
    private(set) var activeVoiceChannel: Channel?
    private(set) var voiceSessionState: VoiceSessionState = .idle
    private(set) var voiceParticipants: [VoiceRemoteParticipant] = []
    private(set) var isLocallySpeaking = false
    private(set) var voiceVideoFrames: [String: VoiceVideoFrame] = [:]
    private(set) var voiceEncryptionVersion: UInt16?
    private(set) var voiceLatencyMilliseconds: Int?
    private(set) var voiceErrorMessage: String?
    private(set) var voiceStates: [UserID: VoiceParticipantState] = [:]
    private(set) var privateCallsByChannel: [ChannelID: PrivateCall] = [:]
    private(set) var mediaDevices: MediaDeviceSnapshot = .empty
    private(set) var emojisByGuild: [GuildID: [DiscordEmoji]] = [:] {
        didSet { updateOrderedCustomEmojis() }
    }
    private(set) var loadingEmojiGuildIDs: Set<GuildID> = []
    private(set) var emojiLoadErrorsByGuild: [GuildID: String] = [:]
    private(set) var favoriteEmojiKeys: Set<String>
    private(set) var emojiUsageCounts: [String: Int]
    private(set) var discordFavoriteEmojiKeys: [String] = []
    private(set) var discordFrequentlyUsedEmojiKeys: [String] = []
    private(set) var discordEmojiUsageScores: [String: Int] = [:]
    private(set) var discordGuildAndChannelUsageScores: [String: Int] = [:]
    private(set) var hasLoadedDiscordEmojiSettings = false
    private(set) var orderedCustomEmojis: [DiscordEmoji] = []
    private(set) var customEmojiURLsByID: [String: URL] = [:]

    private func updateOrderedCustomEmojis() {
        let guildOrder = serverRailItems.flatMap { item -> [GuildID] in
            switch item {
            case .guild(let id): [id]
            case .folder(let folder): folder.guildIDs
            }
        }
        let value = DiscordCustomEmojiCatalog.ordered(
            emojisByGuild: emojisByGuild,
            guildOrder: guildOrder
        )
        if orderedCustomEmojis != value {
            orderedCustomEmojis = value
        }
        let imageURLsByID = DiscordCustomEmojiCatalog.imageURLsByID(from: value)
        if customEmojiURLsByID != imageURLsByID {
            customEmojiURLsByID = imageURLsByID
        }
    }
    var isVoiceMuted = UserDefaults.standard.bool(forKey: "voiceMuted")
    var isVoiceDeafened = UserDefaults.standard.bool(forKey: "voiceDeafened")
    var isCameraEnabled = false
    var inputVolume = Float(
        UserDefaults.standard.object(forKey: "voiceInputVolume") as? Double ?? 1)
    var outputVolume = Float(
        UserDefaults.standard.object(forKey: "voiceOutputVolume") as? Double ?? 1
    )
    var selectedGuildID: GuildID?
    var incomingPrivateCalls: [PrivateCall] {
        guard let currentUserID = snapshot?.currentUser.id else { return [] }
        return privateCallsByChannel.values
            .filter {
                !$0.isUnavailable
                    && $0.isRinging(currentUserID)
                    && activeVoiceChannel?.id != $0.channelID
            }
            .sorted { $0.channelID.rawValue < $1.channelID.rawValue }
    }

    func privateCall(in channelID: ChannelID) -> PrivateCall? {
        guard let call = privateCallsByChannel[channelID], !call.isUnavailable else {
            return nil
        }
        return call
    }
    var selectedConversationAccess: ConversationAccess {
        guard let channel = selectedChannel else { return .checking }
        return conversationAccess(for: channel)
    }

    var canCreateForumPosts: Bool {
        selectedConversationAccess.canSend && supportedCapabilities.contains(.forums)
    }

    var canManageForumPosts: Bool {
        guard let permissions = selectedEffectivePermissions else { return false }
        return permissions & DiscordPermissionBits.manageThreads != 0
    }

    func canDeleteForumPost(_ post: ForumPost) -> Bool {
        Self.canDeleteForumPost(
            ownerID: post.thread.ownerID ?? post.owner?.id,
            currentUserID: snapshot?.currentUser.id,
            canManage: canManageForumPosts
        )
    }

    func canArchiveForumPost(_ post: ForumPost) -> Bool {
        if canManageForumPosts { return true }
        guard !post.thread.isLocked else { return false }
        let ownerID = post.thread.ownerID ?? post.owner?.id
        return ownerID != nil && ownerID == snapshot?.currentUser.id
    }

    func canEditForumPostTags(_ post: ForumPost) -> Bool {
        if canManageForumPosts { return true }
        guard !post.thread.isLocked else { return false }
        let ownerID = post.thread.ownerID ?? post.owner?.id
        return ownerID != nil && ownerID == snapshot?.currentUser.id
    }

    func canToggleForumTag(_ tag: ForumTag, on post: ForumPost) -> Bool {
        guard canEditForumPostTags(post), canManageForumPosts || !tag.isModerated else {
            return false
        }
        if selectedChannel?.requiresForumTag == true,
           post.thread.appliedTagIDs.count == 1,
           post.thread.appliedTagIDs.contains(tag.id)
        {
            return false
        }
        return true
    }

    nonisolated static func canDeleteForumPost(
        ownerID: UserID?,
        currentUserID: UserID?,
        canManage: Bool
    ) -> Bool {
        canManage || (ownerID != nil && ownerID == currentUserID)
    }

    func currentUserRoleIDs(for guildID: GuildID?) -> Set<RoleID> {
        guard let guildID else { return [] }
        return currentUserRoleIDsByGuild[guildID] ?? []
    }

    private var selectedEffectivePermissions: UInt64? {
        guard let channel = selectedChannel else { return nil }
        guard let guildID = channel.guildID else { return .max }
        guard let guild = serverRailGuildsByID[guildID],
              let currentUserID = snapshot?.currentUser.id
        else {
            return nil
        }
        return ConversationPermissionResolver.effectivePermissions(
            guild: guild,
            channel: channel,
            currentUserID: currentUserID,
            currentMember: membersByID[currentUserID],
            roles: guildRoles,
            currentRoleIDs: currentUserRoleIDsByGuild[guildID]
        )
    }

    func conversationAccess(for channel: Channel) -> ConversationAccess {
        guard let guildID = channel.guildID else {
            return .readable(canSend: !channel.isOfficialSystemDirectMessage)
        }
        guard let guild = serverRailGuildsByID[guildID],
              let currentUserID = snapshot?.currentUser.id
        else {
            return .checking
        }
        let member = membersByID[currentUserID]
        let permissions = ConversationPermissionResolver.effectivePermissions(
            guild: guild,
            channel: channel,
            currentUserID: currentUserID,
            currentMember: member,
            roles: guildID == selectedGuildID ? guildRoles : [],
            currentRoleIDs: currentUserRoleIDsByGuild[guildID]
        )
        if channel.kind == .voice {
            return ConversationPermissionResolver.voiceChannelAccess(
                effectivePermissions: permissions
            )
        }
        return ConversationPermissionResolver.channelAccess(effectivePermissions: permissions)
    }

    var openThreadAccess: ConversationAccess {
        guard let thread = openThread, let channel = selectedChannel else { return .checking }
        guard let guildID = channel.guildID else { return .readable(canSend: true) }
        guard let guild = serverRailGuildsByID[guildID],
              let currentUserID = snapshot?.currentUser.id
        else {
            return .checking
        }
        let member = membersByID[currentUserID]
        let permissions = ConversationPermissionResolver.effectivePermissions(
            guild: guild,
            channel: channel,
            currentUserID: currentUserID,
            currentMember: member,
            roles: guildRoles,
            currentRoleIDs: currentUserRoleIDsByGuild[guildID]
        )
        return ConversationPermissionResolver.threadAccess(
            effectivePermissions: permissions,
            isLocked: thread.isLocked
        )
    }
    var selectedChannelID: ChannelID? {
        didSet {
            guard selectedChannelID != oldValue else { return }
            dismissInspectorProfile()
            if let oldValue {
                unreadDividerMessageIDs[oldValue] = nil
                if conversationNewestRequest?.channelID == oldValue {
                    conversationNewestRequest = nil
                }
                messageCache[oldValue] = messages
                lastTypingRequestAt[oldValue] = nil
                _ = readState.updatePresentation(channelID: oldValue, isPresented: false)
                readState.endForumVisit(channelID: oldValue)
            }
            selectedChannel =
                snapshot?.channels.first { $0.id == selectedChannelID }
                    ?? visibleChannels.first { $0.id == selectedChannelID }
            commandLoadTask?.cancel()
            commandAutocompleteTask?.cancel()
            cancelApplicationCommandMemberSearch()
            commandExecutionTask?.cancel()
            commandComposer.resetForChannelChange()
            channelComposerAttachments = []
            isVoiceChatOpen = selectedChannel?.kind == .voice
            closeThread()
            if let selectedChannelID {
                _ = readState.updatePresentation(
                    channelID: selectedChannelID,
                    isPresented: true,
                    initialHistoryLoaded: false,
                    initialPositionEstablished: false,
                    windowIsActive: mainWindowIsActive,
                    isAtNewest: false,
                    blocksAutomaticAcknowledgement: false
                )
            }
            if selectedChannel?.kind == .forum {
                if let selectedChannelID {
                    readState.beginForumVisit(channelID: selectedChannelID)
                }
                beginForumLoad()
            } else {
                beginSelectedChannelLoad()
            }
            if let channel = selectedChannel,
               channel.kind == .directMessage || channel.kind == .groupDirectMessage
            {
                Task { [weak self] in
                    await self?.observePrivateCall(in: channel)
                }
            }
        }
    }

    var draft = ""
    var threadDraft = ""
    private(set) var channelComposerAttachments: [ForumPostAttachment] = []
    private(set) var threadComposerAttachments: [ForumPostAttachment] = []
    var showInspector = true
    var errorMessage: String?

    @ObservationIgnored private var provider: any ChatProvider
    @ObservationIgnored private var database: SakuraCordDatabase?
    @ObservationIgnored private let messagePersistenceSink = MessagePersistenceSink()
    @ObservationIgnored private let runsChatPerformanceBenchmark =
        AppLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
        .runsChatPerformanceAutoScroll
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var locallyStartedOutgoingPrivateCallRings:
        Set<ChannelID> = []
    @ObservationIgnored private var outgoingPrivateCallRingTimeoutTasks:
        [ChannelID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingCreatedMessages:
        [PreparedCreatedMessage] = []
    @ObservationIgnored private var createdMessageFlushTask: Task<Void, Never>?
    @ObservationIgnored private var isFlushingCreatedMessageBatch = false
    @ObservationIgnored private var batchedSelectedMessages: [Message] = []
    @ObservationIgnored private var batchedSelectedTextPlansByID:
        [MessageID: NativeTimelineTextPlan] = [:]
    @ObservationIgnored private var batchedUnreadPresentationNeedsRefresh =
        false
    @ObservationIgnored private var unreadPresentationRefreshTask:
        Task<Void, Never>?
    @ObservationIgnored private var batchedAcknowledgementChannelIDs:
        Set<ChannelID> = []
    @ObservationIgnored private let maximumCreatedMessagesPerFlush = 4
    @ObservationIgnored private var localTypingTask: Task<Void, Never>?
    @ObservationIgnored private var localTypingChannelID: ChannelID?
    @ObservationIgnored private var lastTypingRequestAt: [ChannelID: Date] = [:]
    @ObservationIgnored private var localTypingGeneration: UInt64 = 0
    @ObservationIgnored private let localTypingTiming: LocalTypingTiming
    @ObservationIgnored private var inspectorProfileTask:
        Task<Void, Never>?
    @ObservationIgnored private var contextualProfileTask:
        Task<Void, Never>?
    @ObservationIgnored private var profileCache:
        [ProfileCacheKey: UserProfile] = [:]
    @ObservationIgnored private var channelLoadTask: Task<Void, Never>?
    @ObservationIgnored private var forumLoadTask: Task<Void, Never>?
    @ObservationIgnored private var forumNextOffset: Int?
    @ObservationIgnored private var forumLoadGeneration: UInt64 = 0
    @ObservationIgnored private var threadLoadTask: Task<Void, Never>?
    @ObservationIgnored private var gifSearchTask: Task<Void, Never>?
    @ObservationIgnored private var commandLoadTask: Task<Void, Never>?
    @ObservationIgnored private var commandAutocompleteTask: Task<Void, Never>?
    @ObservationIgnored private var commandMemberSearchTask: Task<Void, Never>?
    @ObservationIgnored private var commandMemberSearchQuery: CommandMemberQuery?
    @ObservationIgnored private var commandMemberSearchCache: [CommandMemberQuery: [Member]] = [:]
    @ObservationIgnored private var mentionMemberSearchTask: Task<Void, Never>?
    @ObservationIgnored private var mentionMemberSearchQuery: CommandMemberQuery?
    @ObservationIgnored private var mentionMemberSearchCache:
        [CommandMemberQuery: MentionMemberSearchCacheEntry] = [:]
    @ObservationIgnored private var roleMemberTask: Task<Void, Never>?
    @ObservationIgnored private var commandExecutionTask: Task<Void, Never>?
    @ObservationIgnored private var stickerLoadTasks: [GuildID: Task<Void, Never>] = [:]
    @ObservationIgnored private var componentKeyByNonce: [String: ComponentControlKey] = [:]
    @ObservationIgnored private var loadingReactionReactors: Set<ReactionReactorLoadKey> = []
    @ObservationIgnored private var failedReactionReactorLoads: [ReactionReactorLoadKey: Date] = [:]
    @ObservationIgnored private var liveScrollingConversationIDs:
        Set<ChannelID> = []
    @ObservationIgnored private let reactionReactorLoadLimiter = ReactionReactorLoadLimiter(
        maximumConcurrentLoads: maximumConcurrentReactionReactorLoads
    )
    @ObservationIgnored private var reactionMutations:
        [ReactionMutationKey: ReactionMutationState] = [:]
    @ObservationIgnored private var reactionMutationTasks:
        [ReactionMutationKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var guildActivationTask: Task<Void, Never>?
    @ObservationIgnored private var memberLoadTask: Task<Void, Never>?
    @ObservationIgnored private var voiceEventTask: Task<Void, Never>?
    @ObservationIgnored private var voiceMigrationTask: Task<Void, Never>?
    @ObservationIgnored private var voiceSession: DiscordVoiceSession?
    @ObservationIgnored private var voiceMigrationGeneration = 0
    @ObservationIgnored private var channelLoadGeneration = 0
    @ObservationIgnored private var messageNavigationRequestID: UInt64 = 0
    @ObservationIgnored private var conversationNewestRequestID: UInt64 = 0
    @ObservationIgnored private var messageCache: [ChannelID: [Message]] = [:]
    @ObservationIgnored private var hasMoreCache: [ChannelID: Bool] = [:]
    @ObservationIgnored private let discordNetworkDisabled: Bool
    @ObservationIgnored private let restoresStoredSession: Bool
    @ObservationIgnored private let credentialStore: any CredentialStore
    @ObservationIgnored private let authenticatedProviderFactory:
        (CredentialHandle, String?) -> any ChatProvider
    @ObservationIgnored private let persistsEmojiPreferences: Bool
    @ObservationIgnored private var didAttemptSessionRestore = false
    @ObservationIgnored private var credentialHandle: CredentialHandle?
    @ObservationIgnored private var didAttemptDiscordEmojiSettings = false
    @ObservationIgnored private var acknowledgementTasks: [ChannelID: Task<Void, Never>] = [:]
    @ObservationIgnored private var queuedAcknowledgements: [ChannelID: ReadStateMutation] = [:]
    @ObservationIgnored private var acknowledgementQueueOrder: [ChannelID] = []
    @ObservationIgnored private var acknowledgementProcessorTask: Task<Void, Never>?
    @ObservationIgnored private var acknowledgementGeneration = 0
    @ObservationIgnored private var mainWindowIsActive = false
    @ObservationIgnored private var currentUserRoleIDsByGuild: [GuildID: Set<RoleID>] = [:]
    @ObservationIgnored private let readAcknowledgementTiming: ReadAcknowledgementTiming

    init(
        launchMode: AppLaunchMode,
        provider: (any ChatProvider)? = nil,
        discordNetworkDisabledOverride: Bool? = nil,
        restoresStoredSession: Bool = true,
        credentialStore: (any CredentialStore)? = nil,
        authenticatedProviderFactory: ((CredentialHandle, String?) -> any ChatProvider)? = nil,
        notificationService: (any NativeNotificationService)? = nil,
        soundPlayer: (any AppSoundPlaying)? = nil,
        notificationPreferences: NotificationPreferences? = nil,
        typingExpiry: Duration = .seconds(10),
        localTypingTiming: LocalTypingTiming = LocalTypingTiming(),
        readAcknowledgementTiming: ReadAcknowledgementTiming = ReadAcknowledgementTiming()
    ) {
        self.launchMode = launchMode
        self.notificationService =
            notificationService ?? NoopNativeNotificationService()
        self.soundPlayer = soundPlayer ?? NoopAppSoundPlayer()
        self.notificationPreferences = notificationPreferences ?? NotificationPreferences()
        self.provider =
            provider
                ?? (launchMode == .offlineTesting ? MockChatProvider() : SignedOutChatProvider())
        sessionState = launchMode == .offlineTesting ? .connecting : .restoring
        typingState = TypingStateModel(expiry: typingExpiry)
        self.localTypingTiming = localTypingTiming
        self.readAcknowledgementTiming = readAcknowledgementTiming
        discordNetworkDisabled =
            discordNetworkDisabledOverride
                ?? (launchMode == .offlineTesting
                    || ProcessInfo.processInfo.environment["SAKURACORD_DISABLE_DISCORD_NETWORK"] == "1")
        self.restoresStoredSession = restoresStoredSession
        let resolvedCredentialStore: any CredentialStore =
            credentialStore
                ?? (launchMode == .offlineTesting
                    ? OfflineCredentialStore()
                    : KeychainCredentialStore())
        self.credentialStore = resolvedCredentialStore
        self.authenticatedProviderFactory =
            authenticatedProviderFactory ?? { handle, fingerprint in
                DiscordRESTProvider(
                    credentials: resolvedCredentialStore,
                    handle: handle,
                    fingerprint: fingerprint
                )
            }
        persistsEmojiPreferences = launchMode == .normal
        favoriteEmojiKeys =
            launchMode == .normal
                ? Set(UserDefaults.standard.stringArray(forKey: "dev.sakuracord.favorite-emojis") ?? [])
                : []
        emojiUsageCounts =
            launchMode == .normal
                ? UserDefaults.standard.dictionary(forKey: "dev.sakuracord.emoji-usage")
                as? [String: Int]
                ?? [:]
                : [:]
        database =
            launchMode == .normal
                ? try? SakuraCordDatabase(accountID: AccountID(rawValue: 1))
                : try? SakuraCordDatabase(inMemory: true)
        commandComposer.configureFrecencyScope(
            launchMode == .offlineTesting ? "offline" : "signed-out"
        )
        readState.reset(accountID: launchMode == .offlineTesting ? "offline" : nil)
    }

    var isOfflineTesting: Bool {
        launchMode == .offlineTesting
    }

    var isDiscordNetworkingDisabled: Bool {
        discordNetworkDisabled
    }

    func connectAuthenticatedAccount(
        _ handle: CredentialHandle,
        preservesInteractivePresentation: Bool = false
    ) async -> Bool {
        guard !discordNetworkDisabled else {
            errorMessage = "Discord networking is disabled in offline UI mode."
            return false
        }
        await leaveVoice()
        resetAppSounds()
        await provider.disconnect()
        eventTask?.cancel()
        resetPendingCreatedMessages()
        resetTimelineLiveScrolling()
        clearReactionMutationState()
        stopLocalTyping(clearThrottle: true)
        typingState.clearAll()
        if !preservesInteractivePresentation {
            sessionState = .connecting
        }
        let fingerprint = await UserDefaultsDiscordFingerprintStore.shared.load()
        provider = authenticatedProviderFactory(handle, fingerprint)
        resetAcknowledgementWork()
        readState.reset(accountID: handle.accountID)
        currentUserRoleIDsByGuild = [:]
        supportedCapabilities = []
        pendingComponentControls = []
        componentErrors = [:]
        componentKeyByNonce = [:]
        credentialHandle = handle
        commandComposer.configureFrecencyScope(handle.accountID)
        database = AccountID(handle.accountID).flatMap { try? SakuraCordDatabase(accountID: $0) }
        snapshot = nil
        serverRailGuildsByID = [:]
        serverRailItems = []
        emojisByGuild = [:]
        loadingEmojiGuildIDs = []
        emojiLoadErrorsByGuild = [:]
        discordFavoriteEmojiKeys = []
        discordFrequentlyUsedEmojiKeys = []
        discordEmojiUsageScores = [:]
        discordGuildAndChannelUsageScores = [:]
        hasLoadedDiscordEmojiSettings = false
        didAttemptDiscordEmojiSettings = false
        voiceStates = [:]
        privateCallsByChannel = [:]
        visibleChannels = []
        selectedChannel = nil
        selectedGuildID = nil
        selectedChannelID = nil
        replaceSelectedMessages(with: [])
        hasCompletedInitialMessageLoad = false
        hasCompletedInitialThreadLoad = false
        messageCache = [:]
        hasMoreCache = [:]
        dismissAllProfiles(clearsCache: true)
        errorMessage = nil
        await start(publishesSessionState: !preservesInteractivePresentation)
        isAuthenticated = snapshot != nil
        sessionState = isAuthenticated ? .workspace : .signedOut
        if isAuthenticated {
            await requestNotificationPermissionIfNeeded()
        }
        return isAuthenticated
    }

    func logout() async {
        await leaveVoice()
        resetAppSounds()
        await provider.disconnect()
        eventTask?.cancel()
        resetPendingCreatedMessages()
        resetTimelineLiveScrolling()
        clearReactionMutationState()
        stopLocalTyping(clearThrottle: true)
        typingState.clearAll()
        if let credentialHandle {
            do {
                try await credentialStore.remove(credentialHandle)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        credentialHandle = nil
        resetAcknowledgementWork()
        readState.reset(accountID: launchMode == .offlineTesting ? "offline" : nil)
        currentUserRoleIDsByGuild = [:]
        commandComposer.configureFrecencyScope(
            launchMode == .offlineTesting ? "offline" : "signed-out"
        )
        provider = launchMode == .offlineTesting ? MockChatProvider() : SignedOutChatProvider()
        supportedCapabilities = []
        pendingComponentControls = []
        componentErrors = [:]
        componentKeyByNonce = [:]
        database =
            launchMode == .offlineTesting
                ? try? SakuraCordDatabase(inMemory: true)
                : try? SakuraCordDatabase(accountID: AccountID(rawValue: 1))
        snapshot = nil
        serverRailGuildsByID = [:]
        serverRailItems = []
        emojisByGuild = [:]
        loadingEmojiGuildIDs = []
        emojiLoadErrorsByGuild = [:]
        discordFavoriteEmojiKeys = []
        discordFrequentlyUsedEmojiKeys = []
        discordEmojiUsageScores = [:]
        discordGuildAndChannelUsageScores = [:]
        hasLoadedDiscordEmojiSettings = false
        didAttemptDiscordEmojiSettings = false
        voiceStates = [:]
        visibleChannels = []
        selectedChannel = nil
        selectedGuildID = nil
        selectedChannelID = nil
        replaceSelectedMessages(with: [])
        hasCompletedInitialMessageLoad = false
        hasCompletedInitialThreadLoad = false
        messageCache = [:]
        hasMoreCache = [:]
        members = []
        dismissAllProfiles(clearsCache: true)
        connectionState = .disconnected
        isAuthenticated = false
        didAttemptSessionRestore = true
        sessionState = launchMode == .offlineTesting ? .connecting : .signedOut
        if launchMode == .offlineTesting {
            await start()
        }
    }

    func start(publishesSessionState: Bool = true) async {
        guard snapshot == nil else { return }
        if launchMode == .normal, discordNetworkDisabled {
            didAttemptSessionRestore = true
            isLoading = false
            sessionState = .signedOut
            return
        }
        if launchMode == .normal, !didAttemptSessionRestore {
            didAttemptSessionRestore = true
            if restoresStoredSession,
               let handles = try? await credentialStore.handles(),
               let handle = handles.first
            {
                _ = await connectAuthenticatedAccount(handle)
                return
            }
        }
        if launchMode == .normal, credentialHandle == nil {
            isLoading = false
            sessionState = .signedOut
            return
        }
        if publishesSessionState {
            sessionState = .connecting
        }
        await refreshSupportedCapabilities()
        let stream = await provider.eventStream()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.consume(event)
            }
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let value = try await provider.bootstrap()
            snapshot = value
            reconcilePrivateCallSounds()
            readState.configure(
                accountID: credentialHandle?.accountID ?? (launchMode == .offlineTesting ? "offline" : nil),
                guilds: value.guilds,
                channels: value.channels,
                readStates: value.readStates,
                notificationSettings: value.notificationSettings,
                usesNewNotifications: value.usesNewNotifications
            )
            for thread in value.threads {
                readState.merge(thread: thread)
            }
            readState.setCurrentUserID(value.currentUser.id)
            let derivedUnreadGuildCount = value.guilds.count {
                readState.guildUnread($0.id)
            }
            let firstGuildHasNotificationSettings = value.guilds.first.map { guild in
                value.notificationSettings.contains { $0.guildID == guild.id }
            } ?? false
            let firstGuildSettings = value.guilds.first.flatMap { guild in
                value.notificationSettings.last { $0.guildID == guild.id }
            }
            let firstGuildMuteIsActive =
                firstGuildSettings?.isMuted == true
                && (firstGuildSettings?.muteConfiguration?.isActive() ?? true)
            let firstGuildMutedOverrideCount =
                firstGuildSettings?.channelOverrides.count { override in
                    override.isMuted
                        && (override.muteConfiguration?.isActive() ?? true)
                } ?? 0
            Self.unreadDiagnosticsLogger.info(
                """
                Bootstrap unread model configured; readStates=\(value.readStates.count), \
                guildSettings=\(value.notificationSettings.count), \
                newNotifications=\(value.usesNewNotifications), \
                guilds=\(value.guilds.count), \
                firstGuildHasSettings=\(firstGuildHasNotificationSettings), \
                firstGuildMuted=\(firstGuildMuteIsActive), \
                firstGuildMutedOverrides=\(firstGuildMutedOverrideCount), \
                derivedUnreadGuilds=\(derivedUnreadGuildCount)
                """
            )
            if let firstGuildID = value.guilds.first?.id,
               let currentMember = value.members.first(where: { $0.id == value.currentUser.id })
            {
                let roleIDs = Set(currentMember.roles.map(\.id))
                currentUserRoleIDsByGuild[firstGuildID] = roleIDs
                readState.updateCurrentUserRoles(roleIDs, guildID: firstGuildID)
            }
            updateServerRail(from: value)
            refreshUnreadPresentation()
            if credentialHandle != nil {
                isAuthenticated = true
            }
            members = value.members
            currentStatus = await provider.currentStatus()
            await activateGuild(value.guilds.first?.id)
            await channelLoadTask?.value
            if publishesSessionState {
                sessionState = .workspace
            }
        } catch {
            errorMessage = error.localizedDescription
            if launchMode == .normal {
                isAuthenticated = false
                if publishesSessionState {
                    sessionState = .signedOut
                }
            }
        }
    }

    private func refreshSupportedCapabilities() async {
        var values: Set<ChatCapability> = []
        for capability in ChatCapability.allCases where await provider.supports(capability) {
            values.insert(capability)
        }
        supportedCapabilities = values
    }

    func selectGuild(_ guildID: GuildID?) {
        guildActivationTask?.cancel()
        guildActivationTask = Task { [weak self] in
            await self?.activateGuild(guildID)
        }
    }

    var directMessageInspectorSections: [MemberSection] {
        guard let channel = selectedChannel, channel.guildID == nil else {
            return memberSections
        }
        return MemberSection.make(
            from: DirectMessageMemberResolver.members(
                for: channel,
                knownMembers: members,
                currentUser: snapshot?.currentUser,
                currentStatus: currentStatus
            )
        )
    }

    func navigate(to channelID: ChannelID) {
        guard
            let channel = snapshot?.channels.first(where: { $0.id == channelID })
            ?? visibleChannels.first(where: { $0.id == channelID })
        else {
            errorMessage = "That mentioned channel has not been discovered yet."
            return
        }
        guildActivationTask?.cancel()
        guildActivationTask = Task { [weak self] in
            guard let self else { return }
            if selectedGuildID != channel.guildID {
                await activateGuild(channel.guildID)
            }
            guard !Task.isCancelled else { return }
            selectedChannelID = channel.id
        }
    }

    func navigate(to guildID: GuildID?, linkedChannelID channelID: ChannelID) {
        if snapshot?.channels.contains(where: { $0.id == channelID }) == true
            || visibleChannels.contains(where: { $0.id == channelID })
        {
            navigate(to: channelID)
            return
        }

        guildActivationTask?.cancel()
        guildActivationTask = Task { [weak self] in
            guard let self else { return }
            let knownPost =
                forumCataloguePosts.first(where: { $0.id == channelID })
                    ?? forumPosts.first(where: { $0.id == channelID })
            if selectedGuildID != guildID {
                await activateGuild(guildID)
            }
            guard !Task.isCancelled else { return }
            if let channel =
                snapshot?.channels.first(where: { $0.id == channelID })
                    ?? visibleChannels.first(where: { $0.id == channelID })
            {
                selectedChannelID = channel.id
                return
            }

            let post: ForumPost
            do {
                post = if let knownPost {
                    knownPost
                } else {
                    try await provider.forumPost(threadID: channelID)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                return
            }

            let targetGuildID = post.thread.guildID ?? guildID
            if selectedGuildID != targetGuildID {
                await activateGuild(targetGuildID)
            }
            guard !Task.isCancelled else { return }
            guard let parentID = post.thread.parentID,
                  let parent =
                  snapshot?.channels.first(where: { $0.id == parentID })
                      ?? visibleChannels.first(where: { $0.id == parentID })
            else {
                errorMessage = "That thread's parent channel has not been discovered yet."
                return
            }
            if selectedChannelID != parent.id {
                selectedChannelID = parent.id
            }
            await channelLoadTask?.value
            guard !Task.isCancelled, selectedChannelID == parent.id else { return }
            if parent.kind == .forum {
                mergeForumCatalogue([post])
                applyForumPresentation()
            }
            open(post)
        }
    }

    func navigate(to guildID: GuildID?, channelID: ChannelID, messageID: MessageID) {
        guildActivationTask?.cancel()
        guildActivationTask = Task { [weak self] in
            guard let self else { return }
            if selectedGuildID != guildID {
                await activateGuild(guildID)
            }
            guard !Task.isCancelled else { return }
            guard
                let channel = snapshot?.channels.first(where: { $0.id == channelID })
                ?? visibleChannels.first(where: { $0.id == channelID })
            else {
                errorMessage = "That message's channel has not been discovered yet."
                return
            }
            if selectedChannelID != channel.id {
                selectedChannelID = channel.id
            }
            await channelLoadTask?.value
            guard !Task.isCancelled, selectedChannelID == channel.id else { return }

            if !messages.contains(where: { $0.id == messageID }) {
                do {
                    let beforeID =
                        messageID.rawValue == UInt64.max
                            ? nil
                            : MessageID(rawValue: messageID.rawValue + 1)
                    let page = try await provider.messages(
                        in: channel.id,
                        before: beforeID,
                        limit: 50
                    )
                    guard !Task.isCancelled, selectedChannelID == channel.id else { return }
                    replaceSelectedMessages(
                        with: Self.merging(current: messages, fresh: page.messages)
                    )
                    try await database?.save(messages: page.messages)
                } catch is CancellationError {
                    return
                } catch {
                    guard selectedChannelID == channel.id else { return }
                    errorMessage = error.localizedDescription
                    return
                }
            }

            guard messages.contains(where: { $0.id == messageID }) else {
                errorMessage = "That message could not be found in the linked channel."
                return
            }
            messageNavigationRequestID &+= 1
            messageNavigationRequest = MessageNavigationRequest(
                requestID: messageNavigationRequestID,
                channelID: channel.id,
                messageID: messageID
            )
        }
    }

    func navigate(from notification: NotificationDeepLink) async {
        if readState.accountID != notification.accountID {
            let handles = try? await credentialStore.handles()
            guard let handle = handles?.first(where: { $0.accountID == notification.accountID }) else {
                errorMessage = "The account for this notification is no longer available."
                return
            }
            guard await connectAuthenticatedAccount(handle) else { return }
        }
        navigate(
            to: notification.guildID,
            channelID: notification.channelID,
            messageID: notification.messageID
        )
    }

    func completeMessageNavigation(requestID: UInt64) {
        guard messageNavigationRequest?.requestID == requestID else { return }
        messageNavigationRequest = nil
    }

    func completeConversationNewestRequest(requestID: UInt64) {
        guard conversationNewestRequest?.requestID == requestID else { return }
        conversationNewestRequest = nil
    }

    private func activateGuild(_ guildID: GuildID?) async {
        dismissAllProfiles()
        selectedGuildID = guildID
        guildRoles = []
        mentionAutocompleteMembers = []
        var channels =
            snapshot?.channels.filter { channel in
                guildID == nil ? channel.guildID == nil : channel.guildID == guildID
            } ?? []
        visibleChannels = channels
        if channels.isEmpty {
            do {
                channels = try await provider.channels(in: guildID)
                if var value = snapshot {
                    value.channels.removeAll { $0.guildID == guildID }
                    value.channels.append(contentsOf: channels)
                    snapshot = value
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        guard !Task.isCancelled, selectedGuildID == guildID else { return }
        visibleChannels = channels
        if launchMode == .offlineTesting, let guildID {
            await loadEmojis(for: guildID)
        }
        if !visibleChannels.contains(where: { $0.id == selectedChannelID }) {
            let selectableChannels = visibleChannels.filter {
                conversationAccess(for: $0) != .hidden
            }
            selectedChannelID = Self.preferredInitialChannelID(in: selectableChannels)
        }
        beginMemberLoad(for: guildID)
    }

    nonisolated static func preferredInitialChannelID(in channels: [Channel]) -> ChannelID? {
        let textChannels = channels.filter { channel in
            switch channel.kind {
            case .text, .announcement, .forum, .directMessage, .groupDirectMessage:
                true
            case .voice, .unknown:
                false
            }
        }
        return textChannels.first(where: { $0.name == "general" })?.id
            ?? textChannels.first?.id
            ?? channels.first(where: { $0.name == "general" })?.id
            ?? channels.first?.id
    }

    func loadEmojis(for guildID: GuildID) async {
        guard emojisByGuild[guildID] == nil, !loadingEmojiGuildIDs.contains(guildID) else { return }
        loadingEmojiGuildIDs.insert(guildID)
        defer { loadingEmojiGuildIDs.remove(guildID) }
        do {
            let emojis = try await provider.emojis(in: guildID)
            applyEmojis(emojis, to: guildID)
        } catch {
            emojiLoadErrorsByGuild[guildID] = error.localizedDescription
        }
    }

    private func applyEmojis(_ emojis: [DiscordEmoji], to guildID: GuildID) {
        emojisByGuild[guildID] = emojis
        for emoji in emojis {
            ComposerEmojiImageStore.shared.register(emoji)
        }
        emojiLoadErrorsByGuild[guildID] = nil
    }

    private func applyEmojiUpdate(
        upserted: [DiscordEmoji],
        deletedIDs: [String],
        to guildID: GuildID
    ) {
        guard let existing = emojisByGuild[guildID] else {
            // Discord can send a delta when its official client has a cached base.
            // SakuraCord deliberately leaves this guild unresolved so the existing
            // coalesced REST fallback can obtain a complete catalog.
            return
        }
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for id in deletedIDs {
            byID[id] = nil
        }
        for emoji in upserted {
            byID[emoji.id] = emoji
        }
        applyEmojis(
            byID.values.sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            },
            to: guildID
        )
    }

    func retryEmojis(for guildID: GuildID) async {
        emojisByGuild[guildID] = nil
        emojiLoadErrorsByGuild[guildID] = nil
        await loadEmojis(for: guildID)
    }

    func loadDiscordEmojiSettings() async {
        guard !didAttemptDiscordEmojiSettings else { return }
        didAttemptDiscordEmojiSettings = true
        guard let settings = try? await provider.emojiUserSettings() else { return }
        discordFavoriteEmojiKeys = settings.favoriteKeys
        discordFrequentlyUsedEmojiKeys = settings.frequentlyUsedKeys
        discordEmojiUsageScores = settings.usageScores
        discordGuildAndChannelUsageScores = settings.guildAndChannelUsageScores
        hasLoadedDiscordEmojiSettings = true
    }

    func recordEmojiUse(_ key: String) {
        emojiUsageCounts[key, default: 0] += 1
        if persistsEmojiPreferences {
            UserDefaults.standard.set(emojiUsageCounts, forKey: "dev.sakuracord.emoji-usage")
        }
    }

    func toggleFavoriteEmoji(_ key: String) {
        if favoriteEmojiKeys.contains(key) {
            favoriteEmojiKeys.remove(key)
        } else {
            favoriteEmojiKeys.insert(key)
        }
        if persistsEmojiPreferences {
            UserDefaults.standard.set(
                Array(favoriteEmojiKeys), forKey: "dev.sakuracord.favorite-emojis")
        }
    }

    func composerText(for emoji: DiscordEmoji) -> String {
        DiscordEmojiPermissionPolicy.composerText(
            for: emoji,
            currentGuildID: selectedGuildID,
            premiumType: snapshot?.currentUser.premiumType ?? 0
        )
    }

    private func beginMemberLoad(for guildID: GuildID?) {
        memberLoadTask?.cancel()
        memberLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await provider.members(in: guildID)
                guard !Task.isCancelled, selectedGuildID == guildID else { return }
                members = value
                // Keep the pre-subscription GuildMemberStore snapshot for
                // composer search. Full member-list subscriptions feed the
                // inspector, but Discord does not use their visual list order
                // as autocomplete's candidate store.
                mentionAutocompleteMembers = value
                if let guildID {
                    guildRoles = (try? await provider.roles(in: guildID)) ?? []
                } else {
                    guildRoles = []
                }
            } catch {
                guard !Task.isCancelled, selectedGuildID == guildID else { return }
                members =
                    snapshot.map {
                        [Member(user: $0.currentUser, roleName: "You", status: currentStatus)]
                    }
                    ?? []
                guildRoles = []
            }
        }
    }

    private func beginForumLoad() {
        channelLoadTask?.cancel()
        forumLoadTask?.cancel()
        replaceSelectedMessages(with: [])
        draft = ""
        messageLoadError = nil
        isLoadingMessages = false
        forumPosts = []
        forumCataloguePosts = []
        forumCatalogueIndexByID = [:]
        forumRecentPostCount = 0
        forumNextOffset = nil
        forumPostError = nil
        forumActionError = nil
        forumPaginationError = nil
        isLoadingForumPosts = false
        isSearchingForumPosts = false
        isLoadingMoreForumPosts = false
        hasLoadedForumPosts = false
        hasMoreForumPosts = false
        forumSearchText = ""
        forumSelectedTagIDs = []
        if let channel = selectedChannel {
            forumSortOrder = channel.defaultSortOrder ?? .latestActivity
            forumLayout =
                channel.defaultForumLayout == .defaultLayout ? .list : channel.defaultForumLayout
            forumTagMatch = channel.defaultTagMatch
        }
        forumLoadTask = Task { [weak self] in
            await self?.loadForumPosts(reset: true)
        }
    }

    func reloadForumPosts() {
        guard selectedChannel?.kind == .forum else { return }
        forumLoadTask?.cancel()
        forumLoadTask = Task { [weak self] in
            await self?.loadForumPosts(reset: true)
        }
    }

    func loadMoreForumPosts() async {
        guard hasMoreForumPosts, !isLoadingMoreForumPosts else { return }
        await loadForumPosts(reset: false)
    }

    func updateForumSearch(_ text: String) {
        let previousSearch = forumSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextSearch = text.trimmingCharacters(in: .whitespacesAndNewlines)
        forumSearchText = text
        forumPostError = nil
        forumPaginationError = nil
        forumLoadGeneration &+= 1
        if nextSearch.lowercased().hasPrefix(previousSearch.lowercased()) {
            let presentation = ForumPostPresentation(
                posts: forumPosts,
                recentCount: forumRecentPostCount
            ).filtering(
                searchText: nextSearch,
                selectedTagIDs: forumSelectedTagIDs,
                tagMatch: forumTagMatch
            )
            forumPosts = presentation.posts
            forumRecentPostCount = presentation.recentCount
        } else {
            applyForumPresentation()
        }
        forumLoadTask?.cancel()
        guard !nextSearch.isEmpty else {
            isSearchingForumPosts = false
            hasMoreForumPosts = forumNextOffset != nil
            return
        }
        hasMoreForumPosts = false
        isSearchingForumPosts = true
        forumLoadTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                  forumSearchText.trimmingCharacters(in: .whitespacesAndNewlines) == nextSearch
            else { return }
            await loadForumPosts(reset: true)
        }
    }

    private func loadForumPosts(reset: Bool) async {
        guard let channelID = selectedChannelID, selectedChannel?.kind == .forum else { return }
        let loadSignpost = Self.forumPerformanceSignposter.beginInterval("ForumPostsLoad")
        defer {
            Self.forumPerformanceSignposter.endInterval("ForumPostsLoad", loadSignpost)
        }
        let trimmedSearch = forumSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSearch = !trimmedSearch.isEmpty
        if isSearch { isSearchingForumPosts = true }
        if reset {
            forumLoadGeneration &+= 1
            forumPaginationError = nil
            if !isSearch { forumNextOffset = nil }
        } else {
            isLoadingMoreForumPosts = true
            forumPaginationError = nil
        }
        let requestGeneration = forumLoadGeneration
        let loadingIndicatorTask: Task<Void, Never>? =
            reset && !hasLoadedForumPosts
                ? Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard let self, !Task.isCancelled,
                          selectedChannelID == channelID,
                          forumLoadGeneration == requestGeneration,
                          !hasLoadedForumPosts
                    else { return }
                    isLoadingForumPosts = true
                }
                : nil
        defer {
            loadingIndicatorTask?.cancel()
            if selectedChannelID == channelID, forumLoadGeneration == requestGeneration {
                isLoadingForumPosts = false
                isLoadingMoreForumPosts = false
                if isSearch { isSearchingForumPosts = false }
            }
        }
        let scope: ForumPostScope =
            !trimmedSearch.isEmpty
                ? .search(trimmedSearch)
                : .active
        do {
            let providerSignpost = Self.forumPerformanceSignposter.beginInterval("ForumProviderLoad")
            let page: ForumPostPage
            do {
                defer {
                    Self.forumPerformanceSignposter.endInterval(
                        "ForumProviderLoad",
                        providerSignpost
                    )
                }
                page = try await provider.forumPosts(
                    in: channelID,
                    query: ForumPostQuery(
                        scope: scope,
                        sortOrder: forumSortOrder,
                        selectedTagIDs: forumSelectedTagIDs,
                        tagMatch: forumTagMatch,
                        offset: reset ? 0 : (forumNextOffset ?? 0),
                        limit: 25
                    )
                )
            }
            guard !Task.isCancelled, selectedChannelID == channelID,
                  forumLoadGeneration == requestGeneration
            else { return }
            let catalogueSignpost = Self.forumPerformanceSignposter.beginInterval(
                "ForumCatalogueUpdate"
            )
            if isSearch {
                mergeForumCatalogue(page.posts)
            } else if reset {
                replaceForumCatalogue(with: page.posts)
            } else {
                mergeForumCatalogue(page.posts)
            }
            Self.forumPerformanceSignposter.endInterval(
                "ForumCatalogueUpdate",
                catalogueSignpost
            )
            let presentationSignpost = Self.forumPerformanceSignposter.beginInterval(
                "ForumPresentation"
            )
            applyForumPresentation()
            Self.forumPerformanceSignposter.endInterval(
                "ForumPresentation",
                presentationSignpost
            )
            if !isSearch {
                forumNextOffset = page.nextOffset
                hasMoreForumPosts = page.hasMore
            } else {
                hasMoreForumPosts = false
            }
            forumPostError = nil
            forumPaginationError = nil
            hasLoadedForumPosts = true
            if !isSearch, reset {
                acknowledgeForumVisitIfNeeded(channelID: channelID)
            }
        } catch {
            guard !Self.isForumLoadCancellation(error) else { return }
            guard selectedChannelID == channelID, forumLoadGeneration == requestGeneration else {
                return
            }
            if reset {
                forumPostError =
                    isSearch && !forumCataloguePosts.isEmpty
                        ? nil
                        : error.localizedDescription
            } else {
                forumPaginationError = error.localizedDescription
            }
            hasLoadedForumPosts = true
        }
    }

    private func mergeForumCatalogue(_ posts: [ForumPost]) {
        for incoming in posts {
            readState.merge(forumPost: incoming)
            let post: ForumPost
            if let index = forumCatalogueIndexByID[incoming.id] {
                post = forumPostPreservingReactionPresentation(
                    incoming,
                    previous: forumCataloguePosts[index]
                )
            } else {
                post = incoming
            }
            if let index = forumCatalogueIndexByID[post.id] {
                forumCataloguePosts[index] = post
            } else {
                forumCatalogueIndexByID[post.id] = forumCataloguePosts.endIndex
                forumCataloguePosts.append(post)
            }
        }
    }

    private func replaceForumCatalogue(with posts: [ForumPost]) {
        let previousByID = Dictionary(
            uniqueKeysWithValues: forumCataloguePosts.map { ($0.id, $0) }
        )
        forumCataloguePosts = posts.map { incoming in
            readState.merge(forumPost: incoming)
            guard let previous = previousByID[incoming.id] else { return incoming }
            return forumPostPreservingReactionPresentation(incoming, previous: previous)
        }
        forumCatalogueIndexByID = Dictionary(
            uniqueKeysWithValues: forumCataloguePosts.indices.map {
                (forumCataloguePosts[$0].id, $0)
            }
        )
    }

    private func forumPostPreservingReactionPresentation(
        _ incoming: ForumPost,
        previous: ForumPost
    ) -> ForumPost {
        var result = incoming
        if let firstMessage = incoming.firstMessage {
            result.firstMessage = firstMessage.preservingReactionReactors(
                from: previous.firstMessage ?? firstMessage
            )
        } else {
            result.firstMessage = previous.firstMessage
        }
        if let mostRecentMessage = incoming.mostRecentMessage {
            result.mostRecentMessage = mostRecentMessage.preservingReactionReactors(
                from: previous.mostRecentMessage ?? mostRecentMessage
            )
        } else {
            result.mostRecentMessage = previous.mostRecentMessage
        }
        result.owner = incoming.owner ?? previous.owner
        return result
    }

    private func reconcileForumMessage(_ message: Message) {
        guard let index = forumCatalogueIndexByID[message.channelID] else { return }
        var updated = forumCataloguePosts[index]
        let isNewerReply =
            updated.thread.lastMessageID.map { message.id > $0 }
            ?? (message.id.rawValue != updated.id.rawValue)
        if message.id.rawValue == updated.id.rawValue || updated.firstMessage?.id == message.id {
            updated.firstMessage = message
        }
        if updated.mostRecentMessage == nil || message.timestamp >= updated.lastActivityAt {
            updated.mostRecentMessage = message
            updated.thread.lastMessageID = message.id
        }
        if isNewerReply {
            updated.thread.messageCount += 1
            updated.thread.totalMessageSent += 1
        }
        guard updated != forumCataloguePosts[index] else { return }
        forumCataloguePosts[index] = updated
        updateForumPresentation(with: updated)
    }

    private func applyForumPresentation() {
        let presentation = ForumPostPresentation.make(
            catalogue: forumCataloguePosts,
            searchText: forumSearchText,
            selectedTagIDs: forumSelectedTagIDs,
            tagMatch: forumTagMatch,
            sortOrder: forumSortOrder
        )
        forumPosts = presentation.posts
        forumRecentPostCount = presentation.recentCount
    }

    private func updateForumPresentation(with post: ForumPost) {
        let presentation = ForumPostPresentation(
            posts: forumPosts,
            recentCount: forumRecentPostCount
        ).updating(
            post,
            searchText: forumSearchText,
            selectedTagIDs: forumSelectedTagIDs,
            tagMatch: forumTagMatch,
            sortOrder: forumSortOrder
        )
        forumPosts = presentation.posts
        forumRecentPostCount = presentation.recentCount
    }

    nonisolated static func isForumLoadCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        let value = error as NSError
        return value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled
    }

    @discardableResult
    func createForumPost(_ draft: CreateForumPostDraft) async -> Bool {
        guard canCreateForumPosts else {
            forumActionError = "You do not have permission to create posts in this forum."
            return false
        }
        forumActionError = nil
        forumCreateGeneration &+= 1
        let generation = forumCreateGeneration
        defer {
            if forumCreateGeneration == generation {
                forumCreateProgress = nil
                forumCreateGeneration &+= 1
            }
        }
        do {
            let post = try await provider.createForumPost(draft) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.forumCreateGeneration == generation else { return }
                    self.forumCreateProgress = progress
                }
            }
            mergeForumCatalogue([post])
            applyForumPresentation()
            open(post)
            return true
        } catch {
            if Self.isForumLoadCancellation(error) {
                return false
            }
            forumActionError = error.localizedDescription
            return false
        }
    }

    func updateForumPost(_ post: ForumPost, mutation: ForumPostMutation) async {
        switch mutation {
        case .tags(let tagIDs):
            guard canEditForumPostTags(post) else {
                forumActionError = "You do not have permission to edit this post’s tags."
                return
            }
            let uniqueTagIDs = Set(tagIDs)
            guard uniqueTagIDs.count <= 5,
                  let channel = selectedChannel,
                  channel.id == post.thread.parentID
            else {
                forumActionError = "The selected tags are invalid for this forum."
                return
            }
            let availableTagsByID = Dictionary(
                uniqueKeysWithValues: channel.availableTags.map { ($0.id, $0) }
            )
            guard uniqueTagIDs.allSatisfy({ availableTagsByID[$0] != nil }) else {
                forumActionError = "One or more selected tags are no longer available."
                return
            }
            guard !channel.requiresForumTag || !uniqueTagIDs.isEmpty else {
                forumActionError = "This forum requires every post to have at least one tag."
                return
            }
            if !canManageForumPosts {
                let changedTagIDs = uniqueTagIDs.symmetricDifference(post.thread.appliedTagIDs)
                guard changedTagIDs.allSatisfy({
                    availableTagsByID[$0]?.isModerated == false
                }) else {
                    forumActionError = "Only moderators can change moderated tags."
                    return
                }
            }
        case .archived:
            guard canArchiveForumPost(post) else {
                forumActionError = "You do not have permission to close or reopen this post."
                return
            }
        case .locked, .pinned:
            guard canManageForumPosts else {
                forumActionError = "Only moderators can change this post."
                return
            }
        }

        forumActionError = nil
        do {
            let updated = try await provider.updateForumPost(post, mutation: mutation)
            mergeForumCatalogue([updated])
            applyForumPresentation()
            if openThread?.id == updated.id { openThread = updated.thread }
        } catch {
            forumActionError = error.localizedDescription
        }
    }

    func deleteForumPost(_ post: ForumPost) async {
        guard canDeleteForumPost(post) else {
            forumActionError = "You do not have permission to delete this post."
            return
        }
        forumActionError = nil
        do {
            try await provider.deleteForumPost(post)
            removeForumPost(post.id)
            if openThread?.id == post.id {
                closeThread()
            }
            forumActionError = nil
        } catch {
            forumActionError = error.localizedDescription
        }
    }

    func dismissForumActionError() {
        forumActionError = nil
    }

    private func removeForumPost(_ postID: ChannelID) {
        guard let index = forumCatalogueIndexByID.removeValue(forKey: postID) else { return }
        forumCataloguePosts.remove(at: index)
        if index < forumCataloguePosts.endIndex {
            for updatedIndex in index ..< forumCataloguePosts.endIndex {
                forumCatalogueIndexByID[forumCataloguePosts[updatedIndex].id] = updatedIndex
            }
        }
        applyForumPresentation()
    }

    private func beginSelectedChannelLoad() {
        channelLoadTask?.cancel()
        channelLoadGeneration &+= 1
        let generation = channelLoadGeneration
        messageLoadError = nil
        messageLoadErrorIsEarlierPage = false
        isLoadingEarlier = false
        hasCompletedInitialMessageLoad = false
        stopLocalTyping(clearThrottle: true)
        replyingTo = nil

        guard let channelID = selectedChannelID,
              selectedChannel?.kind != .voice || isVoiceChatOpen
        else {
            replaceSelectedMessages(with: [])
            draft = ""
            hasMoreMessages = false
            isLoadingMessages = false
            hasCompletedInitialMessageLoad = true
            return
        }

        let cachedMessages = messageCache.removeValue(forKey: channelID) ?? []
        replaceSelectedMessages(with: cachedMessages)
        hasMoreMessages = hasMoreCache[channelID] ?? false
        // Cached rows are immediately presentable, but the newest-page
        // request is still in flight and the older-history boundary is
        // unknown until it answers. Keeping this true suppresses a false
        // channel beginning and exposes compact progress above cached rows.
        isLoadingMessages = true
        preserveUnreadDividerIfNeeded(channelID: channelID)
        draft = ""
        channelLoadTask = Task { [weak self] in
            await self?.loadSelectedChannel(channelID, generation: generation)
        }
    }

    private func loadSelectedChannel(_ channelID: ChannelID, generation: Int) async {
        async let cachedMessages = storedMessages(in: channelID)
        async let storedDraft = storedDraft(in: channelID)
        async let freshPage = provider.messages(in: channelID, before: nil, limit: 100)

        let cached = await cachedMessages
        guard isCurrentLoad(channelID, generation: generation) else { return }
        if messages.isEmpty, !cached.isEmpty {
            replaceSelectedMessages(with: cached)
            preserveUnreadDividerIfNeeded(channelID: channelID)
        }

        let savedDraft = await storedDraft
        guard isCurrentLoad(channelID, generation: generation) else { return }
        if draft.isEmpty {
            draft = savedDraft
        }

        do {
            let page = try await freshPage
            guard isCurrentLoad(channelID, generation: generation) else { return }
            let merged = Self.merging(current: messages, fresh: page.messages)
            if merged != messages {
                replaceSelectedMessages(with: merged)
            }
            hasMoreMessages = page.hasMoreBefore
            hasMoreCache[channelID] = page.hasMoreBefore
            messageLoadError = nil
            messageLoadErrorIsEarlierPage = false
            isLoadingMessages = false
            hasCompletedInitialMessageLoad = true
            preserveUnreadDividerIfNeeded(channelID: channelID)
            reportConversationHistoryLoaded(channelID: channelID)
            try await database?.save(messages: page.messages)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentLoad(channelID, generation: generation) else { return }
            messageLoadError = error.localizedDescription
            messageLoadErrorIsEarlierPage = false
            isLoadingMessages = false
            hasCompletedInitialMessageLoad = true
        }
    }

    func loadEarlier() async {
        guard let channelID = selectedChannelID, let first = messages.first, hasMoreMessages,
              !isLoadingEarlier
        else { return }
        messageLoadError = nil
        messageLoadErrorIsEarlierPage = false
        isLoadingEarlier = true
        defer {
            if selectedChannelID == channelID {
                isLoadingEarlier = false
            }
        }
        do {
            let page = try await provider.messages(in: channelID, before: first.id, limit: 50)
            guard !Task.isCancelled, selectedChannelID == channelID else { return }
            let reconcileStart = ProcessInfo.processInfo.systemUptime
            let earlier = page.messages.filter {
                !selectedMessageIDs.contains($0.id)
            }
            let filterEnd = ProcessInfo.processInfo.systemUptime
            if !earlier.isEmpty {
                guard await prependSelectedMessages(
                    earlier,
                    channelID: channelID
                ) else { return }
            }
            let prependEnd = ProcessInfo.processInfo.systemUptime
            hasMoreMessages = page.hasMoreBefore
            hasMoreCache[channelID] = page.hasMoreBefore
            messageLoadError = nil
            messageLoadErrorIsEarlierPage = false
            let stateEnd = ProcessInfo.processInfo.systemUptime
            if runsChatPerformanceBenchmark {
                let milliseconds = (stateEnd - reconcileStart) * 1_000
                if milliseconds >= 4 {
                    NSLog(
                        "SakuraCord history phases: filter %.2f ms; prepend %.2f ms; state %.2f ms (%d rows)",
                        (filterEnd - reconcileStart) * 1_000,
                        (prependEnd - filterEnd) * 1_000,
                        (stateEnd - prependEnd) * 1_000,
                        messages.count
                    )
                }
            }
            try await database?.save(messages: page.messages)
        } catch is CancellationError {
            return
        } catch {
            guard selectedChannelID == channelID else { return }
            messageLoadError = error.localizedDescription
            messageLoadErrorIsEarlierPage = true
        }
    }

    func retryMessageLoad() {
        guard selectedChannelID != nil else { return }
        if messageLoadErrorIsEarlierPage {
            messageLoadError = nil
            messageLoadErrorIsEarlierPage = false
            Task { [weak self] in
                await self?.loadEarlier()
            }
            return
        }
        beginSelectedChannelLoad()
    }

    func reply(to message: Message) {
        guard message.channelID == selectedChannelID else { return }
        replyingTo = message
        NotificationCenter.default.post(name: .sakuracordFocusComposer, object: nil)
    }

    func cancelReply() {
        replyingTo = nil
        NotificationCenter.default.post(name: .sakuracordFocusComposer, object: nil)
    }

    func open(_ thread: MessageThreadSummary) {
        guard openThread?.id != thread.id else { return }
        let starter = messages.first { $0.thread?.id == thread.id }
        openThreadConversation(
            thread,
            starter: starter?.author,
            startedAt: starter?.timestamp,
            initialMessages: []
        )
    }

    func open(_ post: ForumPost) {
        guard openThread?.id != post.id else { return }
        readState.merge(forumPost: post)
        openThreadConversation(
            post.thread,
            starter: post.owner ?? post.firstMessage?.author,
            startedAt: post.firstMessage?.timestamp ?? post.createdAt,
            initialMessages: post.firstMessage.map { [$0] } ?? []
        )
    }

    private func openThreadConversation(
        _ thread: MessageThreadSummary,
        starter: User?,
        startedAt: Date?,
        initialMessages: [Message]
    ) {
        threadLoadTask?.cancel()
        readState.merge(thread: thread)
        openThread = thread
        _ = readState.updatePresentation(
            channelID: thread.id,
            isPresented: true,
            initialHistoryLoaded: false,
            initialPositionEstablished: false,
            windowIsActive: mainWindowIsActive,
            isAtNewest: false,
            blocksAutomaticAcknowledgement: false
        )
        openThreadStarter = starter
        openThreadStartedAt = startedAt
        threadMessages = initialMessages
        threadDraft = ""
        threadComposerAttachments = []
        hasMoreThreadMessages = false
        beginInitialThreadLoad(thread)
    }

    private func beginInitialThreadLoad(
        _ thread: MessageThreadSummary
    ) {
        threadLoadTask?.cancel()
        threadErrorMessage = nil
        threadErrorScope = nil
        isLoadingThread = true
        hasCompletedInitialThreadLoad = false
        threadLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await provider.messages(
                    in: thread.id,
                    before: nil,
                    limit: 100
                )
                guard !Task.isCancelled, openThread?.id == thread.id else { return }
                threadMessages = page.messages.sorted { $0.timestamp < $1.timestamp }
                hasMoreThreadMessages = page.hasMoreBefore
                threadErrorMessage = nil
                threadErrorScope = nil
                isLoadingThread = false
                hasCompletedInitialThreadLoad = true
                reportConversationHistoryLoaded(channelID: thread.id)
                try await database?.save(messages: page.messages)
            } catch is CancellationError {
                return
            } catch {
                guard openThread?.id == thread.id else { return }
                threadErrorMessage = error.localizedDescription
                threadErrorScope = .initialPage
                isLoadingThread = false
                hasCompletedInitialThreadLoad = true
            }
        }
    }

    func closeThread() {
        if let threadID = openThread?.id {
            unreadDividerMessageIDs[threadID] = nil
            if conversationNewestRequest?.channelID == threadID {
                conversationNewestRequest = nil
            }
            _ = readState.updatePresentation(channelID: threadID, isPresented: false)
        }
        threadLoadTask?.cancel()
        threadLoadTask = nil
        openThread = nil
        openThreadStarter = nil
        openThreadStartedAt = nil
        threadMessages = []
        threadDraft = ""
        threadComposerAttachments = []
        isLoadingThread = false
        hasCompletedInitialThreadLoad = false
        isLoadingEarlierThread = false
        hasMoreThreadMessages = false
        threadErrorMessage = nil
        threadErrorScope = nil
    }

    func openVoiceChat(for channel: Channel) {
        guard channel.kind == .voice else { return }
        if selectedChannelID != channel.id {
            selectedChannelID = channel.id
        }
        guard selectedChannelID == channel.id, !isVoiceChatOpen else { return }
        isVoiceChatOpen = true
        beginSelectedChannelLoad()
    }

    func closeVoiceChat() {
        guard isVoiceChatOpen else { return }
        channelLoadTask?.cancel()
        channelLoadTask = nil
        channelLoadGeneration &+= 1
        isVoiceChatOpen = false
        isLoadingMessages = false
        isLoadingEarlier = false
        messageLoadError = nil
    }

    func loadEarlierThread() async {
        guard let thread = openThread, let first = threadMessages.first, hasMoreThreadMessages,
              !isLoadingEarlierThread
        else { return }
        threadErrorMessage = nil
        threadErrorScope = nil
        isLoadingEarlierThread = true
        defer {
            if openThread?.id == thread.id {
                isLoadingEarlierThread = false
            }
        }
        do {
            let page = try await provider.messages(in: thread.id, before: first.id, limit: 50)
            guard !Task.isCancelled, openThread?.id == thread.id else { return }
            let ids = Set(threadMessages.map(\.id))
            threadMessages.insert(contentsOf: page.messages.filter { !ids.contains($0.id) }, at: 0)
            hasMoreThreadMessages = page.hasMoreBefore
            threadErrorMessage = nil
            threadErrorScope = nil
            try await database?.save(messages: page.messages)
        } catch is CancellationError {
            return
        } catch {
            guard openThread?.id == thread.id else { return }
            threadErrorMessage = error.localizedDescription
            threadErrorScope = .earlierPage
        }
    }

    func retryThreadLoad() {
        guard let thread = openThread else { return }
        switch threadErrorScope {
        case .initialPage:
            beginInitialThreadLoad(thread)
        case .earlierPage:
            threadErrorMessage = nil
            threadErrorScope = nil
            Task { [weak self] in
                await self?.loadEarlierThread()
            }
        case .action, nil:
            return
        }
    }

    @discardableResult
    func sendThreadMessage(attachments: [URL] = []) async -> Bool {
        await sendThreadComposerMessage(
            attachments: attachments.map { ForumPostAttachment(url: $0) }
        )
    }

    @discardableResult
    func sendThreadComposerMessage(attachments: [ForumPostAttachment]) async -> Bool {
        guard let thread = openThread, openThreadAccess.canSend else { return false }
        let content = threadDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !attachments.isEmpty else { return false }
        guard validateAttachmentCount(attachments) else { return false }
        return await sendThreadMessage(
            content: content,
            attachments: attachments,
            thread: thread,
            clearsComposer: true
        )
    }

    @discardableResult
    private func sendThreadMessage(
        content: String,
        attachments: [ForumPostAttachment],
        thread: MessageThreadSummary,
        clearsComposer: Bool
    ) async -> Bool {
        let draft = SendMessageDraft(
            channelID: thread.id,
            content: content,
            attachments: attachments
        )
        threadErrorMessage = nil
        threadErrorScope = nil
        if clearsComposer {
            threadDraft = ""
        }
        do {
            let message = try await provider.send(draft)
            guard openThread?.id == thread.id else { return true }
            var updated = threadMessages
            updated.removeAll {
                $0.id == message.id || ($0.nonce != nil && $0.nonce == message.nonce)
            }
            Self.insert(message, intoSorted: &updated)
            if updated != threadMessages {
                threadMessages = updated
            }
            try await database?.save(messages: [message])
            completeConversationReadingAndAdvance(channelID: thread.id)
            return true
        } catch {
            guard openThread?.id == thread.id else { return false }
            if clearsComposer, threadDraft.isEmpty {
                threadDraft = content
            }
            threadErrorMessage = error.localizedDescription
            threadErrorScope = .action
            return false
        }
    }

    func updateDraft(_ value: String) {
        draft = value
        if value.hasPrefix("/") || commandComposer.activeCommand != nil {
            stopLocalTyping(clearThrottle: false)
        } else {
            scheduleLocalTyping(for: value)
        }
        guard let channelID = selectedChannelID else { return }
        Task { try? await database?.saveDraft(value, channelID: channelID) }
    }

    func loadApplicationCommands() {
        guard supportedCapabilities.contains(.slashCommands),
              let channel = selectedChannel,
              channel.kind != .voice, channel.kind != .forum, channel.kind != .unknown
        else {
            commandComposer.failLoading(
                ChatProviderError.capabilityDisabled(.slashCommands).localizedDescription
            )
            return
        }
        let contextTarget: ApplicationCommandIndexTarget =
            channel.guildID.map {
                .guild($0)
            } ?? .channel(channel.id)
        let targets: Set<ApplicationCommandIndexTarget> = [contextTarget, .user]
        commandComposer.beginLoading(targets: targets)
        commandLoadTask?.cancel()
        commandLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                async let context: ApplicationCommandCatalog? =
                    try? provider.applicationCommandCatalog(
                        for: contextTarget
                    )
                async let user: ApplicationCommandCatalog? =
                    try? provider.applicationCommandCatalog(
                        for: .user
                    )
                let catalogs = await [context, user].compactMap(\.self)
                guard !catalogs.isEmpty else {
                    throw ChatProviderError.invalidRequest(
                        "Discord did not return an application command index for this conversation."
                    )
                }
                guard !Task.isCancelled, selectedChannelID == channel.id else { return }
                let roleIDs = Set(
                    (snapshot?.currentUser.id).flatMap { membersByID[$0] }?.roles.map(\.id) ?? []
                )
                commandComposer.replaceCatalogs(
                    catalogs,
                    channel: channel,
                    currentUserID: snapshot?.currentUser.id,
                    memberRoleIDs: roleIDs
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, selectedChannelID == channel.id else { return }
                commandComposer.failLoading(error.localizedDescription)
            }
        }
    }

    func requestApplicationCommandAutocomplete(
        for option: ApplicationCommandOption,
        query: String
    ) {
        guard option.usesAutocomplete, option.type.supportsAutocomplete,
              let channelID = selectedChannelID,
              let invocation = commandComposer.invocation(
                  channelID: channelID, guildID: selectedGuildID
              )
        else { return }
        let request = ApplicationCommandAutocompleteRequest(
            invocation: invocation, focusedOptionID: option.id, query: query
        )
        switch commandComposer.prepareAutocomplete(
            option: option, query: query, nonce: request.nonce
        ) {
        case .cached:
            commandAutocompleteTask?.cancel()
            commandAutocompleteTask = nil
            return
        case .pending:
            return
        case .request:
            commandAutocompleteTask?.cancel()
        }
        commandAutocompleteTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(200))
                try Task.checkCancellation()
                try await provider.requestApplicationCommandAutocomplete(request)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                commandComposer.failAutocomplete(
                    nonce: request.nonce, message: error.localizedDescription
                )
            }
        }
    }

    func cancelApplicationCommandAutocompleteTask() {
        commandAutocompleteTask?.cancel()
        commandAutocompleteTask = nil
    }

    func requestApplicationCommandMemberSearch(query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let option = commandComposer.focusedOption,
              option.type == .user || option.type == .mentionable,
              let guildID = selectedGuildID,
              !normalized.isEmpty
        else {
            cancelApplicationCommandMemberSearch()
            return
        }
        let key = CommandMemberQuery(guildID: guildID, query: normalized.lowercased())
        if let cached = commandMemberSearchCache[key] {
            commandMemberSearchTask?.cancel()
            commandMemberSearchTask = nil
            commandMemberSearchQuery = nil
            commandMemberResults = cached
            return
        }
        guard commandMemberSearchQuery != key else { return }
        commandMemberSearchTask?.cancel()
        commandMemberSearchQuery = key
        commandMemberResults = []
        commandMemberSearchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                let results = try await provider.searchMembers(
                    in: guildID, query: normalized, limit: 20
                )
                guard !Task.isCancelled, commandMemberSearchQuery == key,
                      selectedGuildID == guildID
                else { return }
                commandMemberSearchCache[key] = results
                commandMemberResults = results
                commandMemberSearchQuery = nil
                commandMemberSearchTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard commandMemberSearchQuery == key else { return }
                commandMemberSearchQuery = nil
                commandMemberSearchTask = nil
                commandMemberResults = []
            }
        }
    }

    func cancelApplicationCommandMemberSearch() {
        commandMemberSearchTask?.cancel()
        commandMemberSearchTask = nil
        commandMemberSearchQuery = nil
        commandMemberResults = []
    }

    func requestMentionMemberSearch(query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let guildID = selectedGuildID, !normalized.isEmpty else {
            mentionMemberSearchTask?.cancel()
            mentionMemberSearchTask = nil
            mentionMemberSearchQuery = nil
            mentionMemberResults = []
            return
        }
        let key = CommandMemberQuery(guildID: guildID, query: normalized.lowercased())
        if let cached = mentionMemberSearchCache[key],
           Date().timeIntervalSince(cached.storedAt) < 60
        {
            mentionMemberResults = cached.members
            return
        }
        mentionMemberSearchCache[key] = nil
        guard mentionMemberSearchQuery != key else { return }
        mentionMemberSearchTask?.cancel()
        mentionMemberSearchQuery = key
        mentionMemberResults = []
        mentionMemberSearchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(200))
                try Task.checkCancellation()
                let results = try await provider.searchMembers(
                    in: guildID, query: key.query, limit: 10
                )
                let roles = try? await provider.roles(in: guildID)
                guard !Task.isCancelled, mentionMemberSearchQuery == key,
                      selectedGuildID == guildID
                else { return }
                if let roles { guildRoles = roles }
                mentionMemberSearchCache[key] = MentionMemberSearchCacheEntry(
                    members: results,
                    storedAt: Date()
                )
                mentionMemberResults = results
                mergeMentionAutocompleteMembers(results)
                for member in results { knownMentionMembers[member.id] = member }
                mentionMemberSearchQuery = nil
            } catch is CancellationError {
                return
            } catch {
                guard mentionMemberSearchQuery == key else { return }
                mentionMemberSearchQuery = nil
                mentionMemberResults = []
            }
        }
    }

    func rememberMentionMember(_ member: Member) {
        knownMentionMembers[member.id] = member
    }

    private func mergeMentionAutocompleteMembers(_ updates: [Member]) {
        var positions = Dictionary(
            uniqueKeysWithValues: mentionAutocompleteMembers.indices.map {
                (mentionAutocompleteMembers[$0].id, $0)
            }
        )
        for member in updates {
            if let index = positions[member.id] {
                mentionAutocompleteMembers[index] = member
            } else {
                positions[member.id] = mentionAutocompleteMembers.count
                mentionAutocompleteMembers.append(member)
            }
        }
    }

    func showMembers(withRole roleID: RoleID) {
        roleMemberTask?.cancel()
        roleMemberResult = nil
        roleMemberErrorMessage = nil
        guard let guildID = selectedGuildID else {
            roleMemberErrorMessage = "Role members are only available inside a server."
            return
        }
        isLoadingRoleMembers = true
        roleMemberTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await provider.members(withRole: roleID, in: guildID)
                guard !Task.isCancelled, selectedGuildID == guildID else { return }
                roleMemberResult = result
                for member in result.members { knownMentionMembers[member.id] = member }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                roleMemberErrorMessage = error.localizedDescription
            }
            isLoadingRoleMembers = false
        }
    }

    func executeApplicationCommand() {
        guard commandExecutionTask == nil,
              let channelID = selectedChannelID,
              let invocation = commandComposer.invocation(
                  channelID: channelID, guildID: selectedGuildID
              )
        else { return }
        commandAutocompleteTask?.cancel()
        stopLocalTyping(clearThrottle: true)
        updateDraft("")
        commandExecutionTask = Task { [weak self] in
            guard let self else { return }
            defer { commandExecutionTask = nil }
            do {
                try await provider.executeApplicationCommand(invocation) { [weak self] progress in
                    Task { @MainActor in
                        self?.commandComposer.updateExecutionProgress(progress)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                commandComposer.failExecution(error.localizedDescription)
            }
        }
    }

    func searchGIFs(_ query: String) {
        gifSearchTask?.cancel()
        isLoadingGIFs = true
        gifErrorMessage = nil
        gifSearchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard await provider.supports(.gifs) else {
                    throw ChatProviderError.capabilityDisabled(.gifs)
                }
                let values =
                    query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? try await provider.trendingGIFs()
                        : try await provider.searchGIFs(query: query)
                guard !Task.isCancelled else { return }
                gifResults = values
                isLoadingGIFs = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                gifResults = []
                gifErrorMessage = error.localizedDescription
                isLoadingGIFs = false
            }
        }
    }

    @discardableResult
    func sendGIF(_ gif: GIFSearchResult) async -> Bool {
        guard selectedChannelID != nil else { return false }
        let priorDraft = draft
        updateDraft(gif.url.absoluteString)
        let sent = await send()
        if !sent {
            updateDraft(priorDraft)
        }
        return sent
    }

    func loadStickersIfNeeded(in guildID: GuildID) {
        guard stickersByGuild[guildID] == nil, stickerLoadTasks[guildID] == nil else { return }
        stickerLoadTasks[guildID] = Task { [weak self] in
            guard let self else { return }
            defer { stickerLoadTasks[guildID] = nil }
            guard await provider.supports(.stickers) else {
                stickersByGuild[guildID] = []
                return
            }
            stickersByGuild[guildID] = await (try? provider.stickers(in: guildID)) ?? []
        }
    }

    @discardableResult
    func sendSticker(_ sticker: MessageSticker) async -> Bool {
        guard let channelID = selectedChannelID, await provider.supports(.stickerSending) else {
            return false
        }
        let draft = SendMessageDraft(channelID: channelID, content: "", stickerIDs: [sticker.id])
        do {
            let message = try await provider.send(draft)
            reconcile(message)
            try await database?.save(messages: [message])
            completeConversationReadingAndAdvance(channelID: channelID)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func submitComponent(
        on message: Message, customID: String, kind: ComponentInteractionKind, values: [String] = []
    ) async {
        let key = ComponentControlKey(messageID: message.id, customID: customID)
        guard !pendingComponentControls.contains(key) else { return }
        guard supportedCapabilities.contains(.components) else {
            componentErrors[key] =
                ChatProviderError.capabilityDisabled(.components).localizedDescription
            return
        }
        let submission = ComponentInteractionSubmission(
            messageID: message.id, channelID: message.channelID, guildID: message.guildID,
            applicationID: message.applicationID, customID: customID, kind: kind, values: values
        )
        pendingComponentControls.insert(key)
        componentKeyByNonce[submission.nonce] = key
        componentErrors[key] = nil
        do {
            try await provider.submitComponentInteraction(submission)
        } catch {
            pendingComponentControls.remove(key)
            componentKeyByNonce[submission.nonce] = nil
            componentErrors[key] = error.localizedDescription
        }
    }

    func supportsCapability(_ capability: ChatCapability) -> Bool {
        supportedCapabilities.contains(capability)
    }

    func isComponentPending(messageID: MessageID, customID: String) -> Bool {
        pendingComponentControls.contains(
            ComponentControlKey(messageID: messageID, customID: customID))
    }

    func componentError(for messageID: MessageID) -> String? {
        componentErrors
            .filter { $0.key.messageID == messageID }
            .sorted { $0.key.customID < $1.key.customID }
            .first?.value
    }

    func dismissInteractionModal() {
        presentedInteractionModal = nil
        interactionModalNonce = nil
    }

    func submitModal(values: [String: [String]], fileURLs: [String: [URL]]) async -> Bool {
        guard let modal = presentedInteractionModal, let nonce = interactionModalNonce else {
            return false
        }
        do {
            try await provider.submitModal(
                ModalSubmission(customID: modal.customID, values: values, fileURLs: fileURLs),
                nonce: nonce
            )
            dismissInteractionModal()
            return true
        } catch {
            interactionErrorMessage = error.localizedDescription
            return false
        }
    }

    private func scheduleLocalTyping(for value: String) {
        guard !value.isEmpty,
              connectionState == .ready,
              let channel = selectedChannel,
              Self.supportsTyping(channel.kind)
        else {
            stopLocalTyping(clearThrottle: value.isEmpty)
            return
        }
        if localTypingTask != nil, localTypingChannelID == channel.id {
            return
        }
        stopLocalTyping(clearThrottle: false)
        localTypingGeneration &+= 1
        let generation = localTypingGeneration
        localTypingChannelID = channel.id
        let now = Date.now
        let debounce = Self.seconds(localTypingTiming.debounce)
        let remainingThrottle =
            lastTypingRequestAt[channel.id]
                .map { max(0, Self.seconds(localTypingTiming.throttle) - now.timeIntervalSince($0)) }
                ?? 0
        let delay = max(debounce, remainingThrottle)
        localTypingTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.performLocalTyping(channelID: channel.id, generation: generation)
        }
    }

    private func performLocalTyping(channelID: ChannelID, generation: UInt64) async {
        guard generation == localTypingGeneration,
              localTypingChannelID == channelID,
              selectedChannelID == channelID,
              !draft.isEmpty,
              connectionState == .ready,
              let selectedChannel,
              Self.supportsTyping(selectedChannel.kind)
        else { return }
        localTypingTask = nil
        localTypingChannelID = nil
        // Count the attempt, not only a successful response. A failed mutation is
        // not immediately retried by subsequent keystrokes.
        lastTypingRequestAt[channelID] = .now
        do {
            try await provider.sendTyping(in: channelID)
        } catch is CancellationError {
            return
        } catch {
            // Typing is best-effort. The shared provider still applies its safety
            // circuit and mutation retry rules; composer input remains available.
        }
    }

    private func stopLocalTyping(clearThrottle: Bool) {
        localTypingGeneration &+= 1
        localTypingTask?.cancel()
        localTypingTask = nil
        if clearThrottle {
            if let localTypingChannelID {
                lastTypingRequestAt[localTypingChannelID] = nil
            }
            if let selectedChannelID {
                lastTypingRequestAt[selectedChannelID] = nil
            }
        }
        localTypingChannelID = nil
    }

    private static func supportsTyping(_ kind: ChannelKindValue) -> Bool {
        switch kind {
        case .text, .announcement, .directMessage, .groupDirectMessage: true
        case .forum, .voice, .unknown: false
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    @discardableResult
    func send(attachments: [URL] = []) async -> Bool {
        await sendComposerMessage(
            attachments: attachments.map { ForumPostAttachment(url: $0) }
        )
    }

    @discardableResult
    func sendComposerMessage(attachments: [ForumPostAttachment]) async -> Bool {
        guard let channelID = selectedChannelID, selectedConversationAccess.canSend else {
            return false
        }
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !attachments.isEmpty else { return false }
        guard validateAttachmentCount(attachments) else { return false }
        let replyTo = replyingTo?.id
        let replyPreview = replyingTo.map {
            MessageReplyPreview(messageID: $0.id, author: $0.author, content: $0.content)
        }
        return await sendChannelMessage(
            channelID: channelID,
            content: content,
            replyTo: replyTo,
            replyPreview: replyPreview,
            attachments: attachments,
            clearsComposer: true
        )
    }

    @discardableResult
    private func sendChannelMessage(
        channelID: ChannelID,
        content: String,
        replyTo: MessageID?,
        replyPreview: MessageReplyPreview?,
        attachments: [ForumPostAttachment],
        clearsComposer: Bool
    ) async -> Bool {
        let outgoing = SendMessageDraft(
            channelID: channelID, content: content, replyTo: replyTo, attachments: attachments
        )
        if clearsComposer {
            stopLocalTyping(clearThrottle: true)
        }
        let optimistic = Message(
            id: MessageID(rawValue: UInt64.max - UInt64(messages.count)), channelID: channelID,
            author: snapshot?.currentUser
                ?? User(id: UserID(rawValue: 1), username: "me", displayName: "Me"),
            content: content, replyTo: replyTo, replyPreview: replyPreview,
            attachments: attachments.enumerated().map {
                var presentation = OptimisticAttachmentPresentation.attachment(
                    for: $0.element.url,
                    index: $0.offset
                )
                presentation.filename = $0.element.filename
                presentation.description = $0.element.description
                presentation.isSpoiler = $0.element.isSpoiler
                return presentation
            }, nonce: outgoing.nonce, outboxState: .sending
        )
        appendSelectedMessage(optimistic)
        outgoingDraftsByNonce[outgoing.nonce] = outgoing
        if clearsComposer {
            replyingTo = nil
            updateDraft("")
        }
        let didSend = await performOutgoingSend(outgoing, isRetry: false)
        if didSend {
            completeConversationReadingAndAdvance(channelID: channelID)
        }
        return didSend
    }

    func composerAttachments(
        for destination: MessageComposerDestination
    ) -> [ForumPostAttachment] {
        switch destination {
        case .channel: channelComposerAttachments
        case .thread: threadComposerAttachments
        }
    }

    func isComposerDropEligible(_ destination: MessageComposerDestination) -> Bool {
        switch destination {
        case .channel:
            guard commandComposer.activeCommand == nil,
                  selectedConversationAccess.canSend,
                  let kind = selectedChannel?.kind
            else { return false }
            return Self.supportsTyping(kind)
        case .thread:
            return openThread != nil && openThreadAccess.canSend
        }
    }

    @discardableResult
    func addComposerAttachments(
        _ urls: [URL],
        to destination: MessageComposerDestination
    ) -> Bool {
        guard isComposerDropEligible(destination), !urls.isEmpty else { return false }
        var attachments = composerAttachments(for: destination)
        var seen = Set(attachments.map(\.url.standardizedFileURL))
        let unique = urls.filter { seen.insert($0.standardizedFileURL).inserted }
        let remaining = max(0, SendMessageDraft.maximumAttachmentCount - attachments.count)
        attachments.append(
            contentsOf: unique.prefix(remaining).map { ForumPostAttachment(url: $0) }
        )
        setComposerAttachments(attachments, for: destination)
        if unique.count > remaining {
            errorMessage =
                "You can attach up to \(SendMessageDraft.maximumAttachmentCount) files to one message."
        }
        return remaining > 0 && !unique.isEmpty
    }

    func removeComposerAttachment(
        _ url: URL,
        from destination: MessageComposerDestination
    ) {
        var attachments = composerAttachments(for: destination)
        attachments.removeAll { $0.url.standardizedFileURL == url.standardizedFileURL }
        setComposerAttachments(attachments, for: destination)
    }

    func updateComposerAttachment(
        _ attachment: ForumPostAttachment,
        in destination: MessageComposerDestination
    ) {
        var attachments = composerAttachments(for: destination)
        guard let index = attachments.firstIndex(where: { $0.url == attachment.url }) else {
            return
        }
        attachments[index] = attachment
        setComposerAttachments(attachments, for: destination)
    }

    func toggleComposerAttachmentSpoiler(
        _ url: URL,
        in destination: MessageComposerDestination
    ) {
        var attachments = composerAttachments(for: destination)
        guard let index = attachments.firstIndex(where: { $0.url == url }) else { return }
        attachments[index].isSpoiler.toggle()
        setComposerAttachments(attachments, for: destination)
    }

    func clearComposerAttachments(for destination: MessageComposerDestination) {
        setComposerAttachments([], for: destination)
    }

    func restoreComposerAttachments(
        _ restoredAttachments: [ForumPostAttachment],
        to destination: MessageComposerDestination
    ) {
        let current = composerAttachments(for: destination)
        var seen = Set(current.map(\.url.standardizedFileURL))
        let restored = restoredAttachments.filter {
            seen.insert($0.url.standardizedFileURL).inserted
        }
        setComposerAttachments(
            Array((restored + current).prefix(SendMessageDraft.maximumAttachmentCount)),
            for: destination
        )
    }

    @discardableResult
    func sendAttachmentsImmediately(
        _ attachments: [ForumPostAttachment],
        to destination: MessageComposerDestination
    ) async -> Bool {
        guard isComposerDropEligible(destination), !attachments.isEmpty,
              validateAttachmentCount(attachments)
        else { return false }
        switch destination {
        case .channel:
            guard let channelID = selectedChannelID else { return false }
            return await sendChannelMessage(
                channelID: channelID,
                content: "",
                replyTo: nil,
                replyPreview: nil,
                attachments: attachments,
                clearsComposer: false
            )
        case .thread:
            guard let thread = openThread else { return false }
            return await sendThreadMessage(
                content: "",
                attachments: attachments,
                thread: thread,
                clearsComposer: false
            )
        }
    }

    private func setComposerAttachments(
        _ attachments: [ForumPostAttachment],
        for destination: MessageComposerDestination
    ) {
        switch destination {
        case .channel:
            channelComposerAttachments = attachments
        case .thread:
            threadComposerAttachments = attachments
        }
    }

    private func validateAttachmentCount(_ attachments: [ForumPostAttachment]) -> Bool {
        guard attachments.count <= SendMessageDraft.maximumAttachmentCount else {
            errorMessage =
                "You can attach up to \(SendMessageDraft.maximumAttachmentCount) files to one message."
            return false
        }
        return true
    }

    @discardableResult
    func retrySending(_ message: Message) async -> Bool {
        guard message.outboxState == .failed,
              let nonce = message.nonce,
              outgoingState(nonce: nonce, channelID: message.channelID) == .failed
        else { return false }
        let outgoing =
            outgoingDraftsByNonce[nonce]
                ?? SendMessageDraft(
                    channelID: message.channelID,
                    content: message.content,
                    replyTo: message.replyTo,
                    attachmentURLs: message.attachments.map(\.url),
                    nonce: nonce,
                    stickerIDs: message.stickers.map(\.id)
                )
        outgoingDraftsByNonce[nonce] = outgoing
        updateOutgoingState(.sending, nonce: nonce, channelID: message.channelID)
        return await performOutgoingSend(outgoing, isRetry: true)
    }

    private func performOutgoingSend(_ outgoing: SendMessageDraft, isRetry: Bool) async -> Bool {
        Self.messageSendLogger.info(
            "Message send started channel=\(outgoing.channelID.description, privacy: .public) nonce=\(outgoing.nonce, privacy: .public) attachments=\(outgoing.attachmentURLs.count) stickers=\(outgoing.stickerIDs.count) retry=\(isRetry)"
        )
        do {
            let confirmed = try await provider.send(outgoing)
            reconcileVisibleOrCached(confirmed)
            outgoingDraftsByNonce[outgoing.nonce] = nil
            do {
                try await database?.save(messages: [confirmed])
            } catch {
                let nsError = error as NSError
                Self.messageSendLogger.warning(
                    "Message sent but local persistence failed channel=\(outgoing.channelID.description, privacy: .public) message=\(confirmed.id.description, privacy: .public) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code)"
                )
            }
            Self.messageSendLogger.info(
                "Message send succeeded channel=\(outgoing.channelID.description, privacy: .public) nonce=\(outgoing.nonce, privacy: .public) message=\(confirmed.id.description, privacy: .public) retry=\(isRetry)"
            )
            return true
        } catch {
            let state: OutboxState
            if (error as? URLError)?.code == .timedOut {
                state = .awaitingReconciliation
                updateOutgoingState(state, nonce: outgoing.nonce, channelID: outgoing.channelID)
            } else {
                state = .failed
                outgoingDraftsByNonce[outgoing.nonce] = nil
                removeOutgoingMessage(nonce: outgoing.nonce, channelID: outgoing.channelID)
            }
            errorMessage = error.localizedDescription
            let nsError = error as NSError
            Self.messageSendLogger.error(
                "Message send failed channel=\(outgoing.channelID.description, privacy: .public) nonce=\(outgoing.nonce, privacy: .public) state=\(state.rawValue, privacy: .public) retry=\(isRetry) errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code) details=\(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return false
        }
    }

    func edit(_ message: Message, content: String) async {
        do {
            let updated = try await provider.edit(
                messageID: message.id, channelID: message.channelID, content: content
            )
            reconcileVisibleOrCached(updated)
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ message: Message) async {
        do {
            try await provider.delete(messageID: message.id, channelID: message.channelID)
            if replyingTo?.id == message.id {
                replyingTo = nil
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func dismissEphemeralMessage(_ message: Message) {
        guard message.flags.contains(.ephemeral) else { return }
        if message.channelID == selectedChannelID {
            mutateSelectedMessages {
                $0.removeAll { $0.id == message.id }
            }
        }
        messageCache[message.channelID]?.removeAll { $0.id == message.id }
        Task { try? await database?.deleteMessage(message.id) }
    }

    func toggleReaction(_ emoji: String, on message: Message) async {
        let guildID = message.guildID ?? selectedGuildID
        let currentGuildEmojis = guildID.flatMap { emojisByGuild[$0] } ?? []
        guard
            DiscordEmojiPermissionPolicy.canToggleReaction(
                emoji,
                existingReactions: message.reactions,
                currentGuildEmojis: currentGuildEmojis,
                premiumType: snapshot?.currentUser.premiumType ?? 0
            )
        else {
            errorMessage = "Nitro is required for animated and other-server emoji reactions."
            return
        }
        guard snapshot?.currentUser.id != nil else {
            errorMessage = ChatProviderError.unauthenticated.localizedDescription
            return
        }

        let key = ReactionMutationKey(
            channelID: message.channelID,
            messageID: message.id,
            reactionID: Reaction(emoji: emoji, count: 0).id
        )
        let latestMessage = reactionMessage(for: key) ?? message
        let latestReacted =
            latestMessage.reactions.first(where: { $0.id == key.reactionID })?
                .didCurrentUserReact ?? false
        var state =
            reactionMutations[key]
            ?? ReactionMutationState(
                emoji: emoji,
                confirmedReacted: latestReacted,
                desiredReacted: latestReacted,
                generation: 0,
                isSending: false
            )
        state.emoji = emoji
        state.desiredReacted.toggle()
        state.generation &+= 1
        reactionMutations[key] = state
        applyCurrentUserReactionState(state.desiredReacted, for: key, emoji: emoji)

        if !state.isSending {
            scheduleReactionMutation(for: key)
        }
    }

    private func scheduleReactionMutation(for key: ReactionMutationKey) {
        guard let state = reactionMutations[key], !state.isSending else { return }
        let generation = state.generation
        reactionMutationTasks[key]?.cancel()
        reactionMutationTasks[key] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.reactionMutationDebounce)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.sendReactionMutation(for: key, generation: generation)
        }
    }

    private func sendReactionMutation(
        for key: ReactionMutationKey,
        generation: UInt64
    ) async {
        guard var state = reactionMutations[key],
              state.generation == generation,
              !state.isSending
        else { return }
        reactionMutationTasks[key] = nil
        guard state.desiredReacted != state.confirmedReacted else {
            reactionMutations[key] = nil
            return
        }

        let sentState = state.desiredReacted
        state.isSending = true
        reactionMutations[key] = state
        do {
            try await provider.setReaction(
                state.emoji,
                reacted: sentState,
                messageID: key.messageID,
                channelID: key.channelID
            )
        } catch {
            guard let latest = reactionMutations[key] else { return }
            applyCurrentUserReactionState(
                latest.confirmedReacted,
                for: key,
                emoji: latest.emoji
            )
            reactionMutations[key] = nil
            reactionMutationTasks[key] = nil
            if let message = reactionMessage(for: key) {
                persist(message)
            }
            errorMessage = error.localizedDescription
            return
        }

        guard var latest = reactionMutations[key] else { return }
        latest.confirmedReacted = sentState
        latest.isSending = false
        applyCurrentUserReactionState(
            latest.desiredReacted,
            for: key,
            emoji: latest.emoji
        )
        if latest.desiredReacted == latest.confirmedReacted {
            reactionMutations[key] = nil
            reactionMutationTasks[key] = nil
            if let message = reactionMessage(for: key) {
                persist(message)
            }
        } else {
            reactionMutations[key] = latest
            if let message = reactionMessage(for: key) {
                persist(reactionConfirmedSnapshot(message))
            }
            scheduleReactionMutation(for: key)
        }
    }

    private func reactionMessage(for key: ReactionMutationKey) -> Message? {
        if key.channelID == selectedChannelID,
           let index = selectedMessageIndex(for: key.messageID),
           messages.indices.contains(index)
        {
            return messages[index]
        }
        if key.channelID == openThread?.id,
           let message = threadMessages.first(where: { $0.id == key.messageID })
        {
            return message
        }
        if let message = messageCache[key.channelID]?.first(where: { $0.id == key.messageID }) {
            return message
        }
        if let forumIndex = forumCatalogueIndexByID[key.channelID] {
            let post = forumCataloguePosts[forumIndex]
            if post.firstMessage?.id == key.messageID {
                return post.firstMessage
            }
            if post.mostRecentMessage?.id == key.messageID {
                return post.mostRecentMessage
            }
        }
        return nil
    }

    private func knownReactionReactor(for userID: UserID) -> ReactionReactor? {
        if let member = membersByID[userID] {
            return ReactionReactor(
                id: userID,
                displayName: member.user.displayName,
                avatarURL: member.guildAvatarURL ?? member.user.avatarURL
            )
        }
        guard snapshot?.currentUser.id == userID, let user = snapshot?.currentUser else {
            return nil
        }
        return ReactionReactor(user: user)
    }

    private func applyCurrentUserReactionState(
        _ reacted: Bool,
        for key: ReactionMutationKey,
        emoji: String
    ) {
        guard let currentUserID = snapshot?.currentUser.id else { return }
        let update: MessageReactionUpdate =
            reacted
            ? .add(
                channelID: key.channelID,
                messageID: key.messageID,
                userID: currentUserID,
                emoji: emoji,
                kind: .normal
            )
            : .remove(
                channelID: key.channelID,
                messageID: key.messageID,
                userID: currentUserID,
                emoji: emoji,
                kind: .normal
            )
        applyReactionUpdate(update, persistsResult: false)
    }

    func loadReactionReactors(_ reaction: Reaction, on message: Message) async {
        guard reaction.count > 0, reaction.reactors.isEmpty else { return }
        guard await waitForTimelineScrollingToEnd() else { return }
        let key = ReactionReactorLoadKey(
            channelID: message.channelID,
            messageID: message.id,
            reactionID: reaction.id
        )
        if let failedAt = failedReactionReactorLoads[key],
           Date.now.timeIntervalSince(failedAt) < 30
        {
            return
        }
        guard loadingReactionReactors.insert(key).inserted else { return }
        defer { loadingReactionReactors.remove(key) }

        do {
            let provider = self.provider
            let reactors = try await reactionReactorLoadLimiter.withPermit {
                try await provider.reactionReactors(
                    for: reaction.emoji,
                    messageID: message.id,
                    channelID: message.channelID,
                    reactionCount: reaction.count
                )
            }
            guard await waitForTimelineScrollingToEnd() else { return }
            failedReactionReactorLoads[key] = nil
            applyReactionReactors(reactors, for: key)
        } catch is CancellationError {
            return
        } catch {
            if failedReactionReactorLoads.count >= 256,
               let oldest = failedReactionReactorLoads.min(by: { $0.value < $1.value })?.key
            {
                failedReactionReactorLoads[oldest] = nil
            }
            failedReactionReactorLoads[key] = .now
        }
    }

    func reportTimelineLiveScrolling(
        _ isScrolling: Bool,
        conversationID: ChannelID
    ) {
        let wasScrolling = !liveScrollingConversationIDs.isEmpty
        if isScrolling {
            liveScrollingConversationIDs.insert(conversationID)
        } else {
            liveScrollingConversationIDs.remove(conversationID)
        }
        let isScrollingNow = !liveScrollingConversationIDs.isEmpty
        guard wasScrolling != isScrollingNow else { return }
        if !isScrollingNow {
            flushUnreadPresentationRefresh()
        }
    }

    private func waitForTimelineScrollingToEnd() async -> Bool {
        while !liveScrollingConversationIDs.isEmpty {
            do {
                try await Task.sleep(for: .milliseconds(40))
            } catch {
                return false
            }
        }
        return !Task.isCancelled
    }

    private func resetTimelineLiveScrolling() {
        liveScrollingConversationIDs.removeAll(keepingCapacity: true)
        flushUnreadPresentationRefresh()
    }

    private func applyReactionReactors(
        _ reactors: [ReactionReactor],
        for key: ReactionReactorLoadKey
    ) {
        var seen: Set<UserID> = []
        let normalized = reactors.filter { seen.insert($0.id).inserted }.prefix(5)

        func updating(_ values: [Message]) -> [Message] {
            guard let messageIndex = values.firstIndex(where: { $0.id == key.messageID }) else {
                return values
            }
            var result = values
            result[messageIndex] = updating(result[messageIndex])
            return result
        }

        func updating(_ message: Message) -> Message {
            guard
                let reactionIndex = message.reactions.firstIndex(where: {
                    $0.id == key.reactionID && $0.count > 0
                })
            else { return message }
            var result = message
            var seen = Set<UserID>()
            let merged =
                normalized + result.reactions[reactionIndex].reactors
            result.reactions[reactionIndex].reactors = Array(
                merged
                    .filter { seen.insert($0.id).inserted }
                    .prefix(min(5, max(0, result.reactions[reactionIndex].count)))
            )
            return result
        }

        if key.channelID == selectedChannelID {
            replaceSelectedMessages(with: updating(messages))
        } else if var cached = messageCache[key.channelID] {
            cached = updating(cached)
            messageCache[key.channelID] = cached
        }
        if key.channelID == openThread?.id {
            threadMessages = updating(threadMessages)
        }

        guard let forumIndex = forumCatalogueIndexByID[key.channelID] else { return }
        var forumPost = forumCataloguePosts[forumIndex]
        if let firstMessage = forumPost.firstMessage {
            forumPost.firstMessage = updating(firstMessage)
        }
        if let mostRecentMessage = forumPost.mostRecentMessage {
            forumPost.mostRecentMessage = updating(mostRecentMessage)
        }
        guard forumPost != forumCataloguePosts[forumIndex] else { return }
        forumCataloguePosts[forumIndex] = forumPost
        updateForumPresentation(with: forumPost)
    }

    private func clearReactionReactorLoadState(
        channelID: ChannelID,
        messageID: MessageID
    ) {
        loadingReactionReactors = Set(
            loadingReactionReactors.filter {
                $0.channelID != channelID || $0.messageID != messageID
            })
        failedReactionReactorLoads = failedReactionReactorLoads.filter {
            $0.key.channelID != channelID || $0.key.messageID != messageID
        }
    }

    private func clearReactionMutationState(
        channelID: ChannelID? = nil,
        messageID: MessageID? = nil
    ) {
        let keys = reactionMutations.keys.filter { key in
            (channelID == nil || key.channelID == channelID)
                && (messageID == nil || key.messageID == messageID)
        }
        for key in keys {
            reactionMutationTasks[key]?.cancel()
            reactionMutationTasks[key] = nil
            reactionMutations[key] = nil
        }
    }

    private func applyReactionUpdate(
        _ update: MessageReactionUpdate,
        persistsResult: Bool = true
    ) {
        let currentUserID = snapshot?.currentUser.id
        let reactor: ReactionReactor? =
            switch update {
            case .add(_, _, let userID, _, _):
                knownReactionReactor(for: userID)
            case .remove, .removeAll, .removeEmoji:
                nil
            }
        var messageToPersist: Message?

        func applying(to values: inout [Message]) {
            guard
                let index = values.firstIndex(where: {
                    $0.id == update.messageID && $0.channelID == update.channelID
                })
            else {
                return
            }
            var message = values[index]
            if message.applyReactionUpdate(
                update,
                currentUserID: currentUserID,
                reactor: reactor
            ) {
                values[index] = message
            }
            messageToPersist = message
        }

        if update.channelID == selectedChannelID {
            var updated = messages
            applying(to: &updated)
            if updated != messages {
                replaceSelectedMessages(with: updated)
            }
        }
        if var cached = messageCache[update.channelID] {
            applying(to: &cached)
            messageCache[update.channelID] = cached
        }
        if update.channelID == openThread?.id {
            applying(to: &threadMessages)
        }

        if let forumIndex = forumCatalogueIndexByID[update.channelID] {
            var post = forumCataloguePosts[forumIndex]
            if var firstMessage = post.firstMessage, firstMessage.id == update.messageID {
                if firstMessage.applyReactionUpdate(
                    update,
                    currentUserID: currentUserID,
                    reactor: reactor
                ) {
                    post.firstMessage = firstMessage
                }
                messageToPersist = firstMessage
            }
            if var mostRecentMessage = post.mostRecentMessage,
               mostRecentMessage.id == update.messageID
            {
                if mostRecentMessage.applyReactionUpdate(
                    update,
                    currentUserID: currentUserID,
                    reactor: reactor
                ) {
                    post.mostRecentMessage = mostRecentMessage
                }
                messageToPersist = mostRecentMessage
            }
            if post != forumCataloguePosts[forumIndex] {
                forumCataloguePosts[forumIndex] = post
                updateForumPresentation(with: post)
            }
        }

        if persistsResult {
            for (key, mutation) in reactionMutations
            where key.channelID == update.channelID && key.messageID == update.messageID {
                applyCurrentUserReactionState(
                    mutation.desiredReacted,
                    for: key,
                    emoji: mutation.emoji
                )
            }
            let lookupKey = ReactionMutationKey(
                channelID: update.channelID,
                messageID: update.messageID,
                reactionID: ""
            )
            messageToPersist = reactionMessage(for: lookupKey) ?? messageToPersist
        }

        if persistsResult, let messageToPersist {
            persist(reactionConfirmedSnapshot(messageToPersist))
        }
    }

    func updateStatus(_ status: PresenceStatus) async {
        do {
            try await provider.updateStatus(status)
            currentStatus = status
            members = members.map { member in
                guard member.user.id == snapshot?.currentUser.id else { return member }
                var updatedMember = member
                updatedMember.status = status
                return updatedMember
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func joinVoice(_ channel: Channel) async {
        guard channel.kind == .voice
                || channel.kind == .directMessage
                || channel.kind == .groupDirectMessage
        else { return }
        if activeVoiceChannel?.id == channel.id,
           voiceSessionState == .connected || voiceSessionState == .connecting
        {
            return
        }
        await leaveVoice()
        activeVoiceChannel = channel
        reconcilePrivateCallSounds()
        voiceSessionState = .connecting
        voiceErrorMessage = nil
        do {
            let info = try await provider.joinVoice(
                channelID: channel.id,
                guildID: channel.guildID,
                selfMute: isVoiceMuted,
                selfDeaf: isVoiceDeafened
            )
            try await startVoiceSession(with: info)
            soundPlayer.play(.userJoin)
        } catch {
            voiceEventTask?.cancel()
            voiceEventTask = nil
            await voiceSession?.disconnect()
            voiceSessionState = .failed
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
            try? await provider.updateVoiceState(
                channelID: nil,
                guildID: channel.guildID,
                selfMute: false,
                selfDeaf: false,
                selfVideo: false
            )
            activeVoiceChannel = nil
            voiceSession = nil
            reconcilePrivateCallSounds()
        }
    }

    func observePrivateCall(in channel: Channel) async {
        guard channel.kind == .directMessage || channel.kind == .groupDirectMessage else {
            return
        }
        do {
            try await provider.subscribeToPrivateCall(channelID: channel.id)
        } catch {
            // Observation is opportunistic while the Gateway is reconnecting.
            // Connection-ready reconciliation will subscribe again.
        }
    }

    func startPrivateCall(in channel: Channel, withVideo: Bool = false) async {
        guard channel.kind == .directMessage || channel.kind == .groupDirectMessage,
              !channel.isOfficialSystemDirectMessage
        else { return }

        if privateCall(in: channel.id) != nil {
            await joinPrivateCall(in: channel, withVideo: withVideo)
            return
        }

        do {
            try await provider.subscribeToPrivateCall(channelID: channel.id)
            let shouldRing: Bool
            if channel.kind == .groupDirectMessage {
                shouldRing = true
            } else {
                shouldRing = try await provider.privateCallIsRingable(
                    channelID: channel.id
                )
            }
            await joinVoice(channel)
            guard activeVoiceChannel?.id == channel.id,
                  voiceSessionState == .connected
            else { return }
            if withVideo, !isCameraEnabled {
                await toggleCamera()
            }
            if shouldRing {
                beginLocalOutgoingPrivateCallRing(channelID: channel.id)
                do {
                    try await provider.ringPrivateCall(
                        channelID: channel.id,
                        recipients: nil
                    )
                } catch {
                    endLocalOutgoingPrivateCallRing(channelID: channel.id)
                    // Joining succeeded and is not replayed. Surface the bounded
                    // ring failure without turning it into a second call action.
                    voiceErrorMessage = error.localizedDescription
                    errorMessage = error.localizedDescription
                }
            }
        } catch {
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    func joinPrivateCall(in channel: Channel, withVideo: Bool = false) async {
        guard channel.kind == .directMessage || channel.kind == .groupDirectMessage,
              !channel.isOfficialSystemDirectMessage
        else { return }
        do {
            try await provider.subscribeToPrivateCall(channelID: channel.id)
            await joinVoice(channel)
            if withVideo,
               activeVoiceChannel?.id == channel.id,
               voiceSessionState == .connected,
               !isCameraEnabled
            {
                await toggleCamera()
            }
        } catch {
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    func acceptPrivateCall(_ call: PrivateCall) async {
        guard let channel = snapshot?.channels.first(where: { $0.id == call.channelID })
                ?? visibleChannels.first(where: { $0.id == call.channelID })
        else { return }
        if selectedChannelID != channel.id {
            selectedGuildID = nil
            selectedChannelID = channel.id
        }
        await joinPrivateCall(in: channel)
    }

    func declinePrivateCall(_ call: PrivateCall) async {
        guard let currentUserID = snapshot?.currentUser.id else { return }
        do {
            try await provider.stopRingingPrivateCall(
                channelID: call.channelID,
                recipients: [currentUserID]
            )
            if var updated = privateCallsByChannel[call.channelID] {
                updated.ongoingRings.removeAll { $0.recipientID == currentUserID }
                privateCallsByChannel[call.channelID] = updated
                reconcilePrivateCallSounds()
            }
        } catch {
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    private func reconcilePrivateCallVoiceState(_ state: VoiceParticipantState) {
        if let channelID = state.channelID, var call = privateCallsByChannel[channelID] {
            var states = call.voiceStates ?? []
            states.removeAll { $0.userID == state.userID }
            states.append(state)
            call.voiceStates = states
            privateCallsByChannel[channelID] = call
        } else if state.channelID == nil {
            for (channelID, var call) in privateCallsByChannel {
                call.voiceStates?.removeAll { $0.userID == state.userID }
                privateCallsByChannel[channelID] = call
            }
        }
    }

    private func beginLocalOutgoingPrivateCallRing(channelID: ChannelID) {
        locallyStartedOutgoingPrivateCallRings.insert(channelID)
        outgoingPrivateCallRingTimeoutTasks[channelID]?.cancel()
        outgoingPrivateCallRingTimeoutTasks[channelID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(45))
            } catch {
                return
            }
            self?.endLocalOutgoingPrivateCallRing(channelID: channelID)
        }
        reconcilePrivateCallSounds()
    }

    private func endLocalOutgoingPrivateCallRing(channelID: ChannelID) {
        locallyStartedOutgoingPrivateCallRings.remove(channelID)
        outgoingPrivateCallRingTimeoutTasks.removeValue(forKey: channelID)?.cancel()
        reconcilePrivateCallSounds()
    }

    private func reconcilePrivateCallSounds() {
        let state = PrivateCallSoundState.make(
            calls: privateCallsByChannel.values,
            currentUserID: snapshot?.currentUser.id,
            activeChannelID: activeVoiceChannel?.id,
            locallyStartedOutgoingChannelIDs:
                locallyStartedOutgoingPrivateCallRings
        )
        soundPlayer.setLooping(.callRinging, active: state.ringsIncoming)
        soundPlayer.setLooping(.callCalling, active: state.ringsOutgoing)
    }

    private func resetAppSounds() {
        for task in outgoingPrivateCallRingTimeoutTasks.values {
            task.cancel()
        }
        outgoingPrivateCallRingTimeoutTasks = [:]
        locallyStartedOutgoingPrivateCallRings = []
        soundPlayer.stopAll()
    }

    func leaveVoice() async {
        let channel = activeVoiceChannel
        let guildID = channel?.guildID
        let hadActiveVoice = channel != nil
        if let channelID = channel?.id {
            endLocalOutgoingPrivateCallRing(channelID: channelID)
        }
        voiceMigrationGeneration &+= 1
        voiceMigrationTask?.cancel()
        voiceMigrationTask = nil
        voiceEventTask?.cancel()
        voiceEventTask = nil
        await voiceSession?.disconnect()
        voiceSession = nil
        if activeVoiceChannel != nil {
            try? await provider.updateVoiceState(
                channelID: nil,
                guildID: guildID,
                selfMute: false,
                selfDeaf: false,
                selfVideo: false
            )
        }
        activeVoiceChannel = nil
        voiceParticipants = []
        isLocallySpeaking = false
        voiceVideoFrames = [:]
        if let ownUserID = snapshot?.currentUser.id {
            voiceStates[ownUserID] = nil
        }
        voiceEncryptionVersion = nil
        voiceLatencyMilliseconds = nil
        voiceSessionState = .idle
        isCameraEnabled = false
        reconcilePrivateCallSounds()
        if hadActiveVoice {
            soundPlayer.play(.disconnect)
        }
    }

    func toggleVoiceMute() async {
        isVoiceMuted.toggle()
        UserDefaults.standard.set(isVoiceMuted, forKey: "voiceMuted")
        await voiceSession?.setMuted(isVoiceMuted)
        await publishVoiceState()
        if activeVoiceChannel != nil {
            soundPlayer.play(isVoiceMuted ? .mute : .unmute)
        }
    }

    func toggleVoiceDeafen() async {
        isVoiceDeafened.toggle()
        UserDefaults.standard.set(isVoiceDeafened, forKey: "voiceDeafened")
        await voiceSession?.setDeafened(isVoiceDeafened)
        await publishVoiceState()
        if activeVoiceChannel != nil {
            soundPlayer.play(isVoiceDeafened ? .deafen : .undeafen)
        }
    }

    func toggleCamera() async {
        let enabled = !isCameraEnabled
        if voiceSession == nil {
            isCameraEnabled = enabled
            await publishVoiceState()
            if activeVoiceChannel != nil {
                soundPlayer.play(enabled ? .cameraOn : .cameraOff)
            }
            return
        }
        do {
            try await voiceSession?.setCameraEnabled(enabled)
            isCameraEnabled = enabled
            if !enabled, let ownUserID = snapshot?.currentUser.id {
                voiceVideoFrames[String(ownUserID.rawValue)] = nil
            }
            try await provider.updateVoiceState(
                channelID: activeVoiceChannel?.id,
                guildID: activeVoiceChannel?.guildID,
                selfMute: isVoiceMuted,
                selfDeaf: isVoiceDeafened,
                selfVideo: enabled
            )
            soundPlayer.play(enabled ? .cameraOn : .cameraOff)
        } catch {
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    func selectCamera(_ camera: CameraDeviceInfo?) async {
        UserDefaults.standard.set(camera?.uniqueID, forKey: "voiceCameraUID")
        do { try await voiceSession?.selectCamera(uniqueID: camera?.uniqueID) } catch {
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    func updateInputVolume(_ value: Float) async {
        inputVolume = min(max(value, 0), 2)
        UserDefaults.standard.set(Double(inputVolume), forKey: "voiceInputVolume")
        await voiceSession?.setInputVolume(inputVolume)
    }

    func updateOutputVolume(_ value: Float) async {
        outputVolume = min(max(value, 0), 2)
        UserDefaults.standard.set(Double(outputVolume), forKey: "voiceOutputVolume")
        await voiceSession?.setOutputVolume(outputVolume)
    }

    func selectInputDevice(_ device: AudioDeviceInfo?) async {
        UserDefaults.standard.set(device?.uid, forKey: "voiceInputDeviceUID")
        do { try await voiceSession?.selectInputDevice(device?.id) } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectOutputDevice(_ device: AudioDeviceInfo?) async {
        UserDefaults.standard.set(device?.uid, forKey: "voiceOutputDeviceUID")
        do { try await voiceSession?.selectOutputDevice(device?.id) } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateParticipantVolume(_ value: Float, userID: String) async {
        await voiceSession?.setParticipantVolume(value, userID: userID)
    }

    func refreshMediaDevices() async {
        mediaDevices = await Task.detached(priority: .userInitiated) {
            MediaDeviceCatalog.snapshot()
        }.value
    }

    private func publishVoiceState() async {
        guard let activeVoiceChannel else { return }
        do {
            try await provider.updateVoiceState(
                channelID: activeVoiceChannel.id,
                guildID: activeVoiceChannel.guildID,
                selfMute: isVoiceMuted,
                selfDeaf: isVoiceDeafened,
                selfVideo: isCameraEnabled
            )
        } catch {
            voiceErrorMessage = error.localizedDescription
        }
    }

    private func selectedAudioDeviceID(defaultsKey: String, devices: [AudioDeviceInfo])
        -> AudioDeviceID?
    {
        guard let uid = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        return devices.first(where: { $0.uid == uid })?.id
    }

    private func currentVoiceConfiguration() -> VoiceSessionConfiguration {
        let outputDeviceID = selectedAudioDeviceID(
            defaultsKey: "voiceOutputDeviceUID",
            devices: mediaDevices.audioOutputs
        )
        return VoiceSessionConfiguration(
            inputDeviceID: resolvedInputDeviceID(),
            outputDeviceID: outputDeviceID,
            inputVolume: inputVolume,
            outputVolume: outputVolume,
            isMuted: isVoiceMuted,
            isDeafened: isVoiceDeafened,
            cameraUniqueID: UserDefaults.standard.string(forKey: "voiceCameraUID")
        )
    }

    private func resolvedInputDeviceID() -> AudioDeviceID? {
        if let storedUID = UserDefaults.standard.string(forKey: "voiceInputDeviceUID"),
           !storedUID.isEmpty
        {
            return mediaDevices.audioInputs.first(where: { $0.uid == storedUID })?.id
        }

        let defaultInput = mediaDevices.audioInputs.first(where: \.isDefault)
        // Automatic capture must not inherit a Bluetooth call route or a
        // silent virtual/aggregate device. Explicit selections remain honored.
        if defaultInput?.isBluetooth == true || defaultInput?.isVirtual == true,
           let builtIn = mediaDevices.audioInputs.first(where: \.isBuiltIn)
        {
            return builtIn.id
        }
        return nil
    }

    private func startVoiceSession(with info: VoiceConnectionInfo) async throws {
        if info.endpoint == "mock.sakuracord.invalid" {
            voiceSessionState = .connected
            return
        }

        let session = DiscordVoiceSession(
            info: info,
            configuration: currentVoiceConfiguration(),
            gatewayDiagnostics: VoiceGatewayDiagnostics { direction, data in
                DiscordAPIDiagnosticStore.shared.recordWebSocketData(
                    transport: "voice_gateway",
                    direction: direction.rawValue,
                    data: data
                )
            }
        )
        voiceSession = session
        voiceEventTask?.cancel()
        voiceEventTask = Task { [weak self] in
            for await event in session.events {
                guard !Task.isCancelled else { return }
                self?.consumeVoiceEvent(event)
            }
        }
        try await session.connect()
    }

    private func scheduleVoiceServerMigration(to info: VoiceConnectionInfo?) {
        voiceMigrationGeneration &+= 1
        let generation = voiceMigrationGeneration
        voiceMigrationTask?.cancel()
        voiceMigrationTask = Task { [weak self] in
            await self?.migrateVoiceServer(to: info, generation: generation)
        }
    }

    private func migrateVoiceServer(to info: VoiceConnectionInfo?, generation: Int) async {
        guard activeVoiceChannel != nil, generation == voiceMigrationGeneration else { return }
        let cameraWasEnabled = isCameraEnabled

        voiceEventTask?.cancel()
        voiceEventTask = nil
        await voiceSession?.disconnect()
        guard !Task.isCancelled, generation == voiceMigrationGeneration else { return }

        voiceSession = nil
        voiceParticipants = []
        voiceVideoFrames = [:]
        voiceEncryptionVersion = nil
        voiceLatencyMilliseconds = nil
        isCameraEnabled = false
        voiceSessionState = .reconnecting

        guard let info else { return }
        guard info.channelID == activeVoiceChannel?.id else { return }

        do {
            try await startVoiceSession(with: info)
            guard !Task.isCancelled, generation == voiceMigrationGeneration else {
                await voiceSession?.disconnect()
                return
            }
            if cameraWasEnabled, voiceSession != nil {
                try await voiceSession?.setCameraEnabled(true)
                isCameraEnabled = true
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == voiceMigrationGeneration else { return }
            voiceSessionState = .failed
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    private func consumeVoiceEvent(_ event: VoiceSessionEvent) {
        switch event {
        case .stateChanged(let state):
            voiceSessionState = state
        case .latencyUpdated(let milliseconds):
            voiceLatencyMilliseconds = milliseconds
        case .participantChanged(let participant):
            if let index = voiceParticipants.firstIndex(where: { $0.userID == participant.userID }) {
                voiceParticipants[index] = participant
            } else {
                voiceParticipants.append(participant)
            }
            voiceParticipants.sort { $0.userID < $1.userID }
            if let userID = UserID(participant.userID), var state = voiceStates[userID] {
                state.isVideoEnabled = participant.isCameraEnabled
                voiceStates[userID] = state
            }
        case .participantLeft(let userID):
            voiceParticipants.removeAll { $0.userID == userID }
            voiceVideoFrames[userID] = nil
        case .localSpeakingChanged(let speaking):
            isLocallySpeaking = speaking
        case .encryptionReady(let version):
            voiceEncryptionVersion = version
        case .videoFrame(let userID, let frame):
            voiceVideoFrames[userID] = frame
        case .videoStopped(let userID):
            voiceVideoFrames[userID] = nil
        case .error(let message):
            voiceErrorMessage = message
        }
    }

    func selectMember(_ member: Member) {
        if selectedMember?.id == member.id, isInspectorProfilePresented {
            dismissInspectorProfile()
            return
        }
        isInspectorProfilePresented = true
        if selectedMember?.id == member.id {
            return
        }
        presentProfile(for: member, destination: .inspector)
    }

    func showProfile(for user: User) {
        let member =
            membersByID[user.id]
                ?? Member(user: user, roleName: "Member", status: .offline)
        presentProfile(for: member, destination: .contextual)
    }

    func showInspectorProfile(for user: User) {
        isInspectorProfilePresented = true
        let member =
            membersByID[user.id]
                ?? Member(
                    user: user,
                    roleName: "Direct Message",
                    status: .offline
                )
        presentProfile(for: member, destination: .inspector)
    }

    func authorPresentation(for message: Message) -> MessageAuthorPresentation {
        MessageAuthorPresentation.resolve(
            message: message,
            member: membersByID[message.author.id],
            roles: guildRoles
        )
    }

    private func presentProfile(
        for member: Member,
        destination: ProfilePresentationDestination
    ) {
        let requestID = UUID()
        let guildID = selectedGuildID
        let cacheKey = ProfileCacheKey(
            userID: member.id,
            guildID: guildID
        )
        let cachedProfile = profileCache[cacheKey].map {
            profile($0, applyingPresenceFrom: member)
        }
        let presentation = ProfilePresentationState(
            requestID: requestID,
            member: member,
            profile: cachedProfile,
            isLoading: cachedProfile == nil,
            errorMessage: nil
        )
        switch destination {
        case .inspector:
            inspectorProfileTask?.cancel()
            inspectorProfilePresentation = presentation
        case .contextual:
            contextualProfileTask?.cancel()
            contextualProfilePresentation = presentation
        }
        guard cachedProfile == nil else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await provider.profile(
                    for: member.id,
                    in: guildID
                )
                guard !Task.isCancelled,
                      selectedGuildID == guildID,
                      profilePresentation(
                          for: destination
                      )?.requestID == requestID
                else {
                    return
                }
                profileCache[cacheKey] = loaded
                var value = profilePresentation(for: destination)
                value?.member = member
                value?.profile = profile(
                    loaded,
                    applyingPresenceFrom: member
                )
                value?.isLoading = false
                value?.errorMessage = nil
                setProfilePresentation(value, for: destination)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      profilePresentation(
                          for: destination
                      )?.requestID == requestID
                else { return }
                var value = profilePresentation(for: destination)
                value?.isLoading = false
                value?.errorMessage = error.localizedDescription
                setProfilePresentation(value, for: destination)
            }
        }
        switch destination {
        case .inspector:
            inspectorProfileTask = task
        case .contextual:
            contextualProfileTask = task
        }
    }

    func dismissInspectorProfile() {
        inspectorProfileTask?.cancel()
        inspectorProfileTask = nil
        inspectorProfilePresentation = nil
        isInspectorProfilePresented = false
    }

    func dismissContextualProfile(for userID: UserID? = nil) {
        if let userID,
           contextualProfilePresentation?.member.id != userID
        {
            return
        }
        contextualProfileTask?.cancel()
        contextualProfileTask = nil
        contextualProfilePresentation = nil
    }

    private func dismissAllProfiles(clearsCache: Bool = false) {
        dismissInspectorProfile()
        dismissContextualProfile()
        if clearsCache {
            profileCache.removeAll(keepingCapacity: false)
        }
    }

    private func profilePresentation(
        for destination: ProfilePresentationDestination
    ) -> ProfilePresentationState? {
        switch destination {
        case .inspector:
            inspectorProfilePresentation
        case .contextual:
            contextualProfilePresentation
        }
    }

    private func setProfilePresentation(
        _ value: ProfilePresentationState?,
        for destination: ProfilePresentationDestination
    ) {
        switch destination {
        case .inspector:
            inspectorProfilePresentation = value
        case .contextual:
            contextualProfilePresentation = value
        }
    }

    private func profile(
        _ value: UserProfile,
        applyingPresenceFrom member: Member
    ) -> UserProfile {
        var result = value
        result.status = member.status
        result.customStatus = member.customStatus
        return result
    }

    func dismissError() {
        errorMessage = nil
    }

    private func storedMessages(in channelID: ChannelID) async -> [Message] {
        await (try? database?.messages(in: channelID)) ?? []
    }

    private func storedDraft(in channelID: ChannelID) async -> String {
        await (try? database?.draft(channelID: channelID)) ?? ""
    }

    private func isCurrentLoad(_ channelID: ChannelID, generation: Int) -> Bool {
        !Task.isCancelled && selectedChannelID == channelID && channelLoadGeneration == generation
    }

    private static func merging(current: [Message], fresh: [Message]) -> [Message] {
        var byID: [MessageID: Message] = [:]
        var idByNonce: [String: MessageID] = [:]
        for message in current {
            byID[message.id] = message
            if let nonce = message.nonce {
                idByNonce[nonce] = message.id
            }
        }
        for message in fresh {
            var resolved = message
            let matchingID = message.nonce.flatMap { idByNonce[$0] }
            if let existing = byID[message.id] ?? matchingID.flatMap({ byID[$0] }) {
                resolved.replyTo = resolved.replyTo ?? existing.replyTo
                resolved.replyPreview = resolved.replyPreview ?? existing.replyPreview
            }
            if let matchingID, matchingID != resolved.id {
                byID[matchingID] = nil
            }
            byID[resolved.id] = resolved
            if let nonce = resolved.nonce {
                idByNonce[nonce] = resolved.id
            }
        }
        return byID.values.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.id < rhs.id
        }
    }

    func isChannelUnread(_ channelID: ChannelID) -> Bool {
        readState.unread(channelID: channelID)
    }

    func isForumPostUnread(_ post: ForumPost) -> Bool {
        readState.entries[post.id]?.isUnread ?? post.isUnread
    }

    func isForumPostNew(_ post: ForumPost) -> Bool {
        readState.isNewForumPost(post)
    }

    func shouldEmphasizeForumPost(_ post: ForumPost) -> Bool {
        isForumPostUnread(post) || readState.isUnopenedForumPost(post)
    }

    func forumUnreadMessageCount(_ post: ForumPost) -> Int {
        guard isForumPostUnread(post) else { return 0 }
        return readState.unreadMessageCount(channelID: post.id)
    }

    func channelMentionCount(_ channelID: ChannelID) -> Int {
        readState.mentions(channelID: channelID)
    }

    var directMessageUnread: Bool {
        readState.directMessageUnread()
    }

    var directMessageMentionCount: Int {
        readState.directMessageMentions
    }

    func reportMainWindowActive(_ isActive: Bool) {
        mainWindowIsActive = isActive
        if let selectedChannelID {
            preserveUnreadDividerIfNeeded(channelID: selectedChannelID)
            if let target = readState.updatePresentation(
                channelID: selectedChannelID,
                windowIsActive: isActive
            ) {
                scheduleAcknowledgement(channelID: selectedChannelID, messageID: target)
            }
        }
        if let threadID = openThread?.id {
            preserveUnreadDividerIfNeeded(channelID: threadID)
            if let target = readState.updatePresentation(
                channelID: threadID,
                windowIsActive: isActive
            ) {
                scheduleAcknowledgement(channelID: threadID, messageID: target)
            }
        }
    }

    func reportTimelinePosition(channelID: ChannelID, isAtNewest: Bool) {
        guard channelID == selectedChannelID || channelID == openThread?.id else { return }
        preserveUnreadDividerIfNeeded(channelID: channelID)
        if let target = readState.updatePresentation(
            channelID: channelID,
            isPresented: true,
            isAtNewest: isAtNewest
        ) {
            scheduleAcknowledgement(channelID: channelID, messageID: target)
        }
    }

    func reportTimelineInitialPosition(channelID: ChannelID, isAtNewest: Bool) {
        guard channelID == selectedChannelID || channelID == openThread?.id else { return }
        preserveUnreadDividerIfNeeded(channelID: channelID)
        if let target = readState.updatePresentation(
            channelID: channelID,
            isPresented: true,
            initialPositionEstablished: true,
            isAtNewest: isAtNewest
        ) {
            scheduleAcknowledgement(channelID: channelID, messageID: target)
        }
    }

    func reportTimelineUserInteraction(channelID: ChannelID) {
        guard channelID == selectedChannelID || channelID == openThread?.id else { return }
        readState.unblockAutomaticAcknowledgement(channelID: channelID)
    }

    func reportConversationHistoryLoaded(channelID: ChannelID) {
        guard channelID == selectedChannelID || channelID == openThread?.id else { return }
        preserveUnreadDividerIfNeeded(channelID: channelID)
        if let target = readState.updatePresentation(
            channelID: channelID,
            isPresented: true,
            initialHistoryLoaded: true
        ) {
            scheduleAcknowledgement(channelID: channelID, messageID: target)
        }
    }

    func timelineUnreadSummary(
        channelID: ChannelID,
        messages: [Message],
        hasMoreBefore: Bool
    ) -> AccountReadStateModel.TimelineUnreadSummary? {
        readState.timelineUnreadSummary(
            channelID: channelID,
            messages: messages,
            hasMoreBefore: hasMoreBefore
        )
    }

    func unreadDividerMessageID(channelID: ChannelID) -> MessageID? {
        unreadDividerMessageIDs[channelID]
    }

    func markConversationRead(channelID: ChannelID) {
        guard channelID == selectedChannelID || channelID == openThread?.id,
              let target = readState.entries[channelID]?.latestKnownMessageID
        else { return }
        preserveUnreadDividerIfNeeded(channelID: channelID)
        acknowledgementTasks[channelID]?.cancel()
        acknowledgementTasks[channelID] = nil
        queuedAcknowledgements[channelID] = nil
        acknowledgementQueueOrder.removeAll { $0 == channelID }
        readState.unblockAutomaticAcknowledgement(channelID: channelID)
        readState.markAcknowledgementPending(channelID: channelID, messageID: target)
        refreshUnreadPresentation()
        cancelNativeNotifications(channelID: channelID)
        enqueueAcknowledgement(
            channelID: channelID,
            mutation: readStateMutation(
                channelID: channelID,
                messageID: target,
                manual: false,
                mentionCount: nil
            )
        )
    }

    func completeConversationReadingAndAdvance(channelID: ChannelID) {
        guard channelID == selectedChannelID || channelID == openThread?.id else { return }
        markConversationRead(channelID: channelID)
        unreadDividerMessageIDs[channelID] = nil
        conversationNewestRequestID &+= 1
        conversationNewestRequest = ConversationNewestRequest(
            requestID: conversationNewestRequestID,
            channelID: channelID
        )
    }

    private func preserveUnreadDividerIfNeeded(channelID: ChannelID) {
        guard unreadDividerMessageIDs[channelID] == nil else { return }
        let conversationMessages: [Message]
        let hasMoreBefore: Bool
        if channelID == openThread?.id {
            conversationMessages = threadMessages
            hasMoreBefore = hasMoreThreadMessages
                || (isLoadingThread && !threadMessages.isEmpty)
        } else if channelID == selectedChannelID {
            conversationMessages = messages
            hasMoreBefore = hasMoreMessages
                || (isLoadingMessages && !messages.isEmpty)
        } else {
            return
        }
        guard let summary = readState.timelineUnreadSummary(
            channelID: channelID,
            messages: conversationMessages,
            hasMoreBefore: hasMoreBefore
        ), !summary.isLowerBound
        else { return }
        unreadDividerMessageIDs[channelID] = summary.firstUnreadMessageID
    }

    func markMessageAndFollowingUnread(_ message: Message) {
        let channelID = message.channelID
        guard channelID == selectedChannelID || channelID == openThread?.id,
              message.id.rawValue > 0,
              let currentUserID = snapshot?.currentUser.id
        else { return }
        let conversationMessages =
            channelID == openThread?.id ? threadMessages : messages
        let mentionCount = readState.mentionCountForManualUnread(
            channelID: channelID,
            messages: conversationMessages,
            startingAt: message.id,
            currentUserID: currentUserID
        )
        let target = MessageID(rawValue: message.id.rawValue - 1)
        acknowledgementTasks[channelID]?.cancel()
        acknowledgementTasks[channelID] = nil
        queuedAcknowledgements[channelID] = nil
        acknowledgementQueueOrder.removeAll { $0 == channelID }
        readState.markUnread(
            channelID: channelID,
            after: target,
            mentionCount: mentionCount
        )
        // "Mark Unread" identifies the exact first-new row. Publish that
        // anchor in the same transaction instead of waiting for a later
        // timeline geometry callback to infer it from read state.
        unreadDividerMessageIDs[channelID] = message.id
        refreshUnreadPresentation()
        enqueueAcknowledgement(
            channelID: channelID,
            mutation: readStateMutation(
                channelID: channelID,
                messageID: target,
                manual: true,
                mentionCount: mentionCount
            )
        )
    }

    func requestNotificationPermission() async -> Bool {
        (try? await notificationService.requestAuthorization()) ?? false
    }

    private func requestNotificationPermissionIfNeeded() async {
        guard notificationPreferences.isEnabled,
              await notificationService.authorizationStatus() == .notDetermined
        else { return }
        _ = try? await notificationService.requestAuthorization()
    }

    func notificationAuthorizationStatus() async -> UNAuthorizationStatus {
        await notificationService.authorizationStatus()
    }

    func refreshDockBadge() {
        notificationService.setDockBadge(
            readState.totalMentions,
            enabled: notificationPreferences.showsDockBadge
        )
    }

    private func acknowledgeIfEligible(channelID: ChannelID) {
        guard let target = readState.updatePresentation(channelID: channelID) else { return }
        scheduleAcknowledgement(channelID: channelID, messageID: target)
    }

    private func acknowledgeForumVisitIfNeeded(channelID: ChannelID, now: Date = .now) {
        guard selectedChannelID == channelID,
              selectedChannel?.kind == .forum,
              readState.shouldAcknowledgeForumVisit(channelID: channelID),
              let target = Self.forumAcknowledgementBoundary(at: now)
        else { return }
        readState.markAcknowledgementPending(channelID: channelID, messageID: target)
        refreshUnreadPresentation()
        cancelNativeNotifications(channelID: channelID)
        enqueueAcknowledgement(
            channelID: channelID,
            mutation: readStateMutation(
                channelID: channelID,
                messageID: target,
                manual: false,
                mentionCount: nil
            )
        )
    }

    private nonisolated static func forumAcknowledgementBoundary(at date: Date) -> MessageID? {
        let milliseconds = UInt64(max(0, date.timeIntervalSince1970 * 1_000))
        guard milliseconds >= ClientNonce.discordEpochMilliseconds else { return nil }
        return MessageID(
            rawValue: (milliseconds - ClientNonce.discordEpochMilliseconds) << 22
        )
    }

    private func scheduleAcknowledgement(channelID: ChannelID, messageID: MessageID) {
        if let pending = readState.entries[channelID]?.pendingAcknowledgementID,
           pending >= messageID
        {
            return
        }
        acknowledgementTasks[channelID]?.cancel()
        readState.markAcknowledgementPending(channelID: channelID, messageID: messageID)
        refreshUnreadPresentation()
        cancelNativeNotifications(channelID: channelID)
        let debounce = readAcknowledgementTiming.debounce
        acknowledgementTasks[channelID] = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
                guard let self, !Task.isCancelled else { return }
                self.enqueueAcknowledgement(
                    channelID: channelID,
                    mutation: self.readStateMutation(
                        channelID: channelID,
                        messageID: messageID,
                        manual: false,
                        mentionCount: nil
                    )
                )
                self.acknowledgementTasks[channelID] = nil
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func enqueueAcknowledgement(
        channelID: ChannelID,
        mutation: ReadStateMutation
    ) {
        if let queued = queuedAcknowledgements[channelID] {
            if mutation.manual || !queued.manual {
                queuedAcknowledgements[channelID] =
                    mutation.manual
                    ? mutation
                    : ReadStateMutation(
                        messageID: max(queued.messageID, mutation.messageID),
                        manual: false,
                        mentionCount: nil,
                        flags: mutation.flags,
                        lastViewed: mutation.lastViewed
                    )
            }
        } else {
            queuedAcknowledgements[channelID] = mutation
            acknowledgementQueueOrder.append(channelID)
        }
        guard acknowledgementProcessorTask == nil else { return }
        let generation = acknowledgementGeneration
        acknowledgementProcessorTask = Task { [weak self] in
            await self?.drainAcknowledgementQueue(generation: generation)
        }
    }

    private func drainAcknowledgementQueue(generation: Int) async {
        while !Task.isCancelled,
              generation == acknowledgementGeneration,
              let channelID = acknowledgementQueueOrder.first
        {
            acknowledgementQueueOrder.removeFirst()
            guard let mutation = queuedAcknowledgements.removeValue(forKey: channelID) else {
                continue
            }
            do {
                let response = try await provider.acknowledge(
                    channelID: channelID,
                    messageID: mutation.messageID,
                    token: readState.acknowledgementToken,
                    manual: mutation.manual,
                    mentionCount: mutation.mentionCount,
                    flags: mutation.flags,
                    lastViewed: mutation.lastViewed
                )
                guard !Task.isCancelled, generation == acknowledgementGeneration else { return }
                readState.completeAcknowledgement(
                    channelID: channelID,
                    messageID: mutation.messageID,
                    token: response.token
                )
            } catch is CancellationError {
                return
            } catch {
                guard generation == acknowledgementGeneration else { return }
                readState.failAcknowledgement(
                    channelID: channelID,
                    messageID: mutation.messageID
                )
                refreshUnreadPresentation()
                if mutation.manual {
                    errorMessage = "Discord did not accept the read-state update."
                }
            }
        }
        if generation == acknowledgementGeneration {
            acknowledgementProcessorTask = nil
        }
    }

    private func readStateMutation(
        channelID: ChannelID,
        messageID: MessageID,
        manual: Bool,
        mentionCount: Int?
    ) -> ReadStateMutation {
        let metadata = readState.acknowledgementMetadata(channelID: channelID)
        return ReadStateMutation(
            messageID: messageID,
            manual: manual,
            mentionCount: mentionCount,
            flags: metadata.flags,
            lastViewed: metadata.lastViewed
        )
    }

    private func resetAcknowledgementWork() {
        acknowledgementGeneration &+= 1
        acknowledgementTasks.values.forEach { $0.cancel() }
        acknowledgementTasks.removeAll()
        acknowledgementProcessorTask?.cancel()
        acknowledgementProcessorTask = nil
        queuedAcknowledgements.removeAll()
        acknowledgementQueueOrder.removeAll()
    }

    private func refreshUnreadPresentation() {
        guard var value = snapshot else {
            notificationService.setDockBadge(
                readState.totalMentions,
                enabled: notificationPreferences.showsDockBadge
            )
            return
        }
        reconcileChannelAccessibility(value.channels)
        let projectedChannels = value.channels.map { channel in
            var channel = channel
            channel.unreadCount =
                channel.kind == .forum
                ? readState.forumNewPostCount(channelID: channel.id)
                : (readState.unread(channelID: channel.id) ? 1 : 0)
            channel.mentionCount = readState.mentions(channelID: channel.id)
            return channel
        }
        let projectedGuilds = value.guilds.map { guild in
            var guild = guild
            guild.unreadCount = readState.guildUnread(guild.id) ? 1 : 0
            guild.mentionCount = readState.guildMentions(guild.id)
            return guild
        }
        if UnreadPresentationPublicationPolicy.shouldPublish(
            snapshot: value,
            channels: projectedChannels,
            guilds: projectedGuilds
        ) {
            value.channels = projectedChannels
            value.guilds = projectedGuilds
            snapshot = value
        }
        let projectedGuildsByID = Dictionary(
            uniqueKeysWithValues: projectedGuilds.map { ($0.id, $0) }
        )
        if projectedGuildsByID != serverRailGuildsByID {
            serverRailGuildsByID = projectedGuildsByID
        }
        let selectedGuildChannels: [Channel]
        if let selectedGuildID {
            selectedGuildChannels = projectedChannels.filter {
                $0.guildID == selectedGuildID && conversationAccess(for: $0) != .hidden
            }
        } else {
            selectedGuildChannels = projectedChannels.filter {
                $0.guildID == nil && conversationAccess(for: $0) != .hidden
            }
        }
        if selectedGuildChannels != visibleChannels {
            visibleChannels = selectedGuildChannels
        }
        if let selectedChannelID,
           !selectedGuildChannels.contains(where: { $0.id == selectedChannelID })
        {
            self.selectedChannelID = Self.preferredInitialChannelID(
                in: selectedGuildChannels
            )
        }
        let projectedSelectedChannel =
            selectedChannelID.flatMap { id in
                projectedChannels.first { $0.id == id }
            }
                ?? selectedChannel
        if projectedSelectedChannel != selectedChannel {
            selectedChannel = projectedSelectedChannel
        }
        notificationService.setDockBadge(
            readState.totalMentions,
            enabled: notificationPreferences.showsDockBadge
        )
    }

    private func reconcileChannelAccessibility(_ channels: [Channel]) {
        for channel in channels {
            switch conversationAccess(for: channel) {
            case .hidden:
                readState.setAccessible(false, channelID: channel.id)
            case .readable:
                readState.setAccessible(true, channelID: channel.id)
            case .checking:
                break
            }
        }
    }

    private func deliverNativeNotification(for message: Message) {
        // The offline timeline benchmark measures event ingestion, layout,
        // drawing, and scroll scheduling. Enqueuing thousands of synthetic
        // UNUserNotificationCenter requests measures an unrelated XPC queue
        // and eventually starves the main run loop in periodic bursts.
        guard !runsChatPerformanceBenchmark else { return }
        guard !readState.isActivelyPresentedAtNewest(message.channelID) else { return }
        let channel =
            snapshot?.channels.first { $0.id == message.channelID }
                ?? visibleChannels.first { $0.id == message.channelID }
        let guildID = message.guildID ?? channel?.guildID
        let guild = guildID.flatMap { serverRailGuildsByID[$0] }
        let accountID = readState.accountID ?? "offline"
        if notificationPreferences.isEnabled,
           notificationPreferences.playsSound,
           !notificationPreferences.isQuiet()
        {
            // Apple's notification sound facility does not support MP3. Play
            // Discord's exact message asset through the same retained audio
            // path as the voice sounds, and let Notification Center own only
            // the banner/list presentation.
            soundPlayer.play(.message)
        }
        Task {
            await notificationService.deliver(
                message: message,
                channel: channel,
                guild: guild,
                accountID: accountID,
                preferences: notificationPreferences
            )
        }
    }

    private func cancelNativeNotifications(channelID: ChannelID) {
        guard !runsChatPerformanceBenchmark else { return }
        let accountID = readState.accountID ?? "offline"
        Task {
            await notificationService.cancel(accountID: accountID, channelID: channelID)
        }
    }

    private func consume(_ event: ClientEvent) async {
        if case let .messageCreated(message) = event {
            let preparedTextPlan: NativeTimelineTextPlan? =
                if message.channelID == selectedChannelID {
                    await Task.detached(priority: .utility) {
                        NativeTimelineTextPlan.make(for: message)
                    }.value
                } else {
                    nil
                }
            guard !Task.isCancelled else { return }
            pendingCreatedMessages.append(
                PreparedCreatedMessage(
                    message: message,
                    textPlan: preparedTextPlan
                )
            )
            guard createdMessageFlushTask == nil else { return }
            createdMessageFlushTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(8))
                } catch {
                    return
                }
                self?.flushPendingCreatedMessages(
                    maximumCount: self?.maximumCreatedMessagesPerFlush ?? 4
                )
            }
            return
        }
        flushPendingCreatedMessages()
        let preparedTextPlan: NativeTimelineTextPlan? =
            if case let .messageUpdated(message) = event,
               message.channelID == selectedChannelID
            {
                await Task.detached(priority: .userInitiated) {
                    NativeTimelineTextPlan.make(for: message)
                }.value
            } else {
                nil
        }
        guard !Task.isCancelled else { return }
        consumeImmediately(event, preparedTextPlan: preparedTextPlan)
    }

    private func flushPendingCreatedMessages(
        maximumCount: Int = .max
    ) {
        guard !pendingCreatedMessages.isEmpty else {
            createdMessageFlushTask = nil
            return
        }
        createdMessageFlushTask?.cancel()
        createdMessageFlushTask = nil
        let flushCount = min(
            max(1, maximumCount),
            pendingCreatedMessages.count
        )
        let pending = Array(pendingCreatedMessages.prefix(flushCount))
        pendingCreatedMessages.removeFirst(flushCount)
        isFlushingCreatedMessageBatch = true
        for prepared in pending {
            consumeImmediately(
                .messageCreated(prepared.message),
                preparedTextPlan: prepared.textPlan
            )
        }
        commitBatchedSelectedMessages()
        isFlushingCreatedMessageBatch = false
        flushBatchedCreatedMessageSideEffects()
        if !pendingCreatedMessages.isEmpty {
            // A display or AppKit transaction can occasionally delay the
            // eight-millisecond timer long enough for dozens of gateway
            // creates to accumulate. Never turn that scheduling delay into
            // one giant main-actor layout burst; drain bounded chunks while
            // yielding between them.
            createdMessageFlushTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled else { return }
                self.flushPendingCreatedMessages(
                    maximumCount: self.maximumCreatedMessagesPerFlush
                )
            }
        }
    }

    private func resetPendingCreatedMessages() {
        createdMessageFlushTask?.cancel()
        createdMessageFlushTask = nil
        pendingCreatedMessages.removeAll(keepingCapacity: false)
        batchedSelectedMessages.removeAll(keepingCapacity: false)
        batchedSelectedTextPlansByID.removeAll(keepingCapacity: false)
        batchedUnreadPresentationNeedsRefresh = false
        batchedAcknowledgementChannelIDs.removeAll(keepingCapacity: false)
        isFlushingCreatedMessageBatch = false
    }

    private func flushBatchedCreatedMessageSideEffects() {
        if batchedUnreadPresentationNeedsRefresh {
            batchedUnreadPresentationNeedsRefresh = false
            requestUnreadPresentationRefresh()
        }
        let acknowledgementChannelIDs = batchedAcknowledgementChannelIDs
        batchedAcknowledgementChannelIDs.removeAll(keepingCapacity: true)
        for channelID in acknowledgementChannelIDs {
            acknowledgeIfEligible(channelID: channelID)
        }
    }

    private func consumeImmediately(
        _ event: ClientEvent,
        preparedTextPlan: NativeTimelineTextPlan? = nil
    ) {
        switch event {
        case .connectionChanged(let state):
            connectionState = state
            if state != .ready {
                stopLocalTyping(clearThrottle: true)
                typingState.clearAll()
                resetAcknowledgementWork()
            } else if let channel = selectedChannel,
                      channel.kind == .directMessage || channel.kind == .groupDirectMessage
            {
                Task { [weak self] in
                    await self?.observePrivateCall(in: channel)
                }
            }
        case .emojisChanged(let guildID, let emojis):
            applyEmojis(emojis, to: guildID)
        case .emojisUpdated(let guildID, let upserted, let deletedIDs):
            applyEmojiUpdate(upserted: upserted, deletedIDs: deletedIDs, to: guildID)
        case .messageCreated(var message):
            typingState.clear(userID: message.author.id, in: message.channelID)
            if let nonce = message.nonce {
                commandComposer.enrichInteractionResponse(
                    &message, currentUser: snapshot?.currentUser
                )
                commandComposer.interactionSucceeded(nonce: nonce)
            }
            persist(message)
            if message.channelID == openThread?.id {
                reconcileThread(message)
            }
            if message.channelID == selectedChannelID {
                reconcile(
                    message,
                    preparedTextPlan: preparedTextPlan
                )
            } else {
                cache(message)
            }
            reconcileForumMessage(message)
            if let currentUserID = snapshot?.currentUser.id {
                let disposition = readState.receive(message, currentUserID: currentUserID)
                if disposition.accepted {
                    if message.channelID == selectedChannelID
                        || message.channelID == openThread?.id
                    {
                        preserveUnreadDividerIfNeeded(channelID: message.channelID)
                    }
                    if isFlushingCreatedMessageBatch {
                        batchedUnreadPresentationNeedsRefresh = true
                    } else {
                        refreshUnreadPresentation()
                    }
                    if disposition.shouldNotify {
                        deliverNativeNotification(for: message)
                    }
                    if isFlushingCreatedMessageBatch {
                        batchedAcknowledgementChannelIDs.insert(
                            message.channelID
                        )
                    } else {
                        acknowledgeIfEligible(channelID: message.channelID)
                    }
                }
            }
        case .messageUpdated(let incoming):
            let message = reactionPresentationPreserving(incoming)
            persist(reactionConfirmedSnapshot(message))
            if message.channelID == openThread?.id {
                reconcileThreadUpdate(message)
            }
            if message.channelID == selectedChannelID {
                reconcileSelectedMessageUpdate(
                    message,
                    preparedTextPlan: preparedTextPlan
                )
            } else {
                reconcileCachedMessageUpdate(message)
            }
            reconcileForumMessage(message)
        case .messageReactionUpdated(let update):
            applyReactionUpdate(update)
        case .messageDeleted(let channelID, let messageID):
            clearReactionReactorLoadState(channelID: channelID, messageID: messageID)
            clearReactionMutationState(channelID: channelID, messageID: messageID)
            Task { try? await database?.deleteMessage(messageID) }
            if replyingTo?.id == messageID {
                replyingTo = nil
            }
            if channelID == openThread?.id {
                threadMessages.removeAll { $0.id == messageID }
            }
            if channelID == selectedChannelID {
                removeSelectedMessage(id: messageID)
            } else {
                messageCache[channelID]?.removeAll { $0.id == messageID }
            }
        case .readStateSnapshot(let states):
            resetAcknowledgementWork()
            readState.replaceReadStates(states)
            if let selectedChannelID {
                _ = readState.updatePresentation(
                    channelID: selectedChannelID,
                    isPresented: true,
                    initialHistoryLoaded: !isLoadingMessages && messageLoadError == nil,
                    windowIsActive: mainWindowIsActive
                )
            }
            if let threadID = openThread?.id {
                _ = readState.updatePresentation(
                    channelID: threadID,
                    isPresented: true,
                    initialHistoryLoaded: !isLoadingThread && threadErrorMessage == nil,
                    windowIsActive: mainWindowIsActive
                )
            }
            refreshUnreadPresentation()
            if let selectedChannelID { acknowledgeIfEligible(channelID: selectedChannelID) }
            if let threadID = openThread?.id { acknowledgeIfEligible(channelID: threadID) }
        case .readStateChanged(let state):
            if readState.applyRemote(state) {
                refreshUnreadPresentation()
                if !readState.unread(channelID: state.channelID) {
                    cancelNativeNotifications(channelID: state.channelID)
                }
            }
        case .notificationModeChanged(let usesNewNotifications):
            readState.updateNotificationMode(
                usesNewNotifications: usesNewNotifications
            )
            if var value = snapshot {
                value.usesNewNotifications = usesNewNotifications
                snapshot = value
            }
            refreshUnreadPresentation()
        case .notificationSettingsChanged(let settings):
            readState.apply(settings)
            refreshUnreadPresentation()
        case .typing(let channelID, let user):
            typingState.receive(
                channelID: channelID,
                user: user,
                currentUserID: snapshot?.currentUser.id
            )
        case .channelsChanged(let guildID, let channels):
            if var value = snapshot {
                value.channels.removeAll { $0.guildID == guildID }
                value.channels.append(contentsOf: channels)
                snapshot = value
            }
            if guildID == selectedGuildID {
                visibleChannels = channels
                if let selectedChannelID {
                    if let updated = channels.first(where: { $0.id == selectedChannelID }) {
                        selectedChannel = updated
                    } else if guildID == nil {
                        self.selectedChannelID = channels.first?.id
                    }
                }
            }
            readState.replaceChannels(in: guildID, with: channels)
            refreshUnreadPresentation()
        case .forumPostsChanged(let channelID, let posts):
            readState.replaceThreads(parentID: channelID, with: posts.map(\.thread))
            refreshUnreadPresentation()
            guard channelID == selectedChannelID, selectedChannel?.kind == .forum else { return }
            replaceForumCatalogue(with: posts)
            applyForumPresentation()
            if let openThread, openThread.parentID == channelID,
               !posts.contains(where: { $0.id == openThread.id })
            {
                closeThread()
            }
        case .forumPostPreviewsChanged(let channelID, let posts):
            for post in posts { readState.merge(thread: post.thread) }
            refreshUnreadPresentation()
            guard channelID == selectedChannelID, selectedChannel?.kind == .forum else { return }
            mergeForumCatalogue(posts)
            applyForumPresentation()
        case .forumPageLoaded(let channelID, let query, let page):
            for post in page.posts { readState.merge(thread: post.thread) }
            refreshUnreadPresentation()
            guard channelID == selectedChannelID,
                  selectedChannel?.kind == .forum,
                  forumSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  query
                  == ForumPostQuery(
                      scope: .active,
                      sortOrder: forumSortOrder,
                      selectedTagIDs: forumSelectedTagIDs,
                      tagMatch: forumTagMatch,
                      offset: 0,
                      limit: 25
                  )
            else { return }
            replaceForumCatalogue(with: page.posts)
            applyForumPresentation()
            forumNextOffset = page.nextOffset
            hasMoreForumPosts = page.hasMore
        case .membersChanged(let guildID, let value):
            if let currentUserID = snapshot?.currentUser.id,
               let currentMember = value.first(where: { $0.id == currentUserID })
            {
                let roleIDs = Set(currentMember.roles.map(\.id))
                currentUserRoleIDsByGuild[guildID] = roleIDs
                readState.updateCurrentUserRoles(roleIDs, guildID: guildID)
                refreshUnreadPresentation()
            }
            guard guildID == selectedGuildID else { return }
            members = value
            if mentionAutocompleteMembers.isEmpty {
                // A guild activation can finish before Discord's lazy member
                // list has delivered its first store snapshot. Seed the
                // dedicated autocomplete store from that first Gateway update
                // instead of leaving every nonempty @ query blank.
                mentionAutocompleteMembers = value
            } else {
                // Refresh already-known values (nickname/avatar/roles) without
                // letting later visual member-list sorting reorder or expand
                // the autocomplete store.
                let updatesByID = Dictionary(
                    value.map { ($0.id, $0) },
                    uniquingKeysWith: { _, newer in newer }
                )
                mentionAutocompleteMembers = mentionAutocompleteMembers.map {
                    updatesByID[$0.id] ?? $0
                }
            }
            if let selectedMember,
               let updated = value.first(where: {
                   $0.id == selectedMember.id
               })
            {
                inspectorProfilePresentation?.member = updated
                if var profile = inspectorProfilePresentation?.profile {
                    profile.status = updated.status
                    profile.customStatus = updated.customStatus
                    inspectorProfilePresentation?.profile = profile
                }
            }
            if let contextualMember =
                contextualProfilePresentation?.member,
               let updated = value.first(where: {
                   $0.id == contextualMember.id
               })
            {
                contextualProfilePresentation?.member = updated
                if var profile = contextualProfilePresentation?.profile {
                    profile.status = updated.status
                    profile.customStatus = updated.customStatus
                    contextualProfilePresentation?.profile = profile
                }
            }
        case .privateMembersChanged(let value):
            guard selectedGuildID == nil else { return }
            members = value
        case .currentUserRolesChanged(let guildID, let roleIDs):
            let roleIDs = Set(roleIDs)
            currentUserRoleIDsByGuild[guildID] = roleIDs
            readState.updateCurrentUserRoles(roleIDs, guildID: guildID)
            refreshUnreadPresentation()
        case .voiceStateChanged(let state):
            let previous = voiceStates[state.userID]
            let effects = VoiceStateSoundPolicy.effects(
                previous: previous,
                current: state,
                activeChannelID: activeVoiceChannel?.id,
                currentUserID: snapshot?.currentUser.id
            )
            if state.channelID == nil {
                voiceStates[state.userID] = nil
            } else {
                voiceStates[state.userID] = state
            }
            if !state.isVideoEnabled {
                voiceVideoFrames[String(state.userID.rawValue)] = nil
            }
            if state.guildID == nil {
                reconcilePrivateCallVoiceState(state)
            }
            for effect in effects {
                soundPlayer.play(effect)
            }
        case .privateCallChanged(var call):
            if call.voiceStates == nil {
                call.voiceStates = privateCallsByChannel[call.channelID]?.voiceStates
            }
            privateCallsByChannel[call.channelID] = call
            if let currentUserID = snapshot?.currentUser.id,
               call.ongoingRings.contains(where: {
                   $0.senderID == currentUserID
                       && $0.recipientID != currentUserID
               })
            {
                endLocalOutgoingPrivateCallRing(channelID: call.channelID)
            } else {
                reconcilePrivateCallSounds()
            }
        case .privateCallDeleted(let channelID, let unavailable):
            if unavailable, var call = privateCallsByChannel[channelID] {
                call.isUnavailable = true
                call.ongoingRings = []
                privateCallsByChannel[channelID] = call
            } else {
                privateCallsByChannel[channelID] = nil
                if activeVoiceChannel?.id == channelID {
                    Task { [weak self] in
                        await self?.leaveVoice()
                    }
                }
            }
            endLocalOutgoingPrivateCallRing(channelID: channelID)
        case .voiceServerChanged(let info):
            scheduleVoiceServerMigration(to: info)
        case .snapshotChanged(let value):
            snapshot = value
            readState.configure(
                accountID: readState.accountID,
                guilds: value.guilds,
                channels: value.channels,
                readStates: value.readStates,
                notificationSettings: value.notificationSettings,
                usesNewNotifications: value.usesNewNotifications
            )
            for thread in value.threads {
                readState.merge(thread: thread)
            }
            updateServerRail(from: value)
            selectGuild(selectedGuildID)
        case .guildChanged(let guild):
            guard var value = snapshot,
                  let index = value.guilds.firstIndex(where: { $0.id == guild.id })
            else { return }
            value.guilds[index] = guild
            snapshot = value
            readState.merge(guilds: [guild])
        case .guildLayoutChanged(let guilds, let railItems):
            guard var value = snapshot else { return }
            value.guilds = guilds
            value.guildRailItems = railItems
            snapshot = value
            readState.retainGuilds(Set(guilds.map(\.id)))
            readState.merge(guilds: guilds)
            updateServerRail(from: value)
        case .applicationCommandIndexInvalidated(let target):
            if commandComposer.invalidated(target) {
                loadApplicationCommands()
            }
        case .applicationCommandAutocomplete(let result):
            commandComposer.receiveAutocomplete(result)
        case .interaction(let event):
            switch event {
            case .created(let nonce, let interactionID):
                commandComposer.interactionCreated(
                    nonce: nonce, interactionID: interactionID
                )
            case .succeeded(let nonce):
                commandComposer.interactionSucceeded(nonce: nonce)
                if let key = componentKeyByNonce.removeValue(forKey: nonce) {
                    pendingComponentControls.remove(key)
                    componentErrors[key] = nil
                }
                interactionErrorMessage = nil
            case .failed(let nonce, let message):
                let commandHandled = commandComposer.interactionFailed(
                    nonce: nonce, message: message
                )
                if let key = componentKeyByNonce.removeValue(forKey: nonce) {
                    pendingComponentControls.remove(key)
                    componentErrors[key] = message
                } else if !commandHandled {
                    interactionErrorMessage = message
                }
            case .presentModal(let nonce, let modal):
                interactionModalNonce = nonce
                if let key = componentKeyByNonce.removeValue(forKey: nonce) {
                    pendingComponentControls.remove(key)
                }
                presentedInteractionModal = modal
                interactionErrorMessage = nil
            }
        }
    }

    private func updateServerRail(from snapshot: BootstrapSnapshot) {
        serverRailGuildsByID = Dictionary(uniqueKeysWithValues: snapshot.guilds.map { ($0.id, $0) })
        serverRailItems = snapshot.guildRailItems
    }

    private func reconcile(
        _ message: Message,
        preparedTextPlan: NativeTimelineTextPlan? = nil
    ) {
        if message.nonce == nil,
           let index = selectedMessageIndex(for: message.id)
        {
            replaceSelectedMessage(
                message,
                at: index,
                preparedTextPlan: preparedTextPlan
            )
            return
        }
        let previousMessage = batchedSelectedMessages.last ?? messages.last
        if message.nonce == nil,
           previousMessage.map({
               $0.id < message.id && !Self.messagePrecedes(message, $0)
           }) ?? true
        {
            if isFlushingCreatedMessageBatch {
                batchedSelectedMessages.append(message)
                if let preparedTextPlan {
                    batchedSelectedTextPlansByID[message.id] =
                        preparedTextPlan
                }
            } else {
                appendSelectedMessage(
                    message,
                    preparedTextPlan: preparedTextPlan
                )
            }
            return
        }
        commitBatchedSelectedMessages()
        var updated = messages
        var resolved = message
        let replacementIndex =
            message.nonce.flatMap { nonce in
                updated.firstIndex(where: { $0.nonce == nonce })
            } ?? selectedMessageIndex(for: message.id)
        if let index = replacementIndex {
            resolved.replyTo = resolved.replyTo ?? updated[index].replyTo
            resolved.replyPreview = resolved.replyPreview ?? updated[index].replyPreview
            updated.remove(at: index)
            if let duplicateIndex = updated.firstIndex(where: { $0.id == resolved.id }) {
                updated.remove(at: duplicateIndex)
            }
            Self.insert(resolved, intoSorted: &updated)
        } else {
            Self.insert(resolved, intoSorted: &updated)
        }
        if updated != messages {
            replaceSelectedMessages(with: updated)
        }
    }

    private func reconcileSelectedMessageUpdate(
        _ message: Message,
        preparedTextPlan: NativeTimelineTextPlan? = nil
    ) {
        commitBatchedSelectedMessages()
        guard let index = selectedMessageIndex(for: message.id) else { return }
        replaceSelectedMessage(
            message,
            at: index,
            preparedTextPlan: preparedTextPlan
        )
    }

    private func replaceSelectedMessage(
        _ incoming: Message,
        at index: Int,
        preparedTextPlan: NativeTimelineTextPlan? = nil
    ) {
        guard messages.indices.contains(index),
              messageRows.indices.contains(index)
        else { return }
        var resolved = incoming
        resolved.replyTo = resolved.replyTo ?? messages[index].replyTo
        resolved.replyPreview =
            resolved.replyPreview ?? messages[index].replyPreview
        guard resolved != messages[index] else { return }
        let previousReplyTarget = messages[index].replyTo
        if previousReplyTarget != resolved.replyTo {
            if let previousReplyTarget {
                selectedReplyMessageIDsByTarget[previousReplyTarget]?.remove(
                    resolved.id
                )
                if selectedReplyMessageIDsByTarget[previousReplyTarget]?.isEmpty
                    == true
                {
                    selectedReplyMessageIDsByTarget[previousReplyTarget] = nil
                }
            }
            if let replyTarget = resolved.replyTo {
                selectedReplyMessageIDsByTarget[
                    replyTarget,
                    default: []
                ].insert(resolved.id)
            }
        }
        messages[index] = resolved
        let changedIndexes = MessageGrouping.reconcileChangedMessage(
            id: resolved.id,
            replacement: resolved,
            messages: messages,
            availableMessageIDs: selectedMessageIDs,
            rows: &messageRows,
            messageIndex: selectedMessageIndex(for:),
            replyingMessageIDs:
                selectedReplyMessageIDsByTarget[resolved.id] ?? [],
            replacementTextPlan: preparedTextPlan
        )
        publishMessageRowsUpdate(
            change: .replace(changedIndexes),
            changedMessageIDs: Set(changedIndexes.map { messageRows[$0].id })
        )
        messageRowsNonAppendRevision &+= 1
    }

    private func removeSelectedMessage(id: MessageID) {
        guard let index = selectedMessageIndex(for: id),
              messageRows.indices.contains(index)
        else { return }
        let removedReplyTarget = messages[index].replyTo
        messages.remove(at: index)
        messageRows.remove(at: index)
        selectedMessageIDs.remove(id)
        selectedMessageStoredIndexByID[id] = nil
        if index < messages.endIndex {
            for shiftedIndex in index ..< messages.endIndex {
                setSelectedMessageIndex(
                    shiftedIndex,
                    for: messages[shiftedIndex].id
                )
            }
        }
        if let removedReplyTarget {
            selectedReplyMessageIDsByTarget[removedReplyTarget]?.remove(id)
            if selectedReplyMessageIDsByTarget[removedReplyTarget]?.isEmpty
                == true
            {
                selectedReplyMessageIDsByTarget[removedReplyTarget] = nil
            }
        }
        let changedIndexes = MessageGrouping.reconcileChangedMessage(
            id: id,
            replacement: nil,
            messages: messages,
            availableMessageIDs: selectedMessageIDs,
            rows: &messageRows,
            neighborIndex: index,
            messageIndex: selectedMessageIndex(for:),
            replyingMessageIDs:
                selectedReplyMessageIDsByTarget[id] ?? []
        )
        publishMessageRowsUpdate(
            change: .remove(
                removedIndexes: IndexSet(integer: index),
                changedIndexes: changedIndexes
            ),
            changedMessageIDs: Set(changedIndexes.map { messageRows[$0].id }),
            removedMessageIDs: [id]
        )
        messageRowsNonAppendRevision &+= 1
    }

    private func publishMessageRowsUpdate(
        change: MessageRowsUpdateHint.Change? = nil,
        insertedMessageIDs: [MessageID] = [],
        changedMessageIDs: Set<MessageID> = [],
        removedMessageIDs: Set<MessageID> = [],
        invalidatesAllRows: Bool = false
    ) {
        let nextRevision = latestMessageRowsRevision &+ 1
        latestMessageRowsRevision = nextRevision
        messageRowsUpdateHint = change.map {
            MessageRowsUpdateHint(revision: nextRevision, change: $0)
        }
        messageRowsUpdateJournal.append(
            MessageRowsUpdateRecord(
                revision: nextRevision,
                change: change,
                insertedMessageIDs: insertedMessageIDs,
                changedMessageIDs: changedMessageIDs,
                removedMessageIDs: removedMessageIDs,
                invalidatesAllRows: invalidatesAllRows
            )
        )
        messageRowsRevision = nextRevision
        NotificationCenter.default.post(
            name: .sakuracordMessageRowsDidChange,
            object: self
        )
    }

    private func requestUnreadPresentationRefresh() {
        guard !liveScrollingConversationIDs.isEmpty else {
            refreshUnreadPresentation()
            return
        }
        guard unreadPresentationRefreshTask == nil else { return }
        unreadPresentationRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            self?.flushUnreadPresentationRefresh()
        }
    }

    private func flushUnreadPresentationRefresh() {
        unreadPresentationRefreshTask?.cancel()
        unreadPresentationRefreshTask = nil
        refreshUnreadPresentation()
    }

    private func selectedMessageIndex(for id: MessageID) -> Int? {
        selectedMessageStoredIndexByID[id].map {
            $0 - selectedMessageIndexOrigin
        }
    }

    private func setSelectedMessageIndex(
        _ index: Int,
        for id: MessageID
    ) {
        selectedMessageStoredIndexByID[id] =
            index + selectedMessageIndexOrigin
    }

    private func rebuildSelectedMessageIndexes() {
        selectedMessageIDs = Set(messages.lazy.map(\.id))
        selectedMessageIndexOrigin = 0
        selectedMessageStoredIndexByID.removeAll(keepingCapacity: true)
        selectedMessageStoredIndexByID.reserveCapacity(messages.count)
        selectedReplyMessageIDsByTarget.removeAll(keepingCapacity: true)
        for (index, message) in messages.enumerated() {
            setSelectedMessageIndex(index, for: message.id)
            if let replyTarget = message.replyTo {
                selectedReplyMessageIDsByTarget[
                    replyTarget,
                    default: []
                ].insert(message.id)
            }
        }
    }

    private func replaceSelectedMessages(with newMessages: [Message]) {
        let oldMessages = messages
        messages = newMessages
        rebuildSelectedMessageIndexes()
        messageRows = MessageGrouping.updating(
            existing: messageRows,
            oldMessages: oldMessages,
            newMessages: newMessages
        )
        publishMessageRowsUpdate(invalidatesAllRows: true)
        messageRowsNonAppendRevision &+= 1
    }

    private func mutateSelectedMessages(
        _ mutation: (inout [Message]) -> Void
    ) {
        let oldMessages = messages
        mutation(&messages)
        rebuildSelectedMessageIndexes()
        messageRows = MessageGrouping.updating(
            existing: messageRows,
            oldMessages: oldMessages,
            newMessages: messages
        )
        publishMessageRowsUpdate(invalidatesAllRows: true)
        messageRowsNonAppendRevision &+= 1
    }

    private func prependSelectedMessages(
        _ earlier: [Message],
        channelID: ChannelID
    ) async -> Bool {
        guard !earlier.isEmpty else { return true }
        // History preparation performs Markdown/CoreText setup for an entire
        // page. Running it at userInitiated priority lets it contend with the
        // main thread for font and attributed-string internals precisely
        // while the display link is trying to present the next scroll frame.
        // The page is prefetched thousands of points ahead, so utility
        // priority preserves that headroom without priority-inverting UI
        // presentation on every pagination boundary.
        let preparedInsertedRows = await Task.detached(priority: .utility) {
            await MessageGrouping.rowsCooperatively(for: earlier)
        }.value
        guard !Task.isCancelled, selectedChannelID == channelID else {
            return false
        }
        let commitStart = ProcessInfo.processInfo.systemUptime
        var potentiallyChangedMessageIDs = Set<MessageID>()
        if let firstExistingID = messageRows.first?.id {
            potentiallyChangedMessageIDs.insert(firstExistingID)
        }
        for message in earlier {
            potentiallyChangedMessageIDs.formUnion(
                selectedReplyMessageIDsByTarget[message.id] ?? []
            )
        }
        var previousRowsByID: [MessageID: MessageRowPresentation] = [:]
        previousRowsByID.reserveCapacity(potentiallyChangedMessageIDs.count)
        for id in potentiallyChangedMessageIDs {
            if let oldIndex = selectedMessageIndex(for: id),
               messageRows.indices.contains(oldIndex)
            {
                previousRowsByID[id] = messageRows[oldIndex]
            }
        }
        MessageGrouping.prependRows(
            for: earlier,
            into: &messageRows,
            preparedInsertedRows: preparedInsertedRows,
            existingMessageIndex: selectedMessageIndex(for:),
            replyingMessageIDsByTarget:
                selectedReplyMessageIDsByTarget
        )
        let changedMessageIDs = Set(
            potentiallyChangedMessageIDs.filter { id in
                guard let oldIndex = selectedMessageIndex(for: id),
                      let previousRow = previousRowsByID[id],
                      messageRows.indices.contains(earlier.count + oldIndex)
                else { return false }
                return previousRow
                    != messageRows[earlier.count + oldIndex]
            }
        )
        messages.insert(contentsOf: earlier, at: 0)
        selectedMessageIndexOrigin -= earlier.count
        selectedMessageIDs.formUnion(earlier.lazy.map(\.id))
        selectedMessageStoredIndexByID.reserveCapacity(messages.count)
        for (index, message) in earlier.enumerated() {
            setSelectedMessageIndex(index, for: message.id)
            if let replyTarget = message.replyTo {
                selectedReplyMessageIDsByTarget[
                    replyTarget,
                    default: []
                ].insert(message.id)
            }
        }
        publishMessageRowsUpdate(
            change: .insert(
                IndexSet(integersIn: 0 ..< earlier.count)
            ),
            insertedMessageIDs: earlier.map(\.id),
            changedMessageIDs: changedMessageIDs
        )
        messageRowsNonAppendRevision &+= 1
        if runsChatPerformanceBenchmark {
            let commitMilliseconds =
                (ProcessInfo.processInfo.systemUptime - commitStart) * 1_000
            if commitMilliseconds >= 4 {
                NSLog(
                    "SakuraCord history commit: %.2f ms (%d rows)",
                    commitMilliseconds,
                    messageRows.count
                )
            }
        }
        return true
    }

    private func appendSelectedMessage(
        _ message: Message,
        preparedTextPlan: NativeTimelineTextPlan? = nil
    ) {
        appendSelectedMessages(
            [message],
            preparedTextPlans:
                preparedTextPlan.map { [message.id: $0] } ?? [:]
        )
    }

    private func appendSelectedMessages(
        _ appendedMessages: [Message],
        preparedTextPlans: [MessageID: NativeTimelineTextPlan] = [:]
    ) {
        guard !appendedMessages.isEmpty else { return }
        let insertionStart = messageRows.count
        var appendedRows: [MessageRowPresentation] = []
        appendedRows.reserveCapacity(appendedMessages.count)
        var previous = messages.last
        let appendedByID = Dictionary(
            appendedMessages.map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        for message in appendedMessages {
            let replyPreview =
                message.replyTo.flatMap { replyID in
                    (
                        appendedByID[replyID]
                            ?? selectedMessageIndex(for: replyID).map {
                                messages[$0]
                            }
                    ).map {
                        MessageReplyPreview(
                            messageID: $0.id,
                            author: $0.author,
                            content: $0.content
                        )
                    }
                } ?? message.replyPreview
            let isReplyAvailable =
                replyPreview.map { preview in
                    appendedByID[preview.messageID] != nil
                        || selectedMessageIDs.contains(preview.messageID)
                } ?? false
            let row = MessageGrouping.appendingRow(
                for: message,
                after: previous,
                replyPreview: replyPreview,
                isReplyAvailable: isReplyAvailable,
                textPlan: preparedTextPlans[message.id]
            )
            appendedRows.append(row)
            previous = message
        }
        messages.append(contentsOf: appendedMessages)
        selectedMessageIDs.formUnion(appendedMessages.lazy.map(\.id))
        for (offset, message) in appendedMessages.enumerated() {
            setSelectedMessageIndex(
                insertionStart + offset,
                for: message.id
            )
            if let replyTarget = message.replyTo {
                selectedReplyMessageIDsByTarget[
                    replyTarget,
                    default: []
                ].insert(message.id)
            }
        }
        messageRows.append(contentsOf: appendedRows)
        publishMessageRowsUpdate(
            change: .insert(
                IndexSet(
                    integersIn:
                        insertionStart ..< insertionStart + appendedRows.count
                )
            ),
            insertedMessageIDs: appendedRows.map(\.id)
        )
    }

    private func commitBatchedSelectedMessages() {
        guard !batchedSelectedMessages.isEmpty else { return }
        let pending = batchedSelectedMessages
        batchedSelectedMessages.removeAll(keepingCapacity: true)
        let preparedTextPlans = batchedSelectedTextPlansByID
        batchedSelectedTextPlansByID.removeAll(keepingCapacity: true)
        appendSelectedMessages(
            pending,
            preparedTextPlans: preparedTextPlans
        )
    }

    private func reconcileVisibleOrCached(_ message: Message) {
        let message = reactionPresentationPreserving(message)
        if message.channelID == openThread?.id {
            reconcileThread(message)
        }
        if message.channelID == selectedChannelID {
            reconcile(message)
        } else {
            cache(message)
        }
    }

    private func reactionPresentationPreserving(_ incoming: Message) -> Message {
        var result = incoming
        let lookupKey = ReactionMutationKey(
            channelID: incoming.channelID,
            messageID: incoming.id,
            reactionID: ""
        )
        if let existing = reactionMessage(for: lookupKey) {
            result = result.preservingReactionReactors(from: existing)
        }

        guard let currentUserID = snapshot?.currentUser.id else { return result }
        let currentUserReactor = knownReactionReactor(for: currentUserID)
        for (key, mutation) in reactionMutations
        where key.channelID == result.channelID && key.messageID == result.id {
            let currentlyReacted =
                result.reactions.first(where: { $0.id == key.reactionID })?
                    .didCurrentUserReact ?? false
            guard currentlyReacted != mutation.desiredReacted else { continue }
            let update: MessageReactionUpdate =
                mutation.desiredReacted
                ? .add(
                    channelID: key.channelID,
                    messageID: key.messageID,
                    userID: currentUserID,
                    emoji: mutation.emoji,
                    kind: .normal
                )
                : .remove(
                    channelID: key.channelID,
                    messageID: key.messageID,
                    userID: currentUserID,
                    emoji: mutation.emoji,
                    kind: .normal
                )
            _ = result.applyReactionUpdate(
                update,
                currentUserID: currentUserID,
                reactor: currentUserReactor
            )
        }
        return result
    }

    private func reactionConfirmedSnapshot(_ message: Message) -> Message {
        guard let currentUserID = snapshot?.currentUser.id else { return message }
        var result = message
        let currentUserReactor = knownReactionReactor(for: currentUserID)
        for (key, mutation) in reactionMutations
        where key.channelID == result.channelID && key.messageID == result.id {
            let currentlyReacted =
                result.reactions.first(where: { $0.id == key.reactionID })?
                    .didCurrentUserReact ?? false
            guard currentlyReacted != mutation.confirmedReacted else { continue }
            let update: MessageReactionUpdate =
                mutation.confirmedReacted
                ? .add(
                    channelID: key.channelID,
                    messageID: key.messageID,
                    userID: currentUserID,
                    emoji: mutation.emoji,
                    kind: .normal
                )
                : .remove(
                    channelID: key.channelID,
                    messageID: key.messageID,
                    userID: currentUserID,
                    emoji: mutation.emoji,
                    kind: .normal
                )
            _ = result.applyReactionUpdate(
                update,
                currentUserID: currentUserID,
                reactor: currentUserReactor
            )
        }
        return result
    }

    private func updateOutgoingState(_ state: OutboxState, nonce: String, channelID: ChannelID) {
        if selectedChannelID == channelID,
           let index = messages.firstIndex(where: { $0.nonce == nonce })
        {
            mutateSelectedMessages {
                $0[index].outboxState = state
            }
            return
        }
        guard var cached = messageCache[channelID],
              let index = cached.firstIndex(where: { $0.nonce == nonce })
        else { return }
        cached[index].outboxState = state
        messageCache[channelID] = cached
    }

    private func removeOutgoingMessage(nonce: String, channelID: ChannelID) {
        if selectedChannelID == channelID {
            mutateSelectedMessages {
                $0.removeAll { $0.nonce == nonce }
            }
            return
        }
        guard var cached = messageCache[channelID] else { return }
        cached.removeAll { $0.nonce == nonce }
        messageCache[channelID] = cached
    }

    private func outgoingState(nonce: String, channelID: ChannelID) -> OutboxState? {
        if selectedChannelID == channelID {
            return messages.first { $0.nonce == nonce }?.outboxState
        }
        return messageCache[channelID]?.first { $0.nonce == nonce }?.outboxState
    }

    private func persist(_ message: Message) {
        guard !message.flags.contains(.ephemeral) else { return }
        messagePersistenceSink.enqueue(message, database: database)
    }

    private func reconcileThread(_ message: Message) {
        var updated = threadMessages
        if let index = updated.firstIndex(where: {
            $0.id == message.id || ($0.nonce != nil && $0.nonce == message.nonce)
        }) {
            updated.remove(at: index)
            if let duplicateIndex = updated.firstIndex(where: {
                $0.id == message.id
            }) {
                updated.remove(at: duplicateIndex)
            }
        }
        Self.insert(message, intoSorted: &updated)
        guard updated != threadMessages else { return }
        threadMessages = updated
    }

    private func reconcileThreadUpdate(_ message: Message) {
        guard let index = threadMessages.firstIndex(where: {
            $0.id == message.id
        }) else { return }
        var updated = threadMessages
        var resolved = message
        resolved.replyTo = resolved.replyTo ?? updated[index].replyTo
        resolved.replyPreview =
            resolved.replyPreview ?? updated[index].replyPreview
        guard resolved != updated[index] else { return }
        updated[index] = resolved
        threadMessages = updated
    }

    private static func insert(_ message: Message, intoSorted messages: inout [Message]) {
        guard let last = messages.last, !messagePrecedes(message, last) else {
            let index = insertionIndex(for: message, in: messages)
            messages.insert(message, at: index)
            return
        }
        messages.append(message)
    }

    private static func insertionIndex(for message: Message, in messages: [Message]) -> Int {
        var lowerBound = messages.startIndex
        var upperBound = messages.endIndex
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if messagePrecedes(messages[midpoint], message) {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return lowerBound
    }

    private static func messagePrecedes(_ lhs: Message, _ rhs: Message) -> Bool {
        lhs.timestamp != rhs.timestamp ? lhs.timestamp < rhs.timestamp : lhs.id < rhs.id
    }

    private func cache(_ message: Message) {
        let current = messageCache[message.channelID] ?? []
        messageCache[message.channelID] = Self.merging(current: current, fresh: [message])
    }

    private func reconcileCachedMessageUpdate(_ message: Message) {
        guard var cached = messageCache[message.channelID],
              let index = cached.firstIndex(where: { $0.id == message.id })
        else { return }
        var resolved = message
        resolved.replyTo = resolved.replyTo ?? cached[index].replyTo
        resolved.replyPreview =
            resolved.replyPreview ?? cached[index].replyPreview
        guard resolved != cached[index] else { return }
        cached[index] = resolved
        messageCache[message.channelID] = cached
    }
}

private actor OfflineCredentialStore: CredentialStore {
    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        throw ChatProviderError.invalidRequest(
            "Credential storage is unavailable in offline testing mode.")
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        throw ChatProviderError.invalidRequest(
            "Credentials are unavailable in offline testing mode.")
    }

    func remove(_ handle: CredentialHandle) async throws {}

    func handles() async throws -> [CredentialHandle] {
        []
    }
}

nonisolated final class NativeTimelineAttributedTextBox: @unchecked Sendable {
    let value: NSAttributedString
    let framesetter: CTFramesetter
    let layoutHeightAdjustment: CGFloat

    nonisolated init(
        _ value: NSAttributedString,
        layoutHeightAdjustment: CGFloat = 0
    ) {
        self.value = value
        self.layoutHeightAdjustment = layoutHeightAdjustment
        framesetter = CTFramesetterCreateWithAttributedString(value)
    }
}

struct NativeTimelineTextPlan: Equatable, Sendable {
    let preparedText: RichMessageAttributedText.Prepared?
    let linkedImages: [LinkedImageReference]
    let attributedText: NativeTimelineAttributedTextBox?
    let baseFontSize: CGFloat

    nonisolated static func == (
        lhs: NativeTimelineTextPlan,
        rhs: NativeTimelineTextPlan
    ) -> Bool {
        lhs.preparedText == rhs.preparedText
            && lhs.linkedImages == rhs.linkedImages
            && lhs.baseFontSize == rhs.baseFontSize
    }

    nonisolated static func make(
        for message: Message,
        currentUserID: UserID? = nil
    ) -> Self {
        let baseFontSize: CGFloat =
            if message.type.hasGeneratedContent {
                13
            } else {
                15
            }
        let visibleContent =
            if message.type.hasGeneratedContent {
                SystemMessagePresentation.label(
                    for: message,
                    currentUserID: currentUserID
                )
            } else {
                MessageEmbedPresentation.visibleMessageContent(for: message)
            }
        let linkedPresentation = LinkedImagePresentation(content: visibleContent)
        let prepared = linkedPresentation.visibleText.isEmpty
            ? nil
            : RichMessageAttributedText.prepare(
                source: linkedPresentation.visibleText
            )
        let attributed: NativeTimelineAttributedTextBox?
        if message.type.hasGeneratedContent {
            attributed = NativeTimelineAttributedTextBox(
                SystemMessagePresentation.attributedLabel(
                    for: message,
                    currentUserID: currentUserID,
                    baseFontSize: baseFontSize
                )
            )
        } else if let prepared, prepared.tokens.isEmpty {
            attributed = NativeTimelineAttributedTextBox(
                DiscordMarkdown.appKitAttributed(
                    prepared.markdownPlan,
                    baseFontSize: prepared.isEmojiOnly
                        ? 48
                        : baseFontSize
                )
            )
        } else {
            attributed = nil
        }
        return Self(
            preparedText: prepared,
            linkedImages: linkedPresentation.images,
            attributedText: attributed,
            baseFontSize: baseFontSize
        )
    }
}

final class MessageRowPresentation: Identifiable, Equatable, Sendable {
    var id: MessageID {
        message.id
    }

    let message: Message
    let startsGroup: Bool
    let startsDay: Bool
    let replyPreview: MessageReplyPreview?
    let isReplyAvailable: Bool
    let textPlan: NativeTimelineTextPlan

    nonisolated init(
        message: Message,
        startsGroup: Bool,
        startsDay: Bool,
        replyPreview: MessageReplyPreview?,
        isReplyAvailable: Bool,
        textPlan: NativeTimelineTextPlan? = nil
    ) {
        self.message = message
        self.startsGroup = startsGroup
        self.startsDay = startsDay
        self.replyPreview = replyPreview
        self.isReplyAvailable = isReplyAvailable
        self.textPlan = textPlan ?? NativeTimelineTextPlan.make(for: message)
    }

    nonisolated static func == (
        lhs: MessageRowPresentation,
        rhs: MessageRowPresentation
    ) -> Bool {
        lhs.message == rhs.message
            && lhs.startsGroup == rhs.startsGroup
            && lhs.startsDay == rhs.startsDay
            && lhs.replyPreview == rhs.replyPreview
            && lhs.isReplyAvailable == rhs.isReplyAvailable
            && lhs.textPlan == rhs.textPlan
    }
}

nonisolated enum MessageGrouping {
    /// Discord's current cozy layout uses a seven-minute continuation barrier.
    private static let continuationInterval: TimeInterval = 7 * 60

    static func rows(for messages: [Message], calendar: Calendar = .autoupdatingCurrent)
        -> [MessageRowPresentation]
    {
        let messagesByID = messageLookup(for: messages)
        return messages.indices.map { index in
            row(
                at: index,
                in: messages,
                messagesByID: messagesByID,
                calendar: calendar
            )
        }
    }

    static func rowsCooperatively(
        for messages: [Message],
        calendar: Calendar = .autoupdatingCurrent,
        batchSize: Int = 4
    ) async -> [MessageRowPresentation] {
        let messagesByID = messageLookup(for: messages)
        let batchSize = max(1, batchSize)
        var result: [MessageRowPresentation] = []
        result.reserveCapacity(messages.count)
        for index in messages.indices {
            result.append(
                autoreleasepool {
                    row(
                        at: index,
                        in: messages,
                        messagesByID: messagesByID,
                        calendar: calendar
                    )
                }
            )
            if (index + 1).isMultiple(of: batchSize),
               index + 1 < messages.endIndex
            {
                await Task.yield()
            }
        }
        return result
    }

    private static func messageLookup(
        for messages: [Message]
    ) -> [MessageID: Message] {
        guard messages.contains(where: { $0.replyTo != nil }) else {
            return [:]
        }
        return Dictionary(
            messages.map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
    }

    private static func row(
        at index: Int,
        in messages: [Message],
        messagesByID: [MessageID: Message],
        calendar: Calendar
    ) -> MessageRowPresentation {
        let message = messages[index]
        let replyPreview =
            message.replyTo.flatMap { messageID -> MessageReplyPreview? in
                if let referenced = messagesByID[messageID] {
                    return MessageReplyPreview(
                        messageID: referenced.id,
                        author: referenced.author,
                        content: referenced.content
                    )
                }
                return message.replyPreview
            }
        guard index > 0 else {
            return MessageRowPresentation(
                message: message,
                startsGroup: true,
                startsDay: true,
                replyPreview: replyPreview,
                isReplyAvailable:
                    replyPreview.map {
                        messagesByID[$0.messageID] != nil
                    } ?? false
            )
        }
        let previous = messages[index - 1]
        return MessageRowPresentation(
            message: message,
            startsGroup: !continuesGroup(
                from: previous,
                to: message,
                calendar: calendar
            ),
            startsDay: !calendar.isDate(
                previous.timestamp,
                inSameDayAs: message.timestamp
            ),
            replyPreview: replyPreview,
            isReplyAvailable:
                replyPreview.map {
                    messagesByID[$0.messageID] != nil
                } ?? false
        )
    }

    private static func isGroupable(_ message: Message) -> Bool {
        !message.type.hasGeneratedContent && message.type != .chatInputCommand
    }

    static func appendingRow(
        for message: Message,
        after previous: Message?,
        replyPreview: MessageReplyPreview?,
        isReplyAvailable: Bool,
        textPlan: NativeTimelineTextPlan? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) -> MessageRowPresentation {
        guard let previous else {
            return MessageRowPresentation(
                message: message,
                startsGroup: true,
                startsDay: true,
                replyPreview: replyPreview,
                isReplyAvailable: isReplyAvailable,
                textPlan: textPlan
            )
        }
        return MessageRowPresentation(
            message: message,
            startsGroup: !continuesGroup(
                from: previous,
                to: message,
                calendar: calendar
            ),
            startsDay: !calendar.isDate(
                previous.timestamp,
                inSameDayAs: message.timestamp
            ),
            replyPreview: replyPreview,
            isReplyAvailable: isReplyAvailable,
            textPlan: textPlan
        )
    }

    static func reconcileChangedMessage(
        id changedID: MessageID,
        replacement: Message?,
        messages: [Message],
        availableMessageIDs: Set<MessageID>,
        rows: inout [MessageRowPresentation],
        neighborIndex: Int? = nil,
        messageIndex: ((MessageID) -> Int?)? = nil,
        replyingMessageIDs: Set<MessageID>? = nil,
        replacementTextPlan: NativeTimelineTextPlan? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) -> IndexSet {
        guard rows.count == messages.count else {
            rows = self.rows(for: messages, calendar: calendar)
            return IndexSet(integersIn: messages.indices)
        }
        var affected = IndexSet()
        if let replacement,
           let index =
                messageIndex?(replacement.id)
                ?? messages.firstIndex(where: { $0.id == replacement.id })
        {
            affected.insert(index)
            if messages.indices.contains(index + 1) {
                affected.insert(index + 1)
            }
        } else if let neighborIndex,
                  messages.indices.contains(neighborIndex)
        {
            affected.insert(neighborIndex)
        }
        if let replyingMessageIDs, let messageIndex {
            for replyingMessageID in replyingMessageIDs {
                if let index = messageIndex(replyingMessageID) {
                    affected.insert(index)
                }
            }
        } else {
            for index in messages.indices
            where messages[index].replyTo == changedID {
                affected.insert(index)
            }
        }

        for index in affected {
            let message = messages[index]
            let priorRow = rows[index]
            let replyPreview: MessageReplyPreview?
            if message.replyTo == changedID, let replacement {
                replyPreview = MessageReplyPreview(
                    messageID: replacement.id,
                    author: replacement.author,
                    content: replacement.content
                )
            } else {
                replyPreview = message.replyPreview ?? priorRow.replyPreview
            }
            let startsGroup: Bool
            let startsDay: Bool
            if index == messages.startIndex {
                startsGroup = true
                startsDay = true
            } else {
                startsGroup = !continuesGroup(
                    from: messages[index - 1],
                    to: message,
                    calendar: calendar
                )
                startsDay = !calendar.isDate(
                    messages[index - 1].timestamp,
                    inSameDayAs: message.timestamp
                )
            }
            rows[index] = MessageRowPresentation(
                message: message,
                startsGroup: startsGroup,
                startsDay: startsDay,
                replyPreview: replyPreview,
                isReplyAvailable:
                    replyPreview.map {
                        availableMessageIDs.contains($0.messageID)
                    } ?? false,
                textPlan:
                    priorRow.message == message
                    ? priorRow.textPlan
                    : message.id == replacement?.id
                    ? replacementTextPlan
                    : nil
            )
        }
        return affected
    }

    static func prependRows(
        for insertedMessages: [Message],
        into existingRows: inout [MessageRowPresentation],
        preparedInsertedRows: [MessageRowPresentation]? = nil,
        existingMessageIndex: ((MessageID) -> Int?)? = nil,
        replyingMessageIDsByTarget:
            [MessageID: Set<MessageID>]? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        guard !insertedMessages.isEmpty else { return }
        let insertedRows =
            if let preparedInsertedRows,
               preparedInsertedRows.count == insertedMessages.count,
               zip(preparedInsertedRows, insertedMessages).allSatisfy({ pair in
                   pair.0.message.id == pair.1.id
               })
            {
                preparedInsertedRows
            } else {
                rows(for: insertedMessages, calendar: calendar)
            }
        guard !existingRows.isEmpty else {
            existingRows = insertedRows
            return
        }

        let insertedByID = Dictionary(
            uniqueKeysWithValues: insertedMessages.map { ($0.id, $0) }
        )
        let insertedLast = insertedMessages[insertedMessages.count - 1]

        var affectedExistingIndexes = IndexSet(integer: 0)
        if let existingMessageIndex,
           let replyingMessageIDsByTarget
        {
            for insertedMessage in insertedMessages {
                for replyingMessageID in
                    replyingMessageIDsByTarget[insertedMessage.id] ?? []
                {
                    if let index = existingMessageIndex(replyingMessageID) {
                        affectedExistingIndexes.insert(index)
                    }
                }
            }
        } else {
            for (index, row) in existingRows.enumerated()
            where row.message.replyTo.map({
                insertedByID[$0] != nil
            }) == true {
                affectedExistingIndexes.insert(index)
            }
        }

        var replacements: [(index: Int, row: MessageRowPresentation)] = []
        replacements.reserveCapacity(affectedExistingIndexes.count)
        for index in affectedExistingIndexes
        where existingRows.indices.contains(index) {
            let row = existingRows[index]
            let message = row.message
            let referenced = message.replyTo.flatMap { insertedByID[$0] }
            let replyPreview =
                referenced.map {
                    MessageReplyPreview(
                        messageID: $0.id,
                        author: $0.author,
                        content: $0.content
                    )
                } ?? row.replyPreview
            let startsGroup =
                index == 0
                ? !continuesGroup(
                    from: insertedLast,
                    to: message,
                    calendar: calendar
                )
                : row.startsGroup
            let startsDay =
                index == 0
                ? !calendar.isDate(
                    insertedLast.timestamp,
                    inSameDayAs: message.timestamp
                )
                : row.startsDay
            replacements.append(
                (
                    index,
                    MessageRowPresentation(
                        message: message,
                        startsGroup: startsGroup,
                        startsDay: startsDay,
                        replyPreview: replyPreview,
                        isReplyAvailable:
                            referenced != nil || row.isReplyAvailable,
                        textPlan: row.textPlan
                    )
                )
            )
        }
        // Mutate the existing buffer so its geometric spare capacity is
        // reused across pagination. Rebuilding an exact-sized row array for
        // every 50-message page left one progressively larger 4–9 MB malloc
        // region behind per page, producing both the periodic hitch and a
        // hundreds-of-megabytes allocator high-water mark after long runs.
        existingRows.insert(contentsOf: insertedRows, at: 0)
        for replacement in replacements {
            existingRows[insertedMessages.count + replacement.index] =
                replacement.row
        }
    }

    private static func continuesGroup(
        from previous: Message, to message: Message, calendar: Calendar
    ) -> Bool {
        isGroupable(previous)
            && isGroupable(message)
            && previous.author.id == message.author.id
            && message.replyTo == nil
            && message.timestamp.timeIntervalSince(previous.timestamp) >= 0
            && message.timestamp.timeIntervalSince(previous.timestamp) < continuationInterval
            && calendar.isDate(previous.timestamp, inSameDayAs: message.timestamp)
    }

    static func updating(
        existing: [MessageRowPresentation], oldMessages: [Message], newMessages: [Message],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [MessageRowPresentation] {
        guard existing.count == oldMessages.count, !oldMessages.isEmpty else {
            return rows(for: newMessages, calendar: calendar)
        }

        if newMessages.count >= oldMessages.count,
           newMessages.prefix(oldMessages.count).elementsEqual(oldMessages)
        {
            var result = existing
            let appended = newMessages[oldMessages.count...]
            let byID =
                appended.contains(where: { $0.replyTo != nil })
                    ? Dictionary(uniqueKeysWithValues: newMessages.map { ($0.id, $0) })
                    : [:]
            for index in oldMessages.count ..< newMessages.count {
                result.append(
                    presentation(at: index, in: newMessages, messagesByID: byID, calendar: calendar)
                )
            }
            return result
        }

        if newMessages.count > oldMessages.count {
            let insertedCount = newMessages.count - oldMessages.count
            if newMessages.suffix(oldMessages.count).elementsEqual(oldMessages) {
                let insertedMessages = newMessages.prefix(insertedCount)
                let insertedByID = Dictionary(
                    uniqueKeysWithValues: insertedMessages.map { ($0.id, $0) }
                )
                var result =
                    rows(for: Array(insertedMessages), calendar: calendar) + existing
                let insertedIDs = Set(insertedMessages.map(\.id))
                var affected = Set<Int>()
                for (index, message) in newMessages.enumerated()
                    where message.replyTo.map(insertedIDs.contains) == true {
                    affected.insert(index)
                }
                for index in affected where newMessages.indices.contains(index) {
                    result[index] = presentation(
                        at: index,
                        in: newMessages,
                        messagesByID: insertedByID,
                        calendar: calendar
                    )
                }
                if newMessages.indices.contains(insertedCount),
                   !affected.contains(insertedCount)
                {
                    let prior = existing[0]
                    let message = newMessages[insertedCount]
                    result[insertedCount] = MessageRowPresentation(
                        message: message,
                        startsGroup: !continuesGroup(
                            from: newMessages[insertedCount - 1],
                            to: message,
                            calendar: calendar
                        ),
                        startsDay: !calendar.isDate(
                            newMessages[insertedCount - 1].timestamp,
                            inSameDayAs: message.timestamp
                        ),
                        replyPreview: prior.replyPreview,
                        isReplyAvailable: prior.isReplyAvailable,
                        textPlan: prior.textPlan
                    )
                }
                return result
            }
        }

        if newMessages.count == oldMessages.count,
           zip(newMessages, oldMessages).allSatisfy({ $0.0.id == $0.1.id })
        {
            var result = existing
            var changed: [Int] = []
            changed.reserveCapacity(1)
            for index in newMessages.indices where newMessages[index] != oldMessages[index] {
                changed.append(index)
            }
            guard !changed.isEmpty else { return result }
            let byID = Dictionary(uniqueKeysWithValues: newMessages.map { ($0.id, $0) })
            let changedIDs = Set(changed.lazy.map { newMessages[$0].id })
            var affected = Set(changed)
            for index in changed {
                if newMessages.indices.contains(index + 1) {
                    affected.insert(index + 1)
                }
            }
            for (index, message) in newMessages.enumerated()
                where message.replyTo.map(changedIDs.contains) == true {
                affected.insert(index)
            }
            for index in affected {
                result[index] = presentation(
                    at: index, in: newMessages, messagesByID: byID, calendar: calendar
                )
            }
            return result
        }
        return rows(for: newMessages, calendar: calendar)
    }

    private static func presentation(
        at index: Int, in messages: [Message], messagesByID: [MessageID: Message],
        calendar: Calendar
    ) -> MessageRowPresentation {
        let message = messages[index]
        let replyPreview = message.replyTo.flatMap { id in
            messagesByID[id].map {
                MessageReplyPreview(messageID: $0.id, author: $0.author, content: $0.content)
            } ?? message.replyPreview
        }
        guard index > 0 else {
            return MessageRowPresentation(
                message: message,
                startsGroup: true,
                startsDay: true,
                replyPreview: replyPreview,
                isReplyAvailable: replyPreview.map { messagesByID[$0.messageID] != nil } ?? false
            )
        }
        let continues = continuesGroup(
            from: messages[index - 1], to: message, calendar: calendar
        )
        return MessageRowPresentation(
            message: message,
            startsGroup: !continues,
            startsDay: !calendar.isDate(
                messages[index - 1].timestamp,
                inSameDayAs: message.timestamp
            ),
            replyPreview: replyPreview,
            isReplyAvailable: replyPreview.map { messagesByID[$0.messageID] != nil } ?? false
        )
    }
}
