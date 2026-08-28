import AppKit
import SwiftUI

nonisolated struct SelectionFieldCanvasRow: Hashable, Sendable {
    let title: String
    let subtitle: String?
    let leading: SelectionFieldLeading
    let isSelected: Bool
}

struct SelectionFieldResultList: NSViewRepresentable {
    let rows: [SelectionFieldCanvasRow]
    let rowHeight: CGFloat
    let allowsMultipleSelection: Bool
    let keyboardIndex: Int?
    let activate: (Int) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let canvas = SelectionFieldResultCanvas()
        canvas.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.documentView = canvas
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let canvas = scrollView.documentView as? SelectionFieldResultCanvas else {
            return
        }
        canvas.update(
            rows: rows,
            rowHeight: rowHeight,
            allowsMultipleSelection: allowsMultipleSelection,
            keyboardIndex: keyboardIndex,
            activate: activate
        )
    }
}

private final class SelectionFieldResultCanvas: NSView {
    private static let inset: CGFloat = 6
    private static let rowHorizontalInset: CGFloat = 6
    private static let rowSpacing: CGFloat = 0
    private static let indicatorSize: CGFloat = 18

    override var isFlipped: Bool { true }

    private var rows: [SelectionFieldCanvasRow] = []
    private var rowHeight: CGFloat = 44
    private var allowsMultipleSelection = true
    private var keyboardIndex: Int?
    private var hoveredIndex: Int?
    private var pressedIndex: Int?
    private var activate: (Int) -> Void = { _ in }
    private var trackingArea: NSTrackingArea?
    private var images: [URL: CGImage] = [:]
    private var imageTasks: [URL: Task<Void, Never>] = [:]
    private var accessibilityRows: [Int: SelectionFieldAccessibilityRow] = [:]
    private var boundsObserver: NSObjectProtocol?

    isolated deinit {
        for task in imageTasks.values { task.cancel() }
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clipView = enclosingScrollView?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcileAccessibilityRows()
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func update(
        rows: [SelectionFieldCanvasRow],
        rowHeight: CGFloat,
        allowsMultipleSelection: Bool,
        keyboardIndex: Int?,
        activate: @escaping (Int) -> Void
    ) {
        let previousKeyboardIndex = self.keyboardIndex
        self.rows = rows
        self.rowHeight = max(30, rowHeight)
        self.allowsMultipleSelection = allowsMultipleSelection
        self.keyboardIndex = keyboardIndex
        self.activate = activate
        if let hoveredIndex, !rows.indices.contains(hoveredIndex) {
            self.hoveredIndex = nil
        }
        rebuildDocumentFrame()
        pruneImages()
        reconcileAccessibilityRows()
        if previousKeyboardIndex != keyboardIndex, let keyboardIndex {
            scrollToVisible(rowRect(at: keyboardIndex))
        }
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reconcileAccessibilityRows()
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let newTrackingArea = NSTrackingArea(
            rect: .zero,
            options: [
                .activeInKeyWindow,
                .inVisibleRect,
                .mouseMoved,
                .mouseEnteredAndExited,
            ],
            owner: self
        )
        addTrackingArea(newTrackingArea)
        trackingArea = newTrackingArea
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let nextIndex = rowIndex(at: convert(event.locationInWindow, from: nil))
        guard nextIndex != hoveredIndex else { return }
        let previousIndex = hoveredIndex
        hoveredIndex = nextIndex
        if let previousIndex { setNeedsDisplay(rowRect(at: previousIndex)) }
        if let nextIndex { setNeedsDisplay(rowRect(at: nextIndex)) }
    }

    override func mouseExited(with event: NSEvent) {
        guard let hoveredIndex else { return }
        self.hoveredIndex = nil
        setNeedsDisplay(rowRect(at: hoveredIndex))
    }

    override func mouseDown(with event: NSEvent) {
        pressedIndex = rowIndex(at: convert(event.locationInWindow, from: nil))
        if let pressedIndex { setNeedsDisplay(rowRect(at: pressedIndex)) }
    }

    override func mouseUp(with event: NSEvent) {
        let releasedIndex = rowIndex(at: convert(event.locationInWindow, from: nil))
        let originalPressedIndex = pressedIndex
        pressedIndex = nil
        if let originalPressedIndex {
            setNeedsDisplay(rowRect(at: originalPressedIndex))
        }
        guard releasedIndex == originalPressedIndex, let releasedIndex else { return }
        activate(releasedIndex)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for index in visibleRowRange(intersecting: dirtyRect) {
            draw(row: rows[index], at: index)
        }
    }

    private func rebuildDocumentFrame() {
        frame = CGRect(
            x: 0,
            y: 0,
            width: enclosingScrollView?.contentSize.width ?? frame.width,
            height: max(1, Self.inset * 2 + CGFloat(rows.count) * rowStride)
        )
    }

    private var rowStride: CGFloat {
        rowHeight + Self.rowSpacing
    }

    private func rowRect(at index: Int) -> CGRect {
        CGRect(
            x: Self.rowHorizontalInset,
            y: Self.inset + CGFloat(index) * rowStride,
            width: max(0, bounds.width - Self.rowHorizontalInset * 2),
            height: rowHeight
        )
    }

    private func rowIndex(at point: CGPoint) -> Int? {
        guard point.x >= Self.rowHorizontalInset,
              point.x <= bounds.maxX - Self.rowHorizontalInset,
              point.y >= Self.inset
        else { return nil }
        let index = Int((point.y - Self.inset) / rowStride)
        guard rows.indices.contains(index), rowRect(at: index).contains(point) else {
            return nil
        }
        return index
    }

    private func visibleRowRange(intersecting rect: CGRect) -> Range<Int> {
        guard !rows.isEmpty else { return 0 ..< 0 }
        let lower = max(0, Int(((rect.minY - Self.inset) / rowStride).rounded(.down)))
        let upper = min(
            rows.count,
            Int(((rect.maxY - Self.inset) / rowStride).rounded(.up)) + 1
        )
        return lower ..< max(lower, upper)
    }

    private func draw(row: SelectionFieldCanvasRow, at index: Int) {
        let rect = rowRect(at: index)
        let shape = NSBezierPath(
            roundedRect: rect,
            xRadius: 7,
            yRadius: 7
        )

        if hoveredIndex == index {
            NSColor.labelColor.withAlphaComponent(0.075).setFill()
            shape.fill()
        }
        if keyboardIndex == index {
            NSColor.sakuraCordAccentColor.withAlphaComponent(0.10).setFill()
            shape.fill()
            NSColor.sakuraCordAccentColor.withAlphaComponent(0.78).setStroke()
            shape.lineWidth = 1.25
            shape.stroke()
        }
        if pressedIndex == index {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            shape.fill()
        }

        let leadingRect = CGRect(
            x: rect.minX + 9,
            y: rect.midY - 12,
            width: 24,
            height: 24
        )
        let hasLeading = row.leading != .none
        if hasLeading {
            draw(leading: row.leading, in: leadingRect)
        }

        let indicatorRect = CGRect(
            x: rect.maxX - 10 - Self.indicatorSize,
            y: rect.midY - Self.indicatorSize / 2,
            width: Self.indicatorSize,
            height: Self.indicatorSize
        )
        drawSelectionIndicator(
            selected: row.isSelected,
            in: indicatorRect
        )

        let titleX = hasLeading ? leadingRect.maxX + 9 : rect.minX + 10
        let subtitleFont = NSFont.systemFont(ofSize: 12)
        let subtitleWidth = row.subtitle.map {
            min(
                max(0, rect.width * 0.42),
                ceil(($0 as NSString).size(
                    withAttributes: [.font: subtitleFont]
                ).width)
            )
        } ?? 0
        let subtitleRect = CGRect(
            x: indicatorRect.minX - 8 - subtitleWidth,
            y: rect.midY - 8,
            width: subtitleWidth,
            height: 17
        )
        let titleRect = CGRect(
            x: titleX,
            y: rect.midY - 9,
            width: max(0, subtitleRect.minX - titleX - (subtitleWidth > 0 ? 10 : 0)),
            height: 19
        )
        drawText(
            row.title,
            in: titleRect,
            font: .systemFont(ofSize: 14, weight: .medium),
            color: .labelColor
        )
        if let subtitle = row.subtitle {
            drawText(
                subtitle,
                in: subtitleRect,
                font: subtitleFont,
                color: .secondaryLabelColor,
                alignment: .right
            )
        }
    }

    private func draw(leading: SelectionFieldLeading, in rect: CGRect) {
        switch leading {
        case .none:
            return
        case .systemImage(let name):
            drawSystemImage(name, in: rect)
        case .text(let value):
            drawText(
                value,
                in: rect.offsetBy(dx: 0, dy: 3),
                font: .systemFont(ofSize: 17),
                color: .labelColor,
                alignment: .center
            )
        case .remoteImage(let url, let fallback, let imageShape):
            drawRemoteImage(
                url: url,
                fallback: fallback,
                shape: imageShape,
                in: rect
            )
        }
    }

    private func drawSelectionIndicator(selected: Bool, in rect: CGRect) {
        if allowsMultipleSelection {
            let box = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            (selected
                ? NSColor.sakuraCordAccentColor
                : NSColor.tertiaryLabelColor.withAlphaComponent(0.7))
                .setStroke()
            box.lineWidth = selected ? 1.7 : 1.4
            if selected {
                NSColor.sakuraCordAccentColor.setFill()
                box.fill()
            }
            box.stroke()
        }
        guard selected else { return }
        drawSystemImage(
            "checkmark",
            in: allowsMultipleSelection ? rect.insetBy(dx: 3, dy: 3) : rect,
            color: allowsMultipleSelection ? .white : .sakuraCordAccentColor,
            pointSize: allowsMultipleSelection ? 9 : 13,
            weight: .bold
        )
    }

    private func drawSystemImage(
        _ name: String,
        in rect: CGRect,
        color: NSColor = .secondaryLabelColor,
        pointSize: CGFloat = 16,
        weight: NSFont.Weight = .medium
    ) {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: pointSize,
            weight: weight
        ).applying(
            NSImage.SymbolConfiguration(paletteColors: [color])
        )
        guard let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration)
        else { return }
        let destination = NativeTimelineSymbolGeometry.opticallyFitted(
            sourceSize: image.size,
            alignmentRect: image.alignmentRect,
            in: rect
        )
        image.draw(
            in: destination,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    private func drawRemoteImage(
        url: URL?,
        fallback: String,
        shape: SelectionFieldImageShape,
        in rect: CGRect
    ) {
        let path: NSBezierPath = switch shape {
        case .circle:
            NSBezierPath(ovalIn: rect)
        case .roundedRectangle:
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let url, let image = images[url], let context = NSGraphicsContext.current?.cgContext {
            let destination = QuickSwitcherIconGeometry.aspectFillRect(
                imageSize: CGSize(width: image.width, height: image.height),
                in: rect
            )
            context.interpolationQuality = .high
            context.translateBy(x: 0, y: destination.minY * 2 + destination.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: destination)
        } else {
            NSColor.sakuraCordAccentColor.withAlphaComponent(0.82).setFill()
            path.fill()
            drawText(
                String(fallback.prefix(1)).uppercased(),
                in: rect.offsetBy(dx: 0, dy: 5),
                font: .systemFont(ofSize: 10, weight: .semibold),
                color: .white,
                alignment: .center
            )
        }
        NSGraphicsContext.restoreGraphicsState()
        if let url, images[url] == nil {
            requestImage(url)
        }
    }

    private func drawText(
        _ value: String,
        in rect: CGRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private func requestImage(_ url: URL) {
        guard images[url] == nil, imageTasks[url] == nil else { return }
        imageTasks[url] = Task { [weak self] in
            let image = await SharedDecodedImageLoader.shared.image(
                for: url,
                maximumPixelDimension: 96,
                priority: .visible
            )
            guard !Task.isCancelled, let self else { return }
            imageTasks[url] = nil
            guard let image else { return }
            images[url] = image
            for index in rows.indices where rows[index].leading.imageURL == url {
                setNeedsDisplay(rowRect(at: index))
            }
        }
    }

    private func pruneImages() {
        let wantedURLs = Set(rows.compactMap { $0.leading.imageURL })
        for (url, task) in imageTasks where !wantedURLs.contains(url) {
            task.cancel()
            imageTasks[url] = nil
        }
        for url in images.keys where !wantedURLs.contains(url) {
            images[url] = nil
        }
    }

    private func reconcileAccessibilityRows() {
        guard let scrollView = enclosingScrollView else { return }
        let visibleRect = scrollView.documentVisibleRect
        var wanted = Set(visibleRowRange(intersecting: visibleRect))
        if let keyboardIndex { wanted.insert(keyboardIndex) }

        for index in wanted where rows.indices.contains(index) {
            let proxy = accessibilityRows[index] ?? {
                let value = SelectionFieldAccessibilityRow()
                addSubview(value)
                accessibilityRows[index] = value
                return value
            }()
            proxy.configure(
                row: rows[index],
                activate: { [weak self] in self?.activate(index) }
            )
            proxy.frame = rowRect(at: index)
        }
        for (index, proxy) in accessibilityRows where !wanted.contains(index) {
            proxy.removeFromSuperview()
            accessibilityRows[index] = nil
        }
        setAccessibilityChildren(
            wanted.sorted().compactMap { accessibilityRows[$0] }
        )
    }
}

private final class SelectionFieldAccessibilityRow: NSView {
    private var activation: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(
        row: SelectionFieldCanvasRow,
        activate: @escaping () -> Void
    ) {
        activation = activate
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(
            [row.title, row.subtitle].compactMap { $0 }.joined(separator: ", ")
        )
        setAccessibilityValue(row.isSelected ? "Selected" : "Not selected")
    }

    override func accessibilityPerformPress() -> Bool {
        guard let activation else { return false }
        activation()
        return true
    }
}

private extension SelectionFieldLeading {
    var imageURL: URL? {
        guard case .remoteImage(let url, _, _) = self else { return nil }
        return url
    }
}
