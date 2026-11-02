import AppKit
import MediaPipeline
import SakuraCordModels
import SwiftUI
import UniformTypeIdentifiers

/// Discord's Edit Group dialog. The name and icon stay local until Save; a
/// failed save keeps the dialog open with Discord's reason.
struct GroupDirectMessageEditorView: View {
    let model: AppModel
    let presentation: GroupDirectMessageEditorStore.Presentation
    @Environment(\.windowModalContext) private var modal
    @Environment(\.windowModalAvailableSize) private var availableSize
    @State private var isPreparingIcon = false

    var body: some View {
        let store = model.groupDirectMessageEditor
        let isBusy = store.isSaving || isPreparingIcon
        VStack(alignment: .leading, spacing: InterfaceScale.metric(16)) {
            Text("Edit Group")
                .font(.interface(.title2).weight(.bold))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, InterfaceScale.metric(12))
            VStack(spacing: InterfaceScale.metric(10)) {
                GroupDirectMessageIconEditor(
                    store: store,
                    presentation: presentation,
                    isPreparing: $isPreparingIcon
                )
                if store.showsIcon {
                    // Clears the draft icon; the group returns to its default avatar on Save.
                    Button("Remove Icon") { store.icon = .removed }
                        .buttonStyle(.plain)
                        .font(.interface(.callout).weight(.medium))
                        .foregroundStyle(.red)
                        .pointerStyle(.link)
                        .disabled(isPreparingIcon)
                }
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
                GroupDirectMessageNameField(
                    placeholder: presentation.placeholder,
                    draft: Bindable(store).draftName,
                    submit: save
                )
                if let error = store.error {
                    Text(error).font(.interface(.caption)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, InterfaceScale.metric(12))
            // Keep the 12-point footer inset that makes the capsules concentric with the panel.
            HStack {
                ModalGlassButton(symbol: "xmark", label: "Cancel") { modal?.dismiss() }
                    .disabled(store.isSaving)
                Spacer(minLength: InterfaceScale.metric(16))
                ModalGlassButton(symbol: "checkmark", label: "Save", primary: true, isLoading: store.isSaving, action: save)
                    .disabled(isBusy || !store.changes.hasChanges)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, InterfaceScale.metric(4))
        }
        .disabled(store.isSaving)
        .padding(.top, InterfaceScale.metric(12))
        .padding(InterfaceScale.metric(12))
        .frame(width: min(InterfaceScale.metric(400), availableSize.width))
        .windowModalDismissDisabled(isBusy)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Edit Group")
    }

    private func save() {
        guard !model.groupDirectMessageEditor.isSaving, !isPreparingIcon else { return }
        model.saveGroupDirectMessage(presentation)
    }
}

private struct GroupDirectMessageNameField: View {
    let placeholder: String
    @Binding var draft: String
    let submit: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
            Text("Group Name").font(.interface(.headline))
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain).font(.interface(.body))
                .focused($isFocused)
                .onSubmit(submit)
                .padding(InterfaceScale.metric(14)).frame(maxWidth: .infinity, alignment: .leading)
                .modifier(ModalInputSurface(isFocused: isFocused) { isFocused = true })
                .onChange(of: draft) { _, value in
                    let limit = GroupDirectMessageChanges.maximumNameLength
                    guard value.utf16.count > limit else { return }
                    var trimmed = value
                    while trimmed.utf16.count > limit { trimmed.removeLast() }
                    draft = trimmed
                }
                .accessibilityLabel("Group Name")
        }
        .task {
            await Task.yield()
            isFocused = true
        }
    }
}

/// The group icon with Discord's pencil badge. A chosen image is cropped to
/// its centred square before it becomes the draft icon.
private struct GroupDirectMessageIconEditor: View {
    let store: GroupDirectMessageEditorStore
    let presentation: GroupDirectMessageEditorStore.Presentation
    @Binding var isPreparing: Bool
    @State private var importing = false
    @State private var work: Task<Void, Never>?
    @State private var errorMessage: String?
    /// The cropped upload, decoded once for display.
    @State private var preview: NSImage?

    private var size: CGFloat { InterfaceScale.metric(96) }
    private var badgeSize: CGFloat { InterfaceScale.metric(32) }
    /// Discord's Edit Group image picker accepts files up to 8 MiB.
    private static let maximumSourceBytes = 8 * 1024 * 1024

    var body: some View {
        Button { importing = true } label: { icon }
            .buttonStyle(.plain)
            .accessibilityLabel(store.showsIcon ? "Change Group Icon" : "Upload Group Icon")
            .overlay(alignment: .topTrailing) {
                Menu {
                    Button("Upload Image") { importing = true }
                    if store.showsIcon {
                        Button("Remove Icon", role: .destructive) { store.icon = .removed }
                    }
                } label: {
                    Image(systemName: "pencil").font(.interface(.callout).weight(.medium))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: badgeSize, height: badgeSize)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("Edit Group Icon")
                .help("Edit Group Icon")
            }
            .overlay { if isPreparing { ProgressView().controlSize(.small) } }
            .disabled(isPreparing)
            .fileImporter(isPresented: $importing, allowedContentTypes: ProfileImagePicker.allowedImageTypes) { result in
                switch result {
                case let .success(url): load(url)
                case let .failure(error): errorMessage = error.localizedDescription
                }
            }
            .alert("Unable to Use Image", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .onDisappear { work?.cancel() }
    }

    @ViewBuilder
    private var icon: some View {
        if case .upload = store.icon, let preview {
            Image(nsImage: preview)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .accessibilityLabel("\(presentation.channel.name) group icon")
        } else if store.showsIcon, let url = presentation.channel.iconURL {
            AvatarView(name: presentation.channel.name, url: url, size: size)
        } else {
            Image(systemName: "person.2.fill")
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: size, height: size)
                .background(.quaternary, in: Circle())
                .accessibilityLabel("\(presentation.channel.name) group icon")
        }
    }

    private func load(_ url: URL) {
        work?.cancel()
        let revision = store.revision
        work = Task {
            isPreparing = true
            defer { isPreparing = false }
            do {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                // Reject an oversized file before reading it into memory.
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= Self.maximumSourceBytes else { throw GroupIconError.tooLarge }
                let maximumBytes = Self.maximumSourceBytes
                let processing = Task.detached {
                    let data = try Data(contentsOf: url)
                    guard data.count <= maximumBytes else { throw GroupIconError.tooLarge }
                    let source = try ProfileImageSource(data: data)
                    return try ProfileImageProcessor.crop(source, geometry: ProfileImageCropGeometry(naturalSize: source.size, purpose: .avatar))
                }
                let output = try await withTaskCancellationHandler { try await processing.value } onCancel: { processing.cancel() }
                try Task.checkCancellation()
                guard store.revision == revision else { throw CancellationError() }
                preview = NSImage(data: output.data)
                store.icon = .upload(ProfileImageUpload(
                    data: output.data, mediaType: output.mediaType, description: url.lastPathComponent, isAnimated: output.isAnimated
                ))
            } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
        }
    }
}

private enum GroupIconError: LocalizedError {
    case tooLarge
    var errorDescription: String? { "Group icons must be 8 MB or smaller." }
}

struct EditGroupPresentationModifier: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content
            .windowModal(item: Bindable(model.groupDirectMessageEditor).presentation, cornerRadius: InterfaceScale.metric(32), cornerStyle: .circular) {
                GroupDirectMessageEditorView(model: model, presentation: $0)
            }
    }
}
