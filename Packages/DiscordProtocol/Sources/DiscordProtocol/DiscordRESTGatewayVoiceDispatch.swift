import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    func handleGatewayVoiceEvent(
        name: String,
        body: JSONValue
    ) async -> Bool {
        switch name {
        case "VOICE_SERVER_UPDATE":
            await handleVoiceServerUpdateDispatch(name: name, body: body)
        case "STREAM_CREATE", "STREAM_UPDATE":
            await handleStreamCreateDispatch(name: name, body: body)
        case "STREAM_SERVER_UPDATE":
            await handleStreamServerUpdateDispatch(name: name, body: body)
        case "STREAM_DELETE":
            await handleStreamDeleteDispatch(name: name, body: body)
        case "CALL_CREATE":
            await handleCallCreateDispatch(name: name, body: body)
        case "CALL_UPDATE":
            await handleCallUpdateDispatch(name: name, body: body)
        case "CALL_DELETE":
            await handleCallDeleteDispatch(name: name, body: body)
        case "VOICE_CHANNEL_STATUS_UPDATE", "VOICE_CHANNEL_START_TIME_UPDATE":
            await handleVoiceChannelStatusUpdateDispatch(name: name, body: body)
        case "VOICE_STATE_UPDATE":
            await handleVoiceStateUpdateDispatch(name: name, body: body)
        case "EMBEDDED_ACTIVITY_UPDATE_V2":
            if let instance = (try? JSONValueDecoder().decode(GatewayActivityInstanceDTO.self, from: body))?.domain() {
                continuation?.yield(.embeddedActivityChanged(instance))
            }
        default:
            return false
        }
        return true
    }

    func handleVoiceServerUpdateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let update = try? JSONValueDecoder().decode(VoiceServerUpdateDTO.self, from: body)
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
    }

    func handleStreamCreateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let update = try? JSONValueDecoder().decode(ApplicationStreamDTO.self, from: body),
              let key = ApplicationStreamKey(rawValue: update.streamKey),
              let stream = update.merging(applicationStreams[key])
        else { return }
        reconcileApplicationStream(stream)
    }

    func handleStreamServerUpdateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let update = try? JSONValueDecoder().decode(
            ApplicationStreamServerUpdateDTO.self,
            from: body
        ) else { return }
        reconcileApplicationStreamServer(update)
    }

    func handleStreamDeleteDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let deletion = try? JSONValueDecoder().decode(
            ApplicationStreamDeleteDTO.self,
            from: body
        ), let key = ApplicationStreamKey(rawValue: deletion.streamKey)
        else { return }
        if deletion.unavailable != true {
            applicationStreams[key] = nil
        }
        applicationStreamConnections[key] = nil
        failApplicationStreamNegotiation(
            key: key,
            error: ChatProviderError.invalidRequest(
                deletion.reason ?? "Discord ended the screen share."
            )
        )
        continuation?.yield(
            .applicationStreamDeleted(
                key: key,
                unavailable: deletion.unavailable ?? false,
                reason: deletion.reason
            )
        )
    }

    func handleCallCreateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let update = try? JSONValueDecoder().decode(PrivateCallDTO.self, from: body),
              let call = update.domain()
        else { return }
        privateCallsByChannel[call.channelID] = call
        continuation?.yield(.privateCallChanged(call))
    }

    func handleCallUpdateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let update = try? JSONValueDecoder().decode(PrivateCallDTO.self, from: body),
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
    }

    func handleCallDeleteDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let deletion = try? JSONValueDecoder().decode(PrivateCallDeleteDTO.self, from: body),
              let channelID = ChannelID(deletion.channelID)
        else { return }
        privateCallsByChannel[channelID] = nil
        continuation?.yield(
            .privateCallDeleted(
                channelID: channelID,
                unavailable: deletion.unavailable ?? false
            )
        )
    }

    func handleVoiceChannelStatusUpdateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard
            let update = try? JSONValueDecoder().decode(
                GatewayVoiceChannelMetadataDTO.self, from: body
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
    }

    func handleVoiceStateUpdateDispatch(
        name: String,
        body: JSONValue
    ) async {
        guard let state = try? JSONValueDecoder().decode(VoiceStateUpdateDTO.self, from: body),
              let participant = state.domain()
        else { return }
        if participant.channelID != nil, let guildID = participant.guildID,
           cachedMemberIndex(guildID: guildID)[participant.userID] == nil,
           let payload = try? JSONValueDecoder().decode(VoiceStateMemberDTO.self, from: body)
        {
            cacheVoiceStateMember(payload.member, guildID: guildID)
        }
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
    }

    /// Admits a voice participant's member that is not cached yet, so voice
    /// presentations outside the selected guild can show who joined. The
    /// caller checks it is absent: this never replaces a cached member or
    /// publishes a member-list change.
    private func cacheVoiceStateMember(_ dto: GuildMemberDTO, guildID: GuildID) {
        guard let member = try? dto.domain(
            currentUserID: currentUser?.id,
            currentStatus: presenceStatus,
            guildRoles: cachedGuildRoles[guildID] ?? [],
            guildID: guildID
        ) else { return }
        cachedMembers[guildID, default: []].append(member)
    }
}
