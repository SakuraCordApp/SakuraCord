import Foundation
import SakuraCordModels

nonisolated struct SidebarThreadRow: Identifiable, Equatable, Sendable {
    let thread: MessageThreadSummary
    let isUnread: Bool
    let mentionCount: Int
    let isMuted: Bool

    var id: ChannelID { thread.id }
}

/// Discord's channel list shows a parent's active joined threads only while
/// they are relevant. The contract lives in docs/protocol/MESSAGING.md.
nonisolated enum SidebarThreadPolicy {
    static func listsThreads(under kind: ChannelKindValue) -> Bool {
        [.text, .announcement, .forum].contains(kind)
    }

    struct Candidate: Sendable {
        let thread: MessageThreadSummary
        let latestMessageID: MessageID?
        /// Discord's raw `hasUnread`, independent of notification settings.
        let hasUnread: Bool
        /// The read-state unread presentation used for the row's emphasis.
        let showsUnread: Bool
        let mentionCount: Int
    }

    struct Layout: Equatable, Sendable {
        var threadsByParentID: [ChannelID: [SidebarThreadRow]] = [:]
        /// Future instants at which a timed-relevant thread expires.
        var relevanceDeadlines: [Date] = []
    }

    static func isMuted(_ thread: MessageThreadSummary, now: Date) -> Bool {
        guard let settings = thread.notificationSettings, settings.isMuted else {
            return false
        }
        return settings.muteConfiguration?.isActive(at: now) ?? true
    }

    /// A thread stays relevant until its auto-archive window has elapsed since
    /// its latest activity, even when Discord has not archived it yet.
    static func relevanceDeadline(for candidate: Candidate) -> Date? {
        let thread = candidate.thread
        guard !thread.isArchived, let minutes = thread.autoArchiveDuration else {
            return nil
        }
        let latestActivity = max(
            candidate.latestMessageID?.createdAt ?? thread.id.createdAt,
            max(thread.archiveTimestamp ?? .distantPast, thread.lastNonMessageActivityAt ?? .distantPast)
        )
        return latestActivity.addingTimeInterval(TimeInterval(minutes * 60))
    }

    static func isRelevant(_ candidate: Candidate, now: Date) -> Bool {
        if relevanceDeadline(for: candidate).map({ $0 > now }) == true { return true }
        return candidate.thread.isPinned
            || isUnreadRelevant(candidate, now: now)
    }

    /// The narrower set Discord keeps under a collapsed category or muted parent.
    static func isUnreadRelevant(_ candidate: Candidate, now: Date) -> Bool {
        candidate.mentionCount > 0
            || (candidate.hasUnread && !isMuted(candidate.thread, now: now))
    }

    /// Orders by most recent join, and keeps the open thread visible beneath
    /// its parent even when it is not otherwise relevant or joined.
    static func rows(
        for candidates: [Candidate],
        openThread: Candidate?,
        unreadOnly: Bool,
        hideMuted: Bool = false,
        now: Date
    ) -> [SidebarThreadRow] {
        var visible = candidates
            .filter { unreadOnly ? isUnreadRelevant($0, now: now) : isRelevant($0, now: now) }
            .filter { !hideMuted || !isMuted($0.thread, now: now) || $0.mentionCount > 0 }
            .sorted {
                let lhs = $0.thread.notificationSettings?.joinedAt ?? .distantPast
                let rhs = $1.thread.notificationSettings?.joinedAt ?? .distantPast
                return lhs == rhs ? $0.thread.id > $1.thread.id : lhs > rhs
            }
        if let openThread, !visible.contains(where: { $0.thread.id == openThread.thread.id }) {
            visible.insert(openThread, at: 0)
        }
        return visible.map {
            SidebarThreadRow(
                thread: $0.thread,
                isUnread: $0.showsUnread,
                mentionCount: $0.mentionCount,
                isMuted: isMuted($0.thread, now: now)
            )
        }
    }
}

extension AppModel {
    func sidebarThreadLayout(
        guildID: GuildID?,
        channelGroups: [ChannelGroup],
        now: Date
    ) -> SidebarThreadPolicy.Layout {
        guard let guildID else { return .init() }
        let settings = readState.notificationSettings(guildID: guildID)
        var layout = SidebarThreadPolicy.Layout()
        if settings?.hideMutedChannels == true {
            // A timed channel mute can expire without another Gateway event.
            // Reuse the sidebar's existing explicit refresh schedule.
            layout.relevanceDeadlines = settings?.channelOverrides.compactMap {
                guard $0.isMuted, let endTime = $0.muteConfiguration?.endTime,
                      endTime > now else { return nil }
                return endTime
            }.sorted() ?? []
        }
        let joined = activeJoinedThreads.filter {
            $0.guildID == guildID && !$0.isArchived
        }
        let open = (isThreadFullWidth ? openThread : nil).flatMap { thread -> MessageThreadSummary? in
            let guildMatches = thread.guildID == guildID
                || (thread.guildID == nil && channelGroups.contains {
                    $0.channels.contains { $0.id == thread.parentID }
                })
            return guildMatches ? thread : nil
        }
        guard !joined.isEmpty || open != nil else { return layout }

        let candidatesByParentID = Dictionary(
            grouping: joined,
            by: \.parentID
        )
        for group in channelGroups {
            let isCollapsed = group.categoryID.map {
                isCategoryCollapsed(guildID: guildID, categoryID: $0)
            } ?? false
            for channel in group.channels {
                guard SidebarThreadPolicy.listsThreads(under: channel.kind),
                      !hiddenChannelIDs.contains(channel.id) else { continue }
                let candidates = (candidatesByParentID[channel.id] ?? []).map(sidebarThreadCandidate)
                let openCandidate = open?.parentID == channel.id
                    ? candidates.first { $0.thread.id == open?.id }
                        ?? open.map(sidebarThreadCandidate)
                    : nil
                guard !candidates.isEmpty || openCandidate != nil else { continue }
                let isFocused = selectedChannelID == channel.id || openCandidate != nil
                let rows = SidebarThreadPolicy.rows(
                    for: candidates,
                    openThread: openCandidate,
                    unreadOnly: !isFocused && (isCollapsed || isChannelMuted(channel)),
                    hideMuted: !isFocused && readState.notificationSettings(guildID: guildID)?.hideMutedChannels == true,
                    now: now
                )
                if !rows.isEmpty {
                    layout.threadsByParentID[channel.id] = rows
                }
                layout.relevanceDeadlines += candidates.compactMap {
                    SidebarThreadPolicy.relevanceDeadline(for: $0)
                }.filter { $0 > now }
                layout.relevanceDeadlines += candidates.compactMap {
                    $0.thread.notificationSettings?.muteConfiguration?.endTime
                }.filter { $0 > now }
            }
        }
        layout.relevanceDeadlines.sort()
        return layout
    }

    private func sidebarThreadCandidate(
        _ thread: MessageThreadSummary
    ) -> SidebarThreadPolicy.Candidate {
        let entry = readState[thread.id]
        let latestMessageID = [entry?.latestKnownMessageID, thread.lastMessageID]
            .compactMap(\.self).max()
        return SidebarThreadPolicy.Candidate(
            thread: thread,
            latestMessageID: latestMessageID,
            hasUnread: entry?.isUnread ?? false,
            showsUnread: readState.unread(channelID: thread.id),
            mentionCount: readState.mentions(channelID: thread.id)
        )
    }

    func sidebarThread(_ id: ChannelID) -> MessageThreadSummary? {
        if let openThread, openThread.id == id { return openThread }
        return activeJoinedThreads.first { $0.id == id }
            ?? threads.first { $0.id == id }
    }

    func threadNavigationChannel(_ thread: MessageThreadSummary) -> Channel {
        Channel(id: thread.id, guildID: thread.guildID ?? selectedGuildID, name: thread.name)
    }

    func openSidebarThread(
        _ thread: MessageThreadSummary,
        historyDestination: ConversationNavigationHistory.Destination? = nil
    ) {
        onboarding.presentedGuildID = nil
        let target = ConversationNavigationTarget.thread(thread.id, fullWidth: true)
        if historyDestination == nil, isNavigating(to: target) { return }
        startConversationNavigation(target: target, to: historyDestination) { model, account in
            let guildID = thread.guildID ?? model.selectedGuildID
            if model.selectedGuildID != guildID {
                await model.activateGuild(guildID, account: account)
            }
            guard !Task.isCancelled, model.isCurrentAccountSession(account) else { return }
            guard let parentID = thread.parentID,
                  let parent = model.knownRootChannel(parentID)
            else {
                model.errorMessage = "That thread's parent channel has not been discovered yet."
                return
            }
            guard model.conversationAccess(for: parent) != .hidden else {
                model.errorMessage = "You do not have permission to view that thread."
                return
            }
            model.onboarding.presentedGuildID = nil
            if model.selectedChannelID != parentID { model.selectedChannelID = parentID }
            // Establish presentation before loading history so the hidden parent
            // cannot acknowledge messages while the thread occupies the workspace.
            if model.openThread?.id == thread.id {
                model.isThreadFullWidth = true
                model.suspendSelectedConversationPresentation()
            } else {
                model.openThreadConversation(
                    thread, starter: nil, startedAt: thread.createdAt,
                    initialMessages: [], fullWidth: true
                )
            }
        }
    }
}
