import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

public struct AudioDeviceInfo: Identifiable, Equatable, Sendable {
    public var id: AudioDeviceID
    public var uid: String
    public var name: String
    public var isDefault: Bool
    public var transportType: UInt32

    public init(
        id: AudioDeviceID,
        uid: String,
        name: String,
        isDefault: Bool,
        transportType: UInt32 = 0
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.isDefault = isDefault
        self.transportType = transportType
    }

    public var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    public var isBuiltIn: Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn
    }

    public var isVirtual: Bool {
        transportType == kAudioDeviceTransportTypeVirtual
            || transportType == kAudioDeviceTransportTypeAggregate
    }
}

public struct CameraDeviceInfo: Identifiable, Equatable, Sendable {
    public var id: String {
        uniqueID
    }

    public var uniqueID: String
    public var name: String
    public var isDefault: Bool

    public init(uniqueID: String, name: String, isDefault: Bool = false) {
        self.uniqueID = uniqueID
        self.name = name
        self.isDefault = isDefault
    }
}

public struct MediaDeviceSnapshot: Equatable, Sendable {
    public var audioInputs: [AudioDeviceInfo]
    public var audioOutputs: [AudioDeviceInfo]
    public var cameras: [CameraDeviceInfo]

    public init(
        audioInputs: [AudioDeviceInfo],
        audioOutputs: [AudioDeviceInfo],
        cameras: [CameraDeviceInfo]
    ) {
        self.audioInputs = audioInputs
        self.audioOutputs = audioOutputs
        self.cameras = cameras
    }

    public static let empty = MediaDeviceSnapshot(
        audioInputs: [],
        audioOutputs: [],
        cameras: []
    )
}

public enum MediaDeviceCatalog {
    public static func snapshot() -> MediaDeviceSnapshot {
        let system = AudioHardwareSystem.shared
        let devices = (try? system.devices) ?? []
        let defaultInput = try? system.defaultInputDevice?.id
        let defaultOutput = try? system.defaultOutputDevice?.id
        let inputs = devices.compactMap { device -> AudioDeviceInfo? in
            guard channelCount(try? device.inputStreamConfiguration) > 0 else { return nil }
            return info(for: device, defaultDevice: defaultInput)
        }
        let outputs = devices.compactMap { device -> AudioDeviceInfo? in
            guard channelCount(try? device.outputStreamConfiguration) > 0 else { return nil }
            return info(for: device, defaultDevice: defaultOutput)
        }
        let cameraTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .external,
            .continuityCamera
        ]
        let defaultCameraID = AVCaptureDevice.default(for: .video)?.uniqueID
        let cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: cameraTypes,
            mediaType: .video,
            position: .unspecified
        ).devices.map {
            CameraDeviceInfo(
                uniqueID: $0.uniqueID,
                name: $0.localizedName,
                isDefault: $0.uniqueID == defaultCameraID
            )
        }
        return MediaDeviceSnapshot(
            audioInputs: inputs.sorted(by: deviceOrder),
            audioOutputs: outputs.sorted(by: deviceOrder),
            cameras: cameras.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        )
    }

    public static func camera(uniqueID: String?) -> AVCaptureDevice? {
        guard let uniqueID, !uniqueID.isEmpty else { return AVCaptureDevice.default(for: .video) }
        return AVCaptureDevice(uniqueID: uniqueID)
    }

    static func audioCaptureDevice(deviceID: AudioDeviceID?) -> AVCaptureDevice? {
        guard let deviceID else { return AVCaptureDevice.default(for: .audio) }
        guard let uid = stringProperty(
            deviceID: deviceID,
            selector: kAudioDevicePropertyDeviceUID
        ) else {
            return nil
        }
        return AVCaptureDevice(uniqueID: uid)
    }

    public static func selectInput(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) throws {
        try engine.inputNode.withAudioUnit { audioUnit throws(MediaDeviceError) in
            try select(deviceID, on: audioUnit)
        }
    }

    public static func selectOutput(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) throws {
        try engine.outputNode.withAudioUnit { audioUnit throws(MediaDeviceError) in
            try select(deviceID, on: audioUnit)
        }
    }

    public static func defaultOutputDeviceID() -> AudioDeviceID? {
        try? AudioHardwareSystem.shared.defaultOutputDevice?.id
    }

    public static func defaultInputDeviceID() -> AudioDeviceID? {
        try? AudioHardwareSystem.shared.defaultInputDevice?.id
    }

    private static func select(_ deviceID: AudioDeviceID, on audioUnit: AudioUnit?) throws(MediaDeviceError) {
        guard let audioUnit else { throw MediaDeviceError.audioUnitUnavailable }
        var value = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &value,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw MediaDeviceError.coreAudio(status) }
    }

    private static func channelCount(_ buffers: [AudioBuffer]?) -> Int {
        buffers?.reduce(0) { $0 + Int($1.mNumberChannels) } ?? 0
    }

    private static func info(
        for device: AudioHardwareDevice,
        defaultDevice: AudioDeviceID?
    ) -> AudioDeviceInfo? {
        guard (try? device.isHidden) != true,
              let name = try? device.name,
              let uid = stringProperty(
                  deviceID: device.id,
                  selector: kAudioDevicePropertyDeviceUID
              ) else { return nil }
        return AudioDeviceInfo(
            id: device.id,
            uid: uid,
            name: name,
            isDefault: device.id == defaultDevice,
            transportType: integerProperty(
                deviceID: device.id,
                selector: kAudioDevicePropertyTransportType
            ) ?? 0
        )
    }

    /// The Swift Core Audio hardware API does not expose device UIDs or transport
    /// types as typed properties. Keep these raw reads isolated to metadata that
    /// is required for stable persistence and useful route descriptions.
    private static func stringProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeUnretainedValue() as String?
    }

    private static func integerProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func deviceOrder(_ lhs: AudioDeviceInfo, _ rhs: AudioDeviceInfo) -> Bool {
        if lhs.isDefault != rhs.isDefault {
            return lhs.isDefault
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

/// Observes the Core Audio system object so device menus and active voice
/// sessions can react to hot-plug, Bluetooth route, and default-device changes.
public final class MediaDeviceMonitor: @unchecked Sendable {
    public typealias Handler = @Sendable (MediaDeviceSnapshot) -> Void

    private final class ListenerOwner: PropertyListenerDelegate, @unchecked Sendable {
        weak var monitor: MediaDeviceMonitor?

        func propertiesChanged(properties _: [AudioObjectPropertyAddress]) {
            monitor?.scheduleRefresh()
        }
    }

    private static let observedAddresses = [
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        ),
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        ),
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    ]

    private let queue = DispatchQueue(
        label: "app.sakuracord.media-device-monitor",
        qos: .userInitiated
    )
    private let handler: Handler
    private let system = AudioHardwareSystem(id: AudioObjectID(kAudioObjectSystemObject))
    private let listenerOwner = ListenerOwner()
    private var isRegistered = false
    private var pendingRefresh: DispatchWorkItem?

    public init(handler: @escaping Handler) {
        self.handler = handler
        listenerOwner.monitor = self
        system.delegates = [listenerOwner]
        do {
            try system.addListener(
                forProperties: Self.observedAddresses,
                dispatchQueue: queue
            )
            isRegistered = true
        } catch {
            system.delegates = []
        }
        queue.async { [weak self] in
            self?.deliverSnapshot()
        }
    }

    deinit {
        listenerOwner.monitor = nil
        if isRegistered {
            try? system.removeListener(
                forProperties: Self.observedAddresses,
                dispatchQueue: queue
            )
        }
        system.delegates = []
    }

    private func scheduleRefresh() {
        dispatchPrecondition(condition: .onQueue(queue))
        pendingRefresh?.cancel()
        let refresh = DispatchWorkItem { [weak self] in
            self?.deliverSnapshot()
        }
        pendingRefresh = refresh
        queue.asyncAfter(deadline: .now() + .milliseconds(150), execute: refresh)
    }

    private func deliverSnapshot() {
        dispatchPrecondition(condition: .onQueue(queue))
        pendingRefresh = nil
        handler(MediaDeviceCatalog.snapshot())
    }
}

public enum MediaDeviceError: Error, Equatable {
    case audioUnitUnavailable
    case coreAudio(OSStatus)
}

extension MediaDeviceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .audioUnitUnavailable:
            "The audio output is not ready for device switching."
        case let .coreAudio(status):
            "Core Audio could not use that device (error \(status))."
        }
    }
}
