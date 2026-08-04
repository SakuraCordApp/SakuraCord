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

enum ServerRailNavigationDestination: Equatable {
    case directMessages
    case guild(GuildID)
}

@Observable
final class AppModel {
    enum ThreadErrorScope {
        case initialPage
        case earlierPage
        case action
    }

    struct CommandMemberQuery: Hashable {
        var guildID: GuildID
        var query: String
    }

    struct MentionMemberSearchCacheEntry {
        var members: [Member]
        var storedAt: Date
    }

    struct ReactionReactorLoadKey: Hashable {
        var channelID: ChannelID
        var messageID: MessageID
        var reactionID: String
    }

    struct ReactionMutationKey: Hashable {
        var channelID: ChannelID
        var messageID: MessageID
        var reactionID: String
    }

    struct ReactionMutationState {
        var emoji: String
        var confirmedReacted: Bool
        var desiredReacted: Bool
        var generation: UInt64
        var isSending: Bool
    }

    static let messageSendLogger = Logger(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "MessageSend"
    )
    static let unreadDiagnosticsLogger = Logger(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "Unread"
    )
    static let forumPerformanceSignposter = OSSignposter(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "PointsOfInterest"
    )
    nonisolated static let maximumConcurrentReactionReactorLoads = 4

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

    struct ReactionMutationTiming: Sendable {
        var debounce: Duration = .milliseconds(160)
    }

    struct ReadAcknowledgementTiming: Sendable {
        var debounce: Duration = .zero
    }

    struct ReadStateMutation: Sendable {
        var messageID: MessageID
        var manual: Bool
        var mentionCount: Int?
        var flags: UInt64?
        var lastViewed: Int
    }

    var snapshot: BootstrapSnapshot?
    var serverRailGuildsByID: [GuildID: Guild] = [:]
    var serverRailItems: [GuildRailItem] = [] {
        didSet { updateOrderedCustomEmojis() }
    }
    var visibleChannels: [Channel] = []
    var hiddenChannelIDs: Set<ChannelID> = []
    var checkingChannelIDs: Set<ChannelID> = []
    var selectedChannel: Channel?
    @ObservationIgnored var messages: [Message] = []
    @ObservationIgnored var messageRows: [MessageRowPresentation] = []
    @ObservationIgnored var messageRowsRevision: UInt64 = 0
    var timelinePresentationRevision: UInt64 = 0
    @ObservationIgnored var messageRowsUpdateHint:
        MessageRowsUpdateHint?
    @ObservationIgnored let messageRowsUpdateJournal =
        MessageRowsUpdateJournal()
    @ObservationIgnored let timelineSpoilerRevealStore =
        NativeTimelineSpoilerRevealStore()
    @ObservationIgnored var latestMessageRowsRevision: UInt64 = 0
    @ObservationIgnored var messageRowsNonAppendRevision: UInt64 = 0
    @ObservationIgnored var selectedMessageIDs: Set<MessageID> = []
    @ObservationIgnored var selectedMessageStoredIndexByID:
        [MessageID: Int] = [:]
    /// Stored indexes use a movable origin so prepending a history page does
    /// not rewrite every existing message's dictionary value. A logical array
    /// index is `stored - selectedMessageIndexOrigin`.
    @ObservationIgnored var selectedMessageIndexOrigin = 0
    @ObservationIgnored var selectedReplyMessageIDsByTarget:
        [MessageID: Set<MessageID>] = [:]
    var messageNavigationRequest: MessageNavigationRequest?
    var conversationNewestRequest: ConversationNewestRequest?
    var mediaViewerPresentation: NativeTimelineMediaViewerPresentation?
    var unreadDividerMessageIDs: [ChannelID: MessageID] = [:]
    var members: [Member] = [] {
        didSet {
            guard oldValue != members else { return }
            let previousMembersByID = membersByID
            if !defersMemberPresentationRebuild {
                rebuildMemberSections()
            }
            let indexed = mergedMemberStore(with: members)
            if membersByID != indexed {
                membersByID = indexed
            }
            var permissionsChanged = false
            if let guildID = selectedGuildID,
               let currentUserID = snapshot?.currentUser.id,
               let currentMember = indexed[currentUserID]
            {
                let roleIDs = Set(currentMember.roles.map(\.id))
                if currentUserRoleIDsByGuild[guildID] != roleIDs {
                    currentUserRoleIDsByGuild[guildID] = roleIDs
                    readState.updateCurrentUserRoles(roleIDs, guildID: guildID)
                    permissionsChanged = true
                }
            }
            if permissionsChanged {
                refreshUnreadPresentation(appliesAccessImmediately: true)
            }
            if !defersMemberPresentationRebuild {
                publishTimelineMemberPresentationChanges(
                    from: previousMembersByID,
                    to: indexed
                )
            }
        }
    }

    var membersByID: [UserID: Member] = [:]
    @ObservationIgnored var membersByGuildID: [GuildID: [UserID: Member]] = [:]
    @ObservationIgnored var memberListsByGuildID: [GuildID: [Member]] = [:]
    @ObservationIgnored var memberListGroupsByGuildID: [GuildID: [GuildMemberListGroup]] = [:]
    @ObservationIgnored var defersMemberPresentationRebuild = false
    var memberSections: [MemberSection] = []
    var memberListGroups: [GuildMemberListGroup] = [] {
        didSet {
            if oldValue != memberListGroups, !defersMemberPresentationRebuild {
                rebuildMemberSections()
            }
        }
    }
    var guildRoles: [GuildRole] = [] {
        didSet {
            let presentationChanged = oldValue != guildRoles
            if presentationChanged, !defersMemberPresentationRebuild {
                rebuildMemberSections()
                AppPerformanceSignposts.signposter.emitEvent(
                    "TimelineInvalidationGuildRoles"
                )
                invalidateTimelinePresentation()
            }
        }
    }
    @ObservationIgnored var guildRolesByGuildID: [GuildID: [GuildRole]] = [:]
    var commandMemberResults: [Member] = []
    var mentionMemberResults: [Member] = []
    var mentionAutocompleteMembers: [Member] = []
    var knownMentionMembers: [UserID: Member] = [:] {
        didSet {
            if oldValue != knownMentionMembers {
                AppPerformanceSignposts.signposter.emitEvent(
                    "TimelineInvalidationKnownMentionMembers"
                )
                invalidateTimelinePresentation()
            }
        }
    }
    var roleMemberResult: RoleMemberResult?
    var isLoadingRoleMembers = false
    var roleMemberErrorMessage: String?
    var currentStatus: PresenceStatus = .offline
    var connectionState: ConnectionState = .disconnected
    var isAuthenticated = false
    var isSwitchingAccounts = false
    var savedAccounts: [SavedAccount] = []
    var activeAccountID: String?
    var sessionState: SessionState
    let launchMode: AppLaunchMode
    let typingState: TypingStateModel
    let commandComposer = ApplicationCommandComposerModel()
    let readState = AccountReadStateModel()
    let notificationPreferences: NotificationPreferences
    @ObservationIgnored let notificationService: any NativeNotificationService
    @ObservationIgnored let soundPlayer: any AppSoundPlaying
    var isLoading = false
    var isLoadingMessages = false
    var hasCompletedInitialMessageLoad = false
    var isLoadingEarlier = false
    var hasMoreMessages = false
    var messageLoadError: String?
    @ObservationIgnored var messageLoadErrorIsEarlierPage = false
    var forumPosts: [ForumPost] = []
    var forumCataloguePosts: [ForumPost] = []
    var forumCatalogueIndexByID: [ChannelID: Int] = [:]
    var forumRecentPostCount = 0
    var forumRecentPosts: ArraySlice<ForumPost> { forumPosts.prefix(forumRecentPostCount) }
    var forumOlderPosts: ArraySlice<ForumPost> { forumPosts.dropFirst(forumRecentPostCount) }
    var isLoadingForumPosts = false
    var isSearchingForumPosts = false
    var hasLoadedForumPosts = false
    var isLoadingMoreForumPosts = false
    var hasMoreForumPosts = false
    var forumPostError: String?
    var forumActionError: String?
    var forumPaginationError: String?
    var forumCreateProgress: MessageSendProgress?
    var forumCreateGeneration: UInt64 = 0
    var forumSearchText = ""
    var forumSelectedTagIDs: Set<ForumTagID> = []
    var forumSortOrder: ForumSortOrder = .latestActivity
    var forumLayout: ForumLayout = .list
    var forumTagMatch: ForumTagMatch = .matchSome
    var replyingTo: Message?
    var threadReplyingTo: Message?
    var presentedInteractionModal: InteractionModal?
    var interactionModalNonce: String?
    var interactionErrorMessage: String?
    var isVoiceChatOpen = false
    var openThread: MessageThreadSummary?
    var openThreadStarter: User?
    var openThreadStartedAt: Date?
    var threadMessages: [Message] = [] {
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
    @ObservationIgnored var threadMessageRows:
        [MessageRowPresentation] = []
    @ObservationIgnored var threadMessageRowsUpdateHint:
        MessageRowsUpdateHint?
    @ObservationIgnored let threadMessageRowsUpdateJournal =
        MessageRowsUpdateJournal()
    @ObservationIgnored var threadMessageRowsRevision: UInt64 = 0
    var isLoadingThread = false
    var hasCompletedInitialThreadLoad = false
    var isLoadingEarlierThread = false
    var hasMoreThreadMessages = false
    var threadErrorMessage: String?
    @ObservationIgnored var threadErrorScope: ThreadErrorScope?
    var canRetryThreadLoad: Bool {
        threadErrorScope == .initialPage
            || threadErrorScope == .earlierPage
    }
    var outgoingDraftsByNonce: [String: SendMessageDraft] = [:]
    var gifResults: [GIFSearchResult] = []
    var isLoadingGIFs = false
    var gifErrorMessage: String?
    var stickersByGuild: [GuildID: [MessageSticker]] = [:]
    var supportedCapabilities: Set<ChatCapability> = []
    var pendingComponentControls: Set<ComponentControlKey> = []
    var componentErrors: [ComponentControlKey: String] = [:]
    var inspectorProfilePresentation:
        ProfilePresentationState?
    var contextualProfilePresentation:
        ProfilePresentationState?
    var isInspectorProfilePresented = false
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
    var activeVoiceChannel: Channel?
    var voiceSessionState: VoiceSessionState = .idle
    var voiceParticipants: [VoiceRemoteParticipant] = []
    var isLocallySpeaking = false
    var voiceVideoFrames: [String: VoiceVideoFrame] = [:]
    var voiceEncryptionVersion: UInt16?
    var voiceLatencyMilliseconds: Int?
    var voiceErrorMessage: String?
    var voiceStates: [UserID: VoiceParticipantState] = [:]
    var privateCallsByChannel: [ChannelID: PrivateCall] = [:]
    var privateCallActionChannelIDs: Set<ChannelID> = []
    var mediaDevices: MediaDeviceSnapshot = .empty
    var emojisByGuild: [GuildID: [DiscordEmoji]] = [:] {
        didSet { updateOrderedCustomEmojis() }
    }
    var loadingEmojiGuildIDs: Set<GuildID> = []
    var emojiLoadErrorsByGuild: [GuildID: String] = [:]
    var favoriteEmojiKeys: Set<String>
    var emojiUsageCounts: [String: Int]
    var discordFavoriteEmojiKeys: [String] = []
    var discordFrequentlyUsedEmojiKeys: [String] = []
    var discordEmojiUsageScores: [String: Int] = [:]
    var discordGuildAndChannelUsageScores: [String: Int] = [:]
    var hasLoadedDiscordEmojiSettings = false
    var orderedCustomEmojis: [DiscordEmoji] = []
    var customEmojiURLsByID: [String: URL] = [:]

    func updateOrderedCustomEmojis() {
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

    func isPrivateCallActionInFlight(in channelID: ChannelID) -> Bool {
        privateCallActionChannelIDs.contains(channelID)
    }
    var selectedConversationAccess: ConversationAccess {
        guard let channel = selectedChannel else { return .checking }
        return conversationAccess(for: channel)
    }

    var canCreateForumPosts: Bool {
        !presentsCachedStartup
            && selectedConversationAccess.canSend
            && supportedCapabilities.contains(.forums)
    }

    var canManageForumPosts: Bool {
        guard !presentsCachedStartup else { return false }
        guard let permissions = selectedEffectivePermissions else { return false }
        return permissions & DiscordPermissionBits.manageThreads != 0
    }

    func canDeleteForumPost(_ post: ForumPost) -> Bool {
        guard !presentsCachedStartup else { return false }
        return Self.canDeleteForumPost(
            ownerID: post.thread.ownerID ?? post.owner?.id,
            currentUserID: snapshot?.currentUser.id,
            canManage: canManageForumPosts
        )
    }

    func canArchiveForumPost(_ post: ForumPost) -> Bool {
        guard !presentsCachedStartup else { return false }
        if canManageForumPosts { return true }
        guard !post.thread.isLocked else { return false }
        let ownerID = post.thread.ownerID ?? post.owner?.id
        return ownerID != nil && ownerID == snapshot?.currentUser.id
    }

    func canEditForumPostTags(_ post: ForumPost) -> Bool {
        guard !presentsCachedStartup else { return false }
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

    var selectedEffectivePermissions: UInt64? {
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
        let member =
            membersByGuildID[guildID]?[currentUserID]
            ?? (guildID == selectedGuildID ? membersByID[currentUserID] : nil)
        let roles =
            guildRolesByGuildID[guildID]
            ?? (guildID == selectedGuildID ? guildRoles : [])
        let permissions = ConversationPermissionResolver.effectivePermissions(
            guild: guild,
            channel: channel,
            currentUserID: currentUserID,
            currentMember: member,
            roles: roles,
            currentRoleIDs: currentUserRoleIDsByGuild[guildID]
        )
        if channel.kind == .voice {
            return ConversationPermissionResolver.voiceChannelAccess(
                effectivePermissions: permissions
            )
        }
        return ConversationPermissionResolver.channelAccess(effectivePermissions: permissions)
    }

    func canJoinVoice(_ channel: Channel) -> Bool {
        guard channel.kind == .voice
                || channel.kind == .directMessage
                || channel.kind == .groupDirectMessage
        else { return false }
        return conversationAccess(for: channel).isReadable
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
            if let selectedChannelID {
                AppPerformanceSignposts.ensureConversationNavigation(
                    to: selectedChannelID
                )
            } else {
                AppPerformanceSignposts.cancelConversationNavigation()
            }
            dismissInspectorProfile()
            if let oldValue {
                cancelConversationRefresh(in: oldValue)
                unreadDividerMessageIDs[oldValue] = nil
                if conversationNewestRequest?.channelID == oldValue {
                    conversationNewestRequest = nil
                }
                storeCachedMessages(messages, for: oldValue)
                storeCachedMessageRows(messageRows, for: oldValue)
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
                    hasReachedReadBoundary: false,
                    blocksAutomaticAcknowledgement: presentsCachedStartup
                )
            }
            if selectedChannel?.kind == .forum {
                if let selectedChannelID {
                    readState.beginForumVisit(channelID: selectedChannelID)
                }
                if !presentsCachedStartup {
                    beginForumLoad()
                }
            } else {
                beginSelectedChannelLoad()
            }
            if let channel = selectedChannel,
               !presentsCachedStartup,
               channel.kind == .directMessage || channel.kind == .groupDirectMessage
            {
                let account = accountSession()
                startAccountChildTask(account: account) { model, account in
                    await model.observePrivateCall(in: channel, account: account)
                }
            }
        }
    }

    var draft = ""
    var threadDraft = ""
    var channelComposerAttachments: [ForumPostAttachment] = []
    var threadComposerAttachments: [ForumPostAttachment] = []
    var showInspector = true
    var errorMessage: String?

    @ObservationIgnored var provider: any ChatProvider
    @ObservationIgnored var database: SakuraCordDatabase?
    @ObservationIgnored var accountSessionGeneration: UInt64 = 0
    @ObservationIgnored var installedAccountSessionRevision: UInt64 = 0
    @ObservationIgnored let accountTransitionCoordinator = AccountTransitionCoordinator()
    @ObservationIgnored var accountTransitionIsActive = false
    @ObservationIgnored var accountChildTasks: [UUID: Task<Void, Never>] = [:]
    var presentsCachedStartup = false
    @ObservationIgnored let runsChatPerformanceBenchmark: Bool
    @ObservationIgnored var eventTask: Task<Void, Never>?
    @ObservationIgnored var locallyStartedOutgoingPrivateCallRings:
        Set<ChannelID> = []
    @ObservationIgnored var outgoingPrivateCallRingTimeoutTasks:
        [ChannelID: Task<Void, Never>] = [:]
    @ObservationIgnored var pendingCreatedMessages:
        [PreparedCreatedMessage] = []
    @ObservationIgnored var createdMessageFlushTask: Task<Void, Never>?
    @ObservationIgnored var isFlushingCreatedMessageBatch = false
    @ObservationIgnored var batchedSelectedMessages: [Message] = []
    @ObservationIgnored var batchedSelectedTextPlansByID:
        [MessageID: NativeTimelineTextPlan] = [:]
    @ObservationIgnored var batchedUnreadPresentationNeedsRefresh =
        false
    @ObservationIgnored var hasDeferredUnreadPresentationRefresh = false
    @ObservationIgnored var batchedAcknowledgementChannelIDs:
        Set<ChannelID> = []
    @ObservationIgnored let maximumCreatedMessagesPerFlush = 4
    @ObservationIgnored var localTypingTask: Task<Void, Never>?
    @ObservationIgnored var localTypingChannelID: ChannelID?
    @ObservationIgnored var lastTypingRequestAt: [ChannelID: Date] = [:]
    @ObservationIgnored var localTypingGeneration: UInt64 = 0
    @ObservationIgnored let localTypingTiming: LocalTypingTiming
    @ObservationIgnored var inspectorProfileTask:
        Task<Void, Never>?
    @ObservationIgnored var contextualProfileTask:
        Task<Void, Never>?
    @ObservationIgnored var profileCache:
        [ProfileCacheKey: UserProfile] = [:]
    @ObservationIgnored var channelLoadTask: Task<Void, Never>?
    @ObservationIgnored var conversationRefreshJournals:
        [ChannelID: ConversationRefreshJournal] = [:]
    @ObservationIgnored var conversationRefreshJournalRevision: UInt64 = 0
    @ObservationIgnored var forumLoadTask: Task<Void, Never>?
    @ObservationIgnored var forumNextOffset: Int?
    @ObservationIgnored var forumLoadGeneration: UInt64 = 0
    @ObservationIgnored var threadLoadTask: Task<Void, Never>?
    @ObservationIgnored var gifSearchTask: Task<Void, Never>?
    @ObservationIgnored var commandLoadTask: Task<Void, Never>?
    @ObservationIgnored var commandAutocompleteTask: Task<Void, Never>?
    @ObservationIgnored var commandMemberSearchTask: Task<Void, Never>?
    @ObservationIgnored var commandMemberSearchQuery: CommandMemberQuery?
    @ObservationIgnored var commandMemberSearchCache: [CommandMemberQuery: [Member]] = [:]
    @ObservationIgnored var mentionMemberSearchTask: Task<Void, Never>?
    @ObservationIgnored var mentionMemberSearchQuery: CommandMemberQuery?
    @ObservationIgnored var mentionMemberSearchCache:
        [CommandMemberQuery: MentionMemberSearchCacheEntry] = [:]
    @ObservationIgnored var roleMemberTask: Task<Void, Never>?
    @ObservationIgnored var commandExecutionTask: Task<Void, Never>?
    @ObservationIgnored var stickerLoadTasks: [GuildID: Task<Void, Never>] = [:]
    @ObservationIgnored var stickerLoadGeneration: UInt64 = 0
    @ObservationIgnored var componentKeyByNonce: [String: ComponentControlKey] = [:]
    @ObservationIgnored var loadingReactionReactors: Set<ReactionReactorLoadKey> = []
    @ObservationIgnored var failedReactionReactorLoads: [ReactionReactorLoadKey: Date] = [:]
    @ObservationIgnored var liveScrollingConversationIDs:
        Set<ChannelID> = []
    @ObservationIgnored var timelineScrollActivityRevision: UInt64 = 0
    @ObservationIgnored let reactionReactorLoadLimiter = ReactionReactorLoadLimiter(
        maximumConcurrentLoads: maximumConcurrentReactionReactorLoads
    )
    @ObservationIgnored var reactionMutations:
        [ReactionMutationKey: ReactionMutationState] = [:]
    @ObservationIgnored var reactionMutationTasks:
        [ReactionMutationKey: Task<Void, Never>] = [:]
    @ObservationIgnored let reactionMutationTiming: ReactionMutationTiming
    @ObservationIgnored var guildActivationTask: Task<Void, Never>?
    @ObservationIgnored var memberLoadTask: Task<Void, Never>?
    @ObservationIgnored var memberLoadGeneration: UInt64 = 0
    @ObservationIgnored var voiceEventTask: Task<Void, Never>?
    @ObservationIgnored var voiceMigrationTask: Task<Void, Never>?
    @ObservationIgnored var voiceSession: DiscordVoiceSession?
    @ObservationIgnored var voiceMigrationGeneration = 0
    @ObservationIgnored var privateCallActionGeneration: UInt64 = 0
    @ObservationIgnored var channelLoadGeneration = 0
    @ObservationIgnored var messageNavigationRequestID: UInt64 = 0
    @ObservationIgnored var conversationNewestRequestID: UInt64 = 0
    @ObservationIgnored var messageCache: [ChannelID: [Message]] = [:]
    @ObservationIgnored var messageCacheOrder: [ChannelID] = []
    @ObservationIgnored var messageRowCache:
        [ChannelID: [MessageRowPresentation]] = [:]
    @ObservationIgnored var messageRowCacheOrder: [ChannelID] = []
    @ObservationIgnored var hasMoreCache: [ChannelID: Bool] = [:]
    @ObservationIgnored let discordNetworkDisabled: Bool
    @ObservationIgnored let usesInsecureDebugCredentials: Bool
    @ObservationIgnored let restoresStoredSession: Bool
    @ObservationIgnored let credentialStore: any CredentialStore
    @ObservationIgnored let savedAccountStore: any SavedAccountStoring
    @ObservationIgnored let authenticatedProviderFactory:
        (CredentialHandle, String?) -> any ChatProvider
    @ObservationIgnored let pendingAuthenticatedProviderFactory:
        (PendingDiscordCredential, String?) -> any PendingCredentialChatProvider
    @ObservationIgnored let accountDatabaseFactory:
        (AccountID) -> SakuraCordDatabase?
    @ObservationIgnored let persistsEmojiPreferences: Bool
    @ObservationIgnored var didAttemptSessionRestore = false
    @ObservationIgnored var credentialHandle: CredentialHandle?
    @ObservationIgnored var didAttemptDiscordEmojiSettings = false
    @ObservationIgnored var acknowledgementTasks: [ChannelID: Task<Void, Never>] = [:]
    @ObservationIgnored var queuedAcknowledgements: [ChannelID: ReadStateMutation] = [:]
    @ObservationIgnored var acknowledgementQueueOrder: [ChannelID] = []
    @ObservationIgnored var acknowledgementProcessorTask: Task<Void, Never>?
    @ObservationIgnored var acknowledgementGeneration = 0
    @ObservationIgnored var guildAcknowledgementTasks:
        [GuildID: Task<Void, Never>] = [:]
    @ObservationIgnored var guildNotificationMutationTasks:
        [GuildID: Task<Void, Never>] = [:]
    @ObservationIgnored var channelNotificationMutationTasks:
        [ChannelID: Task<Void, Never>] = [:]
    @ObservationIgnored var channelNotificationMutationGeneration = 0
    @ObservationIgnored var forumNotificationMutationTasks:
        [ChannelID: Task<Void, Never>] = [:]
    @ObservationIgnored var forumNotificationMutationGeneration = 0
    @ObservationIgnored var mainWindowIsActive = false
    @ObservationIgnored var clientAppStateUpdateTask: Task<Void, Never>?
    @ObservationIgnored var currentUserRoleIDsByGuild: [GuildID: Set<RoleID>] = [:]
    @ObservationIgnored let readAcknowledgementTiming: ReadAcknowledgementTiming

    init(
        launchMode: AppLaunchMode,
        provider: (any ChatProvider)? = nil,
        discordNetworkDisabledOverride: Bool? = nil,
        usesInsecureDebugCredentialsOverride: Bool? = nil,
        restoresStoredSession: Bool = true,
        credentialStore: (any CredentialStore)? = nil,
        savedAccountStore: (any SavedAccountStoring)? = nil,
        authenticatedProviderFactory: ((CredentialHandle, String?) -> any ChatProvider)? = nil,
        pendingAuthenticatedProviderFactory:
            ((PendingDiscordCredential, String?) -> any PendingCredentialChatProvider)? = nil,
        accountDatabaseFactory: ((AccountID) -> SakuraCordDatabase?)? = nil,
        notificationService: (any NativeNotificationService)? = nil,
        soundPlayer: (any AppSoundPlaying)? = nil,
        notificationPreferences: NotificationPreferences? = nil,
        typingExpiry: Duration = .seconds(10),
        localTypingTiming: LocalTypingTiming = LocalTypingTiming(),
        reactionMutationTiming: ReactionMutationTiming = ReactionMutationTiming(),
        readAcknowledgementTiming: ReadAcknowledgementTiming = ReadAcknowledgementTiming(),
        runsChatPerformanceBenchmarkOverride: Bool? = nil
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
        self.reactionMutationTiming = reactionMutationTiming
        self.readAcknowledgementTiming = readAcknowledgementTiming
        runsChatPerformanceBenchmark =
            runsChatPerformanceBenchmarkOverride
                ?? AppLaunchConfiguration(
                    arguments: ProcessInfo.processInfo.arguments
                ).runsChatPerformanceAutoScroll
        discordNetworkDisabled =
            discordNetworkDisabledOverride
                ?? (launchMode == .offlineTesting
                    || ProcessInfo.processInfo.environment["SAKURACORD_DISABLE_DISCORD_NETWORK"] == "1")
        self.restoresStoredSession = restoresStoredSession
        usesInsecureDebugCredentials =
            usesInsecureDebugCredentialsOverride
                ?? (launchMode == .normal
                    && Bundle.main.object(
                        forInfoDictionaryKey: "SakuraCordInsecureDebugCredentialsEnabled"
                    ) as? Bool == true)
        let defaultCredentialStore: any CredentialStore
        if launchMode == .offlineTesting {
            defaultCredentialStore = OfflineCredentialStore()
        } else if usesInsecureDebugCredentials {
            defaultCredentialStore = InsecureDebugMigratingCredentialStore()
        } else {
            defaultCredentialStore = KeychainCredentialStore()
        }
        let resolvedCredentialStore = credentialStore ?? defaultCredentialStore
        self.credentialStore = resolvedCredentialStore
        self.savedAccountStore = savedAccountStore ?? UserDefaultsSavedAccountStore.shared
        self.authenticatedProviderFactory =
            authenticatedProviderFactory ?? { handle, installationID in
                DiscordRESTProvider(
                    credentials: resolvedCredentialStore,
                    handle: handle,
                    installationID: installationID
                )
            }
        self.pendingAuthenticatedProviderFactory =
            pendingAuthenticatedProviderFactory ?? { credential, installationID in
                DiscordRESTProvider(
                    pendingCredential: credential,
                    installationID: installationID
                )
            }
        self.accountDatabaseFactory = accountDatabaseFactory ?? { accountID in
            try? SakuraCordDatabase(accountID: accountID)
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
        // A normal launch does not know the account yet. Opening the historical
        // account-1 fallback here only to replace it during credential restore
        // duplicates filesystem and SQLite work on every startup.
        database = launchMode == .offlineTesting
            ? try? SakuraCordDatabase(inMemory: true)
            : nil
        commandComposer.configureFrecencyScope(
            launchMode == .offlineTesting ? "offline" : "signed-out"
        )
        readState.reset(accountID: launchMode == .offlineTesting ? "offline" : nil)
    }
}
