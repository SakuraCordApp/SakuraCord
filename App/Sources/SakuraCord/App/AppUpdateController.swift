import Combine
import AppKit
import Foundation
import Sparkle
import SakuraCordModels

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
    case invalidPreviewMetadata

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
        case .invalidPreviewMetadata:
            "This PR build does not have valid build-switching metadata."
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
    let installedPullRequestBuildID: String?
    let installedPullRequestNumber: Int?

    var pullRequestFeedURL: URL? {
        installedPullRequestNumber.flatMap {
            URL(string: "https://github.com/SakuraCordApp/Builds/releases/download/pr-\($0)/appcast.xml")
        }
    }
    let publicEdKey: String?
    let unavailabilityReason: AppUpdateUnavailabilityReason?

    init(
        infoDictionary: [String: Any],
        bundleIdentifier: String?
    ) {
        let enabled = infoDictionary[Self.enabledInfoKey] as? Bool == true
        let preview = SakuraCordStorageProfile(infoDictionary: infoDictionary).previewIdentifier
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
        installedPullRequestBuildID = preview
        installedPullRequestNumber = preview.flatMap { identifier in
            identifier.split(separator: "-").dropFirst().first.flatMap { Int($0) }
        }
        self.publicEdKey = publicEdKey
        if !enabled {
            unavailabilityReason = .disabledForBuild
        } else if preview != nil, preview == "unrecognized-preview" || installedPullRequestNumber == nil
            || infoDictionary["SakuraCordBuildSwitchingProtocol"] as? Int != 1 {
            unavailabilityReason = .invalidPreviewMetadata
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

nonisolated enum AppUpdateReleaseTrack: String, Codable, CaseIterable, Identifiable, Sendable {
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

/// Checkpoint a requested return before Sparkle's external installer can finish on
/// normal Quit. Older release binaries already see the selected track; cancellation
/// and an unchanged/recovery launch restore the previous preference.
nonisolated struct PendingReleaseReturn: Codable, Equatable {
    static let preferenceKey = "updates.pendingReleaseReturn"
    let previousTrack: String?
    let targetTrack: AppUpdateReleaseTrack
    let targetVersion: String

    static func load(from defaults: any PreferenceStoring) -> Self? {
        defaults.data(forKey: preferenceKey).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    static func checkpoint(track: AppUpdateReleaseTrack, version: String, defaults: any PreferenceStoring) {
        if let pending = load(from: defaults), pending.targetTrack == track, pending.targetVersion == version {
            return
        }
        rollback(defaults: defaults)
        let intent = Self(previousTrack: defaults.string(forKey: AppUpdateReleaseTrack.preferenceKey),
                          targetTrack: track, targetVersion: version)
        guard let data = try? JSONEncoder().encode(intent) else { return }
        defaults.set(data, forKey: preferenceKey)
        defaults.set(track.rawValue, forKey: AppUpdateReleaseTrack.preferenceKey)
    }

    static func rollback(defaults: any PreferenceStoring) {
        guard let intent = load(from: defaults) else { return }
        if defaults.string(forKey: AppUpdateReleaseTrack.preferenceKey) == intent.targetTrack.rawValue {
            if let previousTrack = intent.previousTrack {
                defaults.set(previousTrack, forKey: AppUpdateReleaseTrack.preferenceKey)
            } else {
                defaults.removeObject(forKey: AppUpdateReleaseTrack.preferenceKey)
            }
        }
        defaults.removeObject(forKey: preferenceKey)
    }

    static func reconcile(configuration: AppUpdateConfiguration, defaults: any PreferenceStoring) {
        guard let intent = load(from: defaults) else { return }
        if configuration.isEnabled, configuration.installedPullRequestBuildID == nil,
           let installedVersion = configuration.installedBuildVersion,
           SUStandardVersionComparator().compareVersion(installedVersion, toVersion: intent.targetVersion) != .orderedAscending,
           configuration.installedReleaseTrack == intent.targetTrack {
            // An older release may have installed this target and updated again
            // before reaching a binary that understands the checkpoint. Keep any
            // subsequent explicit track choice made in that released app.
            defaults.removeObject(forKey: preferenceKey)
        } else {
            rollback(defaults: defaults)
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
    @Published private var updateSessionInProgress = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var allowsAutomaticUpdates = false
    @Published private(set) var releaseTrack: AppUpdateReleaseTrack
    @Published private(set) var lastSuccessfulCheckDate: Date?
    @Published var buildSwitchError: String?
    @Published private(set) var isPreparingBuildSwitch = false
    @Published private(set) var recoveryLocation: URL?

    var installedPullRequestBuildID: String? {
        configuration.installedPullRequestBuildID
    }

    var activeTrackTitle: String {
        configuration.installedPullRequestNumber.map { "PR #\($0)" } ?? releaseTrack.title
    }

    var currentFeedURL: URL? {
        if let build = selectedPullRequestBuild { return build.appcastURL }
        if let track = explicitReturnTrack { return track.feedURL(in: configuration) }
        return configuration.pullRequestFeedURL ?? releaseTrack.feedURL(in: configuration)
    }

    @Published private var selectedPullRequestBuild: PullRequestBuild?
    @Published private var explicitReturnTrack: AppUpdateReleaseTrack?
    private var returnBuildVersion: String?

    var canSwitchBuilds: Bool {
        isEnabled && canCheckForUpdates && !updateSessionInProgress && !isPreparingBuildSwitch
            && selectedPullRequestBuild == nil && explicitReturnTrack == nil
    }

    let isEnabled: Bool

    var unavailabilityDescription: String? {
        configuration.unavailabilityReason?.description
    }

    var availabilityDescription: String {
        if let unavailabilityDescription {
            return unavailabilityDescription
        }
        if canCheckForUpdates {
            return "SakuraCord is ready to check the signed \(activeTrackTitle) feed."
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
        PendingReleaseReturn.reconcile(configuration: configuration, defaults: defaults)
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
        updater.publisher(for: \.sessionInProgress)
            .assign(to: &$updateSessionInProgress)
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
        guard configuration.isEnabled, canCheckForUpdates,
              !isPreparingBuildSwitch else { return }
        updaterController.checkForUpdates(nil)
    }

    func installPullRequestBuild(_ build: PullRequestBuild) async {
        guard canSwitchBuilds else { return }
        isPreparingBuildSwitch = true
        defer { isPreparingBuildSwitch = false }
        do {
            try build.validate()
            recoveryLocation = try await PRBuildRecovery().prepareRecovery()
            guard canCheckForUpdates, !updateSessionInProgress else { throw PullRequestBuildError.unavailable }
            selectedPullRequestBuild = build
            explicitReturnTrack = nil
            try updaterController.updater.checkForUpdates(forVersion: build.buildVersion)
        } catch {
            selectedPullRequestBuild = nil
            if (error as NSError).code != NSUserCancelledError {
                buildSwitchError = error.localizedDescription
            }
        }
    }

    func revealRecoveryCopy() async {
        do {
            let url = try await PRBuildRecovery().retainedRecoveryURL()
            recoveryLocation = url
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            buildSwitchError = error.localizedDescription
        }
    }

    func returnToRelease(_ track: AppUpdateReleaseTrack) {
        guard canSwitchBuilds, installedPullRequestBuildID != nil else { return }
        selectedPullRequestBuild = nil
        explicitReturnTrack = track
        returnBuildVersion = nil
        versionComparator?.setAllowsInstalledVersionDowngrade(true)
        updaterController.updater.checkForUpdateInformation()
    }

    func updater(_: SPUUpdater, mayPerform check: SPUUpdateCheck) throws {
        if check == .updatesInBackground,
           selectedPullRequestBuild != nil || explicitReturnTrack != nil || isPreparingBuildSwitch {
            throw NSError(domain: "SakuraCord.BuildSwitching", code: 1)
        }
    }

    func updater(_: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck _: SPUUpdateCheck) throws {
        guard let build = selectedPullRequestBuild else { return }
        guard item.versionString == build.buildVersion,
              item.fileURL == build.archiveURL else {
            throw PullRequestBuildError.invalidCatalog
        }
    }

    func exportAutomaticPreference(for id: SettingsControlID) -> Bool {
        if id == .updateAutomaticChecks {
            return isEnabled ? automaticallyChecksForUpdates : defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true
        }
        return isEnabled ? automaticallyDownloadsUpdates : defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool ?? false
    }

    func importAutomaticPreference(_ enabled: Bool, for id: SettingsControlID) {
        if id == .updateAutomaticChecks {
            defaults.set(enabled, forKey: "SUEnableAutomaticChecks")
            if isEnabled { setAutomaticallyChecksForUpdates(enabled) }
        } else if id == .updateAutomaticDownloads {
            defaults.set(enabled, forKey: "SUAutomaticallyUpdate")
            if isEnabled { setAutomaticallyDownloadsUpdates(enabled) }
        }
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
        guard configuration.isEnabled, track != releaseTrack,
              installedPullRequestBuildID == nil, !isPreparingBuildSwitch,
              selectedPullRequestBuild == nil else { return }
        defaults.set(track.rawValue, forKey: AppUpdateReleaseTrack.preferenceKey)
        releaseTrack = track
        updateVersionDowngradeComparison(for: track)
        pendingReleaseTrackCheck = true
        pendingReleaseTrackUpdatePresentation = false
        continueReleaseTrackChange()
    }

    func importReleaseTrack(_ track: AppUpdateReleaseTrack) {
        if isEnabled {
            setReleaseTrack(track)
        } else {
            defaults.set(track.rawValue, forKey: AppUpdateReleaseTrack.preferenceKey)
            releaseTrack = track
        }
    }

    func feedURLString(for _: SPUUpdater) -> String? {
        currentFeedURL?.absoluteString
    }

    func versionComparator(for _: SPUUpdater) -> (any SUVersionComparison)? {
        versionComparator
    }

    func standardUserDriverRequestsVersionDisplayer() -> (any SUVersionDisplay)? {
        versionDisplay
    }

    func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        if explicitReturnTrack != nil {
            returnBuildVersion = item.versionString
        }
        guard probingReleaseTrack == releaseTrack else { return }
        releaseTrackProbeFoundUpdate = true
    }

    func updater(_: SPUUpdater, didFinishLoading _: SUAppcast) {
        recordSuccessfulFeedCheck(at: Date())
    }

    func updater(
        _: SPUUpdater,
        didFinishUpdateCycleFor check: SPUUpdateCheck,
        error: (any Error)?
    ) {
        if error != nil, installedPullRequestBuildID != nil {
            PendingReleaseReturn.rollback(defaults: defaults)
        }
        if let track = explicitReturnTrack, check == .updateInformation {
            if let version = returnBuildVersion, error == nil {
                // Sparkle clears its driver/session before this callback. Start
                // the selected operation before it reschedules automatic checks;
                // deferring to another task lets that cycle take the idle slot.
                do {
                    try updaterController.updater.checkForUpdates(forVersion: version)
                } catch {
                    explicitReturnTrack = nil
                    updateVersionDowngradeComparison(for: releaseTrack)
                    buildSwitchError = error.localizedDescription
                }
            } else {
                explicitReturnTrack = nil
                updateVersionDowngradeComparison(for: releaseTrack)
                buildSwitchError = error?.localizedDescription ?? "No compatible \(track.title) release is available. You are still on \(activeTrackTitle)."
            }
            return
        }
        if selectedPullRequestBuild != nil || explicitReturnTrack != nil {
            selectedPullRequestBuild = nil
            explicitReturnTrack = nil
            returnBuildVersion = nil
            if let error { buildSwitchError = error.localizedDescription }
            updateVersionDowngradeComparison(for: releaseTrack)
            return
        }
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

    func updater(_: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        guard let track = explicitReturnTrack, item.versionString == returnBuildVersion else { return }
        // Sparkle invokes this before the external helper can finish on Quit.
        // The feed item is verified; archive/installation failures still roll back.
        PendingReleaseReturn.checkpoint(track: track, version: item.versionString, defaults: defaults)
    }

    func updater(_: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate _: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip || (choice == .dismiss && state.stage != .installing) {
            PendingReleaseReturn.rollback(defaults: defaults)
        }
    }

    private func continueReleaseTrackChange() {
        guard hasStarted, canCheckForUpdates, installedPullRequestBuildID == nil,
              selectedPullRequestBuild == nil, explicitReturnTrack == nil,
              !isPreparingBuildSwitch else { return }
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
            configuration.installedPullRequestBuildID == nil
                && configuration.installedReleaseTrack == .nightly && track == .regular
        )
    }

    func recordSuccessfulFeedCheck(at date: Date) {
        lastSuccessfulCheckDate = date
        defaults.set(date, forKey: Self.lastSuccessfulCheckPreferenceKey)
    }
}
