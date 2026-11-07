import AppKit
import SwiftUI

enum SakuraCordSystemSymbol {
    nonisolated static let emojiFaceGrinning = "emoji.face.grinning"
    nonisolated static let sticker = "sticker"
    nonisolated static let thread = "thread"
    nonisolated static let applicationCommands = "xmark.triangle.circle.square.fill"

    private static let privateSymbolsBundle = Bundle(
        path: "/System/Library/PrivateFrameworks/SFSymbols.framework/Resources/CoreGlyphsPrivate.bundle"
    )

    /// macOS 27.3 made the emoji face public; 27.2 has it only in the private catalogue.
    static let emojiFaceGrinningImage =
        if NSImage(systemSymbolName: emojiFaceGrinning, accessibilityDescription: nil) == nil,
           let privateSymbolsBundle {
            Image(emojiFaceGrinning, bundle: privateSymbolsBundle)
        } else {
            Image(systemName: emojiFaceGrinning)
        }

    static var stickerImage: Image {
        guard let privateSymbolsBundle else {
            return Image(systemName: sticker)
        }
        return Image(sticker, bundle: privateSymbolsBundle)
    }

    @ViewBuilder
    static func swiftUIImage(named name: String) -> some View {
        if name == thread {
            Image(name, bundle: .module)
                .imageScale(.large)
        } else {
            Image(systemName: name)
        }
    }

    static func image(
        named name: String,
        accessibilityDescription: String? = nil
    ) -> NSImage? {
        let source = name == thread ? Bundle.module.image(forResource: name) : NSImage(
            systemSymbolName: name,
            accessibilityDescription: accessibilityDescription
        ) ?? privateSymbolsBundle?.image(forResource: name)
        guard let image = source?.copy() as? NSImage else { return nil }
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
