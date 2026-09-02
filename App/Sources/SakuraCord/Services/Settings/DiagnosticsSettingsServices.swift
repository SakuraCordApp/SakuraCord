import AppKit
import Darwin
import DiscordProtocol
import Foundation
import MediaPipeline
import SakuraCordModels
import UniformTypeIdentifiers
import UserNotifications

nonisolated enum DiagnosticsPreferences {
    static let capturesDetailedPayloadsKey = "captureDetailedAPIPayloads"
    static let savesDiagnosticsToDiskKey = "saveAPIDiagnosticsToDisk"

    static func restore(
        defaults: any PreferenceStoring = UserDefaults.standard,
        store: DiscordAPIDiagnosticStore = .shared
    ) {
        store.capturesPayloadDetails = defaults.bool(
            forKey: capturesDetailedPayloadsKey
        )
        do {
            try store.setSavesDiagnosticsToDisk(
                defaults.bool(forKey: savesDiagnosticsToDiskKey)
            )
        } catch {
            defaults.set(false, forKey: savesDiagnosticsToDiskKey)
        }
    }
}

nonisolated enum DiagnosticsHealth: String, Codable, Equatable, Sendable {
    case unavailable
    case checking
    case healthy
    case degraded
    case failed

    var title: String {
        switch self {
        case .unavailable: "Unavailable"
        case .checking: "Checking"
        case .healthy: "Healthy"
        case .degraded: "Degraded"
        case .failed: "Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .unavailable: "minus.circle"
        case .checking: "clock"
        case .healthy: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }
}

nonisolated enum DiagnosticsSubsystem: String, Codable, CaseIterable, Sendable {
    case account
    case gateway
    case voice
    case voiceLatency
    case notifications
    case mediaCache
    case updateService
    case microphonePermission
    case cameraPermission

    var title: String {
        switch self {
        case .account: "Active Account"
        case .gateway: "Gateway Session"
        case .voice: "Voice Connection"
        case .voiceLatency: "Voice Latency"
        case .notifications: "Notifications"
        case .mediaCache: "Media Cache"
        case .updateService: "Update Service"
        case .microphonePermission: "Microphone Permission"
        case .cameraPermission: "Camera Permission"
        }
    }

}

nonisolated struct DiagnosticsStatusItem: Identifiable, Equatable, Sendable {
    let subsystem: DiagnosticsSubsystem
    let health: DiagnosticsHealth
    let detail: String

    var id: DiagnosticsSubsystem { subsystem }
}

nonisolated enum DiagnosticsMediaCacheCheck: Equatable, Sendable {
    case checking
    case available(MediaCache.Status)
    case unavailable
    case failed
}

@MainActor
enum DiagnosticsStatusBuilder {
    static func make(
        model: AppModel,
        updateController: AppUpdateController,
        notificationPermissionStatus: UNAuthorizationStatus?,
        mediaPermissions: VoiceMediaPermissionSnapshot,
        mediaCacheCheck: DiagnosticsMediaCacheCheck
    ) -> [DiagnosticsStatusItem] {
        [
            accountStatus(model),
            gatewayStatus(model),
            voiceStatus(model),
            notificationStatus(
                notificationPermissionStatus,
                preferences: model.notificationPreferences
            ),
            cacheStatus(mediaCacheCheck),
            updateStatus(updateController),
            voiceLatencyStatus(model),
            permissionStatus(.microphonePermission, mediaPermissions.microphone),
            permissionStatus(.cameraPermission, mediaPermissions.camera),
        ]
    }

    private static func accountStatus(_ model: AppModel) -> DiagnosticsStatusItem {
        guard model.activeAccountID != nil else {
            return DiagnosticsStatusItem(
                subsystem: .account,
                health: model.sessionState == .restoring ? .checking : .unavailable,
                detail: model.sessionState == .restoring
                    ? "Checking saved sessions" : "No active account"
            )
        }
        return switch model.sessionState {
        case .restoring:
            DiagnosticsStatusItem(
                subsystem: .account,
                health: .checking,
                detail: "Restoring session"
            )
        case .connecting:
            DiagnosticsStatusItem(
                subsystem: .account,
                health: .checking,
                detail: "Connecting"
            )
        case .workspace:
            DiagnosticsStatusItem(
                subsystem: .account,
                health: .healthy,
                detail: "Active session"
            )
        case .signedOut:
            DiagnosticsStatusItem(
                subsystem: .account,
                health: .degraded,
                detail: "Session unavailable"
            )
        }
    }

    private static func gatewayStatus(_ model: AppModel) -> DiagnosticsStatusItem {
        guard model.activeAccountID != nil else {
            return DiagnosticsStatusItem(
                subsystem: .gateway,
                health: .unavailable,
                detail: "No active account"
            )
        }
        return switch model.connectionState {
        case .ready:
            DiagnosticsStatusItem(
                subsystem: .gateway,
                health: .healthy,
                detail: "Ready"
            )
        case .connecting:
            DiagnosticsStatusItem(
                subsystem: .gateway,
                health: .checking,
                detail: "Connecting"
            )
        case .resuming:
            DiagnosticsStatusItem(
                subsystem: .gateway,
                health: .checking,
                detail: "Resuming"
            )
        case .backingOff:
            DiagnosticsStatusItem(
                subsystem: .gateway,
                health: .degraded,
                detail: "Waiting to reconnect"
            )
        case .authenticationFailed:
            DiagnosticsStatusItem(
                subsystem: .gateway,
                health: .failed,
                detail: "Authentication failed"
            )
        case .disconnected:
            DiagnosticsStatusItem(
                subsystem: .gateway,
                health: .degraded,
                detail: "Disconnected"
            )
        }
    }

    private static func voiceStatus(_ model: AppModel) -> DiagnosticsStatusItem {
        guard model.activeAccountID != nil else {
            return DiagnosticsStatusItem(
                subsystem: .voice,
                health: .unavailable,
                detail: "No active account"
            )
        }
        return switch model.voiceSessionState {
        case .idle:
            DiagnosticsStatusItem(
                subsystem: .voice,
                health: .healthy,
                detail: "Ready"
            )
        case .disconnected:
            disconnectedVoiceStatus(model)
        case .connecting:
            DiagnosticsStatusItem(
                subsystem: .voice,
                health: .checking,
                detail: "Connecting"
            )
        case .connected:
            DiagnosticsStatusItem(
                subsystem: .voice,
                health: .healthy,
                detail: "Connected"
            )
        case .reconnecting:
            DiagnosticsStatusItem(
                subsystem: .voice,
                health: .degraded,
                detail: "Reconnecting"
            )
        case .disconnecting:
            DiagnosticsStatusItem(
                subsystem: .voice,
                health: .checking,
                detail: "Disconnecting"
            )
        case .failed:
            DiagnosticsStatusItem(
                subsystem: .voice,
                health: .failed,
                detail: "Connection failed"
            )
        }
    }

    private static func disconnectedVoiceStatus(
        _ model: AppModel
    ) -> DiagnosticsStatusItem {
        guard model.activeVoiceChannel != nil else {
            return DiagnosticsStatusItem(
                subsystem: .voice,
                health: .healthy,
                detail: "Ready"
            )
        }
        return DiagnosticsStatusItem(
            subsystem: .voice,
            health: .degraded,
            detail: "Disconnected"
        )
    }

    private static func voiceLatencyStatus(_ model: AppModel) -> DiagnosticsStatusItem {
        guard model.activeAccountID != nil else {
            return DiagnosticsStatusItem(
                subsystem: .voiceLatency,
                health: .unavailable,
                detail: "No active account"
            )
        }
        switch model.voiceSessionState {
        case .idle:
            return DiagnosticsStatusItem(
                subsystem: .voiceLatency,
                health: .healthy,
                detail: "Ready"
            )
        case .disconnected where model.activeVoiceChannel == nil:
            return DiagnosticsStatusItem(
                subsystem: .voiceLatency,
                health: .healthy,
                detail: "Ready"
            )
        case .connecting, .connected, .disconnecting:
            guard let latency = model.voiceLatencyMilliseconds else {
                return DiagnosticsStatusItem(
                    subsystem: .voiceLatency,
                    health: .checking,
                    detail: "Measuring"
                )
            }
            return DiagnosticsStatusItem(
                subsystem: .voiceLatency,
                health: latency <= 150 ? .healthy : .degraded,
                detail: "\(latency) ms"
            )
        case .reconnecting, .disconnected:
            return DiagnosticsStatusItem(
                subsystem: .voiceLatency,
                health: .degraded,
                detail: "Waiting for connection"
            )
        case .failed:
            return DiagnosticsStatusItem(
                subsystem: .voiceLatency,
                health: .failed,
                detail: "Voice connection failed"
            )
        }
    }

    private static func notificationStatus(
        _ authorization: UNAuthorizationStatus?,
        preferences: NotificationPreferences
    ) -> DiagnosticsStatusItem {
        guard preferences.isEnabled else {
            return DiagnosticsStatusItem(
                subsystem: .notifications,
                health: .healthy,
                detail: "Disabled in SakuraCord"
            )
        }
        guard let authorization else {
            return DiagnosticsStatusItem(
                subsystem: .notifications,
                health: .checking,
                detail: "Checking macOS authorization"
            )
        }
        let delivery = preferences.notifiesOnlyInBackground
            ? "Background delivery enabled" : "Foreground and background delivery enabled"
        return switch authorization {
        case .authorized:
            DiagnosticsStatusItem(
                subsystem: .notifications,
                health: .healthy,
                detail: delivery
            )
        case .provisional, .ephemeral:
            DiagnosticsStatusItem(
                subsystem: .notifications,
                health: .degraded,
                detail: "Limited macOS authorization"
            )
        case .denied:
            DiagnosticsStatusItem(
                subsystem: .notifications,
                health: .degraded,
                detail: "Denied by macOS"
            )
        case .notDetermined:
            DiagnosticsStatusItem(
                subsystem: .notifications,
                health: .unavailable,
                detail: "Permission not requested"
            )
        @unknown default:
            DiagnosticsStatusItem(
                subsystem: .notifications,
                health: .failed,
                detail: "Unknown authorization state"
            )
        }
    }

    private static func cacheStatus(
        _ check: DiagnosticsMediaCacheCheck
    ) -> DiagnosticsStatusItem {
        let status: MediaCache.Status
        switch check {
        case .checking:
            return DiagnosticsStatusItem(
                subsystem: .mediaCache,
                health: .checking,
                detail: "Checking cache state"
            )
        case let .available(value):
            status = value
        case .unavailable:
            return DiagnosticsStatusItem(
                subsystem: .mediaCache,
                health: .unavailable,
                detail: "Cache status unavailable"
            )
        case .failed:
            return DiagnosticsStatusItem(
                subsystem: .mediaCache,
                health: .failed,
                detail: "Cache status check failed"
            )
        }
        return switch status.evictionStatus {
        case .withinLimit:
            DiagnosticsStatusItem(
                subsystem: .mediaCache,
                health: .healthy,
                detail: "Within configured limit"
            )
        case .converging:
            DiagnosticsStatusItem(
                subsystem: .mediaCache,
                health: .checking,
                detail: "Converging to configured limit"
            )
        case .incomplete:
            DiagnosticsStatusItem(
                subsystem: .mediaCache,
                health: .degraded,
                detail: "Eviction is incomplete"
            )
        }
    }

    private static func updateStatus(
        _ controller: AppUpdateController
    ) -> DiagnosticsStatusItem {
        guard controller.isEnabled else {
            return DiagnosticsStatusItem(
                subsystem: .updateService,
                health: .unavailable,
                detail: controller.unavailabilityDescription ?? "Unavailable in this build"
            )
        }
        return DiagnosticsStatusItem(
            subsystem: .updateService,
            health: controller.canCheckForUpdates ? .healthy : .checking,
            detail: controller.canCheckForUpdates ? "Ready" : "Busy"
        )
    }

    private static func permissionStatus(
        _ subsystem: DiagnosticsSubsystem,
        _ authorization: VoiceMediaAuthorization
    ) -> DiagnosticsStatusItem {
        switch authorization {
        case .authorized:
            DiagnosticsStatusItem(subsystem: subsystem, health: .healthy, detail: "Allowed")
        case .notDetermined:
            DiagnosticsStatusItem(
                subsystem: subsystem,
                health: .unavailable,
                detail: "Not requested"
            )
        case .denied:
            DiagnosticsStatusItem(subsystem: subsystem, health: .degraded, detail: "Denied")
        case .restricted:
            DiagnosticsStatusItem(
                subsystem: subsystem,
                health: .degraded,
                detail: "Restricted"
            )
        }
    }
}

nonisolated struct DiagnosticsSupportSummary: Codable, Equatable, Sendable {
    struct Application: Codable, Equatable, Sendable {
        let version: String
        let build: String
        let releaseTrack: String
    }

    struct System: Codable, Equatable, Sendable {
        let macOSVersion: String
        let architecture: String
        let chip: String?
        let memoryBytes: UInt64
        let storageBytes: UInt64?
    }

    struct Feature: Codable, Equatable, Sendable {
        let subsystem: DiagnosticsSubsystem
        let health: DiagnosticsHealth
    }

    struct DiagnosticModes: Codable, Equatable, Sendable {
        let capturesDetailedSanitizedPayloads: Bool
        let savesSanitizedDiagnosticsToDisk: Bool
        let retainedEntryCount: Int
    }

    static let format = "dev.sakuracord.support-summary"
    static let version = 2
    static let currentSystemSnapshot = currentSystem()

    let format: String
    let formatVersion: Int
    let application: Application
    let system: System
    let features: [Feature]
    let diagnosticModes: DiagnosticModes

    init(
        application: Application,
        system: System,
        statusItems: [DiagnosticsStatusItem],
        diagnosticModes: DiagnosticModes
    ) {
        format = Self.format
        formatVersion = Self.version
        self.application = application
        self.system = system
        features = statusItems.map {
            Feature(subsystem: $0.subsystem, health: $0.health)
        }
        self.diagnosticModes = diagnosticModes
    }

    func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    func encodedText() throws -> String {
        guard let text = String(data: try encodedData(), encoding: .utf8) else {
            throw DiagnosticsSupportSummaryError.encodingFailed
        }
        return text
    }

    static func currentApplication(
        bundle: Bundle = .main,
        releaseTrack: AppUpdateReleaseTrack
    ) -> Application {
        Application(
            version: AboutVersionInformation(bundle: bundle).semanticVersionDisplay,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion")
                as? String ?? "Unknown",
            releaseTrack: releaseTrack.rawValue
        )
    }

    static func currentSystem(
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo
            .operatingSystemVersion
    ) -> System {
        System(
            macOSVersion: "\(operatingSystemVersion.majorVersion)."
                + "\(operatingSystemVersion.minorVersion)."
                + "\(operatingSystemVersion.patchVersion)",
            architecture: currentArchitecture,
            chip: currentChip,
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            storageBytes: currentStorageCapacity
        )
    }

    private static var currentChip: String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0,
              size > 0
        else { return nil }

        var value = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &value, &size, nil, 0) == 0 else {
            return nil
        }
        return String(bytes: value.prefix { $0 != 0 }, encoding: .utf8)
    }

    private static var currentStorageCapacity: UInt64? {
        guard let capacity = try? URL.homeDirectory.resourceValues(
            forKeys: [.volumeTotalCapacityKey]
        ).volumeTotalCapacity,
        capacity > 0
        else { return nil }
        return UInt64(capacity)
    }

    private static var currentArchitecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }
}

nonisolated enum DiagnosticsSupportSummaryError: Error {
    case encodingFailed
}

nonisolated enum DiagnosticsManagedFolder {
    static func exists(
        at url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

@MainActor
enum DiagnosticsSupportSummaryExporter {
    static func export(_ summary: DiagnosticsSupportSummary) async throws -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Support Summary"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "SakuraCord Support Summary.json"
        let response = await DiscordAPILogExporter.present(
            panel,
            attachedTo: NSApp.keyWindow ?? NSApp.mainWindow
        )
        guard response == .OK, let url = panel.url else { return nil }
        try await write(summary, to: url)
        return url
    }

    static func write(
        _ summary: DiagnosticsSupportSummary,
        to url: URL,
        stagingRootURL: URL? = nil
    ) async throws {
        try await ExactDestinationFileWriter.write(
            try summary.encodedData(),
            to: url,
            stagingRootURL: stagingRootURL,
            posixPermissions: 0o600
        )
    }
}
