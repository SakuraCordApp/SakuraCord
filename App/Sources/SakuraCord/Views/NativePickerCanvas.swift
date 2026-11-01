import AppKit
import SwiftUI

@MainActor
final class NativePickerCanvas<Row: Identifiable>: NSView, NativePickerViewport where Row.ID == String {
    private(set) var geometry = NativePickerLayout()
    private var rows: [Row] = []
    private var revision: Int?
    private var layoutWidth: CGFloat = -1
    private var layoutScale = InterfaceScale.factor
    private var height: ((Row, CGFloat) -> CGFloat)?
    private var content: ((Row) -> AnyView)?
    private var visible: ((Row) -> Void)?
    private var didScrollTo: ((Row) -> Void)?
    private var topVisibleRowChanged: ((Row) -> Void)?
    private var pointerRowChanged: ((Row) -> Void)?
    private var rowActivated: ((Row) -> Void)?
    private var pointerLocationInWindow: NSPoint?
    private var pointerFollowsScrolling = false
    private var pointerRefreshTask: Task<Void, Never>?
    private var hosts: [String: NSView] = [:]
    private var nativeContent: ((Row, NSView?) -> NSView?)?
    private var visibleIDs: Set<String> = []
    private var deliveredRequest: UInt64?
    /// A scroll request received before the viewport has a height. Revealing
    /// against an empty viewport would bottom-align the row and leave the
    /// list scrolled once it grows.
    private var waitingRequest: NativePickerScrollPosition.Request?
    private var pendingDestinationID: String?
    private var notificationTask: Task<Void, Never>?
    private var isUpdating = false
    private var pinnedHeader: ((Row) -> Bool)?
    private var headerIndices: [Int] = []

    private struct PinnedHeader {
        let index: Int
        let frame: CGRect
    }

    private var currentPinnedHeader: PinnedHeader? {
        var low = 0
        var high = headerIndices.count
        while low < high {
            let middle = (low + high) / 2
            if geometry.origins[headerIndices[middle]] <= viewport.minY { low = middle + 1 } else { high = middle }
        }
        guard low > 0 else { return nil }
        let index = headerIndices[low - 1]
        let nextOrigin = low < headerIndices.count ? geometry.origins[headerIndices[low]] : geometry.contentHeight
        let headerY = min(max(geometry.origins[index], viewport.minY), nextOrigin - geometry.heights[index])
        return PinnedHeader(index: index, frame: CGRect(x: 0, y: headerY, width: bounds.width, height: geometry.heights[index]))
    }

    // SwiftUI can position this representable outside its composer's bounds.
    // AppKit's ancestor-clipped visibleRect is then empty despite a visible clip view.
    private var viewport: CGRect { enclosingScrollView?.documentVisibleRect ?? bounds }

    func viewportDidLayout() {
        viewportChanged()
        apply(waitingRequest)
    }

    var activatesRowsOnClick: Bool { rowActivated != nil }

    /// The pointer row for overlay clicks. Hosted SwiftUI rows cannot receive
    /// clicks forwarded by an event monitor, so the list activates the row.
    func rowID(at locationInWindow: NSPoint) -> String? {
        let point = convert(locationInWindow, from: nil)
        guard viewport.contains(point), currentPinnedHeader?.frame.contains(point) != true,
              let index = geometry.rows(intersecting: CGRect(x: point.x, y: point.y, width: 1, height: 0.01)).first,
              rows.indices.contains(index) else { return nil }
        return rows[index].id
    }

    func activateRow(id: String) {
        guard WindowModalCoordinator.allowsInput(for: self), let row = rows.first(where: { $0.id == id }) else { return }
        rowActivated?(row)
    }

    func synchronizePointerHighlight(at location: NSPoint?) {
        guard let pointerRowChanged, let window, window.isKeyWindow,
              WindowModalCoordinator.allowsInput(for: self) else { return }
        if let location { pointerLocationInWindow = location }
        pointerFollowsScrolling = true
        let point = convert(pointerLocationInWindow ?? window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        guard viewport.contains(point), currentPinnedHeader?.frame.contains(point) != true,
              let index = geometry.rows(intersecting: CGRect(x: point.x, y: point.y, width: 1, height: 0.01)).first,
              rows.indices.contains(index) else { return }
        pointerRowChanged(rows[index])
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    func update(
        rows: [Row], revision: Int, width: CGFloat,
        height: @escaping (Row, CGFloat) -> CGFloat,
        visible: @escaping (Row) -> Void,
        pinnedHeader: ((Row) -> Bool)? = nil,
        didScrollTo: @escaping (Row) -> Void = { _ in },
        topVisibleRowChanged: @escaping (Row) -> Void = { _ in },
        pointerRowChanged: ((Row) -> Void)? = nil,
        rowActivated: ((Row) -> Void)? = nil,
        nativeContent: ((Row, NSView?) -> NSView?)? = nil,
        content: @escaping (Row) -> AnyView
    ) {
        self.pinnedHeader = pinnedHeader
        self.height = height
        self.content = content
        self.visible = visible
        self.didScrollTo = didScrollTo
        self.topVisibleRowChanged = topVisibleRowChanged
        self.pointerRowChanged = pointerRowChanged
        self.rowActivated = rowActivated
        self.nativeContent = nativeContent
        let changed = self.revision != revision || abs(layoutWidth - width) > 0.5
            || layoutScale != InterfaceScale.factor
        let anchorIndex = geometry.rows(intersecting: viewport).first
        let anchorID = anchorIndex.flatMap { self.rows.indices.contains($0) ? self.rows[$0].id : nil }
        let offset = anchorIndex.map { viewport.minY - geometry.origins[$0] } ?? 0
        self.rows = rows
        if changed || frame.height != max(geometry.contentHeight, enclosingScrollView?.contentSize.height ?? 0) {
            isUpdating = true
            self.revision = revision
            layoutWidth = width
            layoutScale = InterfaceScale.factor
            if changed {
                geometry = NativePickerLayout(ids: rows.map(\.id), heights: rows.map { height($0, width) })
                headerIndices = pinnedHeader.map { isHeader in rows.indices.filter { isHeader(rows[$0]) } } ?? []
            }
            setFrameSize(NSSize(width: width, height: max(geometry.contentHeight, enclosingScrollView?.contentSize.height ?? 0)))
            if let scroll = enclosingScrollView {
                let proposedY = anchorID.flatMap { geometry.indicesByID[$0] }.map { geometry.origins[$0] + offset }
                    ?? scroll.contentView.bounds.minY
                let originY = min(max(0, proposedY), max(0, frame.height - scroll.contentSize.height))
                scroll.contentView.scroll(to: NSPoint(x: 0, y: originY))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            isUpdating = false
        }
        reconcile(refresh: true)
    }

    @objc private func viewportChanged() {
        guard !isUpdating, let scroll = enclosingScrollView else { return }
        if abs(layoutWidth - scroll.contentSize.width) > 0.5 || frame.height != max(geometry.contentHeight, scroll.contentSize.height),
           let revision, let height, let visible, let content {
            update(rows: rows, revision: revision, width: scroll.contentSize.width, height: height, visible: visible, pinnedHeader: pinnedHeader,
                didScrollTo: didScrollTo ?? { _ in }, topVisibleRowChanged: topVisibleRowChanged ?? { _ in }, pointerRowChanged: pointerRowChanged,
                rowActivated: rowActivated, nativeContent: nativeContent, content: content)
        } else {
            reconcile(refresh: false)
        }
        if pointerFollowsScrolling {
            pointerRefreshTask?.cancel()
            pointerRefreshTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self, pointerFollowsScrolling else { return }
                synchronizePointerHighlight(at: nil)
            }
        }
    }

    func apply(_ request: NativePickerScrollPosition.Request?) {
        guard let request, deliveredRequest != request.sequence,
              let index = geometry.indicesByID[request.id], let scroll = enclosingScrollView else { return }
        guard scroll.contentSize.height > 0 else {
            waitingRequest = request
            return
        }
        waitingRequest = nil
        deliveredRequest = request.sequence
        pointerFollowsScrolling = false
        pointerRefreshTask?.cancel()
        pendingDestinationID = request.id
        let row = CGRect(x: 0, y: geometry.origins[index], width: bounds.width, height: geometry.heights[index])
        if let anchor = request.anchor {
            let maximum = max(0, frame.height - scroll.contentSize.height)
            let originY = min(maximum, max(0, row.minY - (scroll.contentSize.height - row.height) * anchor.y))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: originY))
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            // Keep keyboard-selected commands below the pinned section heading.
            let headerHeight = headerIndices.last(where: { $0 <= index }).map { geometry.heights[$0] } ?? 0
            let viewport = scroll.documentVisibleRect
            let originY: CGFloat
            let inset = request.edgeInset
            if row.minY - headerHeight - inset < viewport.minY {
                originY = row.minY - headerHeight - inset
            } else if row.maxY + inset > viewport.maxY {
                originY = row.maxY + inset - viewport.height
            } else {
                originY = viewport.minY
            }
            let maximum = max(0, frame.height - scroll.contentSize.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maximum, max(0, originY))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        reconcile(refresh: false)
    }

    private func reconcile(refresh: Bool) {
        AppPerformanceSignposts.measureSync("PickerViewport") { reconcileRows(refresh: refresh) }
    }

    private func reconcileRows(refresh: Bool) {
        guard let content, enclosingScrollView != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let range = geometry.rows(intersecting: viewport)
        let pinned = currentPinnedHeader
        var retained = Array(max(0, range.lowerBound - 1) ..< min(rows.count, range.upperBound + 1))
        if let pinned, !retained.contains(pinned.index) { retained.insert(pinned.index, at: 0) }
        let retainedIDs = Set(retained.map { rows[$0].id })
        var recycled: [NSView] = []
        for id in Array(hosts.keys) where !retainedIDs.contains(id) {
            if let view = hosts.removeValue(forKey: id) { recycled.append(view) }
        }
        for index in retained {
            let row = rows[index]
            let existing = hosts[row.id]
            let view: NSView
            if let existing, !refresh {
                view = existing
            } else {
                let candidate = existing ?? recycled.first(where: { !($0 is NSHostingView<AnyView>) })
                if let native = nativeContent?(row, candidate) {
                    view = native
                } else {
                    let host = existing as? NSHostingView<AnyView>
                        ?? recycled.first(where: { $0 is NSHostingView<AnyView> }) as? NSHostingView<AnyView>
                        ?? NSHostingView(rootView: AnyView(EmptyView()))
                    host.rootView = content(row)
                    host.sizingOptions = []
                    view = host
                }
                recycled.removeAll { $0 === view }
                if let existing, existing !== view { recycled.append(existing) }
            }
            layout(view, at: index, pinned: pinned)
            if view.superview == nil { addSubview(view) }
            hosts[row.id] = view
        }
        for view in recycled { remove(view) }
        orderRows(pinned: pinned)
        let nextVisibleIDs = Set(range.map { rows[$0].id })
        if nextVisibleIDs != visibleIDs || pendingDestinationID != nil {
            // Avoid publishing observable section/load state inside an AppKit
            // layout or representable update, as in the timeline coordinator.
            notificationTask?.cancel()
            notificationTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                let currentRange = self.geometry.rows(intersecting: self.viewport)
                let entered = currentRange.filter { !self.visibleIDs.contains(self.rows[$0].id) }.map { self.rows[$0] }
                self.visibleIDs = Set(currentRange.map { self.rows[$0].id })
                for row in entered { self.visible?(row) }
                if let first = currentRange.first { self.topVisibleRowChanged?(self.rows[first]) }
                if let destination = self.pendingDestinationID,
                   let index = self.geometry.indicesByID[destination] {
                    self.didScrollTo?(self.rows[index])
                }
                self.pendingDestinationID = nil
            }
        }
    }

    private func layout(_ view: NSView, at index: Int, pinned: PinnedHeader?) {
        view.frame = pinned?.index == index ? pinned!.frame
            : CGRect(x: 0, y: geometry.origins[index], width: bounds.width, height: geometry.heights[index])
        // The glass header remains translucent, but rows are clipped below
        // it so their text and selection backgrounds cannot bleed through.
        let clippedTop = pinned?.index == index ? 0 : min(view.bounds.height, max(0, (pinned?.frame.maxY ?? 0) - view.frame.minY))
        if pinnedHeader != nil, clippedTop > 0 {
            let mask = view.layer?.mask as? CAShapeLayer ?? CAShapeLayer()
            mask.frame = view.bounds
            mask.path = CGPath(rect: CGRect(x: 0, y: clippedTop, width: view.bounds.width, height: view.bounds.height - clippedTop), transform: nil)
            view.layer?.mask = mask
        } else if pinnedHeader != nil {
            view.layer?.mask = nil
        }
    }

    private func orderRows(pinned: PinnedHeader?) {
        let pinnedView = pinned.flatMap { hosts[rows[$0.index].id] }
        sortSubviews({ left, right, context in
            if left === right { return .orderedSame }
            if let context {
                let header = Unmanaged<NSView>.fromOpaque(context).takeUnretainedValue()
                if left === header { return .orderedDescending }
                if right === header { return .orderedAscending }
            }
            return left.frame.minY < right.frame.minY ? .orderedAscending : .orderedDescending
        }, context: pinnedView.map { Unmanaged.passUnretained($0).toOpaque() })
    }

    func stop() {
        pointerRefreshTask?.cancel()
        notificationTask?.cancel()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        for view in hosts.values { remove(view) }
        hosts.removeAll()
        visibleIDs.removeAll()
        content = nil
        visible = nil
        didScrollTo = nil
        topVisibleRowChanged = nil
        pointerRowChanged = nil
        nativeContent = nil
        pinnedHeader = nil
        headerIndices = []
    }

    private func remove(_ view: NSView) {
        (view as? NSHostingView<AnyView>)?.rootView = AnyView(EmptyView())
        (view as? any NativePickerReusableRow)?.clear()
        view.removeFromSuperview()
    }
}
