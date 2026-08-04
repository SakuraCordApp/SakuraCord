import AppKit

@MainActor
enum ContextMenuItemSupport {
    static func configure(
        _ item: NSMenuItem,
        title: String,
        systemImage: String,
        isDestructive: Bool = false
    ) {
        let baseConfiguration = NSImage.SymbolConfiguration(
            pointSize: 13,
            weight: .regular
        )
        let configuration = isDestructive
            ? baseConfiguration.applying(
                NSImage.SymbolConfiguration(
                    paletteColors: [.systemRed]
                )
            )
            : baseConfiguration
        if let image = NSImage(
            systemSymbolName: systemImage,
            accessibilityDescription: title
        )?.withSymbolConfiguration(configuration) {
            image.isTemplate = !isDestructive
            item.image = image
        }
        if #available(macOS 27.0, *) {
            item.preferredImageVisibility = .visible
        }
        if isDestructive {
            item.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.foregroundColor: NSColor.systemRed]
            )
        }
    }

    static func configure(_ item: NSMenuItem, image: NSImage) {
        image.isTemplate = false
        item.image = image
        if #available(macOS 27.0, *) {
            item.preferredImageVisibility = .visible
        }
    }
}
