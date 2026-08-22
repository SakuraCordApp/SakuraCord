@preconcurrency import CoreImage
@preconcurrency import ScreenCaptureKit
import CoreMedia
import Foundation
import OSLog

private let screenCaptureLogger = Logger(
    subsystem: "dev.sakuracord.SakuraCord",
    category: "ScreenShareCapture"
)

private struct ScreenShareSettingsUpdateContext {
    var previousSettings: ScreenShareSettings
    var filter: SCContentFilter
    var stream: SCStream
}

private struct ScreenShareEncodingContext {
    var filter: SCContentFilter
    var stream: SCStream
    var format: ScreenShareVideoFormat
    var includesAudio: Bool
}

private struct ScreenShareDemandTransition {
    var shouldStartEncoder: Bool
    var format: ScreenShareVideoFormat?
    var audioEncoderToReset: OpusSampleBufferEncoder?
}

public enum ScreenShareFrameRate: Int, CaseIterable, Codable, Equatable, Sendable {
    case fps15 = 15
    case fps30 = 30
    case fps60 = 60

    public var title: String { "\(rawValue) FPS" }
}

public enum ScreenShareQuality: String, CaseIterable, Codable, Equatable, Sendable {
    case p720
    case p1080
    case p1440
    case source

    public var title: String {
        switch self {
        case .p720: "720p"
        case .p1080: "1080p"
        case .p1440: "1440p"
        case .source: "Source"
        }
    }

    var targetHeight: Int? {
        switch self {
        case .p720: 720
        case .p1080: 1_080
        case .p1440: 1_440
        case .source: nil
        }
    }
}

public struct ScreenShareSettings: Codable, Equatable, Sendable {
    public var frameRate: ScreenShareFrameRate
    public var quality: ScreenShareQuality
    public var includesAudio: Bool

    public init(
        frameRate: ScreenShareFrameRate = .fps30,
        quality: ScreenShareQuality = .p1080,
        includesAudio: Bool = true
    ) {
        self.frameRate = frameRate
        self.quality = quality
        self.includesAudio = includesAudio
    }
}

public struct ScreenShareVideoFormat: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: Int
    public var bitrate: Int
}

public enum ScreenShareCaptureState: Equatable, Sendable {
    case idle
    case starting
    case previewing
    case sharing
    case interrupted
    case failed(String)
    case stopped
}

public enum ScreenShareCaptureEvent: Equatable, Sendable {
    case stateChanged(ScreenShareCaptureState)
    case sourceChanged(String)
    case pickerCancelled
    case error(String)
}

public enum ScreenShareCaptureError: LocalizedError, Equatable, Sendable {
    case unavailable
    case outputUnavailable
    case encoderUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Screen sharing is unavailable. Check Screen Recording access in System Settings."
        case .outputUnavailable:
            "SakuraCord could not attach to the selected screen source."
        case .encoderUnavailable(let message):
            "The screen-share encoder could not start: \(message)"
        }
    }
}

/// Owns one system-selected ScreenCaptureKit stream. Capture starts only after
/// the user selects a source; H.264 encoding is attached only after the user
/// confirms sharing so an idle preview does not pay encoder or network costs.
public final class ScreenShareCaptureEngine: NSObject, @unchecked Sendable {
    public nonisolated let events: AsyncStream<ScreenShareCaptureEvent>
    public nonisolated let previewFrames: AsyncStream<VoiceVideoFrame>
    public nonisolated let encodedFrames: AsyncStream<EncodedVideoFrame>
    public nonisolated let encodedAudioFrames: AsyncStream<CapturedOpusFrame>

    private let eventContinuation: AsyncStream<ScreenShareCaptureEvent>.Continuation
    private let previewContinuation: AsyncStream<VoiceVideoFrame>.Continuation
    private let encodedContinuation: AsyncStream<EncodedVideoFrame>.Continuation
    private let encodedAudioContinuation: AsyncStream<CapturedOpusFrame>.Continuation
    private let captureQueue = DispatchQueue(
        label: "dev.sakuracord.screen-share.capture",
        qos: .userInitiated
    )
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var stream: SCStream?
    private var filter: SCContentFilter?
    private var configuration: SCStreamConfiguration?
    private var settings: ScreenShareSettings
    private var format: ScreenShareVideoFormat?
    private var encoder: H264VideoEncoder?
    private var audioEncoder: OpusSampleBufferEncoder?
    private var isEncoding = false
    private var hasNetworkDemand = true
    private var isPreviewEnabled = true
    private var isPickerObserverInstalled = false
    private var lastPreviewTime = CFAbsoluteTimeGetCurrent()
    private var isStopped = false
    private var encodedFrameDropCount = 0

    public init(settings: ScreenShareSettings = .init()) {
        self.settings = settings
        let events = AsyncStream<ScreenShareCaptureEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(100)
        )
        self.events = events.stream
        eventContinuation = events.continuation
        let preview = AsyncStream<VoiceVideoFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        previewFrames = preview.stream
        previewContinuation = preview.continuation
        let encoded = AsyncStream<EncodedVideoFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(2)
        )
        encodedFrames = encoded.stream
        encodedContinuation = encoded.continuation
        let encodedAudio = AsyncStream<CapturedOpusFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        encodedAudioFrames = encodedAudio.stream
        encodedAudioContinuation = encodedAudio.continuation
        super.init()
    }

    deinit {
        eventContinuation.finish()
        previewContinuation.finish()
        encodedContinuation.finish()
        encodedAudioContinuation.finish()
    }

    public func preparePreview() async throws {
        let picker = await MainActor.run { SCContentSharingPicker.shared }
        guard await MainActor.run(body: { picker.isAvailable }) else {
            throw ScreenShareCaptureError.unavailable
        }
        await configurePicker(picker)
    }

    public func presentSourcePicker() async {
        let picker = await MainActor.run { SCContentSharingPicker.shared }
        guard await MainActor.run(body: { picker.isAvailable }) else {
            eventContinuation.yield(.error(ScreenShareCaptureError.unavailable.localizedDescription))
            return
        }
        await configurePicker(picker)
        await MainActor.run {
            if let stream = self.lock.withLock({ self.stream }) {
                picker.present(for: stream)
            } else {
                picker.present()
            }
        }
    }

    public func updateSettings(_ settings: ScreenShareSettings) async throws {
        let current = lock.withLock { () -> ScreenShareSettingsUpdateContext? in
            let previous = self.settings
            self.settings = settings
            guard let filter, let stream else { return nil }
            return ScreenShareSettingsUpdateContext(
                previousSettings: previous,
                filter: filter,
                stream: stream
            )
        }
        guard let current else { return }
        let previous = current.previousSettings
        if settings.includesAudio, lock.withLock({ isEncoding }) {
            do {
                try prepareAudioEncoderIfNeeded()
            } catch {
                lock.withLock { self.settings = previous }
                throw error
            }
        }
        let (configuration, format) = makeConfiguration(filter: current.filter)
        do {
            try await current.stream.updateConfiguration(configuration)
        } catch {
            lock.withLock { self.settings = previous }
            throw error
        }
        lock.withLock {
            self.configuration = configuration
            self.format = format
        }
        if previous.includesAudio, !settings.includesAudio {
            lock.withLock { audioEncoder }?.reset()
        }
        let videoChanged = previous.frameRate != settings.frameRate
            || previous.quality != settings.quality
        if videoChanged, lock.withLock({ isEncoding && hasNetworkDemand }) {
            try replaceEncoder(format: format)
        }
    }

    public func beginEncoding() async throws -> ScreenShareVideoFormat {
        let current = lock.withLock { () -> ScreenShareEncodingContext? in
            guard let filter, let stream, let format else { return nil }
            return ScreenShareEncodingContext(
                filter: filter,
                stream: stream,
                format: format,
                includesAudio: settings.includesAudio
            )
        }
        guard let current else {
            throw ScreenShareCaptureError.outputUnavailable
        }
        if current.includesAudio {
            try prepareAudioEncoderIfNeeded()
        }
        try replaceEncoder(format: current.format)
        lock.withLock {
            isEncoding = true
            hasNetworkDemand = true
        }
        let (configuration, updatedFormat) = makeConfiguration(filter: current.filter)
        do {
            try await current.stream.updateConfiguration(configuration)
        } catch {
            lock.withLock {
                isEncoding = false
                encoder?.completeFrames()
                encoder = nil
            }
            throw error
        }
        lock.withLock {
            self.configuration = configuration
            self.format = updatedFormat
        }
        eventContinuation.yield(.stateChanged(.sharing))
        return updatedFormat
    }

    public var currentVideoFormat: ScreenShareVideoFormat? {
        lock.withLock { format }
    }

    public var includesAudio: Bool {
        lock.withLock { settings.includesAudio }
    }

    public func endEncoding() async {
        let current = lock.withLock { () -> (SCContentFilter, SCStream)? in
            isEncoding = false
            hasNetworkDemand = false
            encoder?.completeFrames()
            encoder = nil
            guard let filter, let stream else { return nil }
            return (filter, stream)
        }
        if let (filter, stream) = current {
            let (configuration, format) = makeConfiguration(filter: filter)
            try? await stream.updateConfiguration(configuration)
            lock.withLock {
                self.configuration = configuration
                self.format = format
            }
        }
        if !lock.withLock({ isStopped }) {
            eventContinuation.yield(.stateChanged(.previewing))
        }
        logEncodedFrameDrops()
    }

    public func setPreviewEnabled(_ enabled: Bool) {
        lock.withLock { isPreviewEnabled = enabled }
    }

    /// Stops VideoToolbox when Discord reports zero viewers, while keeping the
    /// lightweight preview capture alive for immediate recovery.
    public func setNetworkDemand(_ demanded: Bool) throws {
        let action = lock.withLock { () -> ScreenShareDemandTransition in
            guard isEncoding, hasNetworkDemand != demanded else {
                return ScreenShareDemandTransition(shouldStartEncoder: false)
            }
            hasNetworkDemand = demanded
            if !demanded {
                encoder?.completeFrames()
                encoder = nil
                return ScreenShareDemandTransition(
                    shouldStartEncoder: false,
                    audioEncoderToReset: audioEncoder
                )
            }
            return ScreenShareDemandTransition(
                shouldStartEncoder: true,
                format: format
            )
        }
        action.audioEncoderToReset?.reset()
        if action.shouldStartEncoder, let format = action.format {
            try replaceEncoder(format: format)
        }
    }

    public func stop() async {
        let stream = lock.withLock { () -> SCStream? in
            guard !isStopped else { return nil }
            isStopped = true
            isEncoding = false
            encoder?.completeFrames()
            encoder = nil
            audioEncoder?.handler = nil
            audioEncoder = nil
            let current = self.stream
            self.stream = nil
            filter = nil
            configuration = nil
            format = nil
            return current
        }
        if let stream {
            try? await stream.stopCapture()
        }
        await MainActor.run {
            let picker = SCContentSharingPicker.shared
            picker.remove(self)
            picker.isActive = false
        }
        lock.withLock { isPickerObserverInstalled = false }
        logEncodedFrameDrops()
        previewContinuation.finish()
        encodedContinuation.finish()
        encodedAudioContinuation.finish()
        eventContinuation.finish()
    }

    private func startOrReplaceStream(filter: SCContentFilter) async throws {
        guard !lock.withLock({ isStopped }) else { throw CancellationError() }
        let (configuration, format) = makeConfiguration(filter: filter)
        if let stream = lock.withLock({ self.stream }) {
            try await stream.updateContentFilter(filter)
            try await stream.updateConfiguration(configuration)
            lock.withLock {
                self.filter = filter
                self.configuration = configuration
                self.format = format
            }
            if lock.withLock({ isEncoding && hasNetworkDemand }) {
                try replaceEncoder(format: format)
            }
            return
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
        } catch {
            throw ScreenShareCaptureError.outputUnavailable
        }
        lock.withLock {
            self.stream = stream
            self.filter = filter
            self.configuration = configuration
            self.format = format
        }
        do {
            try await stream.startCapture()
        } catch {
            lock.withLock {
                self.stream = nil
                self.filter = nil
                self.configuration = nil
                self.format = nil
            }
            throw error
        }
    }

    private func makeConfiguration(
        filter: SCContentFilter
    ) -> (SCStreamConfiguration, ScreenShareVideoFormat) {
        let (settings, isEncoding) = lock.withLock { (settings, isEncoding) }
        let sourceWidth = max(2, Int(filter.contentRect.width * CGFloat(filter.pointPixelScale)))
        let sourceHeight = max(2, Int(filter.contentRect.height * CGFloat(filter.pointPixelScale)))
        let outputSize = Self.outputSize(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            quality: settings.quality
        )
        let configuration = SCStreamConfiguration()
        configuration.width = outputSize.width
        configuration.height = outputSize.height
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(settings.frameRate.rawValue)
        )
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        configuration.capturesAudio = settings.includesAudio && isEncoding
        configuration.sampleRate = Int(OpusCodec.sampleRate)
        configuration.channelCount = Int(OpusCodec.channels)
        configuration.excludesCurrentProcessAudio = true
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        let format = ScreenShareVideoFormat(
            width: outputSize.width,
            height: outputSize.height,
            frameRate: settings.frameRate.rawValue,
            bitrate: Self.bitrate(
                width: outputSize.width,
                height: outputSize.height,
                frameRate: settings.frameRate.rawValue
            )
        )
        return (configuration, format)
    }

    private func replaceEncoder(format: ScreenShareVideoFormat) throws {
        do {
            let encoder = try H264VideoEncoder(
                width: format.width,
                height: format.height,
                framerate: format.frameRate,
                bitrate: format.bitrate
            ) { [weak self] frame in
                self?.yieldEncodedFrame(frame)
            }
            lock.withLock {
                self.encoder?.completeFrames()
                self.encoder = encoder
            }
        } catch {
            throw ScreenShareCaptureError.encoderUnavailable(error.localizedDescription)
        }
    }

    private func yieldEncodedFrame(_ frame: EncodedVideoFrame) {
        if case .dropped = encodedContinuation.yield(frame) {
            lock.withLock { encodedFrameDropCount += 1 }
        }
    }

    private func logEncodedFrameDrops() {
        let dropped = lock.withLock { () -> Int in
            defer { encodedFrameDropCount = 0 }
            return encodedFrameDropCount
        }
        screenCaptureLogger.info(
            "Screen-share encoder queue stopped; droppedFrames=\(dropped)"
        )
    }

    private func prepareAudioEncoderIfNeeded() throws {
        if lock.withLock({ audioEncoder != nil }) {
            return
        }
        do {
            let audioEncoder = try OpusSampleBufferEncoder(activityThreshold: 0.000_1)
            audioEncoder.handler = { [encodedAudioContinuation] frame in
                encodedAudioContinuation.yield(frame)
            }
            lock.withLock { self.audioEncoder = audioEncoder }
        } catch {
            throw ScreenShareCaptureError.encoderUnavailable(error.localizedDescription)
        }
    }

    private func configurePicker(_ picker: SCContentSharingPicker) async {
        await MainActor.run {
            var configuration = SCContentSharingPickerConfiguration()
            configuration.allowedPickerModes = [
                .singleDisplay,
                .singleWindow,
                .singleApplication,
                .multipleWindows,
                .multipleApplications,
            ]
            configuration.allowsChangingSelectedContent = true
            configuration.excludedBundleIDs = []
            configuration.excludedWindowIDs = []
            picker.defaultConfiguration = configuration
            let shouldInstallObserver = self.lock.withLock { () -> Bool in
                guard !self.isPickerObserverInstalled else { return false }
                self.isPickerObserverInstalled = true
                return true
            }
            if shouldInstallObserver {
                picker.add(self)
            }
            picker.isActive = true
        }
    }

    private static func outputSize(
        sourceWidth: Int,
        sourceHeight: Int,
        quality: ScreenShareQuality
    ) -> (width: Int, height: Int) {
        guard let targetHeight = quality.targetHeight else {
            return (even(sourceWidth), even(sourceHeight))
        }
        let scale = min(1, Double(targetHeight) / Double(sourceHeight))
        return (
            even(max(2, Int((Double(sourceWidth) * scale).rounded()))),
            even(max(2, Int((Double(sourceHeight) * scale).rounded())))
        )
    }

    private static func even(_ value: Int) -> Int { max(2, value - value % 2) }

    private static func bitrate(width: Int, height: Int, frameRate: Int) -> Int {
        let pixelsPerSecond = Double(width * height * frameRate)
        // Authenticated desktop captures advertise 9 Mbps for a 2560x1440
        // 60 FPS source. Going above the SFU's announced ceiling only creates
        // motion-time queue growth and loss; it does not improve delivered
        // quality.
        return min(9_000_000, max(2_500_000, Int(pixelsPerSecond * 0.12)))
    }
}

extension ScreenShareCaptureEngine: SCStreamOutput {
    public func stream(
        _: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }
        if outputType == .audio {
            let audioEncoder = lock.withLock {
                isEncoding && hasNetworkDemand && settings.includesAudio
                    ? self.audioEncoder : nil
            }
            audioEncoder?.process(sampleBuffer)
            return
        }
        guard outputType == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(
                  sampleBuffer,
                  createIfNecessary: false
              ) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let encoder = lock.withLock {
            isEncoding && hasNetworkDemand ? self.encoder : nil
        }
        encoder?.encode(
            pixelBuffer: pixelBuffer,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )

        guard lock.withLock({ isPreviewEnabled }) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPreviewTime >= 1.0 / 15.0 else { return }
        lastPreviewTime = now
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = imageContext.createCGImage(image, from: image.extent) else { return }
        previewContinuation.yield(VoiceVideoFrame(image: cgImage))
    }
}

extension ScreenShareCaptureEngine: SCStreamDelegate {
    public func stream(_: SCStream, didStopWithError error: any Error) {
        guard !lock.withLock({ isStopped }) else { return }
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain,
           nsError.code == SCStreamError.Code.userStopped.rawValue
        {
            eventContinuation.yield(.stateChanged(.stopped))
            return
        }
        let rawMessage = error.localizedDescription
        let message = Self.userFacingMessage(for: error)
        screenCaptureLogger.error("Screen capture stopped: \(rawMessage, privacy: .public)")
        eventContinuation.yield(.stateChanged(.failed(message)))
        eventContinuation.yield(.error(message))
    }

    public func streamDidBecomeActive(_: SCStream) {
        guard !lock.withLock({ isStopped }) else { return }
        eventContinuation.yield(
            .stateChanged(lock.withLock { isEncoding } ? .sharing : .previewing)
        )
    }

    public func streamDidBecomeInactive(_: SCStream) {
        guard !lock.withLock({ isStopped }) else { return }
        eventContinuation.yield(.stateChanged(.interrupted))
    }
}

extension ScreenShareCaptureEngine: SCContentSharingPickerObserver {
    public func contentSharingPicker(
        _: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        eventContinuation.yield(.pickerCancelled)
    }

    public func contentSharingPicker(
        _: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.startOrReplaceStream(filter: filter)
                self.eventContinuation.yield(.sourceChanged(Self.sourceName(filter)))
                self.eventContinuation.yield(
                    .stateChanged(
                        self.lock.withLock { self.isEncoding } ? .sharing : .previewing
                    )
                )
            } catch is CancellationError {
                return
            } catch {
                let rawMessage = error.localizedDescription
                screenCaptureLogger.error(
                    "Could not update screen capture: \(rawMessage, privacy: .public)"
                )
                self.eventContinuation.yield(.error(Self.userFacingMessage(for: error)))
            }
        }
    }

    public func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        let rawMessage = error.localizedDescription
        screenCaptureLogger.error(
            "Screen-sharing picker failed: \(rawMessage, privacy: .public)"
        )
        eventContinuation.yield(.error(Self.userFacingMessage(for: error)))
    }

    private static func sourceName(_ filter: SCContentFilter) -> String {
        switch filter.style {
        case .display: "Entire Screen"
        case .window: "Window"
        case .application: "Application"
        default: "Selected Source"
        }
    }

    private static func userFacingMessage(for error: any Error) -> String {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain,
           nsError.code == SCStreamError.Code.userDeclined.rawValue
        {
            return "Allow Screen Recording in System Settings, then try again."
        }
        return "Couldn’t start the preview. Try again."
    }
}
