import Combine
import Foundation
import Sparkle

nonisolated struct AppUpdateConfiguration: Equatable, Sendable {
    static let canonicalBundleIdentifier = "dev.sakuracord.SakuraCord"
    static let enabledInfoKey = "SakuraCordUpdatesEnabled"
    static let expectedFeedURL = URL(
        string: "https://github.com/SakuraCordApp/SakuraCord/releases/latest/download/appcast.xml"
    )!
    static let scheduledCheckInterval = 6 * 60 * 60

    let isEnabled: Bool
    let feedURL: URL?
    let publicEdKey: String?

    init(
        infoDictionary: [String: Any],
        bundleIdentifier: String?
    ) {
        let enabled = infoDictionary[Self.enabledInfoKey] as? Bool == true
        let feedURL = (infoDictionary["SUFeedURL"] as? String).flatMap(URL.init(string:))
        let publicEdKey = infoDictionary["SUPublicEDKey"] as? String
        let publicKeyData = publicEdKey.flatMap {
            Data(base64Encoded: $0)
        }
        let hasSafeDefaults =
            infoDictionary["SUEnableAutomaticChecks"] as? Bool == true
            && infoDictionary["SUScheduledCheckInterval"] as? Int == Self.scheduledCheckInterval
            && infoDictionary["SUAutomaticallyUpdate"] as? Bool == false
            && infoDictionary["SUAllowsAutomaticUpdates"] as? Bool == true
            && infoDictionary["SUEnableInstallerLauncherService"] as? Bool == true
            && infoDictionary["SUVerifyUpdateBeforeExtraction"] as? Bool == true
            && infoDictionary["SURequireSignedFeed"] as? Bool == true

        self.feedURL = feedURL
        self.publicEdKey = publicEdKey
        isEnabled =
            enabled
            && bundleIdentifier == Self.canonicalBundleIdentifier
            && feedURL == Self.expectedFeedURL
            && publicKeyData?.count == 32
            && hasSafeDefaults
    }

    init(bundle: Bundle = .main) {
        self.init(
            infoDictionary: bundle.infoDictionary ?? [:],
            bundleIdentifier: bundle.bundleIdentifier
        )
    }
}

@MainActor
final class AppUpdateController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var allowsAutomaticUpdates = false

    let isEnabled: Bool

    var availabilityDescription: String {
        if !isEnabled {
            return "Updates are unavailable in development and offline builds."
        }
        if canCheckForUpdates {
            return "SakuraCord is ready to check its signed update feed."
        }
        return "An update check or installation is currently in progress."
    }

    private let configuration: AppUpdateConfiguration
    private var hasStarted = false
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    init(configuration: AppUpdateConfiguration = AppUpdateConfiguration()) {
        self.configuration = configuration
        isEnabled = configuration.isEnabled

        guard configuration.isEnabled else { return }
        let updater = updaterController.updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .assign(to: &$automaticallyDownloadsUpdates)
        updater.publisher(for: \.allowsAutomaticUpdates)
            .assign(to: &$allowsAutomaticUpdates)
    }

    func start() {
        guard configuration.isEnabled, !hasStarted else { return }
        hasStarted = true
        updaterController.startUpdater()
    }

    func checkForUpdates() {
        guard configuration.isEnabled, canCheckForUpdates else { return }
        updaterController.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard configuration.isEnabled else { return }
        updaterController.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard configuration.isEnabled, allowsAutomaticUpdates else { return }
        updaterController.updater.automaticallyDownloadsUpdates = enabled
    }
}
