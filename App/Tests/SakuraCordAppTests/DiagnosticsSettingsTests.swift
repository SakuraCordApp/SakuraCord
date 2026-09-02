@testable import SakuraCord
import DiscordProtocol
import Foundation
import MediaPipeline
import SakuraCordModels
import Testing
import UserNotifications

@MainActor
@Test func `Diagnostics capture preferences restore both modes across launches`() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "SakuraCordDiagnosticsPreferenceTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = InMemoryPreferences()
    let settings = SettingsPreferenceStore(defaults: defaults)
    settings.set(.bool(true), for: .diagnosticDetailedPayloads)
    settings.set(.bool(true), for: .diagnosticDiskCapture)
    let store = DiscordAPIDiagnosticStore(diskDirectoryURL: directory)

    DiagnosticsPreferences.restore(defaults: defaults, store: store)

    #expect(store.capturesPayloadDetails)
    #expect(store.savesDiagnosticsToDisk)
    #expect(settings.value(for: .diagnosticDetailedPayloads) == .bool(true))
    #expect(settings.value(for: .diagnosticDiskCapture) == .bool(true))

    settings.set(.bool(false), for: .diagnosticDetailedPayloads)
    settings.set(.bool(false), for: .diagnosticDiskCapture)
    DiagnosticsPreferences.restore(defaults: defaults, store: store)

    #expect(!store.capturesPayloadDetails)
    #expect(!store.savesDiagnosticsToDisk)
}

@MainActor
@Test func `Diagnostics status follows account reset without retaining identity`() {
    let preferences = InMemoryPreferences()
    let model = AppModel(
        launchMode: .offlineTesting,
        notificationPreferences: NotificationPreferences(defaults: preferences),
        voiceVideoPreferences: VoiceVideoPreferences(defaults: preferences)
    )
    model.activeAccountID = "111111111111111111"
    model.sessionState = .workspace
    model.connectionState = .ready
    model.voiceSessionState = .connected
    model.voiceLatencyMilliseconds = 42
    let updateController = AppUpdateController(
        configuration: AppUpdateConfiguration(
            infoDictionary: [:],
            bundleIdentifier: nil
        ),
        defaults: preferences
    )
    let permissions = VoiceMediaPermissionSnapshot(
        microphone: .authorized,
        camera: .authorized,
        screenRecordingAllowed: true
    )

    let active = DiagnosticsStatusBuilder.make(
        model: model,
        updateController: updateController,
        notificationPermissionStatus: .authorized,
        mediaPermissions: permissions,
        mediaCacheCheck: .available(.init(
            currentBytes: 0,
            maximumBytes: 1,
            evictionStatus: .withinLimit
        ))
    )
    #expect(active.map(\.subsystem) == [
        .account,
        .gateway,
        .voice,
        .notifications,
        .mediaCache,
        .updateService,
        .voiceLatency,
        .microphonePermission,
        .cameraPermission,
    ])
    #expect(active.first { $0.subsystem == .account }?.health == .healthy)
    #expect(active.first { $0.subsystem == .gateway }?.health == .healthy)
    #expect(active.first { $0.subsystem == .voice }?.health == .healthy)
    #expect(active.first { $0.subsystem == .voiceLatency }?.detail == "42 ms")

    model.voiceSessionState = .idle
    model.voiceLatencyMilliseconds = nil
    model.notificationPreferences.isEnabled = false
    let resting = DiagnosticsStatusBuilder.make(
        model: model,
        updateController: updateController,
        notificationPermissionStatus: .authorized,
        mediaPermissions: permissions,
        mediaCacheCheck: .available(.init(
            currentBytes: 0,
            maximumBytes: 1,
            evictionStatus: .withinLimit
        ))
    )
    #expect(resting.first { $0.subsystem == .voice }?.health == .healthy)
    #expect(resting.first { $0.subsystem == .voiceLatency }?.health == .healthy)
    #expect(resting.first { $0.subsystem == .notifications }?.health == .healthy)

    model.activeAccountID = nil
    model.sessionState = .signedOut
    model.connectionState = .disconnected
    model.voiceSessionState = .idle
    let reset = DiagnosticsStatusBuilder.make(
        model: model,
        updateController: updateController,
        notificationPermissionStatus: .authorized,
        mediaPermissions: permissions,
        mediaCacheCheck: .unavailable
    )

    #expect(reset.first { $0.subsystem == .account }?.health == .unavailable)
    #expect(reset.first { $0.subsystem == .gateway }?.health == .unavailable)
    #expect(reset.first { $0.subsystem == .voice }?.health == .unavailable)
    #expect(!reset.map(\.detail).joined().contains("111111111111111111"))
}

@MainActor
@Test func `Support summary excludes identity device and arbitrary error fields`() throws {
    let preferences = InMemoryPreferences()
    let model = AppModel(
        launchMode: .offlineTesting,
        notificationPreferences: NotificationPreferences(defaults: preferences),
        voiceVideoPreferences: VoiceVideoPreferences(defaults: preferences)
    )
    model.activeAccountID = "222222222222222222"
    model.sessionState = .workspace
    model.connectionState = .ready
    model.voiceSessionState = .failed
    model.errorMessage = "credential-secret cookie-secret https://private.example/message"
    model.voiceErrorMessage = "private-profile.txt request-333333333333333333"
    model.voiceVideoPreferences.inputDeviceUID = "private-input-uid"
    model.voiceVideoPreferences.outputDeviceUID = "private-output-uid"
    model.selectedCameraUID = "private-camera-uid"
    let updateController = AppUpdateController(
        configuration: AppUpdateConfiguration(
            infoDictionary: [:],
            bundleIdentifier: nil
        ),
        defaults: preferences
    )
    let statuses = DiagnosticsStatusBuilder.make(
        model: model,
        updateController: updateController,
        notificationPermissionStatus: .denied,
        mediaPermissions: .init(
            microphone: .denied,
            camera: .restricted,
            screenRecordingAllowed: false
        ),
        mediaCacheCheck: .available(.init(
            currentBytes: 2,
            maximumBytes: 1,
            evictionStatus: .incomplete(failedFileCount: 1)
        ))
    )
    let summary = DiagnosticsSupportSummary(
        application: .init(version: "0.1.5", build: "42", releaseTrack: "nightly"),
        system: .init(
            macOSVersion: "27.0.0",
            architecture: "arm64",
            chip: "Apple M2 Pro",
            memoryBytes: 17_179_869_184,
            storageBytes: 1_000_000_000_000
        ),
        statusItems: statuses,
        diagnosticModes: .init(
            capturesDetailedSanitizedPayloads: true,
            savesSanitizedDiagnosticsToDisk: true,
            retainedEntryCount: 7
        )
    )
    let text = try summary.encodedText()

    #expect(text.contains(DiagnosticsSupportSummary.format))
    #expect(text.contains("Apple M2 Pro"))
    #expect(text.contains("17179869184"))
    #expect(text.contains("1000000000000"))
    #expect(text.contains("mediaCache"))
    for prohibited in [
        "222222222222222222", "333333333333333333",
        "credential-secret", "cookie-secret", "private.example",
        "private-profile.txt", "private-input-uid", "private-output-uid",
        "private-camera-uid", "Owner Microphone", "Owner Speaker", "Owner Camera",
    ] {
        #expect(!text.contains(prohibited))
    }
}

@Test func `Support summary export is private and matches the sanitized schema`() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sakuracord-support-summary-\(UUID().uuidString)",
        isDirectory: true
    )
    let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
    let destination = directory.appendingPathComponent("support.json")
    try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let summary = DiagnosticsSupportSummary(
        application: .init(version: "0.1.5", build: "42", releaseTrack: "regular"),
        system: .init(
            macOSVersion: "27.0.0",
            architecture: "arm64",
            chip: "Apple M2 Pro",
            memoryBytes: 17_179_869_184,
            storageBytes: 1_000_000_000_000
        ),
        statusItems: [
            DiagnosticsStatusItem(
                subsystem: .gateway,
                health: .healthy,
                detail: "free-form-detail-must-not-export"
            ),
        ],
        diagnosticModes: .init(
            capturesDetailedSanitizedPayloads: false,
            savesSanitizedDiagnosticsToDisk: false,
            retainedEntryCount: 0
        )
    )

    try await DiagnosticsSupportSummaryExporter.write(
        summary,
        to: destination,
        stagingRootURL: stagingRoot
    )

    let data = try Data(contentsOf: destination)
    let expected = try summary.encodedData()
    #expect(data == expected)
    #expect(!String(decoding: data, as: UTF8.self).contains("free-form-detail"))
    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func `Open diagnostics folder availability requires an existing directory`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sakuracord-managed-diagnostics-\(UUID().uuidString)",
        isDirectory: true
    )
    let file = root.appendingPathComponent("not-a-directory")
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(!DiagnosticsManagedFolder.exists(at: root))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    #expect(DiagnosticsManagedFolder.exists(at: root))
    try Data().write(to: file)
    #expect(!DiagnosticsManagedFolder.exists(at: file))
}

@MainActor
@Test func `Diagnostics catalog exposes status support and preserved API controls`() {
    let expected: Set<SettingsControlID> = [
        .diagnosticsStatusOverview, .diagnosticsRefresh,
        .diagnosticsSupportPreview, .diagnosticsSupportCopy,
        .diagnosticsSupportExport, .diagnosticsOpenFolder,
        .diagnosticDetailedPayloads, .diagnosticDiskCapture,
        .diagnosticRetainedEntries, .diagnosticExport, .diagnosticClear,
    ]
    let controls = SettingsCatalog.foundation.controls.filter {
        $0.destination.page == .diagnostics
    }
    #expect(Set(controls.map(\.id)) == expected)

    let state = SettingsViewState()
    state.searchText = "chip storage"
    #expect(state.searchResults.contains { $0.id == .diagnosticsSupportPreview })
    state.searchText = "Gateway permissions"
    #expect(state.searchResults.contains { $0.id == .diagnosticsStatusOverview })
}
