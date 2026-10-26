import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    func handleGatewayGuildEvent(
        name: String,
        body: JSONValue
    ) async -> Bool {
        if handleInboxEventDispatch(name: name, body: body) { return true }
        switch name {
        case "GUILD_DELETE":
            await handleGuildDeleteDispatch(name: name, body: body)
        case "GUILD_CREATE":
            await handleGuildCreateDispatch(name: name, body: body)
        case "GUILD_UPDATE":
            await handleGuildUpdateDispatch(name: name, body: body)
        case "GUILD_EMOJIS_UPDATE":
            await handleGuildEmojisUpdateDispatch(name: name, body: body)
        case "GUILD_ROLE_CREATE", "GUILD_ROLE_UPDATE":
            await handleGuildRoleCreateDispatch(name: name, body: body)
        case "GUILD_ROLE_DELETE":
            await handleGuildRoleDeleteDispatch(name: name, body: body)
        default:
            return false
        }
        return true
    }

    func handleGuildDeleteDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard
            let deleted = try? JSONValueDecoder().decode(
                GatewayDeletedEntityDTO.self, from: body
            ), let guildID = GuildID(deleted.id)
        else { return }
        invalidateApplicationCommandCatalog(.guild(guildID))
        if deleted.unavailable == true {
            if var guild = cachedGuilds[guildID] {
                guild.isUnavailable = true
                cachedGuilds[guildID] = guild
                continuation?.yield(.guildChanged(guild))
            }
        } else {
            removeInboxEvents(in: guildID)
            removeGuild(guildID)
        }
    }

    func handleGuildCreateDispatch(
        name: String,
        body: JSONValue
    ) async {
        let delivery = continuation
        delivery?.beginBatch()
        defer { delivery?.endBatch() }
        applyGuildInboxEvents(body)
        if let patch = try? JSONValueDecoder().decode(GatewayGuildPatchDTO.self, from: body),
           let guildID = GuildID(patch.id),
           var guild = patch.applying(
               to: cachedGuilds[guildID], currentUserID: currentUser?.id
           )
        {
            guild.isUnavailable = false
            cachedGuilds[guildID] = guild
            if !gatewayGuildIDs.contains(guildID) { gatewayGuildIDs.append(guildID) }
            insertGuildIntoRailIfNeeded(guildID)
            publishGuildLayout()
        }
        if let catalog = try? JSONValueDecoder().decode(GatewayGuildCatalogDTO.self, from: body),
           let guildID = GuildID(catalog.id)
        {
            if let channels = catalog.channels {
                appendQuickSwitcherChannelStoreOrder(
                    channels.compactMap { ChannelID($0.id) }
                )
                persistQuickSwitcherChannelStoreCache()
                cachedGuildChannelDTOs[guildID] = ChannelDTOStore(
                    channels.map { ($0.id, $0) },
                    uniquingKeysWith: { _, newer in newer }
                )
                publishGuildChannels(guildID)
            }
            if let roles = catalog.roles {
                cachedGuildRoles[guildID] = roles
                publishGuildRoles(guildID)
            }
            if let threads = catalog.threads, !threads.isEmpty {
                ingestForumThreads(
                    threads,
                    fallbackGuildID: guildID,
                    advancesParentLatestThreadID: true
                )
            }
            if let catalogMembers = catalog.members, !catalogMembers.isEmpty {
                quickSwitcherGuildMemberUserIDsByGuildID[guildID, default: []]
                    .formUnion(catalogMembers.compactMap { UserID($0.user.id) })
                cacheLiveSearchUsers(catalogMembers.map(\.user))
                let guildRoles = cachedGuildRoles[guildID] ?? []
                let guildRoleCatalog = GuildMemberRoleCatalog(guildRoles)
                let previousMembers = cachedMemberIndex(guildID: guildID)
                let members = catalogMembers.compactMap {
                    try? $0.domain(
                        currentUserID: currentUser?.id,
                        currentStatus: presenceStatus,
                        guildRoles: guildRoles,
                        guildRoleCatalog: guildRoleCatalog,
                        guildID: guildID,
                        previousCommunicationDisabledUntil: UserID($0.user.id).flatMap { previousMembers[$0]?.communicationDisabledUntil }
                    )
                }
                cachedMembers[guildID] = DiscordMemberStoreOrdering.merging(
                    existing: cachedMembers[guildID] ?? [], updates: members
                )
                quickSwitcherJoinedMemberIDsByGuildID[guildID, default: []]
                    .formUnion(zip(catalogMembers, members).compactMap { dto, member in
                        dto.joinedAt != nil && dto.pending != true ? member.id : nil
                    })
                publishMembers(
                    guildID: guildID,
                    members: cachedMembers[guildID] ?? [],
                    groups: selectedMemberListGroups(guildID: guildID)
                )
                // Discord's UserSearchContextManager handles GUILD_CREATE
                // by indexing the accompanying members with their guild
                // nicknames. `cacheLiveSearchUsers` publishes newly
                // observed account records, but the nickname index is a
                // separate snapshot and must advance even when every user
                // was already known from READY.
                publishUserSearchAliases()
                scheduleForwardSearchPeopleCachePersistence()
                if let currentUserID = currentUser?.id,
                   let ownMember = members.first(where: { $0.id == currentUserID })
                {
                    continuation?.yield(
                        .currentUserRolesChanged(
                            guildID: guildID, roleIDs: ownMember.roleIDs
                        )
                    )
                }
            }
        }
        if let emojiSnapshot = try? JSONValueDecoder().decode(
            GatewayGuildEmojiSnapshotDTO.self,
            from: body
        ),
            let guildID = GuildID(emojiSnapshot.id),
            let emojis = emojiSnapshot.emojis
        {
            publishEmojiCollection(emojis, guildID: guildID)
        }
        publishInitialGuildVoiceStates(from: body)
    }

    private func publishInitialGuildVoiceStates(from body: JSONValue) {
        if let snapshot = try? JSONValueDecoder().decode(
            GuildVoiceStateSnapshotDTO.self, from: body
        ) {
            let states = snapshot.domainVoiceStates
            gatewayLogger.info(
                "Initial voice-state snapshot received; guild=\(snapshot.id, privacy: .public), count=\(states.count)"
            )
            if !states.isEmpty {
                continuation?.yield(.voiceStatesReceived(states))
            }
        }
    }

    func handleGuildUpdateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard
            let patch = try? JSONValueDecoder().decode(GatewayGuildPatchDTO.self, from: body),
            let guildID = GuildID(patch.id),
            let guild = patch.applying(
                to: cachedGuilds[guildID], currentUserID: currentUser?.id
            )
        else { return }
        cachedGuilds[guildID] = guild
        continuation?.yield(.guildChanged(guild))
        if discardInaccessibleMemberLists(guildID: guildID) {
            publishMembers(guildID: guildID, members: [], groups: [])
        }
    }

    func handleGuildEmojisUpdateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard
            let update = try? JSONValueDecoder().decode(
                GatewayGuildEmojiSnapshotDTO.self,
                from: body
            ),
            let guildID = GuildID(update.id),
            let emojis = update.emojis
        else { return }
        publishEmojiCollection(emojis, guildID: guildID)
    }

    func handleGuildRoleCreateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard
            let update = try? JSONValueDecoder().decode(
                GatewayGuildRoleEventDTO.self, from: body
            ), let guildID = GuildID(update.guildID)
        else { return }
        var roles = cachedGuildRoles[guildID] ?? []
        roles.removeAll { $0.id == update.role.id }
        roles.append(update.role)
        cachedGuildRoles[guildID] = roles
        clearCurrentUserPermissionSnapshot(guildID)
        publishGuildRoles(guildID)
    }

    func handleGuildRoleDeleteDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard
            let deletion = try? JSONValueDecoder().decode(
                GatewayGuildRoleDeleteDTO.self, from: body
            ), let guildID = GuildID(deletion.guildID)
        else { return }
        cachedGuildRoles[guildID]?.removeAll { $0.id == deletion.roleID }
        if let roleID = RoleID(deletion.roleID),
           var members = cachedMembers[guildID]
        {
            for index in members.indices {
                members[index].roleIDs.removeAll { $0 == roleID }
            }
            cachedMembers[guildID] = members
        }
        clearCurrentUserPermissionSnapshot(guildID)
        publishGuildRoles(guildID)
    }
}
