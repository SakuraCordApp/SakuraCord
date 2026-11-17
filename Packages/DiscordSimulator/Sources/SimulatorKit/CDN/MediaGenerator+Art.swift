import CoreGraphics
import CoreText
import Foundation

public extension MediaGenerator {
    /// How an avatar or server icon looks.
    enum Art: Sendable, Hashable {
        /// A flat drawing on a solid colour.
        case drawing(EmojiMotif, background: UInt32)
        /// A photo-style picture: a pet, a plant, a place.
        case photo(PhotoScene)
        /// Initials on a solid colour.
        case monogram(String, background: UInt32)
        /// For crowds: motif, colour and pattern picked by the seed, so thousands stay tell-apart-able.
        case crowd
    }

    /// The official client's default-avatar files on discord.com (`/assets/<file>`), in the
    /// order of its `DEFAULT_AVATARS` list (official web client bundle). The bundle has no
    /// colours; each is drawn on the matching one of Discord's six default-avatar colours.
    static let defaultAvatarAssets = ["18e336a74a159cfd.png", "788f05731f8aa02e.png", "9855d7e3b9780976.png",
                                      "2ccd8ae8b2379360.png", "411d8a698dd15ddf.png", "320d5a40d309f942.png"]

    /// Discord's default avatar for an account without one (`/assets/<file>` above, or the older
    /// `/embed/avatars/<index>.png` that bot embeds still use): a plain head-and-shoulders on one of its colours.
    static func defaultAvatarPNG(index: Int, size: Int) -> Data {
        let colors: [UInt32] = [0x5865f2, 0x757e8a, 0x3ba55c, 0xfaa61a, 0xed4245, 0xeb459f]
        return encode(render(size, size) { canvas in
            canvas.rect(RGB(colors[(index % colors.count + colors.count) % colors.count]), 0, 0, 1, 1)
            canvas.ellipse(.white, 0.35, 0.48, 0.3, 0.3)
            canvas.ellipse(.white, 0.22, -0.1, 0.56, 0.5)
        }, as: .png)
    }
}

/// Draws `art` filling the canvas; `phase` gives a drawing a gentle bounce for animated avatars.
func drawArt(_ canvas: Canvas, _ art: MediaGenerator.Art, seed: UInt64, phase: Double) {
    switch art {
    case let .drawing(motif, background):
        canvas.rect(RGB(background), 0, 0, 1, 1)
        drawMotif(canvas, motif, seed: seed, phase: phase, inset: 0.2)
    case let .photo(scene):
        var rng = SeededRandom(seed: seed)
        drawPhoto(canvas, scene: scene, rng: &rng)
    case let .monogram(text, background):
        canvas.rect(RGB(background), 0, 0, 1, 1)
        drawCenteredText(canvas, text, color: RGB(background).mixed(.white, 0.82))
    case .crowd:
        drawCrowd(canvas, seed: seed)
    }
}

/// One of 12 hues × 12 motifs × 3 patterns.
private func drawCrowd(_ canvas: Canvas, seed: UInt64) {
    var rng = SeededRandom(seed: seed).fork("crowd")
    let hues: [UInt32] = [0xc0392b, 0xd35400, 0xc79100, 0x689f38, 0x2e7d32, 0x00897b, 0x0288d1, 0x3949ab, 0x5e35b1, 0x8e24aa, 0xc2185b, 0x6d4c41]
    let glyphs: [MediaGenerator.EmojiMotif] = [.star, .heart, .leaf, .drop, .moon, .note, .sun, .sparkle, .house, .book, .gamepad, .pin]
    let background = RGB(rng.pick(hues))
    canvas.rect(background, 0, 0, 1, 1)
    switch rng.next() % 3 {
    case 0:
        for stripe in stride(from: -1.0, to: 1.0, by: 0.2) {
            canvas.polygon(.white, [(stripe, 0), (stripe + 0.08, 0), (stripe + 1.08, 1), (stripe + 1, 1)], alpha: 0.18)
        }
    case 1:
        for px in stride(from: 0.12, to: 1.0, by: 0.25) {
            for py in stride(from: 0.12, to: 1.0, by: 0.25) { canvas.ellipse(.white, px - 0.035, py - 0.035, 0.07, 0.07, alpha: 0.2) }
        }
    default:
        break
    }
    drawMotif(canvas, rng.pick(glyphs), seed: seed, phase: 0, inset: 0.24, silhouette: .white)
}

private func drawCenteredText(_ canvas: Canvas, _ text: String, color: RGB) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, canvas.side * (text.count > 2 ? 0.3 : 0.38), nil)
    let attributed = NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cg(),
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    canvas.context.textPosition = CGPoint(x: (canvas.width - bounds.width) / 2 - bounds.minX, y: (canvas.height - bounds.height) / 2 - bounds.minY)
    CTLineDraw(line, canvas.context)
}

// MARK: - Pictograms

/// Motifs beyond the emoji set, drawn in the unit square (origin bottom-left).
let pictograms: [MediaGenerator.EmojiMotif: @Sendable (Canvas, MotifStyle) -> Void] = [
    .bread: { canvas, style in
        canvas.ellipse(style.color(0xc98a4b), 0.14, 0.18, 0.72, 0.42)
        canvas.rect(style.color(0xe0a865), 0.12, 0.34, 0.76, 0.3, radius: 0.15)
        for px in [0.3, 0.46, 0.62] { canvas.stroke(style.silhouette ?? RGB(0xa96c33), canvas.side * 0.035, line(canvas, (px, 0.44), (px + 0.08, 0.56))) }
    },
    .shoe: { canvas, style in
        canvas.polygon(style.color(0xff7043), [(0.1, 0.3), (0.1, 0.62), (0.36, 0.64), (0.48, 0.5), (0.9, 0.42), (0.9, 0.3)])
        canvas.rect(style.silhouette ?? .white, 0.08, 0.2, 0.84, 0.1, radius: 0.05)
        for px in [0.3, 0.38] { canvas.stroke(style.silhouette ?? .white, canvas.side * 0.025, line(canvas, (px, 0.6), (px + 0.06, 0.5))) }
    },
    .guitar: { canvas, style in
        canvas.rect(style.color(0x6d4c41), 0.46, 0.45, 0.08, 0.48)
        canvas.ellipse(style.color(0xffb300), 0.24, 0.06, 0.52, 0.42)
        canvas.ellipse(style.color(0xffb300), 0.31, 0.36, 0.38, 0.3)
        canvas.ellipse(style.silhouette ?? RGB(0x3e2723), 0.42, 0.28, 0.16, 0.16)
    },
    .moon: { canvas, style in
        // The moon minus a second disc: clip to everything outside it.
        let outside = CGMutablePath()
        outside.addRect(CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
        outside.addEllipse(in: CGRect(x: canvas.width * 0.36, y: canvas.height * 0.3, width: canvas.width * 0.54, height: canvas.height * 0.54))
        canvas.context.saveGState()
        canvas.context.addPath(outside)
        canvas.context.clip(using: .evenOdd)
        canvas.ellipse(style.color(0xffe082), 0.16, 0.16, 0.6, 0.6)
        canvas.context.restoreGState()
        canvas.ellipse(style.color(0xfff8e1), 0.72, 0.18, 0.08, 0.08)
        canvas.ellipse(style.color(0xfff8e1), 0.84, 0.32, 0.05, 0.05)
    },
    .box: { canvas, style in
        canvas.rect(style.color(0xd7a86e), 0.18, 0.16, 0.64, 0.5)
        canvas.polygon(style.silhouette ?? RGB(0xe8c08a), [(0.14, 0.66), (0.86, 0.66), (0.78, 0.8), (0.22, 0.8)])
        canvas.rect(style.silhouette ?? RGB(0xf5e6c8), 0.45, 0.16, 0.1, 0.64)
    },
    .suitcase: { canvas, style in
        let handle = CGRect(x: canvas.width * 0.38, y: canvas.height * 0.6, width: canvas.width * 0.24, height: canvas.height * 0.2)
        canvas.stroke(style.silhouette ?? RGB(0x004d40), canvas.side * 0.06,
                      CGPath(roundedRect: handle, cornerWidth: canvas.side * 0.05, cornerHeight: canvas.side * 0.05, transform: nil))
        canvas.rect(style.color(0x00897b), 0.16, 0.16, 0.68, 0.48, radius: 0.08)
        canvas.rect(style.silhouette ?? RGB(0x004d40), 0.16, 0.36, 0.68, 0.06)
    },
    .robot: { canvas, style in
        canvas.stroke(style.silhouette ?? RGB(0xe0f7fa), canvas.side * 0.04, line(canvas, (0.5, 0.68), (0.5, 0.84)))
        canvas.ellipse(style.color(0xff4081), 0.44, 0.82, 0.12, 0.12)
        canvas.rect(style.color(0xe0f7fa), 0.18, 0.2, 0.64, 0.5, radius: 0.12)
        canvas.ellipse(style.silhouette ?? RGB(0x006064), 0.3, 0.42, 0.12, 0.12)
        canvas.ellipse(style.silhouette ?? RGB(0x006064), 0.58, 0.42, 0.12, 0.12)
        canvas.rect(style.silhouette ?? RGB(0x006064), 0.38, 0.28, 0.24, 0.05, radius: 0.02)
    },
    .house: { canvas, style in
        canvas.polygon(style.color(0xffcc80), [(0.1, 0.52), (0.5, 0.88), (0.9, 0.52)])
        canvas.rect(style.color(0xf5e6d3), 0.2, 0.12, 0.6, 0.42)
        canvas.rect(style.silhouette ?? RGB(0x6d4c41), 0.42, 0.12, 0.16, 0.26)
        canvas.glow(style.color(0xffeb3b), 0.7, 0.38, radius: 0.12, alpha: 0.6)
        canvas.ellipse(style.color(0xffeb3b), 0.66, 0.34, 0.08, 0.08)
    },
    .book: { canvas, style in
        canvas.polygon(style.silhouette ?? .white, [(0.1, 0.24), (0.5, 0.18), (0.5, 0.78), (0.1, 0.84)])
        canvas.polygon(style.color(0xe3f2fd), [(0.5, 0.18), (0.9, 0.24), (0.9, 0.84), (0.5, 0.78)])
        for py in [0.6, 0.5, 0.4] {
            canvas.stroke(style.silhouette ?? RGB(0x90a4ae), canvas.side * 0.02, line(canvas, (0.18, py + 0.06), (0.42, py + 0.03)))
        }
    },
    .gamepad: { canvas, style in
        canvas.rect(style.color(0xeceff1), 0.1, 0.26, 0.8, 0.44, radius: 0.2)
        canvas.rect(style.silhouette ?? RGB(0x37474f), 0.22, 0.44, 0.18, 0.06)
        canvas.rect(style.silhouette ?? RGB(0x37474f), 0.28, 0.38, 0.06, 0.18)
        canvas.ellipse(style.silhouette ?? RGB(0xe53935), 0.6, 0.46, 0.08, 0.08)
        canvas.ellipse(style.silhouette ?? RGB(0x43a047), 0.7, 0.38, 0.08, 0.08)
    },
    .note: { canvas, style in
        let ink = style.color(0xfff3e0)
        canvas.ellipse(ink, 0.2, 0.14, 0.26, 0.2)
        canvas.rect(ink, 0.4, 0.22, 0.06, 0.62)
        canvas.polygon(ink, [(0.46, 0.84), (0.78, 0.7), (0.78, 0.58), (0.46, 0.7)])
    },
    .laptop: { canvas, style in
        canvas.rect(style.color(0xcfd8dc), 0.2, 0.36, 0.6, 0.42, radius: 0.04)
        canvas.rect(style.silhouette ?? RGB(0x263238), 0.25, 0.41, 0.5, 0.32)
        canvas.polygon(style.color(0xb0bec5), [(0.08, 0.26), (0.92, 0.26), (0.84, 0.36), (0.16, 0.36)])
        canvas.rect(style.silhouette ?? RGB(0x80cbc4), 0.3, 0.6, 0.2, 0.04)
        canvas.rect(style.silhouette ?? RGB(0xffcc80), 0.3, 0.5, 0.3, 0.04)
    },
    .pin: { canvas, style in
        canvas.polygon(style.color(0xe53935), [(0.27, 0.52), (0.73, 0.52), (0.5, 0.1)])
        canvas.ellipse(style.color(0xe53935), 0.24, 0.42, 0.52, 0.48)
        if style.silhouette == nil { canvas.ellipse(.white, 0.4, 0.58, 0.2, 0.2) }
    },
    .play: { canvas, style in
        canvas.rect(style.color(0xff1744), 0.12, 0.22, 0.76, 0.56, radius: 0.16)
        if style.silhouette == nil { canvas.polygon(.white, [(0.42, 0.36), (0.42, 0.64), (0.64, 0.5)]) }
    },
    .globe: { canvas, style in
        canvas.ellipse(style.color(0x42a5f5), 0.12, 0.12, 0.76, 0.76)
        canvas.ellipse(style.silhouette ?? RGB(0x66bb6a), 0.26, 0.42, 0.28, 0.3)
        canvas.ellipse(style.silhouette ?? RGB(0x66bb6a), 0.54, 0.2, 0.22, 0.24)
        canvas.stroke(style.silhouette ?? RGB(0xe3f2fd), canvas.side * 0.02, CGPath(ellipseIn: CGRect(
            x: canvas.width * 0.32, y: canvas.height * 0.12, width: canvas.width * 0.36, height: canvas.height * 0.76), transform: nil), alpha: 0.7)
    },
    .pencil: { canvas, style in
        canvas.context.saveGState()
        canvas.context.translateBy(x: canvas.width / 2, y: canvas.height / 2)
        canvas.context.rotate(by: -.pi / 4)
        canvas.context.translateBy(x: -canvas.width / 2, y: -canvas.height / 2)
        canvas.rect(style.color(0xffca28), 0.4, 0.26, 0.2, 0.52)
        canvas.rect(style.color(0xf48fb1), 0.4, 0.78, 0.2, 0.1, radius: 0.03)
        canvas.polygon(style.color(0xffe0b2), [(0.4, 0.26), (0.6, 0.26), (0.5, 0.08)])
        canvas.context.restoreGState()
    },
    .palette: { canvas, style in
        canvas.ellipse(style.color(0xf3d7b0), 0.1, 0.16, 0.8, 0.68)
        if style.silhouette == nil { canvas.ellipse(RGB(0x8d6e63), 0.56, 0.24, 0.14, 0.14, alpha: 0.5) }
        for (index, hex) in [0xe53935, 0x1e88e5, 0xfdd835, 0x43a047].enumerated() {
            canvas.ellipse(style.silhouette ?? RGB(UInt32(hex)), 0.2 + Double(index) * 0.13, 0.56 - Double(index % 2) * 0.08, 0.12, 0.12)
        }
    },
    .sunflower: { canvas, style in
        for petal in 0 ..< 12 {
            let angle = Double(petal) / 12 * 2 * .pi
            canvas.ellipse(style.color(0xffca28), 0.5 + cos(angle) * 0.28 - 0.1, 0.5 + sin(angle) * 0.28 - 0.1, 0.2, 0.2)
        }
        canvas.ellipse(style.silhouette ?? RGB(0x6d4c41), 0.32, 0.32, 0.36, 0.36)
    },
]

private func line(_ canvas: Canvas, _ from: (Double, Double), _ to: (Double, Double)) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: [canvas.point(from.0, from.1), canvas.point(to.0, to.1)])
    return path
}
