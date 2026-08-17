import Foundation

// Gateway lifecycle and transport recovery share stateful invariants that are
// safest to audit in one extension-oriented source file.
// swiftlint:disable file_length
import SakuraCordModels

extension DiscordRESTProvider {
    public func joinVoice(
        channelID: ChannelID,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool
    ) async throws -> VoiceConnectionInfo {
        guard gatewayReady, let userID = currentUser?.id else {
            throw ChatProviderError.invalidRequest(
                "Discord Gateway is not ready for a voice connection.")
        }
        let negotiationID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let pendingVoiceNegotiation {
                    pendingVoiceNegotiation.continuation.resume(
                        throwing: ChatProviderError.invalidRequest(
                            "A newer voice connection replaced this request."
                        )
                    )
                }
                pendingVoiceNegotiation = PendingVoiceNegotiation(
                    id: negotiationID,
                    channelID: channelID,
                    guildID: guildID,
                    userID: userID,
                    selfMute: selfMute,
                    selfDeaf: selfDeaf,
                    continuation: continuation
                )
                voiceNegotiationTimeoutTask?.cancel()
                voiceNegotiationTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    await self?.failVoiceNegotiation(
                        id: negotiationID,
                        error: ChatProviderError.invalidRequest(
                            "Discord did not finish voice negotiation in time."
                        )
                    )
                }
                Task { [weak self] in
                    do {
                        try await self?.sendVoiceState(
                            channelID: channelID,
                            guildID: guildID,
                            selfMute: selfMute,
                            selfDeaf: selfDeaf,
                            selfVideo: false
                        )
                    } catch {
                        await self?.failVoiceNegotiation(id: negotiationID, error: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.failVoiceNegotiation(id: negotiationID, error: CancellationError()) }
        }
    }

    public func updateVoiceState(
        channelID: ChannelID?,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool,
        selfVideo: Bool
    ) async throws {
        try await sendVoiceState(
            channelID: channelID,
            guildID: guildID,
            selfMute: selfMute,
            selfDeaf: selfDeaf,
            selfVideo: selfVideo
        )
        if channelID == nil {
            activeVoiceConnection = nil
        }
    }

    public func subscribeToPrivateCall(channelID: ChannelID) async throws {
        guard gatewayReady else {
            throw ChatProviderError.invalidRequest(
                "Discord Gateway is not ready to observe this private call.")
        }
        guard subscribedPrivateCallChannelIDs.insert(channelID).inserted else { return }
        do {
            try await sendGateway(
                DiscordGatewayPayloadFactory.privateCallConnect(channelID: channelID)
            )
        } catch {
            subscribedPrivateCallChannelIDs.remove(channelID)
            throw error
        }
    }

    public func privateCallIsRingable(channelID: ChannelID) async throws -> Bool {
        let response: PrivateCallEligibilityDTO = try await request(
            "/channels/\(channelID)/call")
        return response.ringable
    }

    public func ringPrivateCall(channelID: ChannelID, recipients: [UserID]?) async throws {
        // Discord creates the call through the voice Gateway transition first.
        // Wait only for that pushed state; never probe or retry the mutation.
        try await waitForPrivateCall(channelID: channelID)
        try await requestEmpty(
            "/channels/\(channelID)/call/ring",
            method: "POST",
            body: [
                "recipients": recipients.map {
                    .array($0.map { .string($0.description) })
                } ?? .null
            ]
        )
    }

    public func stopRingingPrivateCall(channelID: ChannelID, recipients: [UserID]) async throws {
        guard !recipients.isEmpty else {
            throw ChatProviderError.invalidRequest(
                "Stopping a private-call ring requires at least one recipient.")
        }
        try await requestEmpty(
            "/channels/\(channelID)/call/stop-ringing",
            method: "POST",
            body: [
                "recipients": .array(recipients.map { .string($0.description) })
            ]
        )
    }

    func waitForPrivateCall(channelID: ChannelID) async throws {
        for _ in 0 ..< 50 {
            if privateCallsByChannel[channelID] != nil { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ChatProviderError.invalidRequest(
            "Discord did not create the private call before ringing timed out.")
    }

    func sendVoiceState(
        channelID: ChannelID?,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool,
        selfVideo: Bool
    ) async throws {
        try await sendGateway(
            DiscordGatewayPayloadFactory.voiceStateUpdate(
                guildID: guildID,
                channelID: channelID,
                selfMute: selfMute,
                selfDeaf: selfDeaf,
                selfVideo: selfVideo
            )
        )
    }

    public func eventStream() async -> AsyncStream<ClientEvent> {
        let stream = AsyncStream<ClientEvent>.makeStream(bufferingPolicy: .bufferingNewest(500))
        continuation = stream.continuation
        return stream.stream
    }

    public func disconnect() async {
        requestSafetyCircuitIsOpen = true
        cancelStartupSearchCacheLoad()
        await flushForwardSearchPeopleCachePersistence()
        failInitialGatewaySnapshot(CancellationError())
        for task in forumCatalogueTasks.values {
            task.cancel()
        }
        forumCatalogueTasks = [:]
        forumCatalogueTaskIDs = [:]
        for task in messageSendTasks.values {
            task.cancel()
        }
        messageSendTasks = [:]
        for task in forumPreviewHydrationTasks.values {
            task.cancel()
        }
        forumPreviewHydrationTasks = [:]
        forumPreviewHydrationTaskIDs = [:]
        forumPreviewHydrationQueues = [:]
        for task in applicationCommandCatalogTasks.values {
            task.cancel()
        }
        applicationCommandCatalogTasks = [:]
        cachedApplicationCommandCatalogs = [:]
        cancelPendingInteractionRequests()
        cancelPendingMemberRequests(error: CancellationError())
        requestedHistoryMemberIDs = [:]
        resolvingHistoryMemberIDs = [:]
        voiceNegotiationTimeoutTask?.cancel()
        if let pendingVoiceNegotiation {
            pendingVoiceNegotiation.continuation.resume(throwing: CancellationError())
            self.pendingVoiceNegotiation = nil
        }
        activeVoiceConnection = nil
        gatewayEventTask?.cancel()
        gatewayEventTask = nil
        await gatewaySession?.stop()
        gatewaySession = nil
        gatewayReady = false
        restSession.getAllTasks { tasks in
            for task in tasks {
                task.cancel()
            }
        }
        continuation?.yield(.connectionChanged(.disconnected))
        continuation?.finish()
        continuation = nil
        authorizationValue = nil
    }

    func startGateway() async throws {
        guard gatewaySession == nil else { return }
        initialGatewaySnapshotResult = nil
        let token = try await authorizationToken()
        let baseline = DiscordProductionBaseline.august2026
        let identifyEnvelope = GatewayEnvelope(
            op: 2,
            data: .object([
                "token": .string(token),
                // Bit 15 asks Ready Supplemental to carry prioritized private
                // channels separately. Both the ordinary and lazy lists flow
                // through the same recipient hydration, ordering, and Gateway
                // reconciliation path below.
                "capabilities": .number(
                    Double(baseline.privateChannelObfuscationCapabilities)
                ),
                "properties": .object(clientMetadata.gatewayProperties()),
                "client_state": .object(["guild_versions": .object([:])]),
            ])
        )
        let identifyData = try gatewayCodec.encode(identifyEnvelope)
        guard let gatewayURL = URL(string: "wss://gateway.discord.gg") else {
            throw ChatProviderError.invalidRequest("Discord's Gateway URL is invalid.")
        }
        let gateway = GatewaySession(
            configuration: GatewaySession.Configuration(
                gatewayURL: gatewayURL,
                identifyPayload: identifyData,
                token: token,
                gatewayEncoding: gatewayEncoding,
                gatewayCompression: gatewayCompression,
                heartbeatSession: usesDesktopHeartbeat
                    ? clientMetadata.currentHeartbeatSession() : nil,
                clientLaunchID: usesDesktopHeartbeat
                    ? clientMetadata.gatewayClientLaunchID : nil,
                qosActive: clientAppState == "focused",
                qosVersion: baseline.qosHeartbeatVersion
            ),
            transport: gatewayTransport,
            codec: gatewayCodec,
            apiDiagnostics: apiDiagnostics
        )
        gatewaySession = gateway
        gatewayEventTask = Task { [weak self, events = gateway.events] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handleGatewaySessionEvent(event)
            }
        }
        await gateway.connect()
        guard gatewaySession === gateway, !requestSafetyCircuitIsOpen else {
            await gateway.stop()
            throw CancellationError()
        }
    }

    func handleGatewaySessionEvent(_ event: GatewaySessionEvent) async {
        switch event {
        case .stateChanged(let connectionState):
            gatewayReady = connectionState == .ready
            if connectionState == .authenticationFailed {
                failInitialGatewaySnapshot(ChatProviderError.unauthenticated)
                await openSafetyCircuit(
                    status: 401, discordCode: nil, route: "GATEWAY IDENTIFY/RESUME")
                return
            }
            failInitialGatewaySnapshotOnTerminalDisconnect(connectionState)
            continuation?.yield(.connectionChanged(connectionState))
            if connectionState == .ready {
                gatewayLogger.info("Gateway session ready")
                if usesDesktopHeartbeat {
                    do {
                        try await sendGateway(
                            DiscordGatewayPayloadFactory.voiceStateUpdate(
                                guildID: nil,
                                channelID: nil,
                                selfMute: false,
                                selfDeaf: false,
                                selfVideo: false
                            )
                        )
                        try await sendGateway([
                            "op": 3,
                            "d": [
                                "since": 0,
                                "activities": [],
                                "status": presenceStatus.rawValue,
                                "afk": false,
                            ] as [String: Any],
                        ])
                        try await gatewaySession?.announceDesktopSession()
                    } catch {
                        gatewayLogger.error(
                            "Desktop Gateway session synchronization failed: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
                if let pendingMemberGuildID {
                    await attemptMemberSubscription(guildID: pendingMemberGuildID)
                }
            }
        case .dispatch(let name, let value):
            await handleGatewayDispatch(name: name, body: value)
        }
    }

    func subscribeToMemberList(
        guildID: GuildID,
        channelID requestedChannelID: ChannelID? = nil,
        ranges: [ClosedRange<Int>] = [0 ... 99]
    ) async throws {
        let channel = cachedChannels[guildID]?.first(where: { $0.kind != .voice })
        let selectedChannel = requestedChannelID.flatMap { requestedID in
            cachedChannels[guildID]?.first(where: { $0.id == requestedID })
        } ?? channel
        let subscriptionState = selectedChannel.map { channel in
            let memberListID = DiscordMemberListIdentity.id(
                for: channel,
                guildID: guildID,
                roles: cachedGuildRoles[guildID] ?? []
            )
            selectedMemberListID[guildID] = memberListID
            return DiscordMemberListRangePolicy.subscriptionState(
                selecting: memberListID,
                channelID: channel.id,
                ranges: ranges,
                currentSubscriptions: memberListSubscriptions[guildID] ?? [:],
                currentOrder: memberListSubscriptionOrder[guildID] ?? []
            )
        }
        try await sendGateway(
            DiscordGatewayPayloadFactory.guildSubscriptions(
                guildID: guildID,
                channelRanges: subscriptionState?.rangesByChannel ?? [:]
            )
        )
        if let subscriptionState {
            memberListSubscriptionOrder[guildID] = subscriptionState.memberListOrder
            memberListSubscriptions[guildID] =
                subscriptionState.subscriptionsByMemberListID
        }
        gatewayLogger.info(
            "Sent current bulk guild subscription; member-list ranges=\(ranges.count)"
        )
    }

    func attemptMemberSubscription(guildID: GuildID) async {
        do { try await subscribeToMemberList(guildID: guildID) } catch {
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
        if changedSelection {
            continuation?.yield(
                .membersChanged(
                    guildID: guildID,
                    members: orderedMemberListMembers(
                        guildID: guildID, memberListID: memberListID
                    ) ?? [],
                    groups: cachedMemberListGroups[guildID]?[memberListID] ?? []
                )
            )
        }
        if !DiscordMemberListRangePolicy.requiresSubscriptionUpdate(
            memberListID: memberListID,
            ranges: ranges,
            currentSubscriptions: memberListSubscriptions[guildID] ?? [:]
        ) {
            return
        }
        try await subscribeToMemberList(
            guildID: guildID,
            channelID: channelID,
            ranges: ranges
        )
    }

    func sendGateway(_ payload: [String: Any]) async throws {
        guard let gatewaySession else {
            throw ChatProviderError.invalidRequest("Discord Gateway is not connected yet.")
        }
        if let opcode = payload["op"] as? Int,
           let cooldown = gatewayOpcodeRateLimitDates[opcode], cooldown > Date()
        {
            throw ChatProviderError.invalidRequest(
                "Discord is temporarily rate limiting Gateway opcode \(opcode)."
            )
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await gatewaySession.send(data)
    }

    func requestMembersByID(_ userIDs: [UserID], guildID: GuildID) async throws {
        guard gatewayReady else {
            throw ChatProviderError.invalidRequest(
                "Discord Gateway is not ready to resolve role members.")
        }
        let resolution = discordPerformanceSignposter.beginInterval(
            "GatewayMemberResolution",
            id: discordPerformanceSignposter.makeSignpostID()
        )
        defer {
            discordPerformanceSignposter.endInterval(
                "GatewayMemberResolution", resolution
            )
        }
        let batches = userIDs.chunked(into: 100)
        let resolvedBatches = try await withThrowingTaskGroup(
            of: (Int, [Member]).self,
            returning: [[Member]].self
        ) { group in
            for (index, batch) in batches.enumerated() {
                group.addTask { [self] in
                    let members = try await requestMemberBatch(batch, guildID: guildID)
                    return (index, members)
                }
            }
            var results = [[Member]?](repeating: nil, count: batches.count)
            for try await (index, members) in group {
                results[index] = members
            }
            return results.compactMap(\.self)
        }
        for members in resolvedBatches {
            mergeResolvedMembers(members, guildID: guildID)
        }
    }

    func requestMemberBatch(_ batch: [UserID], guildID: GuildID) async throws -> [Member] {
            let batchRequest = discordPerformanceSignposter.beginInterval(
                "GatewayMemberBatchRequest",
                id: discordPerformanceSignposter.makeSignpostID()
            )
            defer {
                discordPerformanceSignposter.endInterval(
                    "GatewayMemberBatchRequest", batchRequest
                )
            }
            // Local continuation identity only; this value is never sent to Discord.
            let requestID = UUID().uuidString.lowercased()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Member], any Error>) in
                let timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    await self?.timeoutRoleMemberRequest(requestID: requestID)
                }
                pendingRoleMemberRequests[requestID] = PendingRoleMemberRequest(
                    guildID: guildID,
                    requestedUserIDs: Set(batch),
                    members: [],
                    receivedChunks: [],
                    continuation: continuation,
                    timeoutTask: timeout
                )
                Task { [weak self] in
                    do {
                        try await self?.sendGateway(
                            DiscordGatewayPayloadFactory.requestMembers(
                                guildID: guildID,
                                userIDs: batch
                            )
                        )
                    } catch {
                        await self?.failRoleMemberRequest(requestID: requestID, error: error)
                    }
                }
            }
    }

    func mergeResolvedMembers(
        _ members: [Member], guildID: GuildID,
        joinedUserIDs: Set<UserID>? = nil
    ) {
        cachedMembers[guildID] = DiscordMemberStoreOrdering.merging(
            existing: cachedMembers[guildID] ?? [], updates: members
        )
        if let joinedUserIDs {
            quickSwitcherJoinedMemberIDsByGuildID[guildID, default: []]
                .subtract(members.map(\.id))
            quickSwitcherJoinedMemberIDsByGuildID[guildID, default: []]
                .formUnion(joinedUserIDs)
        } else {
            quickSwitcherJoinedMemberIDsByGuildID[guildID, default: []]
                .formUnion(members.lazy.filter { $0.isPending != true }.map(\.id))
        }
    }

    func pendingRoleMemberRequestID(
        guildID: GuildID,
        responseUserIDs: Set<UserID>
    ) -> String? {
        DiscordMemberChunkRouting.pendingRequestID(
            guildID: guildID,
            responseUserIDs: responseUserIDs,
            requests: pendingRoleMemberRequests.map {
                DiscordPendingMemberRequestDescriptor(
                    id: $0.key,
                    guildID: $0.value.guildID,
                    requestedUserIDs: $0.value.requestedUserIDs
                )
            }
        )
    }

    func timeoutRoleMemberRequest(requestID: String) {
        guard let request = pendingRoleMemberRequests.removeValue(forKey: requestID) else { return }
        request.continuation.resume(
            throwing: ChatProviderError.invalidRequest(
                "Discord did not finish resolving role members.")
        )
    }

    func timeoutMemberSearchRequest(requestID: String) {
        guard let request = removeMemberSearchRequest(requestID: requestID) else { return }
        gatewayLogger.warning("Member autocomplete Gateway request timed out")
        request.continuation.resume(
            throwing: ChatProviderError.invalidRequest(
                "Discord did not finish searching guild members.")
        )
    }

    func failMemberSearchRequest(requestID: String, error: any Error) {
        guard let request = removeMemberSearchRequest(requestID: requestID) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: error)
    }

    func removeMemberSearchRequest(requestID: String) -> PendingMemberSearchRequest? {
        guard let request = pendingMemberSearchRequests.removeValue(forKey: requestID) else {
            return nil
        }
        if pendingMemberSearchRequestByGuild[request.guildID] == requestID {
            pendingMemberSearchRequestByGuild[request.guildID] = nil
        }
        return request
    }

    func failRoleMemberRequest(requestID: String, error: any Error) {
        guard let request = pendingRoleMemberRequests.removeValue(forKey: requestID) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: error)
    }

    func cancelPendingRoleMemberRequests(error: any Error) {
        let requests = Array(pendingRoleMemberRequests.values)
        pendingRoleMemberRequests = [:]
        for request in requests {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    func cancelPendingMemberRequests(error: any Error) {
        let searches = Array(pendingMemberSearchRequests.values)
        pendingMemberSearchRequests = [:]
        pendingMemberSearchRequestByGuild = [:]
        for search in searches {
            search.timeoutTask.cancel()
            search.continuation.resume(throwing: error)
        }
        cancelPendingRoleMemberRequests(error: error)
    }

    func cancelPendingInteractionRequests() {
        for task in autocompleteTimeoutTasks.values {
            task.cancel()
        }
        autocompleteTimeoutTasks = [:]
        pendingAutocompleteTypes = [:]
        pendingModalContexts = [:]
    }

    func publishEmojiCollection(
        _ collection: GatewayGuildEmojiCollectionDTO,
        guildID: GuildID
    ) {
        switch collection.content {
        case .snapshot(let emojis):
            continuation?.yield(
                .emojisChanged(
                    guildID: guildID,
                    emojis: emojis.compactMap { $0.domain(guildID: guildID) }
                )
            )
        case .update(let writes, let deletes):
            continuation?.yield(
                .emojisUpdated(
                    guildID: guildID,
                    upserted: writes.compactMap { $0.domain(guildID: guildID) },
                    deletedIDs: deletes
                )
            )
        }
    }

    func applyGuildRulesChannelID(_ rawRulesChannelID: String?, guildID: GuildID) {
        guard var guild = cachedGuilds[guildID] else { return }
        let rulesChannelID = rawRulesChannelID.flatMap(ChannelID.init)
        guard guild.rulesChannelID != rulesChannelID else { return }
        guild.rulesChannelID = rulesChannelID
        cachedGuilds[guildID] = guild
        continuation?.yield(.guildChanged(guild))
    }

    var gatewayDispatchOperation:
        @isolated(any) (String, JSONValue) async -> Void
    {
        { [self] name, body in
        let data: Data
        if name == "READY" || name == "RESUMED" {
            data = Data()
        } else {
            let serialization = discordPerformanceSignposter.beginInterval(
                "GatewayDispatchJSONSerialization",
                id: discordPerformanceSignposter.makeSignpostID()
            )
            guard let encoded = try? JSONEncoder().encode(body) else {
                discordPerformanceSignposter.endInterval(
                    "GatewayDispatchJSONSerialization", serialization
                )
                return
            }
            discordPerformanceSignposter.endInterval(
                "GatewayDispatchJSONSerialization", serialization
            )
            data = encoded
        }
        switch name {
        case "READY", "RESUMED":
            subscribedPrivateCallChannelIDs = []
            let readyDecode = discordPerformanceSignposter.beginInterval(
                "GatewayReadyDecode",
                id: discordPerformanceSignposter.makeSignpostID()
            )
            let decodedReady = name == "READY"
                ? try? JSONValueDecoder().decode(GatewayReadyGuildsDTO.self, from: body)
                : nil
            discordPerformanceSignposter.endInterval("GatewayReadyDecode", readyDecode)
            if let ready = decodedReady {
                let readyApplication = discordPerformanceSignposter.beginInterval(
                    "GatewayReadyApplication",
                    id: discordPerformanceSignposter.makeSignpostID()
                )
                defer {
                    discordPerformanceSignposter.endInterval(
                        "GatewayReadyApplication", readyApplication
                    )
                }
                privateCallsByChannel = [:]
                cancelPendingRoleMemberRequests(error: CancellationError())
                cachedMembers = [:]
                quickSwitcherGuildMemberUserIDsByGuildID = [:]
                quickSwitcherJoinedMemberIDsByGuildID = [:]
                cachedMemberListItems = [:]
                cachedMemberListGroups = [:]
                selectedMemberListID = [:]
                memberListSubscriptions = [:]
                memberListSubscriptionOrder = [:]
                cachedGuildChannelDTOs = [:]
                cachedGuildRoles = [:]
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
                cachePrivateRecipientReferences(ready.privateChannels)
                let privateChannels = Self.orderedPrivateChannels(
                    ready.privateChannels.enumerated().compactMap { offset, dto in
                        guard var channel = try? dto.domain(
                            guildID: nil,
                            knownUsersByID: cachedGatewayUsersByID
                        ) else { return nil }
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
                var voiceStateCount = 0
                var currentUserRolesByGuild: [GuildID: [RoleID]] = [:]
                for guild in readyGuilds {
                    let guildID = GuildID(guild.id)
                    if let guildID {
                        applyGuildRulesChannelID(guild.rulesChannelID, guildID: guildID)
                    }
                    if let guildID, !guild.channels.isEmpty {
                        cachedGuildChannelDTOs[guildID] = Dictionary(
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
                        let members = guild.members.compactMap {
                            try? $0.domain(
                                currentUserID: currentUser?.id,
                                currentStatus: presenceStatus,
                                guildRoles: cachedGuildRoles[guildID] ?? [],
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
                    for state in guild.voiceStates {
                        guard let participant = state.domain(defaultGuildID: guildID) else {
                            continue
                        }
                        voiceStateCount += 1
                        continuation?.yield(.voiceStateChanged(participant))
                    }
                }
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
                applyGuildSettingsProto(ready.userSettingsProto)
                finishInitialGatewaySnapshot(
                    InitialGatewaySnapshot(
                        readStates: readyReadStates,
                        notificationSettings: readyNotificationSettings,
                        usesNewNotifications: ready.usesNewNotifications
                    )
                )
            } else if name == "READY" {
                failInitialGatewaySnapshot(
                    ChatProviderError.invalidRequest(
                        "Discord's initial Gateway state could not be decoded."
                    )
                )
            }
        case "USER_SETTINGS_PROTO_UPDATE":
            guard
                let update = try? JSONDecoder().decode(
                    GatewayUserSettingsProtoUpdateDTO.self,
                    from: data
                ), update.settings.type == 1
            else { return }
            applyGuildSettingsProto(
                update.settings.proto,
                replacesAllSettings: update.partial != true
            )
        case "USER_GUILD_SETTINGS_UPDATE":
            guard let update = try? JSONDecoder().decode(
                GatewayUserGuildSettingsDTO.self, from: data
            ) else { return }
            let guildID = update.guildID.flatMap(GuildID.init)
            let settings = update.domain(
                merging: cachedGuildNotificationSettings[guildID]
            )
            cachedGuildNotificationSettings[guildID] = settings
            continuation?.yield(.notificationSettingsChanged(settings))
        case "READY_SUPPLEMENTAL":
            if let supplemental = try? JSONDecoder().decode(
                GatewayReadyGuildsDTO.self, from: data
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
                        try? $0.domain(
                            guildID: nil,
                            knownUsersByID: cachedGatewayUsersByID
                        )
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
                        cachedGuildChannelDTOs[guildID] = Dictionary(
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
                    let members = guild.members.compactMap {
                        try? $0.domain(
                            currentUserID: currentUser?.id,
                            currentStatus: presenceStatus,
                            guildRoles: cachedGuildRoles[guildID] ?? [],
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
            let states = ReadySupplementalVoiceStateResolver.resolve(
                data: data,
                gatewayGuildIDs: gatewayGuildIDs
            )
            for state in states {
                continuation?.yield(.voiceStateChanged(state))
            }
            gatewayLogger.info("Supplemental voice-state snapshot received; count=\(states.count)")
        case "GUILD_CREATE":
            if let patch = try? JSONDecoder().decode(GatewayGuildPatchDTO.self, from: data),
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
            if let catalog = try? JSONDecoder().decode(GatewayGuildCatalogDTO.self, from: data),
               let guildID = GuildID(catalog.id)
            {
                if let channels = catalog.channels {
                    appendQuickSwitcherChannelStoreOrder(
                        channels.compactMap { ChannelID($0.id) }
                    )
                    persistQuickSwitcherChannelStoreCache()
                    cachedGuildChannelDTOs[guildID] = Dictionary(
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
                    let members = catalogMembers.compactMap {
                        try? $0.domain(
                            currentUserID: currentUser?.id,
                            currentStatus: presenceStatus,
                            guildRoles: cachedGuildRoles[guildID] ?? [],
                            guildID: guildID
                        )
                    }
                    cachedMembers[guildID] = DiscordMemberStoreOrdering.merging(
                        existing: cachedMembers[guildID] ?? [], updates: members
                    )
                    quickSwitcherJoinedMemberIDsByGuildID[guildID, default: []]
                        .formUnion(zip(catalogMembers, members).compactMap { dto, member in
                            dto.joinedAt != nil && dto.pending != true ? member.id : nil
                        })
                    continuation?.yield(
                        .membersChanged(
                            guildID: guildID,
                            members: cachedMembers[guildID] ?? [],
                            groups: selectedMemberListGroups(guildID: guildID)
                        )
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
            if let emojiSnapshot = try? JSONDecoder().decode(
                GatewayGuildEmojiSnapshotDTO.self,
                from: data
            ),
                let guildID = GuildID(emojiSnapshot.id),
                let emojis = emojiSnapshot.emojis
            {
                publishEmojiCollection(emojis, guildID: guildID)
            }
            if let snapshot = try? JSONDecoder().decode(
                GuildVoiceStateSnapshotDTO.self, from: data
            ) {
                let states = snapshot.domainVoiceStates
                gatewayLogger.info(
                    "Initial voice-state snapshot received; guild=\(snapshot.id, privacy: .public), count=\(states.count)"
                )
                for state in states {
                    continuation?.yield(.voiceStateChanged(state))
                }
            }
        case "GUILD_UPDATE":
            guard
                let patch = try? JSONDecoder().decode(GatewayGuildPatchDTO.self, from: data),
                let guildID = GuildID(patch.id),
                let guild = patch.applying(
                    to: cachedGuilds[guildID], currentUserID: currentUser?.id
                )
            else { return }
            cachedGuilds[guildID] = guild
            continuation?.yield(.guildChanged(guild))
        case "GUILD_EMOJIS_UPDATE":
            guard
                let update = try? JSONDecoder().decode(
                    GatewayGuildEmojiSnapshotDTO.self,
                    from: data
                ),
                let guildID = GuildID(update.id),
                let emojis = update.emojis
            else { return }
            publishEmojiCollection(emojis, guildID: guildID)
        case "GUILD_ROLE_CREATE", "GUILD_ROLE_UPDATE":
            guard
                let update = try? JSONDecoder().decode(
                    GatewayGuildRoleEventDTO.self, from: data
                ), let guildID = GuildID(update.guildID)
            else { return }
            var roles = cachedGuildRoles[guildID] ?? []
            roles.removeAll { $0.id == update.role.id }
            roles.append(update.role)
            cachedGuildRoles[guildID] = roles
            clearCurrentUserPermissionSnapshot(guildID)
            publishGuildRoles(guildID)
        case "GUILD_ROLE_DELETE":
            guard
                let deletion = try? JSONDecoder().decode(
                    GatewayGuildRoleDeleteDTO.self, from: data
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
        case "GUILD_MEMBER_ADD", "GUILD_MEMBER_UPDATE":
            guard
                let update = try? JSONDecoder().decode(
                    GatewayGuildMemberEventDTO.self, from: data
                ), let guildID = GuildID(update.guildID),
                let member = try? update.member.domain(
                    currentUserID: currentUser?.id,
                    currentStatus: presenceStatus,
                    guildRoles: cachedGuildRoles[guildID] ?? [],
                    guildID: guildID
                )
            else { return }
            quickSwitcherGuildMemberUserIDsByGuildID[guildID, default: []].insert(member.id)
            if update.member.joinedAt != nil, member.isPending != true {
                quickSwitcherJoinedMemberIDsByGuildID[guildID, default: []]
                    .insert(member.id)
            } else {
                quickSwitcherJoinedMemberIDsByGuildID[guildID]?.remove(member.id)
            }
            cacheLiveSearchUsers([update.member.user])
            publishMemberChange(member, guildID: guildID)
            publishUserSearchAliases()
            scheduleForwardSearchPeopleCachePersistence()
        case "GUILD_MEMBER_REMOVE":
            guard
                let deletion = try? JSONDecoder().decode(
                    GatewayGuildMemberRemoveDTO.self, from: data
                ), let guildID = GuildID(deletion.guildID),
                let userID = UserID(deletion.user.id)
            else { return }
            quickSwitcherGuildMemberUserIDsByGuildID[guildID]?.remove(userID)
            quickSwitcherJoinedMemberIDsByGuildID[guildID]?.remove(userID)
            removeMember(userID: userID, guildID: guildID)
            publishUserSearchAliases()
            scheduleForwardSearchPeopleCachePersistence()
        case "USER_UPDATE":
            guard let dto = try? JSONDecoder().decode(UserDTO.self, from: data),
                  let user = try? dto.domain()
            else { return }
            applyUserUpdate(dto: dto, user: user)
        case "MESSAGE_CREATE":
            if let dto = try? JSONDecoder().decode(MessageDTO.self, from: data),
               let message = try? dto.domain()
            {
                cacheMessageSearchUsers(dto.searchIndexUsers)
                cacheForwardSearchMessageAliases([message])
                cachedMessages[message.id] = message
                continuation?.yield(.messageCreated(message))
                promotePrivateChannel(
                    channelID: message.channelID,
                    lastMessageID: message.id
                )
                updateForumPostForMessage(message, marksUnread: true)
            }
        case "THREAD_CREATE":
            guard let dto = try? JSONDecoder().decode(ChannelDTO.self, from: data) else { return }
            ingestForumThreads(
                [dto],
                fallbackGuildID: dto.guildID.flatMap(GuildID.init),
                advancesParentLatestThreadID: true
            )
        case "THREAD_UPDATE":
            guard let dto = try? JSONDecoder().decode(ChannelDTO.self, from: data) else { return }
            ingestForumThreads([dto], fallbackGuildID: dto.guildID.flatMap(GuildID.init))
        case "THREAD_DELETE":
            guard let deleted = try? JSONDecoder().decode(GatewayThreadDeleteDTO.self, from: data),
                  let threadID = ChannelID(deleted.id),
                  let parentID = deleted.parentID.flatMap(ChannelID.init)
            else { return }
            cachedForumPosts[parentID]?[threadID] = nil
            cachedForumThreadOrder.removeAll { $0 == threadID }
            cachedJoinedThreads[threadID] = nil
            cachedJoinedThreadOrder.removeAll { $0 == threadID }
            publishForumPosts(parentID: parentID)
            publishActiveJoinedThreads()
        case "THREAD_MEMBER_UPDATE":
            guard
                let member = try? JSONDecoder().decode(ThreadMemberDTO.self, from: data),
                member.userID == nil || member.userID.flatMap(UserID.init) == currentUser?.id,
                let rawThreadID = member.id,
                let threadID = ChannelID(rawThreadID)
            else { return }
            for (parentID, posts) in cachedForumPosts where posts[threadID] != nil {
                cachedForumPosts[parentID]?[threadID]?.thread.notificationSettings =
                    member.domain
                if let thread = cachedForumPosts[parentID]?[threadID]?.thread {
                    reconcileJoinedThread(thread)
                }
                publishForumPosts(parentID: parentID)
                publishActiveJoinedThreads()
                break
            }
        case "THREAD_MEMBERS_UPDATE":
            guard
                let update = try? JSONDecoder().decode(
                    GatewayThreadMembersUpdateDTO.self, from: data
                ), let threadID = ChannelID(update.id)
            else { return }
            for parentID in cachedForumPosts.keys.sorted(by: {
                $0.rawValue < $1.rawValue
            }) where cachedForumPosts[parentID]?[threadID] != nil {
                cachedForumPosts[parentID]?[threadID]?.thread.memberCount =
                    update.memberCount
                if let ownMember = update.addedMembers?.first(where: {
                    $0.userID.flatMap(UserID.init) == currentUser?.id
                }) {
                    cachedForumPosts[parentID]?[threadID]?.thread.notificationSettings =
                        ownMember.domain
                    if let thread = cachedForumPosts[parentID]?[threadID]?.thread {
                        reconcileJoinedThread(thread)
                    }
                } else if update.removedMemberIDs?.contains(
                    currentUser?.id.description ?? ""
                ) == true {
                    cachedForumPosts[parentID]?[threadID]?.thread.notificationSettings = nil
                    cachedJoinedThreads[threadID] = nil
                    cachedJoinedThreadOrder.removeAll { $0 == threadID }
                }
                publishForumPosts(parentID: parentID)
                publishActiveJoinedThreads()
                break
            }
        case "THREAD_LIST_SYNC":
            guard let sync = try? JSONDecoder().decode(GatewayThreadListSyncDTO.self, from: data),
                  let guildID = GuildID(sync.guildID)
            else { return }
            let parents = Set(sync.channelIDs.compactMap(ChannelID.init))
            let membersByThreadID = Dictionary(
                sync.members.compactMap { member in
                    member.id.map { ($0, member) }
                },
                uniquingKeysWith: { _, latest in latest }
            )
            let hydratedThreads = sync.threads.map { thread in
                var thread = thread
                if thread.member == nil {
                    thread.member = membersByThreadID[thread.id]
                }
                return thread
            }
            ingestForumThreads(
                hydratedThreads, fallbackGuildID: guildID,
                replacingParents: parents.isEmpty ? nil : parents,
                advancesParentLatestThreadID: true
            )
        case "MESSAGE_ACK":
            guard let ack = try? JSONDecoder().decode(GatewayMessageAckDTO.self, from: data),
                  let channelID = ChannelID(ack.channelID)
            else { return }
            forumReadStates[channelID] = ForumReadState(
                lastReadMessageID: ack.messageID.flatMap(MessageID.init),
                mentionCount: ack.mentionCount ?? 0
            )
            continuation?.yield(
                .readStateChanged(
                    ChannelReadState(
                        channelID: channelID,
                        lastAcknowledgedMessageID: ack.messageID.flatMap(MessageID.init),
                        mentionCount: ack.mentionCount ?? 0,
                        isManual: ack.manual ?? false,
                        flags: ack.flags,
                        lastViewed: ack.lastViewed,
                        version: ack.version
                    )
                )
            )
            for (parentID, posts) in cachedForumPosts where posts[channelID] != nil {
                if let lastMessageID = posts[channelID]?.thread.lastMessageID {
                    cachedForumPosts[parentID]?[channelID]?.isUnread =
                        (ack.mentionCount ?? 0) > 0
                        || (ack.messageID.flatMap(MessageID.init).map {
                            lastMessageID > $0
                        } ?? true)
                } else {
                    cachedForumPosts[parentID]?[channelID]?.isUnread =
                        (ack.mentionCount ?? 0) > 0
                }
                publishForumPosts(parentID: parentID)
                break
            }
        case "GUILD_APPLICATION_COMMAND_INDEX_UPDATE":
            guard
                let update = try? JSONDecoder().decode(
                    GatewayApplicationCommandIndexUpdateDTO.self, from: data
                ), let guildID = GuildID(update.guildID)
            else { return }
            let target = ApplicationCommandIndexTarget.guild(guildID)
            if cachedApplicationCommandCatalogs[target]?.version != update.version?.value {
                invalidateApplicationCommandCatalog(target)
            }
        case "RATE_LIMITED":
            guard let rateLimit = try? JSONDecoder().decode(
                GatewayRateLimitedDTO.self, from: data
            ) else { return }
            gatewayOpcodeRateLimitDates[rateLimit.opcode] = Date().addingTimeInterval(
                max(0, rateLimit.retryAfter)
            )
            failGatewayRequests(rateLimited: rateLimit)
        case "GUILD_DELETE":
            guard
                let deleted = try? JSONDecoder().decode(
                    GatewayDeletedEntityDTO.self, from: data
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
                removeGuild(guildID)
            }
        case "CHANNEL_CREATE", "CHANNEL_UPDATE":
            guard let dto = try? JSONDecoder().decode(ChannelDTO.self, from: data) else {
                return
            }
            if dto.isThread {
                ingestForumThreads(
                    [dto],
                    fallbackGuildID: dto.guildID.flatMap(GuildID.init),
                    advancesParentLatestThreadID: name == "CHANNEL_CREATE"
                )
                return
            }
            if let guildID = dto.guildID.flatMap(GuildID.init) {
                if name == "CHANNEL_CREATE", let channelID = ChannelID(dto.id) {
                    appendQuickSwitcherChannelStoreOrder([channelID])
                    persistQuickSwitcherChannelStoreCache()
                }
                cachedGuildChannelDTOs[guildID, default: [:]][dto.id] = dto
                publishGuildChannels(guildID)
                return
            }
            if let recipients = dto.recipients {
                cacheLiveSearchUsers(recipients)
            }
            if let channelID = ChannelID(dto.id) {
                lazyPrivateChannelIDs.remove(channelID)
            }
            cachePrivateRecipientReferences([dto])
            guard dto.type == 1 || dto.type == 3,
                  var channel = try? dto.domain(
                      guildID: nil,
                      knownUsersByID: cachedGatewayUsersByID
                  )
            else { return }
            if name == "CHANNEL_UPDATE", let existing = privateChannel(id: channel.id) {
                if dto.recipients == nil, dto.recipientIDs == nil {
                    channel.recipients = existing.recipients
                }
                if dto.name == nil, dto.recipients == nil, dto.recipientIDs == nil {
                    channel.name = existing.name
                }
                if dto.ownerID == nil {
                    channel.ownerID = existing.ownerID
                }
                if dto.icon == nil {
                    channel.iconURL = existing.iconURL
                }
                if dto.lastMessageID == nil {
                    channel.lastMessageID = existing.lastMessageID
                }
            }
            upsertPrivateChannel(channel)
        case "CHANNEL_RECIPIENT_ADD", "CHANNEL_RECIPIENT_REMOVE":
            guard let update = try? JSONDecoder().decode(
                GatewayChannelRecipientDTO.self,
                from: data
            ),
                let channelID = ChannelID(update.channelID),
                var channel = privateChannel(id: channelID),
                let user = try? update.user.domain()
            else { return }
            if name == "CHANNEL_RECIPIENT_ADD" {
                cacheLiveSearchUsers([update.user])
                if !channel.recipients.contains(where: { $0.id == user.id }) {
                    channel.recipients.append(user)
                }
                channel.kind = .groupDirectMessage
            } else {
                channel.recipients.removeAll { $0.id == user.id }
            }
            channel.recipients = DiscordPrivateRecipientOrdering.sortedDomainUsers(
                channel.recipients,
                channelID: update.channelID,
                channelType: channel.kind == .groupDirectMessage ? 3 : 1
            )
            cachedPrivateRecipientIDsByChannelID[channelID] =
                channel.recipients.map { $0.id.description }
            upsertPrivateChannel(channel)
        case "CHANNEL_DELETE":
            guard
                let deleted = try? JSONDecoder().decode(
                    GatewayDeletedEntityDTO.self, from: data
                ), let channelID = ChannelID(deleted.id)
            else { return }
            invalidateApplicationCommandCatalog(.channel(channelID))
            let guildID = deleted.guildID.flatMap(GuildID.init)
                ?? cachedGuildChannelDTOs.first(where: { $0.value[deleted.id] != nil })?.key
            if let guildID {
                cachedGuildChannelDTOs[guildID]?[deleted.id] = nil
                cachedForumPosts[channelID] = nil
                for parentID in cachedForumPosts.keys {
                    cachedForumPosts[parentID]?[channelID] = nil
                }
                publishGuildChannels(guildID)
                return
            }
            if cachedChannels[nil]?.contains(where: { $0.id == channelID }) == true {
                cachedChannels[nil]?.removeAll { $0.id == channelID }
                lazyPrivateChannelIDs.remove(channelID)
                continuation?.yield(
                    .channelsChanged(guildID: nil, channels: cachedChannels[nil] ?? [])
                )
                continuation?.yield(.privateMembersChanged(privateMembersInChannelOrder()))
            }
        case "USER_APPLICATION_UPDATE", "USER_APPLICATION_REMOVE":
            invalidateApplicationCommandCatalog(.user)
        case "APPLICATION_COMMAND_AUTOCOMPLETE_RESPONSE":
            guard
                let response = try? JSONDecoder().decode(
                    GatewayApplicationCommandAutocompleteDTO.self, from: data
                )
            else { return }
            let nonce = response.nonce.value
            guard let optionType = pendingAutocompleteTypes.removeValue(forKey: nonce) else {
                return
            }
            autocompleteTimeoutTasks.removeValue(forKey: nonce)?.cancel()
            let choices = response.choices.compactMap { $0.domain(optionType: optionType) }
            continuation?.yield(
                .applicationCommandAutocomplete(
                    ApplicationCommandAutocompleteResult(nonce: nonce, choices: choices)
                )
            )
        case "INTERACTION_CREATE":
            guard
                let event = try? JSONDecoder().decode(
                    GatewayInteractionLifecycleDTO.self, from: data),
                let nonce = event.nonce?.value, let interactionID = event.id
            else { return }
            continuation?.yield(
                .interaction(.created(nonce: nonce, interactionID: interactionID))
            )
        case "INTERACTION_SUCCESS":
            guard
                let event = try? JSONDecoder().decode(
                    GatewayInteractionLifecycleDTO.self, from: data),
                let nonce = event.nonce?.value
            else { return }
            if pendingAutocompleteTypes[nonce] == nil {
                continuation?.yield(.interaction(.succeeded(nonce: nonce)))
            }
        case "INTERACTION_FAILURE":
            guard
                let event = try? JSONDecoder().decode(
                    GatewayInteractionLifecycleDTO.self, from: data),
                let nonce = event.nonce?.value
            else { return }
            pendingAutocompleteTypes[nonce] = nil
            autocompleteTimeoutTasks.removeValue(forKey: nonce)?.cancel()
            continuation?.yield(
                .interaction(
                    .failed(
                        nonce: nonce,
                        message: event.errorMessage
                            ?? event.errorCode.map {
                                "Discord rejected the interaction (code \($0))."
                            }
                            ?? "Discord rejected the interaction."
                    )
                )
            )
        case "INTERACTION_MODAL_CREATE":
            guard
                let event = try? JSONDecoder().decode(
                    GatewayInteractionModalDTO.self, from: data
                )
            else { return }
            pendingModalContexts[event.nonce.value] = event
            continuation?.yield(
                .interaction(.presentModal(nonce: event.nonce.value, modal: event.modal))
            )
        case "TYPING_START":
            guard let typing = try? JSONDecoder().decode(TypingStartDTO.self, from: data),
                  let channelID = ChannelID(typing.channelID),
                  let userID = UserID(typing.userID),
                  let user = DiscordTypingEventResolver.resolve(.init(
                      typing: typing,
                      userID: userID,
                      currentUser: currentUser,
                      currentStatus: presenceStatus,
                      cachedMembers: cachedMembers,
                      cachedChannels: cachedChannels.values.flatMap(\.self),
                      cachedMessages: Array(cachedMessages.values),
                      cachedGuildRoles: cachedGuildRoles
                  ))
            else {
                gatewayLogger.debug("Ignored an unresolved or malformed typing event")
                return
            }
            continuation?.yield(.typing(channelID: channelID, user: user))
        case "MESSAGE_REACTION_ADD":
            guard
                let value = try? JSONDecoder().decode(
                    GatewayMessageReactionUserDTO.self,
                    from: data
                ),
                let update = value.domainUpdate(isAddition: true)
            else { return }
            applyGatewayReactionUpdate(update)
        case "MESSAGE_REACTION_REMOVE":
            guard
                let value = try? JSONDecoder().decode(
                    GatewayMessageReactionUserDTO.self,
                    from: data
                ),
                let update = value.domainUpdate(isAddition: false)
            else { return }
            applyGatewayReactionUpdate(update)
        case "MESSAGE_REACTION_REMOVE_ALL":
            guard
                let value = try? JSONDecoder().decode(
                    GatewayMessageReactionRemoveAllDTO.self,
                    from: data
                ),
                let update = value.domainUpdate
            else { return }
            applyGatewayReactionUpdate(update)
        case "MESSAGE_REACTION_REMOVE_EMOJI":
            guard
                let value = try? JSONDecoder().decode(
                    GatewayMessageReactionRemoveEmojiDTO.self,
                    from: data
                ),
                let update = value.domainUpdate
            else { return }
            applyGatewayReactionUpdate(update)
        case "MESSAGE_UPDATE":
            if let update = try? JSONDecoder().decode(MessageUpdateDTO.self, from: data),
               let messageID = MessageID(update.id), ChannelID(update.channelID) != nil,
               var message = cachedMessages[messageID]
            {
                if let mentions = update.mentions?.elements {
                    cacheMessageSearchUsers(mentions.map(\.searchIndexUser))
                }
                update.apply(to: &message)
                cachedMessages[messageID] = message
                continuation?.yield(.messageUpdated(message))
                updateForumPostForMessage(message)
            }
        case "MESSAGE_DELETE":
            if let value = try? JSONDecoder().decode(MessageDeleteDTO.self, from: data),
               let channelID = ChannelID(value.channelID), let messageID = MessageID(value.id)
            {
                cachedMessages[messageID] = nil
                continuation?.yield(.messageDeleted(channelID: channelID, messageID: messageID))
            }
        case "MESSAGE_DELETE_BULK":
            guard
                let deletion = try? JSONDecoder().decode(
                    GatewayMessageDeleteBulkDTO.self, from: data
                ), let channelID = ChannelID(deletion.channelID)
            else { return }
            for messageID in deletion.ids.compactMap(MessageID.init) {
                cachedMessages[messageID] = nil
                continuation?.yield(
                    .messageDeleted(channelID: channelID, messageID: messageID)
                )
            }
        case "CHANNEL_PINS_UPDATE":
            guard
                let update = try? JSONDecoder().decode(
                    GatewayChannelPinsUpdateDTO.self, from: data
                ), let channelID = ChannelID(update.channelID)
            else { return }
            let timestamp = update.lastPinTimestamp.flatMap(DiscordDate.parse)
            if let guildID = update.guildID.flatMap(GuildID.init) {
                cachedGuildChannelDTOs[guildID]?[update.channelID]?.lastPinTimestamp =
                    update.lastPinTimestamp
                publishGuildChannels(guildID)
            } else if var channels = cachedChannels[nil],
                      let index = channels.firstIndex(where: { $0.id == channelID })
            {
                channels[index].lastPinTimestamp = timestamp
                cachedChannels[nil] = channels
                continuation?.yield(.channelsChanged(guildID: nil, channels: channels))
            }
        case "GUILD_MEMBER_LIST_UPDATE":
            guard let update = try? JSONDecoder().decode(GuildMemberListUpdateDTO.self, from: data),
                  let guildID = GuildID(update.guildID)
            else {
                gatewayLogger.error("Member-list update could not be decoded; bytes=\(data.count)")
                return
            }
            let syncItemCount = update.ops.reduce(0) { $0 + ($1.items?.count ?? 0) }
            if syncItemCount > 0 {
                gatewayLogger.info("Member-list range synchronized; items=\(syncItemCount)")
            }
            // Discord's UserSearchManager deliberately does not subscribe to
            // GUILD_MEMBER_LIST_UPDATE. These members remain available to the
            // visible member list and nickname store, but must not leak into
            // the account-wide Forward user-search index.
            applyMemberListOperations(
                update.ops, guildID: guildID, memberListID: update.id
            )
            if let groups = update.groups {
                cachedMemberListGroups[guildID, default: [:]][update.id] = groups.map {
                    GuildMemberListGroup(id: $0.id, count: $0.count)
                }
            }
            let members = decodedMemberListMembers(
                guildID: guildID, memberListID: update.id
            )
            cachedMembers[guildID] = DiscordMemberStoreOrdering.merging(
                existing: cachedMembers[guildID] ?? [], updates: members
            )
            publishUserSearchAliases()
            if guildID == pendingMemberGuildID,
               update.id == selectedMemberListID[guildID]
            {
                continuation?.yield(
                    .membersChanged(
                        guildID: guildID,
                        members: orderedMemberListMembers(guildID: guildID) ?? members,
                        groups: cachedMemberListGroups[guildID]?[update.id] ?? []
                    )
                )
            }
        case "GUILD_MEMBERS_CHUNK":
            guard
                let chunk = try? JSONDecoder().decode(GatewayGuildMembersChunkDTO.self, from: data),
                let guildID = GuildID(chunk.guildID)
            else { return }
            let decodedMembers = chunk.members.compactMap {
                try? $0.domain(
                    currentUserID: currentUser?.id,
                    currentStatus: presenceStatus,
                    guildRoles: cachedGuildRoles[guildID] ?? [],
                    guildID: guildID
                )
            }
            let responseUserIDs = Set(decodedMembers.map(\.id)).union(
                (chunk.notFound ?? []).compactMap(UserID.init)
            )
            let roleMemberRequestID = pendingRoleMemberRequestID(
                guildID: guildID,
                responseUserIDs: responseUserIDs
            )
            if roleMemberRequestID == nil {
                // Discord's SearchContextManager handles unsolicited and
                // search-driven GUILD_MEMBERS_CHUNK_BATCH users. SakuraCord
                // also issues private member-resolution requests solely to
                // hydrate timeline presentation; those extra requests must
                // not expand message-search UserStore beyond Discord's live
                // source set.
                cacheLiveSearchUsers(chunk.members.map(\.user))
            } else {
                for member in chunk.members {
                    cacheGatewayUser(member.user, messageSearchEligible: false)
                }
            }
            let joinedUserIDs = Set<UserID>(chunk.members.compactMap { member -> UserID? in
                guard member.joinedAt != nil, member.pending != true else { return nil }
                return UserID(member.user.id)
            })
            mergeResolvedMembers(
                decodedMembers, guildID: guildID, joinedUserIDs: joinedUserIDs
            )
            // The first-party SearchContext worker records membership from
            // every GUILD_MEMBERS_CHUNK_BATCH result. Keep this index separate
            // from the bounded visible-member cache so @ searches can filter
            // a newly resolved user immediately within this live connection.
            quickSwitcherGuildMemberUserIDsByGuildID[guildID, default: []]
                .formUnion(decodedMembers.map(\.id))
            publishUserSearchAliases()
            if let requestID = roleMemberRequestID,
               var request = pendingRoleMemberRequests[requestID]
            {
                request.members.append(contentsOf: decodedMembers)
                request.receivedChunks.insert(chunk.chunkIndex)
                if request.receivedChunks.count >= max(1, chunk.chunkCount) {
                    pendingRoleMemberRequests[requestID] = nil
                    request.timeoutTask.cancel()
                    request.continuation.resume(returning: request.members)
                } else {
                    pendingRoleMemberRequests[requestID] = request
                }
                return
            }

            guard let requestID = pendingMemberSearchRequestByGuild[guildID],
                  var search = pendingMemberSearchRequests[requestID]
            else {
                return
            }
            search.members.append(contentsOf: decodedMembers)
            search.receivedChunks.insert(chunk.chunkIndex)
            if search.receivedChunks.count >= max(1, chunk.chunkCount) {
                _ = removeMemberSearchRequest(requestID: requestID)
                search.timeoutTask.cancel()
                let responseMembers = Array(search.members.prefix(search.maximumResults))
                mergeResolvedMembers(responseMembers, guildID: guildID)
                let members = DiscordMemberStoreOrdering.searchResults(
                    in: cachedMembers[guildID] ?? [],
                    matching: responseMembers,
                    limit: search.maximumResults
                )
                search.continuation.resume(returning: members)
            } else {
                pendingMemberSearchRequests[requestID] = search
            }
        case "PRESENCE_UPDATE":
            guard let update = try? JSONDecoder().decode(PresenceUpdateDTO.self, from: data)
            else { return }
            if update.guildID == nil {
                cachePrivatePresence(update)
                continuation?.yield(.privateMembersChanged(privateMembersInChannelOrder()))
                return
            }
            guard let guildID = update.guildID.flatMap(GuildID.init),
                  let userID = UserID(update.user.id),
                  let status = PresenceStatus(rawValue: update.status),
                  var members = cachedMembers[guildID],
                  let index = members.firstIndex(where: { $0.id == userID })
            else { return }
            members[index].status = status
            if let activities = update.activities {
                members[index].customStatus = activities.first(where: { $0.type == 4 })?.displayText
                members[index].activityText =
                    activities.first(where: { $0.type != 4 })?.displayText
                        ?? members[index].customStatus
            }
            cachedMembers[guildID] = members
            if guildID == pendingMemberGuildID {
                continuation?.yield(
                    .membersChanged(
                        guildID: guildID,
                        members: orderedMemberListMembers(guildID: guildID) ?? members,
                        groups: selectedMemberListGroups(guildID: guildID)
                    )
                )
            }
        case "VOICE_CHANNEL_STATUS_UPDATE", "VOICE_CHANNEL_START_TIME_UPDATE":
            guard
                let update = try? JSONDecoder().decode(
                    GatewayVoiceChannelMetadataDTO.self, from: data
                ), let guildID = GuildID(update.guildID),
                cachedGuildChannelDTOs[guildID]?[update.id] != nil
            else { return }
            if name == "VOICE_CHANNEL_STATUS_UPDATE" {
                cachedGuildChannelDTOs[guildID]?[update.id]?.status = update.status
            } else {
                cachedGuildChannelDTOs[guildID]?[update.id]?.voiceStartTime =
                    update.voiceStartTime
            }
            publishGuildChannels(guildID)
        case "VOICE_STATE_UPDATE":
            guard let state = try? JSONDecoder().decode(VoiceStateUpdateDTO.self, from: data),
                  let participant = state.domain()
            else { return }
            continuation?.yield(.voiceStateChanged(participant))
            reconcilePrivateCallVoiceState(participant)
            if participant.userID == currentUser?.id {
                if participant.channelID == nil {
                    activeVoiceConnection = nil
                } else if participant.channelID == activeVoiceConnection?.channelID {
                    activeVoiceConnection?.sessionID = participant.sessionID
                }
            }
            if participant.userID == currentUser?.id,
               participant.channelID == pendingVoiceNegotiation?.channelID
            {
                pendingVoiceNegotiation?.sessionID = participant.sessionID
                finishVoiceNegotiationIfReady()
            }
        case "VOICE_SERVER_UPDATE":
            guard let update = try? JSONDecoder().decode(VoiceServerUpdateDTO.self, from: data)
            else {
                return
            }
            if let pending = pendingVoiceNegotiation, update.matches(guildID: pending.guildID) {
                pendingVoiceNegotiation?.token = update.token
                pendingVoiceNegotiation?.endpoint = update.resolvedEndpoint
                finishVoiceNegotiationIfReady()
                return
            }
            guard let activeVoiceConnection,
                  let resolution = VoiceServerMigrationResolver.resolve(
                      update: update,
                      activeConnection: activeVoiceConnection
                  )
            else { return }
            switch resolution {
            case .waitForAllocation:
                continuation?.yield(.voiceServerChanged(nil))
            case .reconnect(let info):
                self.activeVoiceConnection = info
                continuation?.yield(.voiceServerChanged(info))
            }
        case "CALL_CREATE":
            guard let update = try? JSONDecoder().decode(PrivateCallDTO.self, from: data),
                  let call = update.domain()
            else { return }
            privateCallsByChannel[call.channelID] = call
            continuation?.yield(.privateCallChanged(call))
        case "CALL_UPDATE":
            guard let update = try? JSONDecoder().decode(PrivateCallDTO.self, from: data),
                  let incoming = update.domain()
            else { return }
            let existing = privateCallsByChannel[incoming.channelID]
            let merged = PrivateCall(
                channelID: incoming.channelID,
                messageID: incoming.messageID ?? existing?.messageID,
                region: incoming.region ?? existing?.region,
                ongoingRings: update.ongoingRings == nil
                    ? (existing?.ongoingRings ?? [])
                    : incoming.ongoingRings,
                voiceStates: incoming.voiceStates ?? existing?.voiceStates,
                isUnavailable: update.unavailable ?? existing?.isUnavailable ?? false
            )
            privateCallsByChannel[merged.channelID] = merged
            continuation?.yield(.privateCallChanged(merged))
        case "CALL_DELETE":
            guard let deletion = try? JSONDecoder().decode(PrivateCallDeleteDTO.self, from: data),
                  let channelID = ChannelID(deletion.channelID)
            else { return }
            privateCallsByChannel[channelID] = nil
            continuation?.yield(
                .privateCallDeleted(
                    channelID: channelID,
                    unavailable: deletion.unavailable ?? false
                )
            )
        default:
            return
        }
        }
    }

    func handleGatewayDispatch(name: String, body: JSONValue) async {
        await gatewayDispatchOperation(name, body)
    }
    func reconcilePrivateCallVoiceState(_ state: VoiceParticipantState) {
        var changedChannelIDs: [ChannelID] = []
        for (channelID, var call) in privateCallsByChannel {
            var states = call.voiceStates ?? []
            let originalStates = states
            states.removeAll { $0.userID == state.userID }
            if channelID == state.channelID {
                states.append(state)
            }
            guard states != originalStates else { continue }
            call.voiceStates = states
            privateCallsByChannel[channelID] = call
            changedChannelIDs.append(channelID)
        }
        for channelID in changedChannelIDs.sorted(by: {
            $0.rawValue < $1.rawValue
        }) {
            if let call = privateCallsByChannel[channelID] {
                continuation?.yield(.privateCallChanged(call))
            }
        }
    }

    func invalidateApplicationCommandCatalog(_ target: ApplicationCommandIndexTarget) {
        cachedApplicationCommandCatalogs[target] = nil
        applicationCommandCatalogTasks.removeValue(forKey: target)?.cancel()
        continuation?.yield(.applicationCommandIndexInvalidated(target))
    }

    func publishGuildLayout() {
        continuation?.yield(
            .guildLayoutChanged(
                guilds: guildsInCurrentRailOrder(),
                railItems: cachedGuildRailItems
            )
        )
    }

    func insertGuildIntoRailIfNeeded(_ guildID: GuildID) {
        let containsGuild = cachedGuildRailItems.contains { item in
            switch item {
            case .guild(let id): id == guildID
            case .folder(let folder): folder.guildIDs.contains(guildID)
            }
        }
        if !containsGuild { cachedGuildRailItems.insert(.guild(guildID), at: 0) }
    }

    func removeGuildFromRail(_ guildID: GuildID) {
        cachedGuildRailItems = cachedGuildRailItems.compactMap { item in
            switch item {
            case .guild(let id):
                return id == guildID ? nil : item
            case .folder(var folder):
                folder.guildIDs.removeAll { $0 == guildID }
                return folder.guildIDs.isEmpty ? nil : .folder(folder)
            }
        }
    }

    func publishGuildChannels(_ guildID: GuildID) {
        guard let values = cachedGuildChannelDTOs[guildID]?.values,
              let channels = try? Self.domainChannels(Array(values), guildID: guildID)
        else { return }
        cachedChannels[guildID] = channels
        continuation?.yield(.channelsChanged(guildID: guildID, channels: channels))
    }

    func publishGuildRoles(_ guildID: GuildID) {
        let roles = (cachedGuildRoles[guildID] ?? [])
            .compactMap(\.domain)
            .sorted { lhs, rhs in
                if lhs.position != rhs.position { return lhs.position > rhs.position }
                return lhs.id.rawValue > rhs.id.rawValue
            }
        continuation?.yield(.guildRolesChanged(guildID: guildID, roles: roles))
        reconcileMembersAfterRoleChange(guildID: guildID)
    }

    func reconcileMembersAfterRoleChange(guildID: GuildID) {
        guard var members = cachedMembers[guildID] else { return }
        let roleDTOs = cachedGuildRoles[guildID] ?? []
        for index in members.indices {
            let roleIDs = Set(members[index].roleIDs.map(\.description))
            let resolved = roleDTOs
                .filter { roleIDs.contains($0.id) }
                .sorted { $0.position > $1.position }
            let category = resolved.filter(\.hoist).max { lhs, rhs in
                if lhs.position != rhs.position { return lhs.position < rhs.position }
                return lhs.id < rhs.id
            }
            members[index].roles = resolved.compactMap(\.domain)
            members[index].roleName = category?.name ?? "Member"
            members[index].roleID = category.flatMap { RoleID($0.id) }
            members[index].rolePosition = category?.position
            members[index].isRoleCategory = category != nil
        }
        cachedMembers[guildID] = members
        continuation?.yield(
            .membersChanged(
                guildID: guildID,
                members: members,
                groups: selectedMemberListGroups(guildID: guildID)
            )
        )
    }

}
