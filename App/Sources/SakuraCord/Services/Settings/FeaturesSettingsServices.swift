import Foundation

nonisolated struct FeaturesSettingsSnapshot: Equatable, Sendable {
    static let defaults = Self()

    var readAllButton = false
    var showHiddenChannels = true
    var channelManagement = true
    var fakeNitroEmojis = true
    var fakeNitroStickers = true
    var fakeNitroSoundboard = true
    var fakeNitroStreamQuality = true
    var voiceMessageRecording = true
}

@MainActor
final class FeaturesSettingsStore {
    static let shared = FeaturesSettingsStore()
    private let preferences: SettingsPreferenceStore

    init(preferences: SettingsPreferenceStore = .shared) {
        self.preferences = preferences
    }

    func load() -> FeaturesSettingsSnapshot {
        var value = FeaturesSettingsSnapshot.defaults
        if case let .bool(saved) = preferences.value(for: .readAllButton) { value.readAllButton = saved }
        if case let .bool(saved) = preferences.value(for: .channelManagement) { value.channelManagement = saved }
        if case let .bool(saved) = preferences.value(for: .showHiddenChannels) { value.showHiddenChannels = saved }
        if case let .bool(saved) = preferences.value(for: .fakeNitroEmojis) { value.fakeNitroEmojis = saved }
        if case let .bool(saved) = preferences.value(for: .fakeNitroStickers) { value.fakeNitroStickers = saved }
        if case let .bool(saved) = preferences.value(for: .fakeNitroSoundboard) { value.fakeNitroSoundboard = saved }
        if case let .bool(saved) = preferences.value(for: .fakeNitroStreamQuality) { value.fakeNitroStreamQuality = saved }
        if case let .bool(saved) = preferences.value(for: .voiceMessageRecording) { value.voiceMessageRecording = saved }
        return value
    }

    func save(_ value: FeaturesSettingsSnapshot) {
        preferences.set(.bool(value.readAllButton), for: .readAllButton)
        preferences.set(.bool(value.channelManagement), for: .channelManagement)
        preferences.set(.bool(value.showHiddenChannels), for: .showHiddenChannels)
        preferences.set(.bool(value.fakeNitroEmojis), for: .fakeNitroEmojis)
        preferences.set(.bool(value.fakeNitroStickers), for: .fakeNitroStickers)
        preferences.set(.bool(value.fakeNitroSoundboard), for: .fakeNitroSoundboard)
        preferences.set(.bool(value.fakeNitroStreamQuality), for: .fakeNitroStreamQuality)
        preferences.set(.bool(value.voiceMessageRecording), for: .voiceMessageRecording)
    }
}

extension AppModel {
    func applyFeaturesSettings(_ value: FeaturesSettingsSnapshot) {
        if featuresSettings.channelManagement, !value.channelManagement {
            closeCustomizationPreview()
            onboarding.browsingChannels = false
            onboarding.channelSearch = ""
            onboarding.isChannelSearchFocused = false
        }
        if featuresSettings.voiceMessageRecording, !value.voiceMessageRecording {
            channelVoiceMessageComposer.discard(playback: voiceMessagePlayback)
            threadVoiceMessageComposer.discard(playback: voiceMessagePlayback)
        }
        featuresSettings = value
        FeaturesSettingsStore.shared.save(value)
        refreshVisibleChannelGroups()
        reconcileSelectedOnboardingChannel()
        if allowedScreenShareSettings(screenShareSettings) != screenShareSettings {
            Task { [weak self] in
                guard let self else { return }
                await updateScreenShareSettings(screenShareSettings)
            }
        }
    }

    func refreshVisibleChannelGroups() {
        visibleChannelGroups = AppPerformanceSignposts.measureSync("ChannelSidebarGrouping") {
            ChannelGroup.make(from: featuresSettings.showHiddenChannels
                ? visibleChannels
                : visibleChannels.filter { !hiddenChannelIDs.contains($0.id) })
        }
    }
}
