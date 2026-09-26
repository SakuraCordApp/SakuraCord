import MessageRendering
import SakuraCordModels
import SwiftUI
import UniformTypeIdentifiers

struct EmojiAutocompleteRow: View {
    let suggestion: ColonAutocompleteSuggestion
    let isSelected: Bool
    let select: () -> Void
    let highlight: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 9) {
                if let url = suggestion.imageURL {
                    AnimatedRemoteImage(
                        url: url,
                    )
                        .frame(width: 28, height: 28)
                } else {
                    Text(suggestion.value)
                        .font(.title3)
                        .frame(width: 28, height: 28)
                }
                Text(suggestion.detail)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 10)
                if let source = suggestion.source {
                    Text(source)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .background {
            ConcentricRectangle(
                cornerRadius: 7,
                style: .continuous
            )
            .fill(isSelected ? Color.primary.opacity(0.13) : .clear)
        }
        .clipShape(
            ConcentricRectangle(
                cornerRadius: 7,
                style: .continuous
            )
        )
        .onModalHover { hovering in
            guard hovering else { return }
            highlight()
        }
    }
}

struct UploadProgressView: View {
    let progress: MessageSendProgress
    var body: some View {
        HStack(spacing: 8) {
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
                    .frame(width: 90)
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
        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
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
    var onHoverChanged: ((Bool) -> Void)?
    let action: (() -> Void)?

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
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
            isHovering = showsHoverBackground && $0
            onHoverChanged?($0)
        }
        .help(help)
    }

    private var buttonLabel: some View {
        icon
            .symbolVariant(.none)
            .font(.system(size: iconSize, weight: iconWeight))
            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
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
            AnyShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
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
    @Environment(\.colorScheme) private var colorScheme
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
        Image(systemName: "paperplane.circle.fill")
            .font(.system(size: 21, weight: .medium))
            .foregroundStyle(
                isEnabled && !isSlowmodeBlocked
                    ? (colorScheme == .dark ? Color.white : Color.black)
                    : Color.gray.opacity(0.62)
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
            AnyShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private var hoverColor: Color {
        appearance == .legacy && isHovering && isEnabled && !isSlowmodeBlocked
            ? .primary.opacity(0.14)
            : .clear
    }
}
