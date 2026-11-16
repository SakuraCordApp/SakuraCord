import CryptoKit
import Foundation
import ImageIO
@testable import SimulatorKit
import Testing
import UniformTypeIdentifiers

private struct Decoded {
    let type: UTType
    let width: Int
    let height: Int
    let frames: Int
}

private func decode(_ data: Data) throws -> Decoded {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let type = try #require(CGImageSourceGetType(source).flatMap { UTType($0 as String) })
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    return Decoded(type: type, width: image.width, height: image.height, frames: CGImageSourceGetCount(source))
}

private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

struct MediaGeneratorTests {
    /// Each generator, called twice with the same arguments.
    private static let generators: [(String, @Sendable () -> Data)] = [
        ("avatar", { MediaGenerator.avatarPNG(seed: 0x57e1, size: 128) }),
        ("guild icon", { MediaGenerator.guildIconPNG(seed: 0x9024, size: 128) }),
        ("banner", { MediaGenerator.bannerPNG(width: 600, height: 240, seed: 0x6a2e) }),
        ("photo", { MediaGenerator.photoJPEG(seed: 0xca6f, width: 640, height: 480, scene: .cake) }),
        ("emoji", { MediaGenerator.emojiPNG(seed: 0xf20, motif: .frog) }),
        ("sticker", { MediaGenerator.stickerPNG(seed: 0x3151, motif: .cat) }),
        ("animated avatar", { MediaGenerator.animatedGIF(seed: 0x57e1, frames: 8, size: 96) }),
        ("animated emoji", { MediaGenerator.animatedGIF(seed: 0xbee, frames: 8, size: 64, motif: .bee) }),
    ]

    @Test(arguments: generators.indices)
    func sameSeedGivesIdenticalBytes(_ index: Int) {
        let (name, generate) = Self.generators[index]
        #expect(digest(generate()) == digest(generate()), "\(name) is not deterministic")
    }

    @Test func differentSeedsDiffer() {
        #expect(MediaGenerator.avatarPNG(seed: 1, size: 64) != MediaGenerator.avatarPNG(seed: 2, size: 64))
        #expect(MediaGenerator.photoJPEG(seed: 1, width: 64, height: 48) != MediaGenerator.photoJPEG(seed: 2, width: 64, height: 48))
    }

    @Test func stillImagesDecode() throws {
        let avatar = try decode(MediaGenerator.avatarPNG(seed: 9, size: 128))
        #expect(avatar.type == .png && avatar.width == 128 && avatar.height == 128)
        let banner = try decode(MediaGenerator.bannerPNG(width: 600, height: 240, seed: 9))
        #expect(banner.type == .png && banner.width == 600 && banner.height == 240)
        let icon = try decode(MediaGenerator.guildIconPNG(seed: 9, size: 256))
        #expect(icon.type == .png && icon.width == 256)
        let sticker = try decode(MediaGenerator.stickerPNG(seed: 9))
        #expect(sticker.type == .png && sticker.width == 320)
        for motif in MediaGenerator.EmojiMotif.allCases {
            let emoji = try decode(MediaGenerator.emojiPNG(seed: 9, motif: motif))
            #expect(emoji.type == .png && emoji.width == 128, "\(motif)")
        }
    }

    @Test(arguments: MediaGenerator.PhotoScene.allCases)
    func photosDecode(_ scene: MediaGenerator.PhotoScene) throws {
        let photo = try decode(MediaGenerator.photoJPEG(seed: 5, width: 640, height: 480, scene: scene))
        #expect(photo.type == .jpeg && photo.width == 640 && photo.height == 480)
    }

    @Test func animatedGIFHasEveryFrame() throws {
        let gif = try decode(MediaGenerator.animatedGIF(seed: 4, frames: 10, size: 80))
        #expect(gif.type == .gif && gif.frames == 10 && gif.width == 80)
    }

    @Test func mediaReferencesResolve() throws {
        #expect(try decode(#require(MediaGenerator.data(for: .photo(seed: 1, scene: .garden), width: 320, height: 240))).type == .jpeg)
        #expect(try decode(#require(MediaGenerator.data(for: .animation(seed: 1, motif: .frog), width: 64, height: 64))).type == .gif)
        #expect(try decode(#require(MediaGenerator.data(for: .sticker(seed: 1, motif: .bee), width: 160, height: 160))).type == .png)
        #expect(try decode(#require(MediaGenerator.data(for: .bundled("demo-sticker.apng"), width: 0, height: 0))).type == .png)
        #expect(MediaGenerator.data(for: .bundled("no-such-file.bin"), width: 0, height: 0) == nil)
        for name in ["benchmark-video.mp4", "demo-voice-message.ogg", "benchmark-lottie.json", "demo-notes.txt"] {
            #expect(MediaGenerator.bundled(name)?.isEmpty == false, "missing \(name)")
        }
    }
}
