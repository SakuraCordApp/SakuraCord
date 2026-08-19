import CoreAudio
import MediaPipeline
@testable import SakuraCord
import Testing

@Test func `system default route follows a changed default device`() {
    let previous = audioDevice(id: 1, uid: "speaker-a", isDefault: true)
    let current = audioDevice(id: 2, uid: "speaker-b", isDefault: true)

    let resolution = AppModel.audioDeviceRouteResolution(
        selectedUID: nil,
        previousDevices: [previous],
        currentDevices: [current]
    )

    #expect(resolution.requestedDeviceID == nil)
    #expect(resolution.requiresSwitch)
    #expect(!resolution.clearsStoredUID)
}

@Test func `removed saved route recovers to the system default`() {
    let previous = audioDevice(id: 1, uid: "airpods", isDefault: false)
    let current = audioDevice(id: 2, uid: "speakers", isDefault: true)

    let resolution = AppModel.audioDeviceRouteResolution(
        selectedUID: "airpods",
        previousDevices: [previous],
        currentDevices: [current]
    )

    #expect(resolution.requestedDeviceID == nil)
    #expect(resolution.requiresSwitch)
    #expect(resolution.clearsStoredUID)
}

@Test func `reconnected saved route adopts its new Core Audio identifier`() {
    let previous = audioDevice(id: 1, uid: "airpods", isDefault: false)
    let current = audioDevice(id: 7, uid: "airpods", isDefault: false)

    let resolution = AppModel.audioDeviceRouteResolution(
        selectedUID: "airpods",
        previousDevices: [previous],
        currentDevices: [current]
    )

    #expect(resolution.requestedDeviceID == 7)
    #expect(resolution.requiresSwitch)
    #expect(!resolution.clearsStoredUID)
}

private func audioDevice(
    id: AudioDeviceID,
    uid: String,
    isDefault: Bool
) -> AudioDeviceInfo {
    AudioDeviceInfo(
        id: id,
        uid: uid,
        name: uid,
        isDefault: isDefault
    )
}
