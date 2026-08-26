import SakuraCordModels
import SwiftUI

struct ComposerAttachmentTray: View {
    let attachments: [ForumPostAttachment]
    let open: (UUID) -> Void
    let toggleSpoiler: (UUID) -> Void
    let update: (ForumPostAttachment) -> Void
    let remove: (UUID) -> Void
    @State private var hoveredID: UUID?
    @State private var editingTarget: ComposerAttachmentEditorTarget?

    private let tileSize: CGFloat = 230
    private let filenameRowHeight: CGFloat = 38

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(attachments) { attachment in
                    attachmentTile(attachment)
                        .id(attachment.id)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .scrollIndicators(.hidden)
        .frame(height: tileSize + 28)
        .accessibilityLabel("Message attachments")
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
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 14)
                .frame(
                    width: tileSize,
                    height: filenameRowHeight,
                    alignment: .leading
                )
        }
            .frame(width: tileSize, height: tileSize, alignment: .topLeading)
            .background(.primary.opacity(0.035))
            .clipShape(ConcentricRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                ConcentricRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.separator, lineWidth: 1)
            }
            .contentShape(ConcentricRectangle(cornerRadius: 14, style: .continuous))
            .onHover { hovering in
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
                imageCornerRadius: 16
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if attachment.isSpoiler {
                Rectangle()
                    .fill(.black.opacity(0.58))
                VStack(spacing: 5) {
                    Image(systemName: "eye.slash")
                    Text("SPOILER")
                        .font(.caption2.weight(.bold))
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
                    .padding(7)
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
                diameter: 22,
                iconFont: .caption2.weight(.semibold)
            ) {
                toggleSpoiler(attachment.id)
            }
            HoverActionButton(
                systemImage: "pencil",
                help: "Edit attachment",
                diameter: 22,
                iconFont: .caption2.weight(.semibold)
            ) {
                editingTarget = ComposerAttachmentEditorTarget(id: attachment.id)
            }
            HoverActionButton(
                systemImage: "trash",
                help: "Delete attachment",
                role: .destructive,
                diameter: 22,
                iconFont: .caption2.weight(.semibold)
            ) {
                remove(attachment.id)
            }
        }
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
