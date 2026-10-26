import MediaPipeline

extension AppModel {
    var allowsEnhancedStreamQuality: Bool {
        let premiumType = currentUser?.premiumType ?? 0
        return featuresSettings.fakeNitroStreamQuality || premiumType == 1 || premiumType == 2
    }

    var availableScreenShareQualities: [ScreenShareQuality] {
        allowsEnhancedStreamQuality ? ScreenShareQuality.allCases : [.p720]
    }

    var availableScreenShareFrameRates: [ScreenShareFrameRate] {
        allowsEnhancedStreamQuality ? ScreenShareFrameRate.allCases : [.fps15, .fps30]
    }

    func allowedScreenShareSettings(_ settings: ScreenShareSettings) -> ScreenShareSettings {
        guard !allowsEnhancedStreamQuality else { return settings }
        var settings = settings
        settings.quality = .p720
        if settings.frameRate == .fps60 { settings.frameRate = .fps30 }
        return settings
    }
}
