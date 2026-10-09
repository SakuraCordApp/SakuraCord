import MessageRendering
import SakuraCordModels
import SwiftUI
import UniformTypeIdentifiers

struct EmojiAutocompleteRow: View {
    let suggestion: ColonAutocompleteSuggestion
    let isSelected: Bool
    let select: () -> Void
    var cornerRadius: CGFloat = ChatChromeMetrics.composerCornerRadius - 6

    var body: some View {
        Button(action: select) {
            HStack(spacing: InterfaceScale.metric(9)) {
                if let url = suggestion.imageURL {
                    AnimatedRemoteImage(
                        url: url,
                    )
                        .frame(width: InterfaceScale.metric(28), height: InterfaceScale.metric(28))
                } else {
                    Text(suggestion.value)
                        .font(.interface(.title3))
                        .frame(width: InterfaceScale.metric(28), height: InterfaceScale.metric(28))
                }
                Text(suggestion.detail)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: InterfaceScale.metric(10))
                if let source = suggestion.source {
                    Text(source)
                        .font(.interface(.callout))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, InterfaceScale.metric(9))
            .frame(height: InterfaceScale.metric(40))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .background {
            ConcentricRectangle(
                cornerRadius: cornerRadius,
                style: .continuous
            )
            .fill(isSelected ? Color.primary.opacity(0.13) : .clear)
        }
        .clipShape(
            ConcentricRectangle(
                cornerRadius: cornerRadius,
                style: .continuous
            )
        )
    }
}

struct UploadProgressView: View {
    let progress: MessageSendProgress
    var body: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            switch progress {
            case .preparing:
                ProgressView()
                Text("Preparing attachments…")
            case let .reserving(files):
                ProgressView()
                Text("Reserving \(files) file\(files == 1 ? "" : "s")…")
            case let .uploading(fileName, completed, total):
                ProgressView(value: total > 0 ? Double(completed) / Double(total) : 0)
                    .tint(SakuraCordAccentColor.color)
                    .frame(width: InterfaceScale.metric(90))
                Text("Uploading \(fileName)…").lineLimit(1)
            case .submitting:
                ProgressView()
                Text("Sending message…")
            case .awaitingReconciliation:
                Image(systemName: "clock")
                Text("Waiting for confirmation — do not resend")
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Sent")
            }
        }
        .font(.interface(.caption)).foregroundStyle(.secondary).padding(.horizontal, InterfaceScale.metric(6))
    }
}

struct ComposerAttachmentButton: View {
    let appearance: ComposerBarAppearance
    let action: (() -> Void)?

    var body: some View {
        ComposerActionButton(
            icon: Image(systemName: "plus"),
            help: "Add attachments",
            showsHoverBackground: appearance == .legacy,
            appearance: appearance,
            action: action
        )
    }
}

struct ComposerActionButton: View {
    let icon: Image
    let help: String
    var isActive = false
    /// Replaces `icon` for glyphs that aren't symbols, such as the GIF label.
    var customGlyph: AnyView?
    var iconSize: CGFloat = 17
    var iconWeight: Font.Weight = .regular
    var size = ChatChromeMetrics.composerControlHeight
    var showsHoverBackground = true
    var appearance: ComposerBarAppearance = .defaultStyle
    var cornerRadius: CGFloat?
    var onHoverChanged: ((Bool) -> Void)?
    let action: (() -> Void)?

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { buttonLabel }
            } else {
                buttonLabel
            }
        }
        .buttonStyle(.plain)
        .background(hoverColor, in: buttonShape)
        .contentShape(buttonShape)
        .onModalHover {
            isHovering = $0
            onHoverChanged?($0)
        }
        .help(help)
    }

    private var buttonLabel: some View {
        Group {
            if let customGlyph {
                customGlyph
            } else {
                icon.symbolVariant(.none)
            }
        }
            .font(.interfaceSystem(size: iconSize, weight: iconWeight))
            .foregroundStyle(iconStyle)
            .frame(width: size, height: size)
            .contentShape(buttonShape)
    }

    private var buttonShape: AnyShape {
        if let cornerRadius {
            return switch appearance {
            case .defaultStyle:
                AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            case .legacy:
                AnyShape(ConcentricRectangle(
                    corners: .concentric(minimum: .fixed(cornerRadius)),
                    isUniform: true
                ))
            }
        }
        return switch appearance {
        case .defaultStyle:
            AnyShape(Circle())
        case .legacy:
            AnyShape(RoundedRectangle(cornerRadius: InterfaceScale.metric(9), style: .continuous))
        }
    }

    private var iconStyle: AnyShapeStyle {
        if isActive { return AnyShapeStyle(.tint) }
        return isHovering && isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    private var hoverColor: Color {
        showsHoverBackground && isHovering && isEnabled
            ? .primary.opacity(0.14)
            : .clear
    }
}

struct ComposerSendButton: View {
    let action: (() -> Void)?
    var appearance: ComposerBarAppearance = .defaultStyle

    var isSlowmodeBlocked = false

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { buttonLabel }
            } else {
                buttonLabel
            }
        }
        .buttonStyle(.plain)
        .background(hoverColor, in: buttonShape)
        .contentShape(buttonShape)
        .onModalHover { isHovering = appearance == .legacy && $0 }
        .help("Send message")
    }

    private var buttonLabel: some View {
        Image(systemName: "arrow.up.circle.fill")
            .font(.interfaceSystem(size: 22, weight: .regular))
            .foregroundStyle(
                isEnabled && !isSlowmodeBlocked
                    ? AnyShapeStyle(.tint)
                    : AnyShapeStyle(.tertiary)
            )
            .frame(
                width: ChatChromeMetrics.composerControlHeight,
                height: ChatChromeMetrics.composerControlHeight
            )
            .contentShape(buttonShape)
    }

    private var buttonShape: AnyShape {
        switch appearance {
        case .defaultStyle:
            AnyShape(Circle())
        case .legacy:
            AnyShape(RoundedRectangle(cornerRadius: InterfaceScale.metric(9), style: .continuous))
        }
    }

    private var hoverColor: Color {
        appearance == .legacy && isHovering && isEnabled && !isSlowmodeBlocked
            ? .primary.opacity(0.14)
            : .clear
    }
}
