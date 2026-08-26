import Combine
import Foundation
import Sparkle

nonisolated enum AppUpdateUnavailabilityReason: Equatable, Sendable {
    case disabledForBuild
    case noncanonicalBundle
    case invalidStableFeed
    case invalidNightlyFeed
    case invalidPublicKey
    case automaticChecksNotEnabled
    case invalidCheckInterval
    case automaticInstallationNotDisabled
    case automaticUpdatesNotAllowed
    case installerLauncherServiceNotEnabled
    case updateVerificationNotEnabled
    case signedFeedNotRequired

    var description: String {
        switch self {
        case .disabledForBuild:
            "This build was packaged with update checking disabled."
        case .noncanonicalBundle:
            "Update checking is disabled because this is not the canonical SakuraCord app bundle."
        case .invalidStableFeed:
            "The configured stable update feed does not match SakuraCord’s signed stable feed."
        case .invalidNightlyFeed:
            "The configured nightly update feed does not match SakuraCord’s signed nightly feed."
        case .invalidPublicKey:
            "The Sparkle public key is not a valid 32-byte Ed25519 key."
        case .automaticChecksNotEnabled:
            "Automatic update checking is not enabled in this build’s configuration."
        case .invalidCheckInterval:
            "The configured update-check interval is not the required six hours."
        case .automaticInstallationNotDisabled:
            "Automatic update installation is not explicitly disabled in this build."
        case .automaticUpdatesNotAllowed:
            "Automatic update downloads are not allowed by this build’s configuration."
        case .installerLauncherServiceNotEnabled:
            "Sparkle’s installer launcher service is not enabled in this build."
        case .updateVerificationNotEnabled:
            "Update verification before extraction is not enabled in this build."
        case .signedFeedNotRequired:
            "This build does not require a signed update feed."
        }
    }
}

nonisolated struct AppUpdateConfiguration: Equatable, Sendable {
    static let canonicalBundleIdentifier = "dev.sakuracord.SakuraCord"
    static let enabledInfoKey = "SakuraCordUpdatesEnabled"
    static let nightlyFeedInfoKey = "SakuraCordNightlyFeedURL"
    static let expectedFeedURL = URL(
        string: "https://github.com/SakuraCordApp/SakuraCord/releases/latest/download/appcast.xml"
    )!
    static let expectedNightlyFeedURL = URL(
        string: "https://raw.githubusercontent.com/SakuraCordApp/SakuraCord/nightly-feed/appcast.xml"
    )!
    static let scheduledCheckInterval = 6 * 60 * 60

    let isEnabled: Bool
    let feedURL: URL?
    let nightlyFeedURL: URL?
    let publicEdKey: String?
    let unavailabilityReason: AppUpdateUnavailabilityReason?

    init(
        infoDictionary: [String: Any],
        bundleIdentifier: String?
    ) {
        let enabled = infoDictionary[Self.enabledInfoKey] as? Bool == true
        let feedURL = (infoDictionary["SUFeedURL"] as? String).flatMap(URL.init(string:))
        let nightlyFeedURL = (infoDictionary[Self.nightlyFeedInfoKey] as? String)
            .flatMap(URL.init(string:))
        let publicEdKey = infoDictionary["SUPublicEDKey"] as? String
        let publicKeyData = publicEdKey.flatMap {
            Data(base64Encoded: $0)
        }
        self.feedURL = feedURL
        self.nightlyFeedURL = nightlyFeedURL
        self.publicEdKey = publicEdKey
        if !enabled {
            unavailabilityReason = .disabledForBuild
        } else if bundleIdentifier != Self.canonicalBundleIdentifier {
            unavailabilityReason = .noncanonicalBundle
        } else if feedURL != Self.expectedFeedURL {
            unavailabilityReason = .invalidStableFeed
        } else if nightlyFeedURL != Self.expectedNightlyFeedURL {
            unavailabilityReason = .invalidNightlyFeed
        } else if publicKeyData?.count != 32 {
            unavailabilityReason = .invalidPublicKey
        } else if infoDictionary["SUEnableAutomaticChecks"] as? Bool != true {
            unavailabilityReason = .automaticChecksNotEnabled
        } else if infoDictionary["SUScheduledCheckInterval"] as? Int
            != Self.scheduledCheckInterval
        {
            unavailabilityReason = .invalidCheckInterval
        } else if infoDictionary["SUAutomaticallyUpdate"] as? Bool != false {
            unavailabilityReason = .automaticInstallationNotDisabled
        } else if infoDictionary["SUAllowsAutomaticUpdates"] as? Bool != true {
            unavailabilityReason = .automaticUpdatesNotAllowed
        } else if infoDictionary["SUEnableInstallerLauncherService"] as? Bool != true {
            unavailabilityReason = .installerLauncherServiceNotEnabled
        } else if infoDictionary["SUVerifyUpdateBeforeExtraction"] as? Bool != true {
            unavailabilityReason = .updateVerificationNotEnabled
        } else if infoDictionary["SURequireSignedFeed"] as? Bool != true {
            unavailabilityReason = .signedFeedNotRequired
        } else {
            unavailabilityReason = nil
        }
        isEnabled = unavailabilityReason == nil
    }

    init(bundle: Bundle = .main) {
        self.init(
            infoDictionary: bundle.infoDictionary ?? [:],
            bundleIdentifier: bundle.bundleIdentifier
        )
    }
}

nonisolated enum AppUpdateReleaseTrack: String, CaseIterable, Identifiable, Sendable {
    case regular
    case nightly

    static let preferenceKey = "updateReleaseTrack"

    var id: Self { self }

    var title: String {
        switch self {
        case .regular: "Regular"
        case .nightly: "Nightly"
        }
    }

    var systemImage: String {
        switch self {
        case .regular: "sun.max.fill"
        case .nightly: "moon.fill"
        }
    }

    init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .regular
    }

    func feedURL(in configuration: AppUpdateConfiguration) -> URL? {
        switch self {
        case .regular: configuration.feedURL
        case .nightly: configuration.nightlyFeedURL
        }
    }
}

@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let lastSuccessfulCheckPreferenceKey =
        "updates.lastSuccessfulSignedFeedCheck"

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var allowsAutomaticUpdates = false
    @Published private(set) var releaseTrack: AppUpdateReleaseTrack
    @Published private(set) var lastSuccessfulCheckDate: Date?

    let isEnabled: Bool

    var unavailabilityDescription: String? {
        configuration.unavailabilityReason?.description
    }

    var availabilityDescription: String {
        if let unavailabilityDescription {
            return unavailabilityDescription
        }
        if canCheckForUpdates {
            return "SakuraCord is ready to check the signed \(releaseTrack.title.lowercased()) feed."
        }
        return "An update check or installation is currently in progress."
    }

    private let configuration: AppUpdateConfiguration
    private let defaults: any PreferenceStoring
    private var hasStarted = false
    private var pendingReleaseTrackCheck = false
    private var probingReleaseTrack: AppUpdateReleaseTrack?
    private var releaseTrackProbeFoundUpdate = false
    private var pendingReleaseTrackUpdatePresentation = false
    private var cancellables: Set<AnyCancellable> = []
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    init(
        configuration: AppUpdateConfiguration = AppUpdateConfiguration(),
        defaults: any PreferenceStoring = UserDefaults.standard
    ) {
        self.configuration = configuration
        self.defaults = defaults
        releaseTrack = AppUpdateReleaseTrack(
            storedValue: defaults.string(forKey: AppUpdateReleaseTrack.preferenceKey)
        )
        lastSuccessfulCheckDate = defaults.object(
            forKey: Self.lastSuccessfulCheckPreferenceKey
        ) as? Date
        isEnabled = configuration.isEnabled
        super.init()

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
        $canCheckForUpdates
            .removeDuplicates()
            .sink { [weak self] canCheckForUpdates in
                guard canCheckForUpdates else { return }
                self?.continueReleaseTrackChange()
            }
            .store(in: &cancellables)
    }

    func start() {
        guard configuration.isEnabled, !hasStarted else { return }
        hasStarted = true
        updaterController.startUpdater()
        continueReleaseTrackChange()
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

    func setReleaseTrack(_ track: AppUpdateReleaseTrack) {
        guard configuration.isEnabled, track != releaseTrack else { return }
        defaults.set(track.rawValue, forKey: AppUpdateReleaseTrack.preferenceKey)
        releaseTrack = track
        pendingReleaseTrackCheck = true
        pendingReleaseTrackUpdatePresentation = false
        continueReleaseTrackChange()
    }

    func feedURLString(for _: SPUUpdater) -> String? {
        releaseTrack.feedURL(in: configuration)?.absoluteString
    }

    func updater(_: SPUUpdater, didFindValidUpdate _: SUAppcastItem) {
        guard probingReleaseTrack == releaseTrack else { return }
        releaseTrackProbeFoundUpdate = true
    }

    func updater(_: SPUUpdater, didFinishLoading _: SUAppcast) {
        recordSuccessfulFeedCheck(at: Date())
    }

    func updater(
        _: SPUUpdater,
        didFinishUpdateCycleFor _: SPUUpdateCheck,
        error _: (any Error)?
    ) {
        if let probingReleaseTrack {
            let stillSelected = probingReleaseTrack == releaseTrack
            self.probingReleaseTrack = nil
            if stillSelected, releaseTrackProbeFoundUpdate {
                pendingReleaseTrackUpdatePresentation = true
            }
            releaseTrackProbeFoundUpdate = false
        }
        continueReleaseTrackChange()
    }

    private func continueReleaseTrackChange() {
        guard hasStarted, canCheckForUpdates else { return }
        let updater = updaterController.updater
        if pendingReleaseTrackCheck {
            pendingReleaseTrackCheck = false
            probingReleaseTrack = releaseTrack
            releaseTrackProbeFoundUpdate = false
            updater.checkForUpdateInformation()
            if updater.canCheckForUpdates {
                probingReleaseTrack = nil
                pendingReleaseTrackCheck = true
            }
            return
        }
        if pendingReleaseTrackUpdatePresentation {
            pendingReleaseTrackUpdatePresentation = false
            updater.checkForUpdates()
        }
    }

    func recordSuccessfulFeedCheck(at date: Date) {
        lastSuccessfulCheckDate = date
        defaults.set(date, forKey: Self.lastSuccessfulCheckPreferenceKey)
    }
}
