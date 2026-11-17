import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Deterministic generated images: the same arguments always give the same
/// bytes. Everything is drawn with CoreGraphics from a `SeededRandom` stream.
public enum MediaGenerator {
    public enum PhotoScene: String, Sendable, Hashable, CaseIterable {
        case landscape, sunset, food, cake, plant, cat, dog, city, couch, bike, medal, desk, garden
    }

    /// Flat drawings for emoji, avatars and server icons.
    public enum EmojiMotif: String, Sendable, Hashable, CaseIterable {
        case smile, heart, star, leaf, frog, cat, sparkle, drop, flower, bee, sun, couch
        case bread, shoe, guitar, moon, box, suitcase, robot, house, book, gamepad, note, laptop, pin, play, globe, pencil, palette, sunflower

        /// The ones custom emoji are drawn from.
        static let emoji: [EmojiMotif] = [.smile, .heart, .star, .leaf, .frog, .cat, .sparkle, .drop, .flower, .bee, .sun, .couch]
    }

    /// An avatar: `art` when one was picked for the person, otherwise a crowd avatar from the seed.
    public static func avatarPNG(seed: UInt64, size: Int, art: Art? = nil) -> Data {
        encode(render(size, size) { drawArt($0, art ?? .crowd, seed: seed, phase: 0) }, as: .png)
    }

    /// A server, group or badge icon: `art` when picked, otherwise soft petals in `palette`.
    public static func guildIconPNG(seed: UInt64, size: Int, art: Art? = nil, palette: Int? = nil) -> Data {
        encode(render(size, size) { canvas in
            if let art { drawArt(canvas, art, seed: seed, phase: 0) } else { drawGuildIcon(canvas, seed: seed, palette: palette) }
        }, as: .png)
    }

    public static func bannerPNG(width: Int, height: Int, seed: UInt64, palette: Int? = nil) -> Data {
        encode(render(width, height) { drawBanner($0, seed: seed, palette: palette) }, as: .png)
    }

    /// A pleasant, photo-like scene; `scene` defaults to one picked by `seed`.
    public static func photoJPEG(seed: UInt64, width: Int, height: Int, scene: PhotoScene? = nil) -> Data {
        var rng = SeededRandom(seed: seed)
        let scene = scene ?? rng.pick(PhotoScene.allCases)
        return encode(render(width, height) { drawPhoto($0, scene: scene, rng: &rng) }, as: .jpeg)
    }

    /// A custom-emoji-style picture on a transparent background.
    public static func emojiPNG(seed: UInt64, motif: EmojiMotif? = nil, size: Int = 128) -> Data {
        let motif = motif ?? defaultMotif(seed)
        return encode(render(size, size) { drawMotif($0, motif, seed: seed, phase: 0) }, as: .png)
    }

    /// The motif with a white die-cut outline and a soft shadow.
    public static func stickerPNG(seed: UInt64, motif: EmojiMotif? = nil, size: Int = 320) -> Data {
        let motif = motif ?? defaultMotif(seed)
        return encode(render(size, size) { canvas in
            let context = canvas.context
            context.setShadow(offset: CGSize(width: 0, height: -canvas.side * 0.02), blur: canvas.side * 0.04,
                              color: CGColor(gray: 0, alpha: 0.35))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            for angle in stride(from: 0.0, to: 2 * .pi, by: .pi / 12) {
                context.saveGState()
                context.translateBy(x: cos(angle) * canvas.side * 0.035, y: sin(angle) * canvas.side * 0.035)
                drawMotif(canvas, motif, seed: seed, phase: 0, inset: 0.12, silhouette: .white)
                context.restoreGState()
            }
            context.endTransparencyLayer()
            drawMotif(canvas, motif, seed: seed, phase: 0, inset: 0.12)
        }, as: .png)
    }

    /// A looping GIF: a bouncing `motif` on a transparent background for animated
    /// emoji, an avatar's `art` moving gently, or drifting blobs.
    public static func animatedGIF(seed: UInt64, frames: Int = 12, size: Int = 128, motif: EmojiMotif? = nil, art: Art? = nil) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil)!
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for frame in 0 ..< frames {
            let phase = Double(frame) / Double(frames)
            let image = render(size, size) { canvas in
                if let motif {
                    drawMotif(canvas, motif, seed: seed, phase: phase)
                } else if let art {
                    drawArt(canvas, art, seed: seed, phase: phase)
                } else {
                    drawAvatar(canvas, seed: seed, phase: phase)
                }
            }
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.08],
            ] as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// An avatar decoration: a frame drawn around the avatar, transparent in
    /// the middle (the avatar shows through at 1/1.2 of the size, as on
    /// Discord). Animated decorations are APNG, Discord's format for them.
    public static func avatarDecorationPNG(seed: UInt64, size: Int, animated: Bool) -> Data {
        let frames = animated ? 12 : 1
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, frames, nil)!
        if animated {
            CGImageDestinationSetProperties(destination, [
                kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0],
            ] as CFDictionary)
        }
        for frame in 0 ..< frames {
            let image = render(size, size) { drawDecoration($0, seed: seed, phase: Double(frame) / Double(frames)) }
            CGImageDestinationAddImage(destination, image, animated ? [
                kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.08],
            ] as CFDictionary : nil)
        }
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// Bytes for a media reference; `nil` only for a missing bundled file.
    public static func data(for media: DemoMediaRef, width: Int, height: Int) -> Data? {
        switch media {
        case .photo(let seed, let scene): photoJPEG(seed: seed, width: width, height: height, scene: scene)
        case .animation(let seed, let motif): animatedGIF(seed: seed, size: min(width, height), motif: motif)
        case .sticker(let seed, let motif): stickerPNG(seed: seed, motif: motif, size: min(width, height))
        case .bundled(let name): bundled(name)
        }
    }

    /// A file from `Resources/Media`.
    public static func bundled(_ name: String) -> Data? {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Media").flatMap { try? Data(contentsOf: $0) }
    }
}

// MARK: - Rendering

struct RGB {
    var red: Double
    var green: Double
    var blue: Double

    init(_ hex: UInt32) {
        red = Double(hex >> 16 & 0xff) / 255
        green = Double(hex >> 8 & 0xff) / 255
        blue = Double(hex & 0xff) / 255
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    static let white = RGB(0xffffff)

    func mixed(_ other: RGB, _ amount: Double) -> RGB {
        RGB(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount)
    }

    func cg(_ alpha: Double = 1) -> CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

/// Light to dark, so index 0 suits backgrounds and 3 suits accents.
private let palettes: [[RGB]] = [
    [0xf6c1a8, 0xf28c8c, 0xb57ba6, 0x6c5b9e], [0xa8e6cf, 0x56c1c1, 0x2e86ab, 0x1b4965],
    [0xdde8b9, 0xa3c981, 0x5e9f6e, 0x2f5d50], [0xe8dff5, 0xc3aed6, 0x8e7cc3, 0x4b3f72],
    [0xffe29a, 0xffb347, 0xff7f50, 0xd1495b], [0xf7c6d9, 0xe07a9c, 0xa23b72, 0x5c2751],
    [0xf4e3c1, 0xe0b184, 0xb07d62, 0x6b4f4f], [0xd8f3dc, 0x95d5b2, 0x52b788, 0x2d6a4f],
    [0xffd6c0, 0xff9e80, 0xf25f5c, 0x70587c], [0xa9b4d9, 0x6c7bbf, 0x3d4a8a, 0x1e2350],
    [0xfde2e4, 0xfad2e1, 0xe2a0b5, 0x9d6381], [0xe3e8ee, 0xa7b6c2, 0x6b8094, 0x3a4a5c],
].map { $0.map(RGB.init) }

private func palette(_ index: Int?, _ rng: inout SeededRandom) -> [RGB] {
    let drawn = Int(rng.next() % UInt64(palettes.count))
    return palettes[index.map { ($0 % palettes.count + palettes.count) % palettes.count } ?? drawn]
}

/// A drawing surface in unit-friendly coordinates: origin bottom-left.
struct Canvas {
    let context: CGContext
    let width: Double
    let height: Double

    var side: Double { min(width, height) }

    func point(_ px: Double, _ py: Double) -> CGPoint { CGPoint(x: px * width, y: py * height) }

    func fill(_ color: RGB, _ alpha: Double = 1, _ path: CGPath) {
        context.addPath(path)
        context.setFillColor(color.cg(alpha))
        context.fillPath()
    }

    func stroke(_ color: RGB, _ lineWidth: Double, _ path: CGPath, alpha: Double = 1) {
        context.addPath(path)
        context.setStrokeColor(color.cg(alpha))
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
    }

    func ellipse(_ color: RGB, _ px: Double, _ py: Double, _ pw: Double, _ ph: Double, alpha: Double = 1) {
        fill(color, alpha, CGPath(ellipseIn: CGRect(x: px * width, y: py * height, width: pw * width, height: ph * height), transform: nil))
    }

    func rect(_ color: RGB, _ px: Double, _ py: Double, _ pw: Double, _ ph: Double, radius: Double = 0, alpha: Double = 1) {
        let frame = CGRect(x: px * width, y: py * height, width: pw * width, height: ph * height)
        let corner = min(radius * side, frame.width / 2, frame.height / 2)
        fill(color, alpha, CGPath(roundedRect: frame, cornerWidth: corner, cornerHeight: corner, transform: nil))
    }

    func polygon(_ color: RGB, _ points: [(Double, Double)], alpha: Double = 1) {
        let path = CGMutablePath()
        path.addLines(between: points.map { point($0.0, $0.1) })
        path.closeSubpath()
        fill(color, alpha, path)
    }

    /// A gradient across the whole canvas (or current clip) at `angle` radians.
    func linear(_ colors: [RGB], angle: Double = .pi / 2) {
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map { $0.cg() } as CFArray, locations: nil)!
        let center = CGPoint(x: width / 2, y: height / 2)
        let reach = hypot(width, height) / 2
        let offset = CGPoint(x: cos(angle) * reach, y: sin(angle) * reach)
        context.drawLinearGradient(gradient, start: CGPoint(x: center.x - offset.x, y: center.y - offset.y),
                                   end: CGPoint(x: center.x + offset.x, y: center.y + offset.y),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// A soft-edged blob: `color` fading to transparent at `radius` (× side).
    func glow(_ color: RGB, _ px: Double, _ py: Double, radius: Double, alpha: Double = 0.9) {
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color.cg(alpha), color.cg(0)] as CFArray, locations: nil)!
        let center = point(px, py)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius * side, options: [])
    }

    /// A filled band from the bottom edge up to a sine-wave horizon.
    func hill(_ color: RGB, base: Double, amplitude: Double, frequency: Double, phase: Double, alpha: Double = 1) {
        let path = CGMutablePath()
        path.move(to: point(0, 0))
        for step in 0 ... 48 {
            let px = Double(step) / 48
            path.addLine(to: point(px, base + amplitude * sin(px * frequency * 2 * .pi + phase)))
        }
        path.addLine(to: point(1, 0))
        path.closeSubpath()
        fill(color, alpha, path)
    }
}

func render(_ width: Int, _ height: Int, _ draw: (Canvas) -> Void) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    draw(Canvas(context: context, width: Double(width), height: Double(height)))
    return context.makeImage()!
}

enum Encoding { case png, jpeg }

func encode(_ image: CGImage, as encoding: Encoding) -> Data {
    let data = NSMutableData()
    let type = encoding == .png ? UTType.png : UTType.jpeg
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    let options = encoding == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary : nil
    CGImageDestinationAddImage(destination, image, options)
    CGImageDestinationFinalize(destination)
    return data as Data
}

func defaultMotif(_ seed: UInt64) -> MediaGenerator.EmojiMotif {
    var rng = SeededRandom(seed: seed).fork("motif")
    return rng.pick(MediaGenerator.EmojiMotif.emoji)
}

extension SeededRandom {
    mutating func range(_ lower: Double, _ upper: Double) -> Double { lower + (upper - lower) * unit() }
}

// MARK: - Avatars, icons, banners

private func drawAvatar(_ canvas: Canvas, seed: UInt64, phase: Double) {
    var rng = SeededRandom(seed: seed)
    let colors = palette(nil, &rng)
    canvas.linear([colors[0], colors[1]], angle: rng.range(0, 2 * .pi))
    for blob in 0 ..< 3 {
        let (px, py, radius) = (rng.range(0.1, 0.9), rng.range(0.1, 0.9), rng.range(0.35, 0.6))
        let drift = 2 * .pi * (phase + Double(blob) / 3)
        canvas.glow(colors[2 + blob % 2], px + 0.08 * cos(drift), py + 0.08 * sin(drift), radius: radius, alpha: 0.8)
    }
    canvas.glow(.white, rng.range(0.25, 0.75), rng.range(0.55, 0.85), radius: 0.3, alpha: 0.45)
    let accent = colors[rng.pick([2, 3, 3])]
    let (px, py) = (rng.range(0.36, 0.64), rng.range(0.36, 0.64))
    let radius = rng.range(0.16, 0.24)
    let disc = { (dx: Double, dy: Double, discRadius: Double) in
        CGPath(ellipseIn: CGRect(x: canvas.width * (px + dx - discRadius), y: canvas.height * (py + dy - discRadius),
                                 width: canvas.width * discRadius * 2, height: canvas.height * discRadius * 2), transform: nil)
    }
    switch rng.next() % 6 {
    case 0:
        canvas.hill(colors[2], base: rng.range(0.38, 0.5), amplitude: 0.06, frequency: rng.range(0.8, 1.6), phase: rng.range(0, 6) + phase * 2 * .pi, alpha: 0.6)
        canvas.hill(accent, base: rng.range(0.18, 0.3), amplitude: 0.05, frequency: rng.range(0.8, 1.6), phase: rng.range(0, 6) - phase * 2 * .pi, alpha: 0.9)
    case 1:
        canvas.fill(accent, 0.9, disc(0, 0, radius))
        canvas.fill(.white, 0.7, disc(radius * 0.9, radius * 0.9, radius * 0.4))
    case 2:
        canvas.stroke(accent, canvas.side * 0.07, disc(0, 0, radius * 1.3), alpha: 0.85)
    case 3:
        canvas.context.saveGState()
        canvas.context.translateBy(x: canvas.width / 2, y: canvas.height / 2)
        canvas.context.rotate(by: rng.range(0, .pi) + phase * .pi / 4)
        canvas.fill(accent, 0.8, CGPath(rect: CGRect(x: -canvas.side, y: -canvas.side * 0.12, width: canvas.side * 2, height: canvas.side * 0.24), transform: nil))
        canvas.context.restoreGState()
    case 4:
        let crescent = CGMutablePath()
        crescent.addPath(disc(0, 0, radius * 1.2))
        crescent.addPath(disc(radius * 0.6, radius * 0.4, radius * 1.1))
        canvas.context.addPath(crescent)
        canvas.context.setFillColor(accent.cg(0.9))
        canvas.context.fillPath(using: .evenOdd)
    default:
        for dot in 0 ..< 3 {
            let angle = Double(dot) * 2 * .pi / 3 + phase * 2 * .pi
            canvas.fill(colors[1 + dot], 0.85, disc(cos(angle) * radius * 0.9, sin(angle) * radius * 0.9, radius * 0.55))
        }
    }
}

private func drawDecoration(_ canvas: Canvas, seed: UInt64, phase: Double) {
    var rng = SeededRandom(seed: seed).fork("decoration")
    let colors = palette(nil, &rng)
    let center = canvas.point(0.5, 0.5)
    // The ring sits just outside the avatar's edge (radius 0.5 / 1.2 of the side).
    let ring = canvas.side * 0.455
    canvas.stroke(colors[1], canvas.side * 0.07, CGPath(ellipseIn: CGRect(
        x: center.x - ring, y: center.y - ring, width: ring * 2, height: ring * 2), transform: nil))
    canvas.stroke(colors[0], canvas.side * 0.02, CGPath(ellipseIn: CGRect(
        x: center.x - ring, y: center.y - ring, width: ring * 2, height: ring * 2), transform: nil), alpha: 0.8)
    for index in 0 ..< 3 {
        let angle = (phase + Double(index) / 3) * 2 * .pi
        let sparkle = 0.07 + 0.02 * sin(angle * 2)
        canvas.ellipse(colors[index % 2 == 0 ? 0 : 2],
                       0.5 + 0.455 * cos(angle) - sparkle / 2, 0.5 + 0.455 * sin(angle) - sparkle / 2,
                       sparkle, sparkle)
    }
}

private func drawGuildIcon(_ canvas: Canvas, seed: UInt64, palette index: Int?) {
    var rng = SeededRandom(seed: seed)
    let colors = palette(index, &rng)
    canvas.linear([colors[3], colors[2]], angle: rng.range(0, 2 * .pi))
    canvas.glow(colors[1], 0.3, 0.75, radius: 0.7, alpha: 0.6)
    let petals = 4 + Int(rng.next() % 4)
    let turn = rng.range(0, .pi)
    for petal in 0 ..< petals {
        let angle = turn + Double(petal) / Double(petals) * 2 * .pi
        canvas.context.saveGState()
        canvas.context.translateBy(x: canvas.width / 2, y: canvas.height / 2)
        canvas.context.rotate(by: angle)
        canvas.fill(colors[0], 0.9, CGPath(ellipseIn: CGRect(x: 0, y: -canvas.side * 0.09, width: canvas.side * 0.34, height: canvas.side * 0.18), transform: nil))
        canvas.context.restoreGState()
    }
    canvas.ellipse(colors[1], 0.4, 0.4, 0.2, 0.2)
    canvas.glow(.white, 0.47, 0.53, radius: 0.08, alpha: 0.6)
}

private func drawBanner(_ canvas: Canvas, seed: UInt64, palette index: Int?) {
    var rng = SeededRandom(seed: seed)
    let colors = palette(index, &rng)
    canvas.linear([colors[0], colors[1], colors[2]], angle: rng.range(-0.4, 0.4))
    for _ in 0 ..< 4 {
        canvas.glow(rng.pick(colors), rng.range(0, 1), rng.range(0.3, 1), radius: rng.range(0.6, 1.1), alpha: 0.5)
    }
    for layer in 0 ..< 3 {
        canvas.hill(colors[1 + layer], base: 0.45 - Double(layer) * 0.13, amplitude: rng.range(0.04, 0.09),
                    frequency: rng.range(1, 2.5), phase: rng.range(0, 6), alpha: 0.75)
    }
}

// MARK: - Photos

func drawPhoto(_ canvas: Canvas, scene: MediaGenerator.PhotoScene, rng: inout SeededRandom) {
    switch scene {
    case .landscape: landscape(canvas, &rng)
    case .sunset: sunset(canvas, &rng)
    case .food: food(canvas, &rng)
    case .cake: cake(canvas, &rng)
    case .plant: plant(canvas, &rng)
    case .cat: pet(canvas, &rng, dog: false)
    case .dog: pet(canvas, &rng, dog: true)
    case .city: city(canvas, &rng)
    case .couch: couch(canvas, &rng)
    case .bike: bike(canvas, &rng)
    case .medal: medal(canvas, &rng)
    case .desk: desk(canvas, &rng)
    case .garden: garden(canvas, &rng)
    }
    // A gentle vignette makes flat shapes read more like a photo.
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.28)] as CFArray, locations: nil)!
    let center = canvas.point(0.5, 0.5)
    canvas.context.drawRadialGradient(gradient, startCenter: center, startRadius: canvas.side * 0.45, endCenter: center,
                                      endRadius: hypot(canvas.width, canvas.height) * 0.6, options: [.drawsAfterEndLocation])
}

private func sky(_ canvas: Canvas, _ top: UInt32, _ bottom: UInt32) {
    canvas.linear([RGB(bottom), RGB(top)])
}

private func landscape(_ canvas: Canvas, _ rng: inout SeededRandom) {
    sky(canvas, rng.pick([0x6fa8dc, 0x89c2e8, 0x7fb3d5]), 0xe9f4fb)
    canvas.glow(RGB(0xfff6d5), rng.range(0.15, 0.85), rng.range(0.7, 0.88), radius: 0.22, alpha: 0.95)
    for _ in 0 ..< 3 { canvas.glow(.white, rng.range(0, 1), rng.range(0.7, 0.95), radius: rng.range(0.08, 0.16), alpha: 0.7) }
    let greens: [UInt32] = [0x9cc5a1, 0x6fa776, 0x4a7f55, 0x2f5e3c]
    for (layer, green) in greens.enumerated() {
        canvas.hill(RGB(green), base: 0.55 - Double(layer) * 0.12, amplitude: rng.range(0.03, 0.08), frequency: rng.range(0.6, 1.8), phase: rng.range(0, 6))
    }
    for _ in 0 ..< Int(rng.range(3, 8)) {
        let px = rng.range(0.05, 0.95), py = rng.range(0.08, 0.22), ph = rng.range(0.1, 0.18)
        canvas.polygon(RGB(0x22472e), [(px - 0.03, py), (px + 0.03, py), (px, py + ph)])
    }
}

private func sunset(_ canvas: Canvas, _ rng: inout SeededRandom) {
    canvas.linear([RGB(0xffc48c), RGB(0xf2777a), RGB(0x6b4c8a)])
    let sunX = rng.range(0.3, 0.7)
    canvas.glow(RGB(0xfff1c1), sunX, 0.38, radius: 0.35, alpha: 0.8)
    canvas.ellipse(RGB(0xffe9a8), sunX - 0.09, 0.3, 0.18, 0.18 * canvas.width / canvas.height)
    canvas.rect(RGB(0x40335c), 0, 0, 1, 0.35)
    for row in 0 ..< 7 {
        let py = 0.04 + Double(row) * 0.045
        let span = 0.05 + Double(row) * 0.025
        canvas.rect(RGB(0xffd08a), sunX - span / 2 + rng.range(-0.02, 0.02), py, span, 0.012, radius: 0.01, alpha: 0.7)
    }
    canvas.hill(RGB(0x2b2240), base: 0.36, amplitude: 0.03, frequency: 1.3, phase: rng.range(0, 6))
}

private func tabletop(_ canvas: Canvas, _ rng: inout SeededRandom) {
    let wood = RGB(rng.pick([0xc89f7a, 0xb88a64, 0xd8b896]))
    canvas.linear([wood, wood.mixed(RGB(0x5a3d2b), 0.35)], angle: rng.range(0.2, 1.2))
    for plank in 0 ..< 6 {
        canvas.rect(RGB(0x5a3d2b), 0, Double(plank) / 6, 1, 0.006, alpha: 0.25)
    }
}

private func food(_ canvas: Canvas, _ rng: inout SeededRandom) {
    tabletop(canvas, &rng)
    let (px, py) = (rng.range(0.42, 0.58), rng.range(0.45, 0.55))
    canvas.ellipse(RGB(0x000000), px - 0.33, py - 0.36, 0.68, 0.7, alpha: 0.18)
    canvas.ellipse(RGB(0xfaf7f2), px - 0.34, py - 0.34, 0.68, 0.68)
    canvas.ellipse(RGB(0xece6dc), px - 0.26, py - 0.26, 0.52, 0.52)
    let dish: [UInt32] = rng.pick([[0xe8a33d, 0xc2452d, 0x6a994e], [0xf2d388, 0xd9a05b, 0x8c5a3c], [0xe76f51, 0xf4a261, 0x2a9d8f]])
    for _ in 0 ..< 14 {
        let angle = rng.range(0, 2 * .pi), distance = rng.range(0, 0.18), size = rng.range(0.06, 0.13)
        canvas.ellipse(RGB(rng.pick(dish)), px + cos(angle) * distance - size / 2, py + sin(angle) * distance - size / 2, size, size * rng.range(0.7, 1.1))
    }
    canvas.rect(RGB(0xc9ccd1), px + 0.38, py - 0.3, 0.025, 0.6, radius: 0.02)
}

private func cake(_ canvas: Canvas, _ rng: inout SeededRandom) {
    tabletop(canvas, &rng)
    canvas.glow(RGB(0xfff3d6), 0.5, 0.8, radius: 0.6, alpha: 0.5)
    let frosting = RGB(rng.pick([0x8fd17a, 0xf6a5c0, 0xa8d8ea, 0xffe08a]))
    canvas.ellipse(RGB(0xf4f1ec), 0.15, 0.12, 0.7, 0.16)
    canvas.rect(frosting.mixed(RGB(0x000000), 0.15), 0.25, 0.2, 0.5, 0.32)
    canvas.ellipse(frosting.mixed(RGB(0x000000), 0.15), 0.25, 0.14, 0.5, 0.12)
    canvas.ellipse(frosting, 0.25, 0.46, 0.5, 0.12)
    for index in 0 ..< 5 {
        let px = 0.32 + Double(index) * 0.085
        canvas.rect(RGB(rng.pick([0xffffff, 0xffd6e0, 0xc9e4ff])), px, 0.53, 0.018, 0.12, radius: 0.01)
        canvas.glow(RGB(0xffc44d), px + 0.009, 0.68, radius: 0.035, alpha: 0.95)
    }
    for _ in 0 ..< 18 { canvas.ellipse(RGB(rng.pick([0xff6b6b, 0xffd93d, 0x6bcBff, 0xffffff])), rng.range(0.27, 0.71), rng.range(0.22, 0.48), 0.012, 0.012) }
}

private func plant(_ canvas: Canvas, _ rng: inout SeededRandom) {
    canvas.linear([RGB(0xe9e2d6), RGB(0xf7f3ec)])
    canvas.glow(RGB(0xfffaf0), rng.range(0.6, 0.9), 0.85, radius: 0.5, alpha: 0.8)
    canvas.rect(RGB(0xcbbba4), 0, 0, 1, 0.18)
    canvas.polygon(RGB(0xc8693f), [(0.36, 0.14), (0.64, 0.14), (0.68, 0.38), (0.32, 0.38)])
    canvas.rect(RGB(0xb35a33), 0.3, 0.36, 0.4, 0.05, radius: 0.01)
    let green = RGB(rng.pick([0x3f7d4e, 0x4f8f3a, 0x2f6b4f]))
    for _ in 0 ..< Int(rng.range(6, 10)) {
        let angle = rng.range(-1.2, 1.2), length = rng.range(0.22, 0.38)
        canvas.context.saveGState()
        canvas.context.translateBy(x: canvas.width * 0.5, y: canvas.height * 0.4)
        canvas.context.rotate(by: angle)
        let leaf = CGPath(ellipseIn: CGRect(x: -canvas.side * 0.07, y: canvas.side * length * 0.4, width: canvas.side * 0.14, height: canvas.side * length), transform: nil)
        canvas.fill(green.mixed(.white, rng.range(0, 0.25)), 1, leaf)
        canvas.stroke(RGB(0x1f4a2c), canvas.side * 0.006, CGPath(rect: CGRect(x: 0, y: canvas.side * length * 0.45, width: 0, height: canvas.side * length * 0.9), transform: nil), alpha: 0.5)
        canvas.context.restoreGState()
    }
}

private func pet(_ canvas: Canvas, _ rng: inout SeededRandom, dog: Bool) {
    canvas.linear([RGB(0xd9c9b6), RGB(0xf1e7da)])
    canvas.rect(RGB(0xa98f75), 0, 0, 1, 0.3)
    canvas.ellipse(RGB(rng.pick([0x5b7db1, 0xb14f4f, 0x6e9e6a])), 0.12, 0.08, 0.76, 0.24, alpha: 0.9)
    let fur = RGB(rng.pick(dog ? [0xc8924f, 0xe8d3b0, 0x5a4033, 0xb07040] : [0xe39b4f, 0x7d7d7d, 0x3a3a3a, 0xf0e6d8]))
    let (px, py) = (rng.range(0.42, 0.58), 0.3)
    let round = canvas.width / canvas.height
    let tail = CGMutablePath()
    tail.move(to: canvas.point(px + 0.18, py + 0.04))
    if dog {
        tail.addQuadCurve(to: canvas.point(px + 0.3, py + 0.2), control: canvas.point(px + 0.3, py + 0.04))
    } else {
        tail.addCurve(to: canvas.point(px + 0.32, py + 0.3), control1: canvas.point(px + 0.36, py + 0.02), control2: canvas.point(px + 0.4, py + 0.22))
    }
    canvas.stroke(fur, canvas.side * (dog ? 0.04 : 0.05), tail)
    canvas.ellipse(fur, px - 0.22, py - 0.04, 0.44, 0.26)
    canvas.ellipse(fur, px - 0.27, py + 0.12, 0.24, 0.24 * round)
    let headTop = py + 0.12 + 0.24 * round
    if dog {
        let ear = fur.mixed(RGB(0x000000), 0.25)
        canvas.ellipse(ear, px - 0.3, headTop - 0.2 * round, 0.07, 0.17 * round)
        canvas.ellipse(ear, px - 0.1, headTop - 0.2 * round, 0.07, 0.17 * round)
        canvas.ellipse(fur.mixed(.white, 0.35), px - 0.205, py + 0.13, 0.11, 0.08 * round)
        canvas.ellipse(RGB(0x2a2a2a), px - 0.17, py + 0.19, 0.04, 0.025 * round)
        canvas.ellipse(RGB(0xe5707e), px - 0.162, py + 0.12, 0.024, 0.03 * round)
    } else {
        canvas.polygon(fur, [(px - 0.26, headTop - 0.08), (px - 0.24, headTop + 0.06), (px - 0.18, headTop - 0.03)])
        canvas.polygon(fur, [(px - 0.12, headTop - 0.03), (px - 0.07, headTop + 0.06), (px - 0.04, headTop - 0.08)])
        canvas.ellipse(RGB(0xe58a9a), px - 0.165, py + 0.2, 0.02, 0.015)
    }
    for eye in [px - 0.2, px - 0.11] { canvas.ellipse(RGB(0x2a2a2a), eye, py + 0.25, 0.025, 0.04) }
}

private func city(_ canvas: Canvas, _ rng: inout SeededRandom) {
    canvas.linear([RGB(0xf6a96b), RGB(0x8a6aa8), RGB(0x2e3a6e)])
    var px = 0.0
    while px < 1 {
        let width = rng.range(0.08, 0.16), height = rng.range(0.25, 0.7)
        let tone = RGB(0x1d2240).mixed(RGB(0x3c4170), rng.unit())
        canvas.rect(tone, px, 0, width - 0.008, height)
        var row = 0.04
        while row < height - 0.05 {
            var column = px + 0.012
            while column < px + width - 0.03 {
                if rng.chance(0.45) { canvas.rect(RGB(0xffd98a), column, row, 0.014, 0.022, alpha: 0.9) }
                column += 0.026
            }
            row += 0.045
        }
        px += width
    }
}

private func couch(_ canvas: Canvas, _ rng: inout SeededRandom) {
    canvas.linear([RGB(0xece4d8), RGB(0xf8f4ee)])
    canvas.rect(RGB(0xb08a63), 0, 0, 1, 0.16)
    canvas.rect(RGB(0xffffff), 0.68, 0.16, 0.26, 0.74)
    canvas.rect(RGB(0x9b7b5c), 0.7, 0.16, 0.22, 0.7)
    canvas.ellipse(RGB(0xd8b24a), 0.73, 0.48, 0.03, 0.04)
    let green = RGB(rng.pick([0x5d8a5a, 0x4f7f6a, 0x6b8f3e]))
    canvas.rect(green.mixed(RGB(0x000000), 0.15), 0.06, 0.34, 0.58, 0.3, radius: 0.06)
    canvas.rect(green, 0.08, 0.2, 0.54, 0.18, radius: 0.04)
    canvas.rect(green.mixed(.white, 0.1), 0.03, 0.2, 0.1, 0.3, radius: 0.05)
    canvas.rect(green.mixed(.white, 0.1), 0.57, 0.2, 0.1, 0.3, radius: 0.05)
    for leg in [0.1, 0.58] { canvas.rect(RGB(0x3d2b1f), leg, 0.15, 0.025, 0.06) }
    canvas.rect(RGB(rng.pick([0xf2c14e, 0xe76f51, 0xf4f1de])), 0.15, 0.36, 0.13, 0.13, radius: 0.03)
}

private func bike(_ canvas: Canvas, _ rng: inout SeededRandom) {
    canvas.linear([RGB(0xbfc9cf), RGB(0xe4ebef)])
    canvas.rect(RGB(0x8d8f8a), 0, 0, 1, 0.22)
    let frame = RGB(rng.pick([0x2b6cb0, 0xc0392b, 0x2f855a, 0xd69e2e]))
    let radius = 0.17 * canvas.height / canvas.side
    for wheel in [0.28, 0.72] {
        let tyre = CGRect(x: canvas.width * wheel - canvas.side * radius, y: canvas.height * 0.32 - canvas.side * radius,
                          width: canvas.side * radius * 2, height: canvas.side * radius * 2)
        canvas.stroke(RGB(0x222222), canvas.side * 0.025, CGPath(ellipseIn: tyre, transform: nil))
    }
    let path = CGMutablePath()
    path.addLines(between: [canvas.point(0.28, 0.32), canvas.point(0.46, 0.32), canvas.point(0.4, 0.56), canvas.point(0.28, 0.32)])
    path.addLines(between: [canvas.point(0.46, 0.32), canvas.point(0.64, 0.56), canvas.point(0.4, 0.56)])
    path.addLines(between: [canvas.point(0.64, 0.56), canvas.point(0.72, 0.32)])
    path.addLines(between: [canvas.point(0.64, 0.56), canvas.point(0.62, 0.64), canvas.point(0.68, 0.66)])
    path.addLines(between: [canvas.point(0.4, 0.56), canvas.point(0.39, 0.62)])
    canvas.stroke(frame, canvas.side * 0.022, path)
    canvas.rect(RGB(0x222222), 0.35, 0.61, 0.08, 0.025, radius: 0.01)
    let chain = CGMutablePath()
    chain.move(to: canvas.point(0.46, 0.32))
    chain.addCurve(to: canvas.point(0.52, 0.12), control1: canvas.point(0.5, 0.24), control2: canvas.point(0.47, 0.14))
    canvas.stroke(RGB(0x555555), canvas.side * 0.008, chain)
}

private func medal(_ canvas: Canvas, _ rng: inout SeededRandom) {
    canvas.linear([RGB(0x2d3e50), RGB(0x46617a)], angle: rng.range(1, 2))
    let ribbon = RGB(rng.pick([0xe63946, 0x1d7874, 0x6a4c93]))
    canvas.polygon(ribbon, [(0.36, 1), (0.46, 1), (0.54, 0.5), (0.46, 0.46)])
    canvas.polygon(ribbon.mixed(.white, 0.2), [(0.54, 1), (0.64, 1), (0.54, 0.46), (0.46, 0.5)])
    let size = 0.3 * canvas.height / canvas.width
    canvas.glow(RGB(0xffe7a0), 0.5, 0.32, radius: 0.32, alpha: 0.4)
    canvas.ellipse(RGB(0xc9962b), 0.5 - size / 2, 0.17, size, 0.3)
    canvas.ellipse(RGB(0xf2c94c), 0.5 - size * 0.4, 0.2, size * 0.8, 0.24)
    canvas.glow(.white, 0.47, 0.37, radius: 0.06, alpha: 0.6)
}

private func desk(_ canvas: Canvas, _ rng: inout SeededRandom) {
    tabletop(canvas, &rng)
    for _ in 0 ..< 7 {
        let (px, py) = (rng.range(0.05, 0.6), rng.range(0.1, 0.6))
        canvas.context.saveGState()
        canvas.context.translateBy(x: canvas.width * px, y: canvas.height * py)
        canvas.context.rotate(by: rng.range(-0.4, 0.4))
        canvas.fill(RGB(rng.pick([0xffffff, 0xfff3b0, 0xcde7f0, 0xf7d6e0])), 1, CGPath(rect: CGRect(x: 0, y: 0, width: canvas.side * 0.3, height: canvas.side * 0.19), transform: nil))
        for line in 0 ..< 3 {
            let text = CGRect(x: canvas.side * 0.03, y: canvas.side * (0.04 + Double(line) * 0.04),
                              width: canvas.side * rng.range(0.12, 0.24), height: canvas.side * 0.008)
            canvas.fill(RGB(0x8a8f98), 0.6, CGPath(rect: text, transform: nil))
        }
        canvas.context.restoreGState()
    }
    canvas.ellipse(RGB(0x000000), 0.7, 0.18, 0.2, 0.2 * canvas.width / canvas.height, alpha: 0.2)
    canvas.ellipse(RGB(rng.pick([0xf4f1de, 0x81b29a, 0xe07a5f])), 0.69, 0.2, 0.2, 0.2 * canvas.width / canvas.height)
    canvas.ellipse(RGB(0x5b3a29), 0.71, 0.22 + 0.02, 0.16, 0.16 * canvas.width / canvas.height)
}

private func garden(_ canvas: Canvas, _ rng: inout SeededRandom) {
    sky(canvas, 0x9fd3f0, 0xf1f8e9)
    canvas.rect(RGB(0x7a5c3e), 0, 0, 1, 0.55)
    for row in 0 ..< 4 {
        let py = 0.05 + Double(row) * 0.13
        canvas.rect(RGB(0x5b4330), 0, py, 1, 0.07, radius: 0.03)
        var px = rng.range(0, 0.05)
        while px < 1 {
            let size = rng.range(0.035, 0.06)
            canvas.ellipse(RGB(rng.pick([0x4f9a4a, 0x6bbf59, 0x3e7d3a])), px, py + 0.04, size, size * 1.6)
            if rng.chance(0.3) { canvas.ellipse(RGB(rng.pick([0xe63946, 0xf4a261, 0xffd166])), px + size * 0.2, py + 0.06, size * 0.5, size * 0.6) }
            px += rng.range(0.05, 0.09)
        }
    }
    canvas.rect(RGB(0xa47148), 0.82, 0.55, 0.012, 0.25)
    canvas.rect(RGB(0xa47148), 0.75, 0.75, 0.15, 0.012)
}

// MARK: - Emoji motifs

/// Shared colouring for a motif: a tint, or one flat colour for sticker outlines.
struct MotifStyle {
    let silhouette: RGB?
    let tint: Double
    var dark: RGB { silhouette ?? RGB(0x3b2a2a) }

    func color(_ hex: UInt32) -> RGB {
        silhouette ?? (tint < 0 ? RGB(hex).mixed(RGB(0x000000), -tint) : RGB(hex).mixed(.white, tint))
    }
}

private func drawCreature(_ canvas: Canvas, _ motif: MediaGenerator.EmojiMotif, _ style: MotifStyle, _ rng: inout SeededRandom) {
    let context = canvas.context
    switch motif {
    case .smile:
        canvas.ellipse(style.color(0xffcc4d), 0.05, 0.05, 0.9, 0.9)
        canvas.ellipse(style.dark, 0.3, 0.52, 0.1, 0.16)
        canvas.ellipse(style.dark, 0.6, 0.52, 0.1, 0.16)
        let mouth = CGMutablePath()
        mouth.addArc(center: canvas.point(0.5, 0.45), radius: canvas.side * 0.24, startAngle: .pi * 1.15, endAngle: .pi * 1.85, clockwise: false)
        canvas.stroke(style.dark, canvas.side * 0.06, mouth)
    case .frog:
        canvas.ellipse(style.color(0x7cc66b), 0.06, 0.08, 0.88, 0.66)
        for px in [0.14, 0.56] {
            canvas.ellipse(style.color(0x7cc66b), px, 0.5, 0.3, 0.3)
            canvas.ellipse(style.silhouette ?? .white, px + 0.05, 0.55, 0.2, 0.2)
            canvas.ellipse(style.dark, px + 0.1, 0.59, 0.1, 0.12)
        }
        let mouth = CGMutablePath()
        mouth.addArc(center: canvas.point(0.5, 0.42), radius: canvas.side * 0.22, startAngle: .pi * 1.2, endAngle: .pi * 1.8, clockwise: false)
        canvas.stroke(style.silhouette ?? RGB(0x2f6b2a), canvas.side * 0.04, mouth)
        canvas.ellipse(style.color(0xf3a6b5), 0.16, 0.26, 0.12, 0.07, alpha: 0.8)
        canvas.ellipse(style.color(0xf3a6b5), 0.72, 0.26, 0.12, 0.07, alpha: 0.8)
    case .cat:
        let fur = style.color(rng.pick([0xf2a65a, 0x9a9a9a, 0x4a4a4a]))
        canvas.polygon(fur, [(0.1, 0.5), (0.16, 0.95), (0.42, 0.72)])
        canvas.polygon(fur, [(0.9, 0.5), (0.84, 0.95), (0.58, 0.72)])
        canvas.ellipse(fur, 0.06, 0.06, 0.88, 0.78)
        canvas.ellipse(style.silhouette ?? RGB(0xfff3e0), 0.3, 0.1, 0.4, 0.3)
        canvas.ellipse(style.dark, 0.28, 0.46, 0.1, 0.14)
        canvas.ellipse(style.dark, 0.62, 0.46, 0.1, 0.14)
        canvas.polygon(style.silhouette ?? RGB(0xe58a9a), [(0.45, 0.36), (0.55, 0.36), (0.5, 0.3)])
    case .bee:
        canvas.ellipse(style.silhouette ?? RGB(0xdff3ff), 0.22, 0.52, 0.3, 0.36, alpha: style.silhouette == nil ? 0.9 : 1)
        canvas.ellipse(style.silhouette ?? RGB(0xdff3ff), 0.48, 0.52, 0.3, 0.36, alpha: style.silhouette == nil ? 0.9 : 1)
        canvas.ellipse(style.color(0xffcc33), 0.1, 0.16, 0.8, 0.52)
        context.saveGState()
        context.addPath(CGPath(ellipseIn: CGRect(x: canvas.width * 0.1, y: canvas.height * 0.16, width: canvas.width * 0.8, height: canvas.height * 0.52), transform: nil))
        context.clip()
        for px in [0.34, 0.52, 0.7] { canvas.rect(style.dark, px, 0.1, 0.08, 0.7) }
        context.restoreGState()
        canvas.ellipse(style.dark, 0.16, 0.4, 0.07, 0.09)
    default:
        break
    }
}

private func drawObject(_ canvas: Canvas, _ motif: MediaGenerator.EmojiMotif, _ style: MotifStyle, _ rng: inout SeededRandom) {
    let context = canvas.context
    switch motif {
    case .heart:
        canvas.ellipse(style.color(0xf05d7a), 0.08, 0.4, 0.46, 0.46)
        canvas.ellipse(style.color(0xf05d7a), 0.46, 0.4, 0.46, 0.46)
        canvas.polygon(style.color(0xf05d7a), [(0.12, 0.56), (0.88, 0.56), (0.5, 0.06)])
    case .star, .sparkle:
        let points = motif == .star ? 5 : 4
        let inner = motif == .star ? 0.2 : 0.12
        let path = CGMutablePath()
        for index in 0 ..< (points * 2) {
            let angle = .pi / 2 + Double(index) * .pi / Double(points)
            let radius = index.isMultiple(of: 2) ? 0.46 : inner
            let point = canvas.point(0.5 + cos(angle) * radius, 0.48 + sin(angle) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        canvas.fill(style.color(motif == .star ? 0xffc93c : 0x9ad7ff), 1, path)
        if motif == .sparkle { canvas.ellipse(style.color(0xd6efff), 0.72, 0.72, 0.14, 0.14) }
    case .leaf:
        context.saveGState()
        context.translateBy(x: canvas.width / 2, y: canvas.height / 2)
        context.rotate(by: -.pi / 4)
        canvas.fill(style.color(0x58b368), 1, CGPath(ellipseIn: CGRect(x: -canvas.side * 0.22, y: -canvas.side * 0.42, width: canvas.side * 0.44, height: canvas.side * 0.84), transform: nil))
        canvas.stroke(style.silhouette ?? RGB(0x2f7a3d), canvas.side * 0.03, CGPath(rect: CGRect(x: 0, y: -canvas.side * 0.45, width: 0, height: canvas.side * 0.8), transform: nil))
        context.restoreGState()
    case .drop:
        canvas.ellipse(style.color(0x4fb3e8), 0.18, 0.06, 0.64, 0.64)
        canvas.polygon(style.color(0x4fb3e8), [(0.21, 0.5), (0.79, 0.5), (0.5, 0.96)])
        canvas.ellipse(style.silhouette ?? .white, 0.3, 0.3, 0.12, 0.18, alpha: style.silhouette == nil ? 0.6 : 1)
    case .flower:
        for petal in 0 ..< 6 {
            let angle = Double(petal) / 6 * 2 * .pi
            canvas.ellipse(style.color(rng.pick([0xf7a1c4, 0xffffff, 0xc5a3ff])), 0.5 + cos(angle) * 0.24 - 0.2, 0.5 + sin(angle) * 0.24 - 0.2, 0.4, 0.4)
        }
        canvas.ellipse(style.color(0xffcf3f), 0.34, 0.34, 0.32, 0.32)
    case .sun:
        for ray in 0 ..< 12 {
            let angle = Double(ray) / 12 * 2 * .pi
            let path = CGMutablePath()
            path.addLines(between: [canvas.point(0.5 + cos(angle) * 0.3, 0.5 + sin(angle) * 0.3), canvas.point(0.5 + cos(angle) * 0.46, 0.5 + sin(angle) * 0.46)])
            canvas.stroke(style.color(0xffb627), canvas.side * 0.06, path)
        }
        canvas.ellipse(style.color(0xffd23f), 0.22, 0.22, 0.56, 0.56)
    case .couch:
        let fabric = style.color(0x5d8a5a)
        canvas.rect(fabric, 0.12, 0.4, 0.76, 0.34, radius: 0.08)
        canvas.rect(style.silhouette ?? fabric.mixed(.white, 0.15), 0.14, 0.24, 0.72, 0.22, radius: 0.06)
        canvas.rect(style.silhouette ?? fabric.mixed(.white, 0.25), 0.04, 0.24, 0.16, 0.38, radius: 0.07)
        canvas.rect(style.silhouette ?? fabric.mixed(.white, 0.25), 0.8, 0.24, 0.16, 0.38, radius: 0.07)
        canvas.rect(style.dark, 0.12, 0.14, 0.06, 0.1)
        canvas.rect(style.dark, 0.82, 0.14, 0.06, 0.1)
    default:
        break
    }
}

/// Draws `motif` centred with `inset` margin. `phase` animates a gentle
/// bounce; `silhouette` paints every part one colour (for sticker outlines).
func drawMotif(_ canvas: Canvas, _ motif: MediaGenerator.EmojiMotif, seed: UInt64, phase: Double, inset: Double = 0.06, silhouette: RGB? = nil) {
    var rng = SeededRandom(seed: seed)
    let context = canvas.context
    context.saveGState()
    let scale = (1 - inset * 2) * (1 + 0.06 * sin(phase * 2 * .pi))
    context.translateBy(x: canvas.width / 2, y: canvas.height / 2 + canvas.side * 0.04 * sin(phase * 2 * .pi))
    context.rotate(by: 0.08 * sin(phase * 4 * .pi))
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -canvas.width / 2, y: -canvas.height / 2)
    let tint = rng.range(-0.12, 0.12)
    let style = MotifStyle(silhouette: silhouette, tint: tint)
    switch motif {
    case .smile, .frog, .cat, .bee: drawCreature(canvas, motif, style, &rng)
    default: if let pictogram = pictograms[motif] { pictogram(canvas, style) } else { drawObject(canvas, motif, style, &rng) }
    }
    context.restoreGState()
}
