import AVFAudio
@testable import MediaPipeline
import Synchronization
import Testing

@Test func `opus packet duration follows its TOC sequence`() throws {
    #expect(try OpusPacket.sampleCount(Data([0b0001_1000])) == 2_880)
    #expect(try OpusPacket.sampleCount(Data([0b0110_0000])) == 480)
    #expect(try OpusPacket.sampleCount(Data([0b1000_0000])) == 120)
    #expect(try OpusPacket.sampleCount(Data([0b1000_0010])) == 240)
    #expect(try OpusPacket.sampleCount(Data([0b1000_0011, 0b0000_0100])) == 480)
}

@Test func `opus packet duration rejects missing and oversized frame counts`() {
    #expect(throws: OpusCodecError.invalidPacket) {
        try OpusPacket.sampleCount(Data([0b0001_1011]))
    }
    #expect(throws: OpusCodecError.invalidPacket) {
        try OpusPacket.sampleCount(Data([0b0001_1011, 0b0000_0000]))
    }
    #expect(throws: OpusCodecError.invalidPacket) {
        try OpusPacket.sampleCount(Data([0b0001_1011, 0b0000_0011]))
    }
}

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

@Test func `native opus codec decodes sixty millisecond packets`() throws {
    let packet = Data([0xFF, 0x03, 0xFF, 0xFE, 0xFF, 0xFE, 0xFF, 0xFE])
    let decoded = try OpusCodec().decode(packet)

    #expect(decoded.frameLength > OpusCodec.frameSamples)
    #expect(decoded.frameLength <= 2_880)
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

@Test func `voice capture encoder meters controlled audio and mutes transmitted samples`() throws {
    let encoder = try OpusSampleBufferEncoder()
    let capturedFrames = Mutex<[CapturedOpusFrame]>([])
    let capturedLevels = Mutex<[Float]>([])
    encoder.handler = { frame in
        capturedFrames.withLock { $0.append(frame) }
    }
    encoder.levelHandler = { level in
        capturedLevels.withLock { $0.append(level) }
    }
    let format = OpusCodec.pcmFormat
    let input = try #require(AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: OpusCodec.frameSamples
    ))
    input.frameLength = OpusCodec.frameSamples
    for channel in 0 ..< Int(format.channelCount) {
        let samples = try #require(input.floatChannelData?[channel])
        for index in 0 ..< Int(input.frameLength) {
            samples[index] = Float(sin(Double(index) * 0.1)) * 0.08
        }
    }

    encoder.process(input)

    #expect(capturedFrames.withLock { $0.count } == 1)
    #expect(capturedFrames.withLock { $0.first?.containsVoice } == true)
    #expect(capturedLevels.withLock { ($0.last ?? 0) > 0 })

    encoder.isMuted = true
    encoder.process(input)

    #expect(capturedFrames.withLock { $0.count } == 2)
    #expect(capturedFrames.withLock { $0.last?.containsVoice } == false)
    #expect(capturedLevels.withLock { $0.last } == 0)
    encoder.reset()
}

@Test func `muted voice capture transmits injected sound without microphone audio`() throws {
    let encoder = try OpusSampleBufferEncoder()
    let capturedFrames = Mutex<[CapturedOpusFrame]>([])
    encoder.handler = { frame in capturedFrames.withLock { $0.append(frame) } }
    encoder.isMuted = true
    let samples = (0 ..< Int(OpusCodec.frameSamples)).map {
        Float(sin(Double($0) * 0.09)) * 0.25
    }
    let clip = try SoundboardPCMClip(left: samples, right: samples)
    #expect(encoder.enqueueInjectedAudio(clip, volume: 1))

    let input = try #require(AVAudioPCMBuffer(
        pcmFormat: OpusCodec.pcmFormat,
        frameCapacity: OpusCodec.frameSamples
    ))
    input.frameLength = OpusCodec.frameSamples
    for channel in 0 ..< 2 {
        let channelSamples = try #require(input.floatChannelData?[channel])
        for index in samples.indices { channelSamples[index] = 0.8 }
    }
    encoder.process(input)

    let frame = try #require(capturedFrames.withLock { $0.last })
    #expect(frame.containsVoice)
    #expect(!frame.containsMicrophoneVoice)
    #expect(frame.containsInjectedAudio)
    let decoded = try OpusCodec().decode(frame.data)
    let decodedSamples = try #require(decoded.floatChannelData?[0])
    let peak = (0 ..< Int(decoded.frameLength)).reduce(Float.zero) {
        max($0, abs(decodedSamples[$1]))
    }
    #expect(peak > 0.05)
    #expect(!encoder.hasActiveInjectedAudio)
}

@Test func `soundboard mixer overlaps triggers limits samples and stays realtime safe`() throws {
    let mixer = OutgoingSoundboardMixer()
    let clip = try SoundboardPCMClip(
        left: Array(repeating: 0.8, count: 96_000),
        right: Array(repeating: -0.8, count: 96_000)
    )
    for _ in 0 ..< 40 { #expect(mixer.enqueue(clip, volume: 1)) }
    #expect(mixer.diagnostics.peakConcurrentVoices == 32)
    var left = Array(repeating: Float(0.7), count: 960)
    var right = Array(repeating: Float(-0.7), count: 960)
    let clock = ContinuousClock()
    let start = clock.now
    for _ in 0 ..< 100 {
        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                _ = mixer.mix(
                    into: leftBuffer.baseAddress!,
                    rightBuffer.baseAddress!,
                    count: leftBuffer.count
                )
            }
        }
    }
    let elapsed = start.duration(to: clock.now)
    #expect(left.allSatisfy { (-1 ... 1).contains($0) })
    #expect(right.allSatisfy { (-1 ... 1).contains($0) })
    #expect(mixer.diagnostics.mixedFrameCount == 96_000)
    #expect(elapsed < .seconds(2))
}
