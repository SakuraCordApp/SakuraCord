import AppKit
import DiscordProtocol
import MediaPipeline
import SakuraCordPersistence
import SwiftUI
import UniformTypeIdentifiers

struct StorageDownloadsSettingsPage: View {
    private enum Confirmation: String, Identifiable {
        case mediaCache
        case incompleteDownloads
        case selectedDrafts
        case allDrafts
        case reset

        var id: String { rawValue }
    }

    let model: AppModel
    let state: SettingsViewState

    @State private var value = StorageDownloadsSettingsSnapshot.defaults
    @State private var cacheStatus: MediaCache.Status?
    @State private var incompleteDownloads: StorageByteSummary?
    @State private var draftSummary: LocalDraftStorageSummary?
    @State private var diagnosticUsage: StorageByteSummary?
    @State private var confirmation: Confirmation?
    @State private var exportedPreferences: SettingsPreferenceExportFile?
    @State private var isExporting = false
    @State private var isRefreshing = false
    @State private var isClearingCache = false
    @State private var isClearingIncompleteDownloads = false
    @State private var operationMessage: String?
    @State private var cacheClearTask: Task<Void, Never>?
    @State private var incompleteClearTask: Task<Void, Never>?

    var body: some View {
        SettingsPageForm(page: .storageDownloads, state: state) {
            mediaCacheSection
            downloadsSection
            localDataSection
        }
        .task {
            value = StorageDownloadsSettingsStore.shared.load()
            await refreshStorageStatus()
        }
        .onChange(of: value) { oldValue, newValue in
            StorageDownloadsSettingsStore.shared.save(newValue)
            guard oldValue.mediaCacheLimit != newValue.mediaCacheLimit else { return }
            Task { await applyMediaCacheLimit(newValue.mediaCacheLimit) }
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            )
        ) {
            if confirmation != nil {
                Button(confirmationButtonTitle, role: .destructive) {
                    if let confirmation { perform(confirmation) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
        .fileExporter(
            isPresented: $isExporting,
            item: exportedPreferences,
            contentTypes: [.json],
            defaultFilename: "SakuraCord-Storage-Downloads-v1"
        ) { result in
            operationMessage = switch result {
            case .success: "Exported Storage & Downloads preferences."
            case .failure: "The Storage & Downloads preferences could not be exported."
            }
            exportedPreferences = nil
        } onCancellation: {
            exportedPreferences = nil
        }
        .onDisappear {
            cacheClearTask?.cancel()
            incompleteClearTask?.cancel()
        }
    }

    private var mediaCacheSection: some View {
        Section {
            Picker("Maximum size", selection: $value.mediaCacheLimit) {
                ForEach(MediaCacheLimit.allCases) { limit in
                    Text(limit.title).tag(limit)
                }
            }
            .settingsControlAnchor(.mediaCacheLimit, state: state)

            LabeledContent("Current usage") {
                Text(cacheStatus.map { formatBytes($0.currentBytes) } ?? "Unavailable")
                    .foregroundStyle(.secondary)
            }
            .settingsControlAnchor(.mediaCacheUsage, state: state)

            LabeledContent("Configured limit") {
                Text(cacheStatus.map { formatBytes($0.maximumBytes) } ?? value.mediaCacheLimit.title)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Eviction") {
                Text(cacheEvictionDescription)
                    .foregroundStyle(cacheEvictionIsIncomplete ? .red : .secondary)
            }

            if cacheEvictionIsIncomplete {
                Button("Retry Eviction") {
                    Task { await applyMediaCacheLimit(value.mediaCacheLimit) }
                }
            }

            LabeledContent("Last cleared") {
                Text(lastCacheClearDescription)
                    .foregroundStyle(.secondary)
            }

            if isClearingCache {
                HStack {
                    ProgressView("Clearing disposable media…")
                    Spacer()
                    Button("Cancel") { cacheClearTask?.cancel() }
                }
            } else {
                Button("Clear Media Cache…", role: .destructive) {
                    confirmation = .mediaCache
                }
                .settingsControlAnchor(.mediaCacheClear, state: state)
            }
        } header: {
            Text("Media Cache", bundle: #bundle)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "The limit applies to SakuraCord's least-recently-used disk cache. "
                        + "Lower limits converge asynchronously. Visible and playing media remain in memory."
                )
                SettingsScopeFooter(scope: .appWideLocal)
            }
        }
    }

    private var downloadsSection: some View {
        Section {
            Picker("Save downloads", selection: $value.downloadLocationMode) {
                ForEach(DownloadLocationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .settingsControlAnchor(.downloadLocationMode, state: state)

            if value.downloadLocationMode == .defaultFolder {
                LabeledContent("Default folder") {
                    Text(StorageDownloadsSettingsStore.shared.defaultFolderName ?? "Not chosen")
                        .foregroundStyle(.secondary)
                }
                .settingsControlAnchor(.downloadFolderName, state: state)

                Button("Choose Folder…") { chooseDownloadFolder() }
            }

            Picker("If a filename exists", selection: $value.filenameCollisionPolicy) {
                ForEach(DownloadFilenameCollisionPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .settingsControlAnchor(.downloadCollisionPolicy, state: state)

            Toggle(
                "Reveal completed downloads in Finder",
                isOn: $value.revealsCompletedDownloads
            )
            .tint(SakuraCordAccentColor.color)
            .settingsControlAnchor(.revealCompletedDownloads, state: state)

            LabeledContent("Stale incomplete downloads") {
                Text(incompleteDownloads.map(summaryDescription) ?? "Unavailable")
                    .foregroundStyle(.secondary)
            }
            .settingsControlAnchor(.incompleteDownloadsUsage, state: state)

            if isClearingIncompleteDownloads {
                HStack {
                    ProgressView("Clearing stale temporary downloads…")
                    Spacer()
                    Button("Cancel") { incompleteClearTask?.cancel() }
                }
            } else {
                Button("Clear Incomplete Downloads…", role: .destructive) {
                    confirmation = .incompleteDownloads
                }
                .disabled((incompleteDownloads?.fileCount ?? 0) == 0)
                .settingsControlAnchor(.incompleteDownloadsClear, state: state)
            }
        } header: {
            Text("Downloads", bundle: #bundle)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "Default folders use a macOS security-scoped bookmark. Cleanup is limited to "
                        + "SakuraCord-owned temporary download folders older than one hour."
                )
                SettingsScopeFooter(scope: .appWideLocal)
            }
        }
    }

    private var localDataSection: some View {
        Section {
            LabeledContent("Selected account drafts") {
                Text(selectedDraftDescription)
                    .foregroundStyle(.secondary)
            }
            .settingsControlAnchor(.selectedAccountDrafts, state: state)

            LabeledContent("All account drafts") {
                Text(allDraftDescription)
                .foregroundStyle(.secondary)
            }
            .settingsControlAnchor(.allAccountDrafts, state: state)

            HStack {
                Button("Clear Selected Account Drafts…", role: .destructive) {
                    confirmation = .selectedDrafts
                }
                .disabled((draftSummary?.selectedAccount?.draftCount ?? 0) == 0)
                .settingsControlAnchor(.clearSelectedAccountDrafts, state: state)

                Button("Clear All Account Drafts…", role: .destructive) {
                    confirmation = .allDrafts
                }
                .disabled((draftSummary?.allAccounts.draftCount ?? 0) == 0)
                .settingsControlAnchor(.clearAllAccountDrafts, state: state)
            }

            LabeledContent("Diagnostic disk usage") {
                Text(diagnosticUsage.map(summaryDescription) ?? "Unavailable")
                    .foregroundStyle(.secondary)
            }
            .settingsControlAnchor(.diagnosticDiskUsage, state: state)

            Button("Manage Diagnostics…") {
                state.navigate(
                    to: SettingsDestination(page: .diagnostics, section: .apiDiagnostics),
                    controlID: .diagnosticDiskCapture
                )
            }
            .settingsControlAnchor(.storageDiagnosticsLink, state: state)

            Text(
                "Discord workspaces, messages, members, read state, and Gateway state are held "
                    + "only for the signed-in session and are not stored in this local database."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button("Refresh") { Task { await refreshStorageStatus() } }
                    .disabled(isRefreshing)
                Button("Export Preferences…") { exportPreferences() }
                    .settingsControlAnchor(.storageExport, state: state)
                Button("Reset Preferences…", role: .destructive) {
                    confirmation = .reset
                }
                .settingsControlAnchor(.storageReset, state: state)
            }

            if isRefreshing {
                ProgressView("Measuring SakuraCord-managed storage…")
            }
            if let operationMessage {
                Text(operationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        } header: {
            Text("Local Data", bundle: #bundle)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "Drafts are account-local. Diagnostic capture and download preferences are "
                        + "app-wide. Resetting preferences does not delete drafts, media, or diagnostics."
                )
                SettingsScopeFooter(scope: .mixed)
            }
        }
    }

    private var cacheEvictionDescription: String {
        guard let cacheStatus else { return "Unavailable" }
        return switch cacheStatus.evictionStatus {
        case .withinLimit: "Within limit"
        case .converging: "Converging to limit"
        case let .incomplete(failedFileCount):
            "Incomplete (\(failedFileCount) file(s) could not be removed)"
        }
    }

    private var cacheEvictionIsIncomplete: Bool {
        guard let cacheStatus else { return false }
        if case .incomplete = cacheStatus.evictionStatus { return true }
        return false
    }

    private var lastCacheClearDescription: String {
        StorageDownloadsSettingsStore.shared.lastMediaCacheClearDate?
            .formatted(date: .abbreviated, time: .shortened) ?? "Never"
    }

    private var selectedDraftDescription: String {
        guard let draftSummary else { return "Unavailable" }
        return draftSummary.selectedAccount.map(draftDescription) ?? "No active account"
    }

    private var allDraftDescription: String {
        guard let draftSummary else { return "Unavailable" }
        return "\(draftDescription(draftSummary.allAccounts)) in "
            + "\(draftSummary.accountCount) account(s)"
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .mediaCache: "Clear Media Cache?"
        case .incompleteDownloads: "Clear Incomplete Downloads?"
        case .selectedDrafts: "Clear Selected Account Drafts?"
        case .allDrafts: "Clear All Account Drafts?"
        case .reset: "Reset Storage & Downloads Preferences?"
        case nil: "Confirm Storage Action"
        }
    }

    private var confirmationButtonTitle: String {
        switch confirmation {
        case .mediaCache: "Clear Media Cache"
        case .incompleteDownloads: "Clear Incomplete Downloads"
        case .selectedDrafts: "Clear Selected Drafts"
        case .allDrafts: "Clear All Drafts"
        case .reset: "Reset Preferences"
        case nil: "Confirm"
        }
    }

    private var confirmationMessage: String {
        switch confirmation {
        case .mediaCache:
            "This removes SakuraCord's disposable disk media. Visible and playing media remain available."
        case .incompleteDownloads:
            "This removes only SakuraCord-owned temporary download folders older than one hour."
        case .selectedDrafts:
            "This permanently removes unsent local drafts for the active account only."
        case .allDrafts:
            "This permanently removes unsent local drafts for every saved account."
        case .reset:
            "This restores registered storage preferences and forgets the default folder. It does not delete local data."
        case nil:
            "No action has been selected."
        }
    }

    private func perform(_ action: Confirmation) {
        confirmation = nil
        switch action {
        case .mediaCache:
            clearMediaCache()
        case .incompleteDownloads:
            clearIncompleteDownloads()
        case .selectedDrafts:
            Task { await clearDraftsForSelectedAccount() }
        case .allDrafts:
            Task { await clearDraftsForAllAccounts() }
        case .reset:
            resetPreferences()
        }
    }

    private func applyMediaCacheLimit(_ limit: MediaCacheLimit) async {
        do {
            try await SharedMediaDataLoader.shared.setDiskCacheLimit(limit.rawValue)
            cacheStatus = try await SharedMediaDataLoader.shared.diskCacheStatus()
            operationMessage = "Applied the media cache limit."
        } catch {
            operationMessage = "The media cache limit could not be applied."
            cacheStatus = nil
        }
    }

    private func refreshStorageStatus() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var measurementFailed = false
        do {
            cacheStatus = try await SharedMediaDataLoader.shared.diskCacheStatus()
        } catch {
            cacheStatus = nil
            measurementFailed = true
        }
        do {
            incompleteDownloads = try await SakuraCordStorageInspector
                .incompleteDownloadSummary()
        } catch {
            incompleteDownloads = nil
            measurementFailed = true
        }
        do {
            draftSummary = try await model.localDraftStorageSummary()
        } catch {
            draftSummary = nil
            measurementFailed = true
        }
        do {
            diagnosticUsage = try await SakuraCordStorageInspector.directorySummary(
                DiscordAPIDiagnosticStore.shared.diskDirectoryURL
            )
        } catch {
            diagnosticUsage = nil
            measurementFailed = true
        }
        if measurementFailed {
            operationMessage = "Some SakuraCord-managed storage could not be measured."
        }
    }

    private func clearMediaCache() {
        cacheClearTask?.cancel()
        isClearingCache = true
        cacheClearTask = Task {
            defer {
                isClearingCache = false
                cacheClearTask = nil
            }
            do {
                try await SharedMediaDataLoader.shared.clearDiskCache()
                try Task.checkCancellation()
                StorageDownloadsSettingsStore.shared.recordMediaCacheClear(at: Date())
                cacheStatus = try await SharedMediaDataLoader.shared.diskCacheStatus()
                operationMessage = "Cleared the media cache."
            } catch is CancellationError {
                cacheStatus = try? await SharedMediaDataLoader.shared.diskCacheStatus()
                if cacheStatus?.currentBytes == 0 {
                    StorageDownloadsSettingsStore.shared.recordMediaCacheClear(at: Date())
                    operationMessage = "Cleared the media cache before cancellation completed."
                } else {
                    operationMessage = "Media cache clearing was cancelled."
                }
            } catch {
                operationMessage = "The media cache could not be completely cleared."
                cacheStatus = try? await SharedMediaDataLoader.shared.diskCacheStatus()
            }
        }
    }

    private func clearIncompleteDownloads() {
        incompleteClearTask?.cancel()
        isClearingIncompleteDownloads = true
        incompleteClearTask = Task {
            defer {
                isClearingIncompleteDownloads = false
                incompleteClearTask = nil
            }
            do {
                let removed = try await SakuraCordStorageInspector.clearIncompleteDownloads()
                try Task.checkCancellation()
                incompleteDownloads = try await SakuraCordStorageInspector
                    .incompleteDownloadSummary()
                operationMessage = "Removed \(summaryDescription(removed)) of stale temporary downloads."
            } catch is CancellationError {
                incompleteDownloads = try? await SakuraCordStorageInspector
                    .incompleteDownloadSummary()
                operationMessage = incompleteDownloads.map {
                    "Cleanup stopped with \(summaryDescription($0)) remaining."
                } ?? "Cleanup stopped, but remaining temporary storage is unavailable."
            } catch {
                operationMessage = "Incomplete downloads could not be completely cleared."
                incompleteDownloads = try? await SakuraCordStorageInspector
                    .incompleteDownloadSummary()
            }
        }
    }

    private func clearDraftsForSelectedAccount() async {
        do {
            try await model.clearLocalDrafts()
            operationMessage = "Cleared drafts for the selected account."
        } catch {
            operationMessage = "Drafts for the selected account could not be cleared."
        }
        draftSummary = try? await model.localDraftStorageSummary()
    }

    private func clearDraftsForAllAccounts() async {
        do {
            try await model.clearAllLocalDrafts()
            operationMessage = "Cleared drafts for all saved accounts."
        } catch {
            operationMessage = "Drafts for all saved accounts could not be completely cleared."
        }
        draftSummary = try? await model.localDraftStorageSummary()
    }

    private func chooseDownloadFolder() {
        Task {
            let panel = NSOpenPanel()
            panel.title = "Choose Download Folder"
            panel.prompt = "Choose"
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.folder]
            // macOS 27 derives chooser capabilities from allowed types, so set the
            // intended directory-only behavior after assigning them.
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            let response = await withCheckedContinuation { continuation in
                panel.begin { continuation.resume(returning: $0) }
            }
            guard response == .OK, let url = panel.url else { return }
            do {
                try StorageDownloadsSettingsStore.shared.saveDefaultFolder(url)
                value.downloadLocationMode = .defaultFolder
                operationMessage = "Saved the default download folder."
            } catch {
                operationMessage = "The selected folder could not be authorized. Choose another folder."
            }
        }
    }

    private func resetPreferences() {
        SettingsPreferenceStore.shared.reset(scope: .appWide, page: .storageDownloads)
        value = StorageDownloadsSettingsStore.shared.load()
        Task { await applyMediaCacheLimit(value.mediaCacheLimit) }
        operationMessage = "Restored Storage & Downloads preferences without deleting local data."
    }

    private func exportPreferences() {
        exportedPreferences = SettingsPreferenceExportFile(
            export: SettingsPreferenceStore.shared.export(
                scope: .appWide,
                page: .storageDownloads
            )
        )
        isExporting = true
    }

    private func summaryDescription(_ summary: StorageByteSummary) -> String {
        "\(summary.fileCount) file(s), \(formatBytes(summary.byteCount))"
    }

    private func draftDescription(_ summary: DraftStorageSummary) -> String {
        "\(summary.draftCount) draft(s), about \(formatBytes(summary.approximateByteCount))"
    }

    private func formatBytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file))
    }
}
