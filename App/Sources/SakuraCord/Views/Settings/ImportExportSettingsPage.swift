import SwiftUI

struct ImportExportSettingsPage: View {
    let model: AppModel
    @ObservedObject var updateController: AppUpdateController
    let state: SettingsViewState
    let launchAtLogin: LaunchAtLoginController

    @State private var selectedPages = Set(SettingsTransferService.pages)
    @State private var document: SettingsArchiveDocument?
    @State private var showsExporter = false
    @State private var showsImporter = false
    @State private var isWorking = false
    @State private var showsResult = false
    @State private var resultTitle = ""
    @State private var resultMessage = ""
    @State private var suggestsUpdate = false

    var body: some View {
        SettingsPageForm(page: .importExport, state: state) {
            Section {
                Grid(alignment: .leading, horizontalSpacing: InterfaceScale.metric(24), verticalSpacing: InterfaceScale.metric(10)) {
                    ForEach(0 ..< (SettingsTransferService.pages.count + 1) / 2, id: \.self) { row in
                        GridRow {
                            categoryToggle(at: row * 2)
                            categoryToggle(at: row * 2 + 1)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                HStack {
                    Button("Select All") { selectedPages = Set(SettingsTransferService.pages) }
                        .disabled(selectedPages.count == SettingsTransferService.pages.count)
                        .settingsControlAnchor(.exportSelectAll, state: state)
                    Button("Deselect All") { selectedPages.removeAll() }
                        .disabled(selectedPages.isEmpty)
                        .settingsControlAnchor(.exportDeselectAll, state: state)
                }
            } header: {
                Text("Include in Export", bundle: #bundle)
            }
            Section {
                HStack {
                    Button("Export Settings…", systemImage: "square.and.arrow.up") { exportSettings() }
                        .disabled(selectedPages.isEmpty || isWorking)
                        .settingsControlAnchor(.settingsExport, state: state)
                    Button("Import Settings…", systemImage: "square.and.arrow.down") { showsImporter = true }
                        .disabled(isWorking)
                        .settingsControlAnchor(.settingsImport, state: state)
                    if isWorking { ProgressView().controlSize(.small) }
                }
            }
        }
        .fileExporter(isPresented: $showsExporter, document: document, contentType: .sakuraSettings, defaultFilename: "SakuraCord Settings") { result in
            if case let .failure(error) = result { presentError(error) }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.sakuraSettings]) { result in
            switch result {
            case let .success(url): importSettings(from: url)
            case let .failure(error): presentError(error)
            }
        }
        .alert(resultTitle, isPresented: $showsResult) {
            if suggestsUpdate {
                Button("Check for Updates…") {
                    state.selectedPage = .softwareUpdates
                    if updateController.canCheckForUpdates { updateController.checkForUpdates() }
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(resultMessage)
        }
    }

    @ViewBuilder
    private func categoryToggle(at index: Int) -> some View {
        if SettingsTransferService.pages.indices.contains(index) {
            let page = SettingsTransferService.pages[index]
            Toggle(isOn: Binding(
                get: { selectedPages.contains(page) },
                set: { enabled in
                    if enabled { selectedPages.insert(page) } else { selectedPages.remove(page) }
                }
            )) { Text(state.catalog.page(page).title) }
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsControlAnchor(.exportCategory(page), state: state)
        }
    }

    private func exportSettings() {
        isWorking = true
        let pages = selectedPages
        Task {
            defer { isWorking = false }
            do {
                let archive = await SettingsTransferService().export(pages: pages, updateController: updateController, launchAtLogin: launchAtLogin)
                document = try SettingsArchiveDocument(archive: archive)
                showsExporter = true
            } catch { presentError(error) }
        }
    }

    private func importSettings(from url: URL) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let archive = try await Task.detached(priority: .userInitiated) {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= SettingsArchive.maximumFileSize else { throw SettingsArchiveError.tooLarge }
                    return try SettingsArchive.decode(Data(contentsOf: url))
                }.value
                let report = await SettingsTransferService().importArchive(archive, model: model, updateController: updateController, launchAtLogin: launchAtLogin)
                resultTitle = report.needsUpdate ? "Update to Import All Settings" : "Settings Imported"
                resultMessage = report.message
                suggestsUpdate = report.needsUpdate
                showsResult = true
            } catch { presentError(error) }
        }
    }

    private func presentError(_ error: any Error) {
        resultTitle = "Settings Transfer Failed"
        resultMessage = error.localizedDescription
        suggestsUpdate = false
        showsResult = true
    }
}
