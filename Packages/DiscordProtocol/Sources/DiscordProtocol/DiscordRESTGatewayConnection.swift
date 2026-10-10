import Foundation
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
        let buffer = SessionEventBuffer<ClientEvent>(
            overflowEvent: .sessionInvalidated(Self.eventOverflowMessage),
            coalescing: Self.coalescingChannelSnapshots,
            onOverflow: { [weak self] in
                Task { await self?.stopAfterEventOverflow() }
            }
        )
        continuation?.finish()
        continuation = buffer
        return buffer.stream
    }

    private static let eventOverflowMessage =
        "The connection could not keep up with Discord updates. Reconnect your saved account to reload its state."

    private func stopAfterEventOverflow(gatewayDelivery: Bool = false) async {
        guard !requestSafetyCircuitIsOpen else { return }
        requestSafetyCircuitIsOpen = true
        apiDiagnostics.recordWebSocketLifecycle(
            transport: "client", operation: "event_delivery_failed",
            flags: ["gateway_to_provider": gatewayDelivery]
        )
        #if DEBUG
            eventOverflowDidStopRequestsForTesting?()
        #endif
        continuation?.yield(.sessionInvalidated(Self.eventOverflowMessage))
        failInitialGatewaySnapshot(ChatProviderError.invalidRequest(Self.eventOverflowMessage))
        await disconnect()
    }

    public func disconnect() async {
        await finishGuildFoldersEdits()
        currentAccountDetails = nil
        currentAuthSessionIDHash = nil
        accountInformationRevision = UUID()
        profileApexAssignments = nil
        pendingStatusEditConnectionClosed()
        resetProfileEditingState()
        derivedCacheGeneration &+= 1
        stickerFrecencyFlushGeneration &+= 1
        stickerFrecencyFlushTask?.cancel()
        stickerFrecencyFlushTask = nil
        await flushStickerFrecencyIfNeeded()
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
        cancelSoundboardRequests()
        requestedHistoryMemberIDs = [:]
        resolvingHistoryMemberIDs = [:]
        voiceNegotiationTimeoutTask?.cancel()
        if let pendingVoiceNegotiation {
            pendingVoiceNegotiation.continuation.resume(throwing: CancellationError())
            self.pendingVoiceNegotiation = nil
        }
        activeVoiceConnection = nil
        cancelApplicationStreamNegotiations(error: CancellationError())
        applicationStreamNegotiationTimeoutTasks.values.forEach { $0.cancel() }
        applicationStreamNegotiationTimeoutTasks = [:]
        applicationStreamConnections = [:]
        applicationStreams = [:]
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
        cachedMessages.removeAll()
    }

    func startGateway() async throws {
        guard gatewaySession == nil else { return }
        initialGatewaySnapshotResult = nil
        let token = try await authorizationToken()
        let baseline = DiscordProductionBaseline.current
        let identifyEnvelope = GatewayEnvelope(
            op: 2,
            data: .object([
                "token": .string(token),
                // Discord adds bit 15 only when its channel-obfuscation
                // experiment is active. Advertising it without the matching
                // integrity and resync protocol replaces inaccessible channel
                // names with the server sentinel instead of their real names.
                "capabilities": .number(Double(baseline.defaultCapabilities)),
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
        case .deliveryFailed:
            await stopAfterEventOverflow(gatewayDelivery: true)
        case let .payloadRejected(message):
            // Preserve the local cause before the following terminal disconnect
            // would replace it with a generic bootstrap failure.
            failInitialGatewaySnapshot(ChatProviderError.invalidRequest(message))
        case .stateChanged(let connectionState):
            let wasReady = gatewayReady
            gatewayReady = connectionState == .ready
            if wasReady, !gatewayReady { pendingStatusEditConnectionClosed() }
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
                        // The desktop lifecycle starts a new idle session with a
                        // null voice state. Repeating that reset while an existing
                        // Voice connection survives a Gateway gap would make
                        // Discord remove the user from the call before AppModel can
                        // republish the active state.
                        if activeVoiceConnection == nil {
                            try await sendGateway(
                                DiscordGatewayPayloadFactory.voiceStateUpdate(
                                    guildID: nil,
                                    channelID: nil,
                                    selfMute: false,
                                    selfDeaf: false,
                                    selfVideo: false
                                )
                            )
                        }
                        lastSentPresenceStatus = nil
                        await sendPresenceIfChanged()
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
        let previousSubscriptions = memberListSubscriptions[guildID]
        let previousOrder = memberListSubscriptionOrder[guildID]
        var selectedListID: String?
        let subscriptionState = selectedChannel.map { channel in
            let memberListID = DiscordMemberListIdentity.id(
                for: channel,
                guildID: guildID,
                roles: cachedGuildRoles[guildID] ?? []
            )
            selectedMemberListID[guildID] = memberListID
            selectedListID = memberListID
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
                channelRanges: subscriptionState?.rangesByChannel ?? [:],
                threadMemberLists: threadMemberSubscriptions[guildID]
            )
        )
        if let selectedListID {
            memberListsNeedingRefresh[guildID]?.remove(selectedListID)
        }
        // Another subscription send may have committed newer state while this
        // one awaited; that state already reflects the later request, so a
        // value computed before the await must not overwrite it.
        if let subscriptionState,
           memberListSubscriptions[guildID] == previousSubscriptions,
           memberListSubscriptionOrder[guildID] == previousOrder
        {
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
            publishMembers(
                guildID: guildID,
                members: orderedMemberListMembers(
                    guildID: guildID, memberListID: memberListID
                ) ?? [],
                groups: cachedMemberListGroups[guildID]?[memberListID] ?? []
            )
        }
        let needsRefresh = memberListsNeedingRefresh[guildID]?.contains(memberListID) == true
        if !needsRefresh,
           !DiscordMemberListRangePolicy.requiresSubscriptionUpdate(
               memberListID: memberListID,
               ranges: ranges,
               currentSubscriptions: memberListSubscriptions[guildID] ?? [:]
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
        publishThreadMembers(guildID: guildID)
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
        autocompleteOptionTypes = [:]
        autocompleteNonceOrder = []
        pendingInteractionContexts = [:]
        pendingInteractionContextOrder = []
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
              let channels = try? Self.domainChannels(Array(values), guildID: guildID),
              cachedChannels[guildID] != channels
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
        publishMembers(
            guildID: guildID,
            members: members,
            groups: selectedMemberListGroups(guildID: guildID)
        )
    }

}
