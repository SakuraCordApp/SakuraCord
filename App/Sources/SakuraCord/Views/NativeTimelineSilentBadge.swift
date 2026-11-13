import AppKit

/// Discord's badge for a message sent with `@silent`: a bell whose badge is a
/// "z", 4/3 of the timestamp's size, with the tooltip below.
enum NativeTimelineSilentBadge {
    static let help = "This is a @silent message."
    static var spacing: CGFloat { InterfaceScale.metric(5) }

    static func side(for timestampFont: NSFont) -> CGFloat {
        (timestampFont.pointSize * 4 / 3).rounded()
    }

    private struct Key: Hashable {
        let side: CGFloat
        let appearance: NSAppearance.Name
    }

    private static var images: [Key: NSImage] = [:]

    /// SF Symbols has no such bell, so `bell.badge.fill` loses its dot to a
    /// "z". Each size and appearance is composed once, then drawn from the
    /// image's cached bitmap.
    static func draw(in frame: CGRect) {
        let appearance = NSAppearance.currentDrawing()
        let key = Key(side: frame.height, appearance: appearance.name)
        let image = images[key] ?? makeImage(side: frame.height, appearance: appearance)
        images[key] = image
        guard let image else { return }
        let scale = min(frame.width / image.size.width, frame.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(
            in: CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
        )
    }

    private static func makeImage(side: CGFloat, appearance: NSAppearance) -> NSImage? {
        var color = NSColor.secondaryLabelColor
        appearance.performAsCurrentDrawingAppearance { color = color.usingColorSpace(.deviceRGB) ?? color }
        let configuration = NSImage.SymbolConfiguration(pointSize: side, weight: .regular)
            .applying(.init(paletteColors: [.clear, color]))
        guard let bell = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return nil }
        return NSImage(size: bell.size, flipped: false) { rect in
            bell.draw(in: rect)
            let letter = NSAttributedString(string: "z", attributes: [
                .font: NSFont.systemFont(ofSize: rect.height * 0.55, weight: .heavy),
                .foregroundColor: color,
            ])
            let size = letter.size()
            letter.draw(at: CGPoint(x: rect.maxX - size.width, y: rect.maxY - size.height + rect.height * 0.06))
            return true
        }
    }
}
