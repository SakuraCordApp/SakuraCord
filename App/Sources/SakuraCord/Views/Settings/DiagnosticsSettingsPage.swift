import AppKit
import DiscordProtocol
import MediaPipeline
import SwiftUI
import UserNotifications

struct DiagnosticsSettingsPage: View {
    let model: AppModel
    @ObservedObject var updateController: AppUpdateController
    let state: SettingsViewState

    @AppStorage("saveAPIDiagnosticsToDisk") private var savesAPIDiagnosticsToDisk = false
    @State private var capturesDetailedAPIPayloads =
        DiscordAPIDiagnosticStore.shared.capturesPayloadDetails
    @State private var apiDiagnosticEntryCount = 0
    @State private var apiDiagnosticStatus: String?
    @State private var notificationAuthorization: UNAuthorizationStatus?
    @State private var mediaPermissions = VoiceMediaPermissionSnapshot.current()
    @State private var mediaDevices = MediaDeviceSnapshot.empty
    @State private var mediaCacheCheck = DiagnosticsMediaCacheCheck.checking
    @State private var isRefreshing = false
    @State private var lastRefreshedAt: Date?
    @State private var managedDiagnosticsFolderExists = false
    @State private var supportSummaryStatus: String?

    var body: some View {
        SettingsPageForm(page: .diagnostics, state: state) {
            statusSection
            supportSummarySection
            apiLogsSection
        }
        .task { await refresh() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await refresh() }
        }
        .onChange(of: capturesDetailedAPIPayloads) { _, captures in
            DiscordAPIDiagnosticStore.shared.capturesPayloadDetails = captures
        }
        .onChange(of: savesAPIDiagnosticsToDisk) { _, savesToDisk in
            updateDiskLogging(savesToDisk)
        }
    }

    private var statusItems: [DiagnosticsStatusItem] {
        DiagnosticsStatusBuilder.make(
            model: model,
            updateController: updateController,
            notificationPermissionStatus: notificationAuthorization,
            mediaPermissions: mediaPermissions,
            mediaDevices: mediaDevices,
            mediaCacheCheck: mediaCacheCheck,
            systemChecksAreRunning: isRefreshing
        )
    }

    private var supportSummary: DiagnosticsSupportSummary {
        DiagnosticsSupportSummary(
            application: DiagnosticsSupportSummary.currentApplication(
                releaseTrack: updateController.releaseTrack
            ),
            system: DiagnosticsSupportSummary.currentSystem(),
            statusItems: statusItems,
            diagnosticModes: .init(
                capturesDetailedSanitizedPayloads: capturesDetailedAPIPayloads,
                savesSanitizedDiagnosticsToDisk: DiscordAPIDiagnosticStore.shared
                    .savesDiagnosticsToDisk,
                retainedEntryCount: apiDiagnosticEntryCount
            )
        )
    }

    private var statusSection: some View {
        Section {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 210), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(statusItems) { item in
                    DiagnosticsStatusCard(item: item)
                }
            }
            .textSelection(.enabled)
            .settingsControlAnchor(.diagnosticsStatusOverview, state: state)

            HStack {
                Button("Refresh Status") { Task { await refresh() } }
                    .disabled(isRefreshing)
                    .settingsControlAnchor(.diagnosticsRefresh, state: state)
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Text(lastRefreshedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Status", bundle: #bundle)
        } footer: {
            Text(
                "Connection status updates with the active session. macOS permissions, devices, "
                    + "notification authorization, and cache state refresh when this page opens, "
                    + "when SakuraCord becomes active, or when you choose Refresh Status."
            )
        }
    }

    private var supportSummarySection: some View {
        Section {
            DiagnosticsSupportSummaryPreview(summary: supportSummary)
                .settingsControlAnchor(.diagnosticsSupportPreview, state: state)

            HStack {
                Button("Copy Support Summary") { copySupportSummary() }
                    .settingsControlAnchor(.diagnosticsSupportCopy, state: state)
                Button("Export Support Summary…") {
                    Task { await exportSupportSummary() }
                }
                .settingsControlAnchor(.diagnosticsSupportExport, state: state)
            }

            if let supportSummaryStatus {
                Text(supportSummaryStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Support Summary", bundle: #bundle)
        } footer: {
            Text(
                "The summary contains only SakuraCord version/build/track, macOS version, "
                    + "architecture, fixed feature-health states, permission states, and diagnostic "
                    + "modes. It never includes credentials, content, names, filenames, URLs, IDs, "
                    + "nonces, request IDs, bucket IDs, challenge data, or arbitrary preferences."
            )
        }
    }

    private var apiLogsSection: some View {
        Section {
            Toggle(
                "Capture detailed sanitized payloads",
                isOn: $capturesDetailedAPIPayloads
            )
            .settingsControlAnchor(.diagnosticDetailedPayloads, state: state)

            Toggle(
                "Save diagnostics to disk",
                isOn: $savesAPIDiagnosticsToDisk
            )
            .settingsControlAnchor(.diagnosticDiskCapture, state: state)

            LabeledContent("Retained entries") {
                Text(apiDiagnosticEntryCount.formatted())
                    .monospacedDigit()
            }
            .settingsControlAnchor(.diagnosticRetainedEntries, state: state)

            Text(
                "Exports retained Discord REST, attachment, authentication, and Gateway request/response metadata from this app session. "
                    + "Detailed sanitized payload capture is off by default because processing large responses increases CPU and energy use. "
                    + "Message text, names, usernames, profile text, credentials, cookies, challenge data, filenames, and URLs are discarded before logging. "
                    + "IDs, nonces, request IDs, and rate-limit bucket IDs are always redacted. "
                    + "Disk capture is off by default and keeps at most four private JSON Lines session files of up to 64 MiB each in Application Support/SakuraCord/Diagnostics."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button("Export API Logs…") {
                    Task { await exportAPILogs() }
                }
                .settingsControlAnchor(.diagnosticExport, state: state)

                Button("Clear Logs", role: .destructive) {
                    clearAPILogs()
                }
                .settingsControlAnchor(.diagnosticClear, state: state)

                if managedDiagnosticsFolderExists {
                    Button("Open Diagnostics Folder") {
                        openDiagnosticsFolder()
                    }
                    .settingsControlAnchor(.diagnosticsOpenFolder, state: state)
                }
            }

            if let apiDiagnosticStatus {
                Text(apiDiagnosticStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Discord API Logs", bundle: #bundle)
        } footer: {
            SettingsScopeFooter(scope: .appWideLocal)
        }
    }

    private var lastRefreshedDescription: String {
        if isRefreshing { return "Checking…" }
        return lastRefreshedAt.map {
            "Refreshed \($0.formatted(date: .omitted, time: .shortened))"
        } ?? "Not checked"
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        notificationAuthorization = nil
        mediaCacheCheck = .checking
        defer { isRefreshing = false }

        async let authorization = model.notificationAuthorizationStatus()
        async let devices = Task.detached(priority: .userInitiated) {
            MediaDeviceCatalog.snapshot()
        }.value
        let cacheTask = Task {
            try await SharedMediaDataLoader.shared.diskCacheStatus()
        }
        let permissions = VoiceMediaPermissionSnapshot.current()

        notificationAuthorization = await authorization
        mediaDevices = await devices
        do {
            if let status = try await cacheTask.value {
                mediaCacheCheck = .available(status)
            } else {
                mediaCacheCheck = .unavailable
            }
        } catch {
            mediaCacheCheck = .failed
        }
        mediaPermissions = permissions
        refreshAPIDiagnosticState()
        lastRefreshedAt = Date()
    }

    private func refreshAPIDiagnosticState() {
        let store = DiscordAPIDiagnosticStore.shared
        apiDiagnosticEntryCount = store.retainedEntryCount
        capturesDetailedAPIPayloads = store.capturesPayloadDetails
        if savesAPIDiagnosticsToDisk != store.savesDiagnosticsToDisk {
            savesAPIDiagnosticsToDisk = store.savesDiagnosticsToDisk
        }
        managedDiagnosticsFolderExists = DiagnosticsManagedFolder.exists(
            at: store.diskDirectoryURL
        )
    }

    private func clearAPILogs() {
        let store = DiscordAPIDiagnosticStore.shared
        let wasSavingToDisk = store.savesDiagnosticsToDisk
        do {
            try store.clearMemoryAndDisk()
            apiDiagnosticEntryCount = 0
            if wasSavingToDisk, store.savesDiagnosticsToDisk {
                apiDiagnosticStatus =
                    "Retained and saved API logs were cleared. Private disk capture continues."
            } else {
                apiDiagnosticStatus = "Retained and saved API logs were cleared."
            }
        } catch {
            savesAPIDiagnosticsToDisk = store.savesDiagnosticsToDisk
            apiDiagnosticStatus = "Could not clear every managed API log."
        }
        refreshAPIDiagnosticState()
    }

    private func updateDiskLogging(_ savesToDisk: Bool) {
        let store = DiscordAPIDiagnosticStore.shared
        guard savesToDisk != store.savesDiagnosticsToDisk else {
            refreshAPIDiagnosticState()
            return
        }
        do {
            try store.setSavesDiagnosticsToDisk(savesToDisk)
            apiDiagnosticStatus = savesToDisk
                ? "Saving sanitized diagnostics to the managed private folder."
                : "Diagnostics are no longer being saved to disk."
        } catch {
            savesAPIDiagnosticsToDisk = store.savesDiagnosticsToDisk
            apiDiagnosticStatus = "Could not change managed diagnostic disk capture."
        }
        refreshAPIDiagnosticState()
    }

    private func exportAPILogs() async {
        do {
            guard try await DiscordAPILogExporter.export() != nil else {
                apiDiagnosticStatus = "Export cancelled."
                refreshAPIDiagnosticState()
                return
            }
            apiDiagnosticStatus = "Exported private sanitized API logs."
        } catch {
            apiDiagnosticStatus = "API log export failed."
        }
        refreshAPIDiagnosticState()
    }

    private func openDiagnosticsFolder() {
        let url = DiscordAPIDiagnosticStore.shared.diskDirectoryURL
        guard DiagnosticsManagedFolder.exists(at: url) else {
            managedDiagnosticsFolderExists = false
            apiDiagnosticStatus = "The managed diagnostics folder is unavailable."
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
            Task { @MainActor in
                apiDiagnosticStatus = error == nil
                    ? "Opened the managed diagnostics folder."
                    : "The managed diagnostics folder could not be opened."
            }
        }
    }

    private func copySupportSummary() {
        do {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(
                try supportSummary.encodedText(),
                forType: .string
            ) else {
                supportSummaryStatus = "The support summary could not be copied."
                return
            }
            supportSummaryStatus = "Copied the sanitized support summary."
        } catch {
            supportSummaryStatus = "The support summary could not be copied."
        }
    }

    private func exportSupportSummary() async {
        do {
            guard try await DiagnosticsSupportSummaryExporter.export(supportSummary) != nil else {
                supportSummaryStatus = "Export cancelled."
                return
            }
            supportSummaryStatus = "Exported the private sanitized support summary."
        } catch {
            supportSummaryStatus = "The support summary could not be exported."
        }
    }
}

private struct DiagnosticsStatusCard: View {
    let item: DiagnosticsStatusItem

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: item.health.systemImage)
                .foregroundStyle(healthColor)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.subsystem.title)
                    .font(.callout.weight(.medium))
                Text(item.health.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(healthColor)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(item.subsystem.title), \(item.health.title), \(item.detail)"
        )
    }

    private var healthColor: Color {
        switch item.health {
        case .unavailable: .secondary
        case .checking: .blue
        case .healthy: .green
        case .degraded: .orange
        case .failed: .red
        }
    }
}

private struct DiagnosticsSupportSummaryPreview: View {
    let summary: DiagnosticsSupportSummary

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
            GridRow {
                Text("SakuraCord")
                    .foregroundStyle(.secondary)
                Text("\(summary.application.version) (\(summary.application.build))")
            }
            GridRow {
                Text("Release track")
                    .foregroundStyle(.secondary)
                Text(summary.application.releaseTrack.capitalized)
            }
            GridRow {
                Text("System")
                    .foregroundStyle(.secondary)
                Text("macOS \(summary.system.macOSVersion), \(summary.system.architecture)")
            }
            GridRow {
                Text("Feature health")
                    .foregroundStyle(.secondary)
                Text(featureHealthDescription)
            }
            GridRow {
                Text("Diagnostic modes")
                    .foregroundStyle(.secondary)
                Text(diagnosticModeDescription)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }

    private var featureHealthDescription: String {
        let counts = Dictionary(grouping: summary.features, by: \.health)
            .mapValues(\.count)
        return "\(counts[.healthy, default: 0]) healthy, "
            + "\(counts[.checking, default: 0]) checking, "
            + "\(counts[.degraded, default: 0]) degraded, "
            + "\(counts[.failed, default: 0]) failed, "
            + "\(counts[.unavailable, default: 0]) unavailable"
    }

    private var diagnosticModeDescription: String {
        let details = summary.diagnosticModes.capturesDetailedSanitizedPayloads
            ? "detailed sanitized payloads on" : "detailed sanitized payloads off"
        let disk = summary.diagnosticModes.savesSanitizedDiagnosticsToDisk
            ? "private disk capture on" : "private disk capture off"
        return "\(details), \(disk), "
            + "\(summary.diagnosticModes.retainedEntryCount) retained entries"
    }
}
