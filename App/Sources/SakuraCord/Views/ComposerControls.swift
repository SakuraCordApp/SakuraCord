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
            case let .uploading(_, fileName, completed, total):
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
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
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
            iconSize: 19,
            iconWeight: .regular,
            showsHoverBackground: appearance == .legacy,
            appearance: appearance,
            action: action
        )
    }
}

struct ComposerActionButton: View {
    let icon: Image
    let help: String
    var iconSize: CGFloat = 18
    var iconWeight: Font.Weight = .medium
    var size = ChatChromeMetrics.composerControlHeight
    var showsHoverBackground = true
    var appearance: ComposerBarAppearance = .defaultStyle
    var cornerRadius: CGFloat?
    /// A destructive button is tinted red, like the message delete action.
    var role: ButtonRole?
    var onHoverChanged: ((Bool) -> Void)?
    let action: (() -> Void)?

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        Group {
            if let action {
                Button(role: role, action: action) { buttonLabel }
            } else {
                buttonLabel
            }
        }
        .buttonStyle(.plain)
        .background(hoverColor, in: buttonShape)
        .contentShape(buttonShape)
        .onModalHover {
            isHovering = showsHoverBackground && $0
            onHoverChanged?($0)
        }
        .help(help)
    }

    private var buttonLabel: some View {
        icon
            // The grinning face otherwise substitutes filled artwork in dark mode.
            .environment(\.colorScheme, icon == SakuraCordSystemSymbol.emojiFaceGrinningImage ? .light : colorScheme)
            .symbolVariant(.none)
            .font(.interfaceSystem(size: iconSize, weight: iconWeight))
            .foregroundStyle(iconColor)
            .frame(width: size, height: size)
            .contentShape(buttonShape)
    }

    private var iconColor: Color {
        if role == .destructive { return .red }
        return colorScheme == .dark ? .white : .black
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

    private var hoverColor: Color {
        guard showsHoverBackground, isHovering, isEnabled else { return .clear }
        return role == .destructive ? .red.opacity(0.18) : .primary.opacity(0.14)
    }
}
