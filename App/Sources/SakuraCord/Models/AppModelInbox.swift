import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    func publishInbox() {
        for thread in snapshot?.activeJoinedThreads ?? [] { inbox.threads[thread.id] = thread }
        refreshInboxMentionRestrictions()
        inbox.publish(channels: snapshot?.channels ?? [], guilds: snapshot?.guilds ?? [], notifying: self)
    }

    func presentInbox() {
        guard sessionState == .workspace else { return }
        inbox.isPresented = true
        if !isOfflineTesting {
            let preferences = PRBuildProfile.defaults
            inbox.query = InboxMentionQuery(
                guildID: preferences.bool(forKey: "dev.sakuracord.inbox-current-server") ? selectedGuildID : nil,
                includesRoles: preferences.object(forKey: "dev.sakuracord.inbox-include-roles") as? Bool ?? true,
                includesEveryone: preferences.object(forKey: "dev.sakuracord.inbox-include-everyone") as? Bool ?? true
            )
        } else if inbox.query.guildID != nil { inbox.query.guildID = selectedGuildID }
        inbox.scrollRequest = MessageTimelineScrollRequest(target: .top)
        inbox.selectedMessageID = nil
        inbox.locallyUndoneEventGuilds = []
        inbox.undoGroups = []
        refreshInbox()
    }

    func inboxMentionQueryDidChange() {
        if !isOfflineTesting {
            let preferences = PRBuildProfile.defaults
            if selectedChannel?.guildID != nil {
                preferences.set(inbox.query.guildID != nil, forKey: "dev.sakuracord.inbox-current-server")
            }
            preferences.set(inbox.query.includesRoles, forKey: "dev.sakuracord.inbox-include-roles")
            preferences.set(inbox.query.includesEveryone, forKey: "dev.sakuracord.inbox-include-everyone")
        }
        inbox.scrollRequest = MessageTimelineScrollRequest(target: .top)
        resumeInbox()
    }

    func dismissInbox() {
        inbox.isPresented = false
        inbox.cancelLoad()
    }

    /// Switches tabs from retained content; Discord learns the final choice once.
    func selectInboxTab(_ tab: InboxTab) {
        guard inbox.tab != tab else { return }
        inbox.tab = tab
        inbox.pendingTab = tab
        inbox.selectedMessageID = nil
        inbox.scrollRequest = MessageTimelineScrollRequest(target: .top)
        resumeInbox()
        scheduleInboxSettingsSync()
    }

    /// Rebuilds unread groups from read state, keeping content for unchanged
    /// ranges, and quietly revalidates the newest mentions.
    func refreshInbox() {
        rebuildInboxUnreadGroups()
        inbox.needsMentionRevalidation = true
        resumeInbox()
    }

    /// An explicit refresh also refetches content that is already shown.
    func reloadInbox() {
        rebuildInboxUnreadGroups()
        for index in inbox.groups.indices where inbox.groups[index].isLoaded && !inbox.groups[index].isAgeRestricted {
            inbox.groups[index].needsRevalidation = true
        }
        inbox.needsMentionRevalidation = true
        inbox.isRefreshing = true
        resumeInbox()
    }

    private func rebuildInboxUnreadGroups() {
        let retained = Dictionary(inbox.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        inbox.groups = makeInboxUnreadGroups().map { fresh in
            guard let previous = retained[fresh.id], fresh.canReuseContent(of: previous) else { return fresh }
            var group = fresh
            group.messages = previous.messages
            group.forumPosts = previous.forumPosts
            group.events = group.isEvents ? visibleInboxEvents(for: group) : []
            group.isLoaded = true
            return group
        }
        inbox.unreadOrder = inbox.groups.map(\.id)
    }

    /// Presents the current tab immediately and fetches only what it lacks.
    private func resumeInbox() {
        inbox.cancelLoad()
        inbox.errorMessage = nil
        inbox.removedIDs = []
        inbox.deletedIDs = []
        if inbox.mentionsQuery != inbox.query {
            inbox.mentions = []
            inbox.nextBefore = nil
            inbox.hasMoreMentions = true
            inbox.needsMentionRevalidation = false
            inbox.mentionsQuery = inbox.query
        }
        publishInbox()
        // Page past hidden mentions even when retained pages are nonempty.
        if inbox.tab == .unread || inbox.visibleMentions.isEmpty || inbox.needsMentionRevalidation { loadMoreInbox() }
    }

    func retryInboxLoad() {
        inbox.errorMessage = nil
        loadMoreInbox()
    }

    func loadMoreInbox() {
        let revalidatesMentions = inbox.tab == .mentions && inbox.needsMentionRevalidation
        guard inbox.isPresented, !inbox.isLoading, inbox.hasMore || revalidatesMentions, inbox.errorMessage == nil else {
            if !inbox.isLoading { inbox.isRefreshing = false }
            return
        }
        let session = accountSession()
        let generation = inbox.generation
        let tab = inbox.tab
        let query = inbox.query
        let before = inbox.nextBefore
        let group = inbox.groups.first { !$0.isLoaded && !$0.isCollapsed }
            ?? inbox.groups.first { $0.needsRevalidation && !$0.isCollapsed }
        if tab == .unread, group == nil {
            inbox.isRefreshing = false
            return
        }
        inbox.isLoading = true
        inbox.refreshJournal = ConversationRefreshJournal(revision: generation)
        inbox.loadTask = Task { [weak self] in
            guard let self else { return }
            var continues = false
            defer {
                if isCurrentAccountSession(session), inbox.generation == generation {
                    inbox.isLoading = false
                    inbox.refreshJournal = nil
                    inbox.loadTask = nil
                    if continues { loadMoreInbox() } else { inbox.isRefreshing = false }
                }
            }
            do {
                if revalidatesMentions {
                    try await revalidateInboxMentions(query: query, session: session, generation: generation)
                } else if tab == .mentions {
                    try await loadInboxMentionPage(query: query, before: before, session: session, generation: generation)
                } else if let group {
                    try await loadInboxGroup(group, session: session, generation: generation)
                }
                guard !Task.isCancelled, isCurrentAccountSession(session), inbox.generation == generation else { return }
                inbox.errorMessage = nil
                await publishPreparedInbox(session: session, generation: generation)
                guard !Task.isCancelled, isCurrentAccountSession(session), inbox.generation == generation else { return }
                continues = dismissEmptyInboxGroups()
                    || group?.needsRevalidation == true && inbox.groups.contains { $0.needsRevalidation && !$0.isCollapsed }
                    || (tab == .mentions && inbox.visibleMentions.isEmpty && inbox.hasMoreMentions)
            } catch is CancellationError {
            } catch {
                guard isCurrentAccountSession(session), inbox.generation == generation else { return }
                inbox.errorMessage = error.localizedDescription
            }
        }
    }

    private func publishPreparedInbox(session: AppModelAccountSession, generation: UInt64) async {
        let channels = snapshot?.channels ?? []
        let guilds = snapshot?.guilds ?? []
        let messages = inbox.tab == .mentions ? inbox.mentions : inbox.groups.flatMap(\.messages)
        let channelGuildIDs = Dictionary(channels.compactMap { channel in channel.guildID.map { (channel.id, $0) } }, uniquingKeysWith: { first, _ in first })
        let guildIDs = Set(messages.compactMap { $0.guildID ?? channelGuildIDs[$0.channelID] })
        var changedRoles = false
        for guildID in guildIDs where guildRolesByGuildID[guildID] == nil {
            if let roles = try? await session.provider.roles(in: guildID), !roles.isEmpty {
                guard !Task.isCancelled, isCurrentAccountSession(session), inbox.generation == generation else { return }
                applyGuildRoles(roles, to: guildID)
                changedRoles = true
            }
        }
        if changedRoles { invalidateTimelinePresentation() }
        refreshInboxMentionRestrictions()
        let inputs = inbox.rowInputs(channels: channels, guilds: guilds)
        let oldRows = inbox.rows
        let revision = inbox.rowsRevision
        let rows = await Task.detached(priority: .userInitiated) {
            InboxMessageRowInput.reusingRows(oldRows, inputs: inputs)
        }.value
        guard !Task.isCancelled, isCurrentAccountSession(session), inbox.generation == generation else { return }
        if revision == inbox.rowsRevision {
            inbox.publish(channels: channels, guilds: guilds, preparedRows: rows, notifying: self)
        } else {
            publishInbox()
        }
    }

    func makeInboxUnreadGroups(now: Date = .now) -> [InboxUnreadGroup] {
        guard let snapshot else { return [] }
        let channels = Dictionary(snapshot.channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let threads = Dictionary(snapshot.activeJoinedThreads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let guildOrder = snapshot.guildRailItems.flatMap { item -> [GuildID] in
            switch item {
            case let .guild(id): [id]
            case let .folder(folder): folder.guildIDs
            }
        }
        let guildPositions = Dictionary(guildOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var candidates: [InboxUnreadCandidate] = []
        for entry in readState.entries.values {
            guard entry.isAccessible, entry.isUnread, let newest = entry.latestUnreadMessageID,
                  channels[entry.channelID] != nil || threads[entry.channelID] != nil else { continue }
            let policy = readState.effectivePolicy(for: entry, now: now)
            guard !policy.channelMuted else { continue }
            if threads[entry.channelID] == nil, policy.guildMuted || policy.categoryMuted { continue }
            if entry.mentionCount == 0,
               entry.guildID == nil || !readState.usesAllMessagesUnreadSetting(for: entry) { continue }
            let channel = channels[entry.channelID]
            let thread = threads[entry.channelID]
            if let settings = thread?.notificationSettings, settings.isMuted,
               settings.muteConfiguration?.isActive(at: now) ?? true { continue }
            if let context = channel ?? entry.parentID.flatMap({ channels[$0] }),
               let permissions = effectiveMessagePermissions(in: context),
               permissions & DiscordPermissionBits.readMessageHistory == 0 { continue }
            let age = now.timeIntervalSince1970 - Double((newest.rawValue >> 22) + 1_420_070_400_000) / 1_000
            let rank = inbox.settings.favoriteChannelIDs.contains(entry.channelID) ? 0
                : entry.guildID == nil ? 1 : entry.mentionCount > 0 ? ((entry.flags ?? 0) & 4 == 0 ? 2 : 3)
                : age > 10 * 86_400 ? 8 : age > 2 * 86_400 ? 6
                : policy.level == .nothing ? 7 : policy.level == .allMessages ? 4 : 5
            let guild = snapshot.guilds.first { $0.id == entry.guildID }
            let boundary = entry.lastAcknowledgedMessageID ?? guild?.joinedAt.map {
                MessageID(rawValue: UInt64(max(0, $0.timeIntervalSince1970 * 1_000 - 1_420_070_400_000)) << 22)
            }
            guard let boundary, boundary < newest else { continue }
            let restricted = inboxRequiresAgeAgreement(channelID: entry.channelID, guildID: entry.guildID)
            let group = InboxUnreadGroup(
                channelID: entry.channelID, guildID: entry.guildID,
                title: channel?.name ?? thread?.name ?? "Conversation",
                subtitle: snapshot.guilds.first { $0.id == entry.guildID }?.name,
                oldestReadMessageID: boundary,
                newestUnreadMessageID: newest, mentionCount: entry.mentionCount,
                isForum: channel?.kind == .forum, isAgeRestricted: restricted,
                isLoaded: restricted,
                isCollapsed: inbox.settings.collapsedChannelIDs.contains(entry.channelID)
            )
            let parent = entry.parentID.flatMap { channels[$0] }
            candidates.append(InboxUnreadCandidate(
                group: group, rank: rank, guild: entry.guildID.flatMap { guildPositions[$0] } ?? -1,
                position: (channel ?? parent)?.position ?? 0,
                parentID: thread?.parentID
            ))
        }
        candidates.append(contentsOf: inboxEventCandidates(guildPositions: guildPositions))
        return candidates.sorted(by: InboxUnreadCandidate.precedes).map(\.group)
    }

    func toggleInboxGroup(_ channelID: ChannelID) {
        guard let index = inbox.groups.firstIndex(where: { $0.id == channelID }) else { return }
        if inbox.groups[index].isAgeRestricted, let guildID = inbox.groups[index].guildID {
            requestInboxAgeAgreement(guildID: guildID) { [weak self] in self?.refreshInbox() }
            return
        }
        inbox.groups[index].isCollapsed.toggle()
        let group = inbox.groups[index]
        inbox.pendingCollapse[group.id] = InboxCollapseIntent(
            isCollapsed: group.isCollapsed, guildID: group.guildID, isEvents: group.isEvents
        )
        publishInbox()
        loadMoreInbox()
        scheduleInboxSettingsSync()
    }

    /// Coalesces rapid tab and collapse changes into the minimum set of saves.
    private func scheduleInboxSettingsSync() {
        inbox.settingsSyncTask?.cancel()
        let session = accountSession()
        inbox.settingsSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled, isCurrentAccountSession(session) else { return }
            inbox.settingsSyncTask = nil
            flushInboxSettings(session: session)
        }
    }

    /// Saves run one at a time; each Discord patch builds on the previous response.
    private func flushInboxSettings(session: AppModelAccountSession) {
        let previousTask = inbox.settingsTask
        inbox.settingsTask = Task { [weak self] in
            await previousTask?.value
            guard let self, !Task.isCancelled, isCurrentAccountSession(session) else { return }
            if let tab = inbox.pendingTab {
                if tab != inbox.settings.tab {
                    // A failed tab save only affects the next launch; keep the local choice.
                    try? await session.provider.updateInboxTab(tab)
                    guard isCurrentAccountSession(session) else { return }
                }
                if inbox.pendingTab == tab { inbox.pendingTab = nil }
            }
            for (id, intent) in inbox.pendingCollapse {
                let saved = intent.isEvents
                    ? intent.guildID.map { inbox.settings.collapsedEventGuildIDs.contains($0) } == true
                    : inbox.settings.collapsedChannelIDs.contains(id)
                var failure: (any Error)?
                if saved != intent.isCollapsed {
                    do {
                        try await session.provider.updateInboxCollapsed(
                            intent.isCollapsed,
                            channelID: intent.isEvents ? ChannelID(rawValue: 1_539_033_557_786_173_450) : id,
                            guildID: intent.guildID
                        )
                    } catch { failure = error }
                    guard isCurrentAccountSession(session) else { return }
                }
                guard inbox.pendingCollapse[id] == intent else { continue }
                inbox.pendingCollapse[id] = nil
                if let failure {
                    inbox.errorMessage = failure.localizedDescription
                    applyInboxSettings(inbox.settings)
                }
            }
        }
    }

    func dismissInboxMention(_ message: Message) {
        guard inbox.dismissingIDs.insert(message.id).inserted else { return }
        let session = accountSession()
        inbox.mutationTasks[message.id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await session.provider.dismissInboxMention(message.id)
                guard isCurrentAccountSession(session) else { return }
                removeInboxMessage(message.id)
            } catch {
                guard isCurrentAccountSession(session) else { return }
                inbox.errorMessage = error.localizedDescription
            }
            inbox.dismissingIDs.remove(message.id)
            inbox.mutationTasks[message.id] = nil
        }
    }

    func removeInboxMessage(_ id: MessageID, mentionsOnly: Bool = true) {
        guard inbox.isPresented || inbox.loadTask != nil || inbox.retainedMessages.contains(where: { $0.id == id }) else { return }
        inbox.removedIDs.insert(id)
        if mentionsOnly {
            inbox.mentions.removeAll { $0.id == id }
        } else {
            inbox.deletedIDs.insert(id)
            inbox.replaceRetainedMessage(id, with: nil)
        }
        publishInbox()
        if !mentionsOnly { dismissEmptyInboxGroups() }
    }

    func reconcileInboxMessage(_ message: Message, isNew: Bool = false) {
        var changed = inbox.replaceRetainedMessage(message.id, with: message)
        guard inbox.isPresented else { return }
        if inbox.refreshJournal != nil {
            let confirmed = pollVoteConfirmedSnapshot(reactionConfirmedSnapshot(message))
            inbox.refreshJournal?.record(.upsert(confirmed), messageID: message.id)
        }
        if isNew, !inbox.mentions.contains(where: { $0.id == message.id }), acceptsLiveInboxMention(message) {
            inbox.mentions.append(message)
            inbox.mentions.sort { $0.id > $1.id }
            resolveInboxThreadContext(for: message)
            changed = true
        }
        if changed { publishInbox() }
    }

    private func acceptsLiveInboxMention(_ message: Message) -> Bool {
        !inbox.removedIDs.contains(message.id)
            && readState.isInboxMention(message, query: inbox.query)
            && (inbox.query.guildID == nil || inbox.query.guildID == (message.guildID ?? readState.entries[message.channelID]?.guildID))
    }

    func reconcileInboxEligibility() {
        refreshInboxMentionRestrictions()
        guard inbox.isPresented else { return }
        let eligible = Set(makeInboxUnreadGroups().map(\.id))
        inbox.groups.removeAll { !eligible.contains($0.id) }
        inbox.mentions.removeAll {
            readState.entries[$0.channelID]?.isAccessible == false
        }
        publishInbox()
        if inbox.tab == .mentions, inbox.visibleMentions.isEmpty { loadMoreInbox() }
    }

    func reconcileInboxReadState() {
        guard inbox.isPresented else { return }
        for (id, group) in inbox.pendingReadGroups where readState.entries[id]?.pendingAcknowledgementID == nil {
            if (readState.entries[id]?.lastAcknowledgedMessageID ?? MessageID(rawValue: 0)) < group.newestUnreadMessageID {
                restoreInboxGroup(group)
                inbox.undoGroups.removeAll { $0.id == id }
            }
            inbox.pendingReadGroups[id] = nil
        }
        inbox.groups.removeAll { group in
            !group.isEvents && (readState.entries[group.id]?.lastAcknowledgedMessageID ?? MessageID(rawValue: 0)) >= group.newestUnreadMessageID
        }
        publishInbox()
    }

    func markInboxGroupRead(_ channelID: ChannelID, allowsUndo: Bool = true) {
        guard let index = inbox.groups.firstIndex(where: { $0.id == channelID }) else { return }
        let group = inbox.groups.remove(at: index)
        if allowsUndo { inbox.undoGroups.append(group) }
        if group.isEvents {
            markInboxEventGroupRead(group)
            return
        }
        let boundary = group.newestUnreadMessageID
        inbox.pendingReadGroups[channelID] = group
        let metadata = readState.acknowledgementMetadata(channelID: channelID)
        let lastViewed = readState.entries[channelID]?.lastViewed
        acknowledgementTasks[channelID]?.cancel()
        acknowledgementTasks[channelID] = nil
        readState.markAcknowledgementPending(channelID: channelID, messageID: boundary)
        enqueueAcknowledgement(channelID: channelID, mutation: ReadStateMutation(
            messageID: boundary, manual: false, mentionCount: nil,
            flags: metadata.flags, lastViewed: lastViewed
        ))
        if readState.entries[channelID]?.isUnread != true {
            cancelNativeNotifications(channelID: channelID)
        }
        refreshUnreadPresentation()
        publishInbox()
        loadMoreInbox()
    }

    func undoInboxRead() {
        guard let group = inbox.undoGroups.popLast(), let boundary = group.oldestReadMessageID else { return }
        if group.isEvents {
            undoInboxEventRead(group)
            return
        }
        let metadata = readState.acknowledgementMetadata(channelID: group.id)
        let lastViewed = readState.entries[group.id]?.lastViewed
        inbox.pendingReadGroups[group.id] = nil
        readState.markUnread(channelID: group.id, after: boundary, mentionCount: 0)
        enqueueAcknowledgement(channelID: group.id, mutation: ReadStateMutation(
            messageID: boundary, manual: true, mentionCount: nil,
            flags: metadata.flags, lastViewed: lastViewed, wireManual: false
        ))
        restoreInboxGroup(group)
        refreshUnreadPresentation()
        publishInbox()
    }

    func restoreInboxGroup(_ group: InboxUnreadGroup) {
        guard !inbox.groups.contains(where: { $0.id == group.id }) else { return }
        inbox.groups.append(group)
        let positions = Dictionary(uniqueKeysWithValues: inbox.unreadOrder.enumerated().map { ($1, $0) })
        inbox.groups.sort { positions[$0.id, default: .max] < positions[$1.id, default: .max] }
    }
}

struct InboxUnreadCandidate {
    let group: InboxUnreadGroup
    let rank: Int
    let guild: Int
    let position: Int
    var parentID: ChannelID?

    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        if lhs.guild != rhs.guild { return lhs.guild < rhs.guild }
        if lhs.group.guildID == nil { return lhs.group.newestUnreadMessageID > rhs.group.newestUnreadMessageID }
        if lhs.position != rhs.position { return lhs.position < rhs.position }
        // Discord visits each selectable channel in channel-position order,
        // followed immediately by that channel's joined threads. Categories
        // do not participate in this order.
        let leftParent = lhs.parentID ?? lhs.group.channelID
        let rightParent = rhs.parentID ?? rhs.group.channelID
        if leftParent != rightParent { return leftParent < rightParent }
        if (lhs.parentID == nil) != (rhs.parentID == nil) { return lhs.parentID == nil }
        return lhs.group.channelID < rhs.group.channelID
    }
}

extension AppModel {
    func applyInboxSettings(_ settings: InboxSettings) {
        inbox.settings = settings
        // An open Inbox keeps the tab the user is looking at; a delayed echo of
        // an earlier save must never switch it back.
        if !inbox.isPresented, inbox.pendingTab == nil { inbox.tab = settings.tab }
        var changed = false
        for index in inbox.groups.indices {
            let group = inbox.groups[index]
            let collapsed = inbox.pendingCollapse[group.id]?.isCollapsed ?? (group.isEvents
                ? group.guildID.map { settings.collapsedEventGuildIDs.contains($0) } == true
                : settings.collapsedChannelIDs.contains(group.id))
            guard collapsed != group.isCollapsed else { continue }
            inbox.groups[index].isCollapsed = collapsed
            changed = true
        }
        guard changed, inbox.isPresented else { return }
        publishInbox()
        loadMoreInbox()
    }
}
