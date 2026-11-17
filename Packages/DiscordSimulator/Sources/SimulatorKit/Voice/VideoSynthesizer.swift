import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import VideoToolbox

/// Video we generate ourselves for simulated cameras and Go Live streams: a
/// soft colour field with a drifting light, encoded as H.264 (what Discord
/// video carries) with a keyframe every second, so the loop can restart and
/// late viewers can start at any second.
enum VideoSynthesizer {
    enum Kind: Sendable { case camera, screen }

    static let width = 640, height = 360, framesPerSecond = 15
    private static let clips = Mutex<[String: [[Data]]]>([:])

    /// Each frame's NAL units (no start codes); keyframes begin with SPS and PPS.
    static func clip(seed: UInt64, kind: Kind) -> [[Data]] {
        let key = "\(seed)-\(kind)"
        if let cached = clips.withLock({ $0[key] }) { return cached }
        let clip = encode(seconds: 3, seed: seed, kind: kind)
        clips.withLock { $0[key] = clip }
        return clip
    }

    private static func encode(seconds: Int, seed: UInt64, kind: Kind) -> [[Data]] {
        var session: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr,
            let session else { return [] }
        defer { VTCompressionSessionInvalidate(session) }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: false, kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Baseline_AutoLevel,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: framesPerSecond, kVTCompressionPropertyKey_AverageBitRate: 600_000,
        ]
        for (key, value) in properties { VTSessionSetProperty(session, key: key, value: value as CFTypeRef) }
        let frames = Mutex<[[Data]]>([])
        for index in 0 ..< seconds * framesPerSecond {
            guard let image = render(frame: index, seed: seed, kind: kind) else { return [] }
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(framesPerSecond))
            VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: time, duration: .invalid,
                                            frameProperties: nil, infoFlagsOut: nil) { _, _, sample in
                if let sample { frames.withLock { $0.append(nalUnits(sample)) } }
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return frames.withLock { $0 }
    }

    /// AVCC sample to NAL units, with the parameter sets ahead of a keyframe.
    private static func nalUnits(_ sample: CMSampleBuffer) -> [Data] {
        var units: [Data] = []
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            for index in 0 ..< 2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    units.append(Data(bytes: pointer, count: size))
                }
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return units }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return units }
        let bytes = Data(bytes: pointer, count: length)
        var offset = 0
        while offset + 4 <= bytes.count {
            let size = bytes[offset ..< offset + 4].reduce(0) { $0 << 8 | Int($1) }
            offset += 4
            guard offset + size <= bytes.count else { break }
            units.append(bytes.subdata(in: offset ..< offset + size))
            offset += size
        }
        return units
    }

    /// One frame: a colour field from the seed with a drifting light (camera) or a scrolling page of bars (screen).
    private static func render(frame: Int, seed: UInt64, kind: Kind) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let hue = CGFloat(seed % 360) / 360
        let time = CGFloat(frame) / CGFloat(framesPerSecond)
        context.setFillColor(color(hue: hue, brightness: 0.35))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        switch kind {
        case .camera:
            let center = CGPoint(x: CGFloat(width) * (0.5 + 0.25 * sin(time * 2 * .pi / 3)), y: CGFloat(height) * (0.5 + 0.2 * cos(time * 2 * .pi / 3)))
            context.setFillColor(color(hue: hue + 0.08, brightness: 0.8))
            context.fillEllipse(in: CGRect(x: center.x - 70, y: center.y - 70, width: 140, height: 140))
        case .screen:
            for row in 0 ..< 12 {
                let top = (CGFloat(row) * 34 + time * 40).truncatingRemainder(dividingBy: CGFloat(height) + 34) - 34
                context.setFillColor(color(hue: hue + 0.5, brightness: row % 3 == 0 ? 0.9 : 0.6))
                context.fill(CGRect(x: 40, y: top, width: CGFloat(width - 80) * (0.4 + 0.5 * CGFloat((row * 7) % 5) / 5), height: 18))
            }
        }
        return buffer
    }

    private static func color(hue: CGFloat, brightness: CGFloat) -> CGColor {
        let wrapped = hue - floor(hue)
        let red = brightness * (0.5 + 0.5 * cos(2 * .pi * wrapped))
        let green = brightness * (0.5 + 0.5 * cos(2 * .pi * (wrapped - 1.0 / 3)))
        let blue = brightness * (0.5 + 0.5 * cos(2 * .pi * (wrapped - 2.0 / 3)))
        return CGColor(red: red, green: green, blue: blue, alpha: 1)
    }
}
