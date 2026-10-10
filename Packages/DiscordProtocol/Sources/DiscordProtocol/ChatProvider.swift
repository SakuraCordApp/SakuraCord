import Foundation
import SakuraCordModels

public enum MessageHistoryAnchor: Equatable, Sendable {
    case newest
    case before(MessageID)
    case after(MessageID)
    case around(MessageID)
}

public struct PartialBulkReadAcknowledgementError: Error, Sendable {
    public let acceptedReadStates: [BulkReadStateAcknowledgement]
    public let failureDescription: String

    public init(
        acceptedReadStates: [BulkReadStateAcknowledgement],
        failureDescription: String
    ) {
        self.acceptedReadStates = acceptedReadStates
        self.failureDescription = failureDescription
    }
}

/// A pending emoji batch contributed to another type-2 settings save. The
/// owner acknowledges its captured uses only after the merged response arrives.
public struct EmojiFrecencySaveContribution: Sendable {
    public var messages: DiscordFrecencyHistory
    public var reactions: DiscordFrecencyHistory
    public var complete: @Sendable (EmojiUserSettings?) async -> Void

    public init(messages: DiscordFrecencyHistory, reactions: DiscordFrecencyHistory,
                complete: @escaping @Sendable (EmojiUserSettings?) async -> Void) {
        self.messages = messages
        self.reactions = reactions
        self.complete = complete
    }
}

public protocol ChatProvider: Sendable {
    func guildGuide(in guildID: GuildID) async throws -> GuildGuide
    func guildProfile(in guildID: GuildID) async throws -> GuildProfile
    func guildGuideProgress(in guildID: GuildID) async throws -> GuildGuideProgress
    func completeGuildGuideAction(in guildID: GuildID, channelID: ChannelID) async throws -> GuildGuideProgress
    func guildOnboarding(in guildID: GuildID) async throws -> GuildOnboarding
    func refreshCurrentMember(in guildID: GuildID) async throws -> Member
    func saveGuildOnboarding(in guildID: GuildID, responses: Set<String>, initial: Bool) async throws -> GuildOnboarding
    func updateGuildChannelSelection(in guildID: GuildID, enabled: Bool?, channels: [ChannelID: Bool]) async throws -> GuildNotificationSettings

    func serverInvite(_ reference: ServerInviteReference) async throws -> ServerInvite
    func acceptServerInvite(_ reference: ServerInviteReference, messageID: MessageID?, captchaHandler: DiscordCaptchaHandler?) async throws -> ServerInviteAcceptance
    func joinDiscoverableGuild(_ guildID: GuildID, captchaHandler: DiscordCaptchaHandler?) async throws -> Bool
    func createServerInvite(in channelID: ChannelID, guildID: GuildID, settings: ServerInviteSettings) async throws -> CreatedServerInvite
    func leaveGuild(_ guildID: GuildID) async throws
    func clearLocalSearchCache() async throws
    func prepareAuthentication() async throws
    func bootstrap() async throws -> BootstrapSnapshot
    func channels(in guildID: GuildID?) async throws -> [Channel]
    func threadMembers(in thread: MessageThreadSummary) async throws -> [Member]?
    func members(in guildID: GuildID?) async throws -> [Member]
    func updateMemberListViewport(
        in guildID: GuildID,
        channelID: ChannelID,
        visibleRange: ClosedRange<Int>
    ) async throws
    func resolveMembers(in guildID: GuildID, userIDs: [UserID]) async throws -> [Member]
    func searchMembers(in guildID: GuildID, query: String, limit: Int) async throws -> [Member]
    func requestQuickSwitcherMembers(
        in guildID: GuildID, query: String, limit: Int
    ) async throws
    func roles(in guildID: GuildID) async throws -> [GuildRole]
    func members(withRole roleID: RoleID, in guildID: GuildID) async throws -> RoleMemberResult
    func accountDetails() async throws -> AccountDetails
    func accountDevices() async throws -> [AccountDevice]
    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile
    func profileEditingSnapshot(in scope: ProfileEditingScope) async throws -> ProfileEditingSnapshot
    func cachedProfileEditingSnapshot(in scope: ProfileEditingScope) async throws -> ProfileEditingSnapshot?
    func profileCollectibleInventory() async throws -> ProfileCollectibleInventory
    func profileCollectibleProduct(id: String) async throws -> ProfileCollectibleProduct
    func profileAvatarHistory() async throws -> [ProfileAvatarHistoryEntry]
    func deleteProfileAvatarHistoryEntry(id: String) async throws
    func uploadProfileWidgetImage(fileURL: URL, filename: String, contentType: String) async throws -> ProfileWidgetImage
    func suggestedProfileWidgetGames() async throws -> ProfileWidgetGameSuggestions
    func defaultProfileWidgetGames() async throws -> [ProfileGame]
    func searchProfileWidgetGames(query: String) async throws -> [ProfileGame]
    func profileWidgetGames(ids: [String]) async throws -> [ProfileGame]
    func similarProfileGames(to gameID: String) async throws -> [ProfileGame]
    func profileGameAnnouncements(gameID: String) async throws -> ProfileGameAnnouncements
    func profileWidgetCatalogue(developer: Bool) async throws -> [ProfileApplicationWidget]
    func profileWidgetApplication(id: String) async throws -> [ProfileApplicationWidget]
    func profileWidgetApplicationIdentities(for userID: UserID) async throws -> [ProfileWidgetApplicationIdentity]
    func profileWidgetConnections(applicationIDs: [String]) async throws -> [String: ProfileWidgetConnection]
    /// Changes the current member's nickname; an empty string resets it.
    func setNickname(_ nickname: String, in guildID: GuildID) async throws -> String?
    /// Changes any member's server nickname; an empty string resets it.
    func setMemberNickname(_ nickname: String, for userID: UserID, in guildID: GuildID) async throws -> String?
    /// Sets the private nickname for a friend; nil or blank text removes it.
    func setFriendNickname(_ nickname: String?, for userID: UserID) async throws -> String?
    /// Renames a group DM or changes its icon, returning the saved channel.
    func editGroupDirectMessage(_ channelID: ChannelID, changes: GroupDirectMessageChanges) async throws -> Channel
    /// Leaves a group DM, optionally without notifying the other members.
    func leaveGroupDirectMessage(_ channelID: ChannelID, silently: Bool) async throws
    func saveProfileChanges(
        _ changes: ProfileEditChanges, in scope: ProfileEditingScope,
        didSave: @Sendable (ProfileSaveConfirmation) async -> Void
    ) async throws
    func emojis(in guildID: GuildID) async throws -> [DiscordEmoji]
    func emojiUserSettings() async throws -> EmojiUserSettings
    func configureEmojiFrecencyPersistence(_ prepare: @escaping @Sendable () async -> EmojiFrecencySaveContribution?) async
    func saveEmojiFrecency(_ messages: DiscordFrecencyHistory, reactions: DiscordFrecencyHistory, favoriteKey: String?, isFavorite: Bool) async throws -> EmojiUserSettings
    func setEmojiFavorite(_ key: String, isFavorite: Bool) async throws -> EmojiUserSettings
    func defaultSoundboardSounds() async throws -> [SoundboardSound]
    func soundboardSounds(in guildIDs: [GuildID]) async throws -> [GuildID: [SoundboardSound]]
    func soundboardUserSettings() async throws -> SoundboardUserSettings
    func setSoundboardFavorite(_ soundID: String, isFavorite: Bool) async throws
        -> SoundboardUserSettings
    func sendSoundboardSound(_ sound: SoundboardSound, in channelID: ChannelID) async throws
    func currentStatus() async -> PresenceStatus
    func updateStatus(_ status: PresenceStatus) async throws
    func updateProfileCustomStatus(_ status: ProfileCustomStatus?) async throws -> ProfileCustomStatus?
    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws -> MessagePage
    func messages(
        in channelID: ChannelID,
        anchoredAt anchor: MessageHistoryAnchor,
        limit: Int
    ) async throws -> MessagePage
    func messagesForImmediatePresentation(
        in channelID: ChannelID,
        anchoredAt anchor: MessageHistoryAnchor,
        limit: Int
    ) async throws -> MessagePage
    func searchMessages(_ query: MessageSearchQuery) async throws -> MessageSearchPage
    func inboxMentions(_ query: InboxMentionQuery, before: MessageID?) async throws -> InboxMentionPage
    func dismissInboxMention(_ messageID: MessageID) async throws
    func inboxSettings() async -> InboxSettings
    func inboxEventInterests(in guildID: GuildID) async throws -> Set<ScheduledEventID>
    func acknowledgeInboxEvents(in guildID: GuildID, through eventID: ScheduledEventID) async throws
    func setInboxEventInterested(_ interested: Bool, event: InboxScheduledEvent) async throws
    func updateInboxTab(_ tab: InboxTab) async throws
    func updateInboxCollapsed(_ collapsed: Bool, channelID: ChannelID, guildID: GuildID?) async throws
    func updateGuildRailLayout(_ items: [GuildRailItem]) async throws
    func pinnedMessages(
        in channelID: ChannelID,
        before: Date?,
        limit: Int
    ) async throws -> PinnedMessagePage
    func setMessagePinned(
        _ isPinned: Bool,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws
    func forumPosts(in channelID: ChannelID, query: ForumPostQuery) async throws -> ForumPostPage
    func forumPost(threadID: ChannelID) async throws -> ForumPost
    func createForumPost(
        _ draft: CreateForumPostDraft,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> ForumPost
    func createThread(_ draft: CreateThreadDraft) async throws -> MessageThreadSummary
    func updateForumPost(_ post: ForumPost, mutation: ForumPostMutation) async throws -> ForumPost
    func deleteForumPost(_ post: ForumPost) async throws
    func setThreadMembership(threadID: ChannelID, isJoined: Bool) async throws
    func updateForumPostNotificationLevel(
        _ post: ForumPost,
        level: MessageNotificationLevel
    ) async throws
    func updateForumPostMute(
        _ post: ForumPost,
        isMuted: Bool,
        until: Date?
    ) async throws
    func sendTyping(in channelID: ChannelID) async throws
    func ensurePrivateChannel(for userID: UserID) async throws -> Channel
    func send(_ draft: SendMessageDraft) async throws -> Message
    func send(_ draft: SendMessageDraft, progress: @escaping @Sendable (MessageSendProgress) -> Void)
        async throws -> Message
    func setPollAnswers(_ answerIDs: [Int], messageID: MessageID, channelID: ChannelID) async throws
    func pollVoters(messageID: MessageID, channelID: ChannelID, answerID: Int, after: UserID?, limit: Int) async throws -> PollVoterPage
    func endPoll(messageID: MessageID, channelID: ChannelID) async throws -> Message
    /// Returns a freshly signed copy of a Discord attachment URL, or nil when Discord returns none.
    func refreshAttachmentURL(_ url: URL) async throws -> URL?
    func forward(_ draft: ForwardMessageDraft) async throws -> Message
    func supports(_ capability: ChatCapability) async -> Bool
    func applicationCommandCatalog(for target: ApplicationCommandIndexTarget) async throws
        -> ApplicationCommandCatalog
    func requestApplicationCommandAutocomplete(_ request: ApplicationCommandAutocompleteRequest)
        async throws
    func executeApplicationCommand(
        _ invocation: ApplicationCommandInvocation,
        progress: @escaping @Sendable (ApplicationCommandProgress) -> Void
    ) async throws
    func submitComponentInteraction(_ submission: ComponentInteractionSubmission) async throws
    /// Submits a returned form. A definite rejection throws `ModalSubmissionRejection`.
    func submitModal(_ submission: ModalSubmission) async throws
    /// Grants an OAuth2 authorization code after the person explicitly asked to sign in.
    func authorizeOAuth2(_ request: OAuth2AuthorizationRequest) async throws -> OAuth2AuthorizationGrant
    func componentChoices(
        kind: ComponentSelectKind, query: String, guildID: GuildID?, channelID: ChannelID
    ) async throws -> [ComponentSelectOption]
    func searchGIFs(query: String) async throws -> [GIFSearchResult]
    func trendingGIFs() async throws -> [GIFSearchResult]
    func gifPickerLanding() async throws -> GIFPickerLanding
    func recordProfileGIFSelection(id: String, query: String?) async throws
    func favoriteGIFs() async throws -> [GIFSearchResult]
    func setGIFFavorite(_ gif: GIFSearchResult, isFavorite: Bool) async throws
        -> [GIFSearchResult]
    func stickers(in guildID: GuildID) async throws -> [MessageSticker]
    func standardStickerPacks() async throws -> [StickerPack]
    func stickerUserSettings() async throws -> StickerUserSettings
    func setStickerFavorite(_ stickerID: String, isFavorite: Bool) async throws
        -> StickerUserSettings
    func recordStickerUse(_ stickerID: String) async throws -> StickerUserSettings
    /// Synced slash-command usage from Discord's frecency settings.
    func applicationCommandFrecency() async throws -> DiscordFrecencyHistory
    /// Replaces the synced command usage, as Discord's client does when it
    /// flushes pending uses. Returns what the server stored.
    func saveApplicationCommandFrecency(_ history: DiscordFrecencyHistory) async throws
        -> DiscordFrecencyHistory
    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message
    func delete(messageID: MessageID, channelID: ChannelID) async throws
    func acknowledge(
        channelID: ChannelID,
        messageID: MessageID,
        token: String?
    ) async throws -> ReadAcknowledgementResponse
    func acknowledge(
        channelID: ChannelID,
        messageID: MessageID,
        token: String?,
        manual: Bool,
        mentionCount: Int?,
        flags: UInt64?,
        lastViewed: Int?
    ) async throws -> ReadAcknowledgementResponse
    func acknowledgeBulk(_ readStates: [BulkReadStateAcknowledgement]) async throws
    func updateGuildNotificationLevel(
        guildID: GuildID,
        level: MessageNotificationLevel
    ) async throws
    func updateGuildMute(
        guildID: GuildID,
        isMuted: Bool,
        until: Date?
    ) async throws
    func updateGuildNotificationToggle(
        guildID: GuildID,
        toggle: GuildNotificationToggle,
        isEnabled: Bool
    ) async throws
    func updateChannelNotificationLevel(
        guildID: GuildID?,
        channelID: ChannelID,
        level: MessageNotificationLevel
    ) async throws
    func updateChannelMute(
        guildID: GuildID?,
        channelID: ChannelID,
        isMuted: Bool,
        until: Date?
    ) async throws
    func updateDirectMessagePin(channelID: ChannelID, flags: UInt64) async throws
    func updateCategoryNotificationLevel(
        guildID: GuildID,
        categoryID: ChannelID,
        level: MessageNotificationLevel
    ) async throws
    func updateCategoryMute(
        guildID: GuildID,
        categoryID: ChannelID,
        isMuted: Bool,
        until: Date?
    ) async throws
    func updateCategoryCollapsed(
        guildID: GuildID,
        categoryID: ChannelID,
        isCollapsed: Bool
    ) async throws
    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws
    func setReaction(
        _ emoji: String,
        reacted: Bool,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws
    func reactionReactors(
        for emoji: String,
        messageID: MessageID,
        channelID: ChannelID,
        reactionCount: Int
    ) async throws -> [ReactionReactor]
    func joinVoice(
        channelID: ChannelID,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool
    ) async throws -> VoiceConnectionInfo
    func updateVoiceState(
        channelID: ChannelID?,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool,
        selfVideo: Bool
    ) async throws
    func startApplicationStream(
        channelID: ChannelID,
        guildID: GuildID?,
        preferredRegion: String?
    ) async throws -> ApplicationStreamConnectionInfo
    func watchApplicationStream(
        _ key: ApplicationStreamKey
    ) async throws -> ApplicationStreamConnectionInfo
    func stopApplicationStream(_ key: ApplicationStreamKey) async throws
    func pingApplicationStream(_ key: ApplicationStreamKey) async throws
    func setApplicationStreamPaused(
        _ key: ApplicationStreamKey,
        isPaused: Bool
    ) async throws
    func applicationStreamPreview(for key: ApplicationStreamKey) async throws -> URL?
    func subscribeToPrivateCall(channelID: ChannelID) async throws
    func privateCallIsRingable(channelID: ChannelID) async throws -> Bool
    func ringPrivateCall(channelID: ChannelID, recipients: [UserID]?) async throws
    func stopRingingPrivateCall(channelID: ChannelID, recipients: [UserID]) async throws
    func updateClientAppState(isFocused: Bool) async
    func eventStream() async -> AsyncStream<ClientEvent>
    func disconnect() async
}

public protocol PendingCredentialChatProvider: ChatProvider {
    func persistPendingCredential(
        to store: any CredentialStore,
        accountID: String
    ) async throws -> CredentialHandle
    func discardPendingCredential() async
}

public extension ChatProvider {
    func updateGuildRailLayout(_ items: [GuildRailItem]) async throws {
        throw ChatProviderError.invalidRequest("Rearranging servers is unavailable for this session.")
    }
    func guildGuide(in guildID: GuildID) async throws -> GuildGuide { throw ChatProviderError.invalidRequest("Server Guide is unavailable.") }
    func guildProfile(in guildID: GuildID) async throws -> GuildProfile { throw ChatProviderError.invalidRequest("Server profile is unavailable.") }
    func guildGuideProgress(in guildID: GuildID) async throws -> GuildGuideProgress { throw ChatProviderError.invalidRequest("Server Guide is unavailable.") }
    func completeGuildGuideAction(in guildID: GuildID, channelID: ChannelID) async throws -> GuildGuideProgress { throw ChatProviderError.invalidRequest("Server Guide is unavailable.") }
    func guildOnboarding(in guildID: GuildID) async throws -> GuildOnboarding {
        throw ChatProviderError.invalidRequest("Channels & Roles is unavailable for this session.")
    }
    func refreshCurrentMember(in guildID: GuildID) async throws -> Member {
        throw ChatProviderError.invalidRequest("Membership verification is unavailable for this session.")
    }
    func saveGuildOnboarding(in guildID: GuildID, responses: Set<String>, initial: Bool) async throws -> GuildOnboarding {
        throw ChatProviderError.invalidRequest("Onboarding is unavailable for this session.")
    }
    func updateGuildChannelSelection(in guildID: GuildID, enabled: Bool?, channels: [ChannelID: Bool]) async throws -> GuildNotificationSettings {
        throw ChatProviderError.invalidRequest("Channel selection is unavailable for this session.")
    }

    func serverInvite(_ reference: ServerInviteReference) async throws -> ServerInvite {
        throw ServerInviteError.unsupported("Server invites are unavailable for this session.")
    }

    func acceptServerInvite(_ reference: ServerInviteReference, messageID: MessageID?) async throws -> ServerInviteAcceptance {
        try await acceptServerInvite(reference, messageID: messageID, captchaHandler: nil)
    }

    func acceptServerInvite(_ reference: ServerInviteReference, messageID: MessageID?, captchaHandler: DiscordCaptchaHandler?) async throws -> ServerInviteAcceptance {
        throw ServerInviteError.unsupported("Joining servers is unavailable for this session.")
    }

    func joinDiscoverableGuild(_ guildID: GuildID, captchaHandler: DiscordCaptchaHandler?) async throws -> Bool {
        throw ServerInviteError.unsupported("Joining servers is unavailable for this session.")
    }

    func createServerInvite(in channelID: ChannelID, guildID: GuildID, settings: ServerInviteSettings) async throws -> CreatedServerInvite {
        throw ServerInviteError.unsupported("Creating invites is unavailable for this session.")
    }

    func leaveGuild(_ guildID: GuildID) async throws {
        throw ServerInviteError.unsupported("Leaving servers is unavailable for this session.")
    }

    func updateProfileCustomStatus(_ status: ProfileCustomStatus?) async throws -> ProfileCustomStatus? {
        throw ChatProviderError.invalidRequest("Custom status editing is unavailable for this session.")
    }

    func defaultProfileWidgetGames() async throws -> [ProfileGame] {
        throw ChatProviderError.invalidRequest("Profile widget games are unavailable for this session.")
    }

    func accountDetails() async throws -> AccountDetails {
        throw ChatProviderError.invalidRequest("Account details are unavailable for this session.")
    }

    func accountDevices() async throws -> [AccountDevice] {
        throw ChatProviderError.invalidRequest("Logged-in devices are unavailable for this session.")
    }

    func profileWidgetCatalogue(developer: Bool) async throws -> [ProfileApplicationWidget] {
        throw ChatProviderError.invalidRequest("Application widgets are unavailable for this session.")
    }

    func profileWidgetApplication(id: String) async throws -> [ProfileApplicationWidget] {
        throw ChatProviderError.invalidRequest("Application widgets are unavailable for this session.")
    }

    func profileWidgetApplicationIdentities(for userID: UserID) async throws -> [ProfileWidgetApplicationIdentity] {
        throw ChatProviderError.invalidRequest("Application widgets are unavailable for this session.")
    }

    func profileWidgetConnections(applicationIDs: [String]) async throws -> [String: ProfileWidgetConnection] {
        throw ChatProviderError.invalidRequest("Application connections are unavailable for this session.")
    }

    func uploadProfileWidgetImage(fileURL: URL, filename: String, contentType: String) async throws -> ProfileWidgetImage {
        throw ChatProviderError.invalidRequest("Widget image uploads are unavailable for this session.")
    }

    func suggestedProfileWidgetGames() async throws -> ProfileWidgetGameSuggestions {
        throw ChatProviderError.invalidRequest("Profile widget games are unavailable for this session.")
    }

    func searchProfileWidgetGames(query: String) async throws -> [ProfileGame] {
        throw ChatProviderError.invalidRequest("Profile widget games are unavailable for this session.")
    }

    func profileWidgetGames(ids: [String]) async throws -> [ProfileGame] {
        throw ChatProviderError.invalidRequest("Profile widget games are unavailable for this session.")
    }

    func similarProfileGames(to gameID: String) async throws -> [ProfileGame] {
        throw ChatProviderError.invalidRequest("Game profiles are unavailable for this session.")
    }

    func profileGameAnnouncements(gameID: String) async throws -> ProfileGameAnnouncements {
        throw ChatProviderError.invalidRequest("Game announcements are unavailable for this session.")
    }

    func profileEditingSnapshot(in scope: ProfileEditingScope) async throws -> ProfileEditingSnapshot {
        throw ChatProviderError.invalidRequest("Profile editing is unavailable for this session.")
    }

    func cachedProfileEditingSnapshot(in scope: ProfileEditingScope) async throws -> ProfileEditingSnapshot? { nil }

    func profileCollectibleInventory() async throws -> ProfileCollectibleInventory {
        throw ChatProviderError.invalidRequest("Profile collectibles are unavailable for this session.")
    }

    func profileCollectibleProduct(id: String) async throws -> ProfileCollectibleProduct {
        throw ChatProviderError.invalidRequest("Profile collectibles are unavailable for this session.")
    }

    func profileAvatarHistory() async throws -> [ProfileAvatarHistoryEntry] {
        throw ChatProviderError.invalidRequest("Avatar history is unavailable for this session.")
    }

    func deleteProfileAvatarHistoryEntry(id: String) async throws {
        throw ChatProviderError.invalidRequest("Avatar history is unavailable for this session.")
    }

    func setNickname(_ nickname: String, in guildID: GuildID) async throws -> String? {
        throw ChatProviderError.invalidRequest("Nickname editing is unavailable for this session.")
    }

    func setMemberNickname(_ nickname: String, for userID: UserID, in guildID: GuildID) async throws -> String? {
        throw ChatProviderError.invalidRequest("Nickname editing is unavailable for this session.")
    }

    func setFriendNickname(_ nickname: String?, for userID: UserID) async throws -> String? {
        throw ChatProviderError.invalidRequest("Friend nicknames are unavailable for this session.")
    }

    func editGroupDirectMessage(_ channelID: ChannelID, changes: GroupDirectMessageChanges) async throws -> Channel {
        throw ChatProviderError.invalidRequest("Group editing is unavailable for this session.")
    }

    func leaveGroupDirectMessage(_ channelID: ChannelID, silently: Bool) async throws {
        throw ChatProviderError.invalidRequest("Leaving groups is unavailable for this session.")
    }

    func saveProfileChanges(
        _ changes: ProfileEditChanges, in scope: ProfileEditingScope,
        didSave: @Sendable (ProfileSaveConfirmation) async -> Void
    ) async throws {
        throw ChatProviderError.invalidRequest("Profile editing is unavailable for this session.")
    }

    func clearLocalSearchCache() async throws {}

    func prepareAuthentication() async throws {}

    func pinnedMessages(
        in _: ChannelID,
        before _: Date?,
        limit _: Int
    ) async throws -> PinnedMessagePage {
        throw ChatProviderError.unauthenticated
    }

    func setMessagePinned(
        _: Bool,
        messageID _: MessageID,
        channelID _: ChannelID
    ) async throws {
        throw ChatProviderError.unauthenticated
    }

    func updateClientAppState(isFocused: Bool) async {}

    func startApplicationStream(
        channelID _: ChannelID,
        guildID _: GuildID?,
        preferredRegion _: String?
    ) async throws -> ApplicationStreamConnectionInfo {
        throw ChatProviderError.invalidRequest("This provider does not support screen sharing.")
    }

    func watchApplicationStream(
        _ key: ApplicationStreamKey
    ) async throws -> ApplicationStreamConnectionInfo {
        throw ChatProviderError.invalidRequest("This provider does not support watching screen shares.")
    }

    func stopApplicationStream(_: ApplicationStreamKey) async throws {}

    func pingApplicationStream(_: ApplicationStreamKey) async throws {}

    func setApplicationStreamPaused(
        _: ApplicationStreamKey,
        isPaused _: Bool
    ) async throws {}

    func applicationStreamPreview(for _: ApplicationStreamKey) async throws -> URL? { nil }

    func messages(
        in channelID: ChannelID,
        anchoredAt anchor: MessageHistoryAnchor,
        limit: Int
    ) async throws -> MessagePage {
        switch anchor {
        case .newest:
            return try await messages(in: channelID, before: nil, limit: limit)
        case .before(let messageID):
            return try await messages(in: channelID, before: messageID, limit: limit)
        case .after, .around:
            throw ChatProviderError.invalidRequest(
                "This provider does not support bidirectional message history."
            )
        }
    }

    /// Returns the history payload required to draw the conversation. Providers
    /// may defer supplemental member resolution because Discord message payloads
    /// already carry the nickname, roles, and guild avatar used by the timeline.
    /// The default retains the complete-history behavior for other providers.
    func messagesForImmediatePresentation(
        in channelID: ChannelID,
        anchoredAt anchor: MessageHistoryAnchor,
        limit: Int
    ) async throws -> MessagePage {
        try await messages(
            in: channelID,
            anchoredAt: anchor,
            limit: limit
        )
    }

    func searchMessages(_ query: MessageSearchQuery) async throws -> MessageSearchPage {
        guard !query.isEmpty else {
            throw ChatProviderError.invalidRequest("Enter text or choose a filter to search.")
        }
        let availableChannels = try await channels(in: query.scope.guildID)
        let selectedChannelIDs = Set(query.filters.channelIDs)
        let searchedChannels = availableChannels.filter {
            selectedChannelIDs.isEmpty || selectedChannelIDs.contains($0.id)
        }
        var candidates: [Message] = []
        for channel in searchedChannels {
            try Task.checkCancellation()
            candidates.append(
                contentsOf: try await messages(
                    in: channel.id,
                    before: nil,
                    limit: 100
                ).messages
            )
        }
        let normalized = query.normalizedContent
        let authorIDs = Set(query.filters.authorIDs)
        let mentionedUserIDs = Set(query.filters.mentionedUserIDs)
        let matches = candidates.filter { message in
            (normalized.isEmpty
                || message.content.localizedCaseInsensitiveContains(normalized))
                && (authorIDs.isEmpty || authorIDs.contains(message.author.id))
                && (mentionedUserIDs.isEmpty
                    || !mentionedUserIDs.isDisjoint(
                        with: message.mentionedUsers.map(\.id)
                    ))
                && Self.matchesSearchContentTypes(
                    query.filters.contentTypes,
                    message: message
                )
        }.sorted {
            query.sort == .oldest
                ? $0.timestamp < $1.timestamp
                : $0.timestamp > $1.timestamp
        }
        let lowerBound = min(max(0, query.offset), matches.count)
        let upperBound = min(
            matches.count,
            lowerBound + MessageSearchQuery.pageSize
        )
        return MessageSearchPage(
            messages: Array(matches[lowerBound ..< upperBound]),
            channels: searchedChannels,
            totalResults: matches.count
        )
    }

    private static func matchesSearchContentTypes(
        _ types: [MessageSearchContentType],
        message: Message
    ) -> Bool {
        guard !types.isEmpty else { return true }
        return types.contains { type in
            switch type {
            case .image:
                message.attachments.contains { attachment in
                    attachment.mediaType?.hasPrefix("image/") == true
                }
            case .video:
                message.attachments.contains { attachment in
                    attachment.mediaType?.hasPrefix("video/") == true
                }
            case .link:
                message.content.contains("://")
            case .file:
                !message.attachments.isEmpty
            case .embed:
                !message.embeds.isEmpty
            case .sound:
                message.attachments.contains { attachment in
                    attachment.mediaType?.hasPrefix("audio/") == true
                }
            case .poll:
                message.hasPoll
            case .sticker:
                !message.stickers.isEmpty
            case .forward:
                message.forwardedSnapshot != nil
            }
        }
    }

    func threadMembers(in thread: MessageThreadSummary) async throws -> [Member]? { [] }

    func updateMemberListViewport(
        in guildID: GuildID,
        channelID: ChannelID,
        visibleRange: ClosedRange<Int>
    ) async throws {}

    func resolveMembers(in guildID: GuildID, userIDs: [UserID]) async throws -> [Member] {
        let requested = Set(userIDs.prefix(100))
        return try await members(in: guildID).filter { requested.contains($0.id) }
    }

    func searchMembers(in guildID: GuildID, query: String, limit: Int) async throws -> [Member] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        return try await members(in: guildID).filter { member in
            member.user.displayName.localizedCaseInsensitiveContains(normalized)
                || member.user.username.localizedCaseInsensitiveContains(normalized)
        }.prefix(max(1, limit)).map(\.self)
    }

    func requestQuickSwitcherMembers(
        in guildID: GuildID, query: String, limit: Int
    ) async throws {}

    func roles(in guildID: GuildID) async throws -> [GuildRole] {
        var rolesByID: [RoleID: GuildRole] = [:]
        for role in try await members(in: guildID).flatMap(\.roles) {
            rolesByID[role.id] = role
        }
        return rolesByID.values.sorted { $0.position > $1.position }
    }

    func members(withRole roleID: RoleID, in guildID: GuildID) async throws -> RoleMemberResult {
        let values = try await members(in: guildID).filter { member in
            member.roles.contains { $0.id == roleID }
        }
        return RoleMemberResult(members: values, totalCount: values.count)
    }

    func send(
        _ draft: SendMessageDraft, progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> Message {
        progress(.preparing)
        let message = try await send(draft)
        progress(.completed(messageID: message.id))
        return message
    }

    func forward(_ draft: ForwardMessageDraft) async throws -> Message {
        throw ChatProviderError.capabilityDisabled(.messageForwarding)
    }

    func ensurePrivateChannel(for userID: UserID) async throws -> Channel {
        throw ChatProviderError.channelNotFound
    }

    func supports(_ capability: ChatCapability) async -> Bool {
        false
    }

    func applicationCommandCatalog(for target: ApplicationCommandIndexTarget) async throws
        -> ApplicationCommandCatalog
    {
        throw ChatProviderError.capabilityDisabled(.slashCommands)
    }

    func requestApplicationCommandAutocomplete(_ request: ApplicationCommandAutocompleteRequest)
        async throws
    {
        throw ChatProviderError.capabilityDisabled(.slashCommands)
    }

    func executeApplicationCommand(
        _ invocation: ApplicationCommandInvocation,
        progress: @escaping @Sendable (ApplicationCommandProgress) -> Void
    ) async throws {
        throw ChatProviderError.capabilityDisabled(.slashCommands)
    }

    func submitComponentInteraction(_ submission: ComponentInteractionSubmission) async throws {
        throw ChatProviderError.capabilityDisabled(.components)
    }

    func submitModal(_ submission: ModalSubmission) async throws {
        throw ChatProviderError.capabilityDisabled(.modals)
    }

    func authorizeOAuth2(_ request: OAuth2AuthorizationRequest) async throws -> OAuth2AuthorizationGrant {
        throw OAuth2AuthorizationError.unavailable
    }

    func componentChoices(
        kind: ComponentSelectKind, query: String, guildID: GuildID?, channelID: ChannelID
    ) async throws -> [ComponentSelectOption] {
        throw ChatProviderError.capabilityDisabled(.remoteComponentChoices)
    }

    func searchGIFs(query: String) async throws -> [GIFSearchResult] {
        throw ChatProviderError.capabilityDisabled(.gifs)
    }

    func trendingGIFs() async throws -> [GIFSearchResult] {
        throw ChatProviderError.capabilityDisabled(.gifs)
    }

    func gifPickerLanding() async throws -> GIFPickerLanding {
        throw ChatProviderError.capabilityDisabled(.gifs)
    }

    func recordProfileGIFSelection(id: String, query: String?) async throws {
        throw ChatProviderError.capabilityDisabled(.gifs)
    }

    func favoriteGIFs() async throws -> [GIFSearchResult] {
        throw ChatProviderError.capabilityDisabled(.gifs)
    }

    func setGIFFavorite(_ gif: GIFSearchResult, isFavorite: Bool) async throws
        -> [GIFSearchResult]
    {
        throw ChatProviderError.capabilityDisabled(.gifs)
    }

    func stickers(in guildID: GuildID) async throws -> [MessageSticker] {
        throw ChatProviderError.capabilityDisabled(.stickers)
    }

    func standardStickerPacks() async throws -> [StickerPack] { [] }

    func stickerUserSettings() async throws -> StickerUserSettings {
        StickerUserSettings()
    }

    func setStickerFavorite(_ stickerID: String, isFavorite: Bool) async throws
        -> StickerUserSettings
    {
        throw ChatProviderError.capabilityDisabled(.stickers)
    }

    func recordStickerUse(_ stickerID: String) async throws -> StickerUserSettings {
        StickerUserSettings()
    }

    func applicationCommandFrecency() async throws -> DiscordFrecencyHistory {
        DiscordFrecencyHistory()
    }

    func saveApplicationCommandFrecency(_ history: DiscordFrecencyHistory) async throws
        -> DiscordFrecencyHistory
    {
        history
    }

    func emojis(in guildID: GuildID) async throws -> [DiscordEmoji] {
        []
    }

    func emojiUserSettings() async throws -> EmojiUserSettings {
        EmojiUserSettings()
    }

    func configureEmojiFrecencyPersistence(_ prepare: @escaping @Sendable () async -> EmojiFrecencySaveContribution?) async {}

    func saveEmojiFrecency(_ messages: DiscordFrecencyHistory, reactions: DiscordFrecencyHistory, favoriteKey: String?, isFavorite: Bool) async throws -> EmojiUserSettings {
        throw ChatProviderError.invalidRequest("Emoji usage updates are unavailable for this provider.")
    }

    func setEmojiFavorite(_ key: String, isFavorite: Bool) async throws -> EmojiUserSettings {
        throw ChatProviderError.invalidRequest(
            "Emoji favorite updates are unavailable for this provider."
        )
    }

    func defaultSoundboardSounds() async throws -> [SoundboardSound] {
        throw ChatProviderError.capabilityDisabled(.soundboard)
    }

    func soundboardSounds(in guildIDs: [GuildID]) async throws -> [GuildID: [SoundboardSound]] {
        throw ChatProviderError.capabilityDisabled(.soundboard)
    }

    func soundboardUserSettings() async throws -> SoundboardUserSettings {
        SoundboardUserSettings()
    }

    func setSoundboardFavorite(_ soundID: String, isFavorite: Bool) async throws
        -> SoundboardUserSettings
    {
        throw ChatProviderError.capabilityDisabled(.soundboard)
    }

    func sendSoundboardSound(_ sound: SoundboardSound, in channelID: ChannelID) async throws {
        throw ChatProviderError.capabilityDisabled(.soundboard)
    }

    func sendTyping(in channelID: ChannelID) async throws {}

    func acknowledge(
        channelID: ChannelID,
        messageID: MessageID,
        token: String?
    ) async throws -> ReadAcknowledgementResponse {
        ReadAcknowledgementResponse(token: token)
    }

    func acknowledge(
        channelID: ChannelID,
        messageID: MessageID,
        token: String?,
        manual: Bool,
        mentionCount: Int?,
        flags: UInt64?,
        lastViewed: Int?
    ) async throws -> ReadAcknowledgementResponse {
        try await acknowledge(channelID: channelID, messageID: messageID, token: token)
    }

    func updateChannelNotificationLevel(
        guildID: GuildID?,
        channelID: ChannelID,
        level: MessageNotificationLevel
    ) async throws {}

    func acknowledgeBulk(_ readStates: [BulkReadStateAcknowledgement]) async throws {}

    func updateGuildNotificationLevel(
        guildID: GuildID,
        level: MessageNotificationLevel
    ) async throws {}

    func updateGuildMute(
        guildID: GuildID,
        isMuted: Bool,
        until: Date?
    ) async throws {}

    func updateGuildNotificationToggle(
        guildID: GuildID,
        toggle: GuildNotificationToggle,
        isEnabled: Bool
    ) async throws {}

    func updateChannelMute(
        guildID: GuildID?,
        channelID: ChannelID,
        isMuted: Bool,
        until: Date?
    ) async throws {}

    func updateDirectMessagePin(channelID: ChannelID, flags: UInt64) async throws {}

    func updateCategoryNotificationLevel(
        guildID: GuildID,
        categoryID: ChannelID,
        level: MessageNotificationLevel
    ) async throws {}

    func updateCategoryMute(
        guildID: GuildID,
        categoryID: ChannelID,
        isMuted: Bool,
        until: Date?
    ) async throws {}

    func updateCategoryCollapsed(
        guildID: GuildID,
        categoryID: ChannelID,
        isCollapsed: Bool
    ) async throws {}

    func forumPosts(in channelID: ChannelID, query: ForumPostQuery) async throws -> ForumPostPage {
        throw ChatProviderError.capabilityDisabled(.forums)
    }

    func forumPost(threadID: ChannelID) async throws -> ForumPost {
        throw ChatProviderError.capabilityDisabled(.forums)
    }

    func createForumPost(
        _ draft: CreateForumPostDraft,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> ForumPost {
        throw ChatProviderError.capabilityDisabled(.forums)
    }

    func createThread(_ draft: CreateThreadDraft) async throws -> MessageThreadSummary {
        throw ChatProviderError.invalidRequest("This account cannot create threads.")
    }

    func updateForumPost(_ post: ForumPost, mutation: ForumPostMutation) async throws -> ForumPost {
        throw ChatProviderError.capabilityDisabled(.forums)
    }

    func deleteForumPost(_ post: ForumPost) async throws {
        throw ChatProviderError.capabilityDisabled(.forums)
    }

    func setThreadMembership(threadID: ChannelID, isJoined: Bool) async throws {
        throw ChatProviderError.capabilityDisabled(.forums)
    }

    func updateForumPostNotificationLevel(
        _ post: ForumPost,
        level: MessageNotificationLevel
    ) async throws {
        throw ChatProviderError.capabilityDisabled(.forums)
    }

    func updateForumPostMute(
        _ post: ForumPost,
        isMuted: Bool,
        until: Date?
    ) async throws {
        throw ChatProviderError.capabilityDisabled(.forums)
    }

    func setReaction(
        _ emoji: String,
        reacted: Bool,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {
        try await toggleReaction(emoji, messageID: messageID, channelID: channelID)
    }

    func reactionReactors(
        for emoji: String,
        messageID: MessageID,
        channelID: ChannelID,
        reactionCount: Int
    ) async throws -> [ReactionReactor] {
        []
    }

    func joinVoice(
        channelID: ChannelID,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool
    ) async throws -> VoiceConnectionInfo {
        throw ChatProviderError.invalidRequest("Voice calling is unavailable for this provider.")
    }

    func updateVoiceState(
        channelID: ChannelID?,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool,
        selfVideo: Bool
    ) async throws {
        throw ChatProviderError.invalidRequest("Voice calling is unavailable for this provider.")
    }

    func updateVoiceState(
        channelID: ChannelID?,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool
    ) async throws {
        try await updateVoiceState(
            channelID: channelID,
            guildID: guildID,
            selfMute: selfMute,
            selfDeaf: selfDeaf,
            selfVideo: false
        )
    }

    func subscribeToPrivateCall(channelID: ChannelID) async throws {
        throw ChatProviderError.invalidRequest(
            "Direct-message calling is unavailable for this provider.")
    }

    func privateCallIsRingable(channelID: ChannelID) async throws -> Bool {
        throw ChatProviderError.invalidRequest(
            "Direct-message calling is unavailable for this provider.")
    }

    func ringPrivateCall(channelID: ChannelID, recipients: [UserID]?) async throws {
        throw ChatProviderError.invalidRequest(
            "Direct-message calling is unavailable for this provider.")
    }

    func stopRingingPrivateCall(channelID: ChannelID, recipients: [UserID]) async throws {
        throw ChatProviderError.invalidRequest(
            "Direct-message calling is unavailable for this provider.")
    }
}

public enum ChatProviderError: LocalizedError, Equatable, Sendable {
    case unauthenticated
    case channelNotFound
    case slowmode(retryAfter: TimeInterval)
    case messageNotFound
    case invalidRequest(String)
    case transport(status: Int, requestID: String?)
    case capabilityDisabled(ChatCapability)

    public var errorDescription: String? {
        switch self {
        case .unauthenticated: "The account session is no longer valid."
        case .slowmode: "This conversation is on a slowmode cooldown. Please wait before sending again."
        case .channelNotFound: "The selected channel is unavailable."
        case .messageNotFound: "The message no longer exists."
        case let .invalidRequest(message): message
        case let .transport(status, requestID):
            requestID.map { "Discord returned HTTP \(status) (request \($0))." }
                ?? "Discord returned HTTP \(status)."
        case let .capabilityDisabled(capability):
            "\(capability.displayName) is not enabled for this account session."
        }
    }
}

public enum ChatCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case forums
    case slashCommands
    case components
    case modals
    case remoteComponentChoices
    case gifs
    case stickers
    case stickerSending
    case messageForwarding
    case soundboard

    public var displayName: String {
        switch self {
        case .forums: "Forum channels"
        case .slashCommands: "Application commands"
        case .components: "Message interactions"
        case .modals: "Interaction forms"
        case .remoteComponentChoices: "Remote interaction choices"
        case .gifs: "GIF search"
        case .stickers: "Guild stickers"
        case .stickerSending: "Sticker sending"
        case .messageForwarding: "Message forwarding"
        case .soundboard: "Soundboard"
        }
    }
}

public extension ChatProvider {
    func setPollAnswers(_ answerIDs: [Int], messageID: MessageID, channelID: ChannelID) async throws {
        throw ChatProviderError.invalidRequest("Poll voting is unavailable.")
    }
    func pollVoters(messageID: MessageID, channelID: ChannelID, answerID: Int, after: UserID?, limit: Int) async throws -> PollVoterPage {
        throw ChatProviderError.invalidRequest("Poll voters are unavailable.")
    }
    func endPoll(messageID: MessageID, channelID: ChannelID) async throws -> Message {
        throw ChatProviderError.invalidRequest("Ending polls is unavailable.")
    }
    func refreshAttachmentURL(_ url: URL) async throws -> URL? {
        throw ChatProviderError.invalidRequest("Opening attachment links is unavailable.")
    }
}
