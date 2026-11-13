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
        let scale: CGFloat
        let appearance: NSAppearance.Name
    }

    private static var images: [Key: NSImage?] = [:]

    /// SF Symbols has no such bell, so `bell.badge.fill` loses its dot to a
    /// "z". Each size, backing scale and appearance is rasterized once.
    static func draw(in frame: CGRect) {
        let appearance = NSAppearance.currentDrawing()
        let scale = NSGraphicsContext.current?.cgContext.convertToDeviceSpace(CGSize(width: 1, height: 1)).height
            .magnitude ?? 2
        let key = Key(side: frame.height, scale: scale, appearance: appearance.name)
        let image: NSImage?
        if let cached = images[key] {
            image = cached
        } else {
            image = makeImage(side: frame.height, scale: scale, appearance: appearance)
            images[key] = image
        }
        guard let image else { return }
        let fit = min(frame.width / image.size.width, frame.height / image.size.height)
        let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        image.draw(
            in: CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
        )
    }

    private static func makeImage(side: CGFloat, scale: CGFloat, appearance: NSAppearance) -> NSImage? {
        var color = NSColor.secondaryLabelColor
        appearance.performAsCurrentDrawingAppearance { color = color.usingColorSpace(.deviceRGB) ?? color }
        let configuration = NSImage.SymbolConfiguration(pointSize: side, weight: .regular)
            .applying(.init(paletteColors: [.clear, color]))
        guard let bell = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return nil }
        let composed = NSImage(size: bell.size, flipped: false) { rect in
            bell.draw(in: rect)
            let letter = NSAttributedString(string: "z", attributes: [
                .font: NSFont.systemFont(ofSize: rect.height * 0.55, weight: .heavy),
                .foregroundColor: color,
            ])
            let size = letter.size()
            letter.draw(at: CGPoint(x: rect.maxX - size.width, y: rect.maxY - size.height + rect.height * 0.06))
            return true
        }
        return NativeTimelineSystemSymbolCache.rasterizedImage(from: composed, scale: scale, appearance: appearance)
    }
}
