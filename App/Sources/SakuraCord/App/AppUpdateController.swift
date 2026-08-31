import Combine
import Foundation
import Sparkle

nonisolated enum AppUpdateUnavailabilityReason: Equatable, Sendable {
    case disabledForBuild
    case noncanonicalBundle
    case invalidStableFeed
    case invalidNightlyFeed
    case invalidBuildVersion
    case invalidVersionDowngradePolicy
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
        case .invalidBuildVersion:
            "This build does not have a valid numeric update version."
        case .invalidVersionDowngradePolicy:
            "This build’s release-track replacement policy is invalid."
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
    static let releaseTrackInfoKey = "SakuraCordReleaseTrack"
    static let versionDowngradeInfoKey = "SUAllowsVersionDowngrades"
    static let expectedFeedURL = URL(
        string: "https://github.com/SakuraCordApp/SakuraCord/releases/latest/download/appcast.xml"
    )!
    static let expectedNightlyFeedURL = URL(
        string: "https://sakuracord.app/updates/appcast.xml"
    )!
    static let scheduledCheckInterval = 6 * 60 * 60

    let isEnabled: Bool
    let feedURL: URL?
    let nightlyFeedURL: URL?
    let installedReleaseTrack: AppUpdateReleaseTrack
    let installedBuildVersion: String?
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
        let installedBuildVersion = infoDictionary["CFBundleVersion"] as? String
        let allowsVersionDowngrades =
            infoDictionary[Self.versionDowngradeInfoKey] as? Bool == true
        let publicKeyData = publicEdKey.flatMap {
            Data(base64Encoded: $0)
        }
        self.feedURL = feedURL
        self.nightlyFeedURL = nightlyFeedURL
        installedReleaseTrack = AppUpdateReleaseTrack(
            storedValue: infoDictionary[Self.releaseTrackInfoKey] as? String
        )
        self.installedBuildVersion = installedBuildVersion
        self.publicEdKey = publicEdKey
        if !enabled {
            unavailabilityReason = .disabledForBuild
        } else if bundleIdentifier != Self.canonicalBundleIdentifier {
            unavailabilityReason = .noncanonicalBundle
        } else if feedURL != Self.expectedFeedURL {
            unavailabilityReason = .invalidStableFeed
        } else if nightlyFeedURL != Self.expectedNightlyFeedURL {
            unavailabilityReason = .invalidNightlyFeed
        } else if installedBuildVersion.flatMap(Int.init).map({ $0 > 0 }) != true {
            unavailabilityReason = .invalidBuildVersion
        } else if allowsVersionDowngrades != (installedReleaseTrack == .nightly) {
            unavailabilityReason = .invalidVersionDowngradePolicy
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

nonisolated final class AppUpdateVersionComparator: NSObject, SUVersionComparison,
    @unchecked Sendable
{
    private let installedVersion: String
    private let standardComparator = SUStandardVersionComparator()
    private let lock = NSLock()
    private var allowsInstalledVersionDowngrade = false

    init(installedVersion: String) {
        self.installedVersion = installedVersion
    }

    func setAllowsInstalledVersionDowngrade(_ allowed: Bool) {
        lock.withLock {
            allowsInstalledVersionDowngrade = allowed
        }
    }

    func compareVersion(
        _ versionA: String,
        toVersion versionB: String
    ) -> ComparisonResult {
        let result = standardComparator.compareVersion(versionA, toVersion: versionB)
        let allowsDowngrade = lock.withLock { allowsInstalledVersionDowngrade }
        guard allowsDowngrade else { return result }

        if versionA == installedVersion,
           versionB != installedVersion,
           result == .orderedDescending
        {
            return .orderedAscending
        }
        if versionB == installedVersion,
           versionA != installedVersion,
           result == .orderedAscending
        {
            return .orderedDescending
        }
        return result
    }
}

nonisolated final class AppUpdateVersionDisplay: NSObject, SUVersionDisplay,
    @unchecked Sendable
{
    private let installedDisplayVersion: String?

    init(installedDisplayVersion: String?) {
        self.installedDisplayVersion = installedDisplayVersion
    }

    func bundleDisplayVersion(fallback: String) -> String {
        installedDisplayVersion ?? fallback
    }

    func formatUpdateVersion(
        fromUpdate update: SUAppcastItem,
        andBundleDisplayVersion bundleDisplayVersion:
            AutoreleasingUnsafeMutablePointer<NSString>,
        withBundleVersion _: String
    ) -> String {
        bundleDisplayVersion.pointee = self.bundleDisplayVersion(
            fallback: bundleDisplayVersion.pointee as String
        ) as NSString
        return update.displayVersionString
    }

    func formatBundleDisplayVersion(
        _ bundleDisplayVersion: String,
        withBundleVersion _: String,
        matchingUpdate _: SUAppcastItem?
    ) -> String {
        self.bundleDisplayVersion(fallback: bundleDisplayVersion)
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

    init(storedValue: String?, defaultingTo defaultTrack: Self = .regular) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? defaultTrack
    }

    func feedURL(in configuration: AppUpdateConfiguration) -> URL? {
        switch self {
        case .regular: configuration.feedURL
        case .nightly: configuration.nightlyFeedURL
        }
    }
}

@MainActor
final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate,
    SPUStandardUserDriverDelegate
{
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
    private let versionComparator: AppUpdateVersionComparator?
    private let versionDisplay: AppUpdateVersionDisplay
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    init(
        configuration: AppUpdateConfiguration = AppUpdateConfiguration(),
        defaults: any PreferenceStoring = UserDefaults.standard
    ) {
        self.configuration = configuration
        self.defaults = defaults
        let initialReleaseTrack = AppUpdateReleaseTrack(
            storedValue: defaults.string(forKey: AppUpdateReleaseTrack.preferenceKey),
            defaultingTo: configuration.installedReleaseTrack
        )
        releaseTrack = initialReleaseTrack
        versionComparator = configuration.installedBuildVersion.map(
            AppUpdateVersionComparator.init(installedVersion:)
        )
        versionDisplay = AppUpdateVersionDisplay(
            installedDisplayVersion: AboutVersionInformation().displayVersion
        )
        lastSuccessfulCheckDate = defaults.object(
            forKey: Self.lastSuccessfulCheckPreferenceKey
        ) as? Date
        isEnabled = configuration.isEnabled
        super.init()

        updateVersionDowngradeComparison(for: initialReleaseTrack)

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
        updateVersionDowngradeComparison(for: track)
        pendingReleaseTrackCheck = true
        pendingReleaseTrackUpdatePresentation = false
        continueReleaseTrackChange()
    }

    func feedURLString(for _: SPUUpdater) -> String? {
        releaseTrack.feedURL(in: configuration)?.absoluteString
    }

    func versionComparator(for _: SPUUpdater) -> (any SUVersionComparison)? {
        versionComparator
    }

    func standardUserDriverRequestsVersionDisplayer() -> (any SUVersionDisplay)? {
        versionDisplay
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

    private func updateVersionDowngradeComparison(for track: AppUpdateReleaseTrack) {
        versionComparator?.setAllowsInstalledVersionDowngrade(
            configuration.installedReleaseTrack == .nightly && track == .regular
        )
    }

    func recordSuccessfulFeedCheck(at date: Date) {
        lastSuccessfulCheckDate = date
        defaults.set(date, forKey: Self.lastSuccessfulCheckPreferenceKey)
    }
}
