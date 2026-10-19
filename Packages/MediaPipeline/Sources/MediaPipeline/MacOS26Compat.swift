// Stand-ins for macOS 27 SDK APIs so MediaPipeline builds with Xcode 26.
// Delete this file if you move to Xcode 27.
import AudioToolbox
import AVFoundation
import CoreMedia
@preconcurrency import ScreenCaptureKit

enum MacOS26CompatError: Error {
    case engineNotRunning
}

extension AVAudioIONode {
    func withAudioUnit<E: Error>(_ body: (AudioUnit?) throws(E) -> Void) throws(E) {
        try body(audioUnit)
    }
}

extension AVAudioPlayerNode {
    // play() crashes if the engine is stopped; throw instead so callers can recover.
    func playAudio() throws {
        guard let engine, engine.isRunning else { throw MacOS26CompatError.engineNotRunning }
        play()
    }
}

extension AVAudioEngine {
    func connectNode(_ node1: AVAudioNode, to node2: AVAudioNode, format: AVAudioFormat?) throws {
        connect(node1, to: node2, format: format)
    }
}

extension AVAudioFormat {
    convenience init?(formatDescription: CMAudioFormatDescription) {
        self.init(cmAudioFormatDescription: formatDescription)
    }
}

extension SCContentSharingPicker {
    // The macOS 26 picker has no availability flag; it's always present.
    var isAvailable: Bool { true }
}
