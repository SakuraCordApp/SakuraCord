import SwiftUI

nonisolated enum MediaViewerTopChromeMetrics {
    static let outerPadding: CGFloat = 18
    static let height: CGFloat = 36
    static let avatarDiameter = height
    static let actionDiameter: CGFloat = 28
    static let actionPadding: CGFloat = 4
    static let mediaTopInset = outerPadding + height + outerPadding
}

struct MediaViewerHeader: View {
    let authorName: String
    let authorAvatarURL: URL?
    let timestamp: Date
    let selection: Int
    let itemCount: Int

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(
                name: authorName,
                url: authorAvatarURL,
                size: MediaViewerTopChromeMetrics.avatarDiameter
            )
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(authorName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if itemCount > 1 {
                        Text("\(selection + 1) / \(itemCount)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(
                    timestamp,
                    format: .dateTime.day().month().year().hour().minute()
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.75), radius: 8, y: 2)
        .frame(
            maxWidth: 260,
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
    let save: () -> Void
    let open: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
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

                Button(action: save) {
                    HoverActionControlLabel(
                        diameter: MediaViewerTopChromeMetrics.actionDiameter
                    ) {
                        if isSaving {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.down.to.line")
                                .symbolVariant(.none)
                                .font(.callout.weight(.medium))
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
                .help("Save Media")
                .accessibilityLabel("Save Media")

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
                    save: save,
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
                    iconFont: .body.weight(.semibold),
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
                .font(.callout.weight(.medium))
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
                        iconFont: .title3.weight(.semibold),
                        action: moveBackward
                    )
                }
            } else {
                Color.clear.frame(width: 36, height: 36)
            }
            Spacer()
            if canMoveForward {
                HoverActionPill {
                    HoverActionButton(
                        systemImage: "chevron.right",
                        help: "Next Media",
                        iconFont: .title3.weight(.semibold),
                        action: moveForward
                    )
                }
            } else {
                Color.clear.frame(width: 36, height: 36)
            }
        }
        .foregroundStyle(.white)
    }
}

struct MediaViewerThumbnailStrip: View {
    let items: [RichMediaItem]
    let selection: Int
    let select: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(items.enumerated(), id: \.element.id) { index, item in
                        MediaViewerThumbnail(
                            item: item,
                            isSelected: index == selection,
                            select: { select(index) }
                        )
                        .id(item.id)
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .glassEffect(.regular, in: Capsule())
            .onChange(of: selection) { _, index in
                guard items.indices.contains(index) else { return }
                withAnimation(.snappy(duration: 0.2)) {
                    proxy.scrollTo(items[index].id, anchor: .center)
                }
            }
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
                case .video:
                    Image(systemName: "play.fill")
                        .font(.title3)
                case .audio:
                    Image(systemName: "waveform")
                        .font(.title3)
                case .file:
                    Image(systemName: "doc.fill")
                        .font(.title3)
                }
            }
            .frame(width: 58, height: 42)
            .clipShape(ConcentricRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                ConcentricRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor : Color.white.opacity(0.16),
                        lineWidth: isSelected ? 2.5 : 1
                    )
            }
            .contentShape(ConcentricRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct MediaViewerFeedbackPill: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: Capsule())
            .foregroundStyle(.white)
    }
}
