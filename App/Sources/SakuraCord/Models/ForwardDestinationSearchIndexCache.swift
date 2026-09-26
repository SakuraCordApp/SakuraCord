import OSLog
import SakuraCordModels
import SwiftUI

@MainActor
final class ForwardDestinationSearchIndexCache {
    static let shared = ForwardDestinationSearchIndexCache()

    private struct Key: Equatable {
        let modelID: ObjectIdentifier
        let userID: UserID?
        let revision: UInt64
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
        let eligibleChannelIDs: Set<ChannelID>

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
        let guildRoles: [GuildRole]
        let guildRolesByGuildID: [GuildID: [GuildRole]]
        let currentUserRoleIDsByGuild: [GuildID: Set<RoleID>]
        let usageScores: [String: Int]
        let usageOrder: [String]

        func makeInput(currentUserID: UserID?) -> Input {
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
                permissionsByChannelID[channel.id] = permissionBasis.map {
                    ConversationPermissionResolver.effectivePermissions(
                        guild: $0.guild,
                        channel: channel,
                        resolvedBasePermissions: $0.resolvedBasePermissions,
                        overwritePrincipals: $0.overwritePrincipals,
                        hasCurrentRoleIdentity: $0.hasCurrentRoleIdentity
                    )
                } ?? nil
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
            let eligibleChannelIDs = Set(
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

        private func makePermissionBasis(
            for guildID: GuildID,
            currentUserID: UserID?
        ) -> ConversationPermissionBasis? {
            guard let guild = serverRailGuildsByID[guildID],
                  let currentUserID
            else { return nil }
            let member = membersByGuildID[guildID]?[currentUserID]
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
                currentUserRequiresOnboarding: guild.features.contains("GUILD_ONBOARDING") && member?.requiresOnboarding == true,
                currentUserOnboardingIsKnown: !guild.features.contains("GUILD_ONBOARDING") || member?.flags != nil
            )
        }
    }

    private var modelID: ObjectIdentifier?
    private var userID: UserID?
    private var revision: UInt64?
    private var index: ForwardDestinationSearchPolicy.Index?
    private var preparationKey: Key?
    private var preparationTask: Task<ForwardDestinationSearchPolicy.Index, Never>?
    private var prewarmKey: PrewarmKey?
    private var prewarmTask: Task<Void, Never>?

    func value(
        for model: AppModel,
        userID: UserID?,
        revision: UInt64
    ) -> ForwardDestinationSearchPolicy.Index? {
        guard modelID == ObjectIdentifier(model),
              self.userID == userID,
              self.revision == revision
        else { return nil }
        return index
    }

    /// Returns the most recently completed index for this account even while a
    /// newer source revision is being prepared. An open search surface can use
    /// this immutable snapshot immediately and adopt the refresh next time it
    /// is presented instead of blocking interaction on background work.
    func latestValue(
        for model: AppModel,
        userID: UserID?
    ) -> ForwardDestinationSearchPolicy.Index? {
        guard modelID == ObjectIdentifier(model),
              self.userID == userID
        else { return nil }
        return index
    }

    func invalidate(for model: AppModel) {
        guard modelID == ObjectIdentifier(model) else { return }
        revision = nil
    }

    func store(
        _ index: ForwardDestinationSearchPolicy.Index,
        for model: AppModel,
        userID: UserID?,
        revision: UInt64
    ) {
        modelID = ObjectIdentifier(model)
        self.userID = userID
        self.revision = revision
        self.index = index
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
        priority: TaskPriority
    ) async -> ForwardDestinationSearchPolicy.Index? {
        let currentUserID = model.snapshot?.currentUser.id
        let sourceRevision = model.forwardSearchSourceRevision
        if let cached = value(
            for: model,
            userID: currentUserID,
            revision: sourceRevision
        ) {
            return cached
        }

        let key = Key(
            modelID: ObjectIdentifier(model),
            userID: currentUserID,
            revision: sourceRevision
        )
        if let preparationTask,
           let preparationKey,
           preparationKey != key
        {
            // Index construction is synchronous CPU work. Cancelling its Task
            // does not interrupt that work, so starting the next revision here
            // used to leave overlapping rebuilds competing with typing and
            // presentation. Cache the in-flight snapshot, then coalesce callers
            // onto one rebuild for the newest revision.
            let prepared = await preparationTask.value
            if self.preparationKey == preparationKey {
                modelID = preparationKey.modelID
                userID = preparationKey.userID
                revision = preparationKey.revision
                index = prepared
                self.preparationKey = nil
                self.preparationTask = nil
            }
            guard !Task.isCancelled else { return nil }
            return await prepare(for: model, priority: priority)
        }

        let task: Task<ForwardDestinationSearchPolicy.Index, Never>
        if preparationKey == key, let preparationTask {
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
                let input = source.makeInput(currentUserID: currentUserID)
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
            preparationKey = key
            preparationTask = newTask
            task = newTask
        }

        let prepared = await task.value
        if preparationKey == key {
            store(
                prepared,
                for: model,
                userID: currentUserID,
                revision: sourceRevision
            )
            preparationKey = nil
            preparationTask = nil
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
            guildRoles: model.guildRoles,
            guildRolesByGuildID: model.guildRolesByGuildID,
            currentUserRoleIDsByGuild: model.currentUserRoleIDsByGuild,
            usageScores: model.discordGuildAndChannelUsageScores,
            usageOrder: model.discordGuildAndChannelUsageOrder
        )
    }
}
