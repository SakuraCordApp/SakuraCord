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

nonisolated struct ConversationPermissionBasis: Sendable {
    let guild: Guild
    let resolvedBasePermissions: UInt64?
    let overwritePrincipals: PermissionOverwritePrincipals
    let hasCurrentRoleIdentity: Bool
    let currentUserIsPending: Bool
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

    struct MemberListViewportRequest: Equatable {
        var guildID: GuildID
        var channelID: ChannelID
        var visibleRange: ClosedRange<Int>
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
    static let memberListLogger = Logger(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "MemberList"
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

    struct CategoryCollapseMutationState {
        var guildID: GuildID
        var confirmedCollapsed: Bool
        var desiredCollapsed: Bool
    }

    var snapshot: BootstrapSnapshot? {
        didSet {
            snapshotSourceRevision &+= 1
            if oldValue?.currentUser != snapshot?.currentUser {
                refreshVoiceSidebarPresentation()
            }
        }
    }
    @ObservationIgnored let serverRailPresentation =
        ServerRailPresentationStore()
    @ObservationIgnored let voiceSidebarPresentation =
        VoiceSidebarPresentationStore()
    var serverRailGuildsByID: [GuildID: Guild] = [:]
    var serverRailHomeIsUnread = false {
        didSet {
            serverRailPresentation.home.isUnread = serverRailHomeIsUnread
        }
    }
    var serverRailHomeMentionCount = 0 {
        didSet {
            serverRailPresentation.home.mentionCount =
                serverRailHomeMentionCount
        }
    }
    var serverRailItems: [GuildRailItem] = [] {
        didSet {
            serverRailPresentation.updateLayout(serverRailItems)
            requestOrderedCustomEmojiUpdate()
        }
    }
    var visibleChannels: [Channel] = [] {
        didSet {
            visibleChannelGroups = AppPerformanceSignposts.measureSync(
                "ChannelSidebarGrouping"
            ) {
                ChannelGroup.make(from: visibleChannels)
            }
        }
    }
    var visibleChannelGroups: [ChannelGroup] = []
    var unreadCategoryIDsByGuild: [GuildID: Set<ChannelID>] = [:]
    var hiddenChannelIDs: Set<ChannelID> = []
    var checkingChannelIDs: Set<ChannelID> = []
    var selectedChannel: Channel?
    var workspaceNavigationOverlay: WorkspaceNavigationOverlay?
    let messageSearch = MessageSearchState()
    @ObservationIgnored var lastOpenedChannelIDsByGuild: [GuildID: ChannelID] = [:]
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
            refreshVoiceSidebarPresentation(using: indexed)
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
                refreshUnreadPresentation(
                    appliesAccessImmediately: true,
                    accessAffectedGuildIDs: selectedGuildID.map { [$0] }
                )
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
    var isLoadingLater = false
    var hasMoreMessages = false
    var hasMoreLaterMessages = false
    var messageLoadError: String?
    @ObservationIgnored var messageLoadErrorIsEarlierPage = false
    @ObservationIgnored var messageLoadErrorIsLaterPage = false
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
    var forwardingMessage: Message?
    var forwardingErrorMessage: String?
    var isForwardingMessages = false
    var forwardDestinationHistory: [ChannelID] = []
    var quickSwitcherDraftChannelIDs: [ChannelID] = []
    var forwardSearchSourceRevision: UInt64 = 0
    var forumCreateGeneration: UInt64 = 0
    var forumSearchText = ""
    var forumSelectedTagIDs: Set<ForumTagID> = []
    var forumSortOrder: ForumSortOrder = .latestActivity
    var forumLayout: ForumLayout = .list
    var forumTagMatch: ForumTagMatch = .matchSome
    var replyingTo: Message?
    var threadReplyingTo: Message?
    var replyMentionsAuthor = true
    var threadReplyMentionsAuthor = true
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
    var gifCategories: [GIFPickerCategory] = []
    var gifTrendingPreviewURL: URL?
    var favoriteGIFs: [GIFSearchResult] = []
    var isLoadingGIFs = false
    var isLoadingGIFPicker = false
    var gifErrorMessage: String?
    var gifFavoriteMutationURL: URL?
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
    var activeVoiceChannel: Channel? {
        didSet {
            guard oldValue != activeVoiceChannel else { return }
            refreshVoiceSidebarPresentation()
        }
    }
    var voiceSessionState: VoiceSessionState = .idle
    var voiceParticipants: [VoiceRemoteParticipant] = []
    var isLocallySpeaking = false
    var voiceVideoFrames: [String: VoiceVideoFrame] = [:]
    var voiceEncryptionVersion: UInt16?
    var voiceLatencyMilliseconds: Int?
    var voiceErrorMessage: String?
    var voiceStates: [UserID: VoiceParticipantState] = [:] {
        didSet {
            guard oldValue != voiceStates else { return }
            refreshVoiceSidebarPresentation()
        }
    }
    var privateCallsByChannel: [ChannelID: PrivateCall] = [:]
    var privateCallActionChannelIDs: Set<ChannelID> = []
    var mediaDevices: MediaDeviceSnapshot = .empty
    var emojisByGuild: [GuildID: [DiscordEmoji]] = [:] {
        didSet { requestOrderedCustomEmojiUpdate() }
    }
    var loadingEmojiGuildIDs: Set<GuildID> = []
    var emojiLoadErrorsByGuild: [GuildID: String] = [:]
    var favoriteEmojiKeys: Set<String>
    var emojiUsageCounts: [String: Int]
    var discordFavoriteEmojiKeys: [String] = []
    var discordFrequentlyUsedEmojiKeys: [String] = []
    var discordEmojiUsageScores: [String: Int] = [:]
    var discordGuildAndChannelUsageScores: [String: Int] = [:]
    var discordSyncedGuildAndChannelUsageScores: [String: Int] = [:]
    var discordGuildAndChannelUsage: [String: DiscordFrecencyUsage] = [:]
    var discordGuildAndChannelUsageOrder: [String] = []
    @ObservationIgnored var forwardDestinationHistoryDefaultsKey =
        "dev.sakuracord.forward-destination-history.signed-out"
    @ObservationIgnored var pendingDiscordFrecencyUses: [(key: String, timestamp: UInt64)] = []
    @ObservationIgnored var persistedDiscordFrecencyUsageDeltas: [String: DiscordFrecencyUsage] = [:]
    @ObservationIgnored var discordFrecencyUsageDeltasDefaultsKey =
        "dev.sakuracord.forward-frecency-deltas.signed-out"
    @ObservationIgnored var appliedDiscordFrecencyDeltasKey: String?
    @ObservationIgnored var lastDiscordFrecencyChannelID: ChannelID?
    @ObservationIgnored var lastDiscordFrecencyGuildID: GuildID?
    var hasLoadedDiscordEmojiSettings = false
    var orderedCustomEmojis: [DiscordEmoji] = []
    var customEmojiURLsByID: [String: URL] = [:]
    @ObservationIgnored var orderedCustomEmojiUpdateTask: Task<Void, Never>?
    @ObservationIgnored var orderedCustomEmojiUpdateGeneration: UInt64 = 0

    var isVoiceMuted = UserDefaults.standard.bool(forKey: "voiceMuted") {
        didSet {
            guard oldValue != isVoiceMuted else { return }
            refreshVoiceSidebarPresentation()
        }
    }
    var isVoiceDeafened = UserDefaults.standard.bool(forKey: "voiceDeafened") {
        didSet {
            guard oldValue != isVoiceDeafened else { return }
            refreshVoiceSidebarPresentation()
        }
    }
    var isCameraEnabled = false {
        didSet {
            guard oldValue != isCameraEnabled else { return }
            refreshVoiceSidebarPresentation()
        }
    }
    var inputVolume = Float(
        UserDefaults.standard.object(forKey: "voiceInputVolume") as? Double ?? 1)
    var outputVolume = Float(
        UserDefaults.standard.object(forKey: "voiceOutputVolume") as? Double ?? 1
    )
    var selectedGuildID: GuildID? {
        didSet {
            serverRailPresentation.updateSelection(selectedGuildID)
        }
    }
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
        selectedConversationAccess.canSend
            && supportedCapabilities.contains(.forums)
    }

    var canManageForumPosts: Bool {
        guard let permissions = selectedEffectivePermissions else { return false }
        return permissions & DiscordPermissionBits.manageThreads != 0
    }

    func canDeleteForumPost(_ post: ForumPost) -> Bool {
        return Self.canDeleteForumPost(
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
        return Self.resolveConversationAccess(
            for: channel,
            permissionBasis: conversationPermissionBasis(for: guildID)
        )
    }

    func conversationPermissionBasis(
        for guildID: GuildID
    ) -> ConversationPermissionBasis? {
        guard let guild = serverRailGuildsByID[guildID],
              let currentUserID = snapshot?.currentUser.id
        else {
            return nil
        }
        let member =
            membersByGuildID[guildID]?[currentUserID]
            ?? (guildID == selectedGuildID ? membersByID[currentUserID] : nil)
        let roles =
            guildRolesByGuildID[guildID]
            ?? (guildID == selectedGuildID ? guildRoles : [])
        let storedRoleIDs = currentUserRoleIDsByGuild[guildID]
        let roleIDs = storedRoleIDs ?? Set(member?.roles.map(\.id) ?? [])
        return ConversationPermissionBasis(
            guild: guild,
            resolvedBasePermissions: guild.currentUserPermissions
                ?? ConversationPermissionResolver.basePermissions(
                    guildID: guildID,
                    roleIDs: roleIDs,
                    roles: roles
                ),
            overwritePrincipals: PermissionOverwritePrincipals(
                guildID: guildID,
                currentUserID: currentUserID,
                roleIDs: roleIDs
            ),
            hasCurrentRoleIdentity: storedRoleIDs != nil || member != nil,
            currentUserIsPending: member?.isPending == true
        )
    }

    func conversationAccess(
        for channel: Channel,
        permissionBasis: ConversationPermissionBasis?
    ) -> ConversationAccess {
        Self.resolveConversationAccess(
            for: channel,
            permissionBasis: permissionBasis
        )
    }

    nonisolated static func resolveConversationAccess(
        for channel: Channel,
        permissionBasis: ConversationPermissionBasis?
    ) -> ConversationAccess {
        guard channel.guildID != nil else {
            return .readable(canSend: !channel.isOfficialSystemDirectMessage)
        }
        guard let permissionBasis else { return .checking }
        let permissions = ConversationPermissionResolver.effectivePermissions(
            guild: permissionBasis.guild,
            channel: channel,
            resolvedBasePermissions: permissionBasis.resolvedBasePermissions,
            overwritePrincipals: permissionBasis.overwritePrincipals,
            hasCurrentRoleIdentity: permissionBasis.hasCurrentRoleIdentity
        )
        if channel.kind == .voice {
            return ConversationPermissionResolver.voiceChannelAccess(
                effectivePermissions: permissions
            )
        }
        return ConversationPermissionResolver.channelAccess(effectivePermissions: permissions)
    }

    /// Mirrors Discord desktop's source-side forwarding guard for the state
    /// SakuraCord has resolved locally. Private channels do not require a
    /// guild permission check; guild messages require message-history access.
    func canForward(_ message: Message) -> Bool {
        guard supportedCapabilities.contains(.messageForwarding),
              message.isForwardable
        else { return false }
        guard let channel = snapshot?.channels.first(where: { $0.id == message.channelID })
                ?? visibleChannels.first(where: { $0.id == message.channelID })
        else { return true }
        guard channel.guildID != nil else { return true }

        let guildID = channel.guildID
        guard let guildID,
              let guild = serverRailGuildsByID[guildID],
              let currentUserID = snapshot?.currentUser.id
        else { return false }
        guard !guild.features.contains("FORWARDING_DISABLED") else { return false }
        let member =
            membersByGuildID[guildID]?[currentUserID]
            ?? (guildID == selectedGuildID ? membersByID[currentUserID] : nil)
        let roles =
            guildRolesByGuildID[guildID]
            ?? (guildID == selectedGuildID ? guildRoles : [])
        guard let permissions = ConversationPermissionResolver.effectivePermissions(
            guild: guild,
            channel: channel,
            currentUserID: currentUserID,
            currentMember: member,
            roles: roles,
            currentRoleIDs: currentUserRoleIDsByGuild[guildID]
        ) else { return false }
        return permissions & DiscordPermissionBits.readMessageHistory != 0
    }

    /// Discord's global search admits guild text candidates with VIEW_CHANNEL
    /// and vocal candidates with VIEW_CHANNEL plus CONNECT. The forwarding
    /// filter runs only after that category has been truncated.
    func canSearchForwardDestination(_ channel: Channel) -> Bool {
        canSearchForwardDestination(
            channel,
            permissions: forwardDestinationPermissions(channel)
        )
    }

    func canSearchForwardDestination(
        _ channel: Channel,
        permissions: UInt64?
    ) -> Bool {
        ForwardDestinationPermissionPolicy.canSearchChannel(
            channel,
            permissions: permissions
        )
    }

    /// Discord applies the actual forwarding filter after the raw per-category
    /// limit. Guild destinations require VIEW_CHANNEL and SEND_MESSAGES; vocal
    /// destinations have already passed the search-stage CONNECT check.
    func canUseForwardDestination(_ channel: Channel) -> Bool {
        canUseForwardDestination(
            channel,
            permissions: forwardDestinationPermissions(channel)
        )
    }

    func canUseForwardDestination(
        _ channel: Channel,
        permissions: UInt64?
    ) -> Bool {
        ForwardDestinationPermissionPolicy.canUseChannel(
            channel,
            permissions: permissions
        )
    }

    /// Active joined threads remain valid targets even when their parent is a
    /// forum, which is not itself a forward destination in Discord's picker.
    func canSearchForwardThreadDestination(parent: Channel) -> Bool {
        canSearchForwardThreadDestination(
            parent: parent,
            permissions: forwardDestinationPermissions(parent)
        )
    }

    func canSearchForwardThreadDestination(
        parent: Channel,
        permissions: UInt64?
    ) -> Bool {
        ForwardDestinationPermissionPolicy.canSearchThread(
            parent: parent,
            permissions: permissions
        )
    }

    func canUseForwardThreadDestination(parent: Channel) -> Bool {
        canUseForwardThreadDestination(
            parent: parent,
            permissions: forwardDestinationPermissions(parent)
        )
    }

    func canUseForwardThreadDestination(
        parent: Channel,
        permissions: UInt64?
    ) -> Bool {
        ForwardDestinationPermissionPolicy.canUseThread(
            parent: parent,
            permissions: permissions
        )
    }

    private func forwardDestinationPermissions(_ channel: Channel) -> UInt64? {
        guard let guildID = channel.guildID else {
            return nil
        }
        return forwardDestinationPermissions(
            channel,
            permissionBasis: conversationPermissionBasis(for: guildID)
        )
    }

    func forwardDestinationPermissions(
        _ channel: Channel,
        permissionBasis: ConversationPermissionBasis?
    ) -> UInt64? {
        guard let permissionBasis else { return nil }
        return ConversationPermissionResolver.effectivePermissions(
            guild: permissionBasis.guild,
            channel: channel,
            resolvedBasePermissions: permissionBasis.resolvedBasePermissions,
            overwritePrincipals: permissionBasis.overwritePrincipals,
            hasCurrentRoleIdentity: permissionBasis.hasCurrentRoleIdentity
        )
    }

    func forwardUnavailableReason(
        for message: Message,
        destination channel: Channel
    ) -> String? {
        guard let guildID = channel.guildID else { return nil }
        guard let guild = serverRailGuildsByID[guildID],
              let currentUserID = snapshot?.currentUser.id
        else { return "Destination permissions are unavailable." }
        let member =
            membersByGuildID[guildID]?[currentUserID]
            ?? (guildID == selectedGuildID ? membersByID[currentUserID] : nil)
        let roles =
            guildRolesByGuildID[guildID]
            ?? (guildID == selectedGuildID ? guildRoles : [])
        guard let permissions = ConversationPermissionResolver.effectivePermissions(
            guild: guild,
            channel: channel,
            currentUserID: currentUserID,
            currentMember: member,
            roles: roles,
            currentRoleIDs: currentUserRoleIDsByGuild[guildID]
        ) else {
            return channel.permissionOverwrites?.isEmpty != false
                ? nil
                : "Destination permissions are unavailable."
        }
        if !message.attachments.isEmpty,
           permissions & DiscordPermissionBits.attachFiles == 0
        {
            return "You cannot attach files in this conversation."
        }
        if !message.embeds.isEmpty,
           permissions & DiscordPermissionBits.embedLinks == 0
        {
            return "You cannot embed links in this conversation."
        }
        if message.stickers.contains(where: { $0.guildID != nil && $0.guildID != guildID }),
           permissions & DiscordPermissionBits.useExternalStickers == 0
        {
            return "You cannot use external stickers in this conversation."
        }
        if message.flags.contains(.voiceMessage),
           permissions & DiscordPermissionBits.sendVoiceMessages == 0
        {
            return "You cannot send voice messages in this conversation."
        }
        return nil
    }

    func shouldSendForwardContext(to channelID: ChannelID) -> Bool {
        guard let channel = snapshot?.channels.first(where: { $0.id == channelID })
                ?? visibleChannels.first(where: { $0.id == channelID }),
              channel.rateLimitPerUser > 0
        else { return true }
        guard let guildID = channel.guildID,
              let guild = serverRailGuildsByID[guildID],
              let currentUserID = snapshot?.currentUser.id
        else { return false }
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
        return permissions.map { $0 & DiscordPermissionBits.bypassSlowmode != 0 } ?? false
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
            if let previousChannel = selectedChannel,
               let guildID = previousChannel.guildID
            {
                lastOpenedChannelIDsByGuild[guildID] = previousChannel.id
            }
            if pendingAutomaticChannelAccessID != selectedChannelID {
                pendingAutomaticChannelAccessID = nil
            }
            memberListViewportRequest = nil
            if let retainedMemberViewport = lastMemberListVisibleRange {
                updateMemberListViewport(retainedMemberViewport)
            }
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
                if hasMoreLaterMessages {
                    messageCache[oldValue] = nil
                    messageCacheOrder.removeAll { $0 == oldValue }
                    messageRowCache[oldValue] = nil
                    messageRowCacheOrder.removeAll { $0 == oldValue }
                    hasMoreCache[oldValue] = nil
                } else {
                    storeCachedMessages(messages, for: oldValue)
                    storeCachedMessageRows(messageRows, for: oldValue)
                }
                lastTypingRequestAt[oldValue] = nil
                _ = readState.updatePresentation(channelID: oldValue, isPresented: false)
                readState.endForumVisit(channelID: oldValue)
            }
            selectedChannel =
                snapshot?.channels.first { $0.id == selectedChannelID }
                    ?? visibleChannels.first { $0.id == selectedChannelID }
            if let selectedChannel,
               let guildID = selectedChannel.guildID
            {
                lastOpenedChannelIDsByGuild[guildID] = selectedChannel.id
            }
            commandLoadTask?.cancel()
            commandAutocompleteTask?.cancel()
            cancelApplicationCommandMemberSearch()
            commandExecutionTask?.cancel()
            commandComposer.resetForChannelChange()
            clearComposerAttachments(for: .channel)
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
    var oversizedAttachmentPrompt: OversizedAttachmentPrompt?
    var externalAttachmentUploadPresentation: ExternalAttachmentUploadPresentation?
    var showInspector = true
    var errorMessage: String?

    @ObservationIgnored var provider: any ChatProvider
    @ObservationIgnored var database: SakuraCordDatabase?
    @ObservationIgnored var accountSessionGeneration: UInt64 = 0
    @ObservationIgnored var installedAccountSessionRevision: UInt64 = 0
    @ObservationIgnored let accountTransitionCoordinator = AccountTransitionCoordinator()
    @ObservationIgnored var accountTransitionIsActive = false
    @ObservationIgnored var accountChildTasks: [UUID: Task<Void, Never>] = [:]
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
    @ObservationIgnored var unreadPresentationRefreshTask: Task<Void, Never>?
    @ObservationIgnored var unreadPresentationPreparationTask: Task<Void, Never>?
    @ObservationIgnored var unreadPresentationPreparationGeneration: UInt64 = 0
    @ObservationIgnored var unreadPresentationPreparationSequence: UInt64 = 0
    @ObservationIgnored var activeUnreadPreparationGeneration: UInt64?
    @ObservationIgnored var unreadAccessProjectionGeneration: UInt64 = 0
    @ObservationIgnored var snapshotSourceRevision: UInt64 = 0
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
    @ObservationIgnored var bootstrapHistoryPrefetch: BootstrapHistoryPrefetch?
    @ObservationIgnored var conversationRefreshJournals:
        [ChannelID: ConversationRefreshJournal] = [:]
    @ObservationIgnored var conversationRefreshJournalRevision: UInt64 = 0
    @ObservationIgnored var forumLoadTask: Task<Void, Never>?
    @ObservationIgnored var forumNextOffset: Int?
    @ObservationIgnored var forumLoadGeneration: UInt64 = 0
    @ObservationIgnored var threadLoadTask: Task<Void, Never>?
    @ObservationIgnored var gifSearchTask: Task<Void, Never>?
    @ObservationIgnored var gifPickerLoadTask: Task<Void, Never>?
    @ObservationIgnored var gifPickerLoadGeneration: UInt64 = 0
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
    @ObservationIgnored var memberListViewportRequest: MemberListViewportRequest?
    @ObservationIgnored var lastMemberListVisibleRange: ClosedRange<Int>?
    @ObservationIgnored var pendingAutomaticChannelAccessID: ChannelID?
    @ObservationIgnored var voiceEventTask: Task<Void, Never>?
    @ObservationIgnored var voiceMigrationTask: Task<Void, Never>?
    @ObservationIgnored var voiceSession: DiscordVoiceSession?
    @ObservationIgnored var voiceMigrationGeneration = 0
    @ObservationIgnored var voiceActionGeneration: UInt64 = 0
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
    @ObservationIgnored var credentialHandlesByAccountID:
        [String: CredentialHandle] = [:]
    @ObservationIgnored var didAttemptDiscordEmojiSettings = false
    @ObservationIgnored var acknowledgementTasks: [ChannelID: Task<Void, Never>] = [:]
    @ObservationIgnored var queuedAcknowledgements: [ChannelID: ReadStateMutation] = [:]
    @ObservationIgnored var acknowledgementQueueOrder: [ChannelID] = []
    @ObservationIgnored var acknowledgementProcessorTask: Task<Void, Never>?
    @ObservationIgnored var acknowledgementGeneration = 0
    @ObservationIgnored var guildAcknowledgementTasks:
        [GuildID: Task<Void, Never>] = [:]
    @ObservationIgnored var categoryAcknowledgementTasks:
        [ChannelID: Task<Void, Never>] = [:]
    @ObservationIgnored var guildNotificationMutationTasks:
        [GuildID: Task<Void, Never>] = [:]
    @ObservationIgnored var channelNotificationMutationTasks:
        [ChannelID: Task<Void, Never>] = [:]
    @ObservationIgnored var categoryCollapseMutationTasks:
        [ChannelID: Task<Void, Never>] = [:]
    @ObservationIgnored var categoryCollapseMutationStates:
        [ChannelID: CategoryCollapseMutationState] = [:]
    var optimisticCategoryCollapsedByID: [ChannelID: Bool] = [:]
    @ObservationIgnored var channelNotificationMutationGeneration = 0
    @ObservationIgnored var forumNotificationMutationTasks:
        [ChannelID: Task<Void, Never>] = [:]
    @ObservationIgnored var forumNotificationMutationGeneration = 0
    @ObservationIgnored var mainWindowIsActive = false
    @ObservationIgnored var clientAppStateUpdateTask: Task<Void, Never>?
    @ObservationIgnored var currentUserRoleIDsByGuild: [GuildID: Set<RoleID>] = [:]
    @ObservationIgnored let readAcknowledgementTiming: ReadAcknowledgementTiming
    @ObservationIgnored let externalAttachmentUploader: any ExternalAttachmentUploading
    @ObservationIgnored var queuedOversizedAttachmentPrompts: [OversizedAttachmentPrompt] = []
    @ObservationIgnored var externalAttachmentUploadTask: Task<Void, Never>?
    @ObservationIgnored var externalAttachmentUploadGeneration: UInt64 = 0
    @ObservationIgnored var promisedAttachmentDirectoryByFileURL: [URL: URL] = [:]
    @ObservationIgnored var promisedAttachmentFilesInFlight: Set<URL> = []
    @ObservationIgnored var externalAttachmentUploadFileURL: URL?

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
        runsChatPerformanceBenchmarkOverride: Bool? = nil,
        externalAttachmentUploader: (any ExternalAttachmentUploading)? = nil
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
        self.externalAttachmentUploader = externalAttachmentUploader ?? CatboxAttachmentUploader()
        runsChatPerformanceBenchmark =
            runsChatPerformanceBenchmarkOverride
                ?? AppLaunchConfiguration(
                    arguments: ProcessInfo.processInfo.arguments
                ).runsAnyReadOnlyPerformanceBenchmark
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
