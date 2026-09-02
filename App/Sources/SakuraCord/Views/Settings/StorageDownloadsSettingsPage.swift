import AppKit
import MediaPipeline
import SwiftUI

struct StorageDownloadsSettingsPage: View {
    private enum Confirmation: String, Identifiable {
        case mediaCache
        case allDrafts

        var id: String { rawValue }
    }

    let model: AppModel
    let state: SettingsViewState

    @State private var value = StorageDownloadsSettingsSnapshot.defaults
    @State private var defaultFolderPath: String?
    @State private var cacheStatus: MediaCache.Status?
    @State private var draftSummary: LocalDraftStorageSummary?
    @State private var confirmation: Confirmation?
    @State private var isClearingCache = false
    @State private var cacheClearTask: Task<Void, Never>?

    var body: some View {
        SettingsPageForm(page: .storageDownloads, state: state) {
            localStorageSection
            downloadsSection
        }
        .task {
            value = StorageDownloadsSettingsStore.shared.load()
            refreshDefaultFolderPath()
            await loadStorageStatus()
        }
        .onChange(of: value) { oldValue, newValue in
            StorageDownloadsSettingsStore.shared.save(newValue)
            guard oldValue.localStorageLimit != newValue.localStorageLimit else { return }
            Task { await applyLocalStorageLimit(newValue.localStorageLimit) }
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
        .onDisappear {
            cacheClearTask?.cancel()
        }
    }

    private var localStorageSection: some View {
        Section {
            Picker("Maximum size", selection: $value.localStorageLimit) {
                ForEach(LocalStorageLimit.allCases) { limit in
                    Text(limit.title).tag(limit)
                }
            }
            .settingsControlAnchor(.localStorageLimit, state: state)

            LabeledContent("Current usage") {
                if let cacheStatus, let draftSummary {
                    let mediaBytes = cacheStatus.currentBytes
                    let draftBytes = draftSummary.allAccounts.approximateByteCount
                    let totalBytes = mediaBytes + draftBytes
                    Text(
                        "\(totalBytes, format: .byteCount(style: .file)) (\(mediaBytes, format: .byteCount(style: .file)) media cache, \(draftBytes, format: .byteCount(style: .file)) drafts)",
                        bundle: #bundle,
                        comment: "Storage usage: total bytes, then media cache bytes and draft bytes."
                    )
                    .foregroundStyle(.secondary)
                } else {
                    Text("Unavailable", bundle: #bundle)
                        .foregroundStyle(.secondary)
                }
            }
            .settingsControlAnchor(.localStorageUsage, state: state)

            HStack {
                Button("Clear Media Cache…", role: .destructive) {
                    confirmation = .mediaCache
                }
                .disabled(isClearingCache)
                .settingsControlAnchor(.mediaCacheClear, state: state)
                if isClearingCache {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Clear Drafts…", role: .destructive) {
                    confirmation = .allDrafts
                }
                .disabled((draftSummary?.allAccounts.draftCount ?? 0) == 0)
                .settingsControlAnchor(.clearAllAccountDrafts, state: state)
                Spacer()
                Text(lastCacheClearDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Storage", bundle: #bundle)
        }
    }

    private var downloadsSection: some View {
        Section {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Default download folder", bundle: #bundle)
                    if let defaultFolderPath {
                        Text(defaultFolderPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(defaultFolderPath)
                    } else {
                        Text("No folder selected", bundle: #bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Select Folder…") {
                    chooseDownloadFolder()
                }
            }
            .settingsControlAnchor(.downloadFolderName, state: state)

            Toggle(
                "Reveal completed downloads in Finder",
                isOn: $value.revealsCompletedDownloads
            )
            .tint(SakuraCordAccentColor.color)
            .settingsControlAnchor(.revealCompletedDownloads, state: state)
        } header: {
            Text("Downloads", bundle: #bundle)
        }
    }

    private var lastCacheClearDescription: String {
        if isClearingCache { return "Clearing…" }
        return StorageDownloadsSettingsStore.shared.lastMediaCacheClearDate.map {
            "Cleared \($0.formatted(date: .abbreviated, time: .shortened))"
        } ?? "Never cleared"
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .mediaCache: "Clear Media Cache?"
        case .allDrafts: "Clear Drafts?"
        case nil: "Confirm Storage Action"
        }
    }

    private var confirmationButtonTitle: String {
        switch confirmation {
        case .mediaCache: "Clear Media Cache"
        case .allDrafts: "Clear Drafts"
        case nil: "Confirm"
        }
    }

    private var confirmationMessage: String {
        switch confirmation {
        case .mediaCache:
            "This removes SakuraCord's disposable disk media. Visible and playing media remain available."
        case .allDrafts:
            "This permanently removes unsent local drafts for every saved account."
        case nil:
            "No action has been selected."
        }
    }

    private func perform(_ action: Confirmation) {
        confirmation = nil
        switch action {
        case .mediaCache:
            clearMediaCache()
        case .allDrafts:
            Task { await clearDraftsForAllAccounts() }
        }
    }

    private func applyLocalStorageLimit(_ limit: LocalStorageLimit) async {
        do {
            draftSummary = try await model.applyLocalStorageLimit(limit)
            cacheStatus = try await SharedMediaDataLoader.shared.diskCacheStatus()
        } catch {
            cacheStatus = nil
        }
    }

    private func loadStorageStatus() async {
        do {
            draftSummary = try await model.applyLocalStorageLimit(value.localStorageLimit)
        } catch {
            draftSummary = nil
        }
        do {
            cacheStatus = try await SharedMediaDataLoader.shared.diskCacheStatus()
        } catch {
            cacheStatus = nil
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
            } catch is CancellationError {
                cacheStatus = try? await SharedMediaDataLoader.shared.diskCacheStatus()
                if cacheStatus?.currentBytes == 0 {
                    StorageDownloadsSettingsStore.shared.recordMediaCacheClear(at: Date())
                }
            } catch {
                cacheStatus = try? await SharedMediaDataLoader.shared.diskCacheStatus()
            }
        }
    }

    private func clearDraftsForAllAccounts() async {
        do {
            try await model.clearAllLocalDrafts()
            draftSummary = try await model.localDraftStorageSummary()
            cacheStatus = try await SharedMediaDataLoader.shared.diskCacheStatus()
        } catch {
            draftSummary = try? await model.localDraftStorageSummary()
        }
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
                defaultFolderPath = url.path(percentEncoded: false)
            } catch {}
        }
    }

    private func refreshDefaultFolderPath() {
        defaultFolderPath = try? StorageDownloadsSettingsStore.shared
            .resolvedDefaultFolder()?
            .path(percentEncoded: false)
    }

}
