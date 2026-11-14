import Foundation
import SakuraCordModels

enum DiscordGuildSubscriptionRequest: Sendable {
    case members(channelID: ChannelID, ranges: [ClosedRange<Int>])
    case threads
    case refresh(memberListID: String, isDeferred: Bool)
}

struct DiscordMemberListInFlightRequest: Sendable {
    let generation: UUID
    let memberListID: String
    let subscription: DiscordMemberListSubscription
}

extension DiscordRESTProvider {
    /// Channel ranges replace the retained map; thread updates are partial.
    /// Serialize both so an older full payload cannot overwrite a newer thread
    /// selection, and compute each payload from the preceding committed send.
    func enqueueGuildSubscription(
        guildID: GuildID, request: DiscordGuildSubscriptionRequest
    ) async throws {
        let previous = guildSubscriptionTasks[guildID]
        let taskID = UUID()
        let generation = guildSubscriptionGenerations[guildID] ?? UUID()
        guildSubscriptionGenerations[guildID] = generation
        let task = Task { [weak self] in
            _ = await previous?.result
            try Task.checkCancellation()
            guard let self else { throw CancellationError() }
            try await self.performGuildSubscription(
                guildID: guildID, request: request, generation: generation
            )
        }
        guildSubscriptionTaskIDs[guildID] = taskID
        guildSubscriptionTasks[guildID] = task
        #if DEBUG
            for waiter in guildSubscriptionQueueWaitersForTesting.removeValue(forKey: guildID) ?? [] {
                waiter.resume()
            }
        #endif
        defer {
            if guildSubscriptionTaskIDs[guildID] == taskID {
                guildSubscriptionTaskIDs[guildID] = nil
                guildSubscriptionTasks[guildID] = nil
            }
        }
        do {
            try await task.value
        } catch {
            scheduleMemberListRefreshRetry(guildID: guildID)
            throw error
        }
    }

    private func performGuildSubscription(
        guildID: GuildID, request: DiscordGuildSubscriptionRequest, generation: UUID
    ) async throws {
        guard guildSubscriptionGenerations[guildID] == generation else {
            throw CancellationError()
        }
        switch request {
        case .threads:
            try await sendGateway(DiscordGatewayPayloadFactory.threadMemberSubscriptions(
                guildID: guildID, threadIDs: threadMemberSubscriptions[guildID] ?? []
            ))
        case let .refresh(memberListID, isDeferred):
            guard pendingMemberGuildID == guildID,
                  memberListState.selectedIDs[guildID] == memberListID
            else { return }
            let viewport = memberListState.viewportRequests[guildID]
            let requested = viewport?.memberListID == memberListID ? viewport?.subscription : nil
            guard let current = requested ?? memberListState.subscriptions[guildID]?[memberListID]
            else { return }
            if isDeferred {
                guard memberListState.listsNeedingRefresh[guildID]?[memberListID] != nil,
                      memberListRefreshRetryAttempts[guildID]?.contains(memberListID) != true,
                      isMemberListAccessible(guildID: guildID, memberListID: memberListID, subscription: current)
                else { return }
                // A newer cooldown can arrive while this refresh waits in the
                // guild queue. A local refusal must not spend its wire attempt.
                if memberListSubscriptionCooldown != nil {
                    scheduleMemberListRefreshRetry(guildID: guildID)
                    return
                }
                memberListRefreshRetryAttempts[guildID, default: []].insert(memberListID)
            }
            try await performGuildSubscription(
                guildID: guildID,
                request: .members(channelID: current.channelID, ranges: current.ranges),
                generation: generation
            )
        case let .members(channelID, ranges):
            guard let channel = cachedChannels[guildID]?.first(where: { $0.id == channelID }),
                  canViewMemberListChannel(channel, guildID: guildID)
            else { return }
            let memberListID = DiscordMemberListIdentity.id(
                for: channel, guildID: guildID, roles: cachedGuildRoles[guildID] ?? []
            )
            let accessible = (memberListState.subscriptions[guildID] ?? [:]).filter {
                isMemberListAccessible(guildID: guildID, memberListID: $0.key)
            }
            let hadCommittedSubscription = accessible[memberListID] != nil
            let state = DiscordMemberListRangePolicy.subscriptionState(
                selecting: memberListID, channelID: channelID, ranges: ranges,
                currentSubscriptions: accessible,
                currentOrder: (memberListState.subscriptionOrder[guildID] ?? []).filter {
                    accessible[$0] != nil
                }
            )
            let refresh = memberListState.listsNeedingRefresh[guildID]?[memberListID]
            memberListInFlightRequests[guildID] = DiscordMemberListInFlightRequest(
                generation: generation, memberListID: memberListID,
                subscription: DiscordMemberListSubscription(channelID: channelID, ranges: ranges)
            )
            defer {
                if memberListInFlightRequests[guildID]?.generation == generation {
                    memberListInFlightRequests[guildID] = nil
                }
            }
            try await sendGateway(DiscordGatewayPayloadFactory.guildSubscriptions(
                guildID: guildID, channelRanges: state.rangesByChannel,
                threadMemberLists: threadMemberSubscriptions[guildID]
            ))
            try Task.checkCancellation()
            guard guildSubscriptionGenerations[guildID] == generation else {
                throw CancellationError()
            }
            memberListState.subscriptionOrder[guildID] = state.memberListOrder
            memberListState.subscriptions[guildID] = state.subscriptionsByMemberListID
            if let refresh, memberListState.listsNeedingRefresh[guildID]?[memberListID] == refresh {
                memberListState.listsNeedingRefresh[guildID]?[memberListID] = nil
                memberListState.refreshRetryTasks.removeValue(forKey: guildID)?.cancel()
            }
            memberListRefreshRetryAttempts[guildID]?.formIntersection(state.subscriptionsByMemberListID.keys)
            // A rejection may arrive before this first send commits. Its
            // refresh marker becomes eligible for the deferred retry now.
            scheduleMemberListRefreshRetry(guildID: guildID)
            // A SYNC can arrive before the socket send completes. Publication
            // waits for a committed subscription, so deliver those cached rows
            // once the selected list has become accessible to its consumer.
            if !hadCommittedSubscription,
               pendingMemberGuildID == guildID,
               memberListState.selectedIDs[guildID] == memberListID,
               memberListState.cachedItems[guildID]?[memberListID] != nil {
                publishMembers(
                    guildID: guildID,
                    members: orderedMemberListMembers(guildID: guildID) ?? [],
                    groups: selectedMemberListGroups(guildID: guildID)
                )
            }
        }
    }

    func markMemberListForRefresh(
        guildID: GuildID, memberListID: String, resetRetryBudget: Bool = true
    ) {
        if resetRetryBudget {
            memberListRefreshRetryAttempts[guildID]?.remove(memberListID)
        }
        memberListState.listsNeedingRefresh[guildID, default: [:]][memberListID] = UUID()
    }

    /// One deferred attempt per invalidation, only for a selected list and a
    /// known opcode cooldown. Further failure awaits a user action or reconnect.
    func scheduleMemberListRefreshRetry(guildID: GuildID) {
        // Waiting timers do not consume the attempt budget. Selection can
        // cancel one before it runs, then return during the same cooldown.
        guard gatewayReady, pendingMemberGuildID == guildID,
              let memberListID = memberListState.selectedIDs[guildID],
              let refresh = memberListState.listsNeedingRefresh[guildID]?[memberListID],
              !memberListSubscriptionsForRefresh(guildID: guildID, memberListID: memberListID).isEmpty,
              let cooldown = memberListSubscriptionCooldown,
              memberListRefreshRetryAttempts[guildID]?.contains(memberListID) != true
        else { return }
        memberListState.refreshRetryTasks[guildID]?.cancel()
        memberListState.refreshRetryTasks[guildID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, cooldown.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            await self?.retryMemberListRefresh(
                guildID: guildID, memberListID: memberListID, refresh: refresh
            )
        }
    }

    func retryMemberListRefresh(guildID: GuildID, memberListID: String, refresh: UUID) async {
        guard pendingMemberGuildID == guildID,
              memberListState.selectedIDs[guildID] == memberListID,
              memberListState.listsNeedingRefresh[guildID]?[memberListID] == refresh,
              memberListRefreshRetryAttempts[guildID]?.contains(memberListID) != true
        else { return }
        memberListState.refreshRetryTasks[guildID] = nil
        guard gatewayReady,
              !memberListSubscriptionsForRefresh(guildID: guildID, memberListID: memberListID).isEmpty
        else { return }
        do {
            try await enqueueGuildSubscription(
                guildID: guildID, request: .refresh(memberListID: memberListID, isDeferred: true)
            )
        } catch {
            gatewayLogger.error("Deferred member-list refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func resetMemberListSubscriptionWork(guildID: GuildID? = nil, preservingThreadRequests: Bool = false) {
        let guildIDs = guildID.map { [$0] } ?? Array(Set(
            guildSubscriptionGenerations.keys
        ).union(memberListState.refreshRetryTasks.keys).union(memberListState.viewportRestoreTasks.keys)
            .union(threadMemberSubscriptionRequestIDs.keys))
        for guildID in guildIDs {
            if !preservingThreadRequests { threadMemberSubscriptionRequestIDs[guildID] = nil }
            guildSubscriptionGenerations[guildID] = nil
            memberListInFlightRequests[guildID] = nil
            guildSubscriptionTasks.removeValue(forKey: guildID)?.cancel()
            guildSubscriptionTaskIDs[guildID] = nil
            memberListState.refreshRetryTasks.removeValue(forKey: guildID)?.cancel()
            memberListState.viewportRestoreTasks.removeValue(forKey: guildID)?.cancel()
            memberListRefreshRetryAttempts[guildID] = nil
            #if DEBUG
                for waiter in guildSubscriptionQueueWaitersForTesting.removeValue(forKey: guildID) ?? [] {
                    waiter.resume()
                }
            #endif
        }
    }
}

extension DiscordRESTProvider {
    /// The active opcode-37 (member-list subscription) cooldown, if any.
    var memberListSubscriptionCooldown: Date? {
        gatewayOpcodeRateLimitDates[37].flatMap { $0 > Date.now ? $0 : nil }
    }

    /// A list's committed ranges, the latest viewport, and an active send
    /// whose viewport selection has changed.
    func memberListSubscriptions(guildID: GuildID, memberListID: String) -> [DiscordMemberListSubscription] {
        let viewport = memberListState.viewportRequests[guildID]
        let inFlight = memberListInFlightRequests[guildID]
        return [
            memberListState.subscriptions[guildID]?[memberListID],
            viewport?.memberListID == memberListID ? viewport?.subscription : nil,
            inFlight?.memberListID == memberListID ? inFlight?.subscription : nil,
        ].compactMap { $0 }
    }

    /// Recovery covers every subscription the list holds. Publication still
    /// requires a committed subscription through isMemberListAccessible's
    /// default lookup.
    func memberListSubscriptionsForRefresh(
        guildID: GuildID, memberListID: String
    ) -> [DiscordMemberListSubscription] {
        memberListSubscriptions(guildID: guildID, memberListID: memberListID).filter {
            isMemberListAccessible(guildID: guildID, memberListID: memberListID, subscription: $0)
        }
    }

    /// Use current guild permissions and role identity, then apply channel
    /// overwrites in Discord's everyone / roles / member order. Metadata alone
    /// does not establish that this account may view the channel.
    func canViewMemberListChannel(_ channel: Channel, guildID: GuildID) -> Bool {
        guard let guild = cachedGuilds[guildID] else { return false }
        if guild.isOwnedByCurrentUser == true { return true }
        guard let userID = currentUser?.id else { return false }
        let member = cachedMembers[guildID]?.first { $0.id == userID }
        let roleIDs = Set(member?.roleIDs.map(\.description) ?? [])
        let roles = cachedGuildRoles[guildID] ?? []
        let everyone = roles.first { $0.id == guildID.description }
        let permissions: UInt64
        if let snapshot = guild.currentUserPermissions {
            permissions = snapshot
        } else {
            guard member != nil, let everyone,
                  roleIDs.allSatisfy({ id in roles.contains { $0.id == id } })
            else { return false }
            permissions = roles.filter {
                $0.id == everyone.id || roleIDs.contains($0.id)
            }.reduce(0) { $0 | ($1.permissions.flatMap(UInt64.init) ?? 0) }
        }
        if permissions & DiscordPermissionBits.administrator != 0 { return true }
        let overwrites = channel.permissionOverwrites ?? []
        if member == nil, overwrites.contains(where: {
            $0.type == 0 && $0.id != guildID.description
        }) { return false }
        var value = permissions
        let everyoneOverwrites = overwrites.filter {
            $0.type == 0 && $0.id == guildID.description
        }
        let roleOverwrites = overwrites.filter {
            $0.type == 0 && $0.id != guildID.description && roleIDs.contains($0.id)
        }
        let memberOverwrites = overwrites.filter {
            $0.type == 1 && $0.id == userID.description
        }
        for group in [everyoneOverwrites, roleOverwrites, memberOverwrites] {
            value &= ~group.reduce(0) { $0 | $1.deny }
            value |= group.reduce(0) { $0 | $1.allow }
        }
        return value & DiscordPermissionBits.viewChannel != 0
    }

    @discardableResult
    func discardInaccessibleMemberLists(guildID: GuildID) -> Bool {
        var selectedWasDiscarded = false
        var discardedSubscription = false
        let viewport = memberListState.viewportRequests[guildID]
        let inFlight = memberListInFlightRequests[guildID]
        var memberListIDs = Set(memberListState.subscriptions[guildID].map { Array($0.keys) } ?? [])
        if let viewport { memberListIDs.insert(viewport.memberListID) }
        if let inFlight { memberListIDs.insert(inFlight.memberListID) }
        for memberListID in memberListIDs {
            // A first subscription may still be in flight. Its requested
            // channel must lose its rows and send generation on access loss,
            // even before there is a committed subscription to discard.
            let requested = memberListState.viewportRequests[guildID].flatMap {
                $0.memberListID == memberListID ? $0.subscription : nil
            }
            guard memberListSubscriptions(guildID: guildID, memberListID: memberListID).contains(where: {
                !isMemberListAccessible(guildID: guildID, memberListID: memberListID, subscription: $0)
            }) else { continue }
            discardedSubscription = true
            memberListState.cachedItems[guildID]?[memberListID] = nil
            memberListState.cachedGroups[guildID]?[memberListID] = nil
            memberListState.subscriptions[guildID]?[memberListID] = nil
            memberListState.subscriptionOrder[guildID]?.removeAll { $0 == memberListID }
            memberListState.listsNeedingRefresh[guildID]?[memberListID] = nil
            memberListRefreshRetryAttempts[guildID]?.remove(memberListID)
            if memberListState.selectedIDs[guildID] == memberListID {
                selectedWasDiscarded = true
                // Two channels may share a list ID. Losing the committed or
                // active channel must not erase a still-accessible desired one.
                if let requested,
                   let channel = cachedChannels[guildID]?.first(where: { $0.id == requested.channelID }),
                   canViewMemberListChannel(channel, guildID: guildID) {
                    // The same viewable channel can now resolve to a different
                    // list. Restore its viewport under the current identity.
                    let currentListID = DiscordMemberListIdentity.id(
                        for: channel, guildID: guildID, roles: cachedGuildRoles[guildID] ?? []
                    )
                    memberListState.selectedIDs[guildID] = currentListID
                    memberListState.viewportRequests[guildID] = (currentListID, requested)
                } else {
                    memberListState.viewportRequests[guildID] = nil
                }
                memberListState.refreshRetryTasks.removeValue(forKey: guildID)?.cancel()
            }
        }
        if discardedSubscription {
            // A send started before access loss must not restore the discarded
            // ranges. Regaining access requires a fresh subscription.
            resetMemberListSubscriptionWork(guildID: guildID, preservingThreadRequests: true)
            // Resetting the guild queue also cancels a newer, still-accessible
            // selection. Restore its desired viewport without requiring a
            // second native viewport callback.
            if gatewayReady, pendingMemberGuildID == guildID,
               let current = memberListState.viewportRequests[guildID],
               memberListState.selectedIDs[guildID] == current.memberListID,
               isMemberListAccessible(
                   guildID: guildID, memberListID: current.memberListID,
                   subscription: current.subscription
               ) {
                let generation = UUID()
                guildSubscriptionGenerations[guildID] = generation
                memberListState.viewportRestoreTasks[guildID] = Task { [weak self] in
                    await self?.restoreSelectedMemberListViewport(guildID: guildID, generation: generation)
                }
            }
        }
        return selectedWasDiscarded
    }

    func restoreSelectedMemberListViewport(guildID: GuildID, generation: UUID) async {
        defer {
            if guildSubscriptionGenerations[guildID] == generation {
                memberListState.viewportRestoreTasks[guildID] = nil
            }
        }
        // One restore attempt waits out an already-known cooldown, including
        // a desired viewport whose first subscription has not committed.
        if let cooldown = memberListSubscriptionCooldown {
            try? await Task.sleep(for: .seconds(max(0, cooldown.timeIntervalSinceNow)))
        }
        guard !Task.isCancelled, gatewayReady, guildSubscriptionGenerations[guildID] == generation,
              pendingMemberGuildID == guildID,
              let viewport = memberListState.viewportRequests[guildID],
              memberListState.selectedIDs[guildID] == viewport.memberListID,
              isMemberListAccessible(
                  guildID: guildID, memberListID: viewport.memberListID,
                  subscription: viewport.subscription
              )
        else { return }
        do {
            try await enqueueGuildSubscription(
                guildID: guildID,
                request: .members(channelID: viewport.subscription.channelID, ranges: viewport.subscription.ranges)
            )
        } catch {
            gatewayLogger.error("Member-list subscription after access change failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// The member-list subscriptions a session holds, dropped together when a
/// new Gateway session replaces them.
struct MemberListSubscriptionState {
    var subscriptions: [GuildID: [String: DiscordMemberListSubscription]] = [:]
    var subscriptionOrder: [GuildID: [String]] = [:]
    /// The selected viewport can move while a cooldown prevents committing it.
    var viewportRequests:
        [GuildID: (memberListID: String, subscription: DiscordMemberListSubscription)] = [:]
    /// Retained member lists whose subscribed ranges were invalidated and
    /// still need a subscription send to get a fresh SYNC.
    var listsNeedingRefresh: [GuildID: [String: UUID]] = [:]
    var cachedItems: [GuildID: [String: [GuildMemberListUpdateDTO.Item?]]] = [:]
    var cachedGroups: [GuildID: [String: [GuildMemberListGroup]]] = [:]
    var selectedIDs: [GuildID: String] = [:]
    var refreshRetryTasks: [GuildID: Task<Void, Never>] = [:]
    var viewportRestoreTasks: [GuildID: Task<Void, Never>] = [:]
}

extension DiscordRESTProvider {
    func subscribeToMemberList(
        guildID: GuildID,
        channelID requestedChannelID: ChannelID? = nil,
        ranges: [ClosedRange<Int>] = [0 ... 99]
    ) async throws {
        let selectedChannel: Channel?
        if let requestedChannelID {
            selectedChannel = cachedChannels[guildID]?.first { $0.id == requestedChannelID }
        } else {
            selectedChannel = cachedChannels[guildID]?.first {
                $0.kind != .voice
                    && canViewMemberListChannel($0, guildID: guildID)
            }
        }
        guard let selectedChannel,
              canViewMemberListChannel(selectedChannel, guildID: guildID)
        else { return }
        let memberListID = DiscordMemberListIdentity.id(
            for: selectedChannel, guildID: guildID,
            roles: cachedGuildRoles[guildID] ?? []
        )
        if memberListState.selectedIDs[guildID] != memberListID {
            memberListState.refreshRetryTasks.removeValue(forKey: guildID)?.cancel()
            memberListState.viewportRestoreTasks.removeValue(forKey: guildID)?.cancel()
        }
        memberListState.selectedIDs[guildID] = memberListID
        memberListState.viewportRequests[guildID] = (
            memberListID, DiscordMemberListSubscription(channelID: selectedChannel.id, ranges: ranges)
        )
        try await enqueueGuildSubscription(
            guildID: guildID,
            request: .members(channelID: selectedChannel.id, ranges: ranges)
        )
    }

    func attemptMemberSubscription(guildID: GuildID, restoringViewport: Bool = false) async {
        // RESUMED retains the selected channel and its latest requested ranges.
        // A fresh READY clears the viewport and starts with the initial block.
        let viewport = restoringViewport ? memberListState.viewportRequests[guildID]?.subscription : nil
        do {
            try await subscribeToMemberList(
                guildID: guildID, channelID: viewport?.channelID,
                ranges: viewport?.ranges ?? [DiscordMemberListRangePolicy.initialRange]
            )
        } catch {
            gatewayLogger.error(
                "Lazy member-list subscription failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    public func updateMemberListViewport(
        in guildID: GuildID,
        channelID: ChannelID,
        visibleRange: ClosedRange<Int>
    ) async throws {
        guard pendingMemberGuildID == guildID else { return }
        let ranges = DiscordMemberListRangePolicy.ranges(around: visibleRange)
        guard let channel = cachedChannels[guildID]?.first(where: { $0.id == channelID })
        else { return }
        let memberListID = DiscordMemberListIdentity.id(
            for: channel,
            guildID: guildID,
            roles: cachedGuildRoles[guildID] ?? []
        )
        let changedSelection = memberListState.selectedIDs[guildID] != memberListID
        memberListState.selectedIDs[guildID] = memberListID
        memberListState.viewportRequests[guildID] = (
            memberListID, DiscordMemberListSubscription(channelID: channelID, ranges: ranges)
        )
        if changedSelection {
            memberListState.refreshRetryTasks.removeValue(forKey: guildID)?.cancel()
            memberListState.viewportRestoreTasks.removeValue(forKey: guildID)?.cancel()
        }
        // An inaccessible viewport still supersedes the old selection. This
        // cancels its recovery and lets returning to an accessible cached list
        // publish rows even when its subscribed ranges have not changed.
        guard canViewMemberListChannel(channel, guildID: guildID) else {
            discardInaccessibleMemberLists(guildID: guildID)
            publishMembers(guildID: guildID, members: [], groups: [])
            return
        }
        if changedSelection {
            publishMembers(
                guildID: guildID,
                members: orderedMemberListMembers(
                    guildID: guildID, memberListID: memberListID
                ) ?? [],
                groups: memberListState.cachedGroups[guildID]?[memberListID] ?? []
            )
        }
        let needsRefresh = memberListState.listsNeedingRefresh[guildID]?[memberListID] != nil
        if !needsRefresh,
           !DiscordMemberListRangePolicy.requiresSubscriptionUpdate(
               memberListID: memberListID,
               ranges: ranges,
               currentSubscriptions: memberListState.subscriptions[guildID] ?? [:]
           )
        {
            return
        }
        try await subscribeToMemberList(
            guildID: guildID,
            channelID: channelID,
            ranges: ranges
        )
    }
}

extension DiscordRESTProvider {
    #if DEBUG
        func orderedMemberListIDsForTesting(
            guildID: GuildID, memberListID: String
        ) -> [UserID] {
            orderedMemberListMembers(
                guildID: guildID, memberListID: memberListID
            )?.map(\.id) ?? []
        }

        func memberListGroupsForTesting(
            guildID: GuildID, memberListID: String
        ) -> [GuildMemberListGroup] {
            memberListState.cachedGroups[guildID]?[memberListID] ?? []
        }
    #endif

    func decodedMemberListMembers(
        guildID: GuildID,
        memberListID: String,
        restrictingTo changedUserIDs: Set<UserID>? = nil
    ) -> [Member] {
        if changedUserIDs?.isEmpty == true {
            discordPerformanceSignposter.emitEvent(
                "GatewayMemberListDomainDecodeSkipped"
            )
            return []
        }
        let roleCatalogBuild = discordPerformanceSignposter.beginInterval(
            "GatewayMemberListRoleCatalogBuild",
            id: discordPerformanceSignposter.makeSignpostID()
        )
        let guildRoles = cachedGuildRoles[guildID] ?? []
        let guildRoleCatalog = GuildMemberRoleCatalog(guildRoles)
        discordPerformanceSignposter.endInterval(
            "GatewayMemberListRoleCatalogBuild", roleCatalogBuild
        )

        let domainDecode = discordPerformanceSignposter.beginInterval(
            "GatewayMemberListDomainDecode",
            id: discordPerformanceSignposter.makeSignpostID()
        )
        defer {
            discordPerformanceSignposter.endInterval(
                "GatewayMemberListDomainDecode", domainDecode
            )
        }
        var seen = Set<UserID>()
        let previousMembers = cachedMemberIndex(guildID: guildID)
        return (memberListState.cachedItems[guildID]?[memberListID] ?? []).enumerated().compactMap { index, item -> Member? in
            guard let memberDTO = item?.member,
                  let userID = UserID(memberDTO.user.id),
                  changedUserIDs?.contains(userID) != false,
                  var member = try? memberDTO.domain(
                      currentUserID: currentUser?.id,
                      currentStatus: presenceStatus,
                      presence: item?.presence,
                      guildRoles: guildRoles,
                      guildRoleCatalog: guildRoleCatalog,
                      guildID: guildID,
                      previousCommunicationDisabledUntil: previousMembers[userID]?.communicationDisabledUntil
                  ),
                  seen.insert(member.id).inserted
            else { return nil }
            member.memberListIndex = index
            return member
        }
    }

    func orderedMemberListMembers(
        guildID: GuildID,
        memberListID: String? = nil
    ) -> [Member]? {
        guard let memberListID = memberListID ?? memberListState.selectedIDs[guildID],
              let memberListItems = memberListState.cachedItems[guildID]?[memberListID]
        else { return nil }
        let ordering = discordPerformanceSignposter.beginInterval(
            "GatewayMemberListOrdering",
            id: discordPerformanceSignposter.makeSignpostID()
        )
        defer {
            discordPerformanceSignposter.endInterval(
                "GatewayMemberListOrdering", ordering
            )
        }
        var membersByID = Dictionary(
            (cachedMembers[guildID] ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        var seen = Set<UserID>()
        let orderedIDs = memberListItems.enumerated().compactMap { index, item -> (UserID, Int)? in
            guard let rawUserID = item?.member?.user.id,
                  let userID = UserID(rawUserID),
                  seen.insert(userID).inserted
            else { return nil }
            return (userID, index)
        }
        let missingUserIDs = Set(orderedIDs.lazy.map(\.0)).subtracting(
            membersByID.keys
        )
        if !missingUserIDs.isEmpty {
            for member in decodedMemberListMembers(
                guildID: guildID,
                memberListID: memberListID,
                restrictingTo: missingUserIDs
            ) {
                membersByID[member.id] = member
            }
        }
        return orderedIDs.compactMap { userID, index in
            guard var member = membersByID[userID] else { return nil }
            member.memberListIndex = index
            return member
        }
    }

    static func memberListChangedUserIDs(
        in operations: [GuildMemberListUpdateDTO.Operation]
    ) -> Set<UserID> {
        var userIDs = Set<UserID>()
        for operation in operations {
            if let items = operation.items {
                userIDs.formUnion(items.compactMap { item in
                    item.member.flatMap { UserID($0.user.id) }
                })
            }
            if let item = operation.item,
               let userID = item.member.flatMap({ UserID($0.user.id) })
            {
                userIDs.insert(userID)
            }
        }
        return userIDs
    }

    static func applyMemberListOperation(
        _ operation: GuildMemberListUpdateDTO.Operation,
        to items: inout [GuildMemberListUpdateDTO.Item?],
        keepingInvalidatedRows: Bool = false
    ) {
        switch operation.op {
        case "SYNC":
            applyMemberListSync(operation, to: &items)
        case "INSERT":
            guard let index = operation.index, let item = operation.item else { return }
            items.insert(item, at: min(max(0, index), items.count))
        case "UPDATE":
            guard let index = operation.index, index >= 0, let item = operation.item else { return }
            if items.count <= index {
                items.append(contentsOf: repeatElement(nil, count: index + 1 - items.count))
            }
            items[index] = item
        case "DELETE":
            guard let index = operation.index, items.indices.contains(index) else { return }
            items.remove(at: index)
        case "INVALIDATE":
            // Rows stay only while a resubscribe will bring a fresh SYNC for a
            // list that is still accessible; otherwise clearing them would
            // leave permanent placeholders, but keeping them could leak members
            // after a permission change.
            guard !keepingInvalidatedRows,
                  let range = operation.range, range.count == 2, !items.isEmpty
            else { return }
            let lower = max(0, range[0])
            let upper = min(items.count - 1, range[1])
            guard lower <= upper else { return }
            for index in lower ... upper {
                items[index] = nil
            }
        default:
            return
        }
    }

    private static func applyMemberListSync(
        _ operation: GuildMemberListUpdateDTO.Operation,
        to items: inout [GuildMemberListUpdateDTO.Item?]
    ) {
        guard let range = operation.range, range.count == 2,
              let values = operation.items
        else { return }
        let lower = max(0, range[0])
        let upper = max(lower, range[1])
        if items.count <= upper {
            items.append(contentsOf: repeatElement(nil, count: upper + 1 - items.count))
        }
        // SYNC replaces its declared interval. Discord can return fewer items
        // than the range spans; retained INVALIDATE rows must not survive in
        // that interval's unfilled tail. Other cached ranges remain intact.
        for index in lower ... upper {
            items[index] = nil
        }
        for (offset, value) in values.enumerated() where lower + offset <= upper {
            items[lower + offset] = value
        }
    }

    func applyMemberListOperations(
        _ operations: [GuildMemberListUpdateDTO.Operation],
        guildID: GuildID,
        memberListID: String
    ) {
        var items = memberListState.cachedItems[guildID]?[memberListID] ?? []
        let keepInvalidatedRows = !memberListSubscriptionsForRefresh(
            guildID: guildID, memberListID: memberListID
        ).isEmpty
        for operation in operations {
            Self.applyMemberListOperation(
                operation, to: &items, keepingInvalidatedRows: keepInvalidatedRows
            )
        }
        memberListState.cachedItems[guildID, default: [:]][memberListID] = items
    }

    /// A retained subscription is accessible while its channel is still
    /// viewable by the current user and resolves to the same member list.
    /// INVALIDATE rows are kept only then, while awaiting a replacement SYNC.
    func isMemberListAccessible(
        guildID: GuildID, memberListID: String,
        subscription requestedSubscription: DiscordMemberListSubscription? = nil
    ) -> Bool {
        guard let subscription = requestedSubscription ?? memberListState.subscriptions[guildID]?[memberListID],
              let channel = cachedChannels[guildID]?.first(where: {
                  $0.id == subscription.channelID
              })
        else { return false }
        return canViewMemberListChannel(channel, guildID: guildID)
            && DiscordMemberListIdentity.id(
                for: channel,
                guildID: guildID,
                roles: cachedGuildRoles[guildID] ?? []
            ) == memberListID
    }

    func selectedMemberListGroups(guildID: GuildID) -> [GuildMemberListGroup] {
        guard let memberListID = memberListState.selectedIDs[guildID] else { return [] }
        return memberListState.cachedGroups[guildID]?[memberListID] ?? []
    }
}
