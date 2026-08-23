import AppKit
import SwiftUI

enum SakuraCordSystemSymbol {
    nonisolated static let emojiFaceGrinning = "emoji.face.grinning"

    private static let privateSymbolsBundle = Bundle(
        path: "/System/Library/PrivateFrameworks/SFSymbols.framework/Resources/CoreGlyphsPrivate.bundle"
    )

    static var emojiFaceGrinningImage: Image {
        guard let privateSymbolsBundle else {
            return Image(systemName: emojiFaceGrinning)
        }
        return Image(emojiFaceGrinning, bundle: privateSymbolsBundle)
    }

    static func image(
        named name: String,
        accessibilityDescription: String? = nil
    ) -> NSImage? {
        let source = NSImage(
            systemSymbolName: name,
            accessibilityDescription: accessibilityDescription
        ) ?? privateSymbolsBundle?.image(forResource: name)
        guard let image = source?.copy() as? NSImage else { return nil }
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
