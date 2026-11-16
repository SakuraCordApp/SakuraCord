import AppKit
import SakuraCordModels
import SwiftUI

/// Recycled by the emoji picker's viewport canvas. Text and image loading are
/// limited to visible rows; scrolling never constructs SwiftUI command cells.
final class NativeCommandPickerRow: NSView, NativePickerReusableRow {
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let attribution = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var row: ApplicationCommandDocumentRow?
    private var choose: ((ApplicationCommand) -> Void)?
    private var highlight: ((String) -> Void)?
    private var imageTask: Task<Void, Never>?
    private var imageIdentity: String?
    private var tracking: NSTrackingArea?
    private var pressedID: String?
    private var titleWidth: CGFloat = 0
    private var detailWidth: CGFloat = 0
    private var attributionWidth: CGFloat = 0
    private var appliedScale: CGFloat = 0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for label in [title, subtitle, detail, attribution] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.masksToBounds = true
        icon.setAccessibilityElement(false)
        addSubview(icon)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ row: ApplicationCommandDocumentRow, selected: Bool, cornerRadius: CGFloat,
                   colorScheme: ColorScheme, choose: @escaping (ApplicationCommand) -> Void,
                   highlight: @escaping (String) -> Void) {
        let changed = self.row?.id != row.id || self.row?.command != row.command || self.row?.title != row.title
            || appliedScale != InterfaceScale.factor
        appliedScale = InterfaceScale.factor
        self.row = row
        self.choose = choose
        self.highlight = highlight
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = (selected && row.command != nil
            ? (colorScheme == .dark ? NSColor.white : NSColor.black).withAlphaComponent(0.10) : .clear).cgColor
        if changed {
            pressedID = nil
            title.stringValue = row.title
            title.font = .interfaceSystemFont(ofSize: row.command == nil ? 12 : 13, weight: .semibold)
            title.textColor = row.command == nil ? .secondaryLabelColor : .labelColor
            subtitle.stringValue = row.subtitle
            subtitle.font = .interfaceSystemFont(ofSize: 12)
            subtitle.textColor = .secondaryLabelColor
            detail.stringValue = row.detail
            detail.font = .interfaceSystemFont(ofSize: 11)
            detail.textColor = .tertiaryLabelColor
            attribution.stringValue = row.command == nil ? "" : row.application?.name ?? ""
            attribution.font = .interfaceSystemFont(ofSize: 11)
            attribution.textColor = .tertiaryLabelColor
            setAccessibilityRole(row.command == nil ? .staticText : .button)
            setAccessibilityLabel([row.title, row.detail, row.subtitle, attribution.stringValue].filter { !$0.isEmpty }.joined(separator: ", "))
            setAccessibilityIdentifier(row.command.map { "application-command-\($0.id)" } ?? row.id)
            // Measure the unbounded string, not NSTextField's previous frame.
            titleWidth = naturalWidth(of: title)
            detailWidth = naturalWidth(of: detail)
            attributionWidth = naturalWidth(of: attribution)
        }
        updateImage(row, colorScheme: colorScheme)
        setAccessibilityValue(selected ? "Selected" : nil)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let row else { return }
        let header = row.command == nil
        let iconSize = InterfaceScale.metric(header ? 16 : 28)
        let textX = row.showsIcon ? InterfaceScale.metric(9) + iconSize + InterfaceScale.metric(9) : InterfaceScale.metric(10)
        icon.isHidden = !row.showsIcon
        icon.frame = CGRect(x: InterfaceScale.metric(9), y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        icon.layer?.cornerRadius = InterfaceScale.metric(header ? 4 : 8)
        let available = max(0, bounds.width - textX - InterfaceScale.metric(10))
        let attributionWidth = min(self.attributionWidth, available * 0.22)
        attribution.frame = CGRect(x: bounds.width - InterfaceScale.metric(10) - attributionWidth, y: InterfaceScale.metric(15), width: attributionWidth, height: InterfaceScale.metric(16))
        let contentWidth = max(0, available - (attributionWidth > 0 ? attributionWidth + InterfaceScale.metric(12) : 0))
        let detailWidth = min(self.detailWidth, contentWidth * 0.4)
        let titleWidth = header ? available : min(self.titleWidth, max(0, contentWidth - (detailWidth > 0 ? detailWidth + InterfaceScale.metric(7) : 0)))
        title.frame = CGRect(x: textX, y: header ? InterfaceScale.metric(7) : InterfaceScale.metric(5), width: titleWidth, height: InterfaceScale.metric(18))
        detail.frame = CGRect(x: textX + titleWidth + InterfaceScale.metric(7), y: InterfaceScale.metric(7), width: detailWidth, height: InterfaceScale.metric(16))
        subtitle.frame = CGRect(x: textX, y: InterfaceScale.metric(24), width: contentWidth, height: InterfaceScale.metric(17))
    }

    private func naturalWidth(of label: NSTextField) -> CGFloat {
        guard !label.stringValue.isEmpty else { return 0 }
        return ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font ?? NSFont.interfaceSystemFont(ofSize: 12)]).width) + 5
    }

    private func updateImage(_ row: ApplicationCommandDocumentRow, colorScheme: ColorScheme) {
        let url = row.showsIcon ? row.application?.displayIconURL : nil
        let size = InterfaceScale.metric(row.command == nil ? 16 : 28)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let identity = "\(row.isFrequent):\(row.application?.id ?? ""):\(row.application?.name ?? ""):\(url?.absoluteString ?? ""):\(size):\(scale):\(colorScheme)"
        guard identity != imageIdentity else { return }
        imageTask?.cancel()
        imageIdentity = identity
        icon.image = nil
        if row.isFrequent, row.command == nil {
            icon.image = symbolImage("clock.fill", size: size, scale: scale, colorScheme: colorScheme)
        } else if row.application?.id == SakuraCordBuiltInCommands.application.id {
            icon.image = CommandGeneratedIcon.sakuraFlower
        } else if let url {
            if let cached = SharedDecodedImageLoader.shared.cachedImage(for: url, maximumPixelDimension: 64) {
                icon.image = NSImage(cgImage: cached, size: .zero)
            } else {
                imageTask = Task { @MainActor [weak self] in
                    guard let image = await SharedDecodedImageLoader.shared.image(for: url, maximumPixelDimension: 64, priority: .visible),
                          !Task.isCancelled, let self, self.imageIdentity == identity else { return }
                    self.icon.image = NSImage(cgImage: image, size: .zero)
                }
            }
        } else {
            icon.image = CommandGeneratedIcon.image(
                symbol: row.application?.id == DiscordBuiltInCommands.application.id ? "slash.circle.fill" : nil,
                initials: row.application.map { String($0.name.prefix(2)).uppercased() } ?? "/",
                size: size, colorScheme: colorScheme, scale: scale
            )
        }
    }

    private func symbolImage(_ name: String, size: CGFloat, scale: CGFloat, colorScheme: ColorScheme) -> NSImage? {
        // Use resolved bitmap artwork, as for downloaded icons. Template symbols
        // otherwise join the glass foreground's separate compositing treatment.
        SystemSymbolImageCache.rasterizedConfiguredImage(
            named: name, pointSize: size, weight: .regular,
            color: (colorScheme == .dark ? NSColor.white : .black).withAlphaComponent(0.65),
            scale: scale
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        self.tracking = tracking
    }

    override func mouseMoved(with event: NSEvent) {
        guard WindowModalCoordinator.allowsInput(for: self), let row, row.command != nil else { return }
        highlight?(row.id)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if WindowModalCoordinator.allowsInput(for: self) { pressedID = row?.id }
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressedID = nil }
        guard pressedID == row?.id, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        _ = activate()
    }
    override func isAccessibilityElement() -> Bool { true }
    nonisolated override func accessibilityActionNames() -> [NSAccessibility.Action] {
        MainActor.assumeIsolated { row?.command == nil ? [] : [.press] }
    }
    nonisolated override func accessibilityPerformPress() -> Bool { MainActor.assumeIsolated { activate() } }
    private func activate() -> Bool {
        guard WindowModalCoordinator.allowsInput(for: self), let command = row?.command, let choose else { return false }
        choose(command)
        return true
    }
    func clear() {
        imageTask?.cancel()
        imageTask = nil
        imageIdentity = nil
        icon.image = nil
        row = nil
        choose = nil
        highlight = nil
        pressedID = nil
    }
}
