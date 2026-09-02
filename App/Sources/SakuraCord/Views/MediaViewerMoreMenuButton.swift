import AppKit
import SwiftUI

/// Uses SakuraCord's AppKit menu path so macOS 27 cannot suppress item icons.
struct MediaViewerMoreMenuButton: NSViewRepresentable {
    let item: RichMediaItem
    let copyImage: () -> Void
    let copyLink: () -> Void
    let copyAttachmentID: () -> Void
    let save: () -> Void
    let open: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(configuration)
    }

    func makeNSView(context: Context) -> MediaViewerMenuNSControl {
        let button = MediaViewerMenuNSControl(frame: .zero)
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.setAccessibilityLabel("More")
        button.toolTip = "More"
        return button
    }

    func updateNSView(
        _ nsView: MediaViewerMenuNSControl,
        context: Context
    ) {
        context.coordinator.update(configuration)
    }

    private var configuration: Configuration {
        Configuration(
            item: item,
            copyImage: copyImage,
            copyLink: copyLink,
            copyAttachmentID: copyAttachmentID,
            save: save,
            open: open
        )
    }

    struct Configuration {
        let item: RichMediaItem
        let copyImage: () -> Void
        let copyLink: () -> Void
        let copyAttachmentID: () -> Void
        let save: () -> Void
        let open: () -> Void
    }

    @MainActor
    final class Coordinator: NSObject {
        private var configuration: Configuration

        init(_ configuration: Configuration) {
            self.configuration = configuration
        }

        func update(_ configuration: Configuration) {
            self.configuration = configuration
        }

        @objc func showMenu(_ sender: NSControl) {
            makeMenu().popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: -4),
                in: sender
            )
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            if case .image = configuration.item.kind {
                menu.addItem(
                    menuItem(
                        "Copy Image",
                        systemImage: "document.on.document.fill",
                        action: #selector(copyImageFromMenu)
                    )
                )
            }
            menu.addItem(
                menuItem(
                    "Copy Media Link",
                    systemImage: "link",
                    action: #selector(copyLinkFromMenu)
                )
            )
            menu.addItem(
                menuItem(
                    "Copy Attachment ID",
                    systemImage: "number.square.fill",
                    action: #selector(copyAttachmentIDFromMenu)
                )
            )
            menu.addItem(.separator())
            let detailsItem = menuItem(
                "View Details",
                systemImage: "info.circle",
                action: nil
            )
            detailsItem.submenu = detailsMenu()
            menu.addItem(detailsItem)
            menu.addItem(.separator())
            menu.addItem(
                menuItem(
                    "Save Media…",
                    systemImage: "arrow.down.to.line",
                    action: #selector(saveFromMenu)
                )
            )
            menu.addItem(
                menuItem(
                    "Open in Browser",
                    systemImage: "arrow.up.forward.app",
                    action: #selector(openFromMenu)
                )
            )
            return menu
        }

        private func detailsMenu() -> NSMenu {
            let menu = NSMenu(title: "View Details")
            menu.autoenablesItems = false
            menu.addItem(
                detailItem(
                    title: "Filename",
                    subtitle: filenameDescription,
                    action: #selector(copyFilenameFromMenu)
                )
            )
            menu.addItem(
                detailItem(
                    title: "Size",
                    subtitle: sizeDescription,
                    action: #selector(copySizeFromMenu)
                )
            )
            return menu
        }

        private var sizeDescription: String {
            let item = configuration.item
            let dimensions: String? = if let width = item.width,
                                         let height = item.height,
                                         width > 0,
                                         height > 0
            {
                "\(width)x\(height)"
            } else {
                nil
            }
            let fileSize = MediaViewerDetails.fileSize(item)
            return switch (dimensions, fileSize) {
            case let (.some(dimensions), .some(fileSize)):
                "\(dimensions) (\(fileSize))"
            case let (.some(dimensions), .none):
                dimensions
            case let (.none, .some(fileSize)):
                fileSize
            case (.none, .none):
                MediaViewerDetails.kind(item)
            }
        }

        private var filenameDescription: String {
            let title = configuration.item.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty
                ? configuration.item.url.lastPathComponent
                : title
        }

        private func detailItem(
            title: String,
            subtitle: String,
            action: Selector
        ) -> NSMenuItem {
            let item = NSMenuItem(
                title: title,
                action: action,
                keyEquivalent: ""
            )
            item.target = self
            item.subtitle = subtitle
            item.isEnabled = true
            return item
        }

        private func menuItem(
            _ title: String,
            systemImage: String? = nil,
            action: Selector?
        ) -> NSMenuItem {
            let item = NSMenuItem(
                title: title,
                action: action,
                keyEquivalent: ""
            )
            item.target = action == nil ? nil : self
            item.isEnabled = true
            if let systemImage {
                ContextMenuItemSupport.configure(
                    item,
                    title: title,
                    systemImage: systemImage
                )
            }
            return item
        }

        @objc private func copyImageFromMenu() {
            configuration.copyImage()
        }

        @objc private func copyLinkFromMenu() {
            configuration.copyLink()
        }

        @objc private func copyAttachmentIDFromMenu() {
            configuration.copyAttachmentID()
        }

        @objc private func copyFilenameFromMenu() {
            MediaViewerActionService.copyText(filenameDescription)
        }

        @objc private func copySizeFromMenu() {
            MediaViewerActionService.copyText(sizeDescription)
        }

        @objc private func saveFromMenu() {
            perform(
                #selector(performDeferredSave),
                with: nil,
                afterDelay: 0
            )
        }

        @objc private func openFromMenu() {
            perform(
                #selector(performDeferredOpen),
                with: nil,
                afterDelay: 0
            )
        }

        @objc private func performDeferredSave() {
            configuration.save()
        }

        @objc private func performDeferredOpen() {
            configuration.open()
        }
    }
}

@MainActor
final class MediaViewerMenuNSControl: NSControl {
    private var pointerIsInside = false
    private var pointerTrackingArea: NSTrackingArea?
    private let symbol: NSImage?

    override init(frame frameRect: NSRect) {
        let baseConfiguration = NSImage.SymbolConfiguration(
            pointSize: 13,
            weight: .medium
        )
        let configuration = baseConfiguration.applying(
            NSImage.SymbolConfiguration(
                paletteColors: [.labelColor]
            )
        )
        symbol = NSImage(
            systemSymbolName: "ellipsis",
            accessibilityDescription: "More"
        )?.withSymbolConfiguration(configuration)
        symbol?.isTemplate = false
        super.init(frame: frameRect)
        focusRingType = .none
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBackground()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let symbol else { return }
        let size = symbol.size
        symbol.draw(
            in: NSRect(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        )
    }

    override func updateTrackingAreas() {
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(trackingArea)
        pointerTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        pointerIsInside = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        pointerIsInside = false
        updateBackground()
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor
            .withAlphaComponent(0.22)
            .cgColor
        sendAction(action, to: target)
        updateBackground()
    }

    override func accessibilityPerformPress() -> Bool {
        sendAction(action, to: target)
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = pointerIsInside
                ? NSColor.labelColor.withAlphaComponent(0.14).cgColor
                : NSColor.clear.cgColor
        }
    }
}
