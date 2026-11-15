import SwiftUI

extension ComposerIcon {
    var image: Image {
        switch self {
        case .gif: Image("gif.square", bundle: .module)
        case .sticker: SakuraCordSystemSymbol.stickerImage
        case .emoji: SakuraCordSystemSymbol.emojiFaceGrinningImage
        }
    }

    var help: String {
        switch self {
        case .gif: String(localized: "Choose GIF", bundle: #bundle)
        case .sticker: String(localized: "Choose sticker", bundle: #bundle)
        case .emoji: String(localized: "Choose emoji", bundle: #bundle)
        }
    }
}

struct ComposerIconView: View {
    let icon: ComposerIcon
    let appearance: ComposerBarAppearance
    var action: (() -> Void)?

    var body: some View {
        // A reorderable item must expose one stable view. The shared control
        // chooses between a button and an inert label; keep that conditional
        // beneath a layout container so SwiftUI retains the item's identity.
        HStack(spacing: 0) {
            ComposerActionButton(
                icon: icon.image,
                help: icon.help,
                iconSize: 19,
                size: appearance.accessoryButtonSize,
                appearance: appearance,
                action: action
            )
            .fixedSize()
        }
    }
}

extension ComposerBarAppearance {
    var accessoryButtonSize: CGFloat {
        self == .defaultStyle
            ? ChatChromeMetrics.composerAccessoryButtonSize
            : ChatChromeMetrics.composerButtonSize
    }
}
