import Foundation
import SakuraCordModels

private enum ApplicationStreamNegotiationRequest: Sendable {
    case create(
        key: ApplicationStreamKey,
        channelID: ChannelID,
        guildID: GuildID?,
        preferredRegion: String?
    )
    case watch(ApplicationStreamKey)
}

public extension DiscordRESTProvider {
    func startApplicationStream(
        channelID: ChannelID,
        guildID: GuildID?,
        preferredRegion: String?
    ) async throws -> ApplicationStreamConnectionInfo {
        guard gatewayReady, let userID = currentUser?.id else {
            throw ChatProviderError.invalidRequest(
                "Discord Gateway is not ready to start screen sharing."
            )
        }
        let key = ApplicationStreamKey(
            type: guildID == nil ? .call : .guild,
            guildID: guildID,
            channelID: channelID,
            ownerID: userID
        )
        return try await negotiateApplicationStream(
            key: key,
            request: .create(
                key: key,
                channelID: channelID,
                guildID: guildID,
                preferredRegion: preferredRegion
            )
        )
    }

    func watchApplicationStream(
        _ key: ApplicationStreamKey
    ) async throws -> ApplicationStreamConnectionInfo {
        guard gatewayReady else {
            throw ChatProviderError.invalidRequest(
                "Discord Gateway is not ready to watch this screen share."
            )
        }
        return try await negotiateApplicationStream(key: key, request: .watch(key))
    }

    func stopApplicationStream(_ key: ApplicationStreamKey) async throws {
        try await sendGateway(DiscordGatewayPayloadFactory.applicationStreamDelete(key))
        failApplicationStreamNegotiation(key: key, error: CancellationError())
        applicationStreamConnections[key] = nil
    }

    func pingApplicationStream(_ key: ApplicationStreamKey) async throws {
        try await sendGateway(DiscordGatewayPayloadFactory.applicationStreamPing(key))
    }

    func setApplicationStreamPaused(
        _ key: ApplicationStreamKey,
        isPaused: Bool
    ) async throws {
        try await sendGateway(
            DiscordGatewayPayloadFactory.applicationStreamSetPaused(
                key,
                isPaused: isPaused
            )
        )
    }

    func applicationStreamPreview(for key: ApplicationStreamKey) async throws -> URL? {
        let preview: ApplicationStreamPreviewDTO = try await request(
            "/streams/\(key.rawValue)/preview",
            query: [
                URLQueryItem(
                    name: "version",
                    value: String(Int(Date.now.timeIntervalSince1970 * 1_000))
                )
            ]
        )
        return preview.url
    }

    private func negotiateApplicationStream(
        key: ApplicationStreamKey,
        request: ApplicationStreamNegotiationRequest
    ) async throws -> ApplicationStreamConnectionInfo {
        let negotiationID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                failApplicationStreamNegotiation(
                    key: key,
                    error: ChatProviderError.invalidRequest(
                        "A newer request replaced this screen-share connection."
                    )
                )
                pendingApplicationStreamNegotiations[key] =
                    PendingApplicationStreamNegotiation(
                        id: negotiationID,
                        key: key,
                        stream: applicationStreams[key],
                        continuation: continuation
                    )
                applicationStreamNegotiationTimeoutTasks[key]?.cancel()
                applicationStreamNegotiationTimeoutTasks[key] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    await self?.failApplicationStreamNegotiation(
                        key: key,
                        id: negotiationID,
                        error: ChatProviderError.invalidRequest(
                            "Discord did not finish screen-share negotiation in time."
                        )
                    )
                }
                Task { [weak self] in
                    do {
                        try await self?.sendApplicationStreamNegotiationRequest(request)
                    } catch {
                        await self?.failApplicationStreamNegotiation(
                            key: key,
                            id: negotiationID,
                            error: error
                        )
                    }
                }
            }
        } onCancel: {
            Task {
                await self.failApplicationStreamNegotiation(
                    key: key,
                    id: negotiationID,
                    error: CancellationError()
                )
            }
        }
    }

    private func sendApplicationStreamNegotiationRequest(
        _ request: ApplicationStreamNegotiationRequest
    ) async throws {
        switch request {
        case let .create(key, channelID, guildID, preferredRegion):
            try await sendGateway(
                DiscordGatewayPayloadFactory.applicationStreamCreate(
                    channelID: channelID,
                    guildID: guildID,
                    preferredRegion: preferredRegion
                )
            )
            try await sendGateway(
                DiscordGatewayPayloadFactory.applicationStreamSetPaused(
                    key,
                    isPaused: false
                )
            )
        case .watch(let key):
            try await sendGateway(
                DiscordGatewayPayloadFactory.applicationStreamWatch(key)
            )
        }
    }

    internal func reconcileApplicationStream(_ incoming: ApplicationStream) {
        let existing = applicationStreams[incoming.key]
        let stream = ApplicationStream(
            key: incoming.key,
            region: incoming.region ?? existing?.region,
            viewerIDs: incoming.viewerIDs,
            rtcServerID: incoming.rtcServerID ?? existing?.rtcServerID,
            rtcChannelID: incoming.rtcChannelID ?? existing?.rtcChannelID,
            isPaused: incoming.isPaused
        )
        applicationStreams[stream.key] = stream
        continuation?.yield(.applicationStreamChanged(stream))
        if pendingApplicationStreamNegotiations[stream.key] != nil {
            pendingApplicationStreamNegotiations[stream.key]?.stream = stream
            finishApplicationStreamNegotiationIfReady(key: stream.key)
        } else if var connection = applicationStreamConnections[stream.key] {
            connection.stream = stream
            applicationStreamConnections[stream.key] = connection
        }
    }

    internal func reconcileApplicationStreamServer(_ update: ApplicationStreamServerUpdateDTO) {
        guard let key = ApplicationStreamKey(rawValue: update.streamKey) else { return }
        guard let endpoint = update.resolvedEndpoint, let token = update.token else {
            applicationStreamConnections[key] = nil
            continuation?.yield(
                .applicationStreamServerChanged(key: key, connection: nil)
            )
            return
        }
        if pendingApplicationStreamNegotiations[key] != nil {
            pendingApplicationStreamNegotiations[key]?.endpoint = endpoint
            pendingApplicationStreamNegotiations[key]?.token = token
            finishApplicationStreamNegotiationIfReady(key: key)
            return
        }
        guard let stream = applicationStreams[key],
              let connection = makeApplicationStreamConnection(
                  stream: stream,
                  token: token,
                  endpoint: endpoint
              )
        else { return }
        applicationStreamConnections[key] = connection
        continuation?.yield(
            .applicationStreamServerChanged(key: key, connection: connection)
        )
    }

    internal func finishApplicationStreamNegotiationIfReady(key: ApplicationStreamKey) {
        guard let pending = pendingApplicationStreamNegotiations[key],
              let stream = pending.stream,
              let token = pending.token,
              let endpoint = pending.endpoint,
              let connection = makeApplicationStreamConnection(
                  stream: stream,
                  token: token,
                  endpoint: endpoint
              )
        else { return }
        applicationStreamNegotiationTimeoutTasks.removeValue(forKey: key)?.cancel()
        pendingApplicationStreamNegotiations[key] = nil
        applicationStreamConnections[key] = connection
        pending.continuation.resume(returning: connection)
    }

    internal func failApplicationStreamNegotiation(
        key: ApplicationStreamKey,
        id: UUID? = nil,
        error: any Error
    ) {
        guard let pending = pendingApplicationStreamNegotiations[key],
              id == nil || pending.id == id
        else { return }
        applicationStreamNegotiationTimeoutTasks.removeValue(forKey: key)?.cancel()
        pendingApplicationStreamNegotiations[key] = nil
        pending.continuation.resume(throwing: error)
    }

    internal func cancelApplicationStreamNegotiations(error: any Error) {
        for key in Array(pendingApplicationStreamNegotiations.keys) {
            failApplicationStreamNegotiation(key: key, error: error)
        }
    }

    private func makeApplicationStreamConnection(
        stream: ApplicationStream,
        token: String,
        endpoint: String
    ) -> ApplicationStreamConnectionInfo? {
        guard let activeVoiceConnection,
              let rtcServerID = stream.rtcServerID,
              let rtcChannelID = stream.rtcChannelID ?? fallbackRTCChannelID(
                  serverID: rtcServerID
              )
        else { return nil }
        let voice = VoiceConnectionInfo(
            serverID: rtcServerID,
            channelID: rtcChannelID,
            guildID: stream.key.guildID,
            userID: activeVoiceConnection.userID,
            sessionID: activeVoiceConnection.sessionID,
            token: token,
            endpoint: endpoint
        )
        return ApplicationStreamConnectionInfo(stream: stream, voice: voice)
    }

    private func fallbackRTCChannelID(serverID: String) -> ChannelID? {
        guard let raw = UInt64(serverID), raw > 0 else { return nil }
        return ChannelID(String(raw - 1))
    }
}
