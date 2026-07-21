import CoreVideo
import Foundation
@testable import MediaPipeline
import Testing

@Test func `native H 264 encoder and decoder produce displayable frame`() async throws {
    var pixelBuffer: CVPixelBuffer?
    let pixelStatus = CVPixelBufferCreate(
        kCFAllocatorDefault,
        320,
        180,
        kCVPixelFormatType_32BGRA,
        [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary,
        &pixelBuffer
    )
    #expect(pixelStatus == kCVReturnSuccess)
    let buffer = try #require(pixelBuffer)
    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
        memset(base, 0x55, CVPixelBufferGetDataSize(buffer))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])

    let encodedStream = AsyncStream<EncodedVideoFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let encoder = try H264VideoEncoder(width: 320, height: 180, framerate: 30, bitrate: 300_000) { frame in
        encodedStream.continuation.yield(frame)
        encodedStream.continuation.finish()
    }
    encoder.encode(pixelBuffer: buffer, presentationTime: .zero)
    encoder.completeFrames()
    let encoded = try #require(await firstValue(from: encodedStream.stream))
    #expect(encoded.isKeyframe)
    #expect(!AnnexB.split(frame: encoded.data).isEmpty)

    let decodedStream = AsyncStream<VoiceVideoFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let decoder = H264VideoDecoder { frame in
        decodedStream.continuation.yield(frame)
        decodedStream.continuation.finish()
    }
    try decoder.decode(annexBFrame: encoded.data)
    let decoded = try #require(await firstValue(from: decodedStream.stream))
    #expect(decoded.image.width == 320)
    #expect(decoded.image.height == 180)
}

private func firstValue<Element: Sendable>(from stream: AsyncStream<Element>) async -> Element? {
    await withTaskGroup(of: Element?.self) { group in
        group.addTask { await stream.first(where: { _ in true }) }
        group.addTask {
            try? await Task.sleep(for: .seconds(5))
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}
