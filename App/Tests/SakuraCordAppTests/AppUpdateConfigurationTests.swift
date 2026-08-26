import Foundation
import Testing
@testable import SakuraCord

private let validPublicKey = Data(repeating: 0xA5, count: 32).base64EncodedString()

@Test("production update metadata enables Sparkle only for the canonical bundle")
func productionUpdateMetadataEnablesCanonicalBundle() {
    let configuration = AppUpdateConfiguration(
        infoDictionary: productionUpdateInfo(),
        bundleIdentifier: AppUpdateConfiguration.canonicalBundleIdentifier
    )

    #expect(configuration.isEnabled)
    #expect(configuration.feedURL == AppUpdateConfiguration.expectedFeedURL)
    #expect(configuration.nightlyFeedURL == AppUpdateConfiguration.expectedNightlyFeedURL)
    #expect(configuration.publicEdKey == validPublicKey)
    #expect(configuration.unavailabilityReason == nil)
    #expect(AppUpdateConfiguration.scheduledCheckInterval == 21_600)
}

@Test("noncanonical developer bundles cannot enable production updates")
func noncanonicalBundlesCannotEnableUpdates() {
    let configuration = AppUpdateConfiguration(
        infoDictionary: productionUpdateInfo(),
        bundleIdentifier: "dev.example.SakuraCord"
    )

    #expect(!configuration.isEnabled)
    #expect(configuration.unavailabilityReason == .noncanonicalBundle)
}

@Test(
    "update configuration fails closed when release metadata is incomplete",
    arguments: [
        AppUpdateConfiguration.enabledInfoKey,
        AppUpdateConfiguration.nightlyFeedInfoKey,
        "SUFeedURL",
        "SUPublicEDKey",
        "SUEnableAutomaticChecks",
        "SUScheduledCheckInterval",
        "SUAutomaticallyUpdate",
        "SUAllowsAutomaticUpdates",
        "SUEnableInstallerLauncherService",
        "SUVerifyUpdateBeforeExtraction",
        "SURequireSignedFeed"
    ]
)
func incompleteUpdateMetadataIsDisabled(missingKey: String) {
    var info = productionUpdateInfo()
    info.removeValue(forKey: missingKey)

    let configuration = AppUpdateConfiguration(
        infoDictionary: info,
        bundleIdentifier: AppUpdateConfiguration.canonicalBundleIdentifier
    )
    let expectedReason: AppUpdateUnavailabilityReason
    switch missingKey {
    case AppUpdateConfiguration.enabledInfoKey: expectedReason = .disabledForBuild
    case AppUpdateConfiguration.nightlyFeedInfoKey: expectedReason = .invalidNightlyFeed
    case "SUFeedURL": expectedReason = .invalidStableFeed
    case "SUPublicEDKey": expectedReason = .invalidPublicKey
    case "SUEnableAutomaticChecks": expectedReason = .automaticChecksNotEnabled
    case "SUScheduledCheckInterval": expectedReason = .invalidCheckInterval
    case "SUAutomaticallyUpdate": expectedReason = .automaticInstallationNotDisabled
    case "SUAllowsAutomaticUpdates": expectedReason = .automaticUpdatesNotAllowed
    case "SUEnableInstallerLauncherService":
        expectedReason = .installerLauncherServiceNotEnabled
    case "SUVerifyUpdateBeforeExtraction": expectedReason = .updateVerificationNotEnabled
    case "SURequireSignedFeed": expectedReason = .signedFeedNotRequired
    default:
        Issue.record("Unexpected update metadata key: \(missingKey)")
        return
    }

    #expect(!configuration.isEnabled)
    #expect(configuration.unavailabilityReason == expectedReason)
}

@Test("update configuration rejects invalid trust or automatic-check metadata")
func invalidUpdateTrustMetadataIsDisabled() {
    var wrongFeed = productionUpdateInfo()
    wrongFeed["SUFeedURL"] = "https://example.invalid/appcast.xml"
    var malformedKey = productionUpdateInfo()
    malformedKey["SUPublicEDKey"] = "not-a-key"
    var wrongNightlyFeed = productionUpdateInfo()
    wrongNightlyFeed[AppUpdateConfiguration.nightlyFeedInfoKey] =
        "https://example.invalid/nightly.xml"
    var wrongInterval = productionUpdateInfo()
    wrongInterval["SUScheduledCheckInterval"] = 60 * 60
    var automaticChecksDisabled = productionUpdateInfo()
    automaticChecksDisabled["SUEnableAutomaticChecks"] = false
    var automaticInstallByDefault = productionUpdateInfo()
    automaticInstallByDefault["SUAutomaticallyUpdate"] = true
    var automaticInstallOptInDisabled = productionUpdateInfo()
    automaticInstallOptInDisabled["SUAllowsAutomaticUpdates"] = false
    var installerLauncherDisabled = productionUpdateInfo()
    installerLauncherDisabled["SUEnableInstallerLauncherService"] = false
    var verificationDisabled = productionUpdateInfo()
    verificationDisabled["SUVerifyUpdateBeforeExtraction"] = false
    var signedFeedNotRequired = productionUpdateInfo()
    signedFeedNotRequired["SURequireSignedFeed"] = false

    #expect(AppUpdateConfiguration(
        infoDictionary: wrongFeed,
        bundleIdentifier: AppUpdateConfiguration.canonicalBundleIdentifier
    ).unavailabilityReason == .invalidStableFeed)
    #expect(AppUpdateConfiguration(
        infoDictionary: malformedKey,
        bundleIdentifier: AppUpdateConfiguration.canonicalBundleIdentifier
    ).unavailabilityReason == .invalidPublicKey)
    #expect(AppUpdateConfiguration(
        infoDictionary: wrongNightlyFeed,
        bundleIdentifier: AppUpdateConfiguration.canonicalBundleIdentifier
    ).unavailabilityReason == .invalidNightlyFeed)
    #expect(AppUpdateConfiguration(
        infoDictionary: wrongInterval,
        bundleIdentifier: AppUpdateConfiguration.canonicalBundleIdentifier
    ).unavailabilityReason == .invalidCheckInterval)
    #expect(AppUpdateConfiguration(
        infoDictionary: automaticChecksDisabled,
        bundleIdentifier: AppUpdateConfiguration.canonicalBundleIdentifier
    ).unavailabilityReason == .automaticChecksNotEnabled)
    #expect(AppUpdateConfiguration(
        infoDictionary: automaticInstallByDefault,
        bundleIdentifier: AppUpdateConfiguration.canonicalBundleIdentifier
    ).unavailabilityReason == .automaticInstallationNotDisabled)
    #expect(AppUpdateConfiguration(
        infoDictionary: automaticInstallOptInDisabled,
        bundleIdentifier: AppUpdateConfiguration.canonicalBundleIdentifier
    ).unavailabilityReason == .automaticUpdatesNotAllowed)
    #expect(AppUpdateConfiguration(
        infoDictionary: installerLauncherDisabled,
        bundleIdentifier: AppUpdateConfiguration.canonicalBundleIdentifier
    ).unavailabilityReason == .installerLauncherServiceNotEnabled)
    #expect(AppUpdateConfiguration(
        infoDictionary: verificationDisabled,
        bundleIdentifier: AppUpdateConfiguration.canonicalBundleIdentifier
    ).unavailabilityReason == .updateVerificationNotEnabled)
    #expect(AppUpdateConfiguration(
        infoDictionary: signedFeedNotRequired,
        bundleIdentifier: AppUpdateConfiguration.canonicalBundleIdentifier
    ).unavailabilityReason == .signedFeedNotRequired)
}

@Test("release track preference defaults safely and selects its signed feed")
func releaseTrackPreferenceAndFeedSelection() {
    let configuration = AppUpdateConfiguration(
        infoDictionary: productionUpdateInfo(),
        bundleIdentifier: AppUpdateConfiguration.canonicalBundleIdentifier
    )

    #expect(AppUpdateReleaseTrack(storedValue: nil) == .regular)
    #expect(AppUpdateReleaseTrack(storedValue: "unknown") == .regular)
    #expect(AppUpdateReleaseTrack(storedValue: "nightly") == .nightly)
    #expect(AppUpdateReleaseTrack.regular.feedURL(in: configuration) == configuration.feedURL)
    #expect(
        AppUpdateReleaseTrack.nightly.feedURL(in: configuration)
            == configuration.nightlyFeedURL
    )
    #expect(AppUpdateReleaseTrack.regular.systemImage == "sun.max.fill")
    #expect(AppUpdateReleaseTrack.nightly.systemImage == "moon.fill")
}

@MainActor
@Test("existing release track preference carries into a new updater controller")
func existingReleaseTrackPreferenceCarriesForward() {
    let defaults = InMemoryPreferences()
    defaults.set("nightly", forKey: AppUpdateReleaseTrack.preferenceKey)
    let configuration = AppUpdateConfiguration(
        infoDictionary: productionUpdateInfo(),
        bundleIdentifier: AppUpdateConfiguration.canonicalBundleIdentifier
    )

    let controller = AppUpdateController(configuration: configuration, defaults: defaults)

    #expect(controller.releaseTrack == .nightly)
}

@MainActor
@Test("release track changes persist before the updater starts")
func releaseTrackChangesPersist() {
    let defaults = InMemoryPreferences()
    let configuration = AppUpdateConfiguration(
        infoDictionary: productionUpdateInfo(),
        bundleIdentifier: AppUpdateConfiguration.canonicalBundleIdentifier
    )
    let controller = AppUpdateController(configuration: configuration, defaults: defaults)

    controller.setReleaseTrack(.nightly)
    #expect(controller.releaseTrack == .nightly)
    #expect(defaults.string(forKey: AppUpdateReleaseTrack.preferenceKey) == "nightly")

    controller.setReleaseTrack(.regular)
    #expect(controller.releaseTrack == .regular)
    #expect(defaults.string(forKey: AppUpdateReleaseTrack.preferenceKey) == "regular")
}

@MainActor
@Test("disabled updater lifecycle stays inert")
func disabledUpdaterLifecycleStaysInert() {
    let defaults = InMemoryPreferences()
    let controller = AppUpdateController(
        configuration: AppUpdateConfiguration(
            infoDictionary: [:],
            bundleIdentifier: AppUpdateConfiguration.canonicalBundleIdentifier
        ),
        defaults: defaults
    )

    controller.start()
    controller.checkForUpdates()
    controller.setAutomaticallyChecksForUpdates(true)
    controller.setAutomaticallyDownloadsUpdates(true)

    #expect(!controller.isEnabled)
    #expect(!controller.canCheckForUpdates)
    #expect(!controller.automaticallyChecksForUpdates)
    #expect(!controller.automaticallyDownloadsUpdates)
    #expect(controller.lastSuccessfulCheckDate == nil)
    #expect(
        controller.availabilityDescription
            == AppUpdateUnavailabilityReason.disabledForBuild.description
    )
    #expect(
        controller.unavailabilityDescription
            == "This build was packaged with update checking disabled."
    )
    #expect(
        defaults.object(forKey: AppUpdateController.lastSuccessfulCheckPreferenceKey)
            == nil
    )
}

@MainActor
@Test("successful appcast loads persist separately from attempted checks")
func successfulAppcastLoadsPersist() {
    let defaults = InMemoryPreferences()
    let date = Date(timeIntervalSince1970: 1_784_764_800)
    let configuration = AppUpdateConfiguration(
        infoDictionary: productionUpdateInfo(),
        bundleIdentifier: AppUpdateConfiguration.canonicalBundleIdentifier
    )
    let controller = AppUpdateController(configuration: configuration, defaults: defaults)

    #expect(controller.lastSuccessfulCheckDate == nil)
    controller.checkForUpdates()
    #expect(controller.lastSuccessfulCheckDate == nil)

    controller.recordSuccessfulFeedCheck(at: date)
    #expect(controller.lastSuccessfulCheckDate == date)

    let restored = AppUpdateController(configuration: configuration, defaults: defaults)
    #expect(restored.lastSuccessfulCheckDate == date)
}

private func productionUpdateInfo() -> [String: Any] {
    [
        AppUpdateConfiguration.enabledInfoKey: true,
        AppUpdateConfiguration.nightlyFeedInfoKey:
            AppUpdateConfiguration.expectedNightlyFeedURL.absoluteString,
        "SUFeedURL": AppUpdateConfiguration.expectedFeedURL.absoluteString,
        "SUPublicEDKey": validPublicKey,
        "SUEnableAutomaticChecks": true,
        "SUScheduledCheckInterval": AppUpdateConfiguration.scheduledCheckInterval,
        "SUAutomaticallyUpdate": false,
        "SUAllowsAutomaticUpdates": true,
        "SUEnableInstallerLauncherService": true,
        "SUVerifyUpdateBeforeExtraction": true,
        "SURequireSignedFeed": true
    ]
}
