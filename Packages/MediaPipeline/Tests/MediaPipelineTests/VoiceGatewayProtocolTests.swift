import Foundation
@testable import MediaPipeline
import Testing

@Test func `voice gateway JSON codec decodes version eight events`() throws {
    let ready = try VoiceGatewayCodec.decodeJSON(Data(#"{"op":2,"d":{"ssrc":42,"ip":"127.0.0.1","port":5000,"modes":["aead_aes256_gcm_rtpsize"]},"seq":7}"#.utf8))
    #expect(ready == SequencedVoiceGatewayEvent(
        sequence: 7,
        event: .ready(VoiceGatewayReady(
            ssrc: 42,
            ip: "127.0.0.1",
            port: 5000,
            modes: ["aead_aes256_gcm_rtpsize"]
        ))
    ))

    let speaking = try VoiceGatewayCodec.decodeJSON(Data(#"{"op":5,"d":{"speaking":1,"ssrc":99,"user_id":"123"},"seq":8}"#.utf8))
    #expect(speaking.event == .speaking(userID: "123", ssrc: 99, flags: 1))
}

@Test func `voice gateway binary codec separates sequence opcode and transition`() throws {
    var data = Data([0, 44, 29, 0, 9])
    data.append(contentsOf: [1, 2, 3])
    let event = try VoiceGatewayCodec.decodeBinary(data)
    #expect(event.sequence == 44)
    #expect(event.event == .daveMLSAnnounceCommit(transitionID: 9, commit: Data([1, 2, 3])))
}

@Test func `dave execute transition allows implicit initial transition ID`() throws {
    let event = try VoiceGatewayCodec.decodeJSON(Data(#"{"op":22,"d":{},"seq":12}"#.utf8))
    #expect(event.event == .daveExecuteTransition(transitionID: 0))
}

@Test func `voice gateway identify advertises DAVE and resume acknowledges sequence`() throws {
    let identify = try VoiceGatewayCodec.identify(
        serverID: "10",
        userID: "20",
        sessionID: "session",
        token: "token",
        maxDaveProtocolVersion: 1
    )
    let identifyObject = try #require(JSONSerialization.jsonObject(with: Data(identify.utf8)) as? [String: Any])
    #expect(identifyObject["op"] as? Int == 0)
    let identifyData = try #require(identifyObject["d"] as? [String: Any])
    #expect(identifyData["max_dave_protocol_version"] as? Int == 1)
    #expect(identifyData["video"] as? Bool == true)
    #expect((identifyData["streams"] as? [[String: Any]])?.first?["rid"] as? String == "100")

    let resume = try VoiceGatewayCodec.resume(serverID: "10", sessionID: "session", token: "token", sequence: 71)
    let resumeObject = try #require(JSONSerialization.jsonObject(with: Data(resume.utf8)) as? [String: Any])
    let resumeData = try #require(resumeObject["d"] as? [String: Any])
    #expect(resumeData["seq_ack"] as? Int == 71)
}

@Test func `voice gateway video codec supports streams and sink wants`() throws {
    let protocolSelection = try VoiceGatewayCodec.selectProtocol(
        address: "127.0.0.1",
        port: 50000,
        mode: .aes256GCMRTPSize
    )
    let selectionObject = try #require(
        JSONSerialization.jsonObject(with: Data(protocolSelection.utf8)) as? [String: Any]
    )
    let selectionData = try #require(selectionObject["d"] as? [String: Any])
    let codecs = try #require(selectionData["codecs"] as? [[String: Any]])
    let h264 = try #require(codecs.first { $0["name"] as? String == "H264" })
    #expect(h264["payload_type"] as? Int == 105)
    #expect(h264["rtx_payload_type"] as? Int == 106)

    let video = try VoiceGatewayCodec.decodeJSON(Data(#"{"op":12,"d":{"user_id":"55","audio_ssrc":11,"video_ssrc":12,"rtx_ssrc":13,"streams":[{"type":"video","rid":"100","ssrc":12,"rtx_ssrc":13,"active":true,"quality":100,"max_framerate":30,"max_resolution":{"type":"fixed","width":1280,"height":720}}]},"seq":9}"#.utf8))
    guard case let .video(state) = video.event else {
        Issue.record("Expected a video event")
        return
    }
    #expect(state.userID == "55")
    #expect(state.streams.first?.width == 1280)

    let wants = try VoiceGatewayCodec.videoSinkWants([12: 100, 22: 0], any: 50)
    let object = try #require(JSONSerialization.jsonObject(with: Data(wants.utf8)) as? [String: Any])
    let data = try #require(object["d"] as? [String: Int])
    #expect(data["12"] == 100)
    #expect(data["22"] == 0)
    #expect(data["any"] == 50)
}

@Test func `voice gateway video state allows discord to omit legacy RTX fields`() throws {
    let event = try VoiceGatewayCodec.decodeJSON(Data(#"""
    {
        "op":12,
        "d":{"user_id":"55","audio_ssrc":14662,"video_ssrc":0,"streams":[]},
        "seq":10
    }
    """#.utf8))
    guard case let .video(state) = event.event else {
        Issue.record("Expected a video event")
        return
    }

    #expect(state.userID == "55")
    #expect(state.audioSSRC == 14662)
    #expect(state.rtxSSRC == 0)
    #expect(state.streams.isEmpty)
}
