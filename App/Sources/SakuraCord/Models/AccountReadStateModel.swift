import Foundation
import Observation
import SakuraCordModels

@MainActor
@Observable
final class AccountReadStateModel {
    struct TimelineUnreadSummary: Equatable, Sendable {
        var firstUnreadMessageID: MessageID
        var loadedUnreadCount: Int
        var isLowerBound: Bool
        var firstUnreadTimestamp: Date
    }

    struct Entry: Equatable, Sendable {
        var channelID: ChannelID
        var guildID: GuildID?
        var parentID: ChannelID?
        var kind: ChannelKindValue
        var latestKnownMessageID: MessageID?
        var latestUnreadMessageID: MessageID?
        var lastAcknowledgedMessageID: MessageID?
        var mentionCount: Int
        var unreadMessageCount: Int
        var pendingAcknowledgementID: MessageID?
        var flags: UInt64?
        var lastViewed: Int?
        var threadNotificationSettings: ThreadNotificationSettings?
        var isAccessible: Bool
        var hasAuthoritativeReadState: Bool

        var isUnread: Bool {
            guard let latestUnreadMessageID else { return false }
            guard let lastAcknowledgedMessageID else { return true }
            return latestUnreadMessageID > lastAcknowledgedMessageID
        }
    }

    struct Presentation: Equatable, Sendable {
        var isPresented = false
        var initialHistoryLoaded = false
        var initialPositionEstablished = false
        var windowIsActive = false
        var hasReachedReadBoundary = false
        var blocksAutomaticAcknowledgement = false

        var canAcknowledge: Bool {
            isPresented
                && initialHistoryLoaded
                && initialPositionEstablished
                && windowIsActive
                && hasReachedReadBoundary
                && !blocksAutomaticAcknowledgement
        }
    }

    enum MentionKind: Equatable, Sendable {
        case none
        case direct
        case role
        case everyone
        case directMessage
    }

    struct MessageDisposition: Equatable, Sendable {
        var accepted: Bool
        var mentionKind: MentionKind
        var shouldNotify: Bool
    }

    struct AcknowledgementMetadata: Equatable, Sendable {
        var flags: UInt64
        var lastViewed: Int
    }

    private struct PendingRollback: Sendable {
        var messageID: MessageID
        var predecessorMessageID: MessageID?
        var lastAcknowledgedMessageID: MessageID?
        var mentionCount: Int
        var unreadMessageCount: Int
    }

    private(set) var accountID: String?
    private(set) var entries: [ChannelID: Entry] = [:]
    private(set) var settingsByGuild: [GuildID?: GuildNotificationSettings] = [:]
    private(set) var presentations: [ChannelID: Presentation] = [:]
    private(set) var acknowledgementToken: String?
    private(set) var readStateVersion: Int?
    private var channelByID: [ChannelID: Channel] = [:]
    private var defaultNotificationLevelByGuild: [GuildID: MessageNotificationLevel] = [:]
    private var currentUserRoleIDsByGuild: [GuildID: Set<RoleID>] = [:]
    private var pendingRollbacks: [ChannelID: [MessageID: PendingRollback]] = [:]
    private var forumSelectionAcknowledgementBoundary: [ChannelID: MessageID] = [:]
    private var forumPostArchivedByID: [ChannelID: Bool] = [:]
    private var usesNewNotifications = true

    func reset(accountID: String?) {
        self.accountID = accountID
        entries.removeAll()
        settingsByGuild.removeAll()
        presentations.removeAll()
        acknowledgementToken = nil
        readStateVersion = nil
        channelByID.removeAll()
        defaultNotificationLevelByGuild.removeAll()
        currentUserRoleIDsByGuild.removeAll()
        pendingRollbacks.removeAll()
        forumSelectionAcknowledgementBoundary.removeAll()
        forumPostArchivedByID.removeAll()
        usesNewNotifications = true
    }

    func configure(
        accountID: String?,
        guilds: [Guild],
        channels: [Channel],
        readStates: [ChannelReadState],
        notificationSettings: [GuildNotificationSettings],
        usesNewNotifications: Bool = true
    ) {
        if self.accountID != accountID {
            reset(accountID: accountID)
        }
        merge(guilds: guilds)
        merge(channels: channels)
        self.usesNewNotifications = usesNewNotifications
        for state in readStates {
            applyRemote(state)
        }
        seedOmittedReadBoundaries(
            channelIDs: Set(channels.map(\.id)).subtracting(readStates.map(\.channelID))
        )
        for settings in notificationSettings {
            apply(settings)
        }
    }

    func merge(guilds: [Guild]) {
        for guild in guilds {
            defaultNotificationLevelByGuild[guild.id] = guild.defaultMessageNotifications
        }
    }

    func updateNotificationMode(usesNewNotifications: Bool) {
        self.usesNewNotifications = usesNewNotifications
    }

    func merge(channels: [Channel]) {
        for channel in channels {
            channelByID[channel.id] = channel
            var entry = entries[channel.id] ?? Entry(
                channelID: channel.id,
                guildID: channel.guildID,
                parentID: channel.categoryID,
                kind: channel.kind,
                latestKnownMessageID: nil,
                latestUnreadMessageID: nil,
                lastAcknowledgedMessageID: nil,
                mentionCount: 0,
                unreadMessageCount: 0,
                pendingAcknowledgementID: nil,
                flags: nil,
                lastViewed: nil,
                threadNotificationSettings: nil,
                isAccessible: true,
                hasAuthoritativeReadState: false
            )
            entry.guildID = channel.guildID
            entry.parentID = channel.categoryID
            entry.kind = channel.kind
            entry.latestKnownMessageID = maximum(entry.latestKnownMessageID, channel.lastMessageID)
            if entry.hasAuthoritativeReadState {
                entry.latestUnreadMessageID = maximum(
                    entry.latestUnreadMessageID, channel.lastMessageID
                )
            }
            entries[channel.id] = entry
        }
    }

    func replaceChannels(in guildID: GuildID?, with channels: [Channel]) {
        let replacementIDs = Set(channels.map(\.id))
        let removedIDs = channelByID.values.compactMap { channel -> ChannelID? in
            channel.guildID == guildID && !replacementIDs.contains(channel.id)
                ? channel.id
                : nil
        }
        for channelID in removedIDs {
            channelByID[channelID] = nil
            entries[channelID] = nil
            presentations[channelID] = nil
            pendingRollbacks[channelID] = nil
            forumSelectionAcknowledgementBoundary[channelID] = nil
        }
        merge(channels: channels)
    }

    func replaceThreads(parentID: ChannelID, with threads: [MessageThreadSummary]) {
        let replacementIDs = Set(threads.map(\.id))
        let removedIDs = entries.values.compactMap { entry -> ChannelID? in
            entry.parentID == parentID
                && channelByID[entry.channelID] == nil
                && !replacementIDs.contains(entry.channelID)
                ? entry.channelID
                : nil
        }
        for channelID in removedIDs {
            entries[channelID] = nil
            presentations[channelID] = nil
            pendingRollbacks[channelID] = nil
            forumPostArchivedByID[channelID] = nil
        }
        for thread in threads {
            merge(thread: thread)
        }
    }

    func retainGuilds(_ guildIDs: Set<GuildID>) {
        let removedEntryIDs = entries.values.compactMap { entry -> ChannelID? in
            guard let guildID = entry.guildID, !guildIDs.contains(guildID) else { return nil }
            return entry.channelID
        }
        for channelID in removedEntryIDs {
            entries[channelID] = nil
            presentations[channelID] = nil
            channelByID[channelID] = nil
            pendingRollbacks[channelID] = nil
            forumSelectionAcknowledgementBoundary[channelID] = nil
            forumPostArchivedByID[channelID] = nil
        }
        settingsByGuild = settingsByGuild.filter { guildID, _ in
            guard let guildID else { return true }
            return guildIDs.contains(guildID)
        }
        defaultNotificationLevelByGuild = defaultNotificationLevelByGuild.filter {
            guildIDs.contains($0.key)
        }
        currentUserRoleIDsByGuild = currentUserRoleIDsByGuild.filter {
            guildIDs.contains($0.key)
        }
    }

    func apply(_ settings: GuildNotificationSettings) {
        settingsByGuild[settings.guildID] = settings
    }

    func notificationSettings(guildID: GuildID?) -> GuildNotificationSettings? {
        settingsByGuild[guildID]
    }

    func notificationOverride(
        channelID: ChannelID,
        guildID: GuildID?
    ) -> ChannelNotificationOverride? {
        settingsByGuild[guildID]?.channelOverrides.last {
            $0.channelID == channelID
        }
    }

    func isChannelMuted(_ channel: Channel, at date: Date = .now) -> Bool {
        guard !channel.isMuted else { return true }
        let settings = settingsByGuild[channel.guildID]
        let directOverride = settings?.channelOverrides.last {
            $0.channelID == channel.id
        }
        let categoryOverride = channel.categoryID.flatMap { categoryID in
            settings?.channelOverrides.last { $0.channelID == categoryID }
        }
        guard let override = directOverride ?? categoryOverride else {
            return false
        }
        return override.isMuted
            && (override.muteConfiguration?.isActive(at: date) ?? true)
    }

    func inheritedNotificationLevel(for channel: Channel) -> MessageNotificationLevel {
        let guildSettings = settingsByGuild[channel.guildID]
        let parentOverride = channel.categoryID.flatMap { parentID in
            guildSettings?.channelOverrides.last { $0.channelID == parentID }
        }
        if let level = parentOverride?.messageNotifications,
           level != .inherit
        {
            return level
        }
        let configuredGuildLevel = guildSettings?.messageNotifications ?? .inherit
        if configuredGuildLevel != .inherit {
            return configuredGuildLevel
        }
        if channel.guildID == nil {
            return .allMessages
        }
        return channel.guildID.flatMap { defaultNotificationLevelByGuild[$0] }
            ?? .onlyMentions
    }

    func updateCurrentUserRoles(_ roleIDs: Set<RoleID>, guildID: GuildID) {
        currentUserRoleIDsByGuild[guildID] = roleIDs
    }

    func setAccessible(_ isAccessible: Bool, channelID: ChannelID) {
        applyAccessibility([channelID: isAccessible])
    }

    /// Applies resolved channel accessibility and propagates each value to the
    /// threads and forum posts hanging off that channel.
    ///
    /// A channel present in `resolved` keeps its own value. Entries absent from
    /// it inherit from their parent when that parent resolved. The account-wide
    /// reconcile runs on every unread refresh, so it must walk the entry table
    /// a fixed number of times rather than rescan it once per channel. It also
    /// publishes only when a value changed because `entries` is observable.
    @discardableResult
    func applyAccessibility(_ resolved: [ChannelID: Bool]) -> Bool {
        guard !resolved.isEmpty else { return false }
        var updated = entries
        var didChange = false
        for (channelID, isAccessible) in resolved {
            if let existing = updated[channelID] {
                guard existing.isAccessible != isAccessible else { continue }
                updated[channelID]?.isAccessible = isAccessible
            } else {
                var value = entry(for: channelID)
                value.isAccessible = isAccessible
                updated[channelID] = value
            }
            didChange = true
        }
        for (channelID, value) in entries where resolved[channelID] == nil {
            guard let parentID = value.parentID,
                  let inherited = resolved[parentID],
                  value.isAccessible != inherited
            else { continue }
            updated[channelID]?.isAccessible = inherited
            didChange = true
        }
        guard didChange else { return false }
        entries = updated
        return true
    }

    @discardableResult
    func applyRemote(_ state: ChannelReadState) -> Bool {
        if let version = state.version,
           let readStateVersion,
           version < readStateVersion
        {
            return false
        }
        var entry = entry(for: state.channelID)
        if let existing = entry.lastAcknowledgedMessageID,
           let incoming = state.lastAcknowledgedMessageID,
           incoming < existing,
           !state.isManual
        {
            if let version = state.version {
                readStateVersion = max(readStateVersion ?? version, version)
            }
            return false
        }
        if state.isManual {
            entry.lastAcknowledgedMessageID = state.lastAcknowledgedMessageID
        } else {
            entry.lastAcknowledgedMessageID = maximum(
                entry.lastAcknowledgedMessageID, state.lastAcknowledgedMessageID
            )
        }
        entry.mentionCount = max(0, state.mentionCount)
        entry.flags = state.flags ?? entry.flags
        entry.lastViewed = state.lastViewed ?? entry.lastViewed
        entry.hasAuthoritativeReadState = true
        entry.latestUnreadMessageID = maximum(
            entry.latestUnreadMessageID, entry.latestKnownMessageID
        )
        entry.unreadMessageCount = entry.isUnread
            ? max(1, entry.unreadMessageCount)
            : 0
        let confirmsPending = entry.pendingAcknowledgementID.map { pending in
            entry.lastAcknowledgedMessageID.map { acknowledged in
                state.isManual ? acknowledged == pending : acknowledged >= pending
            } ?? false
        } ?? false
        if confirmsPending {
            entry.pendingAcknowledgementID = nil
            pendingRollbacks[state.channelID] = nil
        }
        entries[state.channelID] = entry
        if let version = state.version {
            readStateVersion = max(readStateVersion ?? version, version)
        }
        return true
    }

    func replaceReadStates(_ states: [ChannelReadState], version: Int? = nil) {
        let snapshotVersion = version ?? states.compactMap(\.version).max()
        if let snapshotVersion,
           let readStateVersion,
           snapshotVersion < readStateVersion {
            return
        }
        let previousEntries = entries
        let latestStateByChannel = Dictionary(
            states.map { ($0.channelID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        entries.removeAll(keepingCapacity: true)
        merge(channels: Array(channelByID.values))
        for state in latestStateByChannel.values {
            applyRemote(state)
        }
        for channelID in Array(entries.keys) {
            guard let previous = previousEntries[channelID] else { continue }
            entries[channelID] = reconciledSnapshotEntry(
                channelID: channelID,
                previous: previous,
                remote: latestStateByChannel[channelID]
            )
        }
        for (channelID, previous) in previousEntries {
            overlayPendingAcknowledgement(
                channelID: channelID,
                previous: previous,
                remote: latestStateByChannel[channelID]
            )
        }
        if let snapshotVersion {
            readStateVersion = max(readStateVersion ?? snapshotVersion, snapshotVersion)
        }
    }

    private func reconciledSnapshotEntry(
        channelID: ChannelID,
        previous: Entry,
        remote: ChannelReadState?
    ) -> Entry {
        var value = entry(for: channelID)
        value.latestKnownMessageID = maximum(
            value.latestKnownMessageID, previous.latestKnownMessageID
        )
        if value.hasAuthoritativeReadState {
            value.latestUnreadMessageID = maximum(
                value.latestUnreadMessageID, previous.latestKnownMessageID
            )
        }
        value.guildID = value.guildID ?? previous.guildID
        value.parentID = value.parentID ?? previous.parentID
        if channelByID[channelID] == nil { value.kind = previous.kind }
        value.isAccessible = previous.isAccessible
        if let remote,
           !remote.isManual,
           let previousAcknowledged = previous.lastAcknowledgedMessageID,
           remote.lastAcknowledgedMessageID.map({ $0 < previousAcknowledged }) ?? true {
            value.lastAcknowledgedMessageID = previousAcknowledged
            value.mentionCount = previous.mentionCount
            value.unreadMessageCount = previous.unreadMessageCount
            value.flags = previous.flags
            value.lastViewed = previous.lastViewed
        } else if remote == nil, let latestKnownMessageID = value.latestKnownMessageID {
            value.lastAcknowledgedMessageID = latestKnownMessageID
            value.mentionCount = 0
            value.unreadMessageCount = 0
        } else {
            value.unreadMessageCount = value.isUnread
                ? max(max(value.unreadMessageCount, previous.unreadMessageCount), 1)
                : 0
        }
        return value
    }

    private func overlayPendingAcknowledgement(
        channelID: ChannelID,
        previous: Entry,
        remote: ChannelReadState?
    ) {
        guard let pending = previous.pendingAcknowledgementID,
              pendingRollbacks[channelID]?[pending] != nil
        else { return }
        let confirmsPending = remote?.lastAcknowledgedMessageID.map { acknowledged in
            remote?.isManual == true ? acknowledged == pending : acknowledged >= pending
        } ?? false
        if confirmsPending {
            pendingRollbacks[channelID] = nil
            return
        }
        var value = entries[channelID] ?? previous
        value.latestKnownMessageID = maximum(
            value.latestKnownMessageID, previous.latestKnownMessageID
        )
        value.latestUnreadMessageID = maximum(
            value.latestUnreadMessageID, previous.latestUnreadMessageID
        )
        value.lastAcknowledgedMessageID = previous.lastAcknowledgedMessageID
        value.mentionCount = previous.mentionCount
        value.unreadMessageCount = previous.unreadMessageCount
        value.pendingAcknowledgementID = pending
        value.flags = previous.flags
        value.lastViewed = previous.lastViewed
        value.hasAuthoritativeReadState = previous.hasAuthoritativeReadState
            || value.hasAuthoritativeReadState
        entries[channelID] = value
    }

    func observeLoadedMessages(channelID: ChannelID, messages: [Message]) {
        guard let newest = messages.max(by: { $0.id < $1.id }) else { return }
        var entry = entry(for: channelID)
        entry.latestKnownMessageID = maximum(entry.latestKnownMessageID, newest.id)
        if entry.hasAuthoritativeReadState {
            entry.latestUnreadMessageID = maximum(entry.latestUnreadMessageID, newest.id)
            entry.unreadMessageCount = entry.isUnread
                ? max(1, entry.unreadMessageCount)
                : 0
        }
        entries[channelID] = entry
    }

    func receive(
        _ message: Message,
        currentUserID: UserID,
        now: Date = .now
    ) -> MessageDisposition {
        var entry = entry(for: message.channelID)
        guard entry.isAccessible else {
            return MessageDisposition(accepted: false, mentionKind: .none, shouldNotify: false)
        }
        if entry.guildID == nil { entry.guildID = message.guildID }
        if let latest = entry.latestKnownMessageID, message.id <= latest {
            return MessageDisposition(accepted: false, mentionKind: .none, shouldNotify: false)
        }
        entry.latestKnownMessageID = message.id

        if message.author.id == currentUserID {
            if !entry.isUnread {
                entry.lastAcknowledgedMessageID = maximum(
                    entry.lastAcknowledgedMessageID, message.id
                )
            }
            entries[message.channelID] = entry
            return MessageDisposition(accepted: true, mentionKind: .none, shouldNotify: false)
        }

        entry.latestUnreadMessageID = maximum(entry.latestUnreadMessageID, message.id)
        entry.unreadMessageCount += 1
        let policy = effectivePolicy(for: entry, now: now)
        let mentionKind = mentionKind(for: message, entry: entry, policy: policy)
        if mentionKind != .none {
            entry.mentionCount += 1
        }
        entries[message.channelID] = entry

        let isMention = mentionKind != .none
        let createsForumThread =
            message.id.rawValue == message.channelID.rawValue
            && entry.parentID.flatMap { channelByID[$0] }?.kind == .forum
        let allowsOrdinaryNotification =
            createsForumThread
            ? policy.notifiesNewForumThreads
            : policy.level == .allMessages
        let shouldNotify =
            !message.flags.contains(.suppressNotifications)
            && ((isMention && allowsNativeNotification(for: mentionKind, policy: policy))
                || (!isMention && allowsOrdinaryNotification
                    && !policy.guildMuted && !policy.channelMuted))
        return MessageDisposition(
            accepted: true,
            mentionKind: mentionKind,
            shouldNotify: shouldNotify
        )
    }

    func merge(thread: MessageThreadSummary) {
        var entry = entry(for: thread.id)
        entry.guildID = thread.guildID
        entry.parentID = thread.parentID
        entry.kind = .text
        if let settings = thread.notificationSettings {
            entry.threadNotificationSettings = settings
        }
        entry.latestKnownMessageID = maximum(entry.latestKnownMessageID, thread.lastMessageID)
        if entry.hasAuthoritativeReadState {
            entry.latestUnreadMessageID = maximum(
                entry.latestUnreadMessageID, thread.lastMessageID
            )
            entry.unreadMessageCount = entry.isUnread
                ? max(1, entry.unreadMessageCount)
                : 0
        }
        if let parentID = thread.parentID, let parent = entries[parentID] {
            entry.isAccessible = parent.isAccessible
        }
        entries[thread.id] = entry
        forumPostArchivedByID[thread.id] = thread.isArchived

        guard let parentID = thread.parentID,
              var parent = entries[parentID],
              parent.kind == .forum
        else { return }
        let threadMessageID = MessageID(rawValue: thread.id.rawValue)
        parent.latestKnownMessageID = maximum(parent.latestKnownMessageID, threadMessageID)
        if parent.hasAuthoritativeReadState {
            parent.latestUnreadMessageID = maximum(
                parent.latestUnreadMessageID, threadMessageID
            )
            parent.unreadMessageCount = parent.isUnread
                ? max(1, parent.unreadMessageCount)
                : 0
        }
        entries[parentID] = parent
    }

    func merge(forumPost: ForumPost) {
        merge(thread: forumPost.thread)
        guard forumPost.isUnread else { return }
        let latestMessageID =
            forumPost.thread.lastMessageID
            ?? forumPost.mostRecentMessage?.id
            ?? forumPost.firstMessage?.id
        guard let latestMessageID else { return }
        var entry = entry(for: forumPost.id)
        let hadNoAcknowledgedBoundary = entry.lastAcknowledgedMessageID == nil
        if entry.lastAcknowledgedMessageID == nil {
            let firstUnreadMessageID = forumPost.firstMessage?.id ?? latestMessageID
            entry.lastAcknowledgedMessageID = MessageID(
                rawValue: firstUnreadMessageID.rawValue == 0
                    ? 0
                    : firstUnreadMessageID.rawValue - 1
            )
        }
        entry.latestKnownMessageID = maximum(entry.latestKnownMessageID, latestMessageID)
        entry.latestUnreadMessageID = maximum(entry.latestUnreadMessageID, latestMessageID)
        let allRepliesAreAfterAcknowledgement: Bool
        if hadNoAcknowledgedBoundary {
            allRepliesAreAfterAcknowledgement = true
        } else if let acknowledged = entry.lastAcknowledgedMessageID,
           let firstMessageID = forumPost.firstMessage?.id
        {
            allRepliesAreAfterAcknowledgement = acknowledged <= firstMessageID
        } else {
            allRepliesAreAfterAcknowledgement = entry.lastAcknowledgedMessageID == nil
        }
        let catalogueUnreadCount =
            allRepliesAreAfterAcknowledgement ? max(1, forumPost.replyCount) : 1
        entry.unreadMessageCount = max(catalogueUnreadCount, entry.unreadMessageCount)
        entries[forumPost.id] = entry
    }

    /// Captures Discord's forum-selection read boundary before the parent
    /// acknowledgement advances. Post-level unread state remains independent.
    func beginForumVisit(channelID: ChannelID) {
        guard entries[channelID]?.kind == .forum else { return }
        forumSelectionAcknowledgementBoundary[channelID] =
            entries[channelID]?.lastAcknowledgedMessageID ?? MessageID(rawValue: 0)
    }

    func endForumVisit(channelID: ChannelID) {
        forumSelectionAcknowledgementBoundary[channelID] = nil
    }

    func isUnopenedForumPost(_ post: ForumPost) -> Bool {
        entries[post.id]?.hasAuthoritativeReadState != true
            && presentations[post.id] == nil
    }

    func isNewForumPost(_ post: ForumPost) -> Bool {
        guard !post.thread.isArchived,
              post.thread.parentID.flatMap({ entries[$0]?.kind }) == .forum,
              isUnopenedForumPost(post),
              let parentID = post.thread.parentID,
              let boundary = forumSelectionAcknowledgementBoundary[parentID]
                ?? entries[parentID]?.lastAcknowledgedMessageID
        else { return false }
        return MessageID(rawValue: post.id.rawValue) > boundary
    }

    func forumNewPostCount(channelID: ChannelID) -> Int {
        guard let parent = entries[channelID],
              parent.kind == .forum,
              parent.hasAuthoritativeReadState
        else { return 0 }
        let boundary = parent.lastAcknowledgedMessageID ?? MessageID(rawValue: 0)
        return entries.values.lazy.filter { entry in
            entry.parentID == channelID
                && self.forumPostArchivedByID[entry.channelID] != true
                && !entry.hasAuthoritativeReadState
                && MessageID(rawValue: entry.channelID.rawValue) > boundary
        }.count
    }

    func shouldAcknowledgeForumVisit(channelID: ChannelID) -> Bool {
        guard let entry = entries[channelID], entry.kind == .forum else { return false }
        return entry.isUnread || forumNewPostCount(channelID: channelID) > 0
    }

    func updatePresentation(
        channelID: ChannelID,
        isPresented: Bool? = nil,
        initialHistoryLoaded: Bool? = nil,
        initialPositionEstablished: Bool? = nil,
        windowIsActive: Bool? = nil,
        hasReachedReadBoundary: Bool? = nil,
        blocksAutomaticAcknowledgement: Bool? = nil
    ) -> MessageID? {
        var value = presentations[channelID] ?? Presentation()
        if let isPresented { value.isPresented = isPresented }
        if let initialHistoryLoaded { value.initialHistoryLoaded = initialHistoryLoaded }
        if let initialPositionEstablished {
            value.initialPositionEstablished = initialPositionEstablished
        }
        if let windowIsActive { value.windowIsActive = windowIsActive }
        if let hasReachedReadBoundary {
            value.hasReachedReadBoundary = hasReachedReadBoundary
        }
        if let blocksAutomaticAcknowledgement {
            value.blocksAutomaticAcknowledgement = blocksAutomaticAcknowledgement
        }
        presentations[channelID] = value
        return value.canAcknowledge ? newestUnacknowledgedMessage(in: channelID) : nil
    }

    func markAcknowledgementPending(channelID: ChannelID, messageID: MessageID) {
        var entry = entry(for: channelID)
        if pendingRollbacks[channelID]?[messageID] == nil {
            pendingRollbacks[channelID, default: [:]][messageID] = PendingRollback(
                messageID: messageID,
                predecessorMessageID: entry.pendingAcknowledgementID,
                lastAcknowledgedMessageID: entry.lastAcknowledgedMessageID,
                mentionCount: entry.mentionCount,
                unreadMessageCount: entry.unreadMessageCount
            )
        }
        entry.lastAcknowledgedMessageID = maximum(entry.lastAcknowledgedMessageID, messageID)
        entry.pendingAcknowledgementID = maximum(entry.pendingAcknowledgementID, messageID)
        if let newest = entry.latestKnownMessageID, messageID >= newest {
            entry.mentionCount = 0
            entry.unreadMessageCount = 0
        }
        entries[channelID] = entry
    }

    func markUnread(
        channelID: ChannelID,
        after messageID: MessageID,
        mentionCount: Int
    ) {
        var entry = entry(for: channelID)
        pendingRollbacks[channelID] = Dictionary(
            uniqueKeysWithValues: [
                (
                    messageID,
                    PendingRollback(
                        messageID: messageID,
                        predecessorMessageID: nil,
                        lastAcknowledgedMessageID: entry.lastAcknowledgedMessageID,
                        mentionCount: entry.mentionCount,
                        unreadMessageCount: entry.unreadMessageCount
                    )
                )
            ]
        )
        entry.lastAcknowledgedMessageID = messageID
        entry.pendingAcknowledgementID = messageID
        entry.mentionCount = max(0, mentionCount)
        entry.unreadMessageCount = max(1, entry.unreadMessageCount)
        entries[channelID] = entry
        _ = updatePresentation(
            channelID: channelID,
            hasReachedReadBoundary: false,
            blocksAutomaticAcknowledgement: true
        )
    }

    func unblockAutomaticAcknowledgement(channelID: ChannelID) {
        _ = updatePresentation(
            channelID: channelID,
            blocksAutomaticAcknowledgement: false
        )
    }

    func completeAcknowledgement(
        channelID: ChannelID,
        messageID: MessageID,
        token: String?
    ) {
        if let token { acknowledgementToken = token }
        var entry = entry(for: channelID)
        if entry.pendingAcknowledgementID == messageID {
            entry.pendingAcknowledgementID = nil
            pendingRollbacks[channelID] = nil
        } else {
            discardPendingRollback(
                channelID: channelID,
                messageID: messageID,
                succeeded: true
            )
        }
        entries[channelID] = entry
    }

    func failAcknowledgement(channelID: ChannelID, messageID: MessageID) {
        var entry = entry(for: channelID)
        if entry.pendingAcknowledgementID == messageID,
           let rollback = pendingRollbacks[channelID]?[messageID]
        {
            entry.lastAcknowledgedMessageID = rollback.lastAcknowledgedMessageID
            entry.mentionCount = rollback.mentionCount
            entry.unreadMessageCount = rollback.unreadMessageCount
            entry.pendingAcknowledgementID = rollback.predecessorMessageID
            pendingRollbacks[channelID]?[messageID] = nil
            if pendingRollbacks[channelID]?.isEmpty == true {
                pendingRollbacks[channelID] = nil
            }
        } else {
            discardPendingRollback(
                channelID: channelID,
                messageID: messageID,
                succeeded: false
            )
        }
        entries[channelID] = entry
    }

    private func discardPendingRollback(
        channelID: ChannelID,
        messageID: MessageID,
        succeeded: Bool
    ) {
        guard let discarded = pendingRollbacks[channelID]?[messageID] else { return }
        let childID = pendingRollbacks[channelID]?.values.first {
            $0.predecessorMessageID == messageID
        }?.messageID
        if let childID, var child = pendingRollbacks[channelID]?[childID] {
            child.predecessorMessageID = discarded.predecessorMessageID
            if !succeeded {
                child.lastAcknowledgedMessageID = discarded.lastAcknowledgedMessageID
                child.mentionCount += discarded.mentionCount
                child.unreadMessageCount += discarded.unreadMessageCount
            }
            pendingRollbacks[channelID]?[childID] = child
        }
        pendingRollbacks[channelID]?[messageID] = nil
        if pendingRollbacks[channelID]?.isEmpty == true {
            pendingRollbacks[channelID] = nil
        }
    }

    private func seedOmittedReadBoundaries(channelIDs: Set<ChannelID>) {
        for channelID in channelIDs {
            var value = entry(for: channelID)
            guard let latestKnownMessageID = value.latestKnownMessageID else { continue }
            value.lastAcknowledgedMessageID = latestKnownMessageID
            value.mentionCount = 0
            value.unreadMessageCount = 0
            entries[channelID] = value
        }
    }

    func unread(channelID: ChannelID, now: Date = .now) -> Bool {
        guard let entry = entries[channelID], entry.isAccessible, entry.isUnread else {
            return false
        }
        guard !isGuildResourceChannel(entry) else { return false }
        if entry.kind == .voice && entry.mentionCount == 0 {
            return false
        }
        let policy = effectivePolicy(for: entry, now: now)
        return entry.mentionCount > 0 || (!policy.guildMuted && !policy.channelMuted && policy.showsUnread)
    }

    func mentions(channelID: ChannelID) -> Int {
        guard let entry = entries[channelID],
              entry.isAccessible,
              !isGuildResourceChannel(entry)
        else { return 0 }
        return entry.mentionCount
    }

    func unreadMessageCount(channelID: ChannelID) -> Int {
        guard let entry = entries[channelID], entry.isAccessible, entry.isUnread else {
            return 0
        }
        return max(1, entry.unreadMessageCount)
    }

    func guildUnread(_ guildID: GuildID, now: Date = .now) -> Bool {
        channelByID.values.contains { channel in
            channel.guildID == guildID
                && unread(channelID: channel.id, now: now)
        }
    }

    func guildMentions(_ guildID: GuildID) -> Int {
        entries.values.lazy.filter { $0.guildID == guildID }.reduce(0) {
            $0 + mentions(channelID: $1.channelID)
        }
    }

    func folderUnread(_ guildIDs: [GuildID], now: Date = .now) -> Bool {
        guildIDs.contains { guildUnread($0, now: now) }
    }

    func folderMentions(_ guildIDs: [GuildID]) -> Int {
        guildIDs.reduce(0) { $0 + guildMentions($1) }
    }

    func directMessageUnread(now: Date = .now) -> Bool {
        entries.values.contains { entry in
            (entry.kind == .directMessage || entry.kind == .groupDirectMessage)
                && unread(channelID: entry.channelID, now: now)
        }
    }

    var directMessageMentions: Int {
        entries.values.lazy.filter {
            $0.kind == .directMessage || $0.kind == .groupDirectMessage
        }.reduce(0) {
            $0 + mentions(channelID: $1.channelID)
        }
    }

    var totalMentions: Int {
        entries.keys.reduce(0) { $0 + mentions(channelID: $1) }
    }

    func isVisibleAtNewest(_ channelID: ChannelID) -> Bool {
        presentations[channelID]?.canAcknowledge == true
    }

    func isActivelyPresentedAtNewest(_ channelID: ChannelID) -> Bool {
        guard let presentation = presentations[channelID] else { return false }
        return presentation.isPresented
            && presentation.windowIsActive
            && presentation.hasReachedReadBoundary
    }

    func timelineUnreadSummary(
        channelID: ChannelID,
        messages: [Message],
        hasMoreBefore: Bool
    ) -> TimelineUnreadSummary? {
        guard let entry = entries[channelID], entry.isAccessible, entry.isUnread else {
            return nil
        }
        let acknowledged = entry.lastAcknowledgedMessageID
        var lowerBound = messages.startIndex
        var upperBound = messages.endIndex
        if let acknowledged {
            while lowerBound < upperBound {
                let midpoint = lowerBound + (upperBound - lowerBound) / 2
                if messages[midpoint].id <= acknowledged {
                    lowerBound = midpoint + 1
                } else {
                    upperBound = midpoint
                }
            }
        }
        guard lowerBound < messages.endIndex else { return nil }
        let firstUnreadIndex = lowerBound
        let first = messages[firstUnreadIndex]
        let firstLoadedMessageID = messages.first?.id
        let oldestLoadedIsNewerThanAcknowledgement =
            acknowledged.map { acknowledged in
                firstLoadedMessageID.map { $0 > acknowledged } ?? false
            } ?? true
        let isLowerBound = hasMoreBefore && oldestLoadedIsNewerThanAcknowledgement
        return TimelineUnreadSummary(
            firstUnreadMessageID: first.id,
            loadedUnreadCount: messages.distance(
                from: firstUnreadIndex,
                to: messages.endIndex
            ),
            isLowerBound: isLowerBound,
            firstUnreadTimestamp: first.timestamp
        )
    }

    func mentionCountForManualUnread(
        channelID: ChannelID,
        messages: [Message],
        startingAt messageID: MessageID,
        currentUserID: UserID
    ) -> Int {
        guard let entry = entries[channelID] else { return 0 }
        let policy = effectivePolicy(for: entry, now: .now)
        return messages.lazy.filter { message in
            message.id >= messageID
                && message.author.id != currentUserID
                && self.mentionKind(for: message, entry: entry, policy: policy) != .none
        }.count
    }

    private func newestUnacknowledgedMessage(in channelID: ChannelID) -> MessageID? {
        guard let entry = entries[channelID], entry.isAccessible, entry.isUnread else {
            return nil
        }
        return entry.latestKnownMessageID
    }

    func acknowledgementMetadata(
        channelID: ChannelID,
        now: Date = .now
    ) -> AcknowledgementMetadata {
        let entry = entry(for: channelID)
        var flags: UInt64 = entry.guildID == nil ? 0 : 1 << 0
        if channelByID[channelID] == nil, entry.parentID != nil {
            flags |= 1 << 1
        }
        let discordEpoch = Date(timeIntervalSince1970: 1_420_070_400)
        let lastViewed = max(0, Int(now.timeIntervalSince(discordEpoch) / 86_400))
        return AcknowledgementMetadata(flags: flags, lastViewed: lastViewed)
    }

    private func entry(for channelID: ChannelID) -> Entry {
        if let existing = entries[channelID] { return existing }
        let channel = channelByID[channelID]
        return Entry(
            channelID: channelID,
            guildID: channel?.guildID,
            parentID: channel?.categoryID,
            kind: channel?.kind ?? .unknown,
            latestKnownMessageID: channel?.lastMessageID,
            latestUnreadMessageID: channel?.lastMessageID,
            lastAcknowledgedMessageID: nil,
            mentionCount: 0,
            unreadMessageCount: 0,
            pendingAcknowledgementID: nil,
            flags: nil,
            lastViewed: nil,
            threadNotificationSettings: nil,
            isAccessible: true,
            hasAuthoritativeReadState: false
        )
    }

    private func mentionKind(
        for message: Message,
        entry: Entry,
        policy: EffectivePolicy
    ) -> MentionKind {
        guard let currentUserID else { return .none }
        if message.mentionedUsers.contains(where: { $0.id == currentUserID }) {
            return .direct
        }
        if entry.kind == .directMessage || entry.kind == .groupDirectMessage {
            return policy.guildMuted || policy.channelMuted ? .none : .directMessage
        }
        let settings = settingsByGuild[entry.guildID]
        if message.mentionsEveryone, settings?.suppressEveryone != true {
            return .everyone
        }
        if settings?.suppressRoles != true,
           !message.flags.contains(.failedToMentionRoles),
           let guildID = entry.guildID
        {
            let roles = currentUserRoleIDsByGuild[guildID] ?? []
            if !roles.isDisjoint(with: message.mentionedRoleIDs) {
                return .role
            }
        }
        return .none
    }

    private var currentUserID: UserID?

    func setCurrentUserID(_ userID: UserID?) {
        currentUserID = userID
    }

    private struct EffectivePolicy {
        var level: MessageNotificationLevel
        var guildMuted: Bool
        var channelMuted: Bool
        var showsUnread: Bool
        var notifiesNewForumThreads: Bool
    }

    private func allowsNativeNotification(
        for mentionKind: MentionKind,
        policy: EffectivePolicy
    ) -> Bool {
        guard !policy.channelMuted else { return false }
        switch mentionKind {
        case .none:
            return false
        case .directMessage:
            return !policy.guildMuted && policy.level != .nothing
        case .direct, .role:
            return !policy.guildMuted
        case .everyone:
            // Discord's server mute preserves @everyone/@here unless the
            // dedicated suppress-everyone setting removes the mention first.
            return true
        }
    }

    private func effectivePolicy(for entry: Entry, now: Date) -> EffectivePolicy {
        let isDirectMessage =
            entry.kind == .directMessage || entry.kind == .groupDirectMessage
        let guildSettings = settingsByGuild[entry.guildID]
        let directOverride = guildSettings?.channelOverrides.first { $0.channelID == entry.channelID }
        let parentOverride = entry.parentID.flatMap { parentID in
            guildSettings?.channelOverrides.first { $0.channelID == parentID }
        }
        let ancestorOverride =
            entry.parentID
            .flatMap { channelByID[$0]?.categoryID }
            .flatMap { ancestorID in
                guildSettings?.channelOverrides.first { $0.channelID == ancestorID }
            }
        let override = directOverride ?? parentOverride ?? ancestorOverride
        let guildMuted =
            guildSettings?.isMuted == true
            && (guildSettings?.muteConfiguration?.isActive(at: now) ?? true)
        let inheritedChannelMuted =
            override?.isMuted == true
            && (override?.muteConfiguration?.isActive(at: now) ?? true)
        let guildDefault =
            isDirectMessage
            ? .allMessages
            : (entry.guildID.flatMap { defaultNotificationLevelByGuild[$0] }
                ?? .onlyMentions)
        let configuredGuildLevel = guildSettings?.messageNotifications ?? .inherit
        let inherited =
            configuredGuildLevel == .inherit ? guildDefault : configuredGuildLevel
        let inheritedLevel =
            override?.messageNotifications == .inherit || override == nil
            ? inherited
            : override!.messageNotifications
        let threadLevel =
            entry.threadNotificationSettings?.notificationLevel ?? .inherit
        let level =
            threadLevel == .inherit ? inheritedLevel : threadLevel
        let threadMuted =
            entry.threadNotificationSettings?.isMuted == true
            && (entry.threadNotificationSettings?.muteConfiguration?
                .isActive(at: now) ?? true)
        let channelMuted =
            inheritedChannelMuted || threadMuted || threadLevel == .nothing
        let channelFlags = override?.flags ?? 0
        let guildFlags = guildSettings?.flags ?? 0
        let directFlags = directOverride?.flags ?? 0
        let parentFlags = parentOverride?.flags ?? 0
        let channelIsOptedIn =
            directFlags & (1 << 12) != 0
            || parentFlags & (1 << 12) != 0
        let excludedByGuildOptIn =
            !isDirectMessage
            && guildFlags & (1 << 14) != 0
            && !channelIsOptedIn
        let showsUnread =
            if excludedByGuildOptIn {
                false
            } else if !isDirectMessage, !usesNewNotifications {
                true
            } else if channelFlags & (1 << 9) != 0 {
                false
            } else if channelFlags & (1 << 10) != 0 {
                true
            } else if guildFlags & (1 << 12) != 0 {
                false
            } else if guildFlags & (1 << 11) != 0 {
                true
            } else {
                level == .allMessages
            }
        let forumFlags = parentOverride?.flags ?? 0
        let notifiesNewForumThreads =
            if forumFlags & (1 << 14) != 0 {
                true
            } else if forumFlags & (1 << 13) != 0 {
                false
            } else {
                level == .allMessages
            }
        return EffectivePolicy(
            level: level,
            guildMuted: guildMuted,
            channelMuted: channelMuted,
            showsUnread: showsUnread,
            notifiesNewForumThreads: notifiesNewForumThreads
        )
    }

    private func isGuildResourceChannel(_ entry: Entry) -> Bool {
        let resourceFlag: UInt64 = 1 << 7
        if let channel = channelByID[entry.channelID],
           channel.flags & resourceFlag != 0
        {
            return true
        }
        let parentFlags = entry.parentID.flatMap { channelByID[$0] }?.flags ?? 0
        return parentFlags & resourceFlag != 0
    }
}

private func maximum<T: Comparable>(_ lhs: T?, _ rhs: T?) -> T? {
    switch (lhs, rhs) {
    case (.some(let lhs), .some(let rhs)): max(lhs, rhs)
    case (.some(let lhs), .none): lhs
    case (.none, .some(let rhs)): rhs
    case (.none, .none): nil
    }
}
