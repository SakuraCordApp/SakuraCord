import DiscordProtocol
import MediaPipeline
import SakuraCordModels
import SwiftUI
import UniformTypeIdentifiers

struct ProfileImagePicker: View {
    let model: AppModel
    let editor: ProfileEditorState
    let purpose: ProfileImagePurpose
    let dismiss: () -> Void
    let apply: (ProfileAvatarSelection, URL) -> Void

    @Environment(\.stablePopoverPresentationContext) private var popover
    @Environment(\.profileImageImportRequest) private var imageImport
    @State private var showsGIFs = false
    @State private var deleteCandidate: ProfileAvatarHistoryEntry?
    @State private var work: Task<Void, Never>?
    @State private var isBusy = false
    @State private var isLoadingHistory = true
    @State private var errorMessage: String?
    static let allowedImageTypes = ["jpg", "jpeg", "jfif", "png", "gif", "webp", "avif"].compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        chooser
        .windowModalDismissDisabled(isBusy)
        .onChange(of: isBusy || imageImport?.isPresented == true, initial: true) { _, blocked in popover?.preventsDismissal = blocked }
        .onChange(of: showsGIFs) { _, presented in
            popover?.escapeAction = presented ? { showsGIFs = false } : nil
        }
        .alert("Unable to Use Image", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .alert("Remove Recent Avatar?", isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }), presenting: deleteCandidate) { entry in
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
            Button("Remove", role: .destructive) { delete(entry) }
        } message: { _ in
            Text("This image will no longer be available in your recent avatars.", bundle: #bundle)
        }
        .task {
            guard purpose == .avatar else { return }
            isLoadingHistory = true
            defer { isLoadingHistory = false }
            do { try await editor.loadHistory() } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
        }
        .onDisappear {
            popover?.preventsDismissal = false
            popover?.escapeAction = nil
            work?.cancel()
        }
    }

    static func chooserSize(for purpose: ProfileImagePurpose) -> CGSize {
        CGSize(width: InterfaceScale.metric(320), height: purpose == .avatar ? InterfaceScale.metric(148) : InterfaceScale.metric(64))
    }

    private var chooser: some View {
        VStack(spacing: InterfaceScale.metric(8)) {
            HStack(spacing: InterfaceScale.metric(8)) {
                imageAction("Upload Image", icon: Image(systemName: "photo.badge.plus"), action: importImage)
                imageAction("Choose GIF", icon: ComposerIcon.gif.image) { showsGIFs = true }
                    .overlay {
                        StableAnchoredPopoverPresenter(isPresented: showsGIFs, configuration: .toolbarPanel,
                                                       onDismiss: { showsGIFs = false }, content: {
                            GIFPickerView(model: model, dismiss: { showsGIFs = false }, selectionHandler: chooseGIF, hidesFavorites: true)
                        })
                    }
            }
            if purpose == .avatar {
                VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
                    Divider()
                    Text("Recent Avatars", bundle: #bundle)
                        .font(.interface(.caption).weight(.medium)).foregroundStyle(.secondary)
                    recentAvatars
                }
            }
        }
        .padding(InterfaceScale.metric(12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(isBusy)
        .overlay { if isBusy { ProgressView().padding().glassEffect() } }
    }

    private func imageAction(_ title: LocalizedStringKey, icon: Image, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: InterfaceScale.metric(7)) {
                icon.font(.interfaceSystem(size: 18)).frame(width: InterfaceScale.metric(22), height: InterfaceScale.metric(22))
                Text(title).font(.interface(.callout).weight(.medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).frame(height: InterfaceScale.metric(40))
        }
        .buttonStyle(PopoverRowButtonStyle())
    }

    private var recentAvatars: some View {
        HStack(spacing: InterfaceScale.metric(4)) {
            ForEach(editor.history.prefix(6)) { entry in
                ProfileRecentAvatarButton(entry: entry, choose: { selectArchive(entry) }, remove: {
                    if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { delete(entry) } else { deleteCandidate = entry }
                })
            }
        }
        .frame(maxWidth: .infinity).frame(height: InterfaceScale.metric(44))
        .overlay {
            if editor.history.isEmpty {
                if isLoadingHistory {
                    ProgressView().controlSize(.small).accessibilityLabel("Loading recent avatars")
                } else {
                    Text("No Recent Avatars", bundle: #bundle).font(.interface(.caption)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func importImage() {
        guard let imageImport else { return }
        popover?.preventsDismissal = true
        imageImport.present { result in
            switch result {
            case let .success(url): loadFile(url)
            case .failure(is CancellationError): break
            case let .failure(error): errorMessage = error.localizedDescription
            }
        }
    }

    private func loadFile(_ url: URL) {
        let account = model.accountSession()
        begin {
            let permitted = url.startAccessingSecurityScopedResource()
            defer { if permitted { url.stopAccessingSecurityScopedResource() } }
            let data = try await Task.detached { try Data(contentsOf: url) }.value
            try await selectImage(data, name: url.deletingPathExtension().lastPathComponent, account: account)
        }
    }

    private func selectArchive(_ entry: ProfileAvatarHistoryEntry) {
        guard !isBusy else { return }
        guard canSelect(animated: entry.storageHash.hasPrefix("a_")) else {
            errorMessage = String(localized: "This profile image requires Nitro.", bundle: #bundle)
            return
        }
        apply(.history(entry), entry.imageURL)
        dismiss()
    }

    private func chooseGIF(_ gif: GIFSearchResult, page: GIFPickerPage) {
        showsGIFs = false
        begin {
            let account = model.accountSession()
            guard model.isCurrentAccountSession(account),
                  let url = DiscordProfileImageAssets.editableGIFURL(gif.previewURL ?? gif.mediaURL),
                  !GIFPickerMediaPolicy.isVideo(url)
            else { throw ChatProviderError.invalidRequest("This GIF does not include an editable image.") }
            let download = Task { try await SharedMediaDataLoader.shared.data(for: url) }
            if page != .favorites {
                let query: String
                if case let .search(value) = page { query = value } else { query = "" }
                // The first-party picker starts the image fetch before its
                // independent selection notification. A notification failure
                // must not reject an otherwise usable image or trigger retry.
                Task { try? await account.provider.recordProfileGIFSelection(id: gif.id, query: query) }
            }
            let data = try await withTaskCancellationHandler { try await download.value } onCancel: { download.cancel() }
            guard model.isCurrentAccountSession(account) else { throw CancellationError() }
            try await selectImage(data, name: "selected", account: account)
        }
    }

    private func selectImage(_ data: Data, name: String, account: AppModelAccountSession) async throws {
        // Inspect the original bytes for type, animation and validation; do not transform them.
        let image = try await Task.detached { try ProfileImageSource(data: data) }.value
        try Task.checkCancellation()
        guard model.isCurrentAccountSession(account) else { throw CancellationError() }
        guard canSelect(animated: image.isAnimated || image.mediaType == "image/gif") else {
            throw ChatProviderError.invalidRequest(String(localized: "This profile image requires Nitro.", bundle: #bundle))
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "profile-draft-\(UUID().uuidString)")
        var adopted = false
        defer { if !adopted { try? FileManager.default.removeItem(at: url) } }
        try await Task.detached { try data.write(to: url, options: [.atomic, .completeFileProtection]) }.value
        try Task.checkCancellation()
        guard model.isCurrentAccountSession(account) else { throw CancellationError() }
        let date = Date().formatted(.dateTime.day().month(.wide).year().hour().minute())
        let upload = ProfileImageUpload(data: data, mediaType: image.mediaType, description: "\(name), added \(date)",
                                        originalMD5: image.originalMD5, isAnimated: image.isAnimated)
        apply(.upload(upload), url)
        adopted = true // The profile editor now owns the preview file until reset/save.
        dismiss()
    }

    private func canSelect(animated: Bool) -> Bool {
        if purpose == .banner || editor.scope.guildID != nil { return editor.isNitro }
        return !animated || editor.isNitro || editor.snapshot?.presentation.user.premiumType == DiscordPremiumType.nitroClassic
    }

    private func delete(_ entry: ProfileAvatarHistoryEntry) {
        deleteCandidate = nil
        begin { try await editor.deleteHistory(entry) }
    }

    private func begin(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        work = Task {
            defer { isBusy = false }
            do { try await operation() } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct ProfileRecentAvatarButton: View {
    let entry: ProfileAvatarHistoryEntry
    let choose: () -> Void
    let remove: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: choose) {
            AvatarView(name: "", url: entry.imageURL, size: InterfaceScale.metric(40))
                .padding(InterfaceScale.metric(2))
                .background(.primary.opacity(isHovered ? 0.14 : 0), in: Circle())
                .overlay { Circle().strokeBorder(.primary.opacity(isHovered ? 0.3 : 0), lineWidth: 2) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onModalHover { isHovered = $0 }
        .help(entry.description)
        .accessibilityLabel(entry.description)
        .accessibilityAction(named: Text("Remove Recent Avatar", bundle: #bundle), remove)
        .contextMenu { Button("Remove Avatar", systemImage: "trash", role: .destructive, action: remove) }
    }
}
