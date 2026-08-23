@preconcurrency import AVFoundation
import CoreImage
import Foundation
import VideoToolbox

public struct EncodedVideoFrame: Sendable {
    public var data: Data
    public var rtpTimestamp: UInt32
    public var isKeyframe: Bool
}

public final class VoiceVideoFrame: Identifiable, Equatable, @unchecked Sendable {
    public let id = UUID()
    public let image: CGImage

    public init(image: CGImage) {
        self.image = image
    }

    public static func == (lhs: VoiceVideoFrame, rhs: VoiceVideoFrame) -> Bool {
        lhs.id == rhs.id
    }
}

public enum VoiceVideoError: Error, Equatable {
    case cameraPermissionDenied
    case cameraUnavailable
    case cameraInputUnavailable
    case encoderCreationFailed(OSStatus)
    case encoderConfigurationFailed(OSStatus)
    case encodingFailed(OSStatus)
    case malformedEncodedFrame
    case decoderCreationFailed(OSStatus)
    case decodingFailed(OSStatus)
}

public final class VoiceVideoEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public static let width = 1280
    public static let height = 720
    public static let framerate = 30
    public static let bitrate = 2_500_000

    private let captureSession = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "app.sakuracord.video.capture", qos: .userInteractive)
    private let encoder: H264VideoEncoder
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let encodedFrameHandler: @Sendable (EncodedVideoFrame) -> Void
    private let previewFrameHandler: @Sendable (VoiceVideoFrame) -> Void
    private var lastPreviewTime = CFAbsoluteTimeGetCurrent()

    public init(
        encodedFrameHandler: @escaping @Sendable (EncodedVideoFrame) -> Void,
        previewFrameHandler: @escaping @Sendable (VoiceVideoFrame) -> Void
    ) throws {
        self.encodedFrameHandler = encodedFrameHandler
        self.previewFrameHandler = previewFrameHandler
        encoder = try H264VideoEncoder(
            width: Self.width,
            height: Self.height,
            framerate: Self.framerate,
            bitrate: Self.bitrate,
            output: encodedFrameHandler
        )
        super.init()
    }

    public static func requestCameraPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    public func start(cameraUniqueID: String?) throws {
        guard let camera = MediaDeviceCatalog.camera(uniqueID: cameraUniqueID) else {
            throw VoiceVideoError.cameraUnavailable
        }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: camera) } catch { throw VoiceVideoError.cameraInputUnavailable }

        // AVCaptureSession forbids startRunning while a configuration transaction
        // is open. Keep the complete transaction and startup on one serial queue;
        // otherwise the async start can race commitConfiguration and raise an
        // Objective-C exception, which aborts Swift processes rather than throwing.
        try captureQueue.sync { [captureSession] in
            captureSession.beginConfiguration()
            do {
                captureSession.sessionPreset = .hd1280x720
                for existing in captureSession.inputs {
                    captureSession.removeInput(existing)
                }
                for existing in captureSession.outputs {
                    captureSession.removeOutput(existing)
                }
                guard captureSession.canAddInput(input) else { throw VoiceVideoError.cameraInputUnavailable }
                captureSession.addInput(input)

                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                ]
                output.setSampleBufferDelegate(self, queue: captureQueue)
                guard captureSession.canAddOutput(output) else { throw VoiceVideoError.cameraUnavailable }
                captureSession.addOutput(output)
                if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = camera.position == .front
                }
                captureSession.commitConfiguration()
            } catch {
                captureSession.commitConfiguration()
                throw error
            }
            captureSession.startRunning()
        }
    }

    public func stop() {
        captureQueue.sync { [captureSession, encoder] in
            captureSession.stopRunning()
            encoder.finish()
        }
    }

    public func requestKeyframe() {
        captureQueue.async { [encoder] in encoder.requestKeyframe() }
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        encoder.encode(pixelBuffer: pixelBuffer, presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPreviewTime >= 1.0 / 15.0 else { return }
        lastPreviewTime = now
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = imageContext.createCGImage(image, from: image.extent) else { return }
        previewFrameHandler(VoiceVideoFrame(image: cgImage))
    }
}

final class H264VideoEncoder: @unchecked Sendable {
    private final class FrameFailure: @unchecked Sendable {
        private let lock = NSLock()
        private var didReport = false
        private let handler: @Sendable () -> Void

        init(handler: @escaping @Sendable () -> Void) {
            self.handler = handler
        }

        func report() {
            let shouldReport = lock.withLock { () -> Bool in
                guard !didReport else { return false }
                didReport = true
                return true
            }
            if shouldReport {
                handler()
            }
        }
    }

    private var session: VTCompressionSession?
    private let output: @Sendable (EncodedVideoFrame) -> Void
    private let didDropFrame: @Sendable () -> Void
    private let framerate: Int
    private var shouldForceKeyframe = true

    init(
        width: Int,
        height: Int,
        framerate: Int,
        bitrate: Int,
        didDropFrame: @escaping @Sendable () -> Void = {},
        output: @escaping @Sendable (EncodedVideoFrame) -> Void
    ) throws {
        self.output = output
        self.didDropFrame = didDropFrame
        self.framerate = framerate
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else { throw VoiceVideoError.encoderCreationFailed(status) }
        session = created
        try set(kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        try set(kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        try set(kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel)
        try? set(kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CAVLC)
        try? set(kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        // Some hardware encoders expose this key as read-only/unsupported. The
        // constrained profile and zero frame delay still enforce no reordering.
        try? set(kVTCompressionPropertyKey_ReferenceBufferCount, value: 1 as CFNumber)
        try set(kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        // AverageBitRate alone permits large motion bursts. Discord's media
        // transport advertises a hard maximum, so bound VideoToolbox to the
        // same one-second byte window instead of overflowing the RTP sender.
        try? set(
            kVTCompressionPropertyKey_DataRateLimits,
            value: [max(1, bitrate / 8), 1] as CFArray
        )
        try set(kVTCompressionPropertyKey_ExpectedFrameRate, value: framerate as CFNumber)
        try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (framerate * 2) as CFNumber)
        try? set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2 as CFNumber)
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(created)
        guard prepareStatus == noErr else { throw VoiceVideoError.encoderConfigurationFailed(prepareStatus) }
    }

    deinit {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let session else { return }
        let duration = CMTime(value: 1, timescale: CMTimeScale(framerate))
        let frameProperties: CFDictionary? = shouldForceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        let failure = FrameFailure(handler: didDropFrame)
        var infoFlags: UInt32 = 0
        let output = self.output
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: frameProperties,
            infoFlagsOut: &infoFlags
        ) { status, infoFlags, sampleBuffer in
            guard status == noErr,
                  infoFlags & 0x2 == 0,
                  let sampleBuffer,
                  CMSampleBufferDataIsReady(sampleBuffer),
                  let encoded = H264VideoEncoder.annexB(from: sampleBuffer)
            else {
                failure.report()
                return
            }
            output(encoded)
        }
        guard status == noErr, infoFlags & 0x2 == 0 else {
            failure.report()
            return
        }
        shouldForceKeyframe = false
    }

    /// Drains callbacks before invalidating the session. The owner must call
    /// every encoder operation, including this one, from its serial capture
    /// queue; VideoToolbox compression sessions are not Sendable.
    func finish() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    func requestKeyframe() {
        shouldForceKeyframe = true
    }

    private func set(_ key: CFString, value: CFTypeRef) throws {
        guard let session else { throw VoiceVideoError.encoderCreationFailed(-1) }
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else { throw VoiceVideoError.encoderConfigurationFailed(status) }
    }

    private static func annexB(from sampleBuffer: CMSampleBuffer) -> EncodedVideoFrame? {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        var output = Data()
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            for index in 0 ..< 2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                var count = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: &count,
                    nalUnitHeaderLengthOut: nil
                )
                guard status == noErr, let pointer else { continue }
                AnnexB.append(nalUnit: UnsafeBufferPointer(start: pointer, count: size), to: &output)
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            block,
            atOffset: 0,
            lengthAtOffsetOut: &length,
            totalLengthOut: &totalLength,
            dataPointerOut: &pointer
        ) == noErr, let pointer else { return nil }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: totalLength).bindMemory(to: UInt8.self)
        var offset = 0
        while offset + 4 <= totalLength {
            let naluLength = (Int(bytes[offset]) << 24)
                | (Int(bytes[offset + 1]) << 16)
                | (Int(bytes[offset + 2]) << 8)
                | Int(bytes[offset + 3])
            offset += 4
            guard naluLength > 0, offset + naluLength <= totalLength else { return nil }
            AnnexB.append(nalUnit: bytes[offset ..< (offset + naluLength)], to: &output)
            offset += naluLength
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = CMTimeGetSeconds(time)
        let timestamp = seconds.isFinite ? UInt32(truncatingIfNeeded: UInt64(max(0, seconds * 90000))) : 0
        return EncodedVideoFrame(
            data: H264SPSVUIRewriter.rewriteAnnexBFrame(output),
            rtpTimestamp: timestamp,
            isKeyframe: isKeyframe
        )
    }
}

public final class H264VideoDecoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let decodeQueue = DispatchQueue(label: "dev.sakuracord.video.decode", qos: .userInteractive)
    private let output: @Sendable (VoiceVideoFrame) -> Void

    public init(output: @escaping @Sendable (VoiceVideoFrame) -> Void) {
        self.output = output
    }

    deinit {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
    }

    /// Queues hardware decode independently from the voice-session actor. RTP
    /// receive and Opus playback must never wait for VideoToolbox or Core Image.
    public func enqueue(
        annexBFrame: Data,
        onFailure: @escaping @Sendable () -> Void
    ) {
        decodeQueue.async { [weak self] in
            guard let self else { return }
            do {
                try decode(annexBFrame: annexBFrame)
            } catch {
                onFailure()
            }
        }
    }

    public func decode(annexBFrame: Data) throws {
        let nalUnits = AnnexB.split(frame: annexBFrame)
        guard !nalUnits.isEmpty else { throw VoiceVideoError.malformedEncodedFrame }
        var mediaNALUnits: [Data] = []
        var parametersChanged = false
        for nalu in nalUnits {
            guard let type = nalu.first.map({ $0 & 0x1F }) else { continue }
            switch type {
            case 7:
                if sps != nalu {
                    sps = nalu; parametersChanged = true
                }
            case 8:
                if pps != nalu {
                    pps = nalu; parametersChanged = true
                }
            default:
                mediaNALUnits.append(nalu)
            }
        }
        if parametersChanged || session == nil {
            try createSession()
        }
        guard let session, let formatDescription, !mediaNALUnits.isEmpty else { return }

        var avcc = Data()
        for nalu in mediaNALUnits {
            avcc.appendBigEndian(UInt32(nalu.count))
            avcc.append(nalu)
        }
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == noErr, let blockBuffer else { throw VoiceVideoError.decodingFailed(blockStatus) }
        let copyStatus = avcc.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard copyStatus == noErr else { throw VoiceVideoError.decodingFailed(copyStatus) }
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avcc.count
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { throw VoiceVideoError.decodingFailed(sampleStatus) }
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: VTDecodeFrameFlags(rawValue: 0),
            frameRefcon: nil,
            infoFlagsOut: nil
        )
        guard decodeStatus == noErr else { throw VoiceVideoError.decodingFailed(decodeStatus) }
    }

    private func createSession() throws {
        guard let sps, let pps else { return }
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        var description: CMFormatDescription?
        let descriptionStatus: OSStatus = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [
                    spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!
                ]
                let sizes = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description
                        )
                    }
                }
            }
        }
        guard descriptionStatus == noErr, let description else {
            throw VoiceVideoError.decoderCreationFailed(descriptionStatus)
        }
        formatDescription = description
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: H264VideoDecoder.outputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &created
        )
        guard status == noErr, let created else { throw VoiceVideoError.decoderCreationFailed(status) }
        session = created
    }

    private static let outputCallback: VTDecompressionOutputCallback = { refcon, _, status, _, imageBuffer, _, _ in
        guard status == noErr, let refcon, let imageBuffer else { return }
        let decoder = Unmanaged<H264VideoDecoder>.fromOpaque(refcon).takeUnretainedValue()
        let image = CIImage(cvPixelBuffer: imageBuffer)
        guard let cgImage = decoder.imageContext.createCGImage(image, from: image.extent) else { return }
        decoder.output(VoiceVideoFrame(image: cgImage))
    }
}
