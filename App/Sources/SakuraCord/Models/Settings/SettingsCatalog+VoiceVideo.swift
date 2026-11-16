import Foundation

nonisolated extension SettingsCatalog {
    static let voiceVideoPage = page(
        .voiceVideo, group: .preferences, title: "Voice & Video", image: "mic.fill",
        help: "Choose call devices, levels, tests, and share defaults.",
        keywords: ["microphone", "speaker", "camera", "audio", "video", "screen share"]
    )

    static let voiceVideoControls: [SettingsControlMetadata] = [
        control(
            .voiceInputDevice,
            page: .voiceVideo,
            section: .voiceDevices,
            label: "Microphone",
            help: "Choose the microphone used by SakuraCord calls.",
            keywords: ["microphone", "system default"]
        ),
        control(
            .voiceOutputDevice,
            page: .voiceVideo,
            section: .voiceDevices,
            label: "Speaker",
            help: "Choose the speaker or headphones used by SakuraCord calls.",
            keywords: ["speaker", "headphones", "system default"]
        ),
        control(
            .voiceCamera,
            page: .voiceVideo,
            section: .voiceCamera,
            label: "Camera",
            help: "Choose the camera used by SakuraCord calls.",
            keywords: ["webcam", "video"]
        ),
        control(
            .voiceInputVolume,
            page: .voiceVideo,
            section: .voiceLevels,
            label: "Microphone volume",
            help: "Adjust the microphone level applied by SakuraCord.",
            keywords: ["microphone", "gain"]
        ),
        control(
            .voiceOutputVolume,
            page: .voiceVideo,
            section: .voiceLevels,
            label: "Speaker volume",
            help: "Adjust call playback volume in SakuraCord.",
            keywords: ["speaker", "playback"]
        ),
        control(
            .voiceRefreshDevices, page: .voiceVideo, section: .voiceDevices,
            label: "Refresh devices",
            help: "Rescan microphones, speakers, and cameras and recover unavailable saved routes.",
            keywords: ["rescan", "missing device", "fallback"]
        ),
        control(
            .voiceMicrophoneTest, page: .voiceVideo, section: .voiceLevels,
            label: "Test Microphone",
            help: "Hear the selected microphone through your speaker with a short delay and view its live level.",
            keywords: ["mic check", "meter", "input test", "speaker test", "playback"]
        ),
        control(
            .voiceJoinMuted, page: .voiceVideo, section: .voiceCallDefaults,
            label: "Join calls muted",
            help: "Start the next call with microphone transmission muted without changing the current call.",
            keywords: ["mute on join", "microphone default"]
        ),
        control(
            .voiceJoinDeafened, page: .voiceVideo, section: .voiceCallDefaults,
            label: "Join calls deafened",
            help: "Start the next call with call playback deafened without changing the current call.",
            keywords: ["deafen on join", "speaker default"]
        ),
        control(
            .voiceFeedbackSounds, page: .voiceVideo, section: .voiceCallDefaults,
            label: "Play call feedback sounds",
            help: "Play local sounds for joins, leaves, mute, deafen, video, and sharing events.",
            keywords: ["join sound", "leave sound", "mute sound"]
        ),
        control(
            .voiceCameraPreview, page: .voiceVideo, section: .voiceCamera,
            label: "Camera preview",
            help: "Preview the selected camera locally until the preview is explicitly stopped.",
            keywords: ["webcam test", "video preview"]
        ),
        control(
            .voiceMirrorPreview, page: .voiceVideo, section: .voiceCamera,
            label: "Mirror my local preview",
            help: "Mirror only the local self-view; transmitted video remains unchanged.",
            keywords: ["flip camera", "self view"]
        ),
        control(
            .voiceRememberCamera, page: .voiceVideo, section: .voiceCamera,
            label: "Remember selected camera",
            help: "Restore the selected camera on the next launch; disabling this removes the saved camera identifier.",
            keywords: ["save camera", "forget webcam"]
        ),
        control(
            .voiceJoinCameraOff, page: .voiceVideo, section: .voiceCamera,
            label: "Join calls with camera off",
            help: "Keep video off when entering the next call without changing the current camera state.",
            keywords: ["video off", "camera on join"]
        ),
        control(
            .voiceScreenShareQuality, page: .voiceVideo, section: .voiceScreenShare,
            label: "Default quality",
            help: "Choose the initial resolution target for the next screen share.",
            keywords: ["720p", "1080p", "1440p", "source"]
        ),
        control(
            .voiceScreenShareFrameRate, page: .voiceVideo, section: .voiceScreenShare,
            label: "Default frame rate",
            help: "Choose the initial frame rate for the next screen share.",
            keywords: ["FPS", "15", "30", "60"]
        ),
        control(
            .voiceScreenShareAudio, page: .voiceVideo, section: .voiceScreenShare,
            label: "Include system audio",
            help: "Include system audio by default when preparing the next share.",
            keywords: ["share sound", "capture audio"]
        ),
        control(
            .voiceScreenSharePointer, page: .voiceVideo, section: .voiceScreenShare,
            label: "Show pointer",
            help: "Include the pointer by default in the next screen-share capture.",
            keywords: ["cursor", "mouse"]
        ),
        control(
            .voiceMicrophonePermission, page: .voiceVideo, section: .voicePermissions,
            label: "Microphone permission",
            help: "Report the microphone authorization currently managed by macOS.",
            keywords: ["privacy", "permission", "denied"]
        ),
        control(
            .voiceCameraPermission, page: .voiceVideo, section: .voicePermissions,
            label: "Camera permission",
            help: "Report the camera authorization currently managed by macOS.",
            keywords: ["privacy", "webcam permission", "denied"]
        ),

        control(
            .voiceReset, page: .voiceVideo, section: .voiceLocalData,
            label: "Reset Voice & Video Settings",
            help: "Restore local call and share defaults without changing macOS permissions or live call controls.",
            keywords: ["defaults", "restore", "clear preferences"]
        ),
    ]
}
