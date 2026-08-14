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
    #expect(configuration.publicEdKey == validPublicKey)
    #expect(AppUpdateConfiguration.scheduledCheckInterval == 21_600)
}

@Test("noncanonical developer bundles cannot enable production updates")
func noncanonicalBundlesCannotEnableUpdates() {
    let configuration = AppUpdateConfiguration(
        infoDictionary: productionUpdateInfo(),
        bundleIdentifier: "dev.example.SakuraCord"
    )

    #expect(!configuration.isEnabled)
}

@Test(
    "update configuration fails closed when release metadata is incomplete",
    arguments: [
        AppUpdateConfiguration.enabledInfoKey,
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

    #expect(!configuration.isEnabled)
}

@Test("update configuration rejects invalid trust or automatic-check metadata")
func invalidUpdateTrustMetadataIsDisabled() {
    var wrongFeed = productionUpdateInfo()
    wrongFeed["SUFeedURL"] = "https://example.invalid/appcast.xml"
    var malformedKey = productionUpdateInfo()
    malformedKey["SUPublicEDKey"] = "not-a-key"
    var wrongInterval = productionUpdateInfo()
    wrongInterval["SUScheduledCheckInterval"] = 60 * 60
    var automaticChecksDisabled = productionUpdateInfo()
    automaticChecksDisabled["SUEnableAutomaticChecks"] = false
    var automaticInstallByDefault = productionUpdateInfo()
    automaticInstallByDefault["SUAutomaticallyUpdate"] = true
    var automaticInstallOptInDisabled = productionUpdateInfo()
    automaticInstallOptInDisabled["SUAllowsAutomaticUpdates"] = false

    #expect(!AppUpdateConfiguration(
        infoDictionary: wrongFeed,
        bundleIdentifier: AppUpdateConfiguration.canonicalBundleIdentifier
    ).isEnabled)
    #expect(!AppUpdateConfiguration(
        infoDictionary: malformedKey,
        bundleIdentifier: AppUpdateConfiguration.canonicalBundleIdentifier
    ).isEnabled)
    #expect(!AppUpdateConfiguration(
        infoDictionary: wrongInterval,
        bundleIdentifier: AppUpdateConfiguration.canonicalBundleIdentifier
    ).isEnabled)
    #expect(!AppUpdateConfiguration(
        infoDictionary: automaticChecksDisabled,
        bundleIdentifier: AppUpdateConfiguration.canonicalBundleIdentifier
    ).isEnabled)
    #expect(!AppUpdateConfiguration(
        infoDictionary: automaticInstallByDefault,
        bundleIdentifier: AppUpdateConfiguration.canonicalBundleIdentifier
    ).isEnabled)
    #expect(!AppUpdateConfiguration(
        infoDictionary: automaticInstallOptInDisabled,
        bundleIdentifier: AppUpdateConfiguration.canonicalBundleIdentifier
    ).isEnabled)
}

@MainActor
@Test("disabled updater lifecycle stays inert")
func disabledUpdaterLifecycleStaysInert() {
    let controller = AppUpdateController(
        configuration: AppUpdateConfiguration(
            infoDictionary: [:],
            bundleIdentifier: AppUpdateConfiguration.canonicalBundleIdentifier
        )
    )

    controller.start()
    controller.checkForUpdates()
    controller.setAutomaticallyChecksForUpdates(true)
    controller.setAutomaticallyDownloadsUpdates(true)

    #expect(!controller.isEnabled)
    #expect(!controller.canCheckForUpdates)
    #expect(!controller.automaticallyChecksForUpdates)
    #expect(!controller.automaticallyDownloadsUpdates)
}

private func productionUpdateInfo() -> [String: Any] {
    [
        AppUpdateConfiguration.enabledInfoKey: true,
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
