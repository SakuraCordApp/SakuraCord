import Foundation
import SakuraCordModels

public protocol ChatProvider: Sendable {
    func bootstrap() async throws -> BootstrapSnapshot
    func channels(in guildID: GuildID?) async throws -> [Channel]
    func members(in guildID: GuildID?) async throws -> [Member]
    func searchMembers(in guildID: GuildID, query: String, limit: Int) async throws -> [Member]
    func roles(in guildID: GuildID) async throws -> [GuildRole]
    func members(withRole roleID: RoleID, in guildID: GuildID) async throws -> RoleMemberResult
    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile
    func emojis(in guildID: GuildID) async throws -> [DiscordEmoji]
    func emojiUserSettings() async throws -> EmojiUserSettings
    func currentStatus() async -> PresenceStatus
    func updateStatus(_ status: PresenceStatus) async throws
    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws -> MessagePage
    func forumPosts(in channelID: ChannelID, query: ForumPostQuery) async throws -> ForumPostPage
    func forumPost(threadID: ChannelID) async throws -> ForumPost
    func createForumPost(
        _ draft: CreateForumPostDraft,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> ForumPost
    func updateForumPost(_ post: ForumPost, mutation: ForumPostMutation) async throws -> ForumPost
    func deleteForumPost(_ post: ForumPost) async throws
    func sendTyping(in channelID: ChannelID) async throws
    func send(_ draft: SendMessageDraft) async throws -> Message
    func send(_ draft: SendMessageDraft, progress: @escaping @Sendable (MessageSendProgress) -> Void)
        async throws -> Message
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
    func submitModal(_ submission: ModalSubmission, nonce: String) async throws
    func componentChoices(
        kind: ComponentSelectKind, query: String, guildID: GuildID?, channelID: ChannelID
    ) async throws -> [ComponentSelectOption]
    func searchGIFs(query: String) async throws -> [GIFSearchResult]
    func trendingGIFs() async throws -> [GIFSearchResult]
    func stickers(in guildID: GuildID) async throws -> [MessageSticker]
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
    func subscribeToPrivateCall(channelID: ChannelID) async throws
    func privateCallIsRingable(channelID: ChannelID) async throws -> Bool
    func ringPrivateCall(channelID: ChannelID, recipients: [UserID]?) async throws
    func stopRingingPrivateCall(channelID: ChannelID, recipients: [UserID]) async throws
    func eventStream() async -> AsyncStream<ClientEvent>
    func disconnect() async
}

public extension ChatProvider {
    func searchMembers(in guildID: GuildID, query: String, limit: Int) async throws -> [Member] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        return try await members(in: guildID).filter { member in
            member.user.displayName.localizedCaseInsensitiveContains(normalized)
                || member.user.username.localizedCaseInsensitiveContains(normalized)
        }.prefix(max(1, limit)).map(\.self)
    }

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

    func submitModal(_ submission: ModalSubmission, nonce: String) async throws {
        throw ChatProviderError.capabilityDisabled(.modals)
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

    func stickers(in guildID: GuildID) async throws -> [MessageSticker] {
        throw ChatProviderError.capabilityDisabled(.stickers)
    }

    func emojis(in guildID: GuildID) async throws -> [DiscordEmoji] {
        []
    }

    func emojiUserSettings() async throws -> EmojiUserSettings {
        EmojiUserSettings()
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

    func updateForumPost(_ post: ForumPost, mutation: ForumPostMutation) async throws -> ForumPost {
        throw ChatProviderError.capabilityDisabled(.forums)
    }

    func deleteForumPost(_ post: ForumPost) async throws {
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
    case messageNotFound
    case invalidRequest(String)
    case transport(status: Int, requestID: String?)
    case capabilityDisabled(ChatCapability)

    public var errorDescription: String? {
        switch self {
        case .unauthenticated: "The account session is no longer valid."
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
        }
    }
}
