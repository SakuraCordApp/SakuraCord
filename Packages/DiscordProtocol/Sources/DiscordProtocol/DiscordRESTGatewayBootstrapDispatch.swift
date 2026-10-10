import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    func handleGatewayBootstrapEvent(
        name: String,
        body: JSONValue
    ) async -> Bool {
        switch name {
        case "READY", "RESUMED":
            await handleReadyDispatch(name: name, body: body)
        case "AUTH_SESSION_CHANGE":
            if case let .object(values) = body,
               case let .string(hash) = values["auth_session_id_hash"] {
                currentAuthSessionIDHash = hash
            }
        case "USER_SETTINGS_PROTO_UPDATE":
            await handleUserSettingsProtoUpdateDispatch(name: name, body: body)
        case "OAUTH2_TOKEN_CREATE", "OAUTH2_TOKEN_DELETE":
            handleProfileWidgetAuthorizationEvent(name: name, body: body)
        case "GUILD_STICKERS_UPDATE":
            await handleGuildStickersUpdateDispatch(name: name, body: body)
        case "USER_GUILD_SETTINGS_UPDATE":
            await handleUserGuildSettingsUpdateDispatch(name: name, body: body)
        case "SOUNDBOARD_SOUNDS":
            await handleSoundboardSoundsDispatch(name: name, body: body)
        case "VOICE_CHANNEL_EFFECT_SEND", "VOICE_EFFECT_SEND":
            await handleVoiceChannelEffectSendDispatch(name: name, body: body)
        case "GUILD_SOUNDBOARD_SOUND_CREATE", "GUILD_SOUNDBOARD_SOUND_UPDATE":
            await handleGuildSoundboardSoundCreateDispatch(name: name, body: body)
        case "GUILD_SOUNDBOARD_SOUND_DELETE":
            await handleGuildSoundboardSoundDeleteDispatch(name: name, body: body)
        case "READY_SUPPLEMENTAL":
            await handleReadySupplementalDispatch(name: name, body: body)
        default:
            return false
        }
        return true
    }

    func handleReadyDispatch(
        name: String,
        body: JSONValue
    ) async {
        subscribedPrivateCallChannelIDs = []
        let readyDecode = discordPerformanceSignposter.beginInterval(
            "GatewayReadyDecode",
            id: discordPerformanceSignposter.makeSignpostID()
        )
        let ready = name == "READY"
            ? try? JSONValueDecoder().decode(GatewayReadyGuildsDTO.self, from: body)
            : nil
        discordPerformanceSignposter.endInterval("GatewayReadyDecode", readyDecode)
        guard let ready else {
            // Deliberately unlike the official client, a resumed session also
            // saves a pending status edit instead of waiting for a new READY.
            if name == "RESUMED" { schedulePendingStatusEditSave() }
            if name == "READY" {
                failInitialGatewaySnapshot(
                    ChatProviderError.invalidRequest(
                        "Discord's initial Gateway state could not be decoded."
                    )
                )
            }
            return
        }
        let interval = discordPerformanceSignposter.beginInterval(
            "GatewayReadyApplication",
            id: discordPerformanceSignposter.makeSignpostID()
        )
        defer {
            discordPerformanceSignposter.endInterval(
                "GatewayReadyApplication", interval
            )
        }
        await resetReadySessionState(for: ready)
        // No suspension while collecting the events from this READY payload.
        let delivery = continuation
        delivery?.beginBatch()
        defer { delivery?.endBatch() }
        let account = try? JSONValueDecoder().decode(DiscordAccountReadyDTO.self, from: body)
        accountInformationRevision = UUID()
        currentAccountDetails = account?.user?.domain()
        currentAuthSessionIDHash = account?.authSessionIDHash
        // Self members built below, the bootstrap snapshot, and the
        // post-READY opcode 3 all read the account-wide status, or a pending
        // edit that READY must not replace first.
        reconcilePendingStatusEdit(readySettings: ready.userSettingsProto)
        // Its custom status is published once the member projection exists.
        applyProfileSettingsProto(ready.userSettingsProto, isPartial: false)
        schedulePendingStatusEditSave()
        let metadata = applyReadyUserAndReadState(ready)
        applyReadyPrivateChannels(ready)
        let guildProjection = applyReadyGuildProjection(ready)
        applyReadyInboxEvents(body)
        finishReadyApplication(
            ready,
            readStates: metadata.readStates,
            notificationSettings: metadata.notificationSettings,
            voiceStateCount: guildProjection.voiceStateCount,
            currentUserRolesByGuild: guildProjection.currentUserRolesByGuild
        )
    }

    private func resetReadySessionState(
        for ready: GatewayReadyGuildsDTO
    ) async {
        privateCallsByChannel = [:]
        cancelPendingRoleMemberRequests(error: CancellationError())
        cachedMembers = [:]
        cachedThreadMemberIDs = [:]
        for (guildID, threadIDs) in threadMemberSubscriptions {
            for threadID in threadIDs {
                continuation?.yield(.threadMembersChanged(guildID: guildID, threadID: threadID, members: nil))
            }
        }
        quickSwitcherGuildMemberUserIDsByGuildID = [:]
        quickSwitcherJoinedMemberIDsByGuildID = [:]
        cachedMemberListItems = [:]
        cachedMemberListGroups = [:]
        selectedMemberListID = [:]
        memberListSubscriptions = [:]
        memberListsNeedingRefresh = [:]
        memberListSubscriptionOrder = [:]
        cachedGuildChannelDTOs = [:]
        cachedGuildRoles = [:]
        cachedStickersByGuild = [:]
        cachedForumPosts = [:]
        cachedForumThreadOrder = []
        cachedJoinedThreads = [:]
        cachedJoinedThreadOrder = []
        gatewayOpcodeRateLimitDates = [:]
        requestedHistoryMemberIDs = [:]
        resolvingHistoryMemberIDs = [:]
        cachedPrivateMembersByID = [:]
        cachedPrivateRecipientIDsByChannelID = [:]
        cachedGatewayUsersByID = [:]
        cachedGatewayUserOrder = []
        cachedGatewayUserIDs = []
        messageSearchUserIDs = []
        messageSearchUserOrder = []
        lazyPrivateChannelIDs = []
        forwardSearchEligibleUserIDs = []
        forwardSearchEligibleUserOrder = []
        await loadStartupSearchCaches()
        cachedBlockedOrIgnoredUserIDs = ready.blockedOrIgnoredUserIDs
        cachedRelationshipNicknamesByUserID = ready.relationshipNicknamesByUserID
        profileApexAssignments = ready.apexExperiments
        resetProfileEditingState()
    }

    private func applyReadyUserAndReadState(
        _ ready: GatewayReadyGuildsDTO
    ) -> (
        readStates: [ChannelReadState],
        notificationSettings: [GuildNotificationSettings]
    ) {
        if let userDTO = ready.currentUser {
            cacheGatewayUser(userDTO)
            if let user = try? userDTO.domain() {
                currentUser = user
            }
        }
        for user in ready.users {
            cacheGatewayUser(user)
        }
        forumReadStates = ready.readState.channelEntriesByID.mapValues { entry in
            ForumReadState(
                lastReadMessageID: entry.lastMessageID.flatMap(MessageID.init),
                mentionCount: entry.mentionCount ?? 0
            )
        }
        var seenReadStateChannelIDs: Set<ChannelID> = []
        let latestReadStateByChannelID = ready.readState.channelEntriesByID
        let readyReadStates: [ChannelReadState] =
            ready.readState.entries.compactMap { sourceEntry in
                guard sourceEntry.readStateType == 0,
                      let channelID = ChannelID(sourceEntry.id),
                      seenReadStateChannelIDs.insert(channelID).inserted,
                      let entry = latestReadStateByChannelID[channelID]
                else { return nil }
                return ChannelReadState(
                    channelID: channelID,
                    lastAcknowledgedMessageID: entry.lastMessageID.flatMap(MessageID.init),
                    mentionCount: entry.mentionCount ?? 0,
                    flags: entry.flags,
                    lastViewed: entry.lastViewed,
                    version: ready.readState.version
                )
            }
        if !ready.userGuildSettingsPartial {
            cachedGuildNotificationSettings.removeAll(keepingCapacity: true)
        }
        let readyNotificationSettings = ready.userGuildSettings.map { update in
            let guildID = update.guildID.flatMap(GuildID.init)
            let settings = update.domain(
                merging: cachedGuildNotificationSettings[guildID]
            )
            cachedGuildNotificationSettings[guildID] = settings
            return settings
        }
        let guildAllUnreadSettingCount = readyNotificationSettings.count {
            $0.flags & (1 << 11) != 0
        }
        let guildMentionOnlyUnreadSettingCount = readyNotificationSettings.count {
            $0.flags & (1 << 12) != 0
        }
        let guildOptInCount = readyNotificationSettings.count {
            $0.flags & (1 << 14) != 0
        }
        let channelOverrides = readyNotificationSettings.flatMap(\.channelOverrides)
        let channelAllUnreadSettingCount = channelOverrides.count {
            $0.flags & (1 << 10) != 0
        }
        let channelMentionOnlyUnreadSettingCount = channelOverrides.count {
            $0.flags & (1 << 9) != 0
        }
        let channelOptInCount = channelOverrides.count {
            $0.flags & (1 << 12) != 0
        }
        gatewayLogger.info(
            """
            Ready unread metadata decoded; readStates=\(readyReadStates.count), \
            guildSettings=\(readyNotificationSettings.count), \
            guildSettingsPartial=\(ready.userGuildSettingsPartial), \
            newNotifications=\(ready.usesNewNotifications), \
            guildAll=\(guildAllUnreadSettingCount), \
            guildMentions=\(guildMentionOnlyUnreadSettingCount), \
            guildOptIn=\(guildOptInCount), \
            channelOverrides=\(channelOverrides.count), \
            channelAll=\(channelAllUnreadSettingCount), \
            channelMentions=\(channelMentionOnlyUnreadSettingCount), \
            channelOptIn=\(channelOptInCount)
            """
        )
        // READY is the source that completes `bootstrap()`. Publishing
        // its account-wide read metadata here as incremental events
        // makes the app apply the same state once per guild before it
        // immediately applies the complete BootstrapSnapshot again.
        // Subsequent Gateway updates still use their incremental
        // ClientEvent cases below.
        return (readyReadStates, cachedGuildNotificationSettings.values.sorted {
            ($0.guildID?.rawValue ?? 0) < ($1.guildID?.rawValue ?? 0)
        })
    }

    private func applyReadyPrivateChannels(
        _ ready: GatewayReadyGuildsDTO
    ) {
        cachePrivateRecipientReferences(ready.privateChannels)
        let privateChannels = Self.orderedPrivateChannels(
            ready.privateChannels.enumerated().compactMap { offset, dto in
                guard var channel = try? privateChannel(from: dto) else { return nil }
                // Discord's forwarding search preserves the private
                // channel store's source order for equal-score GDMs,
                // even though the DM sidebar is ordered by activity.
                channel.position = offset
                return channel
            }
        )
        cachedChannels = [nil: privateChannels]
        cachedFriendUserIDs = ready.friendUserIDs
        for presence in ready.privatePresences {
            cachePrivatePresence(presence)
        }
        continuation?.yield(.privateMembersChanged(privateMembersInChannelOrder()))
    }

    private func applyReadyGuildProjection(
        _ ready: GatewayReadyGuildsDTO
    ) -> (
        voiceStateCount: Int,
        currentUserRolesByGuild: [GuildID: [RoleID]]
    ) {
        let readyGuilds = ready.hydratedGuilds(using: cachedGatewayUsersByID)
        let readyChannelStoreOrder = readyGuilds.flatMap { guild in
            guild.channels.compactMap { ChannelID($0.id) }
        }
        reconcileQuickSwitcherChannelStoreOrder(with: readyChannelStoreOrder)
        persistQuickSwitcherChannelStoreCache()
        gatewayGuildIDs = readyGuilds.compactMap { GuildID($0.id) }
        for (index, guildID) in gatewayGuildIDs.enumerated()
            where ready.mergedMembers.indices.contains(index)
        {
            // READY's aligned merged-member batch replaces the
            // persisted GuildMemberStore projection for that guild.
            // Unioning retained users who have since left makes `@`
            // queries diverge until a remove event happens to arrive
            // in this process lifetime.
            quickSwitcherGuildMemberUserIDsByGuildID[guildID] = Set(
                ready.mergedMembers[index].compactMap { UserID($0.userID) }
            )
            quickSwitcherJoinedMemberIDsByGuildID[guildID] =
                Set(ready.mergedMembers[index].compactMap { member in
                    guard member.joinedAt != nil, member.pending != true else { return nil }
                    return UserID(member.userID)
                })
        }
        let guilds = readyGuilds.compactMap {
            $0.domain(currentUserID: currentUser?.id)
        }
        cachedGuilds = Dictionary(
            uniqueKeysWithValues: guilds.map { ($0.id, $0) }
        )
        cachedGuildRailItems = guilds.map { .guild($0.id) }
        var voiceStates: [VoiceParticipantState] = []
        var currentUserRolesByGuild: [GuildID: [RoleID]] = [:]
        for guild in readyGuilds {
            let guildID = GuildID(guild.id)
            if let guildID {
                applyGuildRulesChannelID(guild.rulesChannelID, guildID: guildID)
            }
            if let guildID, !guild.channels.isEmpty {
                cachedGuildChannelDTOs[guildID] = ChannelDTOStore(
                    guild.channels.map { ($0.id, $0) },
                    uniquingKeysWith: { _, newer in newer }
                )
                if let channels = try? Self.domainChannels(
                    guild.channels, guildID: guildID
                ) {
                    cachedChannels[guildID] = channels
                }
            }
            if let guildID, !guild.roles.isEmpty {
                cachedGuildRoles[guildID] = guild.roles
                publishGuildRoles(guildID)
            }
            if !guild.threads.isEmpty {
                ingestForumThreads(
                    guild.threads,
                    fallbackGuildID: guildID,
                    advancesParentLatestThreadID: true
                )
            }
            if let guildID, !guild.members.isEmpty {
                let guildRoles = cachedGuildRoles[guildID] ?? []
                let guildRoleCatalog = GuildMemberRoleCatalog(guildRoles)
                let members = guild.members.compactMap {
                    try? $0.domain(
                        currentUserID: currentUser?.id,
                        currentStatus: presenceStatus,
                        guildRoles: guildRoles,
                        guildRoleCatalog: guildRoleCatalog,
                        guildID: guildID
                    )
                }
                cachedMembers[guildID] = DiscordMemberStoreOrdering.merging(
                    existing: cachedMembers[guildID] ?? [], updates: members
                )
                if let currentUserID = currentUser?.id,
                   let currentMember = members.first(where: { $0.id == currentUserID })
                {
                    currentUserRolesByGuild[guildID] = currentMember.roles.map(\.id)
                }
            }
            if let guildID, let emojis = guild.emojis {
                publishEmojiCollection(emojis, guildID: guildID)
            }
            if let guildID {
                let stickers = guild.stickers
                    .map { $0.domain(guildID: guildID) }
                    .filter(\.isAvailable)
                cachedStickersByGuild[guildID] = stickers
                continuation?.yield(
                    .stickersChanged(guildID: guildID, stickers: stickers)
                )
            }
            for state in guild.voiceStates {
                guard let participant = state.domain(defaultGuildID: guildID) else {
                    continue
                }
                voiceStates.append(participant)
            }
        }
        if !voiceStates.isEmpty {
            continuation?.yield(.voiceStatesReceived(voiceStates))
        }
        return (voiceStates.count, currentUserRolesByGuild)
    }

    private func finishReadyApplication(
        _ ready: GatewayReadyGuildsDTO,
        readStates: [ChannelReadState],
        notificationSettings: [GuildNotificationSettings],
        voiceStateCount: Int,
        currentUserRolesByGuild: [GuildID: [RoleID]]
    ) {
        // READY replaces the complete session projection. Publish an
        // empty snapshot too so a fresh session cannot retain roles
        // learned from an earlier READY payload.
        continuation?.yield(
            .currentUserRolesSnapshot(currentUserRolesByGuild)
        )
        if voiceStateCount > 0 {
            gatewayLogger.info(
                "Ready voice-state snapshot received; count=\(voiceStateCount)")
        }
        applyGuildSettingsProto(ready.userSettingsProto, replacesAllSettings: true)
        publishProfileCustomStatus()
        applyInboxSettingsProto(ready.userSettingsProto, isPartial: false)
        finishInitialGatewaySnapshot(
            InitialGatewaySnapshot(
                readStates: readStates,
                notificationSettings: notificationSettings,
                usesNewNotifications: ready.usesNewNotifications
            )
        )
    }

    func handleUserSettingsProtoUpdateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let update = try? JSONValueDecoder().decode(
            GatewayUserSettingsProtoUpdateDTO.self,
            from: body
        ) else { return }
        switch update.settings.type {
        case 1:
            await applyUserSettingsProto(update.settings.proto, isPartial: update.partial == true)
        case 2:
            await applyFrecencySettingsProtoUpdate(
                update.settings.proto,
                isPartial: update.partial == true
            )
        default:
            return
        }
    }

    /// Applies type-1 PreloadedUserSettings from a Gateway update or a
    /// settings reload. A changed account status sends one opcode 3.
    func applyUserSettingsProto(_ encoded: String?, isPartial: Bool) async {
        applyInboxSettingsProto(encoded, isPartial: isPartial)
        if applyProfileSettingsProto(encoded, isPartial: isPartial) { publishProfileCustomStatus() }
        applyGuildSettingsProto(encoded, replacesAllSettings: !isPartial)
        await sendPresenceIfChanged()
    }

    func handleGuildStickersUpdateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let update = try? JSONValueDecoder().decode(
            GatewayGuildStickersUpdateDTO.self,
            from: body
        ), let guildID = GuildID(update.guildID) else { return }
        let stickers = update.stickers
            .map { $0.domain(guildID: guildID) }
            .filter(\.isAvailable)
        cachedStickersByGuild[guildID] = stickers
        continuation?.yield(.stickersChanged(guildID: guildID, stickers: stickers))
    }

    func handleUserGuildSettingsUpdateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let update = try? JSONValueDecoder().decode(
            GatewayUserGuildSettingsDTO.self, from: body
        ) else { return }
        let guildID = update.guildID.flatMap(GuildID.init)
        let settings = update.domain(
            merging: cachedGuildNotificationSettings[guildID]
        )
        cachedGuildNotificationSettings[guildID] = settings
        continuation?.yield(.notificationSettingsChanged(settings))
    }

    func handleSoundboardSoundsDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let update = try? JSONValueDecoder().decode(
            GatewaySoundboardSoundsDTO.self,
            from: body
        ) else { return }
        applySoundboardSounds(update)
    }

    func handleVoiceChannelEffectSendDispatch(
        name: String,
        body: JSONValue
    ) async {
        let decoded: VoiceChannelEffectDTO
        do {
            decoded = try JSONValueDecoder().decode(
                VoiceChannelEffectDTO.self,
                from: body
            )
        } catch {
            gatewayLogger.error(
                "Voice channel effect could not be decoded"
            )
            return
        }
        guard let effect = decoded.domain else {
            gatewayLogger.error("Voice channel effect contained invalid identifiers")
            return
        }
        continuation?.yield(.voiceChannelEffect(effect))
    }

    func handleGuildSoundboardSoundCreateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let sound = try? JSONValueDecoder().decode(
            GatewaySoundboardSoundEventDTO.self,
            from: body
        ).domain else { return }
        upsertSoundboardSound(sound)
    }

    func handleGuildSoundboardSoundDeleteDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let deletion = try? JSONValueDecoder().decode(
            GatewaySoundboardSoundDeleteDTO.self,
            from: body
        ), let guildID = GuildID(deletion.guildID) else { return }
        deleteSoundboardSound(guildID: guildID, soundID: deletion.soundID)
    }

    func handleReadySupplementalDispatch(
        name: String,
        body: JSONValue
    ) async {
        let delivery = continuation
        delivery?.beginBatch()
        defer { delivery?.endBatch() }
        if let supplemental = try? JSONValueDecoder().decode(
            GatewayReadyGuildsDTO.self, from: body
        ) {
            cacheReadySupplementalPrivateState(supplemental)
            applyReadySupplementalGuildProjection(supplemental)
            publishReadySupplementalAliases(supplemental)
        }
        let states = ReadySupplementalVoiceStateResolver.resolve(
            body: body,
            gatewayGuildIDs: gatewayGuildIDs
        )
        if !states.isEmpty {
            continuation?.yield(.voiceStatesReceived(states))
        }
        gatewayLogger.info("Supplemental voice-state snapshot received; count=\(states.count)")
    }

    private func cacheReadySupplementalPrivateState(
        _ supplemental: GatewayReadyGuildsDTO
    ) {
        let supplementalMemberUserIDs = Set(
            supplemental.mergedMembers.flatMap { members in
                members.compactMap { UserID($0.userID) }
            }
        )
        for user in supplemental.users {
            cacheGatewayUser(
                user,
                forwardSearchEligible: UserID(user.id).map {
                    supplementalMemberUserIDs.contains($0)
                } ?? false,
                includeInKnownUserStore: false
            )
        }
        cachePrivateRecipientReferences(supplemental.lazyPrivateChannels)
        cacheLazyPrivateRecipientUsers(supplemental.lazyPrivateChannels)
        for presence in supplemental.privatePresences {
            cachePrivatePresence(presence)
        }
        if !supplemental.lazyPrivateChannels.isEmpty {
            var channels = cachedChannels[nil] ?? []
            var indexByID = Dictionary(
                uniqueKeysWithValues: channels.enumerated().map {
                    ($0.element.id, $0.offset)
                }
            )
            var nextSourceOrder = (channels.lazy.map(\.position).max() ?? -1) + 1
            for var channel in supplemental.lazyPrivateChannels.compactMap({
                try? privateChannel(from: $0)
            }) {
                if let index = indexByID[channel.id] {
                    channel.position = channels[index].position
                    channels[index] = channel
                } else {
                    channel.position = nextSourceOrder
                    nextSourceOrder += 1
                    indexByID[channel.id] = channels.count
                    channels.append(channel)
                    lazyPrivateChannelIDs.insert(channel.id)
                }
            }
            channels = Self.orderedPrivateChannels(channels)
            cachedChannels[nil] = channels
            continuation?.yield(
                .channelsChanged(guildID: nil, channels: channels)
            )
        }
        rehydratePrivateChannelRecipients()
        admitCachedPrivateRecipientUsersToMessageSearch()
        if !supplemental.lazyPrivateChannels.isEmpty
            || !supplemental.privatePresences.isEmpty
        {
            continuation?.yield(.privateMembersChanged(privateMembersInChannelOrder()))
        }
    }

    private func applyReadySupplementalGuildProjection(
        _ supplemental: GatewayReadyGuildsDTO
    ) {
        let hydratedGuilds = supplemental.hydratedGuilds(using: cachedGatewayUsersByID)
        // READY_SUPPLEMENTAL's parallel merged arrays retain READY's
        // guild ordering; they are not keyed by the supplemental
        // guild objects. This is the same mapping used by its merged
        // voice-state projection.
        for (index, guildID) in gatewayGuildIDs.enumerated()
            where supplemental.mergedMembers.indices.contains(index)
        {
            quickSwitcherGuildMemberUserIDsByGuildID[guildID, default: []]
                .formUnion(supplemental.mergedMembers[index].compactMap {
                    UserID($0.userID)
                })
            quickSwitcherJoinedMemberIDsByGuildID[guildID, default: []]
                .formUnion(supplemental.mergedMembers[index].compactMap { member in
                    guard member.joinedAt != nil, member.pending != true else { return nil }
                    return UserID(member.userID)
                })
        }
        for guild in hydratedGuilds {
            guard let guildID = GuildID(guild.id) else { continue }
            for member in guild.members {
                // UserStore's CONNECTION_OPEN_SUPPLEMENTAL handler only
                // updates an existing record's primary-guild badge for
                // hydrated guild members. It does not admit a new user.
                cacheGatewayUser(member.user, messageSearchEligible: false)
            }
            if !guild.channels.isEmpty {
                cachedGuildChannelDTOs[guildID] = ChannelDTOStore(
                    guild.channels.map { ($0.id, $0) },
                    uniquingKeysWith: { _, newer in newer }
                )
                publishGuildChannels(guildID)
            }
            if !guild.roles.isEmpty {
                cachedGuildRoles[guildID] = guild.roles
                publishGuildRoles(guildID)
            }
            if !guild.threads.isEmpty {
                // CONNECTION_OPEN_SUPPLEMENTAL extends ChannelStore
                // after READY. These active threads participate in
                // message-search channel autocomplete in payload order.
                ingestForumThreads(
                    guild.threads,
                    fallbackGuildID: guildID,
                    advancesParentLatestThreadID: true
                )
            }
            guard !guild.members.isEmpty else { continue }
            let guildRoles = cachedGuildRoles[guildID] ?? []
            let guildRoleCatalog = GuildMemberRoleCatalog(guildRoles)
            let members = guild.members.compactMap {
                try? $0.domain(
                    currentUserID: currentUser?.id,
                    currentStatus: presenceStatus,
                    guildRoles: guildRoles,
                    guildRoleCatalog: guildRoleCatalog,
                    guildID: guildID
                )
            }
            cachedMembers[guildID] = DiscordMemberStoreOrdering.merging(
                existing: cachedMembers[guildID] ?? [], updates: members
            )
            if let currentUserID = currentUser?.id,
               let currentMember = members.first(where: { $0.id == currentUserID })
            {
                continuation?.yield(.currentUserRolesChanged(
                    guildID: guildID,
                    roleIDs: currentMember.roles.map(\.id)
                ))
            }
        }
    }

    private func publishReadySupplementalAliases(
        _ supplemental: GatewayReadyGuildsDTO
    ) {
        let hydratedGuilds = supplemental.hydratedGuilds(
            using: cachedGatewayUsersByID
        )
        for guild in hydratedGuilds {
            guard let guildID = GuildID(guild.id) else { continue }
            for participant in guild.activityInstances.flatMap(\.participants) {
                guard let member = participant.member else { continue }
                cacheGatewayUser(member.user, messageSearchEligible: false)
                if let userID = UserID(member.user.id),
                   let nickname = member.nick?.trimmingCharacters(
                       in: .whitespacesAndNewlines
                   ), !nickname.isEmpty
                {
                    if cachedForwardSearchAliasesByGuildID[guildID] == nil {
                        cachedForwardSearchAliasGuildOrder.append(guildID)
                    }
                    cachedForwardSearchAliasesByGuildID[guildID, default: [:]][userID] =
                        nickname
                }
            }
        }
        continuation?.yield(.knownUsersChanged(currentKnownUsers()))
        continuation?.yield(
            .quickSwitcherUserIDsChanged(currentQuickSwitcherUsers().map(\.id))
        )
        continuation?.yield(
            .messageSearchUsersChanged(currentMessageSearchUsers())
        )
        publishUserSearchAliases()
        scheduleForwardSearchPeopleCachePersistence()
    }
}
