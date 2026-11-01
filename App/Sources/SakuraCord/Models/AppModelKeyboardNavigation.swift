import SakuraCordModels

extension AppModel {
    func navigateConversationHistory(direction: Int) {
        guard let destination = keyboardShortcutHistoryDestination(direction: direction) else { return }
        navigate(to: destination.channelID, historyDestination: destination)
    }

    func keyboardShortcutHistoryDestination(direction: Int) -> ConversationNavigationHistory.Destination? {
        // Resolve only actual history candidates; an empty Back/Forward stack
        // must not build an account-wide channel set on every menu update.
        conversationNavigationHistory.destination(direction: direction) { id in
            !hiddenChannelIDs.contains(id)
                && (messagePresentationChannelsByID[id] != nil || visibleChannels.contains { $0.id == id }
                    || openThread?.id == id || knownThreadIDs.contains(id))
        }
    }

    var orderedNavigationGuildIDs: [GuildID] {
        serverRailPresentation.orderedNavigationGuildIDs
    }

    func navigateShortcutServer(direction: Int) {
        switch keyboardShortcutServerDestination(direction: direction) {
        case .directMessages: selectGuild(nil)
        case .guild(let guildID): selectGuild(guildID)
        case nil: break
        }
    }

    func keyboardShortcutServerDestination(direction: Int) -> ServerRailNavigationDestination? {
        let destinations: [ServerRailNavigationDestination] = [.directMessages]
            + orderedNavigationGuildIDs.map { .guild($0) }
        let current = selectedGuildID.map { ServerRailNavigationDestination.guild($0) } ?? .directMessages
        let start = destinations.firstIndex(of: current) ?? 0
        let destination = destinations[(start + direction + destinations.count) % destinations.count]
        return destination == current ? nil : destination
    }

    func keyboardShortcutDirectMessageDestination(direction: Int) -> DirectMessageSidebarSelection? {
        let channels = DirectMessageInboxPolicy.conversations(in: visibleChannels, pinnedChannelIDs: pinnedDirectMessageIDs)
            .filter { !hiddenChannelIDs.contains($0.id) && !checkingChannelIDs.contains($0.id) }
        let destinations: [DirectMessageSidebarSelection] = [.friends]
            + (messageRequestChannels.isEmpty ? [] : [.messageRequests])
            + channels.map { .channel($0.id) }
        let current: DirectMessageSidebarSelection = isMessageRequestsPresented ? .messageRequests
            : isFriendsPresented ? .friends
            : selectedChannelID.map { .channel($0) } ?? .friends
        let start = destinations.firstIndex(of: current) ?? 0
        let destination = destinations[(start + direction + destinations.count) % destinations.count]
        return destination == current ? nil : destination
    }

    func navigateShortcutConversation(direction: Int, unreadOnly: Bool, mentionsOnly: Bool = false) {
        if selectedGuildID == nil, !unreadOnly {
            switch keyboardShortcutDirectMessageDestination(direction: direction) {
            case .friends: openFriends()
            case .messageRequests: openMessageRequests()
            case .channel(let channelID): navigate(to: channelID)
            case nil: break
            }
            return
        }
        if let channelID = keyboardShortcutConversationDestination(direction: direction, unreadOnly: unreadOnly, mentionsOnly: mentionsOnly) {
            navigate(to: channelID)
        }
    }

    func keyboardShortcutConversationDestination(direction: Int, unreadOnly: Bool, mentionsOnly: Bool = false) -> ChannelID? {
        let channels = shortcutConversationChannels(acrossServers: unreadOnly)
        guard !channels.isEmpty else { return nil }
        // Keep read channels in the ordered sequence so traversal starts at the
        // current conversation even after opening it clears its unread state.
        let currentID = isThreadFullWidth ? openThread?.id : selectedChannelID
        let currentIndex = channels.firstIndex { $0.id == currentID }
        let start = currentIndex ?? (direction > 0 ? -1 : 0)
        for offset in 1 ... channels.count {
            let index = (start + direction * offset + channels.count) % channels.count
            let channel = channels[index]
            guard channel.id != currentID,
                  !hiddenChannelIDs.contains(channel.id)
            else { continue }
            if unreadOnly {
                // Account read state already gates accessibility, including
                // authoritative unread evidence for servers not yet activated.
                guard readState.unread(channelID: channel.id),
                      !mentionsOnly || readState.mentions(channelID: channel.id) > 0 else { continue }
            } else if checkingChannelIDs.contains(channel.id) {
                continue
            }
            return channel.id
        }
        return nil
    }

    /// Menu validation needs existence, not navigation order. Sorting every
    /// server's channels here repeats on observed workspace updates, including
    /// history pagination, and can block the main thread between scroll frames.
    func hasKeyboardShortcutConversationDestination(unreadOnly: Bool, mentionsOnly: Bool = false) -> Bool {
        let selectedID = shortcutThreadIsFullWidth ? openThread?.id : selectedChannelID
        if !unreadOnly {
            if selectedGuildID == nil {
                return !isFriendsPresented || visibleChannels.contains { channel in
                    channel.isListedDirectMessage
                        && !hiddenChannelIDs.contains(channel.id)
                        && !checkingChannelIDs.contains(channel.id)
                }
            }
            let groups = selectedChannelGroups(visibleChannelGroups, guildID: selectedGuildID)
            if groups.contains(where: { group in
                group.channels.contains { channel in
                    channel.guildID == selectedGuildID && channel.id != selectedID
                        && !hiddenChannelIDs.contains(channel.id)
                        && !checkingChannelIDs.contains(channel.id)
                }
            }) { return true }
            return sidebarThreadLayout(guildID: selectedGuildID, channelGroups: groups, now: .now)
                .threadsByParentID.values.contains { rows in
                    rows.contains { $0.id != selectedID && !hiddenChannelIDs.contains($0.id) && !checkingChannelIDs.contains($0.id) }
                }
        }
        let guildIDs = serverRailPresentation.navigationGuildIDs
        let hiddenIDs = hiddenChannelIDs
        let channels = messagePresentationChannels
        let isCandidate: (ChannelID) -> Bool = { channelID in
            guard let entry = self.readState[unread: channelID] else { return false }
            return channelID != selectedID && entry.isAccessible && entry.isUnread
                && !hiddenIDs.contains(channelID)
                && (!mentionsOnly || entry.hasMentions)
                && (entry.guildID.map { guildIDs.contains($0) } ?? true)
        }
        let isDestination: (ChannelID) -> Bool = { channelID in
            isCandidate(channelID) && self.readState.unread(channelID: channelID)
        }
        for thread in activeJoinedThreads {
            guard isCandidate(thread.id),
                  readState.unread(channelID: thread.id),
                  let parentID = thread.parentID, messagePresentationChannelsByID[parentID] != nil,
                  let parent = readState.channelByID[parentID],
                  !hiddenIDs.contains(parentID) else { continue }
            if thread.guildID != nil, !thread.isArchived, SidebarThreadPolicy.listsThreads(under: parent.kind) {
                return true
            }
        }
        // A previously successful position is only a hint. Validate the
        // channel currently at that position against every live input, so
        // snapshot replacement, reordering, mute and access changes remain
        // correct without rebuilding an account-wide index on each update.
        let previousIndex = mentionsOnly
            ? shortcutMentionNavigationCandidateIndex
            : shortcutUnreadNavigationCandidateIndex
        if let previousIndex, channels.indices.contains(previousIndex),
           isDestination(channels[previousIndex].id)
        {
            return true
        }
        let candidateIndex = channels.firstIndex { isDestination($0.id) }
        if mentionsOnly {
            shortcutMentionNavigationCandidateIndex = candidateIndex
        } else {
            shortcutUnreadNavigationCandidateIndex = candidateIndex
        }
        return candidateIndex != nil
    }

    private func shortcutChannelsWithThreads(groups: [ChannelGroup], guildID: GuildID?, filterSelection: Bool = false) -> [Channel] {
        let selectedGroups = filterSelection ? channelSelectionGroups(groups, guildID: guildID) : groups
        let layout = sidebarThreadLayout(guildID: guildID, channelGroups: selectedGroups, now: .now)
        let groups = filterSelection
            ? selectedChannelGroups(selectedGroups, guildID: guildID, threadsByParentID: layout.threadsByParentID)
            : selectedGroups
        return groups.flatMap(\.channels).filter { $0.guildID == guildID }.flatMap { channel in
            [channel] + (layout.threadsByParentID[channel.id] ?? []).map { threadNavigationChannel($0.thread) }
        }
    }

    private func shortcutConversationChannels(acrossServers: Bool) -> [Channel] {
        guard acrossServers else {
            if selectedGuildID == nil {
                return DirectMessageInboxPolicy.conversations(in: visibleChannels, pinnedChannelIDs: pinnedDirectMessageIDs)
            }
            return shortcutChannelsWithThreads(groups: visibleChannelGroups, guildID: selectedGuildID, filterSelection: true)
        }
        let channelsByGuild = Dictionary(grouping: snapshot?.channels ?? [], by: \.guildID)
        let scopes: [GuildID?] = [nil] + orderedNavigationGuildIDs.map { $0 }
        return scopes.flatMap { guildID in
            if guildID == nil {
                return DirectMessageInboxPolicy.conversations(in: channelsByGuild[nil] ?? [], pinnedChannelIDs: pinnedDirectMessageIDs)
            }
            return shortcutChannelsWithThreads(
                groups: ChannelGroup.make(from: channelsByGuild[guildID] ?? []), guildID: guildID
            )
        }
    }
}
