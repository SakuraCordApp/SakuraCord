import CoreAudio
import DiscordProtocol
import Foundation
import MediaPipeline
import OSLog
import Observation
import SakuraCordModels
import SakuraCordPersistence

nonisolated struct ComponentControlKey: Hashable, Sendable {
    let messageID: MessageID
    let customID: String
}

nonisolated struct MessageNavigationRequest: Equatable, Sendable {
    let requestID: UInt64
    let channelID: ChannelID
    let messageID: MessageID
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
@Observable
final class AppModel {
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
        var reactionCount: Int
    }

    private static let messageSendLogger = Logger(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "MessageSend"
    )
    private static let forumPerformanceSignposter = OSSignposter(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "PointsOfInterest"
    )
    nonisolated static let maximumConcurrentReactionReactorLoads = 4
    /// Discord emits a full member list for every presence change in the active
    /// guild. Applying each one separately re-derives member sections, indexes,
    /// and every view that reads them, so bursts are collapsed into one update.
    nonisolated static let memberUpdateCoalescingInterval: Duration = .milliseconds(100)

    /// How many channels keep their loaded history in memory between visits.
    nonisolated static let cachedChannelHistoryLimit = 12

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

    private(set) var snapshot: BootstrapSnapshot? {
        didSet {
            guard snapshot?.channels != oldValue?.channels else { return }
            channelsByID = Dictionary(
                (snapshot?.channels ?? []).map { ($0.id, $0) },
                uniquingKeysWith: { _, newer in newer }
            )
        }
    }

    /// Mention and navigation lookups resolve channels per render. Snapshots
    /// carry every channel of every guild, so those must not be linear scans.
    private(set) var channelsByID: [ChannelID: Channel] = [:]
    private(set) var serverRailGuildsByID: [GuildID: Guild] = [:]
    private(set) var serverRailItems: [GuildRailItem] = [] {
        didSet { updateOrderedCustomEmojis() }
    }
    private(set) var visibleChannels: [Channel] = [] {
        didSet {
            guard visibleChannels != oldValue else { return }
            updateHiddenChannelIDs()
        }
    }

    /// Channels the current user cannot read.
    ///
    /// The sidebar previously derived this in its body, so every render
    /// re-resolved permissions for every channel — and because that reads the
    /// member store, presence traffic drove it.
    private(set) var hiddenChannelIDs: Set<ChannelID> = []
    @ObservationIgnored private var currentMemberRoleIDs: [RoleID] = []
    private(set) var selectedChannel: Channel?
    private(set) var messages: [Message] = [] {
        didSet {
            messageRows = MainActorWorkDiagnostics.measure(.messageRows) {
                MessageGrouping.updating(
                    existing: messageRows, oldMessages: oldValue, newMessages: messages
                )
            }
            indexMessageAuthors(in: messages, resettingWhenEmpty: true)
            if let selectedChannelID {
                messageCache[selectedChannelID] = messages
                retainMessageCache(for: selectedChannelID)
            }
        }
    }

    /// Authors seen in the loaded conversation, so mention resolution can fall
    /// back to them without scanning the timeline on every render.
    private(set) var messageAuthorsByID: [UserID: User] = [:]

    private(set) var messageRows: [MessageRowPresentation] = []
    private(set) var messageNavigationRequest: MessageNavigationRequest?
    private(set) var members: [Member] = [] {
        didSet {
            // Sectioning is only read while the inspector is on screen, so it
            // is derived on demand instead of on every Gateway member update.
            memberSectionCache = nil
            let indexed = Dictionary(
                members.map { ($0.id, $0) },
                uniquingKeysWith: { _, newer in newer }
            )
            if membersByID != indexed {
                membersByID = indexed
            }
        }
    }

    private(set) var membersByID: [UserID: Member] = [:] {
        didSet {
            updateAuthorPresentations()
            // Channel visibility only moves when the current user's own roles
            // move, not when some other member's presence changes.
            let currentUserID = snapshot?.currentUser.id
            let roleIDs = currentUserID.flatMap { membersByID[$0]?.roles.map(\.id) } ?? []
            guard roleIDs != currentMemberRoleIDs else { return }
            currentMemberRoleIDs = roleIDs
            updateHiddenChannelIDs()
        }
    }

    /// Author display values for everyone in the loaded conversation.
    ///
    /// A presence change mutates `membersByID` but cannot change any of these
    /// values, so deriving them here — and assigning only on a real difference —
    /// keeps presence traffic from invalidating the timeline.
    private(set) var authorPresentationsByUserID: [UserID: MessageAuthorPresentation] = [:]
    @ObservationIgnored private var memberSectionCache: [MemberSection]?

    var memberSections: [MemberSection] {
        if let memberSectionCache {
            return memberSectionCache
        }
        let value = MainActorWorkDiagnostics.measure(.memberSections) {
            MemberSection.make(from: members)
        }
        memberSectionCache = value
        return value
    }
    private(set) var guildRoles: [GuildRole] = [] {
        didSet {
            guard guildRoles != oldValue else { return }
            guildRolesByID = Dictionary(
                guildRoles.map { ($0.id, $0) },
                uniquingKeysWith: { _, newer in newer }
            )
            updateAuthorPresentations()
            updateHiddenChannelIDs()
        }
    }

    private(set) var guildRolesByID: [RoleID: GuildRole] = [:]
    private(set) var commandMemberResults: [Member] = []
    private(set) var mentionMemberResults: [Member] = []
    private(set) var mentionAutocompleteMembers: [Member] = []
    private(set) var knownMentionMembers: [UserID: Member] = [:]
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
    private(set) var isLoading = false
    private(set) var isLoadingMessages = false
    private(set) var isLoadingEarlier = false
    private(set) var hasMoreMessages = false
    private(set) var messageLoadError: String?
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
            threadMessageRows = MessageGrouping.updating(
                existing: threadMessageRows,
                oldMessages: oldValue,
                newMessages: threadMessages
            )
            indexMessageAuthors(in: threadMessages, resettingWhenEmpty: false)
        }
    }
    private(set) var threadMessageRows: [MessageRowPresentation] = []
    private(set) var isLoadingThread = false
    private(set) var isLoadingEarlierThread = false
    private(set) var hasMoreThreadMessages = false
    private(set) var threadErrorMessage: String?
    private(set) var sendProgressByNonce: [String: MessageSendProgress] = [:]
    private var outgoingDraftsByNonce: [String: SendMessageDraft] = [:]
    private(set) var gifResults: [GIFSearchResult] = []
    private(set) var isLoadingGIFs = false
    private(set) var gifErrorMessage: String?
    private(set) var stickersByGuild: [GuildID: [MessageSticker]] = [:]
    private(set) var supportedCapabilities: Set<ChatCapability> = []
    private(set) var pendingComponentControls: Set<ComponentControlKey> = []
    private(set) var componentErrors: [ComponentControlKey: String] = [:]
    private(set) var selectedMember: Member?
    private(set) var selectedProfile: UserProfile?
    private(set) var isLoadingProfile = false
    private(set) var profileErrorMessage: String?
    private(set) var isInspectorProfilePresented = false
    private(set) var activeVoiceChannel: Channel?
    private(set) var voiceSessionState: VoiceSessionState = .idle
    private(set) var voiceParticipants: [VoiceRemoteParticipant] = []
    private(set) var isLocallySpeaking = false
    private(set) var voiceVideoFrames: [String: VoiceVideoFrame] = [:]
    private(set) var voiceEncryptionVersion: UInt16?
    private(set) var voiceLatencyMilliseconds: Int?
    private(set) var voiceErrorMessage: String?
    private(set) var voiceStates: [UserID: VoiceParticipantState] = [:]
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
            roles: guildRoles
        )
    }

    private func updateHiddenChannelIDs() {
        let value = MainActorWorkDiagnostics.measure(.hiddenChannels) {
            var value: Set<ChannelID> = []
            for channel in visibleChannels where conversationAccess(for: channel) == .hidden {
                value.insert(channel.id)
            }
            return value
        }
        guard hiddenChannelIDs != value else { return }
        hiddenChannelIDs = value
    }

    func conversationAccess(for channel: Channel) -> ConversationAccess {
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
            roles: guildRoles
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
            roles: guildRoles
        )
        return ConversationPermissionResolver.threadAccess(
            effectivePermissions: permissions,
            isLocked: thread.isLocked
        )
    }
    var selectedChannelID: ChannelID? {
        didSet {
            guard selectedChannelID != oldValue else { return }
            if let oldValue {
                lastTypingRequestAt[oldValue] = nil
            }
            selectedChannel =
                snapshot?.channels.first { $0.id == selectedChannelID }
                    ?? visibleChannels.first { $0.id == selectedChannelID }
            commandLoadTask?.cancel()
            commandAutocompleteTask?.cancel()
            cancelApplicationCommandMemberSearch()
            commandExecutionTask?.cancel()
            commandComposer.resetForChannelChange()
            isVoiceChatOpen = selectedChannel?.kind == .voice
            closeThread()
            if selectedChannel?.kind == .forum {
                beginForumLoad()
            } else {
                beginSelectedChannelLoad()
            }
        }
    }

    var draft = ""
    var threadDraft = ""
    var showInspector = true
    var showQuickSwitcher = false
    var errorMessage: String?

    @ObservationIgnored private var provider: any ChatProvider
    @ObservationIgnored private var database: SakuraCordDatabase?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var localTypingTask: Task<Void, Never>?
    @ObservationIgnored private var localTypingChannelID: ChannelID?
    @ObservationIgnored private var lastTypingRequestAt: [ChannelID: Date] = [:]
    @ObservationIgnored private var localTypingGeneration: UInt64 = 0
    @ObservationIgnored private let localTypingTiming: LocalTypingTiming
    @ObservationIgnored private var profileTask: Task<Void, Never>?
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
    @ObservationIgnored private var pendingMemberUpdate: (guildID: GuildID, members: [Member])?
    @ObservationIgnored private var memberUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var commandExecutionTask: Task<Void, Never>?
    @ObservationIgnored private var stickerLoadTasks: [GuildID: Task<Void, Never>] = [:]
    @ObservationIgnored private var componentKeyByNonce: [String: ComponentControlKey] = [:]
    @ObservationIgnored private var loadingReactionReactors: Set<ReactionReactorLoadKey> = []
    @ObservationIgnored private var failedReactionReactorLoads: [ReactionReactorLoadKey: Date] = [:]
    @ObservationIgnored private let reactionReactorLoadLimiter = ReactionReactorLoadLimiter(
        maximumConcurrentLoads: maximumConcurrentReactionReactorLoads
    )
    @ObservationIgnored private var guildActivationTask: Task<Void, Never>?
    @ObservationIgnored private var memberLoadTask: Task<Void, Never>?
    @ObservationIgnored private var voiceEventTask: Task<Void, Never>?
    @ObservationIgnored private var voiceMigrationTask: Task<Void, Never>?
    @ObservationIgnored private var voiceSession: DiscordVoiceSession?
    @ObservationIgnored private var voiceMigrationGeneration = 0
    @ObservationIgnored private var channelLoadGeneration = 0
    @ObservationIgnored private var messageNavigationRequestID: UInt64 = 0
    @ObservationIgnored private var messageCache: [ChannelID: [Message]] = [:]
    @ObservationIgnored private var hasMoreCache: [ChannelID: Bool] = [:]
    /// Least-recently-selected first. Bounds `messageCache`, which otherwise
    /// retains every channel visited for the whole session.
    @ObservationIgnored private var messageCacheOrder: [ChannelID] = []
    @ObservationIgnored private let discordNetworkDisabled: Bool
    @ObservationIgnored private let restoresStoredSession: Bool
    @ObservationIgnored private let credentialStore: any CredentialStore
    @ObservationIgnored private let authenticatedProviderFactory:
        (CredentialHandle, String?) -> any ChatProvider
    @ObservationIgnored private let persistsEmojiPreferences: Bool
    @ObservationIgnored private var didAttemptSessionRestore = false
    @ObservationIgnored private var credentialHandle: CredentialHandle?
    @ObservationIgnored private var didAttemptDiscordEmojiSettings = false

    init(
        launchMode: AppLaunchMode,
        provider: (any ChatProvider)? = nil,
        discordNetworkDisabledOverride: Bool? = nil,
        restoresStoredSession: Bool = true,
        credentialStore: (any CredentialStore)? = nil,
        authenticatedProviderFactory: ((CredentialHandle, String?) -> any ChatProvider)? = nil,
        typingExpiry: Duration = .seconds(10),
        localTypingTiming: LocalTypingTiming = LocalTypingTiming()
    ) {
        self.launchMode = launchMode
        self.provider =
            provider
                ?? (launchMode == .offlineTesting ? MockChatProvider() : SignedOutChatProvider())
        sessionState = launchMode == .offlineTesting ? .connecting : .restoring
        typingState = TypingStateModel(expiry: typingExpiry)
        self.localTypingTiming = localTypingTiming
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
        await provider.disconnect()
        eventTask?.cancel()
        stopLocalTyping(clearThrottle: true)
        typingState.clearAll()
        if !preservesInteractivePresentation {
            sessionState = .connecting
        }
        let fingerprint = await UserDefaultsDiscordFingerprintStore.shared.load()
        provider = authenticatedProviderFactory(handle, fingerprint)
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
        visibleChannels = []
        selectedChannel = nil
        selectedGuildID = nil
        selectedChannelID = nil
        messages = []
        messageCache = [:]
        hasMoreCache = [:]
        messageCacheOrder = []
        dismissProfile()
        errorMessage = nil
        await start(publishesSessionState: !preservesInteractivePresentation)
        isAuthenticated = snapshot != nil
        sessionState = isAuthenticated ? .workspace : .signedOut
        return isAuthenticated
    }

    func logout() async {
        await leaveVoice()
        await provider.disconnect()
        eventTask?.cancel()
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
        messages = []
        messageCache = [:]
        hasMoreCache = [:]
        messageCacheOrder = []
        cancelPendingMemberUpdate()
        members = []
        dismissProfile()
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
                MainActorWorkDiagnostics.measure(.gatewayEvent) { self?.consume(event) }
            }
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let value = try await provider.bootstrap()
            snapshot = value
            updateServerRail(from: value)
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
                    messages = Self.merging(current: messages, fresh: page.messages)
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

    func completeMessageNavigation(requestID: UInt64) {
        guard messageNavigationRequest?.requestID == requestID else { return }
        messageNavigationRequest = nil
    }

    private func activateGuild(_ guildID: GuildID?) async {
        dismissProfile()
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
            selectedChannelID =
                visibleChannels.first(where: { $0.name == "general" })?.id
                    ?? visibleChannels.first?.id
        }
        beginMemberLoad(for: guildID)
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

    /// Collapses a burst of Gateway member updates into a single applied value.
    private func scheduleMemberUpdate(guildID: GuildID, members value: [Member]) {
        pendingMemberUpdate = (guildID, value)
        guard memberUpdateTask == nil else { return }
        memberUpdateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.memberUpdateCoalescingInterval)
            guard let self else { return }
            memberUpdateTask = nil
            guard let pending = pendingMemberUpdate else { return }
            pendingMemberUpdate = nil
            guard pending.guildID == selectedGuildID else { return }
            applyMemberUpdate(pending.members)
        }
    }

    private func cancelPendingMemberUpdate() {
        memberUpdateTask?.cancel()
        memberUpdateTask = nil
        pendingMemberUpdate = nil
    }

    private func applyMemberUpdate(_ value: [Member]) {
        guard members != value else { return }
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
            let refreshed = mentionAutocompleteMembers.map { updatesByID[$0.id] ?? $0 }
            if refreshed != mentionAutocompleteMembers {
                mentionAutocompleteMembers = refreshed
            }
        }
        if let selectedMember, let updated = value.first(where: { $0.id == selectedMember.id }) {
            self.selectedMember = updated
        }
    }

    private func beginMemberLoad(for guildID: GuildID?) {
        cancelPendingMemberUpdate()
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
        messages = []
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
        for post in posts {
            if let index = forumCatalogueIndexByID[post.id] {
                forumCataloguePosts[index] = post
            } else {
                forumCatalogueIndexByID[post.id] = forumCataloguePosts.endIndex
                forumCataloguePosts.append(post)
            }
        }
    }

    private func replaceForumCatalogue(with posts: [ForumPost]) {
        forumCataloguePosts = posts
        forumCatalogueIndexByID = Dictionary(
            uniqueKeysWithValues: posts.indices.map { (posts[$0].id, $0) }
        )
    }

    private func reconcileForumMessage(_ message: Message) {
        guard let index = forumCatalogueIndexByID[message.channelID] else { return }
        var updated = forumCataloguePosts[index]
        if message.id.rawValue == updated.id.rawValue || updated.firstMessage?.id == message.id {
            updated.firstMessage = message
        }
        if updated.mostRecentMessage == nil || message.timestamp >= updated.lastActivityAt {
            updated.mostRecentMessage = message
            updated.thread.lastMessageID = message.id
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
        isLoadingEarlier = false
        stopLocalTyping(clearThrottle: true)
        replyingTo = nil

        guard let channelID = selectedChannelID,
              selectedChannel?.kind != .voice || isVoiceChatOpen
        else {
            messages = []
            draft = ""
            hasMoreMessages = false
            isLoadingMessages = false
            return
        }

        let cachedMessages = messageCache[channelID] ?? []
        messages = cachedMessages
        hasMoreMessages = hasMoreCache[channelID] ?? false
        draft = ""
        isLoadingMessages = cachedMessages.isEmpty
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
            messages = cached
            isLoadingMessages = false
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
                messages = merged
            }
            hasMoreMessages = page.hasMoreBefore
            hasMoreCache[channelID] = page.hasMoreBefore
            messageLoadError = nil
            isLoadingMessages = false
            try await database?.save(messages: page.messages)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentLoad(channelID, generation: generation) else { return }
            messageLoadError = error.localizedDescription
            isLoadingMessages = false
        }
    }

    func loadEarlier() async {
        guard let channelID = selectedChannelID, let first = messages.first, hasMoreMessages,
              !isLoadingEarlier
        else { return }
        isLoadingEarlier = true
        defer {
            if selectedChannelID == channelID {
                isLoadingEarlier = false
            }
        }
        do {
            let page = try await provider.messages(in: channelID, before: first.id, limit: 50)
            guard !Task.isCancelled, selectedChannelID == channelID else { return }
            let existingIDs = Set(messages.lazy.map(\.id))
            let earlier = page.messages.filter { !existingIDs.contains($0.id) }
            if !earlier.isEmpty {
                messages.insert(contentsOf: earlier, at: 0)
            }
            hasMoreMessages = page.hasMoreBefore
            hasMoreCache[channelID] = page.hasMoreBefore
            messageLoadError = nil
            try await database?.save(messages: page.messages)
        } catch is CancellationError {
            return
        } catch {
            guard selectedChannelID == channelID else { return }
            messageLoadError = error.localizedDescription
        }
    }

    func retryMessageLoad() {
        guard selectedChannelID != nil else { return }
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
        openThread = thread
        openThreadStarter = starter
        openThreadStartedAt = startedAt
        threadMessages = initialMessages
        threadDraft = ""
        isLoadingThread = true
        hasMoreThreadMessages = false
        threadErrorMessage = nil
        threadLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await provider.messages(in: thread.id, before: nil, limit: 100)
                guard !Task.isCancelled, openThread?.id == thread.id else { return }
                threadMessages = page.messages.sorted { $0.timestamp < $1.timestamp }
                hasMoreThreadMessages = page.hasMoreBefore
                isLoadingThread = false
                try await database?.save(messages: page.messages)
            } catch is CancellationError {
                return
            } catch {
                guard openThread?.id == thread.id else { return }
                threadErrorMessage = error.localizedDescription
                isLoadingThread = false
            }
        }
    }

    func closeThread() {
        threadLoadTask?.cancel()
        threadLoadTask = nil
        openThread = nil
        openThreadStarter = nil
        openThreadStartedAt = nil
        threadMessages = []
        threadDraft = ""
        isLoadingThread = false
        isLoadingEarlierThread = false
        hasMoreThreadMessages = false
        threadErrorMessage = nil
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
            try await database?.save(messages: page.messages)
        } catch is CancellationError {
            return
        } catch {
            guard openThread?.id == thread.id else { return }
            threadErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func sendThreadMessage(attachments: [URL] = []) async -> Bool {
        guard let thread = openThread, openThreadAccess.canSend else { return false }
        let content = threadDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !attachments.isEmpty else { return false }
        let draft = SendMessageDraft(
            channelID: thread.id,
            content: content,
            attachmentURLs: attachments
        )
        threadErrorMessage = nil
        threadDraft = ""
        do {
            let message = try await provider.send(draft)
            guard openThread?.id == thread.id else { return true }
            threadMessages.removeAll {
                $0.id == message.id || ($0.nonce != nil && $0.nonce == message.nonce)
            }
            threadMessages.append(message)
            threadMessages.sort { $0.timestamp < $1.timestamp }
            try await database?.save(messages: [message])
            return true
        } catch {
            guard openThread?.id == thread.id else { return false }
            threadDraft = content
            threadErrorMessage = error.localizedDescription
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
        guard let channelID = selectedChannelID, selectedConversationAccess.canSend else {
            return false
        }
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !attachments.isEmpty else { return false }
        let replyTo = replyingTo?.id
        let replyPreview = replyingTo.map {
            MessageReplyPreview(messageID: $0.id, author: $0.author, content: $0.content)
        }
        let outgoing = SendMessageDraft(
            channelID: channelID, content: content, replyTo: replyTo, attachmentURLs: attachments
        )
        stopLocalTyping(clearThrottle: true)
        let optimistic = Message(
            id: MessageID(rawValue: UInt64.max - UInt64(messages.count)), channelID: channelID,
            author: snapshot?.currentUser
                ?? User(id: UserID(rawValue: 1), username: "me", displayName: "Me"),
            content: content, replyTo: replyTo, replyPreview: replyPreview,
            attachments: attachments.enumerated().map {
                Attachment(
                    id: "pending-\($0.offset)", filename: $0.element.lastPathComponent,
                    url: $0.element
                )
            }, nonce: outgoing.nonce, outboxState: .sending
        )
        messages.append(optimistic)
        outgoingDraftsByNonce[outgoing.nonce] = outgoing
        replyingTo = nil
        updateDraft("")
        return await performOutgoingSend(outgoing, isRetry: false)
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
            let confirmed = try await provider.send(outgoing) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.sendProgressByNonce[outgoing.nonce] = progress
                }
            }
            reconcileVisibleOrCached(confirmed)
            sendProgressByNonce[outgoing.nonce] = nil
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
                sendProgressByNonce[outgoing.nonce] = .awaitingReconciliation(nonce: outgoing.nonce)
            } else {
                state = .failed
                sendProgressByNonce[outgoing.nonce] = nil
            }
            updateOutgoingState(state, nonce: outgoing.nonce, channelID: outgoing.channelID)
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
            messages.removeAll { $0.id == message.id }
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
        do {
            try await provider.toggleReaction(
                emoji, messageID: message.id, channelID: message.channelID)
        } catch { errorMessage = error.localizedDescription }
    }

    func loadReactionReactors(_ reaction: Reaction, on message: Message) async {
        guard reaction.count > 0, reaction.reactors.isEmpty else { return }
        let key = ReactionReactorLoadKey(
            channelID: message.channelID,
            messageID: message.id,
            reactionID: reaction.id,
            reactionCount: reaction.count
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
            guard !Task.isCancelled else { return }
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
                    $0.id == key.reactionID && $0.count == key.reactionCount && $0.reactors.isEmpty
                })
            else { return message }
            var result = message
            result.reactions[reactionIndex].reactors = Array(
                normalized.prefix(max(0, key.reactionCount))
            )
            return result
        }

        if key.channelID == selectedChannelID {
            messages = updating(messages)
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
        guard channel.kind == .voice else { return }
        if activeVoiceChannel?.id == channel.id,
           voiceSessionState == .connected || voiceSessionState == .connecting
        {
            return
        }
        await leaveVoice()
        activeVoiceChannel = channel
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
        }
    }

    func leaveVoice() async {
        let guildID = activeVoiceChannel?.guildID
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
    }

    func toggleVoiceMute() async {
        isVoiceMuted.toggle()
        UserDefaults.standard.set(isVoiceMuted, forKey: "voiceMuted")
        await voiceSession?.setMuted(isVoiceMuted)
        await publishVoiceState()
    }

    func toggleVoiceDeafen() async {
        isVoiceDeafened.toggle()
        UserDefaults.standard.set(isVoiceDeafened, forKey: "voiceDeafened")
        await voiceSession?.setDeafened(isVoiceDeafened)
        await publishVoiceState()
    }

    func toggleCamera() async {
        let enabled = !isCameraEnabled
        if voiceSession == nil {
            isCameraEnabled = enabled
            await publishVoiceState()
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

        let session = DiscordVoiceSession(info: info, configuration: currentVoiceConfiguration())
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
            dismissProfile()
            return
        }
        isInspectorProfilePresented = true
        if selectedMember?.id == member.id {
            return
        }
        presentProfile(for: member)
    }

    func showProfile(for user: User) {
        isInspectorProfilePresented = false
        let member =
            membersByID[user.id]
                ?? Member(user: user, roleName: "Member", status: .offline)
        presentProfile(for: member)
    }

    /// Accumulates conversation authors. Writes only land when a new author
    /// appears, so an ordinary incoming message does not invalidate readers.
    private func indexMessageAuthors(in values: [Message], resettingWhenEmpty: Bool) {
        if values.isEmpty, resettingWhenEmpty {
            if !messageAuthorsByID.isEmpty {
                messageAuthorsByID = [:]
                updateAuthorPresentations()
            }
            return
        }
        var additions: [UserID: User] = [:]
        for message in values where messageAuthorsByID[message.author.id] == nil {
            additions[message.author.id] = message.author
        }
        guard !additions.isEmpty else { return }
        messageAuthorsByID.merge(additions) { _, newer in newer }
        updateAuthorPresentations()
    }

    /// Marks a channel as most recently used and drops the oldest beyond the
    /// limit. Eviction only costs a reload on revisit, which is the same path a
    /// first visit already takes; `hasMoreCache` goes with it so the two can
    /// never disagree about how much history is available.
    private func retainMessageCache(for channelID: ChannelID) {
        if let index = messageCacheOrder.firstIndex(of: channelID) {
            messageCacheOrder.remove(at: index)
        }
        messageCacheOrder.append(channelID)

        var excess = messageCacheOrder.count - Self.cachedChannelHistoryLimit
        var index = 0
        while excess > 0, index < messageCacheOrder.count {
            let candidate = messageCacheOrder[index]
            guard candidate != selectedChannelID else {
                index += 1
                continue
            }
            messageCache[candidate] = nil
            hasMoreCache[candidate] = nil
            messageCacheOrder.remove(at: index)
            excess -= 1
        }
    }

    func forumPost(withID channelID: ChannelID) -> ForumPost? {
        if let index = forumCatalogueIndexByID[channelID],
           forumCataloguePosts.indices.contains(index)
        {
            return forumCataloguePosts[index]
        }
        return forumPosts.first { $0.id == channelID }
    }

    /// Rebuilds presentations for authors present in the loaded conversation.
    ///
    /// Scoped to conversation authors rather than the whole guild so a large
    /// member list does not make this proportional to guild size.
    private func updateAuthorPresentations() {
        let value = MainActorWorkDiagnostics.measure(.authorPresentations) {
            var value: [UserID: MessageAuthorPresentation] = [:]
            value.reserveCapacity(messageAuthorsByID.count)
            for userID in messageAuthorsByID.keys {
                guard let member = membersByID[userID] else { continue }
                value[userID] = MessageAuthorPresentation(
                    user: member.user,
                    roleColorHex: MessageAuthorPresentation.topRoleColor(in: member.roles)
                )
            }
            return value
        }
        guard authorPresentationsByUserID != value else { return }
        authorPresentationsByUserID = value
    }

    func authorPresentation(for message: Message) -> MessageAuthorPresentation {
        if let value = authorPresentationsByUserID[message.author.id] {
            return value
        }
        // Authors outside the member store (webhooks, apps, departed members)
        // resolve from the message itself. `guildRoles` changes on guild switch
        // rather than on presence traffic, so reading it here is not hot.
        return MessageAuthorPresentation.resolve(
            message: message,
            member: nil,
            roles: guildRoles
        )
    }

    private func presentProfile(for member: Member) {
        profileTask?.cancel()
        selectedMember = member
        selectedProfile = nil
        profileErrorMessage = nil
        isLoadingProfile = true
        let guildID = selectedGuildID
        profileTask = Task { [weak self] in
            guard let self else { return }
            do {
                var value = try await provider.profile(for: member.id, in: guildID)
                guard !Task.isCancelled, selectedMember?.id == member.id, selectedGuildID == guildID
                else {
                    return
                }
                value.status = member.status
                value.customStatus = member.customStatus
                selectedProfile = value
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, selectedMember?.id == member.id else { return }
                profileErrorMessage = error.localizedDescription
            }
            if selectedMember?.id == member.id {
                isLoadingProfile = false
            }
        }
    }

    func dismissProfile() {
        profileTask?.cancel()
        profileTask = nil
        selectedMember = nil
        selectedProfile = nil
        isLoadingProfile = false
        profileErrorMessage = nil
        isInspectorProfilePresented = false
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

    private func consume(_ event: ClientEvent) {
        switch event {
        case .connectionChanged(let state):
            connectionState = state
            if state != .ready {
                stopLocalTyping(clearThrottle: true)
                typingState.clearAll()
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
                reconcile(message)
            } else {
                cache(message)
            }
            reconcileForumMessage(message)
        case .messageUpdated(let message):
            clearReactionReactorLoadState(
                channelID: message.channelID,
                messageID: message.id
            )
            persist(message)
            if message.channelID == openThread?.id {
                reconcileThread(message)
            }
            if message.channelID == selectedChannelID {
                reconcile(message)
            } else {
                cache(message)
            }
            reconcileForumMessage(message)
        case .messageDeleted(let channelID, let messageID):
            clearReactionReactorLoadState(channelID: channelID, messageID: messageID)
            Task { try? await database?.deleteMessage(messageID) }
            if replyingTo?.id == messageID {
                replyingTo = nil
            }
            if channelID == openThread?.id {
                threadMessages.removeAll { $0.id == messageID }
            }
            if channelID == selectedChannelID {
                messages.removeAll { $0.id == messageID }
            } else {
                messageCache[channelID]?.removeAll { $0.id == messageID }
            }
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
            if guildID == selectedGuildID { visibleChannels = channels }
        case .forumPostsChanged(let channelID, let posts):
            guard channelID == selectedChannelID, selectedChannel?.kind == .forum else { return }
            replaceForumCatalogue(with: posts)
            applyForumPresentation()
            if let openThread, openThread.parentID == channelID,
               !posts.contains(where: { $0.id == openThread.id })
            {
                closeThread()
            }
        case .forumPostPreviewsChanged(let channelID, let posts):
            guard channelID == selectedChannelID, selectedChannel?.kind == .forum else { return }
            mergeForumCatalogue(posts)
            applyForumPresentation()
        case .forumPageLoaded(let channelID, let query, let page):
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
            guard guildID == selectedGuildID else { return }
            scheduleMemberUpdate(guildID: guildID, members: value)
        case .voiceStateChanged(let state):
            if state.channelID == nil {
                voiceStates[state.userID] = nil
            } else {
                voiceStates[state.userID] = state
            }
            if !state.isVideoEnabled {
                voiceVideoFrames[String(state.userID.rawValue)] = nil
            }
        case .voiceServerChanged(let info):
            scheduleVoiceServerMigration(to: info)
        case .snapshotChanged(let value):
            snapshot = value
            updateServerRail(from: value)
            selectGuild(selectedGuildID)
        case .guildChanged(let guild):
            guard var value = snapshot,
                  let index = value.guilds.firstIndex(where: { $0.id == guild.id })
            else { return }
            value.guilds[index] = guild
            snapshot = value
        case .guildLayoutChanged(let guilds, let railItems):
            guard var value = snapshot else { return }
            value.guilds = guilds
            value.guildRailItems = railItems
            snapshot = value
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

    private func reconcile(_ message: Message) {
        var updated = messages
        var resolved = message
        let replacementIndex =
            message.nonce.flatMap { nonce in
                updated.firstIndex(where: { $0.nonce == nonce })
            } ?? updated.firstIndex(where: { $0.id == message.id })
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
            messages = updated
        }
    }

    private func reconcileVisibleOrCached(_ message: Message) {
        if message.channelID == openThread?.id {
            reconcileThread(message)
        }
        if message.channelID == selectedChannelID {
            reconcile(message)
        } else {
            cache(message)
        }
    }

    private func updateOutgoingState(_ state: OutboxState, nonce: String, channelID: ChannelID) {
        if selectedChannelID == channelID,
           let index = messages.firstIndex(where: { $0.nonce == nonce })
        {
            messages[index].outboxState = state
            return
        }
        guard var cached = messageCache[channelID],
              let index = cached.firstIndex(where: { $0.nonce == nonce })
        else { return }
        cached[index].outboxState = state
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
        Task { try? await database?.save(messages: [message]) }
    }

    private func reconcileThread(_ message: Message) {
        if let index = threadMessages.firstIndex(where: {
            $0.id == message.id || ($0.nonce != nil && $0.nonce == message.nonce)
        }) {
            threadMessages.remove(at: index)
            if let duplicateIndex = threadMessages.firstIndex(where: { $0.id == message.id }) {
                threadMessages.remove(at: duplicateIndex)
            }
            Self.insert(message, intoSorted: &threadMessages)
        } else {
            Self.insert(message, intoSorted: &threadMessages)
        }
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

struct MessageRowPresentation: Identifiable, Equatable {
    var id: MessageID {
        message.id
    }

    let message: Message
    let startsGroup: Bool
    let startsDay: Bool
    let replyPreview: MessageReplyPreview?
    let isReplyAvailable: Bool
}

enum MessageGrouping {
    /// Discord's current cozy layout uses a seven-minute continuation barrier.
    private static let continuationInterval: TimeInterval = 7 * 60

    static func rows(for messages: [Message], calendar: Calendar = .autoupdatingCurrent)
        -> [MessageRowPresentation]
    {
        var messagesByID: [MessageID: Message] = [:]
        if messages.contains(where: { $0.replyTo != nil }) {
            messagesByID.reserveCapacity(messages.count)
            for message in messages {
                messagesByID[message.id] = message
            }
        }
        return messages.enumerated().map { index, message in
            let replyPreview = message.replyTo.flatMap { messageID -> MessageReplyPreview? in
                if let referenced = messagesByID[messageID] {
                    return MessageReplyPreview(
                        messageID: referenced.id, author: referenced.author,
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
                    isReplyAvailable: replyPreview.map { messagesByID[$0.messageID] != nil }
                        ?? false
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

    private static func isGroupable(_ message: Message) -> Bool {
        !message.type.hasGeneratedContent && message.type != .chatInputCommand
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
                let byID = Dictionary(uniqueKeysWithValues: newMessages.map { ($0.id, $0) })
                var result =
                    rows(for: Array(newMessages.prefix(insertedCount)), calendar: calendar)
                        + existing
                var affected = Set([insertedCount])
                let insertedIDs = Set(newMessages.prefix(insertedCount).map(\.id))
                for (index, message) in newMessages.enumerated()
                    where message.replyTo.map(insertedIDs.contains) == true {
                    affected.insert(index)
                }
                for index in affected where newMessages.indices.contains(index) {
                    result[index] = presentation(
                        at: index, in: newMessages, messagesByID: byID, calendar: calendar
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
