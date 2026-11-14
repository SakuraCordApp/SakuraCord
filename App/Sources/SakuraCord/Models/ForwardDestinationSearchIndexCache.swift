import OSLog
import SakuraCordModels
import SwiftUI

@MainActor
final class ForwardDestinationSearchIndexCache {
    static let shared = ForwardDestinationSearchIndexCache()

    /// The destinations a search covers. Forward lists conversations the
    /// account can post in; Favorites (Add to Favorites and Suggested
    /// Channels) lists every searchable one, as Discord's favourites filter
    /// replaces the forward permission check.
    nonisolated enum Corpus: Hashable, Sendable { case forward, favorites }

    private struct Key: Equatable {
        let modelID: ObjectIdentifier
        let userID: UserID?
        let revision: UInt64
    }

    /// One corpus's latest index and its build in flight.
    private struct Slot {
        var modelID: ObjectIdentifier?
        var userID: UserID?
        var revision: UInt64?
        var index: ForwardDestinationSearchPolicy.Index?
        var preparationKey: Key?
        var preparationTask: Task<ForwardDestinationSearchPolicy.Index, Never>?
    }

    private struct PrewarmKey: Equatable {
        let modelID: ObjectIdentifier
        let userID: UserID?
    }

    private nonisolated struct Input {
        let channels: [Channel]
        let threads: [MessageThreadSummary]
        let channelStoreOrder: [ChannelID]
        let users: [User]
        let friendUserIDs: Set<UserID>
        let relationshipNicknamesByUserID: [UserID: String]
        let userSearchAliasesByUserID: [UserID: [String]]
        let currentUserID: UserID?
        let guilds: [GuildID: Guild]
        let usageScores: [String: Int]
        let usageOrder: [String]
        let searchableChannelIDs: Set<ChannelID>
        /// nil for the Favorites corpus.
        let eligibleChannelIDs: Set<ChannelID>?

        func makeIndex() -> ForwardDestinationSearchPolicy.Index {
            ForwardDestinationSearchPolicy.makeIndex(
                channels: channels,
                threads: threads,
                channelStoreOrder: channelStoreOrder,
                users: users,
                friendUserIDs: friendUserIDs,
                relationshipNicknamesByUserID: relationshipNicknamesByUserID,
                userSearchAliasesByUserID: userSearchAliasesByUserID,
                currentUserID: currentUserID,
                guilds: guilds,
                usageScores: usageScores,
                usageOrder: usageOrder,
                searchableChannelIDs: searchableChannelIDs,
                eligibleChannelIDs: eligibleChannelIDs
            )
        }
    }

    /// A value-semantic snapshot of the stores needed to build the search
    /// corpus. Capturing these copy-on-write values on the main actor is cheap;
    /// ordering, dictionary construction, permission resolution, filtering,
    /// and index construction all happen after the snapshot leaves it.
    private nonisolated struct Source: Sendable {
        let snapshot: BootstrapSnapshot?
        let serverRailGuildsByID: [GuildID: Guild]
        let selectedGuildID: GuildID?
        let membersByID: [UserID: Member]
        let membersByGuildID: [GuildID: [UserID: Member]]
        let currentMembersByGuildID: [GuildID: Member]
        let guildRoles: [GuildRole]
        let guildRolesByGuildID: [GuildID: [GuildRole]]
        let currentUserRoleIDsByGuild: [GuildID: Set<RoleID>]
        let usageScores: [String: Int]
        let usageOrder: [String]

        func makeInput(currentUserID: UserID?, corpus: Corpus) -> Input {
            let channels = ForwardDestinationSearchPolicy.channelsInStoreOrder(
                snapshot?.channels ?? [],
                storeOrder: snapshot?.forwardChannelStoreOrder ?? []
            )
            let channelsByID = Dictionary(
                channels.map { ($0.id, $0) },
                uniquingKeysWith: { _, newer in newer }
            )
            let threads = snapshot?.activeJoinedThreads ?? []
            var permissionBasisByGuildID: [GuildID: ConversationPermissionBasis] = [:]
            var unresolvedGuildIDs: Set<GuildID> = []
            var permissionsByChannelID: [ChannelID: UInt64] = [:]
            permissionBasisByGuildID.reserveCapacity(serverRailGuildsByID.count)
            permissionsByChannelID.reserveCapacity(channels.count)
            for channel in channels {
                guard let guildID = channel.guildID else { continue }
                let permissionBasis: ConversationPermissionBasis?
                if let cached = permissionBasisByGuildID[guildID] {
                    permissionBasis = cached
                } else if unresolvedGuildIDs.contains(guildID) {
                    permissionBasis = nil
                } else if let resolved = makePermissionBasis(
                    for: guildID,
                    currentUserID: currentUserID
                ) {
                    permissionBasisByGuildID[guildID] = resolved
                    permissionBasis = resolved
                } else {
                    unresolvedGuildIDs.insert(guildID)
                    permissionBasis = nil
                }
                permissionsByChannelID[channel.id] = permissionBasis.flatMap { permissions(for: channel, basis: $0) }
            }
            let searchableChannelIDs = Set(
                channels.lazy.filter { channel in
                    ForwardDestinationPermissionPolicy.canSearchChannel(
                        channel,
                        permissions: permissionsByChannelID[channel.id]
                    )
                }.map(\.id)
            ).union(threads.compactMap { thread in
                guard !thread.isArchived,
                      let parentID = thread.parentID,
                      let parent = channelsByID[parentID],
                      ForwardDestinationPermissionPolicy.canSearchThread(
                          parent: parent,
                          permissions: permissionsByChannelID[parent.id]
                      )
                else { return nil }
                return thread.id
            })
            let eligibleChannelIDs = corpus == .favorites ? nil : Set(
                channels.lazy.filter { channel in
                    ForwardDestinationPermissionPolicy.canUseChannel(
                        channel,
                        permissions: permissionsByChannelID[channel.id]
                    )
                }.map(\.id)
            ).union(threads.compactMap { thread in
                guard !thread.isArchived,
                      let parentID = thread.parentID,
                      let parent = channelsByID[parentID],
                      ForwardDestinationPermissionPolicy.canUseThread(
                          parent: parent,
                          permissions: permissionsByChannelID[parent.id]
                      )
                else { return nil }
                return thread.id
            })
            let snapshotGuilds = Dictionary(
                uniqueKeysWithValues: (snapshot?.guilds ?? []).map { ($0.id, $0) }
            )
            let guilds = snapshotGuilds.merging(serverRailGuildsByID) { _, railGuild in
                railGuild
            }
            return Input(
                channels: channels,
                threads: threads,
                channelStoreOrder: snapshot?.forwardChannelStoreOrder ?? [],
                users: snapshot?.knownUsers ?? [],
                friendUserIDs: snapshot?.friendUserIDs ?? [],
                relationshipNicknamesByUserID:
                    snapshot?.relationshipNicknamesByUserID ?? [:],
                userSearchAliasesByUserID:
                    snapshot?.userSearchAliasesByUserID ?? [:],
                currentUserID: currentUserID,
                guilds: guilds,
                usageScores: usageScores,
                usageOrder: usageOrder,
                searchableChannelIDs: searchableChannelIDs,
                eligibleChannelIDs: eligibleChannelIDs
            )
        }

        private func permissions(for channel: Channel, basis: ConversationPermissionBasis) -> UInt64? {
            ConversationPermissionResolver.effectivePermissions(
                guild: basis.guild, channel: channel, resolvedBasePermissions: basis.resolvedBasePermissions,
                overwritePrincipals: basis.overwritePrincipals, hasCurrentRoleIdentity: basis.hasCurrentRoleIdentity,
                communicationDisabledUntil: basis.currentUserCommunicationDisabledUntil
            )
        }

        private func makePermissionBasis(
            for guildID: GuildID,
            currentUserID: UserID?
        ) -> ConversationPermissionBasis? {
            guard let guild = serverRailGuildsByID[guildID],
                  let currentUserID
            else { return nil }
            let member = currentMembersByGuildID[guildID] ?? membersByGuildID[guildID]?[currentUserID]
                ?? (guildID == selectedGuildID ? membersByID[currentUserID] : nil)
            let roles = guildRolesByGuildID[guildID]
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
                currentUserIsPending: member?.isPending == true,
                currentUserCommunicationDisabledUntil: member?.communicationDisabledUntil,
                currentUserRequiresOnboarding: guild.features.contains("GUILD_ONBOARDING") && member?.requiresOnboarding == true,
                currentUserOnboardingIsKnown: !guild.features.contains("GUILD_ONBOARDING") || member?.flags != nil
            )
        }
    }

    private var slots: [Corpus: Slot] = [:]
    private var prewarmKey: PrewarmKey?
    private var prewarmTask: Task<Void, Never>?

    func value(
        for model: AppModel,
        userID: UserID?,
        revision: UInt64,
        corpus: Corpus = .forward
    ) -> ForwardDestinationSearchPolicy.Index? {
        guard let slot = slots[corpus], slot.modelID == ObjectIdentifier(model),
              slot.userID == userID,
              slot.revision == revision
        else { return nil }
        return slot.index
    }

    /// Returns the most recently completed index for this account even while a
    /// newer source revision is being prepared. An open search surface can use
    /// this immutable snapshot immediately and adopt the refresh next time it
    /// is presented instead of blocking interaction on background work.
    func latestValue(
        for model: AppModel,
        userID: UserID?,
        corpus: Corpus = .forward
    ) -> ForwardDestinationSearchPolicy.Index? {
        guard let slot = slots[corpus], slot.modelID == ObjectIdentifier(model),
              slot.userID == userID
        else { return nil }
        return slot.index
    }

    func invalidate(for model: AppModel) {
        for corpus in slots.keys where slots[corpus]?.modelID == ObjectIdentifier(model) {
            slots[corpus]?.revision = nil
        }
    }

    func store(
        _ index: ForwardDestinationSearchPolicy.Index,
        for model: AppModel,
        userID: UserID?,
        revision: UInt64,
        corpus: Corpus = .forward
    ) {
        slots[corpus, default: Slot()].modelID = ObjectIdentifier(model)
        slots[corpus]?.userID = userID
        slots[corpus]?.revision = revision
        slots[corpus]?.index = index
    }

    /// Starts one cache-owned background prewarm for an account. View tasks
    /// are revision-bound and are cancelled repeatedly during READY and guild
    /// activation; owning the debounce here guarantees one build while still
    /// coalescing every source revision that arrives before it begins.
    func schedulePrewarm(for model: AppModel) {
        let userID = model.snapshot?.currentUser.id
        let key = PrewarmKey(
            modelID: ObjectIdentifier(model),
            userID: userID
        )
        if let prewarmKey, prewarmKey != key {
            prewarmTask?.cancel()
            prewarmTask = nil
            self.prewarmKey = nil
        }
        guard latestValue(for: model, userID: userID) == nil,
              prewarmTask == nil
        else { return }
        prewarmKey = key
        AppPerformanceSignposts.signposter.emitEvent(
            "ForwardDestinationIndexPrewarmScheduled"
        )
        prewarmTask = Task { @MainActor [weak self, weak model] in
            do {
                try await Task.sleep(for: .milliseconds(750))
            } catch {
                guard let self, self.prewarmKey == key else { return }
                self.prewarmKey = nil
                self.prewarmTask = nil
                return
            }
            guard let self, self.prewarmKey == key else { return }
            self.prewarmKey = nil
            self.prewarmTask = nil
            guard let model,
                  ObjectIdentifier(model) == key.modelID,
                  model.snapshot?.currentUser.id == key.userID,
                  self.latestValue(for: model, userID: key.userID) == nil
            else { return }
            _ = await self.prepare(for: model, priority: .utility)
        }
    }

    func prepare(
        for model: AppModel,
        priority: TaskPriority,
        corpus: Corpus = .forward
    ) async -> ForwardDestinationSearchPolicy.Index? {
        let currentUserID = model.snapshot?.currentUser.id
        let sourceRevision = model.forwardSearchSourceRevision
        if let cached = value(
            for: model,
            userID: currentUserID,
            revision: sourceRevision,
            corpus: corpus
        ) {
            return cached
        }

        let key = Key(
            modelID: ObjectIdentifier(model),
            userID: currentUserID,
            revision: sourceRevision
        )
        if let preparationTask = slots[corpus]?.preparationTask,
           let preparationKey = slots[corpus]?.preparationKey,
           preparationKey != key
        {
            // Index construction is synchronous CPU work. Cancelling its Task
            // does not interrupt that work, so starting the next revision here
            // used to leave overlapping rebuilds competing with typing and
            // presentation. Cache the in-flight snapshot, then coalesce callers
            // onto one rebuild for the newest revision.
            let prepared = await preparationTask.value
            if slots[corpus]?.preparationKey == preparationKey {
                slots[corpus] = Slot(
                    modelID: preparationKey.modelID, userID: preparationKey.userID,
                    revision: preparationKey.revision, index: prepared
                )
            }
            guard !Task.isCancelled else { return nil }
            return await prepare(for: model, priority: priority, corpus: corpus)
        }

        let task: Task<ForwardDestinationSearchPolicy.Index, Never>
        if slots[corpus]?.preparationKey == key, let preparationTask = slots[corpus]?.preparationTask {
            task = preparationTask
        } else {
            let source = AppPerformanceSignposts.measureSync(
                "ForwardDestinationIndexSourceSnapshot"
            ) {
                makeSource(for: model)
            }
            let newTask = Task.detached(priority: priority) {
                let signposter = OSSignposter(
                    subsystem: "dev.sakuracord.SakuraCord",
                    category: "PointsOfInterest"
                )
                let preparation = signposter.beginInterval(
                    "ForwardDestinationIndexPreparation"
                )
                defer {
                    signposter.endInterval(
                        "ForwardDestinationIndexPreparation",
                        preparation
                    )
                }
                let inputInterval = signposter.beginInterval(
                    "ForwardDestinationIndexInputPreparation"
                )
                let input = source.makeInput(currentUserID: currentUserID, corpus: corpus)
                signposter.endInterval(
                    "ForwardDestinationIndexInputPreparation",
                    inputInterval
                )
                let construction = signposter.beginInterval(
                    "ForwardDestinationIndexConstruction"
                )
                let index = input.makeIndex()
                signposter.endInterval(
                    "ForwardDestinationIndexConstruction",
                    construction
                )
                return index
            }
            slots[corpus, default: Slot()].preparationKey = key
            slots[corpus]?.preparationTask = newTask
            task = newTask
        }

        let prepared = await task.value
        if slots[corpus]?.preparationKey == key {
            store(
                prepared,
                for: model,
                userID: currentUserID,
                revision: sourceRevision,
                corpus: corpus
            )
            slots[corpus]?.preparationKey = nil
            slots[corpus]?.preparationTask = nil
        }
        guard !Task.isCancelled else { return nil }
        return prepared
    }

    private func makeSource(for model: AppModel) -> Source {
        Source(
            snapshot: model.snapshot,
            serverRailGuildsByID: model.serverRailGuildsByID,
            selectedGuildID: model.selectedGuildID,
            membersByID: model.membersByID,
            membersByGuildID: model.membersByGuildID,
            currentMembersByGuildID: model.onboarding.members,
            guildRoles: model.guildRoles,
            guildRolesByGuildID: model.guildRolesByGuildID,
            currentUserRoleIDsByGuild: model.currentUserRoleIDsByGuild,
            usageScores: model.discordGuildAndChannelUsageScores,
            usageOrder: model.discordGuildAndChannelUsageOrder
        )
    }
}
