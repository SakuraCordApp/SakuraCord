import CoreAudio
import Foundation
import MediaPipeline

nonisolated struct AudioDeviceRouteResolution: Equatable, Sendable {
    var requestedDeviceID: AudioDeviceID?
    var requiresSwitch: Bool
    var clearsStoredUID: Bool
}

extension AppModel {
    func selectInputDevice(_ device: AudioDeviceInfo?) async -> Bool {
        let account = accountSession()
        let generation = voiceMigrationGeneration
        let session = voiceSession
        do {
            try await session?.selectInputDevice(device?.id)
            UserDefaults.standard.set(device?.uid, forKey: "voiceInputDeviceUID")
            voiceDeviceStatusMessage = device.map {
                "Using “\($0.name)” as the microphone."
            } ?? "Using the system-default microphone."
            return true
        } catch {
            guard isCurrentVoiceOperation(
                account,
                generation: generation,
                voiceSession: session
            ) else { return false }
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
            return false
        }
    }

    func selectOutputDevice(_ device: AudioDeviceInfo?) async -> Bool {
        let account = accountSession()
        let generation = voiceMigrationGeneration
        let session = voiceSession
        do {
            try await session?.selectOutputDevice(device?.id)
            UserDefaults.standard.set(device?.uid, forKey: "voiceOutputDeviceUID")
            voiceDeviceStatusMessage = device.map {
                "Using “\($0.name)” as the speaker."
            } ?? "Using the system-default speaker."
            return true
        } catch {
            guard isCurrentVoiceOperation(
                account,
                generation: generation,
                voiceSession: session
            ) else { return false }
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
            return false
        }
    }

    func refreshMediaDevices() async {
        let snapshot = await Task.detached(priority: .userInitiated) {
            MediaDeviceCatalog.snapshot()
        }.value
        await installMediaDeviceSnapshot(snapshot)
    }

    func installMediaDeviceSnapshot(_ snapshot: MediaDeviceSnapshot) async {
        guard snapshot != mediaDevices else { return }
        let previousSnapshot = mediaDevices
        let defaults = UserDefaults.standard
        let inputUID = defaults.string(forKey: "voiceInputDeviceUID")
        let outputUID = defaults.string(forKey: "voiceOutputDeviceUID")
        let inputResolution = Self.audioDeviceRouteResolution(
            selectedUID: inputUID,
            previousDevices: previousSnapshot.audioInputs,
            currentDevices: snapshot.audioInputs
        )
        let outputResolution = Self.audioDeviceRouteResolution(
            selectedUID: outputUID,
            previousDevices: previousSnapshot.audioOutputs,
            currentDevices: snapshot.audioOutputs
        )
        mediaDevices = snapshot

        var recoveryMessages: [String] = []
        if inputResolution.clearsStoredUID {
            defaults.removeObject(forKey: "voiceInputDeviceUID")
            recoveryMessages.append("The saved microphone is unavailable; using the system default.")
        }
        if outputResolution.clearsStoredUID {
            defaults.removeObject(forKey: "voiceOutputDeviceUID")
            recoveryMessages.append("The saved speaker is unavailable; using the system default.")
        }

        guard let session = voiceSession else {
            voiceDeviceStatusMessage = recoveryMessages.last
            return
        }
        do {
            if inputResolution.requiresSwitch {
                try await session.selectInputDevice(inputResolution.requestedDeviceID)
            }
            if outputResolution.requiresSwitch {
                try await session.selectOutputDevice(outputResolution.requestedDeviceID)
            }
            voiceDeviceStatusMessage = recoveryMessages.last
        } catch {
            voiceDeviceStatusMessage = "An audio device changed, but its route could not be restored."
            voiceErrorMessage = error.localizedDescription
        }
    }

    nonisolated static func audioDeviceRouteResolution(
        selectedUID: String?,
        previousDevices: [AudioDeviceInfo],
        currentDevices: [AudioDeviceInfo]
    ) -> AudioDeviceRouteResolution {
        guard let selectedUID, !selectedUID.isEmpty else {
            let previousDefault = previousDevices.first(where: \.isDefault)
            let currentDefault = currentDevices.first(where: \.isDefault)
            return AudioDeviceRouteResolution(
                requestedDeviceID: nil,
                requiresSwitch: previousDefault?.id != currentDefault?.id
                    || previousDefault?.uid != currentDefault?.uid,
                clearsStoredUID: false
            )
        }
        guard let current = currentDevices.first(where: { $0.uid == selectedUID }) else {
            return AudioDeviceRouteResolution(
                requestedDeviceID: nil,
                requiresSwitch: true,
                clearsStoredUID: true
            )
        }
        let previous = previousDevices.first(where: { $0.uid == selectedUID })
        return AudioDeviceRouteResolution(
            requestedDeviceID: current.id,
            requiresSwitch: previous?.id != current.id,
            clearsStoredUID: false
        )
    }

    func currentVoiceConfiguration() -> VoiceSessionConfiguration {
        VoiceSessionConfiguration(
            inputDeviceID: selectedAudioDeviceID(
                defaultsKey: "voiceInputDeviceUID",
                devices: mediaDevices.audioInputs
            ),
            outputDeviceID: selectedAudioDeviceID(
                defaultsKey: "voiceOutputDeviceUID",
                devices: mediaDevices.audioOutputs
            ),
            inputVolume: inputVolume,
            outputVolume: outputVolume,
            isMuted: isVoiceMuted,
            isDeafened: isVoiceDeafened,
            cameraUniqueID: UserDefaults.standard.string(forKey: "voiceCameraUID")
        )
    }

    private func selectedAudioDeviceID(
        defaultsKey: String,
        devices: [AudioDeviceInfo]
    ) -> AudioDeviceID? {
        guard let uid = UserDefaults.standard.string(forKey: defaultsKey) else {
            return nil
        }
        return devices.first(where: { $0.uid == uid })?.id
    }
}
