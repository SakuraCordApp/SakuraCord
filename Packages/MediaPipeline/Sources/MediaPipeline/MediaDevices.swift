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

    public init(uniqueID: String, name: String) {
        self.uniqueID = uniqueID
        self.name = name
    }
}

public struct MediaDeviceSnapshot: Equatable, Sendable {
    public var audioInputs: [AudioDeviceInfo]
    public var audioOutputs: [AudioDeviceInfo]
    public var cameras: [CameraDeviceInfo]

    public static let empty = MediaDeviceSnapshot(
        audioInputs: [],
        audioOutputs: [],
        cameras: []
    )
}

public enum MediaDeviceCatalog {
    public static func snapshot() -> MediaDeviceSnapshot {
        let devices = allAudioDeviceIDs()
        let defaultInput = defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
        let defaultOutput = defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
        let inputs = devices.compactMap { device -> AudioDeviceInfo? in
            guard channelCount(device: device, scope: kAudioDevicePropertyScopeInput) > 0 else { return nil }
            return info(for: device, defaultDevice: defaultInput)
        }
        let outputs = devices.compactMap { device -> AudioDeviceInfo? in
            guard channelCount(device: device, scope: kAudioDevicePropertyScopeOutput) > 0 else { return nil }
            return info(for: device, defaultDevice: defaultOutput)
        }
        let cameraTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .external,
            .continuityCamera
        ]
        let cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: cameraTypes,
            mediaType: .video,
            position: .unspecified
        ).devices.map { CameraDeviceInfo(uniqueID: $0.uniqueID, name: $0.localizedName) }
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
        guard let uid = stringProperty(device: deviceID, selector: kAudioDevicePropertyDeviceUID) else {
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

    private static func allAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        var values = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &values) == noErr else {
            return []
        }
        return values
    }

    private static func defaultDevice(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func channelCount(device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func info(for device: AudioDeviceID, defaultDevice: AudioDeviceID?) -> AudioDeviceInfo? {
        guard let name = stringProperty(device: device, selector: kAudioObjectPropertyName),
              let uid = stringProperty(device: device, selector: kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioDeviceInfo(
            id: device,
            uid: uid,
            name: name,
            isDefault: device == defaultDevice,
            transportType: integerProperty(device: device, selector: kAudioDevicePropertyTransportType) ?? 0
        )
    }

    private static func stringProperty(device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeUnretainedValue() as String?
    }

    private static func integerProperty(
        device: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
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

public enum MediaDeviceError: Error, Equatable {
    case audioUnitUnavailable
    case coreAudio(OSStatus)
}
