import AppKit
import SakuraCordModels
import SwiftUI

enum DiscordComponentButtonAppearance {
    static func backgroundHex(for style: ComponentButtonStyle?) -> UInt32 {
        switch style ?? .secondary {
        case .primary: 0x5865F2
        case .secondary, .link, .premium: 0x4E5058
        case .success: 0x248046
        case .destructive: 0xDA373C
        }
    }
}

nonisolated enum DiscordComponentEmojiMetrics {
    static let buttonSize: CGFloat = 16
    static let selectSize: CGFloat = 16

    static func opticalSize(for boxSize: CGFloat) -> CGFloat {
        max(0, boxSize - 2)
    }
}

struct DiscordComponentButton: View {
    let style: ComponentButtonStyle?
    let label: String?
    let emoji: EmojiReference?
    let showsExternalLink: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let emoji {
                    ComponentEmojiGlyph(emoji: emoji, size: DiscordComponentEmojiMetrics.buttonSize)
                } else if style == .premium {
                    Image(systemName: "sparkles")
                }
                Text(label ?? "Button")
                    .lineLimit(1)
                if showsExternalLink {
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.bold))
                }
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(DiscordComponentButtonStyle(style: style))
    }
}

private struct DiscordComponentButtonStyle: ButtonStyle {
    let style: ComponentButtonStyle?

    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration, style: style)
    }

    fileprivate struct Body: View {
        let configuration: Configuration
        let style: ComponentButtonStyle?
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(Color.white.opacity(isEnabled ? 1 : 0.62))
                .background(backgroundColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(isHovering && isEnabled ? 0.14 : 0.07))
                }
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .brightness(configuration.isPressed ? -0.07 : isHovering ? 0.035 : 0)
                .opacity(isEnabled ? 1 : 0.65)
                .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
                .onHover { isHovering = $0 }
        }

        private var backgroundColor: Color {
            Color(hex: DiscordComponentButtonAppearance.backgroundHex(for: style))
        }
    }
}

struct DiscordComponentSelect: View {
    let placeholder: String
    let options: [ComponentSelectOption]
    let isDisabled: Bool
    let select: (ComponentSelectOption) -> Void

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    select(option)
                } label: {
                    HStack {
                        if let emoji = option.emoji {
                            ComponentEmojiGlyph(emoji: emoji, size: DiscordComponentEmojiMetrics.selectSize)
                        }
                        VStack(alignment: .leading) {
                            Text(option.label)
                            if let description = option.description {
                                Text(description)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text(placeholder)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 20)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 210, maxWidth: 380, minHeight: 38)
            .background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.primary.opacity(0.16))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(isDisabled)
    }
}

struct ComponentEmojiGlyph: View {
    let emoji: EmojiReference
    let size: CGFloat

    var body: some View {
        Group {
            if emoji.id != nil, let url = emoji.imageURL(size: Int(size * 2)) {
                AnimatedRemoteImage(
                    url: url,
                    isLooping: emoji.isAnimated,
                    fallbackSystemImage: "face.smiling",
                    fallbackInset: 0
                )
                .frame(width: opticalSize, height: opticalSize)
            } else {
                Image(nsImage: ComponentUnicodeEmojiRenderer.image(for: emoji.name))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: opticalSize, height: opticalSize)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(emoji.accessibilityLabel)
    }

    private var opticalSize: CGFloat {
        DiscordComponentEmojiMetrics.opticalSize(for: size)
    }
}

@MainActor
private enum ComponentUnicodeEmojiRenderer {
    private static var cache: [String: NSImage] = [:]
    private static let sourceFontSize: CGFloat = 64
    private static let canvasPadding = 16

    static func image(for value: String) -> NSImage {
        if let cached = cache[value] {
            return cached
        }

        let font = NSFont(name: "Apple Color Emoji", size: sourceFontSize)
            ?? NSFont.systemFont(ofSize: sourceFontSize)
        let attributed = NSAttributedString(string: value, attributes: [.font: font])
        let measured = attributed.size()
        let width = max(1, Int(ceil(measured.width)) + canvasPadding * 2)
        let height = max(1, Int(ceil(measured.height)) + canvasPadding * 2)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        bitmap.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.current = context
            NSColor.clear.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            attributed.draw(at: NSPoint(x: canvasPadding, y: canvasPadding))
            context.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let crop = opaqueBounds(in: bitmap),
              let cgImage = bitmap.cgImage?.cropping(to: crop)
        else {
            return NSImage(size: NSSize(width: 1, height: 1))
        }
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: crop.width, height: crop.height)
        )
        cache[value] = image
        return image
    }

    private static func opaqueBounds(in bitmap: NSBitmapImageRep) -> CGRect? {
        guard let data = bitmap.bitmapData else { return nil }
        let bytesPerPixel = max(1, bitmap.bitsPerPixel / 8)
        let alphaOffset = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : bytesPerPixel - 1
        let alphaThreshold: UInt8 = 5
        var minimumX = bitmap.pixelsWide
        var minimumY = bitmap.pixelsHigh
        var maximumX = -1
        var maximumY = -1

        for y in 0 ..< bitmap.pixelsHigh {
            let row = data.advanced(by: y * bitmap.bytesPerRow)
            for x in 0 ..< bitmap.pixelsWide
            where row[x * bytesPerPixel + alphaOffset] > alphaThreshold {
                minimumX = min(minimumX, x)
                minimumY = min(minimumY, y)
                maximumX = max(maximumX, x)
                maximumY = max(maximumY, y)
            }
        }
        guard maximumX >= minimumX, maximumY >= minimumY else { return nil }
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX + 1,
            height: maximumY - minimumY + 1
        )
    }
}
