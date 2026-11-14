import AppKit

final class ChannelContextMenuHitView: NSView {
    var menuProvider: (() -> NSMenu?)?
    var isSelected = false {
        didSet {
            updateNativeHoverPresentation()
        }
    }

    private weak var nativeRowView: NSTableRowView?
    private let nativeHoverView = ChannelNativeHoverRowView()
    private let neutralSelectionView = ChannelNeutralSelectionView()
    private let interactionView = ChannelNativeRowInteractionView()
    private var isHovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        interactionView.menuProvider = { [weak self] in
            self?.menuProvider?()
        }
        interactionView.hoverChanged = { [weak self] hovering in
            guard let self else { return }
            isHovering = hovering
            updateNativeHoverPresentation()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleNativeRowInstallation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            uninstallFromNativeRow()
        } else {
            scheduleNativeRowInstallation()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Browse Channels uses ordinary SwiftUI rows rather than table rows.
        // Handle their secondary clicks here; table rows keep their native host.
        guard nativeRowView == nil, bounds.contains(point),
              let event = window?.currentEvent, event.isContextClick
        else { return nil }
        return self
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    func uninstallFromNativeRow() {
        interactionView.resetHoverTracking()
        interactionView.removeFromSuperview()
        nativeHoverView.removeFromSuperview()
        neutralSelectionView.removeFromSuperview()
        nativeRowView = nil
        isHovering = false
    }

    private func scheduleNativeRowInstallation() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.installIntoNativeRowIfNeeded()
        }
    }

    private func installIntoNativeRowIfNeeded() {
        guard window != nil,
              let rowView = enclosingNativeRowView()
        else { return }
        guard nativeRowView !== rowView else {
            synchronizeNativeRowFrames()
            return
        }

        uninstallFromNativeRow()
        nativeRowView = rowView
        nativeHoverView.alphaValue = 0.18
        synchronizeNativeHoverGeometry()
        interactionView.frame = rowView.bounds
        interactionView.autoresizingMask = [.width, .height]
        rowView.addSubview(
            nativeHoverView,
            positioned: .below,
            relativeTo: nil
        )
        rowView.addSubview(neutralSelectionView, positioned: .below, relativeTo: nil)
        rowView.addSubview(
            interactionView,
            positioned: .above,
            relativeTo: nil
        )
        interactionView.refreshHoverTracking()
        updateNativeHoverPresentation()
    }

    private func enclosingNativeRowView() -> NSTableRowView? {
        var candidate = superview
        while let view = candidate {
            if let rowView = view as? NSTableRowView {
                return rowView
            }
            candidate = view.superview
        }
        return nil
    }

    private func synchronizeNativeRowFrames() {
        guard let nativeRowView else { return }
        synchronizeNativeHoverGeometry()
        interactionView.frame = nativeRowView.bounds
    }

    private func updateNativeHoverPresentation() {
        if let nativeRowView,
           let tableView = enclosingNativeTableView(near: nativeRowView),
           tableView.selectionHighlightStyle != .none
        {
            // Preserve native keyboard navigation, but draw a neutral selection
            // using exactly the same geometry as the hover highlight.
            tableView.selectionHighlightStyle = .none
            // Read-only channels have no composer to take focus, so typed
            // characters would otherwise jump to a channel with that prefix.
            tableView.allowsTypeSelect = false
        }
        neutralSelectionView.isHidden = !isSelected
        nativeHoverView.showsHover = isHovering && !isSelected
        guard nativeHoverView.showsHover || !neutralSelectionView.isHidden else { return }
        synchronizeNativeHoverGeometry()
    }

    private func synchronizeNativeHoverGeometry() {
        guard let nativeRowView else { return }

        let template: ChannelNativeHoverTemplate
        if let tableView = enclosingNativeTableView(near: nativeRowView) {
            if let selectionView = nativeSelectionView(in: tableView) {
                template = ChannelNativeHoverTemplate(
                    selectionView: selectionView,
                    fallbackRowBounds: nativeRowView.bounds
                )
                ChannelNativeHoverTemplateStore.shared.set(
                    template,
                    for: tableView
                )
            } else {
                template =
                    ChannelNativeHoverTemplateStore.shared.template(for: tableView)
                    ?? .fallback
            }
        } else {
            template = .fallback
        }

        template.apply(to: nativeHoverView, in: nativeRowView.bounds)
        // A reused sidebar table may carry a template from a shorter guild row.
        nativeHoverView.frame.size.height = max(0, nativeRowView.bounds.height - 2 * template.verticalInset)
        neutralSelectionView.frame = nativeHoverView.frame
        neutralSelectionView.layer?.cornerRadius = template.cornerRadius
        neutralSelectionView.layer?.cornerCurve = template.cornerCurve
        neutralSelectionView.layer?.maskedCorners = template.maskedCorners
    }

    private func enclosingNativeTableView(
        near rowView: NSTableRowView
    ) -> NSTableView? {
        var candidate = rowView.superview
        while let view = candidate {
            if let tableView = view as? NSTableView {
                return tableView
            }
            candidate = view.superview
        }
        return nil
    }

    private func nativeSelectionView(
        in tableView: NSTableView
    ) -> NSVisualEffectView? {
        for row in tableView.rows(in: tableView.visibleRect).integerRange {
            guard let visibleRow = tableView.rowView(
                atRow: row,
                makeIfNecessary: false
            ) else { continue }
            if let selectionView = visibleRow.subviews
                .compactMap({ $0 as? NSVisualEffectView })
                .first(where: {
                    !($0 is ChannelNativeHoverRowView)
                        && $0.material == .selection
                })
            {
                return selectionView
            }
        }
        return nil
    }
}

@MainActor
struct ChannelNativeHoverTemplate {
    static let fallback = ChannelNativeHoverTemplate(
        leadingInset: 5,
        trailingInset: 5,
        verticalInset: 2,
        height: nil,
        material: .selection,
        blendingMode: .withinWindow,
        state: .followsWindowActiveState,
        cornerRadius: 6,
        cornerCurve: .continuous,
        maskedCorners: [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                        .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    )

    let leadingInset: CGFloat
    let trailingInset: CGFloat
    let verticalInset: CGFloat
    let height: CGFloat?
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let state: NSVisualEffectView.State
    let cornerRadius: CGFloat
    let cornerCurve: CALayerCornerCurve
    let maskedCorners: CACornerMask

    init(
        selectionView: NSVisualEffectView,
        fallbackRowBounds: NSRect
    ) {
        let selectionRow = selectionView.superview?.bounds ?? fallbackRowBounds
        leadingInset = selectionView.frame.minX - selectionRow.minX
        trailingInset = selectionRow.maxX - selectionView.frame.maxX
        verticalInset = selectionView.frame.minY - selectionRow.minY
        height = selectionView.frame.height
        material = selectionView.material
        blendingMode = selectionView.blendingMode
        state = selectionView.state
        cornerRadius = selectionView.layer?.cornerRadius ?? 0
        cornerCurve = selectionView.layer?.cornerCurve ?? .circular
        maskedCorners = selectionView.layer?.maskedCorners ?? []
    }

    init(
        leadingInset: CGFloat,
        trailingInset: CGFloat,
        verticalInset: CGFloat,
        height: CGFloat?,
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode,
        state: NSVisualEffectView.State,
        cornerRadius: CGFloat,
        cornerCurve: CALayerCornerCurve,
        maskedCorners: CACornerMask
    ) {
        self.leadingInset = leadingInset
        self.trailingInset = trailingInset
        self.verticalInset = verticalInset
        self.height = height
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
        self.cornerRadius = cornerRadius
        self.cornerCurve = cornerCurve
        self.maskedCorners = maskedCorners
    }

    func frame(in rowBounds: NSRect) -> NSRect {
        NSRect(
            x: rowBounds.minX + leadingInset,
            y: rowBounds.minY + verticalInset,
            width: max(0, rowBounds.width - leadingInset - trailingInset),
            height: height ?? max(0, rowBounds.height - 2 * verticalInset)
        )
    }

    func apply(
        to hoverView: NSVisualEffectView,
        in rowBounds: NSRect
    ) {
        hoverView.frame = frame(in: rowBounds)
        hoverView.material = material
        hoverView.blendingMode = blendingMode
        hoverView.state = state
        hoverView.layer?.cornerRadius = cornerRadius
        hoverView.layer?.cornerCurve = cornerCurve
        hoverView.layer?.maskedCorners = maskedCorners
    }
}

@MainActor
final class ChannelNativeHoverTemplateStore {
    static let shared = ChannelNativeHoverTemplateStore()

    private final class Box: NSObject {
        let template: ChannelNativeHoverTemplate

        init(_ template: ChannelNativeHoverTemplate) {
            self.template = template
        }
    }

    private let templates = NSMapTable<NSTableView, Box>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    func template(for tableView: NSTableView) -> ChannelNativeHoverTemplate? {
        templates.object(forKey: tableView)?.template
    }

    func set(
        _ template: ChannelNativeHoverTemplate,
        for tableView: NSTableView
    ) {
        templates.setObject(Box(template), forKey: tableView)
    }
}

/// The inbox's neutral selection fill, sharing the hover template's bounds and corners.
private final class ChannelNeutralSelectionView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        updateFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    nonisolated override func accessibilityIsIgnored() -> Bool { true }
}

private final class ChannelNativeHoverRowView: NSVisualEffectView {
    var showsHover = false {
        didSet {
            guard showsHover != oldValue else { return }
            isHidden = !showsHover
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    nonisolated override func accessibilityIsIgnored() -> Bool {
        true
    }
}

private extension NSRange {
    var integerRange: Range<Int> {
        location ..< NSMaxRange(self)
    }
}

final class ChannelNativeRowInteractionView: NSView, WindowModalInputParticipant {
    func modalInputDidChange() {
        synchronizeHoverWithCurrentPointer()
        window?.invalidateCursorRects(for: self)
    }

    var menuProvider: (() -> NSMenu?)?
    var hoverChanged: ((Bool) -> Void)?
    var pointerLocationInWindowProvider: (() -> NSPoint?)?
    private var rowTrackingArea: NSTrackingArea?
    private weak var observedClipView: NSClipView?
    private var reportedHover = false

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        refreshHoverTracking()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshHoverTracking()
    }

    override func updateTrackingAreas() {
        if let rowTrackingArea {
            removeTrackingArea(rowTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .activeInKeyWindow,
                .inVisibleRect,
                .mouseEnteredAndExited,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        rowTrackingArea = area
        super.updateTrackingAreas()
        synchronizeHoverWithCurrentPointer()
    }

    override func mouseEntered(with event: NSEvent) {
        guard WindowModalCoordinator.allowsInput(for: self) else { return }
        synchronizeHover(atWindowPoint: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        setReportedHover(false)
    }

    func refreshHoverTracking() {
        updateClipViewObservation()
        synchronizeHoverWithCurrentPointer()
    }

    func resetHoverTracking() {
        stopObservingClipView()
        setReportedHover(false)
    }

    func synchronizeHover(atWindowPoint point: NSPoint?) {
        guard let point, window != nil, WindowModalCoordinator.allowsInput(for: self) else {
            setReportedHover(false)
            return
        }
        let localPoint = convert(point, from: nil)
        setReportedHover(
            bounds.contains(localPoint)
                && !visibleRect.isEmpty
                && visibleRect.contains(localPoint)
        )
    }

    private func synchronizeHoverWithCurrentPointer() {
        let point =
            pointerLocationInWindowProvider?()
            ?? window?.mouseLocationOutsideOfEventStream
        synchronizeHover(atWindowPoint: point)
    }

    private func setReportedHover(_ hovering: Bool) {
        guard reportedHover != hovering else { return }
        reportedHover = hovering
        hoverChanged?(hovering)
    }

    private func updateClipViewObservation() {
        let clipView = window == nil ? nil : enclosingScrollView?.contentView
        guard observedClipView !== clipView else { return }
        stopObservingClipView()
        guard let clipView else { return }
        observedClipView = clipView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView,
        )
    }

    private func stopObservingClipView() {
        if let observedClipView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: observedClipView
            )
        }
        observedClipView = nil
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        synchronizeHoverWithCurrentPointer()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point),
              let event = window?.currentEvent, event.isContextClick
        else { return nil }
        return self
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    nonisolated override func accessibilityIsIgnored() -> Bool {
        true
    }
}
