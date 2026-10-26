import Foundation
import Observation
import SakuraCordModels

@MainActor
@Observable
// Centralize read-state invariants so atomic snapshots and Gateway updates cannot diverge.
final class AccountReadStateModel {
    nonisolated struct InitialState: Sendable {
        var accountID: String?
        var activeJoinedThreadIDs: Set<ChannelID>
        var entries: [ChannelID: Entry]
        var settingsByGuild: [GuildID?: GuildNotificationSettings]
        var overridesByGuildAndChannelID: [GuildID?: [ChannelID: ChannelNotificationOverride]]
        var remoteReadStateOrder: [ChannelID]
        var remoteReadStateOrderIDs: Set<ChannelID>
        var channelByID: [ChannelID: Channel]
        var defaultNotificationLevelByGuild: [GuildID: MessageNotificationLevel]
        var guildJoinedAtByID: [GuildID: Date]
        var forumPostArchivedByID: [ChannelID: Bool]
        var usesNewNotifications: Bool
        var currentUserID: UserID?
    }

    nonisolated struct InitialStateInput: Sendable {
        let accountID: String?
        let guilds: [Guild]
        let channels: [Channel]
        let threads: [MessageThreadSummary]
        let readStates: [ChannelReadState]
        let notificationSettings: [GuildNotificationSettings]
        let usesNewNotifications: Bool
        let currentUserID: UserID
        var activeJoinedThreads: [MessageThreadSummary] = []
    }

    private nonisolated struct InitialStateAssembly {
        var entries: [ChannelID: Entry]
        var channelByID: [ChannelID: Channel]
        var defaultNotificationLevelByGuild: [GuildID: MessageNotificationLevel]
        var remoteReadStateOrder: [ChannelID] = []
        var remoteReadStateOrderIDs: Set<ChannelID> = []
        var forumPostArchivedByID: [ChannelID: Bool] = [:]
    }

    private nonisolated struct NotificationSettingsIndex {
        var settingsByGuild: [GuildID?: GuildNotificationSettings]
        var overridesByGuildAndChannelID:
            [GuildID?: [ChannelID: ChannelNotificationOverride]]
    }

    private(set) var accountID: String?
    @ObservationIgnored private var entriesStorage: [ChannelID: Entry] = [:]
    private(set) var entries: [ChannelID: Entry] {
        get {
            access(keyPath: \.entries)
            return entriesStorage
        }
        set {
            for channelID in Set(entriesStorage.keys).union(newValue.keys) {
                self[channelID] = newValue[channelID]
            }
        }
    }

    private(set) subscript(channelID: ChannelID) -> Entry? {
        get {
            access(keyPath: \.[channelID])
            return entriesStorage[channelID]
        }
        set {
            let previous = entriesStorage[channelID]
            guard previous != newValue else { return }
            if previous?.threadNotificationSettings != newValue?.threadNotificationSettings,
               let settings = newValue?.threadNotificationSettings,
               settings.isMuted, let endTime = settings.muteConfiguration?.endTime,
               endTime > .now {
                nextNotificationPolicyExpiration = min(nextNotificationPolicyExpiration ?? endTime, endTime)
            }
            withMutation(keyPath: \.entries) {
                withMutation(keyPath: \.[channelID]) {
                    if previous?.unreadNavigationState != newValue?.unreadNavigationState {
                        withMutation(keyPath: \.[unread: channelID]) {
                            entriesStorage[channelID] = newValue
                        }
                    } else {
                        entriesStorage[channelID] = newValue
                    }
                }
            }
        }
    }

    subscript(unread channelID: ChannelID) -> UnreadNavigationState? {
        access(keyPath: \.[unread: channelID])
        return entriesStorage[channelID]?.unreadNavigationState
    }
    private(set) var settingsByGuild: [GuildID?: GuildNotificationSettings] = [:] {
        didSet { refreshNextNotificationPolicyExpiration(now: .now) }
    }
    @ObservationIgnored private var nextNotificationPolicyExpiration: Date?
    private var overridesByGuildAndChannelID:
        [GuildID?: [ChannelID: ChannelNotificationOverride]] = [:]
    @ObservationIgnored private var presentationsStorage: [ChannelID: Presentation] = [:]
    private(set) var presentations: [ChannelID: Presentation] {
        get {
            access(keyPath: \.presentations)
            return presentationsStorage
        }
        set {
            for channelID in Set(presentationsStorage.keys).union(newValue.keys) {
                self[presentation: channelID] = newValue[channelID]
            }
        }
    }

    private(set) subscript(presentation channelID: ChannelID) -> Presentation? {
        get {
            access(keyPath: \.[presentation: channelID])
            return presentationsStorage[channelID]
        }
        set {
            guard presentationsStorage[channelID] != newValue else { return }
            withMutation(keyPath: \.presentations) {
                withMutation(keyPath: \.[presentation: channelID]) {
                    presentationsStorage[channelID] = newValue
                }
            }
        }
    }
    private(set) var acknowledgementToken: String?
    private(set) var remoteReadStateOrder: [ChannelID] = []
    private var remoteReadStateOrderIDs: Set<ChannelID> = []
    private(set) var channelByID: [ChannelID: Channel] = [:]
    private var defaultNotificationLevelByGuild: [GuildID: MessageNotificationLevel] = [:]
    private var currentUserRoleIDsByGuild: [GuildID: Set<RoleID>] = [:]
    /// The forum boundary captured when a visit began; zero when the forum
    /// had never been acknowledged, leaving only the join-time check.
    private var forumSelectionAcknowledgementBoundary: [ChannelID: MessageID] = [:]
    private var guildJoinedAtByID: [GuildID: Date] = [:]
    private var activeJoinedThreadIDs: Set<ChannelID> = []
    private var forumPostArchivedByID: [ChannelID: Bool] = [:]
    private var usesNewNotifications = true
    private var currentUserID: UserID?
}

extension AccountReadStateModel {
    var unreadPolicySource: UnreadPolicySource {
        UnreadPolicySource(
            settingsByGuild: settingsByGuild,
            overridesByGuildAndChannelID: overridesByGuildAndChannelID,
            channelByID: channelByID,
            defaultNotificationLevelByGuild: defaultNotificationLevelByGuild,
            usesNewNotifications: usesNewNotifications
        )
    }

    func reset(accountID: String?) {
        self.accountID = accountID
        entries.removeAll()
        settingsByGuild.removeAll()
        overridesByGuildAndChannelID.removeAll()
        presentations.removeAll()
        acknowledgementToken = nil
        remoteReadStateOrder.removeAll()
        remoteReadStateOrderIDs.removeAll()
        channelByID.removeAll()
        defaultNotificationLevelByGuild.removeAll()
        guildJoinedAtByID.removeAll()
        currentUserRoleIDsByGuild.removeAll()
        forumSelectionAcknowledgementBoundary.removeAll()
        forumPostArchivedByID.removeAll()
        activeJoinedThreadIDs.removeAll()
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
            applySnapshot(state)
        }
        seedOmittedReadBoundaries(
            channelIDs: Set(channels.map(\.id)).subtracting(readStates.map(\.channelID))
        )
        for settings in notificationSettings {
            apply(settings)
        }
    }

    /// Returns the conversations READY leaves read that were unread.
    @discardableResult
    func replaceSnapshot(_ snapshot: BootstrapSnapshot) -> Set<ChannelID> {
        retainGuilds(Set(snapshot.guilds.map(\.id)))
        merge(guilds: snapshot.guilds)
        let channelsByGuild = Dictionary(grouping: snapshot.channels, by: \.guildID)
        let guildIDs = Set(channelByID.values.map(\.guildID)).union(channelsByGuild.keys)
        for guildID in guildIDs {
            replaceChannels(in: guildID, with: channelsByGuild[guildID] ?? [])
        }
        settingsByGuild.removeAll(keepingCapacity: true)
        overridesByGuildAndChannelID.removeAll(keepingCapacity: true)
        for settings in snapshot.notificationSettings { apply(settings) }
        usesNewNotifications = snapshot.usesNewNotifications
        currentUserID = snapshot.currentUser.id
        // Discord's CONNECTION_OPEN clears the ACK token and replaces read
        // state; no pending acknowledgement survives READY.
        acknowledgementToken = nil
        let read = replaceReadStates(snapshot.readStates)
        for thread in snapshot.threads + snapshot.activeJoinedThreads { merge(thread: thread) }
        replaceActiveJoinedThreads(snapshot.activeJoinedThreads)
        return read
    }

    nonisolated static func makeInitialState(_ input: InitialStateInput) -> InitialState {
        let accountID = input.accountID
        let guilds = input.guilds
        let channels = input.channels
        let threads = input.threads + input.activeJoinedThreads
        let readStates = input.readStates
        let notificationSettings = input.notificationSettings
        let usesNewNotifications = input.usesNewNotifications
        let currentUserID = input.currentUserID
        var assembly = makeInitialStateAssembly(
            guilds: guilds,
            channels: channels,
            threadCapacity: threads.count
        )

        applyInitialReadStates(readStates, to: &assembly)

        let authoritativeReadStateIDs = Set(readStates.map(\.channelID))
        for channelID in Set(channels.map(\.id)).subtracting(authoritativeReadStateIDs) {
            guard var entry = assembly.entries[channelID],
                  let latestKnownMessageID = entry.latestKnownMessageID
            else { continue }
            entry.lastAcknowledgedMessageID = latestKnownMessageID
            entry.mentionCount = 0
            entry.unreadMessageCount = 0
            assembly.entries[channelID] = entry
        }

        let guildJoinedAtByID = guildJoinedAtByID(guilds)
        applyInitialThreads(threads, guildJoinedAtByID: guildJoinedAtByID, to: &assembly)

        let notificationIndex = initialNotificationSettingsIndex(notificationSettings)
        return InitialState(
            accountID: accountID,
            activeJoinedThreadIDs: Set(input.activeJoinedThreads.filter { !$0.isArchived }.map(\.id)),
            entries: assembly.entries,
            settingsByGuild: notificationIndex.settingsByGuild,
            overridesByGuildAndChannelID: notificationIndex.overridesByGuildAndChannelID,
            remoteReadStateOrder: assembly.remoteReadStateOrder,
            remoteReadStateOrderIDs: assembly.remoteReadStateOrderIDs,
            channelByID: assembly.channelByID,
            defaultNotificationLevelByGuild: assembly.defaultNotificationLevelByGuild,
            guildJoinedAtByID: guildJoinedAtByID,
            forumPostArchivedByID: assembly.forumPostArchivedByID,
            usesNewNotifications: usesNewNotifications,
            currentUserID: currentUserID
        )
    }

    private nonisolated static func makeInitialStateAssembly(
        guilds: [Guild],
        channels: [Channel],
        threadCapacity: Int
    ) -> InitialStateAssembly {
        var channelByID: [ChannelID: Channel] = [:]
        channelByID.reserveCapacity(channels.count)
        var entries: [ChannelID: Entry] = [:]
        entries.reserveCapacity(channels.count + threadCapacity)
        var defaultLevels: [GuildID: MessageNotificationLevel] = [:]
        defaultLevels.reserveCapacity(guilds.count)
        for guild in guilds {
            defaultLevels[guild.id] = guild.defaultMessageNotifications
        }
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
                flags: nil,
                lastViewed: nil,
                threadNotificationSettings: nil,
                isAccessible: true,
                hasAuthoritativeReadState: false
            )
            entry.guildID = channel.guildID
            entry.parentID = channel.categoryID
            entry.kind = channel.kind
            entry.latestKnownMessageID = maximum(
                entry.latestKnownMessageID,
                channel.lastMessageID
            )
            entries[channel.id] = entry
        }
        return InitialStateAssembly(
            entries: entries,
            channelByID: channelByID,
            defaultNotificationLevelByGuild: defaultLevels
        )
    }

    private nonisolated static func applyInitialReadStates(
        _ readStates: [ChannelReadState],
        to assembly: inout InitialStateAssembly
    ) {
        assembly.remoteReadStateOrder.reserveCapacity(readStates.count)
        assembly.remoteReadStateOrderIDs.reserveCapacity(readStates.count)
        for state in readStates {
            if assembly.remoteReadStateOrderIDs.insert(state.channelID).inserted {
                assembly.remoteReadStateOrder.append(state.channelID)
            }
            var entry = assembly.entries[state.channelID]
                ?? initialBaseEntry(for: state.channelID, channels: assembly.channelByID)
            applySnapshot(state, to: &entry)
            assembly.entries[state.channelID] = entry
        }
    }

    /// A READY entry takes the server's boundary and counts directly.
    private nonisolated static func applySnapshot(_ state: ChannelReadState, to entry: inout Entry) {
        entry.lastAcknowledgedMessageID = state.lastAcknowledgedMessageID
        entry.mentionCount = max(0, state.mentionCount)
        entry.flags = state.flags ?? entry.flags
        entry.lastViewed = state.lastViewed ?? entry.lastViewed
        entry.hasAuthoritativeReadState = true
        entry.latestUnreadMessageID = maximum(entry.latestUnreadMessageID, entry.latestKnownMessageID)
        entry.unreadMessageCount = entry.isUnread ? max(1, entry.unreadMessageCount) : 0
    }

    private nonisolated static func applyInitialThreads(
        _ threads: [MessageThreadSummary],
        guildJoinedAtByID: [GuildID: Date],
        to assembly: inout InitialStateAssembly
    ) {
        assembly.forumPostArchivedByID.reserveCapacity(threads.count)
        for thread in threads {
            var entry = assembly.entries[thread.id]
                ?? initialBaseEntry(for: thread.id, channels: assembly.channelByID)
            entry.guildID = thread.guildID
                ?? thread.parentID.flatMap { assembly.channelByID[$0]?.guildID }
            entry.parentID = thread.parentID
            entry.kind = .text
            if let settings = thread.notificationSettings {
                entry.threadNotificationSettings = settings
            }
            entry.latestKnownMessageID = maximum(entry.latestKnownMessageID, thread.lastMessageID)
            updateThreadUnread(
                thread,
                entry: &entry,
                isForumPost: thread.parentID.flatMap { assembly.channelByID[$0] }?.kind == .forum,
                guildJoinedAt: entry.guildID.flatMap { guildJoinedAtByID[$0] }
            )
            if let parentID = thread.parentID, let parent = assembly.entries[parentID] {
                entry.isAccessible = parent.isAccessible
            }
            assembly.entries[thread.id] = entry
            assembly.forumPostArchivedByID[thread.id] = thread.isArchived
            updateInitialForumParent(thread, in: &assembly)
        }
    }

    /// A thread without a saved acknowledgement (or READY's `0`) is read up to
    /// Discord's fallback boundary, so its newer messages are unread.
    private nonisolated static func updateThreadUnread(
        _ thread: MessageThreadSummary,
        entry: inout Entry,
        isForumPost: Bool,
        guildJoinedAt: Date?
    ) {
        if entry.lastAcknowledgedMessageID.map({ $0.rawValue == 0 }) ?? true {
            entry.lastAcknowledgedMessageID = fallbackAcknowledgedMessageID(
                for: thread, isForumPost: isForumPost, guildJoinedAt: guildJoinedAt
            )
        }
        entry.latestUnreadMessageID = maximum(entry.latestUnreadMessageID, thread.lastMessageID)
        entry.unreadMessageCount = entry.isUnread ? max(1, entry.unreadMessageCount) : 0
    }

    /// Discord's `ReadStateStore` fallback (build 649389): the later of joining
    /// the thread less five seconds and its archive time less a millisecond,
    /// else its creation less a millisecond. A text thread's boundary is never
    /// before the account joined the server, or now when that is unknown.
    /// Discord compares milliseconds, so the result is that millisecond's last
    /// snowflake.
    nonisolated static func fallbackAcknowledgedMessageID(
        for thread: MessageThreadSummary,
        isForumPost: Bool,
        guildJoinedAt: Date?,
        now: Date = .now
    ) -> MessageID {
        func milliseconds(_ date: Date) -> Int { Int(MessageID(timestamp: date).rawValue >> 22) }
        let joined = thread.notificationSettings?.joinedAt.map { milliseconds($0) - 5_000 } ?? -5_000
        let archived = thread.archiveTimestamp.map { milliseconds($0) - 1 } ?? 0
        var boundary = max(joined, archived)
        if boundary <= 0 { boundary = Int(thread.id.rawValue >> 22) - 1 }
        if !isForumPost { boundary = max(boundary, milliseconds(guildJoinedAt ?? now)) }
        return MessageID(rawValue: UInt64(max(boundary, 0) + 1) << 22 - 1)
    }

    private nonisolated static func updateInitialForumParent(
        _ thread: MessageThreadSummary,
        in assembly: inout InitialStateAssembly
    ) {
        guard let parentID = thread.parentID,
              var parent = assembly.entries[parentID],
              parent.kind == .forum
        else { return }
        let threadMessageID = MessageID(rawValue: thread.id.rawValue)
        parent.latestKnownMessageID = maximum(parent.latestKnownMessageID, threadMessageID)
        if parent.hasAuthoritativeReadState {
            parent.latestUnreadMessageID = maximum(
                parent.latestUnreadMessageID,
                threadMessageID
            )
            parent.unreadMessageCount = parent.isUnread
                ? max(1, parent.unreadMessageCount)
                : 0
        }
        assembly.entries[parentID] = parent
    }

    private nonisolated static func initialBaseEntry(
        for channelID: ChannelID,
        channels: [ChannelID: Channel]
    ) -> Entry {
        let channel = channels[channelID]
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
            flags: nil,
            lastViewed: nil,
            threadNotificationSettings: nil,
            isAccessible: true,
            hasAuthoritativeReadState: false
        )
    }

    private nonisolated static func initialNotificationSettingsIndex(
        _ settings: [GuildNotificationSettings]
    ) -> NotificationSettingsIndex {
        var settingsByGuild: [GuildID?: GuildNotificationSettings] = [:]
        var overridesByGuildAndChannelID:
            [GuildID?: [ChannelID: ChannelNotificationOverride]] = [:]
        for guildSettings in settings {
            settingsByGuild[guildSettings.guildID] = guildSettings
            var overrides: [ChannelID: ChannelNotificationOverride] = [:]
            overrides.reserveCapacity(guildSettings.channelOverrides.count)
            for override in guildSettings.channelOverrides {
                overrides[override.channelID] = override
            }
            overridesByGuildAndChannelID[guildSettings.guildID] = overrides
        }
        return NotificationSettingsIndex(
            settingsByGuild: settingsByGuild,
            overridesByGuildAndChannelID: overridesByGuildAndChannelID
        )
    }

    func applyInitialState(_ state: InitialState) {
        activeJoinedThreadIDs = state.activeJoinedThreadIDs
        accountID = state.accountID
        entries = state.entries
        settingsByGuild = state.settingsByGuild
        overridesByGuildAndChannelID = state.overridesByGuildAndChannelID
        presentations = [:]
        acknowledgementToken = nil
        remoteReadStateOrder = state.remoteReadStateOrder
        remoteReadStateOrderIDs = state.remoteReadStateOrderIDs
        channelByID = state.channelByID
        defaultNotificationLevelByGuild = state.defaultNotificationLevelByGuild
        guildJoinedAtByID = state.guildJoinedAtByID
        currentUserRoleIDsByGuild = [:]
        forumSelectionAcknowledgementBoundary = [:]
        forumPostArchivedByID = state.forumPostArchivedByID
        usesNewNotifications = state.usesNewNotifications
        currentUserID = state.currentUserID
    }

    func merge(guilds: [Guild]) {
        for guild in guilds {
            defaultNotificationLevelByGuild[guild.id] = guild.defaultMessageNotifications
        }
        guildJoinedAtByID.merge(Self.guildJoinedAtByID(guilds)) { $1 }
    }

    private nonisolated static func guildJoinedAtByID(_ guilds: [Guild]) -> [GuildID: Date] {
        Dictionary(
            guilds.compactMap { guild in guild.joinedAt.map { (guild.id, $0) } },
            uniquingKeysWith: { $1 }
        )
    }

    func updateNotificationMode(usesNewNotifications: Bool) {
        self.usesNewNotifications = usesNewNotifications
    }

    func merge(channels: [Channel]) {
        for channel in channels {
            channelByID[channel.id] = channel
            var entry = self[channel.id] ?? Entry(
                channelID: channel.id,
                guildID: channel.guildID,
                parentID: channel.categoryID,
                kind: channel.kind,
                latestKnownMessageID: nil,
                latestUnreadMessageID: nil,
                lastAcknowledgedMessageID: nil,
                mentionCount: 0,
                unreadMessageCount: 0,
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
            self[channel.id] = entry
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
            self[channelID] = nil
            self[presentation: channelID] = nil
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
            self[channelID] = nil
            self[presentation: channelID] = nil
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
            self[channelID] = nil
            self[presentation: channelID] = nil
            channelByID[channelID] = nil
            forumSelectionAcknowledgementBoundary[channelID] = nil
            forumPostArchivedByID[channelID] = nil
        }
        settingsByGuild = settingsByGuild.filter { guildID, _ in
            guard let guildID else { return true }
            return guildIDs.contains(guildID)
        }
        overridesByGuildAndChannelID = overridesByGuildAndChannelID.filter { guildID, _ in
            guard let guildID else { return true }
            return guildIDs.contains(guildID)
        }
        defaultNotificationLevelByGuild = defaultNotificationLevelByGuild.filter {
            guildIDs.contains($0.key)
        }
        guildJoinedAtByID = guildJoinedAtByID.filter { guildIDs.contains($0.key) }
        currentUserRoleIDsByGuild = currentUserRoleIDsByGuild.filter {
            guildIDs.contains($0.key)
        }
    }

    func apply(_ settings: GuildNotificationSettings) {
        settingsByGuild[settings.guildID] = settings
        var overrides: [ChannelID: ChannelNotificationOverride] = [:]
        overrides.reserveCapacity(settings.channelOverrides.count)
        for override in settings.channelOverrides {
            overrides[override.channelID] = override
        }
        overridesByGuildAndChannelID[settings.guildID] = overrides
    }

    func notificationSettings(guildID: GuildID?) -> GuildNotificationSettings? {
        settingsByGuild[guildID]
    }

    func notificationOverride(
        channelID: ChannelID,
        guildID: GuildID?
    ) -> ChannelNotificationOverride? {
        overridesByGuildAndChannelID[guildID]?[channelID]
    }

    func isChannelMuted(_ channel: Channel, at date: Date = .now) -> Bool {
        guard !channel.isMuted else { return true }
        let directOverride = notificationOverride(
            channelID: channel.id,
            guildID: channel.guildID
        )
        guard let override = directOverride else {
            return false
        }
        return override.isMuted
            && (override.muteConfiguration?.isActive(at: date) ?? true)
    }

    func inheritedNotificationLevel(for channel: Channel) -> MessageNotificationLevel {
        let guildSettings = settingsByGuild[channel.guildID]
        let parentOverride = channel.categoryID.flatMap { parentID in
            notificationOverride(channelID: parentID, guildID: channel.guildID)
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
    /// A channel present in `resolved` keeps its value; absent entries inherit a
    /// resolved parent. This account-wide refresh uses fixed passes rather than
    /// rescanning per channel, and publishes only when observable entries change.
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

    private func recordRemoteReadState(_ channelID: ChannelID) {
        if remoteReadStateOrderIDs.insert(channelID).inserted {
            remoteReadStateOrder.append(channelID)
        }
    }

    private func applySnapshot(_ state: ChannelReadState) {
        recordRemoteReadState(state.channelID)
        var entry = entry(for: state.channelID)
        Self.applySnapshot(state, to: &entry)
        self[state.channelID] = entry
    }

    /// Discord's `MESSAGE_ACK` (build 649389), applied in received order with
    /// no version or boundary comparison. A manual event always rebuilds at
    /// its boundary with its mention count. An ordinary one at the current
    /// boundary is ignored; any other acknowledges there locally.
    @discardableResult
    func applyRemote(_ state: ChannelReadState) -> Bool {
        recordRemoteReadState(state.channelID)
        guard state.isManual else {
            guard state.lastAcknowledgedMessageID != self[state.channelID]?.lastAcknowledgedMessageID,
                  let messageID = state.lastAcknowledgedMessageID ?? self[state.channelID]?.latestKnownMessageID
            else { return false }
            acknowledge(channelID: state.channelID, messageID: messageID)
            return true
        }
        var entry = entry(for: state.channelID)
        entry.lastAcknowledgedMessageID = state.lastAcknowledgedMessageID ?? entry.lastAcknowledgedMessageID
        entry.mentionCount = max(0, state.mentionCount)
        entry.hasAuthoritativeReadState = true
        entry.latestUnreadMessageID = maximum(entry.latestUnreadMessageID, entry.latestKnownMessageID)
        entry.unreadMessageCount = entry.isUnread ? max(1, entry.unreadMessageCount) : 0
        self[state.channelID] = entry
        return true
    }

    /// A full READY replaces every read state, keeping only what the account
    /// knows about each conversation's channel and messages. Returns the
    /// conversations it leaves read that were unread.
    @discardableResult
    func replaceReadStates(_ states: [ChannelReadState]) -> Set<ChannelID> {
        let previousEntries = entries
        remoteReadStateOrder.removeAll(keepingCapacity: true)
        remoteReadStateOrderIDs.removeAll(keepingCapacity: true)
        entries.removeAll(keepingCapacity: true)
        merge(channels: Array(channelByID.values))
        for state in states { applySnapshot(state) }
        for channelID in Array(entries.keys) {
            guard let previous = previousEntries[channelID] else { continue }
            self[channelID] = reconciledSnapshotEntry(channelID: channelID, previous: previous)
        }
        return Set(previousEntries.values.lazy
            .filter { $0.isUnread && self[$0.channelID]?.isUnread == false }
            .map(\.channelID))
    }

    func quickSwitcherMentionChannelIDs(
        mentionsByChannelID mentionCounts: [ChannelID: Int]
    ) -> [ChannelID] {
        var seen: Set<ChannelID> = []
        let ordered = remoteReadStateOrder + entries.keys.filter {
            !remoteReadStateOrderIDs.contains($0)
        }
        // ReadStateStore insertion order follows CONNECTION_OPEN and later mention
        // transitions. QuickSwitcherStore reverses it; snowflake sorting differs.
        return ordered.filter {
            seen.insert($0).inserted && mentionCounts[$0, default: 0] > 0
        }
    }

    /// Produces only local quick-switcher read state. Full sidebar guild aggregates,
    /// forum counters, and notification policies are irrelevant and expensive here.
    func quickSwitcherProjection() -> QuickSwitcherProjection {
        var unreadChannelIDs = Set<ChannelID>()
        var mutedChannelIDs = Set<ChannelID>()
        var mentionsByChannelID: [ChannelID: Int] = [:]
        let now = Date.now
        var mutedGuildIDs = Set<GuildID>()
        var mutedOverrideIDs = Set<ChannelID>()
        for (guildID, settings) in settingsByGuild {
            if let guildID,
               settings.isMuted,
               settings.muteConfiguration?.isActive(at: now) ?? true
            {
                mutedGuildIDs.insert(guildID)
            }
            for override in settings.channelOverrides
                where override.isMuted
                    && (override.muteConfiguration?.isActive(at: now) ?? true)
            {
                mutedOverrideIDs.insert(override.channelID)
            }
        }
        unreadChannelIDs.reserveCapacity(entries.count)
        mutedChannelIDs.reserveCapacity(entries.count)
        mentionsByChannelID.reserveCapacity(entries.count)
        for entry in entries.values where entry.isAccessible {
            guard !isGuildResourceChannel(entry) else { continue }
            if entry.isUnread {
                if usesAllMessagesUnreadSetting(for: entry) {
                    unreadChannelIDs.insert(entry.channelID)
                }
                let ancestorID = entry.parentID.flatMap { channelByID[$0]?.categoryID }
                let threadMuted = entry.threadNotificationSettings.map {
                    ($0.isMuted
                        && ($0.muteConfiguration?.isActive(at: now) ?? true))
                        || $0.notificationLevel == .nothing
                } ?? false
                if entry.guildID.map(mutedGuildIDs.contains) == true
                    || mutedOverrideIDs.contains(entry.channelID)
                    || entry.parentID.map(mutedOverrideIDs.contains) == true
                    || ancestorID.map(mutedOverrideIDs.contains) == true
                    || threadMuted
                    || channelByID[entry.channelID]?.isMuted == true
                {
                    mutedChannelIDs.insert(entry.channelID)
                }
            }
            if entry.mentionCount > 0, countsMentions(entry) {
                mentionsByChannelID[entry.channelID] = entry.mentionCount
            }
        }
        return QuickSwitcherProjection(
            unreadChannelIDs: unreadChannelIDs,
            mutedChannelIDs: mutedChannelIDs,
            mentionsByChannelID: mentionsByChannelID,
            mentionedChannelIDs: quickSwitcherMentionChannelIDs(
                mentionsByChannelID: mentionsByChannelID
            )
        )
    }

    /// Mirrors Discord's `resolveUnreadSetting(channel) === ALL_MESSAGES`, which
    /// gates quick-switcher unread candidates and a forum's new-post count.
    func usesAllMessagesUnreadSetting(
        for entry: Entry
    ) -> Bool {
        let isDirectMessage =
            entry.kind == .directMessage || entry.kind == .groupDirectMessage
        let isThread = channelByID[entry.channelID] == nil && entry.parentID != nil
        if isDirectMessage || isThread || !usesNewNotifications {
            return true
        }

        let guildSettings = settingsByGuild[entry.guildID]
        let directOverride = notificationOverride(
            channelID: entry.channelID,
            guildID: entry.guildID
        )
        let parentOverride = entry.parentID.flatMap { parentID in
            notificationOverride(channelID: parentID, guildID: entry.guildID)
        }

        let unreadAllMessagesFlag: UInt64 = 1 << 10
        let unreadOnlyMentionsFlag: UInt64 = 1 << 9
        func unreadSetting(flags: UInt64) -> Bool? {
            if flags & unreadAllMessagesFlag != 0 { return true }
            if flags & unreadOnlyMentionsFlag != 0 { return false }
            return nil
        }

        if let setting = unreadSetting(flags: directOverride?.flags ?? 0) {
            return setting
        }
        if let setting = unreadSetting(flags: parentOverride?.flags ?? 0) {
            return setting
        }

        let guildUnreadAllMessagesFlag: UInt64 = 1 << 11
        let guildUnreadOnlyMentionsFlag: UInt64 = 1 << 12
        let guildFlags = guildSettings?.flags ?? 0
        if guildFlags & guildUnreadAllMessagesFlag != 0 { return true }
        if guildFlags & guildUnreadOnlyMentionsFlag != 0 { return false }

        let directLevel = directOverride?.messageNotifications ?? .inherit
        if directLevel != .inherit { return directLevel == .allMessages }
        let parentLevel = parentOverride?.messageNotifications ?? .inherit
        if parentLevel != .inherit { return parentLevel == .allMessages }
        let guildLevel = guildSettings?.messageNotifications ?? .inherit
        if guildLevel != .inherit { return guildLevel == .allMessages }
        let defaultLevel = entry.guildID.flatMap {
            defaultNotificationLevelByGuild[$0]
        } ?? .onlyMentions
        return defaultLevel == .allMessages
    }

    private func reconciledSnapshotEntry(channelID: ChannelID, previous: Entry) -> Entry {
        var value = entry(for: channelID)
        value.latestKnownMessageID = maximum(
            value.latestKnownMessageID, previous.latestKnownMessageID
        )
        value.guildID = value.guildID ?? previous.guildID
        value.parentID = value.parentID ?? previous.parentID
        if channelByID[channelID] == nil { value.kind = previous.kind }
        value.isAccessible = previous.isAccessible
        if value.hasAuthoritativeReadState {
            value.latestUnreadMessageID = maximum(
                value.latestUnreadMessageID, previous.latestKnownMessageID
            )
            value.unreadMessageCount = value.isUnread
                ? max(max(value.unreadMessageCount, previous.unreadMessageCount), 1)
                : 0
        } else if let latestKnownMessageID = value.latestKnownMessageID {
            value.lastAcknowledgedMessageID = latestKnownMessageID
            value.mentionCount = 0
            value.unreadMessageCount = 0
        }
        return value
    }

    func observeLoadedMessages(channelID: ChannelID, messages: [Message]) {
        // Local sends and interaction notices carry placeholder IDs counting
        // down from UInt64.max. Observing one would raise the boundary past
        // every real message, so the conversation could never be acknowledged
        // or count new messages. Ephemeral rows never move read state.
        guard let newest = messages.lazy
            .filter({ $0.outboxState == .confirmed && !$0.flags.contains(.ephemeral) })
            .max(by: { $0.id < $1.id })
        else { return }
        var entry = entry(for: channelID)
        entry.latestKnownMessageID = maximum(entry.latestKnownMessageID, newest.id)
        if entry.hasAuthoritativeReadState {
            entry.latestUnreadMessageID = maximum(entry.latestUnreadMessageID, newest.id)
            entry.unreadMessageCount = entry.isUnread
                ? max(1, entry.unreadMessageCount)
                : 0
        }
        self[channelID] = entry
    }

    func receive(
        _ message: Message,
        currentUserID: UserID,
        now: Date = .now
    ) -> MessageDisposition {
        let previous = entriesStorage[message.channelID]
        var entry = entry(for: message.channelID)
        guard entry.isAccessible else {
            return MessageDisposition(accepted: false, mentionKind: .none, shouldNotify: false)
        }
        if entry.guildID == nil { entry.guildID = message.guildID }
        if let latest = entry.latestKnownMessageID, message.id <= latest {
            return MessageDisposition(accepted: false, mentionKind: .none, shouldNotify: false)
        }
        entry.latestKnownMessageID = message.id

        // Discord acknowledges the account's own message locally, except a
        // poll result, which can mention it (build 649389).
        if message.author.id == currentUserID, message.type != .pollResult {
            self[message.channelID] = entry
            acknowledge(channelID: message.channelID, messageID: message.id)
            return MessageDisposition(
                accepted: true, mentionKind: .none, shouldNotify: false,
                requiresUnreadPresentationRefresh: requiresUnreadPresentationRefresh(
                    previous: previous, current: self[message.channelID] ?? entry, now: now
                ),
                acknowledgesOwnMessage: true
            )
        }

        entry.latestUnreadMessageID = maximum(entry.latestUnreadMessageID, message.id)
        entry.unreadMessageCount += 1
        let policy = effectivePolicy(for: entry, now: now)
        let mentionKind = mentionKind(for: message, entry: entry, policy: policy)
        if mentionKind != .none {
            // A real mention promotes any retained low-importance count.
            // Discord clears this flag before incrementing its mention count.
            if let flags = entry.flags { entry.flags = flags & ~UInt64(4) }
            if entry.mentionCount == 0 {
                // MentionStore appends newly mentioned channels. The quick switcher
                // reverses that order, independent of read-state creation time.
                remoteReadStateOrder.removeAll { $0 == message.channelID }
                remoteReadStateOrder.append(message.channelID)
                remoteReadStateOrderIDs.insert(message.channelID)
            }
            entry.mentionCount += 1
        }
        self[message.channelID] = entry

        let isMention = mentionKind != .none
        let createsForumThread =
            message.isPostStarter
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
            shouldNotify: shouldNotify,
            requiresUnreadPresentationRefresh: requiresUnreadPresentationRefresh(
                previous: previous, current: entry, now: now
            )
        )
    }

    private func requiresUnreadPresentationRefresh(previous: Entry?, current: Entry, now: Date) -> Bool {
        let policyExpired = nextNotificationPolicyExpiration.map { $0 <= now } ?? false
        if policyExpired { refreshNextNotificationPolicyExpiration(now: now) }
        return policyExpired
            || previous?.unreadNavigationState != current.unreadNavigationState
            || previous?.mentionCount != current.mentionCount
            || (current.kind == .forum && previous?.lastAcknowledgedMessageID != current.lastAcknowledgedMessageID)
    }

    private func refreshNextNotificationPolicyExpiration(now: Date) {
        let guildExpirations = settingsByGuild.values.flatMap { settings in
            (settings.isMuted ? [settings.muteConfiguration?.endTime] : [])
                + settings.channelOverrides.filter(\.isMuted).map { $0.muteConfiguration?.endTime }
        }
        let threadExpirations = entriesStorage.values.compactMap { entry -> Date? in
            guard let settings = entry.threadNotificationSettings, settings.isMuted else { return nil }
            return settings.muteConfiguration?.endTime
        }
        nextNotificationPolicyExpiration = (guildExpirations.compactMap { $0 } + threadExpirations)
            .filter { $0 > now }.min()
    }

    func replaceActiveJoinedThreads(_ threads: [MessageThreadSummary]) {
        activeJoinedThreadIDs = Set(threads.filter { !$0.isArchived }.map(\.id))
        for thread in threads { merge(thread: thread) }
    }

    func merge(thread: MessageThreadSummary) {
        var entry = entry(for: thread.id)
        entry.guildID = thread.guildID
            ?? thread.parentID.flatMap { channelByID[$0]?.guildID }
        entry.parentID = thread.parentID
        entry.kind = .text
        if let settings = thread.notificationSettings {
            entry.threadNotificationSettings = settings
        }
        entry.latestKnownMessageID = maximum(entry.latestKnownMessageID, thread.lastMessageID)
        Self.updateThreadUnread(
            thread,
            entry: &entry,
            isForumPost: thread.parentID.flatMap { channelByID[$0] }?.kind == .forum,
            guildJoinedAt: entry.guildID.flatMap { guildJoinedAtByID[$0] }
        )
        if let parentID = thread.parentID, let parent = self[parentID] {
            entry.isAccessible = parent.isAccessible
        }
        self[thread.id] = entry
        forumPostArchivedByID[thread.id] = thread.isArchived

        guard let parentID = thread.parentID,
              var parent = self[parentID],
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
        self[parentID] = parent
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
        entry.latestKnownMessageID = maximum(entry.latestKnownMessageID, latestMessageID)
        entry.latestUnreadMessageID = maximum(entry.latestUnreadMessageID, latestMessageID)
        let starterID = forumPost.firstMessage?.id ?? MessageID(rawValue: forumPost.id.rawValue)
        let allRepliesAreAfterAcknowledgement = entry.lastAcknowledgedMessageID.map { $0 <= starterID } ?? true
        let catalogueUnreadCount =
            allRepliesAreAfterAcknowledgement ? max(1, forumPost.replyCount) : 1
        entry.unreadMessageCount = max(catalogueUnreadCount, entry.unreadMessageCount)
        self[forumPost.id] = entry
    }

    /// Captures Discord's forum-selection read boundary before the parent
    /// acknowledgement advances. Post-level unread state remains independent.
    func beginForumVisit(channelID: ChannelID) {
        guard let forum = self[channelID], forum.kind == .forum else { return }
        forumSelectionAcknowledgementBoundary[channelID] =
            forum.trackedAcknowledgedMessageID ?? MessageID(rawValue: 0)
    }

    /// Returns whether a visit ended, which moves the forum's new-post count
    /// back from the visit boundary to its acknowledgement.
    func endForumVisit(channelID: ChannelID) -> Bool {
        forumSelectionAcknowledgementBoundary.removeValue(forKey: channelID) != nil
    }

    func isNewForumPost(_ post: ForumPost) -> Bool {
        guard !post.thread.isArchived,
              self[post.id]?.hasAuthoritativeReadState != true,
              self[presentation: post.id] == nil,
              let parent = post.thread.parentID.flatMap({ self[$0] }),
              parent.kind == .forum
        else { return false }
        return Self.isNewForumPost(
            post.id,
            in: parent,
            visitBoundary: forumSelectionAcknowledgementBoundary[parent.channelID],
            guildJoinedAt: parent.guildID.flatMap { guildJoinedAtByID[$0] }
        )
    }

    /// Discord's rule for an unopened post in a forum. During a visit it is
    /// `isNewForumThread`: past the boundary captured on selection and created
    /// after the user joined the guild. Otherwise it is the sidebar count's
    /// rule: past the forum's acknowledgement, or the join time if the forum
    /// was never acknowledged. An unknown join time counts as now.
    nonisolated static func isNewForumPost(
        _ postID: ChannelID,
        in forum: Entry,
        visitBoundary: MessageID?,
        guildJoinedAt: Date?
    ) -> Bool {
        let joinedAt = guildJoinedAt ?? .now
        if let visitBoundary {
            return MessageID(rawValue: postID.rawValue) > visitBoundary
                && postID.createdAt > joinedAt
        }
        guard let acknowledged = forum.trackedAcknowledgedMessageID else {
            return postID.createdAt > joinedAt
        }
        return MessageID(rawValue: postID.rawValue) > acknowledged
    }

    /// Discord's `isForumPostUnread`, which emphasizes a post's card and
    /// enables its Mark as Read: an active post past its read boundary,
    /// joined or not. `nil` when the channel is not a forum post.
    func isForumPostUnread(channelID: ChannelID) -> Bool? {
        guard let entry = self[channelID],
              entry.parentID.flatMap({ self[$0] })?.kind == .forum
        else { return nil }
        return forumPostArchivedByID[channelID] != true && entry.isUnread
    }

    func forumNewPostCount(channelID: ChannelID) -> Int {
        let source = unreadPresentationSource()
        return entries.values.lazy.filter { entry in
            entry.isAccessible
                && !self.isGuildResourceChannel(entry)
                && source.newForumPostParentID(of: entry) == channelID
        }.count
    }

    /// Discord's forum unread count, which alone enables a forum's own Mark as
    /// Read: active posts whose newest message is past the forum's tracked
    /// acknowledgement and that are unread. A joined post must also be unmuted
    /// unless mentioned. A never-acknowledged forum has none, whatever its
    /// new-post count.
    func hasUnreadForumPosts(channelID: ChannelID, now: Date = .now) -> Bool {
        guard let forum = self[channelID], forum.kind == .forum,
              let acknowledged = forum.trackedAcknowledgedMessageID
        else { return false }
        return entries.values.contains { entry in
            guard entry.parentID == channelID,
                  forumPostArchivedByID[entry.channelID] != true,
                  let latest = entry.latestKnownMessageID, latest > acknowledged
            else { return false }
            guard activeJoinedThreadIDs.contains(entry.channelID) else { return entry.isUnread }
            let settings = entry.threadNotificationSettings
            let isMuted = settings?.isMuted == true
                && (settings?.muteConfiguration?.isActive(at: now) ?? true)
            return entry.mentionCount > 0 || (entry.isUnread && !isMuted)
        }
    }

    func shouldAcknowledgeForumVisit(channelID: ChannelID) -> Bool {
        guard let entry = self[channelID], entry.kind == .forum else { return false }
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
        var value = self[presentation: channelID] ?? Presentation()
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
            value.heldThroughMessageID = blocksAutomaticAcknowledgement
                ? self[channelID]?.latestKnownMessageID ?? MessageID(rawValue: 0)
                : nil
            value.isHeldUntilSelectionChange = false
        }
        self[presentation: channelID] = value
        return canAcknowledge(channelID) ? newestUnacknowledgedMessage(in: channelID) : nil
    }

    func canAcknowledge(_ channelID: ChannelID) -> Bool {
        self[presentation: channelID]?.meetsViewingConditions == true
            && !holdsAutomaticAcknowledgement(channelID)
    }

    func holdsAutomaticAcknowledgement(_ channelID: ChannelID) -> Bool {
        guard let held = self[presentation: channelID]?.heldThroughMessageID else { return false }
        guard let acknowledged = self[channelID]?.lastAcknowledgedMessageID else { return true }
        return acknowledged < held
    }

    /// Discord's `ack()` (E2): the boundary and counts change immediately and
    /// never roll back, whether or not Discord accepts the request. Like any
    /// acknowledgement, it may move the boundary backwards, and it ends Mark
    /// Unread's hold at any boundary.
    func acknowledge(channelID: ChannelID, messageID: MessageID) {
        var entry = entry(for: channelID)
        entry.lastAcknowledgedMessageID = messageID
        entry.mentionCount = 0
        entry.unreadMessageCount = entry.isUnread ? max(1, entry.unreadMessageCount) : 0
        entry.hasAuthoritativeReadState = true
        self[channelID] = entry
        if self[presentation: channelID]?.isHeldUntilSelectionChange == true {
            _ = unblockAutomaticAcknowledgement(channelID: channelID)
        }
    }

    /// Discord's manual MESSAGE_ACK stops a selected conversation from
    /// acknowledging automatically until the selection changes or it is read.
    func holdUntilSelectionChange(channelID: ChannelID) {
        _ = updatePresentation(
            channelID: channelID,
            hasReachedReadBoundary: false,
            blocksAutomaticAcknowledgement: true
        )
        self[presentation: channelID]?.isHeldUntilSelectionChange = true
    }

    @discardableResult
    func unblockAutomaticAcknowledgement(channelID: ChannelID) -> MessageID? {
        updatePresentation(
            channelID: channelID,
            blocksAutomaticAcknowledgement: false
        )
    }

    /// A completed request only chains its token, and not past a newer one
    /// or a READY that cleared it while the request was in flight.
    func completeAcknowledgement(token: String?, sentWith sentToken: String?) {
        guard let token, acknowledgementToken == sentToken else { return }
        acknowledgementToken = token
    }

    private func seedOmittedReadBoundaries(channelIDs: Set<ChannelID>) {
        for channelID in channelIDs {
            var value = entry(for: channelID)
            guard let latestKnownMessageID = value.latestKnownMessageID else { continue }
            value.lastAcknowledgedMessageID = latestKnownMessageID
            value.mentionCount = 0
            value.unreadMessageCount = 0
            self[channelID] = value
        }
    }

    func hasUnreadServerConversations(in guildIDs: Set<GuildID>) -> Bool {
        let source = UnreadPresentationSource(
            entries: entriesStorage,
            activeJoinedThreadIDs: activeJoinedThreadIDs,
            policy: unreadPolicySource,
            forumPostArchivedByID: forumPostArchivedByID,
            forumVisitBoundaryByID: forumSelectionAcknowledgementBoundary,
            guildJoinedAtByID: guildJoinedAtByID
        )
        let forumsWithNewPosts = source.forumsWithNewPosts()
        let channelIDs = Set(channelByID.values.filter {
            $0.guildID.map { guildIDs.contains($0) } == true
        }.map(\.id)).union(activeJoinedThreadIDs)
        return channelIDs.contains { channelID in
            guard let state = self[unread: channelID],
                  let guildID = state.guildID, guildIDs.contains(guildID),
                  state.isAccessible,
                  state.isUnread || forumsWithNewPosts.contains(channelID),
                  let entry = entriesStorage[channelID]
            else { return false }
            if channelByID[channelID] == nil, let parentID = state.parentID {
                _ = self[unread: parentID]
            }
            return serverAcknowledgement(
                for: entry, guildIDs: guildIDs, source: source
            ) != nil
        }
    }

    /// Whether a thread is one the sidebar can surface: an active thread the
    /// account has joined, under a parent that lists threads. Retained read
    /// history is not membership.
    nonisolated static func isListedThread(
        _ entry: Entry,
        parentChannel: Channel?,
        parentEntry: Entry?,
        isActiveJoined: Bool
    ) -> Bool {
        guard isActiveJoined,
              let parentChannel,
              SidebarThreadPolicy.listsThreads(under: parentChannel.kind),
              parentEntry?.isAccessible == true,
              let guildID = parentChannel.guildID,
              entry.guildID == guildID
        else { return false }
        return true
    }

    /// Discord's `ReadState.canHaveMentions`: a thread's mention count stays
    /// hidden until the account has joined the active thread. The raw count is
    /// still tracked, so it surfaces if a later mention or role ping joins it.
    /// Membership comes only from the active joined catalogue (which already
    /// excludes archived threads), so a stale archive flag from a delayed
    /// catalogue response cannot hide a joined thread's badge.
    func countsMentions(_ entry: Entry) -> Bool {
        guard channelByID[entry.channelID] == nil, entry.guildID != nil else { return true }
        return Self.isListedThread(
            entry,
            parentChannel: entry.parentID.flatMap { channelByID[$0] },
            parentEntry: entry.parentID.flatMap { self[$0] },
            isActiveJoined: activeJoinedThreadIDs.contains(entry.channelID)
        )
    }

    func presentedMentionCount(_ entry: Entry) -> Int {
        entry.mentionCount > 0 && countsMentions(entry) ? entry.mentionCount : 0
    }

    func unread(channelID: ChannelID, now: Date = .now) -> Bool {
        _ = self[unread: channelID]
        // Discord's `canBeUnread` shares the joined-thread rule of mentions.
        guard let entry = entriesStorage[channelID], entry.isAccessible, entry.isUnread,
              countsMentions(entry)
        else { return false }
        guard !isGuildResourceChannel(entry) else { return false }
        if entry.kind == .voice, entry.mentionCount == 0 {
            return false
        }
        return unreadPolicySource.presentsUnread(
            entry,
            mentionCount: entry.mentionCount,
            effectivePolicy: effectivePolicy(for: entry, now: now)
        )
    }

    func mentions(channelID: ChannelID) -> Int {
        guard let entry = self[channelID],
              entry.isAccessible,
              !isGuildResourceChannel(entry)
        else { return 0 }
        return presentedMentionCount(entry)
    }

    func unreadMessageCount(channelID: ChannelID) -> Int {
        guard let entry = self[channelID], entry.isAccessible, entry.isUnread else {
            return 0
        }
        return max(1, entry.unreadMessageCount)
    }

    /// Produces all sidebar unread values in linear passes. Scalar helpers suit
    /// narrow updates, but per-guild/forum calls become quadratic on large accounts.
    func unreadPresentationProjection(
        now: Date = .now
    ) -> UnreadPresentationProjection {
        // Scalar callers retain behavior; the app runs this same value-semantic
        // projection in a detached preparation task.
        unreadPresentationSource().projection(now: now)
            ?? UnreadPresentationProjection(
                unreadConversationCount: 0,
                unreadByChannelID: [:],
                mentionsByChannelID: [:],
                newForumPostsByChannelID: [:],
                unreadByGuildID: [:],
                mentionsByGuildID: [:],
                unreadCategoryIDsByGuild: [:],
                directMessageUnread: false,
                directMessageMentions: 0,
                totalMentions: 0
            )
    }

    func unreadPresentationSource() -> UnreadPresentationSource {
        UnreadPresentationSource(
            entries: entries,
            activeJoinedThreadIDs: activeJoinedThreadIDs,
            policy: unreadPolicySource,
            forumPostArchivedByID: forumPostArchivedByID,
            forumVisitBoundaryByID: forumSelectionAcknowledgementBoundary,
            guildJoinedAtByID: guildJoinedAtByID
        )
    }

    func guildUnread(_ guildID: GuildID, now: Date = .now) -> Bool {
        unreadPresentationSource().guildUnread(guildID, now: now)
    }

    func guildMentions(_ guildID: GuildID) -> Int {
        let policy = unreadPolicySource
        return entries.values.reduce(0) { total, entry in
            guard entry.guildID == guildID,
                  entry.isAccessible,
                  !policy.isGuildResourceChannel(entry)
            else { return total }
            return total + presentedMentionCount(entry)
        }
    }

    func folderUnread(_ guildIDs: [GuildID], now: Date = .now) -> Bool {
        guildIDs.contains { guildUnread($0, now: now) }
    }

    func directMessageUnread(now: Date = .now) -> Bool {
        entries.values.contains { entry in
            (entry.kind == .directMessage || entry.kind == .groupDirectMessage)
                && unread(channelID: entry.channelID, now: now)
        }
    }

    var directMessageMentions: Int {
        let policy = unreadPolicySource
        return entries.values.reduce(0) { total, entry in
            guard entry.kind == .directMessage
                    || entry.kind == .groupDirectMessage,
                  entry.isAccessible,
                  !policy.isGuildResourceChannel(entry)
            else { return total }
            return total + presentedMentionCount(entry)
        }
    }

    var totalMentions: Int {
        let policy = unreadPolicySource
        return entries.values.reduce(0) { total, entry in
            guard entry.isAccessible,
                  !policy.isGuildResourceChannel(entry)
            else { return total }
            return total + presentedMentionCount(entry)
        }
    }

    func isActivelyPresentedAtNewest(_ channelID: ChannelID) -> Bool {
        guard let presentation = self[presentation: channelID] else { return false }
        return presentation.isPresented
            && presentation.windowIsActive
            && presentation.hasReachedReadBoundary
    }

    func timelineUnreadSummary(
        channelID: ChannelID,
        messages: [Message],
        hasMoreBefore: Bool
    ) -> TimelineUnreadSummary? {
        guard let entry = self[channelID], entry.isAccessible, entry.isUnread else {
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
        guard let entry = self[channelID] else { return 0 }
        let policy = effectivePolicy(for: entry, now: .now)
        return messages.lazy.filter { message in
            message.id >= messageID
                && message.author.id != currentUserID
                && self.mentionKind(for: message, entry: entry, policy: policy) != .none
        }.count
    }

    private func newestUnacknowledgedMessage(in channelID: ChannelID) -> MessageID? {
        guard let entry = self[channelID], entry.isAccessible, entry.isUnread else {
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
        return AcknowledgementMetadata(
            flags: entry.flags == flags ? nil : flags,
            lastViewed: lastViewed
        )
    }

    private func entry(for channelID: ChannelID) -> Entry {
        if let existing = self[channelID] { return existing }
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

    func isInboxMention(_ message: Message, query: InboxMentionQuery) -> Bool {
        guard let currentUserID, self[message.channelID]?.kind != .directMessage,
              message.author.id != currentUserID || message.type == .pollResult else { return false }
        if message.mentionedUsers.contains(where: { $0.id == currentUserID }) { return true }
        if query.includesEveryone, message.mentionsEveryone { return true }
        let guildID = message.guildID ?? self[message.channelID]?.guildID
        return query.includesRoles && !message.flags.contains(.failedToMentionRoles)
            && guildID.flatMap { currentUserRoleIDsByGuild[$0] }.map { !$0.isDisjoint(with: message.mentionedRoleIDs) } == true
    }

    func setCurrentUserID(_ userID: UserID?) {
        currentUserID = userID
    }
}

private nonisolated func maximum<T: Comparable>(_ lhs: T?, _ rhs: T?) -> T? {
    switch (lhs, rhs) {
    case (.some(let lhs), .some(let rhs)): max(lhs, rhs)
    case (.some(let lhs), .none): lhs
    case (.none, .some(let rhs)): rhs
    case (.none, .none): nil
    }
}
