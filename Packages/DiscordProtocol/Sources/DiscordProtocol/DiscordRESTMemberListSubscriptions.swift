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
                  selectedMemberListID[guildID] == memberListID
            else { return }
            let viewport = memberListState.memberListViewportRequests[guildID]
            let requested = viewport?.memberListID == memberListID ? viewport?.subscription : nil
            guard let current = requested ?? memberListState.memberListSubscriptions[guildID]?[memberListID]
            else { return }
            if isDeferred {
                guard memberListState.memberListsNeedingRefresh[guildID]?[memberListID] != nil,
                      memberListRefreshRetryAttempts[guildID]?.contains(memberListID) != true,
                      isMemberListAccessible(guildID: guildID, memberListID: memberListID, subscription: current)
                else { return }
                // A newer cooldown can arrive while this refresh waits in the
                // guild queue. A local refusal must not spend its wire attempt.
                if let cooldown = gatewayOpcodeRateLimitDates[37], cooldown > Date.now {
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
            let accessible = (memberListState.memberListSubscriptions[guildID] ?? [:]).filter {
                isMemberListAccessible(guildID: guildID, memberListID: $0.key)
            }
            let hadCommittedSubscription = accessible[memberListID] != nil
            let state = DiscordMemberListRangePolicy.subscriptionState(
                selecting: memberListID, channelID: channelID, ranges: ranges,
                currentSubscriptions: accessible,
                currentOrder: (memberListState.memberListSubscriptionOrder[guildID] ?? []).filter {
                    accessible[$0] != nil
                }
            )
            let refresh = memberListState.memberListsNeedingRefresh[guildID]?[memberListID]
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
            memberListState.memberListSubscriptionOrder[guildID] = state.memberListOrder
            memberListState.memberListSubscriptions[guildID] = state.subscriptionsByMemberListID
            if let refresh, memberListState.memberListsNeedingRefresh[guildID]?[memberListID] == refresh {
                memberListState.memberListsNeedingRefresh[guildID]?[memberListID] = nil
                memberListRefreshRetryTasks.removeValue(forKey: guildID)?.cancel()
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
               selectedMemberListID[guildID] == memberListID,
               cachedMemberListItems[guildID]?[memberListID] != nil {
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
        memberListState.memberListsNeedingRefresh[guildID, default: [:]][memberListID] = UUID()
    }

    /// One deferred attempt per invalidation, only for a selected list and a
    /// known opcode cooldown. Further failure awaits a user action or reconnect.
    func scheduleMemberListRefreshRetry(guildID: GuildID) {
        // Waiting timers do not consume the attempt budget. Selection can
        // cancel one before it runs, then return during the same cooldown.
        guard gatewayReady, pendingMemberGuildID == guildID,
              let memberListID = selectedMemberListID[guildID],
              let refresh = memberListState.memberListsNeedingRefresh[guildID]?[memberListID],
              !memberListSubscriptionsForRefresh(guildID: guildID, memberListID: memberListID).isEmpty,
              let cooldown = gatewayOpcodeRateLimitDates[37], cooldown > Date.now,
              memberListRefreshRetryAttempts[guildID]?.contains(memberListID) != true
        else { return }
        memberListRefreshRetryTasks[guildID]?.cancel()
        memberListRefreshRetryTasks[guildID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, cooldown.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            await self?.retryMemberListRefresh(
                guildID: guildID, memberListID: memberListID, refresh: refresh
            )
        }
    }

    func retryMemberListRefresh(guildID: GuildID, memberListID: String, refresh: UUID) async {
        guard pendingMemberGuildID == guildID,
              selectedMemberListID[guildID] == memberListID,
              memberListState.memberListsNeedingRefresh[guildID]?[memberListID] == refresh,
              memberListRefreshRetryAttempts[guildID]?.contains(memberListID) != true
        else { return }
        memberListRefreshRetryTasks[guildID] = nil
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
        ).union(memberListRefreshRetryTasks.keys).union(memberListViewportRestoreTasks.keys)
            .union(threadMemberSubscriptionRequestIDs.keys))
        for guildID in guildIDs {
            if !preservingThreadRequests { threadMemberSubscriptionRequestIDs[guildID] = nil }
            guildSubscriptionGenerations[guildID] = nil
            memberListInFlightRequests[guildID] = nil
            guildSubscriptionTasks.removeValue(forKey: guildID)?.cancel()
            guildSubscriptionTaskIDs[guildID] = nil
            memberListRefreshRetryTasks.removeValue(forKey: guildID)?.cancel()
            memberListViewportRestoreTasks.removeValue(forKey: guildID)?.cancel()
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
    /// Recovery covers committed ranges, the latest viewport, and an active
    /// send whose viewport selection has changed. Publication still requires
    /// a committed subscription through isMemberListAccessible's default lookup.
    func memberListSubscriptionsForRefresh(
        guildID: GuildID, memberListID: String
    ) -> [DiscordMemberListSubscription] {
        var subscriptions = memberListState.memberListSubscriptions[guildID]?[memberListID].map { [$0] } ?? []
        if let viewport = memberListState.memberListViewportRequests[guildID], viewport.memberListID == memberListID {
            subscriptions.append(viewport.subscription)
        }
        if let inFlight = memberListInFlightRequests[guildID], inFlight.memberListID == memberListID {
            subscriptions.append(inFlight.subscription)
        }
        return subscriptions.filter {
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
        let viewport = memberListState.memberListViewportRequests[guildID]
        let inFlight = memberListInFlightRequests[guildID]
        var memberListIDs = Set(memberListState.memberListSubscriptions[guildID].map { Array($0.keys) } ?? [])
        if let viewport { memberListIDs.insert(viewport.memberListID) }
        if let inFlight { memberListIDs.insert(inFlight.memberListID) }
        for memberListID in memberListIDs {
            // A first subscription may still be in flight. Its requested
            // channel must lose its rows and send generation on access loss,
            // even before there is a committed subscription to discard.
            let requested = memberListState.memberListViewportRequests[guildID].flatMap {
                $0.memberListID == memberListID ? $0.subscription : nil
            }
            let subscriptions = [
                memberListState.memberListSubscriptions[guildID]?[memberListID], requested,
                inFlight.flatMap { $0.memberListID == memberListID ? $0.subscription : nil },
            ].compactMap { $0 }
            guard subscriptions.contains(where: {
                !isMemberListAccessible(guildID: guildID, memberListID: memberListID, subscription: $0)
            }) else { continue }
            discardedSubscription = true
            cachedMemberListItems[guildID]?[memberListID] = nil
            cachedMemberListGroups[guildID]?[memberListID] = nil
            memberListState.memberListSubscriptions[guildID]?[memberListID] = nil
            memberListState.memberListSubscriptionOrder[guildID]?.removeAll { $0 == memberListID }
            memberListState.memberListsNeedingRefresh[guildID]?[memberListID] = nil
            memberListRefreshRetryAttempts[guildID]?.remove(memberListID)
            if selectedMemberListID[guildID] == memberListID {
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
                    selectedMemberListID[guildID] = currentListID
                    memberListState.memberListViewportRequests[guildID] = (currentListID, requested)
                } else {
                    memberListState.memberListViewportRequests[guildID] = nil
                }
                memberListRefreshRetryTasks.removeValue(forKey: guildID)?.cancel()
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
               let current = memberListState.memberListViewportRequests[guildID],
               selectedMemberListID[guildID] == current.memberListID,
               isMemberListAccessible(
                   guildID: guildID, memberListID: current.memberListID,
                   subscription: current.subscription
               ) {
                let generation = UUID()
                guildSubscriptionGenerations[guildID] = generation
                memberListViewportRestoreTasks[guildID] = Task { [weak self] in
                    await self?.restoreSelectedMemberListViewport(guildID: guildID, generation: generation)
                }
            }
        }
        return selectedWasDiscarded
    }

    func restoreSelectedMemberListViewport(guildID: GuildID, generation: UUID) async {
        defer {
            if guildSubscriptionGenerations[guildID] == generation {
                memberListViewportRestoreTasks[guildID] = nil
            }
        }
        // One restore attempt waits out an already-known cooldown, including
        // a desired viewport whose first subscription has not committed.
        if let cooldown = gatewayOpcodeRateLimitDates[37], cooldown > Date.now {
            try? await Task.sleep(for: .seconds(max(0, cooldown.timeIntervalSinceNow)))
        }
        guard !Task.isCancelled, gatewayReady, guildSubscriptionGenerations[guildID] == generation,
              pendingMemberGuildID == guildID,
              let viewport = memberListState.memberListViewportRequests[guildID],
              selectedMemberListID[guildID] == viewport.memberListID,
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
    var memberListSubscriptions: [GuildID: [String: DiscordMemberListSubscription]] = [:]
    var memberListSubscriptionOrder: [GuildID: [String]] = [:]
    /// The selected viewport can move while a cooldown prevents committing it.
    var memberListViewportRequests:
        [GuildID: (memberListID: String, subscription: DiscordMemberListSubscription)] = [:]
    /// Retained member lists whose subscribed ranges were invalidated and
    /// still need a subscription send to get a fresh SYNC.
    var memberListsNeedingRefresh: [GuildID: [String: UUID]] = [:]
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
        if selectedMemberListID[guildID] != memberListID {
            memberListRefreshRetryTasks.removeValue(forKey: guildID)?.cancel()
            memberListViewportRestoreTasks.removeValue(forKey: guildID)?.cancel()
        }
        selectedMemberListID[guildID] = memberListID
        memberListState.memberListViewportRequests[guildID] = (
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
        let viewport = restoringViewport ? memberListState.memberListViewportRequests[guildID]?.subscription : nil
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
        let changedSelection = selectedMemberListID[guildID] != memberListID
        selectedMemberListID[guildID] = memberListID
        memberListState.memberListViewportRequests[guildID] = (
            memberListID, DiscordMemberListSubscription(channelID: channelID, ranges: ranges)
        )
        if changedSelection {
            memberListRefreshRetryTasks.removeValue(forKey: guildID)?.cancel()
            memberListViewportRestoreTasks.removeValue(forKey: guildID)?.cancel()
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
                groups: cachedMemberListGroups[guildID]?[memberListID] ?? []
            )
        }
        let needsRefresh = memberListState.memberListsNeedingRefresh[guildID]?[memberListID] != nil
        if !needsRefresh,
           !DiscordMemberListRangePolicy.requiresSubscriptionUpdate(
               memberListID: memberListID,
               ranges: ranges,
               currentSubscriptions: memberListState.memberListSubscriptions[guildID] ?? [:]
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
