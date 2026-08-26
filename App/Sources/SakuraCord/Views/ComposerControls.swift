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
                        accessibilityCategory: .emoji
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
        .onHover { hovering in
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
                ProgressView(value: total > 0 ? Double(completed) / Double(total) : 0).frame(width: 90)
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

struct ComposerActionButton: View {
    let icon: Image
    let help: String
    var iconSize: CGFloat = 18
    var iconWeight: Font.Weight = .medium
    var size = ChatChromeMetrics.composerControlHeight
    var showsHoverBackground = true
    var appearance: ComposerBarAppearance = .defaultStyle
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            icon
                .symbolVariant(.none)
                .font(.system(size: iconSize, weight: iconWeight))
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .contentShape(buttonShape)
        }
        .buttonStyle(.plain)
        .background(hoverColor, in: buttonShape)
        .contentShape(buttonShape)
        .onHover { isHovering = showsHoverBackground && $0 }
        .help(help)
    }

    private var buttonShape: AnyShape {
        switch appearance {
        case .defaultStyle:
            AnyShape(Circle())
        case .legacy:
            AnyShape(ConcentricRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private var hoverColor: Color {
        showsHoverBackground && isHovering && isEnabled
            ? .primary.opacity(0.14)
            : .clear
    }
}

struct ComposerSendButton: View {
    let action: () -> Void
    var appearance: ComposerBarAppearance = .defaultStyle

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "paperplane.circle.fill")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(isEnabled ? Color.white : Color.gray.opacity(0.62))
                .frame(
                    width: ChatChromeMetrics.composerControlHeight,
                    height: ChatChromeMetrics.composerControlHeight
                )
                .contentShape(buttonShape)
        }
        .buttonStyle(.plain)
        .background(hoverColor, in: buttonShape)
        .contentShape(buttonShape)
        .onHover { isHovering = appearance == .legacy && $0 }
        .help("Send message")
    }

    private var buttonShape: AnyShape {
        switch appearance {
        case .defaultStyle:
            AnyShape(Circle())
        case .legacy:
            AnyShape(ConcentricRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private var hoverColor: Color {
        appearance == .legacy && isHovering && isEnabled
            ? .primary.opacity(0.14)
            : .clear
    }
}
