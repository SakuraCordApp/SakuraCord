@testable import SakuraCord

@MainActor
final class RecordingAppSoundPlayer: AppSoundPlaying {
    private(set) var played: [AppSoundEffect] = []
    private(set) var looping: [AppSoundEffect: Bool] = [:]
    private(set) var stopAllCount = 0

    func play(_ effect: AppSoundEffect) {
        played.append(effect)
    }

    func setLooping(_ effect: AppSoundEffect, active: Bool) {
        looping[effect] = active
    }

    func stopAll() {
        stopAllCount += 1
        looping = [:]
    }
}
