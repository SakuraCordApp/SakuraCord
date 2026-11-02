import SakuraCordModels
import SwiftUI
import UniformTypeIdentifiers

/// Edits a staged attachment's name, alt text and spoiler before it sends.
/// The preview and rows sit 8 points inside the 32-point panel, so their
/// 24-point corners stay concentric with it, as the 40-point footer capsules
/// do with its 12-point inset.
struct AttachmentEditor: View {
    let attachment: ForumPostAttachment
    let cancel: () -> Void
    let save: (ForumPostAttachment) -> Void
    @State private var filename: String
    @State private var description: String
    @State private var isSpoiler: Bool
    @State private var previewImage: NSImage?
    @FocusState private var focus: Field?
    @Environment(\.windowModalAvailableSize) private var availableSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Field { case filename, description }
    private static let descriptionLimit = 1_024

    init(attachment: ForumPostAttachment, cancel: @escaping () -> Void, save: @escaping (ForumPostAttachment) -> Void) {
        self.attachment = attachment
        self.cancel = cancel
        self.save = save
        _filename = State(initialValue: attachment.filename)
        _description = State(initialValue: attachment.description)
        _isSpoiler = State(initialValue: attachment.isSpoiler)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: InterfaceScale.metric(8)) {
                preview
                filenameRow
                descriptionRow
            }
            .padding(InterfaceScale.metric(8))
            Divider()
            HStack {
                ModalGlassButton(symbol: "xmark", label: "Cancel", action: cancel)
                Spacer(minLength: InterfaceScale.metric(16))
                ModalGlassButton(symbol: "checkmark", label: "Save", primary: true, action: commit)
                    .disabled(trimmedFilename.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(InterfaceScale.metric(12))
        }
        .frame(width: min(InterfaceScale.metric(480), availableSize.width))
        .task { await Task.yield(); focus = .description }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Modify Attachment")
    }

    private var preview: some View {
        // Layers over a fixed box, so the filled backdrop, which overflows
        // it, can't stretch the box the image fits into.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: isVisualMedia ? min(InterfaceScale.metric(280), max(InterfaceScale.metric(140), availableSize.height - InterfaceScale.metric(300))) : InterfaceScale.metric(140))
            .background {
                if let previewImage {
                    // The image's own colours, blurred, fill the space around it.
                    Image(nsImage: previewImage)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: InterfaceScale.metric(32))
                        .opacity(0.6)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                LocalAttachmentThumbnail(url: attachment.url, maximumPixelDimension: 1_024, contentMode: .fit, onImageLoaded: { previewImage = $0 })
                    .blur(radius: isSpoiler ? InterfaceScale.metric(28) : 0)
            }
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: InterfaceScale.metric(24), style: .continuous))
            .overlay(alignment: .bottomLeading) { spoilerButton.padding(InterfaceScale.metric(8)) }
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: isSpoiler)
            .accessibilityElement(children: .contain)
    }

    /// Sits 8 points inside the preview, so its 32-point capsule is concentric with it.
    private var spoilerButton: some View {
        Button { isSpoiler.toggle() } label: {
            Label("Spoiler", systemImage: isSpoiler ? "eye.slash.fill" : "eye.slash")
                .font(.interface(.callout).weight(.semibold))
                .padding(.horizontal, InterfaceScale.metric(12))
                .frame(height: InterfaceScale.metric(32))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(isSpoiler ? .regular.tint(SakuraCordAccentColor.color).interactive() : .regular.interactive(), in: Capsule())
        .help(isSpoiler ? "Remove Spoiler" : "Mark as Spoiler")
        .accessibilityLabel("Mark as Spoiler")
        .accessibilityValue(isSpoiler ? "On" : "Off")
    }

    private var filenameRow: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            rowIcon("doc")
            TextField("Filename", text: $filename)
                .textFieldStyle(.plain)
                .tint(SakuraCordAccentColor.color)
                .focused($focus, equals: .filename)
                .onSubmit(commit)
        }
        .modifier(ModalRowBackground(isHighlighted: focus == .filename) { focus = .filename })
    }

    private var descriptionRow: some View {
        HStack(alignment: .top, spacing: InterfaceScale.metric(8)) {
            rowIcon("text.below.photo")
            TextField("Description (alt text)", text: $description, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3 ... 6)
                .tint(SakuraCordAccentColor.color)
                .focused($focus, equals: .description)
                // Centres the first line on the 32-point icon.
                .padding(.vertical, InterfaceScale.metric(7))
                .onChange(of: description) { _, value in
                    if value.count > Self.descriptionLimit { description = String(value.prefix(Self.descriptionLimit)) }
                }
            if description.count > Self.descriptionLimit - 100 {
                Text("\(description.count)/\(Self.descriptionLimit)")
                    .font(.interface(.caption)).monospacedDigit().foregroundStyle(.secondary)
                    .padding(.top, InterfaceScale.metric(8))
            }
        }
        .modifier(ModalRowBackground(isHighlighted: focus == .description) { focus = .description })
    }

    private func rowIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .foregroundStyle(.secondary)
            .frame(width: InterfaceScale.metric(32), height: InterfaceScale.metric(32))
            .accessibilityHidden(true)
    }

    private var isVisualMedia: Bool {
        UTType(filenameExtension: attachment.url.pathExtension)?.conforms(to: .image) == true || LocalVideo.isVideo(attachment.url)
    }

    private var trimmedFilename: String { filename.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func commit() {
        guard !trimmedFilename.isEmpty else { return }
        var updated = attachment
        if trimmedFilename != attachment.filename { updated.rename(trimmedFilename) }
        updated.description = description
        updated.isSpoiler = isSpoiler
        save(updated)
    }
}
