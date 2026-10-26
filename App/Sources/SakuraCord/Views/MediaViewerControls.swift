import SwiftUI

nonisolated enum MediaViewerThumbnailMetrics {
    static var width: CGFloat { InterfaceScale.metric(58) }
    static var height: CGFloat { InterfaceScale.metric(42) }
    static var spacing: CGFloat { InterfaceScale.metric(6) }
    static var edgePadding: CGFloat { InterfaceScale.metric(3) }
    static var cornerRadius: CGFloat { InterfaceScale.metric(7) }
    static var selectedBorderWidth: CGFloat { InterfaceScale.metric(3) }
    static let ordinaryBorderWidth: CGFloat = 1
    static var railHeight: CGFloat { height + edgePadding * 2 }

    static func contentWidth(itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return 0 }
        return CGFloat(itemCount) * width
            + CGFloat(itemCount - 1) * spacing
            + edgePadding * 2
    }

    static func railWidth(itemCount: Int, maximumWidth: CGFloat) -> CGFloat {
        min(contentWidth(itemCount: itemCount), max(0, maximumWidth))
    }
}

nonisolated enum MediaViewerTopChromeMetrics {
    static var outerPadding: CGFloat { InterfaceScale.metric(18) }
    static var height: CGFloat { InterfaceScale.metric(36) }
    static var avatarDiameter: CGFloat { height }
    static var actionDiameter: CGFloat { InterfaceScale.metric(28) }
    static var actionPadding: CGFloat { InterfaceScale.metric(4) }
    static var mediaTopInset: CGFloat { outerPadding + height + outerPadding }
}

struct MediaViewerHeader: View {
    var authorFontID: Int?
    let authorName: String
    let authorAvatarURL: URL?
    let timestamp: Date
    let selection: Int
    let itemCount: Int

    var body: some View {
        HStack(spacing: InterfaceScale.metric(10)) {
            AvatarView(
                name: authorName,
                url: authorAvatarURL,
                size: MediaViewerTopChromeMetrics.avatarDiameter
            )
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: InterfaceScale.metric(6)) {
                    Text(authorName)
                        .displayNameFont(authorFontID, textStyle: .callout)
                        .lineLimit(1)
                    if itemCount > 1 {
                        Text("\(selection + 1) / \(itemCount)")
                            .font(.interface(.caption).weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(
                    timestamp,
                    format: .dateTime.day().month().year().hour().minute()
                )
                .font(.interface(.caption))
                .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.75), radius: InterfaceScale.metric(8), y: 2)
        .frame(
            maxWidth: InterfaceScale.metric(260),
            minHeight: MediaViewerTopChromeMetrics.height,
            maxHeight: MediaViewerTopChromeMetrics.height,
            alignment: .leading
        )
    }
}
struct MediaViewerTopControls: View {
    let item: RichMediaItem
    let isSaving: Bool
    let copyImage: () -> Void
    let copyLink: () -> Void
    let copyAttachmentID: () -> Void
    let saveActions: MediaSaveMenuActions
    let open: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: InterfaceScale.metric(10)) {
            HoverActionPill(
                spacing: 1,
                padding: MediaViewerTopChromeMetrics.actionPadding
            ) {
                ShareLink(item: item.url) {
                    viewerActionLabel(systemImage: "arrowshape.turn.up.right")
                }
                .buttonStyle(.plain)
                .help("Share")
                .accessibilityLabel("Share")

                if item.canSave {
                    Button {
                        MediaSaveMenuBuilder.popUp(actions: saveActions)
                    } label: {
                        HoverActionControlLabel(
                            diameter: MediaViewerTopChromeMetrics.actionDiameter
                        ) {
                            if isSaving {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.down.to.line")
                                    .symbolVariant(.none)
                                    .font(.interface(.callout).weight(.medium))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving)
                    .help("Save Media")
                    .accessibilityLabel("Save Media")
                }

                HoverActionButton(
                    systemImage: "arrow.up.forward.app",
                    help: "Open in Browser",
                    diameter: MediaViewerTopChromeMetrics.actionDiameter,
                    action: open
                )

                MediaViewerMoreMenuButton(
                    item: item,
                    copyImage: copyImage,
                    copyLink: copyLink,
                    copyAttachmentID: copyAttachmentID,
                    saveActions: saveActions,
                    open: open
                )
                .frame(
                    width: MediaViewerTopChromeMetrics.actionDiameter,
                    height: MediaViewerTopChromeMetrics.actionDiameter
                )
            }

            HoverActionPill(
                spacing: 0,
                padding: MediaViewerTopChromeMetrics.actionPadding
            ) {
                HoverActionButton(
                    systemImage: "xmark",
                    help: "Close",
                    diameter: MediaViewerTopChromeMetrics.actionDiameter,
                    iconFont: .interface(.body).weight(.semibold),
                    action: close
                )
                .keyboardShortcut(.cancelAction)
            }
        }
        .foregroundStyle(.white)
    }

    private func viewerActionLabel(systemImage: String) -> some View {
        HoverActionControlLabel(
            diameter: MediaViewerTopChromeMetrics.actionDiameter
        ) {
            Image(systemName: systemImage)
                .symbolVariant(.none)
                .font(.interface(.callout).weight(.medium))
        }
    }
}

struct MediaViewerNavigationButtons: View {
    let canMoveBackward: Bool
    let canMoveForward: Bool
    let moveBackward: () -> Void
    let moveForward: () -> Void

    var body: some View {
        HStack {
            if canMoveBackward {
                HoverActionPill {
                    HoverActionButton(
                        systemImage: "chevron.left",
                        help: "Previous Media",
                        iconFont: .interface(.title3).weight(.semibold),
                        action: moveBackward
                    )
                }
            } else {
                Color.clear.frame(width: InterfaceScale.metric(36), height: InterfaceScale.metric(36))
            }
            Spacer()
            if canMoveForward {
                HoverActionPill {
                    HoverActionButton(
                        systemImage: "chevron.right",
                        help: "Next Media",
                        iconFont: .interface(.title3).weight(.semibold),
                        action: moveForward
                    )
                }
            } else {
                Color.clear.frame(width: InterfaceScale.metric(36), height: InterfaceScale.metric(36))
            }
        }
        .foregroundStyle(.white)
    }
}

struct MediaViewerThumbnailStrip: View {
    let items: [RichMediaItem]
    let selection: Int
    let maximumWidth: CGFloat
    let select: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: MediaViewerThumbnailMetrics.spacing) {
                    ForEach(items.enumerated(), id: \.element.id) { index, item in
                        MediaViewerThumbnail(
                            item: item,
                            isSelected: index == selection,
                            select: { select(index) }
                        )
                        .id(item.id)
                    }
                }
                .padding(MediaViewerThumbnailMetrics.edgePadding)
            }
            .scrollIndicators(.hidden)
            .frame(
                width: MediaViewerThumbnailMetrics.railWidth(
                    itemCount: items.count,
                    maximumWidth: maximumWidth
                ),
                height: MediaViewerThumbnailMetrics.railHeight
            )
            .onAppear {
                scrollToSelection(using: proxy, animated: false)
            }
            .onChange(of: selection) { _, index in
                guard items.indices.contains(index) else { return }
                scrollToSelection(using: proxy, animated: true)
            }
        }
    }

    private func scrollToSelection(
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        guard items.indices.contains(selection) else { return }
        if animated {
            withAnimation(.snappy(duration: 0.2)) {
                proxy.scrollTo(items[selection].id, anchor: .center)
            }
        } else {
            proxy.scrollTo(items[selection].id, anchor: .center)
        }
    }
}

private struct MediaViewerThumbnail: View {
    let item: RichMediaItem
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            ZStack {
                Color.black.opacity(0.55)
                switch item.kind {
                case let .image(animated):
                    AnimatedRemoteImage(
                        url: item.previewURL ?? item.url,
                        animates: animated,
                        maximumPixelDimension: 160,
                        contentMode: .fill
                    )
                case .video, .youtube:
                    if let posterURL = item.videoPosterURL(maximumPixelDimension: 160) {
                        AnimatedRemoteImage(
                            url: posterURL,
                            animates: false,
                            maximumPixelDimension: 160,
                            contentMode: .fill
                        )
                    }
                    Image(systemName: "play.fill")
                        .font(.interface(.title3))
                        .shadow(radius: InterfaceScale.metric(2))
                case .audio:
                    Image(systemName: "waveform")
                        .font(.interface(.title3))
                case .file:
                    Image(systemName: "doc.fill")
                        .font(.interface(.title3))
                }
            }
            .frame(
                width: MediaViewerThumbnailMetrics.width,
                height: MediaViewerThumbnailMetrics.height
            )
            .clipShape(thumbnailShape)
            .overlay {
                thumbnailShape
                    .strokeBorder(
                        isSelected
                            ? SakuraCordAccentColor.color
                            : Color.white.opacity(0.16),
                        lineWidth: isSelected
                            ? MediaViewerThumbnailMetrics.selectedBorderWidth
                            : MediaViewerThumbnailMetrics.ordinaryBorderWidth
                    )
            }
            .contentShape(thumbnailShape)
        }
        .buttonStyle(.plain)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var thumbnailShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: MediaViewerThumbnailMetrics.cornerRadius,
            style: .continuous
        )
    }
}

struct MediaViewerFeedbackPill: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.interface(.callout).weight(.semibold))
            .padding(.horizontal, InterfaceScale.metric(14))
            .padding(.vertical, InterfaceScale.metric(9))
            .glassEffect(.regular, in: Capsule())
            .foregroundStyle(.white)
    }
}
