import Foundation

/// Watching a simulated person's Go Live stream the way a client does: op 20,
/// the stream's own voice server, DAVE on that connection, then one H.264
/// frame reassembled from RTP and decrypted end to end.
extension ParityRun {
    mutating func watchSimulatedStream(guild: Snowflake, channel: Snowflake, me: Snowflake, streamer: Snowflake) async throws {
        let world = simulator.world
        guard let probe = gateway, let sessionID = await world.voiceState(of: me)?.sessionID else { return }
        await flowStart()
        _ = try await world.updateVoiceState(streamer, sessionID: "parity-streamer", VoiceStateRequest(guildID: guild, channelID: channel), simulated: true)
        try await world.createStream(streamer, sessionID: "parity-streamer", channelID: channel, guildID: guild, region: nil)
        let key = GoLiveStream.key(userID: streamer, channelID: channel, guildID: guild)
        let preview = try await rest("GET", "/api/v9/streams/\(key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key)/preview")
        if preview["url"]?.stringValue?.hasPrefix("https://media.discordapp.net/") != true {
            report.sequenceFailures.append("go-live watch: a simulated stream's preview has no media URL")
        }
        await flowStart()
        try await probe.send(.object(JSONObject([("op", 20), ("d", .object(JSONObject([("stream_key", .string(key))])))])))
        let frames = await voiceFlow("go-live-watch", expecting: ["STREAM_CREATE", "STREAM_SERVER_UPDATE"])
        guard let created = frames.first(where: { $0.name == "STREAM_CREATE" })?.payload["d"],
              let server = created["rtc_server_id"]?.stringValue, let rtcChannel = created["rtc_channel_id"]?.stringValue.flatMap(Snowflake.init),
              let token = frames.first(where: { $0.name == "STREAM_SERVER_UPDATE" })?.payload["d"]?["token"]?.stringValue
        else { return }
        let failure = await Self.watch(simulator: simulator, server: server, token: token, channel: rtcChannel, me: me, sessionID: sessionID,
                                       streamer: streamer)
        report.checked.append("GO LIVE watch with DAVE")
        if let failure { report.sequenceFailures.append("go-live watch: \(failure)") }
        await flowStart()
        await world.leaveVoice(streamer)
    }

    private static func watch(simulator: DiscordSimulator, server: String, token: String, channel: Snowflake, me: Snowflake,
                              sessionID: String, streamer: Snowflake) async -> String? {
        let probe = VoiceProbe(url: URL(string: "ws://127.0.0.1:\(simulator.port(.voice))/?v=8")!)
        let udp = UDPProbe(port: simulator.port(.voiceMedia))
        defer {
            probe.close()
            udp.close()
        }
        guard let key = await probe.connect([
            ("server_id", .string(server)), ("channel_id", .string(channel.description)), ("user_id", .string(me.description)),
            ("session_id", .string(sessionID)), ("token", .string(token)), ("max_dave_protocol_version", 1), ("video", true),
            ("streams", [["type": "screen", "rid": "100", "quality": 100]]),
        ], udp: udp)?.key else { return "no ready, IP discovery or session description on the stream server" }
        guard let package = await probe.waitForBinary(op: 25),
              let member = DaveMember(userID: me, groupID: channel, externalSender: package, recognized: [streamer])
        else { return "no DAVE external sender on the stream connection" }
        probe.sendBinary(Data([26]) + member.keyPackage())
        guard await probe.acceptWelcome(into: member) else { return "no DAVE welcome and transition into the stream's group" }
        guard let video = await probe.waitFor(op: 12, where: { $0["d"]?["video_ssrc"]?.intValue ?? 0 != 0 })?["d"]?["video_ssrc"]?.intValue else {
            return "no op 12 with the streamer's video SSRC"
        }
        return await decryptFrame(from: udp, ssrc: UInt32(video), key: key, member: member, streamer: streamer)
            ? nil : "no stream video frame decrypts"
    }

    /// Reassembles RTP H.264 (single NAL units and FU-A) into Annex B frames until one DAVE-decrypts.
    private static func decryptFrame(from udp: UDPProbe, ssrc: UInt32, key: [UInt8], member: DaveMember, streamer: Snowflake) async -> Bool {
        var units: [Data] = []
        for _ in 0 ..< 1_500 {
            guard let packet = await udp.receive() else { return false }
            guard let (header, payload) = try? VoiceCrypto.open(packet, key: key, mode: .aes256GCM),
                  header[8 ..< 12].reduce(0, { $0 << 8 | UInt32($1) }) == ssrc, let first = payload.first else { continue }
            if first & 0x1F == 28, payload.count > 2 {
                let fragment = payload[payload.startIndex + 1]
                if fragment & 0x80 != 0 { units.append(Data([first & 0xE0 | fragment & 0x1F])) }
                if !units.isEmpty { units[units.count - 1] += payload.dropFirst(2) }
            } else {
                units.append(Data(payload))
            }
            guard header[1] & 0x80 != 0 else { continue }
            let frame = units.reduce(Data()) { $0 + Data([0, 0, 0, 1]) + $1 }
            units = []
            if member.decrypt(frame, from: streamer, video: true) != nil { return true }
        }
        return false
    }
}
