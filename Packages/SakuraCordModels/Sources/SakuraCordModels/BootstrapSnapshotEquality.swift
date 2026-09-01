// swiftformat:disable redundantEquatable

public extension BootstrapSnapshot {
    /// Keep exact value semantics while checking the high-frequency workspace
    /// mutation domains first. Observation compares the previous and next
    /// snapshot on every assignment; synthesized declaration-order equality
    /// walked the account-wide user/search stores before reaching channel or
    /// guild unread changes, adding several milliseconds to each publication.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.guilds == rhs.guilds
            && lhs.channels == rhs.channels
            && lhs.threads == rhs.threads
            && lhs.activeJoinedThreads == rhs.activeJoinedThreads
            && lhs.members == rhs.members
            && lhs.readStates == rhs.readStates
            && lhs.notificationSettings == rhs.notificationSettings
            && lhs.usesNewNotifications == rhs.usesNewNotifications
            && lhs.currentUser == rhs.currentUser
            && lhs.guildRailItems == rhs.guildRailItems
            && lhs.forwardGuildStoreOrder == rhs.forwardGuildStoreOrder
            && lhs.forwardChannelStoreOrder == rhs.forwardChannelStoreOrder
            && lhs.knownUsers == rhs.knownUsers
            && lhs.quickSwitcherUserIDs == rhs.quickSwitcherUserIDs
            && lhs.messageSearchUsers == rhs.messageSearchUsers
            && lhs.messageSearchUserBoosterChannelIDs
                == rhs.messageSearchUserBoosterChannelIDs
            && lhs.friendUserIDs == rhs.friendUserIDs
            && lhs.blockedOrIgnoredUserIDs == rhs.blockedOrIgnoredUserIDs
            && lhs.relationshipNicknamesByUserID
                == rhs.relationshipNicknamesByUserID
            && lhs.userSearchAliasesByUserID == rhs.userSearchAliasesByUserID
            && lhs.quickSwitcherGuildMemberUserIDs
                == rhs.quickSwitcherGuildMemberUserIDs
            && lhs.quickSwitcherJoinedGuildMemberUserIDs
                == rhs.quickSwitcherJoinedGuildMemberUserIDs
            && lhs.quickSwitcherGuildMemberAliases
                == rhs.quickSwitcherGuildMemberAliases
    }
}
