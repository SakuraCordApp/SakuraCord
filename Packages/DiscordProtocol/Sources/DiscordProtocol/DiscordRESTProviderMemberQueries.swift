import Foundation
import SakuraCordModels

public extension DiscordRESTProvider {
    func members(in guildID: GuildID?) async throws -> [Member] {
        guard let guildID else {
            if let previous = pendingMemberGuildID {
                memberListRefreshRetryTasks.removeValue(forKey: previous)?.cancel()
                memberListViewportRestoreTasks.removeValue(forKey: previous)?.cancel()
            }
            pendingMemberGuildID = nil
            return privateMembersInChannelOrder()
        }
        if cachedGuildRoles[guildID] == nil {
            do {
                _ = try await guildRoleDTOs(in: guildID)
            } catch {
                gatewayLogger.warning(
                    "Guild roles unavailable; member categories will use the default group: \(error.localizedDescription, privacy: .public)"
                )
                cachedGuildRoles[guildID] = []
            }
        }
        if let previous = pendingMemberGuildID, previous != guildID {
            memberListRefreshRetryTasks.removeValue(forKey: previous)?.cancel()
            memberListViewportRestoreTasks.removeValue(forKey: previous)?.cancel()
        }
        pendingMemberGuildID = guildID
        gatewayLogger.info("Member list requested; gatewayReady=\(self.gatewayReady)")
        if gatewayReady {
            await attemptMemberSubscription(guildID: guildID)
        }
        discardInaccessibleMemberLists(guildID: guildID)
        guard let memberListID = selectedMemberListID[guildID],
              isMemberListAccessible(guildID: guildID, memberListID: memberListID)
        else { return [] }
        return membersWithCurrentStatus(orderedMemberListMembers(guildID: guildID) ?? cachedMembers[guildID] ?? [])
    }

    func roles(in guildID: GuildID) async throws -> [GuildRole] {
        try await guildRoleDTOs(in: guildID)
            .compactMap(\.domain)
            .sorted { $0.position > $1.position }
    }

    internal func guildRoleDTOs(in guildID: GuildID) async throws -> [GuildRoleDTO] {
        if let cached = cachedGuildRoles[guildID] {
            return cached
        }
        if let task = guildRoleTasks[guildID] {
            return try await task.value
        }
        // The task caches and returns stamped roles, so every caller sharing
        // it gets the same role-style gates.
        let task = Task { [self] in
            let roles: [GuildRoleDTO] = try await request("/guilds/\(guildID)/roles")
            cacheGuildRoles(roles, in: guildID)
            return cachedGuildRoles[guildID] ?? []
        }
        guildRoleTasks[guildID] = task
        do {
            let roles = try await task.value
            guildRoleTasks[guildID] = nil
            return roles
        } catch {
            guildRoleTasks[guildID] = nil
            throw error
        }
    }

    func searchMembers(
        in guildID: GuildID, query: String, limit: Int
    ) async throws -> [Member] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        _ = try await roles(in: guildID)
        guard gatewayReady else {
            throw ChatProviderError.invalidRequest(
                "Discord Gateway is not ready to search guild members.")
        }
        let requestID = UUID().uuidString
        let maximumResults = min(max(1, limit), 100)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Member], any Error>) in
                if let supersededRequestID = pendingMemberSearchRequestByGuild[guildID] {
                    failMemberSearchRequest(
                        requestID: supersededRequestID,
                        error: CancellationError()
                    )
                }
                let timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    await self?.timeoutMemberSearchRequest(requestID: requestID)
                }
                pendingMemberSearchRequests[requestID] = PendingMemberSearchRequest(
                    guildID: guildID,
                    maximumResults: maximumResults,
                    members: [],
                    receivedChunks: [],
                    continuation: continuation,
                    timeoutTask: timeout
                )
                pendingMemberSearchRequestByGuild[guildID] = requestID
                Task { [weak self] in
                    do {
                        try await self?.sendGateway(
                            DiscordGatewayPayloadFactory.searchMembers(
                                guildIDs: [guildID],
                                query: normalized,
                                limit: maximumResults
                            )
                        )
                        gatewayLogger.info(
                            "Sent member autocomplete Gateway request; limit=\(maximumResults)"
                        )
                    } catch {
                        await self?.failMemberSearchRequest(requestID: requestID, error: error)
                    }
                }
            }
        } onCancel: {
            Task {
                await self.failMemberSearchRequest(
                    requestID: requestID,
                    error: CancellationError()
                )
            }
        }
    }

    func requestQuickSwitcherMembers(
        in guildID: GuildID, query: String, limit: Int
    ) async throws {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard gatewayReady else {
            throw ChatProviderError.invalidRequest(
                "Discord Gateway is not ready to search guild members.")
        }
        let maximumResults = min(max(1, limit), 100)
        try await sendGateway(
            DiscordGatewayPayloadFactory.searchMembers(
                guildIDs: [guildID],
                query: normalized.lowercased(),
                limit: maximumResults
            )
        )
        gatewayLogger.info(
            "Sent quick-switcher member Gateway request; limit=\(maximumResults)"
        )
    }

    func members(withRole roleID: RoleID, in guildID: GuildID) async throws
        -> RoleMemberResult
    {
        let ids: [String] = try await request("/guilds/\(guildID)/roles/\(roleID)/member-ids")
        let validIDs = ids.compactMap(UserID.init)
        let maximumDisplayedMembers = 1_000
        let requestedIDs = Array(validIDs.prefix(maximumDisplayedMembers))
        let cachedByID = Dictionary(
            uniqueKeysWithValues: (cachedMembers[guildID] ?? []).map { ($0.id, $0) })
        let missing = requestedIDs.filter { cachedByID[$0] == nil }
        if !missing.isEmpty {
            try await requestMembersByID(missing, guildID: guildID)
        }
        let resolvedByID = Dictionary(
            uniqueKeysWithValues: (cachedMembers[guildID] ?? []).map { ($0.id, $0) })
        return RoleMemberResult(
            members: requestedIDs.compactMap { resolvedByID[$0] },
            totalCount: validIDs.count,
            isTruncated: validIDs.count > maximumDisplayedMembers
        )
    }

    func resolveMembers(in guildID: GuildID, userIDs: [UserID]) async throws -> [Member] {
        var seen: Set<UserID> = []
        let requested = Array(userIDs.filter { seen.insert($0).inserted }.prefix(100))
        guard !requested.isEmpty else { return [] }

        var cachedByID = cachedMemberIndex(guildID: guildID)
        let missing = requested.filter { cachedByID[$0] == nil }
        if !missing.isEmpty {
            try await requestMembersByID(missing, guildID: guildID)
            cachedByID = cachedMemberIndex(guildID: guildID)
        }
        return requested.compactMap { cachedByID[$0] }
    }

    func knownMembers(in guildID: GuildID, userIDs: [UserID]) async -> [Member] {
        let cachedByID = cachedMemberIndex(guildID: guildID)
        return userIDs.compactMap { cachedByID[$0] }
    }

    internal func cachedMemberIndex(guildID: GuildID) -> [UserID: Member] {
        if let cached = cachedMembersByID[guildID] {
            return cached
        }
        let indexed = Dictionary(
            (cachedMembers[guildID] ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        cachedMembersByID[guildID] = indexed
        return indexed
    }

}
