import AVFAudio
@testable import MediaPipeline
import Testing

@Test func `native opus codec produces discord twenty millisecond frames`() throws {
    let codec = try OpusCodec()
    let format = OpusCodec.pcmFormat
    let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: OpusCodec.frameSamples))
    input.frameLength = OpusCodec.frameSamples
    for channel in 0 ..< Int(format.channelCount) {
        let samples = try #require(input.floatChannelData?[channel])
        for index in 0 ..< Int(input.frameLength) {
            samples[index] = Float(sin(Double(index) * 0.08)) * 0.05
        }
    }

    let packet = try codec.encode(input)
    let decoded = try codec.decode(packet)

    #expect(!packet.isEmpty)
    #expect(packet.count <= OpusCodec.maximumPacketSize)
    #expect(decoded.format.sampleRate == 48000)
    #expect(decoded.format.channelCount == 2)
    #expect(decoded.frameLength > 0)
}

@Test func `native opus codec encodes and decodes consecutive voice packets`() throws {
    let codec = try OpusCodec()
    let format = OpusCodec.pcmFormat
    let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: OpusCodec.frameSamples))
    input.frameLength = OpusCodec.frameSamples
    for channel in 0 ..< Int(format.channelCount) {
        let samples = try #require(input.floatChannelData?[channel])
        for index in 0 ..< Int(input.frameLength) {
            samples[index] = Float(sin(Double(index) * 0.11)) * 0.08
        }
    }

    for _ in 0 ..< 20 {
        let packet = try codec.encode(input)
        let decoded = try codec.decode(packet)
        #expect(!packet.isEmpty)
        #expect(decoded.frameLength > 0)
    }
}

@Test func `media device catalog returns only usable directions`() {
    let snapshot = MediaDeviceCatalog.snapshot()
    #expect(snapshot.audioInputs.allSatisfy { !$0.name.isEmpty && !$0.uid.isEmpty })
    #expect(snapshot.audioOutputs.allSatisfy { !$0.name.isEmpty && !$0.uid.isEmpty })
    #expect(snapshot.cameras.allSatisfy { !$0.name.isEmpty && !$0.uniqueID.isEmpty })
}
