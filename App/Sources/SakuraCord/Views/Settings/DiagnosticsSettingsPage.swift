import DiscordProtocol
import SwiftUI

struct DiagnosticsSettingsPage: View {
    let state: SettingsViewState

    var body: some View {
        SettingsPageForm(page: .diagnostics, state: state) {
            DiagnosticsAPILogsSection(state: state)
        }
    }
}

private struct DiagnosticsAPILogsSection: View {
    let state: SettingsViewState

    @AppStorage("saveAPIDiagnosticsToDisk") private var savesAPIDiagnosticsToDisk = false
    @State private var apiDiagnosticEntryCount = 0
    @State private var apiDiagnosticStatus: String?
    @State private var capturesDetailedAPIPayloads =
        DiscordAPIDiagnosticStore.shared.capturesPayloadDetails

    var body: some View {
        Section {
                Toggle(
                    "Capture detailed sanitized payloads",
                    isOn: $capturesDetailedAPIPayloads
                )
                .onChange(of: capturesDetailedAPIPayloads) { _, captures in
                    DiscordAPIDiagnosticStore.shared.capturesPayloadDetails = captures
                }
                .settingsControlAnchor(.diagnosticDetailedPayloads, state: state)

                Toggle(
                    "Save diagnostics to disk",
                    isOn: $savesAPIDiagnosticsToDisk
                )
                .onChange(of: savesAPIDiagnosticsToDisk) { _, savesToDisk in
                    updateDiskLogging(savesToDisk)
                }
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
                }

                if let apiDiagnosticStatus {
                    Text(apiDiagnosticStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
        } header: {
            Text("Discord API logs", bundle: #bundle)
        } footer: {
            SettingsScopeFooter(scope: .appWideLocal)
        }
        .task { refreshAPIDiagnosticCount() }
    }

    private func refreshAPIDiagnosticCount() {
        apiDiagnosticEntryCount = DiscordAPIDiagnosticStore.shared.retainedEntryCount
    }

    private func clearAPILogs() {
        let store = DiscordAPIDiagnosticStore.shared
        let wasSavingToDisk = store.savesDiagnosticsToDisk
        do {
            try store.clearMemoryAndDisk()
            apiDiagnosticEntryCount = 0
            if wasSavingToDisk, let fileURL = store.currentDiskLogURL {
                apiDiagnosticStatus =
                    "Retained and saved API logs were cleared. Saving continues to \(fileURL.lastPathComponent)."
            } else {
                apiDiagnosticStatus = "Retained and saved API logs were cleared."
            }
        } catch {
            savesAPIDiagnosticsToDisk = store.savesDiagnosticsToDisk
            apiDiagnosticStatus =
                "Could not clear every saved API log: \(error.localizedDescription)"
        }
    }

    private func updateDiskLogging(_ savesToDisk: Bool) {
        do {
            try DiscordAPIDiagnosticStore.shared.setSavesDiagnosticsToDisk(savesToDisk)
            if savesToDisk,
               let fileURL = DiscordAPIDiagnosticStore.shared.currentDiskLogURL
            {
                apiDiagnosticStatus = "Saving diagnostics to \(fileURL.lastPathComponent)"
            } else {
                apiDiagnosticStatus = "Diagnostics are no longer being saved to disk."
            }
        } catch {
            savesAPIDiagnosticsToDisk = false
            apiDiagnosticStatus =
                "Could not save diagnostics to disk: \(error.localizedDescription)"
        }
    }

    private func exportAPILogs() async {
        do {
            guard let url = try await DiscordAPILogExporter.export() else {
                apiDiagnosticStatus = "Export cancelled."
                refreshAPIDiagnosticCount()
                return
            }
            apiDiagnosticStatus = "Exported \(url.lastPathComponent)"
        } catch {
            apiDiagnosticStatus = "Export failed: \(error.localizedDescription)"
        }
        refreshAPIDiagnosticCount()
    }
}
