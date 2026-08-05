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
        let stream = AsyncStream<ClientEvent>.makeStream(bufferingPolicy: .bufferingNewest(500))
        continuation = stream.continuation
        return stream.stream
    }

    public func disconnect() async {
        requestSafetyCircuitIsOpen = true
        failInitialGatewaySnapshot(CancellationError())
        initialGatewaySnapshot = nil
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
        session.getAllTasks { tasks in
            for task in tasks {
                task.cancel()
            }
        }
        continuation?.yield(.connectionChanged(.disconnected))
        continuation?.finish()
        continuation = nil
        authorizationValue = nil
    }

    #if DEBUG
        func seedForumChannelForTesting(
            _ channel: Channel,
            posts: [ForumPost] = [],
            currentUser: User? = nil
        ) {
            cachedChannels[channel.guildID, default: []].removeAll { $0.id == channel.id }
            cachedChannels[channel.guildID, default: []].append(channel)
            cachedForumPosts[channel.id] = Dictionary(
                uniqueKeysWithValues: posts.map { ($0.id, $0) }
            )
            for post in posts {
                cacheForumPreviewMessages(post)
            }
            if let currentUser {
                self.currentUser = currentUser
            }
        }

        func seedPrivateChannelsForTesting(
            _ channels: [Channel],
            currentUser: User? = nil
        ) {
            cachedChannels[nil] = channels
            if let currentUser {
                self.currentUser = currentUser
            }
        }

        func activeForumCatalogueQueriesForTesting(channelID: ChannelID) -> [ForumPostQuery] {
            forumCatalogueTasks.keys.compactMap {
                $0.channelID == channelID ? $0.query : nil
            }
        }

        func suspendForumCatalogueRefreshForTesting() {
            suspendsForumCatalogueRefreshForTesting = true
        }

        func receiveForumMessageForTesting(_ message: Message, marksUnread: Bool = true) {
            updateForumPostForMessage(message, marksUnread: marksUnread)
        }

        func receiveGatewayReactionForTesting(_ update: MessageReactionUpdate) {
            applyGatewayReactionUpdate(update)
        }

        func receiveGatewayDispatchForTesting(name: String, data: JSONValue) async {
            guard let encoded = try? JSONEncoder().encode(data),
                  let body = try? JSONSerialization.jsonObject(with: encoded)
            else { return }
            await handleGatewayDispatch(name: name, body: body)
        }

        func cachedChannelForTesting(channelID: ChannelID) -> Channel? {
            cachedChannels.values.lazy.flatMap { $0 }.first { $0.id == channelID }
        }

        func cachedPrivateChannelsForTesting() -> [Channel] {
            cachedChannels[nil] ?? []
        }

        func cachedForumPostForTesting(threadID: ChannelID) -> ForumPost? {
            cachedForumPosts.values.lazy.compactMap { $0[threadID] }.first
        }

        func cachedMessageForTesting(messageID: MessageID) -> Message? {
            cachedMessages[messageID]
        }

        func seedMessageForTesting(_ message: Message) {
            cachedMessages[message.id] = message
        }

        func cachedGuildForTesting(guildID: GuildID) -> Guild? {
            cachedGuilds[guildID]
        }

        func currentUserForTesting() -> User? {
            currentUser
        }

        func cachedGuildsForTesting() -> [Guild] {
            guildsInCurrentRailOrder()
        }

        func cachedGuildRailItemsForTesting() -> [GuildRailItem] {
            cachedGuildRailItems
        }

        func cachedGuildRolesForTesting(guildID: GuildID) -> [GuildRole] {
            (cachedGuildRoles[guildID] ?? []).compactMap(\.domain)
        }

        func cachedMembersForTesting(guildID: GuildID) -> [Member] {
            cachedMembers[guildID] ?? []
        }

        func gatewayOpcodeIsRateLimitedForTesting(_ opcode: Int) -> Bool {
            gatewayOpcodeRateLimitDates[opcode].map { $0 > Date() } ?? false
        }

        func seedPrivateCallSubscriptionForTesting(channelID: ChannelID) {
            subscribedPrivateCallChannelIDs.insert(channelID)
        }

        func hasPrivateCallSubscriptionForTesting(channelID: ChannelID) -> Bool {
            subscribedPrivateCallChannelIDs.contains(channelID)
        }
    #endif

    func startGateway() async throws {
        guard gatewaySession == nil else { return }
        let token = try await authorizationToken()
        let baseline = DiscordProductionBaseline.august2026
        let identifyEnvelope = GatewayEnvelope(
            op: 2,
            data: .object([
                "token": .string(token),
                // The official client adds bit 15 only for its private-channel
                // obfuscation experiment. SakuraCord does not advertise that
                // capability until it can reconcile obfuscated channels.
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
            guard let data = try? JSONEncoder().encode(value),
                  let body = try? JSONSerialization.jsonObject(with: data)
            else { return }
            await handleGatewayDispatch(name: name, body: body)
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
        for batch in userIDs.chunked(into: 100) {
            // Local continuation identity only; this value is never sent to Discord.
            let requestID = UUID().uuidString.lowercased()
            let members = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Member], any Error>) in
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
            mergeResolvedMembers(members, guildID: guildID)
        }
    }

    func mergeResolvedMembers(_ members: [Member], guildID: GuildID) {
        cachedMembers[guildID] = DiscordMemberStoreOrdering.merging(
            existing: cachedMembers[guildID] ?? [], updates: members
        )
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
        @isolated(any) (String, Any) async -> Void
    {
        { [self] name, body in
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body)
        else { return }
        switch name {
        case "READY", "RESUMED":
            subscribedPrivateCallChannelIDs = []
            if name == "READY",
               let ready = try? JSONDecoder().decode(GatewayReadyGuildsDTO.self, from: data)
            {
                privateCallsByChannel = [:]
                cancelPendingRoleMemberRequests(error: CancellationError())
                cachedMembers = [:]
                cachedMemberListItems = [:]
                cachedMemberListGroups = [:]
                selectedMemberListID = [:]
                memberListSubscriptions = [:]
                memberListSubscriptionOrder = [:]
                cachedGuildChannelDTOs = [:]
                cachedGuildRoles = [:]
                cachedForumPosts = [:]
                gatewayOpcodeRateLimitDates = [:]
                requestedHistoryMemberIDs = [:]
                cachedPrivateMembersByID = [:]
                cachedGatewayUsersByID = Dictionary(
                    ready.users.map { ($0.id, $0) },
                    uniquingKeysWith: { _, newer in newer }
                )
                if let userDTO = ready.currentUser,
                   let user = try? userDTO.domain()
                {
                    currentUser = user
                }
                forumReadStates = ready.readState.channelEntriesByID.mapValues { entry in
                    ForumReadState(
                        lastReadMessageID: entry.lastMessageID.flatMap(MessageID.init),
                        mentionCount: entry.mentionCount ?? 0
                    )
                }
                let readyReadStates: [ChannelReadState] =
                    ready.readState.channelEntriesByID.map { channelID, entry in
                        ChannelReadState(
                            channelID: channelID,
                            lastAcknowledgedMessageID: entry.lastMessageID.flatMap(MessageID.init),
                            mentionCount: entry.mentionCount ?? 0,
                            flags: entry.flags,
                            lastViewed: entry.lastViewed,
                            version: ready.readState.version
                        )
                    }
                    .sorted { $0.channelID.rawValue < $1.channelID.rawValue }
                let readyNotificationSettings = ready.userGuildSettings.map(\.domain)
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
                let privateChannels = Self.orderedPrivateChannels(
                    ready.privateChannels.compactMap {
                        try? $0.domain(
                            guildID: nil,
                            knownUsersByID: cachedGatewayUsersByID
                        )
                    }
                )
                cachedChannels = [nil: privateChannels]
                for presence in ready.privatePresences {
                    cachePrivatePresence(presence)
                }
                continuation?.yield(.privateMembersChanged(privateMembersInChannelOrder()))
                let readyGuilds = ready.hydratedGuilds(using: cachedGatewayUsersByID)
                gatewayGuildIDs = readyGuilds.compactMap { GuildID($0.id) }
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
                if !currentUserRolesByGuild.isEmpty {
                    continuation?.yield(
                        .currentUserRolesSnapshot(currentUserRolesByGuild)
                    )
                }
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
            continuation?.yield(.notificationSettingsChanged(update.domain))
        case "READY_SUPPLEMENTAL":
            if let supplemental = try? JSONDecoder().decode(
                GatewayReadyGuildsDTO.self, from: data
            ) {
                for user in supplemental.users {
                    cachedGatewayUsersByID[user.id] = user
                }
                for presence in supplemental.privatePresences {
                    cachePrivatePresence(presence)
                }
                if !supplemental.lazyPrivateChannels.isEmpty {
                    var channelsByID = Dictionary(
                        (cachedChannels[nil] ?? []).map { ($0.id, $0) },
                        uniquingKeysWith: { _, newer in newer }
                    )
                    for channel in supplemental.lazyPrivateChannels.compactMap({
                        try? $0.domain(
                            guildID: nil,
                            knownUsersByID: cachedGatewayUsersByID
                        )
                    }) {
                        channelsByID[channel.id] = channel
                    }
                    let channels = Self.orderedPrivateChannels(
                        Array(channelsByID.values)
                    )
                    cachedChannels[nil] = channels
                    continuation?.yield(
                        .channelsChanged(guildID: nil, channels: channels)
                    )
                }
                if !supplemental.lazyPrivateChannels.isEmpty
                    || !supplemental.privatePresences.isEmpty
                {
                    continuation?.yield(.privateMembersChanged(privateMembersInChannelOrder()))
                }
                for guild in supplemental.hydratedGuilds(using: cachedGatewayUsersByID) {
                    guard let guildID = GuildID(guild.id), !guild.members.isEmpty else { continue }
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
                }
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
                    continuation?.yield(
                        .membersChanged(
                            guildID: guildID,
                            members: cachedMembers[guildID] ?? [],
                            groups: selectedMemberListGroups(guildID: guildID)
                        )
                    )
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
            cachedGatewayUsersByID[update.member.user.id] = update.member.user
            publishMemberChange(member, guildID: guildID)
        case "GUILD_MEMBER_REMOVE":
            guard
                let deletion = try? JSONDecoder().decode(
                    GatewayGuildMemberRemoveDTO.self, from: data
                ), let guildID = GuildID(deletion.guildID),
                let userID = UserID(deletion.user.id)
            else { return }
            removeMember(userID: userID, guildID: guildID)
        case "USER_UPDATE":
            guard let dto = try? JSONDecoder().decode(UserDTO.self, from: data),
                  let user = try? dto.domain()
            else { return }
            applyUserUpdate(dto: dto, user: user)
        case "MESSAGE_CREATE":
            if let dto = try? JSONDecoder().decode(MessageDTO.self, from: data),
               let message = try? dto.domain()
            {
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
            publishForumPosts(parentID: parentID)
        case "THREAD_MEMBER_UPDATE":
            guard
                let member = try? JSONDecoder().decode(ThreadMemberDTO.self, from: data),
                member.userID == nil || member.userID.flatMap(UserID.init) == currentUser?.id,
                let threadID = ChannelID(member.id)
            else { return }
            for (parentID, posts) in cachedForumPosts where posts[threadID] != nil {
                cachedForumPosts[parentID]?[threadID]?.thread.notificationSettings =
                    member.domain
                publishForumPosts(parentID: parentID)
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
                } else if update.removedMemberIDs?.contains(
                    currentUser?.id.description ?? ""
                ) == true {
                    cachedForumPosts[parentID]?[threadID]?.thread.notificationSettings = nil
                }
                publishForumPosts(parentID: parentID)
                break
            }
        case "THREAD_LIST_SYNC":
            guard let sync = try? JSONDecoder().decode(GatewayThreadListSyncDTO.self, from: data),
                  let guildID = GuildID(sync.guildID)
            else { return }
            let parents = Set(sync.channelIDs.compactMap(ChannelID.init))
            let membersByThreadID = Dictionary(
                sync.members.map { ($0.id, $0) },
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
            if let guildID = dto.guildID.flatMap(GuildID.init) {
                cachedGuildChannelDTOs[guildID, default: [:]][dto.id] = dto
                publishGuildChannels(guildID)
                return
            }
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
                if !channel.recipients.contains(where: { $0.id == user.id }) {
                    channel.recipients.append(user)
                }
                channel.kind = .groupDirectMessage
            } else {
                channel.recipients.removeAll { $0.id == user.id }
            }
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
            mergeResolvedMembers(decodedMembers, guildID: guildID)
            let responseUserIDs = Set(decodedMembers.map(\.id)).union(
                (chunk.notFound ?? []).compactMap(UserID.init)
            )
            if let requestID = pendingRoleMemberRequestID(
                guildID: guildID,
                responseUserIDs: responseUserIDs
            ),
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

    func handleGatewayDispatch(name: String, body: Any) async {
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

    func publishMemberChange(_ member: Member, guildID: GuildID) {
        cachedMembers[guildID] = DiscordMemberStoreOrdering.merging(
            existing: cachedMembers[guildID] ?? [], updates: [member]
        )
        let members = cachedMembers[guildID] ?? []
        continuation?.yield(
            .membersChanged(
                guildID: guildID,
                members: members,
                groups: selectedMemberListGroups(guildID: guildID)
            )
        )
        if member.id == currentUser?.id {
            continuation?.yield(
                .currentUserRolesChanged(guildID: guildID, roleIDs: member.roleIDs)
            )
            if var guild = cachedGuilds[guildID] {
                guild.currentUserPermissions = nil
                cachedGuilds[guildID] = guild
                continuation?.yield(.guildChanged(guild))
            }
        }
    }

    func removeMember(userID: UserID, guildID: GuildID) {
        cachedMembers[guildID]?.removeAll { $0.id == userID }
        let memberListIDs = cachedMemberListItems[guildID].map { Array($0.keys) } ?? []
        for memberListID in memberListIDs {
            cachedMemberListItems[guildID]?[memberListID]?.removeAll {
                $0?.member?.user.id == userID.description
            }
        }
        let members = cachedMembers[guildID] ?? []
        continuation?.yield(
            .membersChanged(
                guildID: guildID,
                members: members,
                groups: selectedMemberListGroups(guildID: guildID)
            )
        )
        if userID == currentUser?.id {
            continuation?.yield(.currentUserRolesChanged(guildID: guildID, roleIDs: []))
            clearCurrentUserPermissionSnapshot(guildID)
        }
    }

    func applyGuildSettingsProto(
        _ encoded: String?,
        replacesAllSettings: Bool = false
    ) {
        guard
            let encoded,
            let data = Data(base64Encoded: encoded)
        else { return }
        let decodedLayout = DiscordSettingsProto.guildLayout(from: data)
        guard decodedLayout != nil || replacesAllSettings else { return }
        let layout = decodedLayout ?? DiscordGuildLayout(folders: [], guildPositions: [])
        cachedGuildLayout = layout
        // A current desktop READY can provide every guild ID and its channels
        // while omitting the catalogue metadata required to construct Guilds.
        // Preserve the settings until bootstrap's bounded guild-list fallback
        // has installed that catalogue instead of replacing the cached rail
        // with an empty layout event here.
        guard !cachedGuilds.isEmpty else { return }
        let result = Self.applyingGuildLayout(layout, to: guildsInCurrentRailOrder())
        cachedGuilds = Dictionary(uniqueKeysWithValues: result.guilds.map { ($0.id, $0) })
        guard result.railItems != cachedGuildRailItems else { return }
        cachedGuildRailItems = result.railItems
        continuation?.yield(.guildLayoutChanged(guilds: result.guilds, railItems: result.railItems))
    }

    func guildsInCurrentRailOrder() -> [Guild] {
        let existingOrder = cachedGuildRailItems.flatMap { item -> [GuildID] in
            switch item {
            case .guild(let id): [id]
            case .folder(let folder): folder.guildIDs
            }
        }
        let existingSet = Set(existingOrder)
        let orderedGuilds =
            existingOrder.compactMap { cachedGuilds[$0] }
                + cachedGuilds.values
                .filter { !existingSet.contains($0.id) }
                .sorted { $0.id.rawValue > $1.id.rawValue }
        return orderedGuilds
    }
}

struct DiscordTypingResolutionInput {
    var typing: TypingStartDTO
    var userID: UserID
    var currentUser: User?
    var currentStatus: PresenceStatus
    var cachedMembers: [GuildID: [Member]]
    var cachedChannels: [Channel]
    var cachedMessages: [Message]
    var cachedGuildRoles: [GuildID: [GuildRoleDTO]]
}

enum DiscordTypingEventResolver {
    static func resolve(_ input: DiscordTypingResolutionInput) -> User? {
        let typing = input.typing
        let userID = input.userID
        let currentUser = input.currentUser
        let currentStatus = input.currentStatus
        let cachedMembers = input.cachedMembers
        let cachedChannels = input.cachedChannels
        let cachedMessages = input.cachedMessages
        let cachedGuildRoles = input.cachedGuildRoles
        let guildID = typing.guildID.flatMap(GuildID.init)
        if let member = typing.member,
           let resolved = try? member.domain(
               currentUserID: currentUser?.id,
               currentStatus: currentStatus,
               guildRoles: guildID.flatMap { cachedGuildRoles[$0] } ?? [],
               guildID: guildID
           ).user
        {
            return resolved
        }
        if let user = typing.user, let resolved = try? user.domain() {
            return resolved
        }
        if let guildID,
           let member = cachedMembers[guildID]?.first(where: { $0.id == userID })
        {
            return member.user
        }
        if let recipient = cachedChannels.lazy
            .flatMap(\.recipients)
            .first(where: { $0.id == userID })
        {
            return recipient
        }
        if let author = cachedMessages.first(where: { $0.author.id == userID })?.author {
            return author
        }
        return currentUser?.id == userID ? currentUser : nil
    }
}
