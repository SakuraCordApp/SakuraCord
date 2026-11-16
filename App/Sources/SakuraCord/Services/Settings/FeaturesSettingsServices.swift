import Foundation

nonisolated struct FeaturesSettingsSnapshot: Equatable, Sendable {
    static let defaults = Self(reading: SettingsPreferenceRegistry.foundation.defaultValue(for:))

    var readAllButton: Bool
    var showHiddenChannels: Bool
    var channelManagement: Bool
    var fakeNitroEmojis: Bool
    var fakeNitroStickers: Bool
    var fakeNitroSoundboard: Bool
    var fakeNitroStreamQuality: Bool
    var unlimitedFavorites: Bool
    var voiceMessageRecording: Bool
    var messageHoverActions: Bool
    var scrollToBottomButton: Bool
}

nonisolated extension FeaturesSettingsSnapshot {
    init(reading value: (SettingsControlID) -> SettingsPreferenceValue) {
        readAllButton = value(.readAllButton).boolValue
        channelManagement = value(.channelManagement).boolValue
        showHiddenChannels = value(.showHiddenChannels).boolValue
        fakeNitroEmojis = value(.fakeNitroEmojis).boolValue
        fakeNitroStickers = value(.fakeNitroStickers).boolValue
        fakeNitroSoundboard = value(.fakeNitroSoundboard).boolValue
        fakeNitroStreamQuality = value(.fakeNitroStreamQuality).boolValue
        unlimitedFavorites = value(.unlimitedFavorites).boolValue
        voiceMessageRecording = value(.voiceMessageRecording).boolValue
        messageHoverActions = value(.messageHoverActions).boolValue
        scrollToBottomButton = value(.scrollToBottomButton).boolValue
    }
}

@MainActor
final class FeaturesSettingsStore {
    static let shared = FeaturesSettingsStore()
    private let preferences: SettingsPreferenceStore

    init(preferences: SettingsPreferenceStore = .shared) {
        self.preferences = preferences
    }

    func load() -> FeaturesSettingsSnapshot {
        FeaturesSettingsSnapshot { preferences.value(for: $0) }
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
