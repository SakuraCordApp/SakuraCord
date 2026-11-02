import MediaPipeline
import SakuraCordModels
import SwiftUI
import UniformTypeIdentifiers

struct ProfileWidgetEditableImage: View {
    let image: ProfileWidgetImage?
    /// Identifies this image slot to the editor, which keeps its upload
    /// progress and failure while the slot's view comes and goes.
    let slot: String
    let purpose: ProfileImagePurpose
    let animates: Bool
    let editor: ProfileEditorState?
    let aspectRatio: Double
    var isCoverHovered = false
    var onHoverChange: ((Bool) -> Void)?
    var removeImage: (() -> Void)?
    let update: (ProfileWidgetImage?) -> Void
    @State private var isHovered = false
    @State private var isActionHovered = false
    @State private var importing = false
    @State private var errorMessage: String?

    private var busy: Bool { editor?.preparingWidgetImageSlots.contains(slot) == true }
    private var failure: String? { errorMessage ?? editor?.widgetImageFailure(for: slot) }

    private var isActive: Bool {
        purpose == .widgetCover ? isCoverHovered : isHovered || isActionHovered
    }

    var body: some View {
        ZStack {
            ProfileWidgetImageView(url: image?.url, animates: animates, contentMode: .fill)
            if let editor, editor.canEditPersonalWidget, image == nil {
                Button { importing = true } label: { Image(systemName: "photo.badge.plus").font(.interfaceSystem(size: 20))
                    .frame(width: InterfaceScale.metric(24), height: InterfaceScale.metric(24))
                    .nativeHoverPopover(isPresented: .constant(isActive)) {
                        Text("Upload Image", bundle: #bundle).font(.interface(.subheadline).weight(.medium))
                            .fixedSize().padding(.horizontal, InterfaceScale.metric(12)).padding(.vertical, InterfaceScale.metric(10))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: purpose == .widgetCover ? .topLeading : .center)
                    .padding(purpose == .widgetCover ? InterfaceScale.metric(16) : 0)
                    .contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("Upload Image")
            } else if editor?.canEditPersonalWidget == true, purpose == .widgetField {
                Button { importing = true } label: { Color.clear.contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("Change Image")
            }
            if busy { ProgressView().controlSize(.small) }
        }
        .overlay {
            RoundedRectangle(cornerRadius: InterfaceScale.metric(8))
                .fill(.primary.opacity(isActive && editor?.canEditPersonalWidget == true ? 0.07 : 0))
                .allowsHitTesting(false)
        }
        .clipShape(.rect(cornerRadius: InterfaceScale.metric(8)))
        .overlay(alignment: .topTrailing) {
            if editor?.canEditPersonalWidget == true, image != nil || removeImage != nil, isActive {
                HoverActionPill {
                    if image != nil, purpose == .widgetCover {
                        Menu {
                            Button("Change Image") { importing = true }
                            Button("Remove Image", role: .destructive) { remove() }
                        } label: {
                            HoverActionControlLabel { Image(systemName: "pencil").font(.interface(.callout).weight(.medium)) }
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Change Image")
                        .help("Change Image")
                    } else if removeImage != nil {
                        HoverActionButton(systemImage: "trash", help: String(localized: "Remove Image", bundle: #bundle), role: .destructive, action: remove)
                    }
                }
                .onModalHover { isActionHovered = $0 }
                .onDisappear { isActionHovered = false }
                .padding(.trailing, purpose == .widgetCover ? InterfaceScale.metric(48) : 0)
                .padding(.top, purpose == .widgetCover ? InterfaceScale.metric(8) : 0)
                .offset(x: purpose == .widgetCover ? 0 : InterfaceScale.metric(8), y: purpose == .widgetCover ? 0 : -InterfaceScale.metric(8))
            }
        }
        .onModalHover { isHovered = $0 }
        .onChange(of: isActive) { _, active in onHoverChange?(active) }
        .onDisappear { onHoverChange?(false) }
        .contextMenu {
            if editor?.canEditPersonalWidget == true {
                Button(image == nil ? "Upload Image" : "Change Image") { importing = true }
                if image != nil || removeImage != nil { Button("Remove Image", role: .destructive, action: remove) }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: ["jpg", "jpeg", "jfif", "png", "gif", "webp", "avif"].compactMap { UTType(filenameExtension: $0) }) { result in
            switch result {
            case let .success(url): load(url)
            case let .failure(error): errorMessage = error.localizedDescription
            }
        }
        .alert("Unable to Use Image", isPresented: Binding(get: { failure != nil }, set: { if !$0 { dismissFailure() } })) {
            Button("OK", role: .cancel, action: dismissFailure)
        } message: { Text(failure ?? "") }
    }

    private func remove() {
        if let removeImage { removeImage() } else { update(nil) }
    }

    /// Hands a chosen image to the editor, which crops and uploads it.
    private func load(_ url: URL) {
        guard let editor, editor.canEditPersonalWidget else { return }
        editor.prepareWidgetImage(from: url, slot: slot, purpose: purpose, aspectRatio: aspectRatio, apply: update)
    }

    private func dismissFailure() {
        errorMessage = nil
        editor?.dismissWidgetImageFailure(for: slot)
    }
}
