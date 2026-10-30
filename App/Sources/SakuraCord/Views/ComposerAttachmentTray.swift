import SakuraCordModels
import SwiftUI
import UniformTypeIdentifiers

struct ComposerAttachmentTray: View {
    static var cornerRadius: CGFloat { InterfaceScale.metric(12) }
    static var tileSize: CGFloat { InterfaceScale.metric(132) }
    /// The upload ring shrinks with the tile and grows back to the
    /// timeline's size as it flies into the message.
    static let ringScale: CGFloat = 0.75

    @AppStorage(PrivacySafetySettingsStore.anonymiseFileNamesKey, store: PRBuildProfile.defaults) private var anonymisesFileNames = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let attachments: [ForumPostAttachment]
    /// Files still being checked; they show at once but cannot be sent yet.
    var checkingIDs: Set<UUID> = []
    let uploads: AttachmentUploadProgressStore
    var sendTransitionAnchor: ComposerSendTransitionAnchor?
    /// The tile the media viewer is zoomed out of, which hides meanwhile.
    /// Read here rather than by the composer, which would otherwise redraw
    /// as the viewer opens.
    var mediaViewerSourceID: () -> String? = { nil }
    let open: (UUID) -> Void
    let toggleSpoiler: (UUID) -> Void
    let update: (ForumPostAttachment) -> Void
    let remove: (UUID) -> Void
    @State private var editingTarget: ComposerAttachmentEditorTarget?

    var body: some View {
        let mediaViewerSourceID = mediaViewerSourceID()
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: InterfaceScale.metric(9)) {
                    ForEach(attachments) { attachment in
                        ComposerAttachmentTile(
                            attachment: attachment,
                            isChecking: checkingIDs.contains(attachment.id),
                            uploads: uploads,
                            anonymisesFileNames: anonymisesFileNames,
                            sendTransitionAnchor: sendTransitionAnchor,
                            isMediaViewerSource: mediaViewerSourceID == attachment.id.uuidString,
                            open: open,
                            toggleSpoiler: toggleSpoiler,
                            toggleFilenamePrivacy: toggleFilenamePrivacy,
                            edit: { editingTarget = ComposerAttachmentEditorTarget(id: $0) },
                            remove: remove
                        )
                        .id(attachment.id)
                        .transition(reduceMotion ? .opacity : Self.tileTransition)
                    }
                }
                .padding(InterfaceScale.metric(10))
                // Tiles settle on their own spring inside the composer's
                // resize, which carries the tray itself.
                .animation(reduceMotion ? .smooth(duration: 0.2) : ComposerResizeMotion.tile, value: attachments.map(\.id))
            }
            .scrollIndicators(.hidden)
            .onChange(of: attachments.map(\.id)) { previous, current in
                // Bring a newly added file into view as it arrives.
                guard let added = current.last(where: { !previous.contains($0) }) else { return }
                withAnimation(reduceMotion ? nil : ComposerResizeMotion.tile) {
                    proxy.scrollTo(added, anchor: .trailing)
                }
            }
        }
        .frame(height: Self.tileSize + InterfaceScale.metric(20))
        .accessibilityLabel("Message attachments")
        .onChange(of: anonymisesFileNames) { _, enabled in
            for var attachment in attachments {
                attachment.setFilenameAnonymised(enabled)
                update(attachment)
            }
        }
        .sheet(item: $editingTarget) { target in
            if let attachment = attachments.first(where: { $0.id == target.id }) {
                ForumAttachmentEditor(
                    attachment: attachment,
                    cancel: { editingTarget = nil },
                    save: {
                        update($0)
                        editingTarget = nil
                    }
                )
            }
        }
    }

    /// A file drops into place and pops back out when removed.
    private static var tileTransition: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.82, anchor: .bottom)
                .combined(with: .opacity)
                .combined(with: .offset(y: InterfaceScale.metric(8))),
            removal: .scale(scale: 0.86).combined(with: .opacity)
        )
    }

    private func toggleFilenamePrivacy(_ attachment: ForumPostAttachment) {
        var updated = attachment
        updated.setFilenameAnonymised(!attachment.isFilenameAnonymised)
        update(updated)
    }
}

private struct ComposerAttachmentTile: View {
    let attachment: ForumPostAttachment
    let isChecking: Bool
    let uploads: AttachmentUploadProgressStore
    let anonymisesFileNames: Bool
    let sendTransitionAnchor: ComposerSendTransitionAnchor?
    let isMediaViewerSource: Bool
    let open: (UUID) -> Void
    let toggleSpoiler: (UUID) -> Void
    let toggleFilenamePrivacy: (ForumPostAttachment) -> Void
    let edit: (UUID) -> Void
    let remove: (UUID) -> Void
    @State private var isHovered = false
    @State private var uploadFraction: Double?
    @State private var thumbnail: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tileSize: CGFloat { ComposerAttachmentTray.tileSize }
    /// The name and action pills' height, so they read as one set.
    private var controlDiameter: CGFloat { InterfaceScale.metric(18) }
    private var pillInset: CGFloat { InterfaceScale.metric(5) }
    private var shape: ConcentricRectangle {
        ConcentricRectangle(cornerRadius: ComposerAttachmentTray.cornerRadius, style: .continuous)
    }

    var body: some View {
        tile
            .background {
                ComposerSendTransitionAttachmentReader(anchor: sendTransitionAnchor, id: attachment.id, thumbnail: thumbnail)
            }
            .animation(.smooth(duration: 0.22), value: attachment.isSpoiler)
            .animation(.smooth(duration: 0.25), value: isChecking)
            .animation(.smooth(duration: 0.25), value: uploadFraction == nil)
            .contentShape(shape)
            .onTapGesture {
                guard isViewable else { return }
                open(attachment.id)
            }
            .onModalHover { hovering in
                withAnimation(ComposerResizeMotion.hover) { isHovered = hovering }
            }
            .onAppear { uploadFraction = uploads.preuploadFraction(attachment.id) }
            .onReceive(NotificationCenter.default.publisher(for: AttachmentUploadProgressStore.didChange, object: uploads)) {
                guard $0.userInfo?[AttachmentUploadProgressStore.attachmentIDKey] as? UUID == attachment.id else { return }
                uploadFraction = uploads.preuploadFraction(attachment.id)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(attachment.filename)
            .accessibilityValue(accessibilityStatus)
            .accessibilityAction(named: "Open attachment") {
                guard isViewable else { return }
                open(attachment.id)
            }
            .accessibilityAction(
                named: attachment.isSpoiler ? "Remove spoiler" : "Mark as spoiler"
            ) {
                toggleSpoiler(attachment.id)
            }
            .accessibilityActions {
                if anonymisesFileNames {
                    Button(attachment.isFilenameAnonymised ? "Restore file name" : "Randomise file name") {
                        toggleFilenamePrivacy(attachment)
                    }
                }
            }
            .accessibilityAction(named: "Edit attachment") {
                edit(attachment.id)
            }
            .accessibilityAction(named: "Delete attachment") {
                remove(attachment.id)
            }
    }

    private var tile: some View {
        ZStack {
            face
            if attachment.isSpoiler {
                spoilerCover
            }
            if isChecking || uploadFraction != nil {
                uploadCover
            }
        }
        .frame(width: tileSize, height: tileSize)
        .clipShape(shape)
        .overlay {
            shape.stroke(.primary.opacity(isHovered ? 0.16 : 0.08), lineWidth: 1)
        }
        // The name, its shade and the actions arrive and leave together.
        .overlay(alignment: .bottom) {
            if isHovered {
                Self.scrim
                    .clipShape(shape)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if isHovered {
                filenamePill
                    .padding(pillInset)
                    .transition(hoverPillTransition(anchor: .bottomLeading))
            }
        }
        .overlay(alignment: .topTrailing) {
            if isHovered {
                actions
                    .padding(pillInset)
                    .transition(hoverPillTransition(anchor: .topTrailing))
            }
        }
        .opacity(isMediaViewerSource ? 0 : 1)
    }

    /// Images and videos fill the tile; other files show their type.
    @ViewBuilder private var face: some View {
        if attachment.isVisualMedia {
            LocalAttachmentThumbnail(
                url: attachment.url,
                maximumPixelDimension: 720,
                onImageLoaded: { thumbnail = $0 }
            )
        } else {
            ComposerAttachmentFileFace(url: attachment.url)
        }
    }

    private var spoilerCover: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.58))
            VStack(spacing: InterfaceScale.metric(4)) {
                Image(systemName: "eye.slash")
                Text("SPOILER")
                    .font(.interface(.caption2).weight(.bold))
            }
            .foregroundStyle(.white)
        }
        .transition(.opacity)
    }

    /// Dims the file while it is checked or uploaded, with its progress.
    private var uploadCover: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(AttachmentUploadRing.dimOpacity))
            if let uploadFraction {
                AttachmentUploadRingView(fraction: uploadFraction)
                    .scaleEffect(ComposerAttachmentTray.ringScale)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .environment(\.colorScheme, .dark)
            }
        }
        .transition(.opacity)
    }

    /// The name in a pill like the actions', so they read as one set.
    private var filenamePill: some View {
        HoverActionPill(spacing: 0, padding: 2) {
            Text(attachment.filename)
                .font(.interface(.caption).weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, InterfaceScale.metric(5))
                .frame(height: controlDiameter)
        }
        .frame(maxWidth: tileSize - 2 * pillInset, alignment: .leading)
        .allowsHitTesting(false)
    }

    private func hoverPillTransition(anchor: UnitPoint) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.7, anchor: anchor).combined(with: .opacity)
    }

    /// A soft shade under the name. Its eased stops leave no visible edge
    /// where it starts.
    private static var scrim: some View {
        LinearGradient(stops: scrimStops, startPoint: .top, endPoint: .bottom)
            .frame(height: ComposerAttachmentTray.tileSize / 2)
    }

    private static let scrimStops: [Gradient.Stop] = (0 ... 16).map { step in
        let location = Double(step) / 16
        let eased = location * location * (3 - 2 * location)
        return .init(color: .black.opacity(0.32 * eased), location: location)
    }

    private var accessibilityStatus: Text {
        if let uploadFraction {
            Text("Uploading, \(uploadFraction, format: .percent.precision(.fractionLength(0)))")
        } else if isChecking {
            Text("Preparing")
        } else {
            Text("")
        }
    }

    private var actions: some View {
        HoverActionPill(
            glass: .regular.interactive(),
            spacing: 1,
            padding: 2
        ) {
            HoverActionButton(
                systemImage: attachment.isSpoiler ? "eye.slash" : "eye",
                help: attachment.isSpoiler ? "Remove spoiler" : "Mark as spoiler",
                isSelected: attachment.isSpoiler,
                diameter: controlDiameter,
                iconFont: .interface(.caption2).weight(.semibold)
            ) {
                toggleSpoiler(attachment.id)
            }
            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
            if anonymisesFileNames {
                HoverActionButton(
                    systemImage: "shuffle",
                    help: attachment.isFilenameAnonymised ? "Restore file name" : "Randomise file name",
                    isSelected: attachment.isFilenameAnonymised,
                    diameter: controlDiameter,
                    iconFont: .interface(.caption2).weight(.semibold)
                ) {
                    toggleFilenamePrivacy(attachment)
                }
            }
            HoverActionButton(
                systemImage: "pencil",
                help: "Edit attachment",
                diameter: controlDiameter,
                iconFont: .interface(.caption2).weight(.semibold)
            ) {
                edit(attachment.id)
            }
            HoverActionButton(
                systemImage: "trash",
                help: "Delete attachment",
                role: .destructive,
                diameter: controlDiameter,
                iconFont: .interface(.caption2).weight(.semibold)
            ) {
                remove(attachment.id)
            }
        }
    }

    /// Images and text files open in the media viewer.
    private var isViewable: Bool {
        let preview = OptimisticAttachmentPresentation.attachment(for: attachment.url, index: 0)
        return preview.mediaKind == .image || preview.mediaKind == .animatedImage || preview.textPreviewLanguage != nil
    }
}

/// A staged file that is not an image or video: its Finder icon over its
/// type, filling the tile. It also renders the file's flight to the timeline.
struct ComposerAttachmentFileFace: View {
    let url: URL

    var body: some View {
        VStack(spacing: InterfaceScale.metric(4)) {
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data))
                .resizable()
                .scaledToFit()
                .frame(width: InterfaceScale.metric(56), height: InterfaceScale.metric(56))
            if !url.pathExtension.isEmpty {
                Text(url.pathExtension.uppercased())
                    .font(.interface(.caption).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(InterfaceScale.metric(9))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.primary.opacity(0.06))
    }
}

extension ForumPostAttachment {
    /// Images and videos, which fill their tile and fly as their thumbnail.
    var isVisualMedia: Bool {
        let type = UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .image) == true || type?.conforms(to: .movie) == true
    }
}
