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
    var unlimitedFavorites = false
    var voiceMessageRecording = true
    var messageHoverActions = true
    var scrollToBottomButton = true
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
        if let saved = preferences.bool(.readAllButton) { value.readAllButton = saved }
        if let saved = preferences.bool(.channelManagement) { value.channelManagement = saved }
        if let saved = preferences.bool(.showHiddenChannels) { value.showHiddenChannels = saved }
        if let saved = preferences.bool(.fakeNitroEmojis) { value.fakeNitroEmojis = saved }
        if let saved = preferences.bool(.fakeNitroStickers) { value.fakeNitroStickers = saved }
        if let saved = preferences.bool(.fakeNitroSoundboard) { value.fakeNitroSoundboard = saved }
        if let saved = preferences.bool(.fakeNitroStreamQuality) { value.fakeNitroStreamQuality = saved }
        if let saved = preferences.bool(.unlimitedFavorites) { value.unlimitedFavorites = saved }
        if let saved = preferences.bool(.voiceMessageRecording) { value.voiceMessageRecording = saved }
        if let saved = preferences.bool(.messageHoverActions) { value.messageHoverActions = saved }
        if let saved = preferences.bool(.scrollToBottomButton) { value.scrollToBottomButton = saved }
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
        preferences.set(.bool(value.unlimitedFavorites), for: .unlimitedFavorites)
        preferences.set(.bool(value.voiceMessageRecording), for: .voiceMessageRecording)
        preferences.set(.bool(value.messageHoverActions), for: .messageHoverActions)
        preferences.set(.bool(value.scrollToBottomButton), for: .scrollToBottomButton)
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
        let showsLocalFavorites = value.unlimitedFavorites && !featuresSettings.unlimitedFavorites
        // Hiding local favourites removes the open one like any removal.
        changeFavorites { featuresSettings = value }
        FeaturesSettingsStore.shared.save(value)
        if showsLocalFavorites {
            dropSyncedLocalFavorites()
            if favorites.isPresented { loadFavoriteThreads() }
        }
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
