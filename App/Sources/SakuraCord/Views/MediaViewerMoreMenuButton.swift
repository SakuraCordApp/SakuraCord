import AppKit
import SwiftUI

/// Uses SakuraCord's AppKit menu path so macOS 27 cannot suppress item icons.
struct MediaViewerMoreMenuButton: NSViewRepresentable {
    let item: RichMediaItem
    let copyImage: () -> Void
    let copyLink: () -> Void
    let copyAttachmentID: () -> Void
    let saveActions: MediaSaveMenuActions
    let open: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(bridge: self)
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
        context.coordinator.bridge = self
    }

    @MainActor
    final class Coordinator: NSObject {
        var bridge: MediaViewerMoreMenuButton

        init(bridge: MediaViewerMoreMenuButton) {
            self.bridge = bridge
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
            if case .image = bridge.item.kind {
                menu.addItem(ContextMenuItemSupport.item("Copy Image", systemImage: "document.on.document.fill") { [self] in
                    bridge.copyImage()
                })
            }
            menu.addItem(ContextMenuItemSupport.item("Copy Media Link", systemImage: "link") { [self] in
                bridge.copyLink()
            })
            menu.addItem(ContextMenuItemSupport.item("Copy Attachment ID", systemImage: "number.square.fill") { [self] in
                bridge.copyAttachmentID()
            })
            menu.addItem(.separator())
            let detailsItem = ContextMenuItemSupport.item("View Details", systemImage: "info.circle", action: nil)
            detailsItem.submenu = detailsMenu()
            menu.addItem(detailsItem)
            menu.addItem(.separator())
            if bridge.item.canSave {
                menu.addItem(
                    MediaSaveMenuBuilder.submenuItem(
                        "Save Media",
                        systemImage: "arrow.down.to.line",
                        actions: bridge.saveActions
                    )
                )
            }
            menu.addItem(ContextMenuItemSupport.item("Open in Browser", systemImage: "arrow.up.forward.app") { [self] in
                perform(#selector(performDeferredOpen), with: nil, afterDelay: 0)
            })
            return menu
        }

        private func detailsMenu() -> NSMenu {
            let menu = NSMenu(title: "View Details")
            menu.autoenablesItems = false
            let filename = ContextMenuItemSupport.item("Filename") { [self] in Pasteboard.copy(filenameDescription) }
            filename.subtitle = filenameDescription
            menu.addItem(filename)
            let size = ContextMenuItemSupport.item("Size") { [self] in Pasteboard.copy(sizeDescription) }
            size.subtitle = sizeDescription
            menu.addItem(size)
            return menu
        }

        private var sizeDescription: String {
            let item = bridge.item
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
            let title = bridge.item.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty
                ? bridge.item.url.lastPathComponent
                : title
        }

        @objc private func performDeferredOpen() {
            bridge.open()
        }
    }
}

@MainActor
final class MediaViewerMenuNSControl: NSControl {
    override var isEnabled: Bool {
        didSet { updateBackground() }
    }
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
        guard isEnabled, WindowModalCoordinator.allowsInput(for: self) else { return }
        pointerIsInside = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        pointerIsInside = false
        updateBackground()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, WindowModalCoordinator.allowsInput(for: self) else { return }
        layer?.backgroundColor = NSColor.labelColor
            .withAlphaComponent(0.22)
            .cgColor
        sendAction(action, to: target)
        updateBackground()
    }

    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, WindowModalCoordinator.allowsInput(for: self) else { return false }
        return sendAction(action, to: target)
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = pointerIsInside && isEnabled
                ? NSColor.labelColor.withAlphaComponent(0.14).cgColor
                : NSColor.clear.cgColor
        }
    }
}
