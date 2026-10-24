import AppKit
import SwiftUI

enum SakuraCordSystemSymbol {
    nonisolated static let emojiFaceGrinning = "emoji.face.grinning"
    nonisolated static let sticker = "sticker"
    nonisolated static let thread = "thread"
    nonisolated static let applicationCommands = "xmark.triangle.circle.square.fill"

    nonisolated private static let privateSymbolsBundle = Bundle(
        path: "/System/Library/PrivateFrameworks/SFSymbols.framework/Resources/CoreGlyphsPrivate.bundle"
    )

    static var emojiFaceGrinningImage: Image {
        guard let privateSymbolsBundle else {
            return Image(systemName: emojiFaceGrinning)
        }
        return Image(emojiFaceGrinning, bundle: privateSymbolsBundle)
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

    nonisolated static func image(
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
