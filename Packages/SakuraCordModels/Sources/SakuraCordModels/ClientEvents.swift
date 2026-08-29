public enum ConnectionState: String, Codable, Equatable, Sendable {
    case disconnected, connecting, ready, resuming, backingOff, authenticationFailed
}

public enum ClientEvent: Equatable, Sendable {
    case connectionChanged(ConnectionState)
    case messageCreated(Message)
    case messageUpdated(Message)
    case messageReactionUpdated(MessageReactionUpdate)
    case messageDeleted(channelID: ChannelID, messageID: MessageID)
    case readStateSnapshot([ChannelReadState], version: Int? = nil)
    case readStateChanged(ChannelReadState)
    case notificationModeChanged(usesNewNotifications: Bool)
    case notificationSettingsChanged(GuildNotificationSettings)
    case emojiUserSettingsChanged(EmojiUserSettings)
    case typing(channelID: ChannelID, user: User)
    case channelsChanged(guildID: GuildID?, channels: [Channel])
    case forumPostsChanged(channelID: ChannelID, posts: [ForumPost])
    case forumPostPreviewsChanged(channelID: ChannelID, posts: [ForumPost])
    case activeJoinedThreadsChanged([MessageThreadSummary])
    case forumPageLoaded(channelID: ChannelID, query: ForumPostQuery, page: ForumPostPage)
    case membersChanged(
        guildID: GuildID,
        members: [Member],
        groups: [GuildMemberListGroup]
    )
    case privateMembersChanged([Member])
    case knownUsersChanged([User])
    case quickSwitcherUserIDsChanged([UserID])
    case messageSearchUsersChanged([User])
    case userSearchAliasesChanged([UserID: [String]])
    case quickSwitcherGuildMemberUserIDsChanged([GuildID: [UserID]])
    case quickSwitcherJoinedMemberIDsChanged([GuildID: [UserID]])
    case quickSwitcherGuildMemberAliasesChanged([GuildID: [UserID: String]])
    case currentUserRolesChanged(guildID: GuildID, roleIDs: [RoleID])
    case currentUserRolesSnapshot([GuildID: [RoleID]])
    case emojisChanged(guildID: GuildID, emojis: [DiscordEmoji])
    case emojisUpdated(
        guildID: GuildID,
        upserted: [DiscordEmoji],
        deletedIDs: [String]
    )
    case voiceStateChanged(VoiceParticipantState)
    case privateCallChanged(PrivateCall)
    case privateCallDeleted(channelID: ChannelID, unavailable: Bool)
    /// A nil value means Discord deallocated the current voice server and the
    /// client must wait for a replacement allocation before reconnecting.
    case voiceServerChanged(VoiceConnectionInfo?)
    case applicationStreamChanged(ApplicationStream)
    case applicationStreamDeleted(
        key: ApplicationStreamKey,
        unavailable: Bool,
        reason: String?
    )
    /// A nil value means the stream RTC allocation was removed. The stream
    /// itself may remain available while Discord allocates a replacement.
    case applicationStreamServerChanged(
        key: ApplicationStreamKey,
        connection: ApplicationStreamConnectionInfo?
    )
    case snapshotChanged(BootstrapSnapshot)
    case guildChanged(Guild)
    case guildLayoutChanged(guilds: [Guild], railItems: [GuildRailItem])
    case guildRolesChanged(guildID: GuildID, roles: [GuildRole])
    case currentUserChanged(User)
    case applicationCommandIndexInvalidated(ApplicationCommandIndexTarget)
    case applicationCommandAutocomplete(ApplicationCommandAutocompleteResult)
    case interaction(InteractionEvent)
}
