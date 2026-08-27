import CoreAudio
import Foundation
import MediaPipeline

nonisolated struct AudioDeviceRouteResolution: Equatable, Sendable {
    var requestedDeviceID: AudioDeviceID?
    var requiresSwitch: Bool
    var clearsStoredUID: Bool
}

extension AppModel {
    var inputVolume: Float {
        get { Float(voiceVideoPreferences.inputVolume) }
        set { voiceVideoPreferences.inputVolume = Double(newValue) }
    }

    var outputVolume: Float {
        get { Float(voiceVideoPreferences.outputVolume) }
        set { voiceVideoPreferences.outputVolume = Double(newValue) }
    }

    func selectInputDevice(_ device: AudioDeviceInfo?) async -> Bool {
        let account = accountSession()
        let generation = voiceMigrationGeneration
        let session = voiceSession
        do {
            try await session?.selectInputDevice(device?.id)
            voiceVideoPreferences.inputDeviceUID = device?.uid ?? ""
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
            voiceDeviceStatusMessage = "The microphone could not be changed."
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
            voiceVideoPreferences.outputDeviceUID = device?.uid ?? ""
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
            voiceDeviceStatusMessage = "The speaker could not be changed."
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

    func updateCameraPersistence(_ remembersCamera: Bool) {
        voiceVideoPreferences.remembersCamera = remembersCamera
        if remembersCamera {
            voiceVideoPreferences.cameraUID = selectedCameraUID ?? ""
        } else {
            voiceVideoPreferences.forgetSavedCamera()
        }
    }

    func installMediaDeviceSnapshot(_ snapshot: MediaDeviceSnapshot) async {
        guard snapshot != mediaDevices else { return }
        let previousSnapshot = mediaDevices
        let inputUID = voiceVideoPreferences.inputDeviceUID
        let outputUID = voiceVideoPreferences.outputDeviceUID
        let unavailableCameraUID = selectedCameraUID.flatMap { uid in
            snapshot.cameras.contains(where: { $0.uniqueID == uid }) ? nil : uid
        }
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
            voiceVideoPreferences.inputDeviceUID = ""
            recoveryMessages.append("The saved microphone is unavailable; using the system default.")
        }
        if outputResolution.clearsStoredUID {
            voiceVideoPreferences.outputDeviceUID = ""
            recoveryMessages.append("The saved speaker is unavailable; using the system default.")
        }
        if unavailableCameraUID != nil {
            recoveryMessages.append("The saved camera is unavailable; using the system default.")
        }

        guard let session = voiceSession else {
            if unavailableCameraUID != nil {
                selectedCameraUID = nil
                if voiceVideoPreferences.remembersCamera {
                    voiceVideoPreferences.cameraUID = ""
                }
            }
            voiceDeviceStatusMessage = recoveryMessages.isEmpty
                ? nil : recoveryMessages.joined(separator: " ")
            return
        }
        do {
            if inputResolution.requiresSwitch {
                try await session.selectInputDevice(inputResolution.requestedDeviceID)
            }
            if outputResolution.requiresSwitch {
                try await session.selectOutputDevice(outputResolution.requestedDeviceID)
            }
            if unavailableCameraUID != nil {
                try await session.selectCamera(uniqueID: nil)
                selectedCameraUID = nil
                if voiceVideoPreferences.remembersCamera {
                    voiceVideoPreferences.cameraUID = ""
                }
            }
            voiceDeviceStatusMessage = recoveryMessages.isEmpty
                ? nil : recoveryMessages.joined(separator: " ")
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
                selectedUID: voiceVideoPreferences.inputDeviceUID,
                devices: mediaDevices.audioInputs
            ),
            outputDeviceID: selectedAudioDeviceID(
                selectedUID: voiceVideoPreferences.outputDeviceUID,
                devices: mediaDevices.audioOutputs
            ),
            inputVolume: inputVolume,
            outputVolume: outputVolume,
            isMuted: isVoiceMuted,
            isDeafened: isVoiceDeafened,
            cameraUniqueID: selectedCameraUID
        )
    }

    private func selectedAudioDeviceID(
        selectedUID: String,
        devices: [AudioDeviceInfo]
    ) -> AudioDeviceID? {
        guard !selectedUID.isEmpty else {
            return nil
        }
        return devices.first(where: { $0.uid == selectedUID })?.id
    }
}
