import AppKit
import DiscordProtocol
import MediaPipeline
import SwiftUI
import UserNotifications

struct DiagnosticsSettingsPage: View {
    let model: AppModel
    @ObservedObject var updateController: AppUpdateController
    let state: SettingsViewState

    @AppStorage(DiagnosticsPreferences.capturesDetailedPayloadsKey)
    private var capturesDetailedAPIPayloads = false
    @AppStorage(DiagnosticsPreferences.savesDiagnosticsToDiskKey)
    private var savesAPIDiagnosticsToDisk = false
    @State private var apiDiagnosticEntryCount = 0
    @State private var notificationAuthorization: UNAuthorizationStatus?
    @State private var mediaPermissions = VoiceMediaPermissionSnapshot.current()
    @State private var mediaCacheCheck = DiagnosticsMediaCacheCheck.checking
    @State private var isRefreshing = false
    @State private var lastRefreshedAt: Date?
    @State private var managedDiagnosticsFolderExists = false

    var body: some View {
        SettingsPageForm(page: .diagnostics, state: state) {
            statusSection
            supportSummarySection
            apiLogsSection
        }
        .task { await refresh() }
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
            mediaCacheCheck: mediaCacheCheck
        )
    }

    private var supportSummary: DiagnosticsSupportSummary {
        DiagnosticsSupportSummary(
            application: DiagnosticsSupportSummary.currentApplication(
                releaseTrack: updateController.releaseTrack
            ),
            system: DiagnosticsSupportSummary.currentSystemSnapshot,
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
            .tint(SakuraCordAccentColor.color)
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
        } header: {
            Text("Support Summary", bundle: #bundle)
        }
    }

    private var apiLogsSection: some View {
        Section {
            Toggle(
                "Capture detailed sanitized payloads",
                isOn: $capturesDetailedAPIPayloads
            )
            .tint(SakuraCordAccentColor.color)
            .settingsControlAnchor(.diagnosticDetailedPayloads, state: state)

            Toggle(
                "Save diagnostics to disk",
                isOn: $savesAPIDiagnosticsToDisk
            )
            .tint(SakuraCordAccentColor.color)
            .settingsControlAnchor(.diagnosticDiskCapture, state: state)

            LabeledContent("Retained entries") {
                Text(apiDiagnosticEntryCount.formatted())
                    .monospacedDigit()
            }
            .settingsControlAnchor(.diagnosticRetainedEntries, state: state)

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
                    Button("Open Diagnostics Folder…") {
                        openDiagnosticsFolder()
                    }
                    .settingsControlAnchor(.diagnosticsOpenFolder, state: state)
                }
            }

        } header: {
            Text("Discord API Logs", bundle: #bundle)
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
        let cacheTask = Task {
            try await SharedMediaDataLoader.shared.diskCacheStatus()
        }
        let permissions = VoiceMediaPermissionSnapshot.current()

        notificationAuthorization = await authorization
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
        do {
            try store.clearMemoryAndDisk()
            apiDiagnosticEntryCount = 0
        } catch {
            savesAPIDiagnosticsToDisk = store.savesDiagnosticsToDisk
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
        } catch {
            savesAPIDiagnosticsToDisk = store.savesDiagnosticsToDisk
        }
        refreshAPIDiagnosticState()
    }

    private func exportAPILogs() async {
        _ = try? await DiscordAPILogExporter.export()
        refreshAPIDiagnosticState()
    }

    private func openDiagnosticsFolder() {
        let url = DiscordAPIDiagnosticStore.shared.diskDirectoryURL
        guard DiagnosticsManagedFolder.exists(at: url) else {
            managedDiagnosticsFolderExists = false
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(url, configuration: configuration, completionHandler: nil)
    }

    private func copySupportSummary() {
        guard let text = try? supportSummary.encodedText() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func exportSupportSummary() async {
        _ = try? await DiagnosticsSupportSummaryExporter.export(supportSummary)
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
                Text(summary.application.version)
            }
            GridRow {
                Text("Release track")
                    .foregroundStyle(.secondary)
                Text(summary.application.releaseTrack.capitalized)
            }
            GridRow {
                Text("System")
                    .foregroundStyle(.secondary)
                Text("macOS \(summary.system.macOSVersion)")
            }
            GridRow {
                Text("Mac")
                    .foregroundStyle(.secondary)
                Text(hardwareDescription)
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
        .tint(SakuraCordAccentColor.color)
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

    private var hardwareDescription: String {
        var components = [String]()
        if let chip = summary.system.chip {
            components.append(chip)
        }
        components.append(
            "\(Int64(clamping: summary.system.memoryBytes).formatted(.byteCount(style: .memory))) memory"
        )
        if let storageBytes = summary.system.storageBytes {
            components.append(
                "\(Int64(clamping: storageBytes).formatted(.byteCount(style: .file))) storage"
            )
        }
        return components.joined(separator: ", ")
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
