import SakuraCordModels
import SwiftUI

struct ComposerAttachmentTray: View {
    static var thumbnailCornerRadius: CGFloat { InterfaceScale.metric(16) }

    @AppStorage(PrivacySafetySettingsStore.anonymiseFileNamesKey, store: PRBuildProfile.defaults) private var anonymisesFileNames = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let attachments: [ForumPostAttachment]
    var sendTransitionAnchor: ComposerSendTransitionAnchor?
    let open: (UUID) -> Void
    let toggleSpoiler: (UUID) -> Void
    let update: (ForumPostAttachment) -> Void
    let remove: (UUID) -> Void
    @State private var hoveredID: UUID?
    @State private var editingTarget: ComposerAttachmentEditorTarget?
    @State private var hasAppeared = false

    private let tileSize: CGFloat = InterfaceScale.metric(230)
    private let filenameRowHeight: CGFloat = InterfaceScale.metric(38)

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: InterfaceScale.metric(12)) {
                ForEach(attachments) { attachment in
                    attachmentTile(attachment)
                        .id(attachment.id)
                }
            }
            .padding(.horizontal, InterfaceScale.metric(14))
            .padding(.vertical, InterfaceScale.metric(14))
        }
        .scrollIndicators(.hidden)
        .frame(height: reduceMotion || hasAppeared ? tileSize + 28 : 0)
        .opacity(reduceMotion || hasAppeared ? 1 : 0)
        .accessibilityLabel("Message attachments")
        .onAppear {
            guard !hasAppeared else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.18)) {
                hasAppeared = true
            }
        }
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

    private func attachmentTile(_ attachment: ForumPostAttachment) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            attachmentPreview(attachment)
            Text(attachment.filename)
                .font(.interface(.callout).weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, InterfaceScale.metric(14))
                .frame(
                    width: tileSize,
                    height: filenameRowHeight,
                    alignment: .leading
                )
        }
            .frame(width: tileSize, height: tileSize, alignment: .topLeading)
            .background(.primary.opacity(0.035))
            .clipShape(ConcentricRectangle(cornerRadius: InterfaceScale.metric(16), style: .continuous))
            .overlay {
                ConcentricRectangle(cornerRadius: InterfaceScale.metric(16), style: .continuous)
                    .stroke(.separator, lineWidth: 1)
            }
            .contentShape(ConcentricRectangle(cornerRadius: InterfaceScale.metric(14), style: .continuous))
            .onModalHover { hovering in
                hoveredID =
                    hovering
                        ? attachment.id
                        : (hoveredID == attachment.id ? nil : hoveredID)
            }
            .help(attachment.filename)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(attachment.filename)
            .accessibilityAction(named: "Open attachment") {
                guard attachmentMediaKind(attachment).isViewableImage else { return }
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
                editingTarget = ComposerAttachmentEditorTarget(id: attachment.id)
            }
            .accessibilityAction(named: "Delete attachment") {
                remove(attachment.id)
            }
    }

    private func attachmentPreview(
        _ attachment: ForumPostAttachment
    ) -> some View {
        ZStack {
            LocalAttachmentThumbnail(
                url: attachment.url,
                maximumPixelDimension: 480,
                preservesImageAspectRatio: true,
                imageCornerRadius: Self.thumbnailCornerRadius,
                animatesImageAppearance: true,
                onImageLoaded: { [sendTransitionAnchor] image in
                    sendTransitionAnchor?.recordAttachmentThumbnail(image, for: attachment.id)
                }
            )
            .background {
                ComposerSendTransitionAttachmentReader(anchor: sendTransitionAnchor, id: attachment.id)
            }
            .padding(.horizontal, InterfaceScale.metric(10))
            .padding(.vertical, InterfaceScale.metric(8))

            if attachment.isSpoiler {
                Rectangle()
                    .fill(.black.opacity(0.58))
                VStack(spacing: InterfaceScale.metric(5)) {
                    Image(systemName: "eye.slash")
                    Text("SPOILER")
                        .font(.interface(.caption2).weight(.bold))
                }
                .foregroundStyle(.white)
            }
        }
        .frame(width: tileSize, height: tileSize - filenameRowHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            guard attachmentMediaKind(attachment).isViewableImage else { return }
            open(attachment.id)
        }
        .overlay(alignment: .topTrailing) {
            if hoveredID == attachment.id {
                attachmentActions(attachment)
                    .padding(InterfaceScale.metric(7))
            }
        }
    }

    private func attachmentActions(
        _ attachment: ForumPostAttachment
    ) -> some View {
        HoverActionPill(
            glass: .regular.interactive(),
            spacing: 1,
            padding: 3
        ) {
            HoverActionButton(
                systemImage: attachment.isSpoiler ? "eye.slash" : "eye",
                help: attachment.isSpoiler ? "Remove spoiler" : "Mark as spoiler",
                isSelected: attachment.isSpoiler,
                diameter: InterfaceScale.metric(22),
                iconFont: .interface(.caption2).weight(.semibold)
            ) {
                toggleSpoiler(attachment.id)
            }
            if anonymisesFileNames {
                HoverActionButton(
                    systemImage: "shuffle",
                    help: attachment.isFilenameAnonymised ? "Restore file name" : "Randomise file name",
                    isSelected: attachment.isFilenameAnonymised,
                    diameter: InterfaceScale.metric(22),
                    iconFont: .interface(.caption2).weight(.semibold)
                ) {
                    toggleFilenamePrivacy(attachment)
                }
            }
            HoverActionButton(
                systemImage: "pencil",
                help: "Edit attachment",
                diameter: InterfaceScale.metric(22),
                iconFont: .interface(.caption2).weight(.semibold)
            ) {
                editingTarget = ComposerAttachmentEditorTarget(id: attachment.id)
            }
            HoverActionButton(
                systemImage: "trash",
                help: "Delete attachment",
                role: .destructive,
                diameter: InterfaceScale.metric(22),
                iconFont: .interface(.caption2).weight(.semibold)
            ) {
                remove(attachment.id)
            }
        }
    }

    private func toggleFilenamePrivacy(_ attachment: ForumPostAttachment) {
        var updated = attachment
        updated.setFilenameAnonymised(!attachment.isFilenameAnonymised)
        update(updated)
    }

    private func attachmentMediaKind(
        _ attachment: ForumPostAttachment
    ) -> AttachmentMediaKind {
        OptimisticAttachmentPresentation.attachment(
            for: attachment.url,
            index: 0
        ).mediaKind
    }
}

private extension AttachmentMediaKind {
    var isViewableImage: Bool {
        self == .image || self == .animatedImage
    }
}
