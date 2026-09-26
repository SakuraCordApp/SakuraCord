import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    func makeBootstrapSnapshot(user: User, ready: InitialGatewaySnapshot) -> BootstrapSnapshot {
        let currentGuilds = guildsInCurrentRailOrder()
        let currentGuildsByID = Dictionary(
            uniqueKeysWithValues: currentGuilds.map { ($0.id, $0) }
        )
        var channelGuildIDs = Set<GuildID>()
        let channelGuilds = gatewayGuildIDs.compactMap { guildID -> Guild? in
            guard channelGuildIDs.insert(guildID).inserted else { return nil }
            return cachedGuilds[guildID] ?? currentGuildsByID[guildID]
        } + currentGuilds.filter { channelGuildIDs.insert($0.id).inserted }
        let members = [Member(user: user, roleName: "You", status: presenceStatus)]
        var channelsByID = Dictionary(
            (cachedChannels[nil] ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        for guild in channelGuilds {
            for channel in cachedChannels[guild.id] ?? [] {
                channelsByID[channel.id] = channel
            }
        }
        let startupChannels =
            (cachedChannels[nil] ?? []).compactMap { channelsByID.removeValue(forKey: $0.id) }
                + channelGuilds.flatMap { guild in
                    (cachedChannels[guild.id] ?? []).compactMap {
                        channelsByID.removeValue(forKey: $0.id)
                    }
                }
                + channelsByID.values.sorted { $0.id < $1.id }
        let forumThreadsByID = Dictionary(
            cachedForumPosts.values.flatMap(\.values).map { ($0.id, $0.thread) },
            uniquingKeysWith: { _, newer in newer }
        )
        var remainingForumThreads = forumThreadsByID
        let startupThreads = cachedForumThreadOrder.compactMap {
            remainingForumThreads.removeValue(forKey: $0)
        } + remainingForumThreads.values.sorted { $0.id < $1.id }
        let startupActiveJoinedThreads = currentActiveJoinedThreads()
        let userSearchAliasesByUserID = currentUserSearchAliasesByUserID()
        return BootstrapSnapshot(
            currentUser: user,
            knownUsers: currentKnownUsers(),
            quickSwitcherUserIDs: currentQuickSwitcherUsers().map(\.id),
            messageSearchUsers: currentMessageSearchUsers(),
            messageSearchUserBoosterChannelIDs: Set(
                (cachedChannels[nil] ?? []).lazy
                    .filter {
                        $0.kind == .directMessage
                            && !self.lazyPrivateChannelIDs.contains($0.id)
                    }
                    .map(\.id)
            ),
            friendUserIDs: cachedFriendUserIDs,
            blockedOrIgnoredUserIDs: cachedBlockedOrIgnoredUserIDs,
            relationshipNicknamesByUserID: cachedRelationshipNicknamesByUserID,
            userSearchAliasesByUserID: userSearchAliasesByUserID,
            quickSwitcherGuildMemberUserIDs: currentQuickSwitcherGuildMemberUserIDs(),
            quickSwitcherJoinedGuildMemberUserIDs:
                currentQuickSwitcherJoinedGuildMemberUserIDs(),
            quickSwitcherGuildMemberAliases: currentQuickSwitcherGuildMemberAliases(),
            guilds: currentGuilds,
            guildRailItems: cachedGuildRailItems,
            forwardGuildStoreOrder: gatewayGuildIDs,
            channels: startupChannels,
            forwardChannelStoreOrder: cachedForwardChannelStoreOrder,
            threads: startupThreads,
            activeJoinedThreads: startupActiveJoinedThreads,
            members: members,
            currentMembersByGuildID: cachedMembers.compactMapValues { members in
                members.first { $0.id == user.id }
            },
            readStates: ready.readStates,
            notificationSettings: ready.notificationSettings,
            usesNewNotifications: ready.usesNewNotifications
        )
    }

    func currentActiveJoinedThreads() -> [MessageThreadSummary] {
        var seen = Set<ChannelID>()
        return cachedJoinedThreadOrder.compactMap { threadID in
            guard seen.insert(threadID).inserted,
                  let thread = cachedJoinedThreads[threadID], !thread.isArchived
            else { return nil }
            return thread
        } + cachedJoinedThreads.values
            .filter { !seen.contains($0.id) && !$0.isArchived }
            .sorted { $0.id < $1.id }
    }

    func waitForInitialGatewaySnapshot() async throws -> InitialGatewaySnapshot {
        if let initialGatewaySnapshotResult {
            return try initialGatewaySnapshotResult.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            initialGatewaySnapshotContinuation = continuation
        }
    }

    func finishInitialGatewaySnapshot(_ snapshot: InitialGatewaySnapshot) {
        if case .success? = initialGatewaySnapshotResult, let currentUser {
            // A rejected Resume starts another READY on the same provider.
            // Publish its complete replacement before the following ready event.
            gatewayReady = true
            initialGatewaySnapshotResult = .success(snapshot)
            continuation?.yield(.snapshotChanged(makeBootstrapSnapshot(user: currentUser, ready: snapshot)))
            return
        }
        guard initialGatewaySnapshotResult == nil else { return }
        // GatewaySession emits READY dispatch before its `.ready` state event.
        // Bootstrap resumes here, so immediate channel loads must already be
        // allowed to resolve missing message authors through the Gateway.
        gatewayReady = true
        initialGatewaySnapshotResult = .success(snapshot)
        initialGatewaySnapshotContinuation?.resume(returning: snapshot)
        initialGatewaySnapshotContinuation = nil
    }

    func failInitialGatewaySnapshot(_ error: any Error) {
        guard initialGatewaySnapshotResult == nil else { return }
        initialGatewaySnapshotResult = .failure(error)
        initialGatewaySnapshotContinuation?.resume(throwing: error)
        initialGatewaySnapshotContinuation = nil
    }

    func failInitialGatewaySnapshotOnTerminalDisconnect(_ state: ConnectionState) {
        guard state == .disconnected else { return }
        failInitialGatewaySnapshot(
            ChatProviderError.invalidRequest(
                "Discord's Gateway disconnected before initial state was ready."
            )
        )
    }

    static func applyingGuildLayout(
        _ layout: DiscordGuildLayout,
        to guilds: [Guild]
    ) -> (guilds: [Guild], railItems: [GuildRailItem]) {
        let byID = Dictionary(uniqueKeysWithValues: guilds.map { ($0.id, $0) })
        let folderGuildIDs = layout.folders.flatMap(\.guildIDs)
        let orderedIDs = folderGuildIDs.isEmpty ? layout.guildPositions : folderGuildIDs
        guard !orderedIDs.isEmpty else {
            return (guilds, guilds.map { .guild($0.id) })
        }

        let referenced = Set(orderedIDs)
        let omitted =
            guilds
                .filter { !referenced.contains($0.id) }
                .sorted { $0.id.rawValue > $1.id.rawValue }
        var railItems = omitted.map { GuildRailItem.guild($0.id) }
        var emittedGuildIDs = Set(omitted.map(\.id))
        var emittedFolderIDs: Set<Int64> = []

        if layout.folders.isEmpty {
            for id in layout.guildPositions
                where byID[id] != nil && emittedGuildIDs.insert(id).inserted {
                railItems.append(.guild(id))
            }
        } else {
            for decodedFolder in layout.folders {
                let validIDs = decodedFolder.guildIDs.filter {
                    byID[$0] != nil && !emittedGuildIDs.contains($0)
                }
                emittedGuildIDs.formUnion(validIDs)
                guard !validIDs.isEmpty else { continue }
                if let id = decodedFolder.id, emittedFolderIDs.insert(id).inserted {
                    railItems.append(
                        .folder(
                            GuildFolder(
                                id: id,
                                name: decodedFolder.name,
                                colorHex: decodedFolder.colorHex,
                                guildIDs: validIDs
                            )))
                } else {
                    railItems.append(contentsOf: validIDs.map(GuildRailItem.guild))
                }
            }
        }

        let flattenedIDs = railItems.flatMap { item -> [GuildID] in
            switch item {
            case .guild(let id): [id]
            case .folder(let folder): folder.guildIDs
            }
        }
        let orderedGuilds = flattenedIDs.compactMap { byID[$0] }
        gatewayLogger.info(
            "Applied guild folder settings; folders=\(emittedFolderIDs.count), guilds=\(orderedGuilds.count), omitted=\(omitted.count)"
        )
        return (orderedGuilds, railItems)
    }

    static func applyingGuildOrder(_ orderedIDs: [GuildID], to guilds: [Guild]) -> [Guild] {
        let byID = Dictionary(uniqueKeysWithValues: guilds.map { ($0.id, $0) })
        let ordered = orderedIDs.compactMap { byID[$0] }
        let orderedSet = Set(orderedIDs)
        let omitted =
            guilds
                .filter { !orderedSet.contains($0.id) }
                .sorted { $0.id.rawValue > $1.id.rawValue }
        gatewayLogger.info(
            "Applied guild settings order; ordered=\(ordered.count), omitted=\(omitted.count)"
        )
        // Match Discord/Paicord's unlisted-guild fallback: guilds absent from the
        // folder payload appear first, newest joined/created first. Guild IDs are
        // time-sortable snowflakes and are the bootstrap-safe proxy for join date.
        return omitted + ordered
    }
}

nonisolated struct DiscordInstallationExperimentsDTO: Decodable {
    let installation: String?
}
