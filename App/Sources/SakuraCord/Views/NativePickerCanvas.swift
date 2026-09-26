import AppKit
import SwiftUI

@MainActor
final class NativePickerCanvas<Row: Identifiable>: NSView where Row.ID == String {
    private(set) var geometry = NativePickerLayout()
    private var rows: [Row] = []
    private var revision: Int?
    private var layoutWidth: CGFloat = -1
    private var height: ((Row, CGFloat) -> CGFloat)?
    private var content: ((Row) -> AnyView)?
    private var visible: ((Row) -> Void)?
    private var didScrollTo: ((Row) -> Void)?
    private var hosts: [String: NSView] = [:]
    private var nativeContent: ((Row, NSView?) -> NSView?)?
    private var visibleIDs: Set<String> = []
    private var deliveredRequest: UInt64?
    private var pendingDestinationID: String?
    private var notificationTask: Task<Void, Never>?
    private var isUpdating = false

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
        didScrollTo: @escaping (Row) -> Void = { _ in },
        nativeContent: ((Row, NSView?) -> NSView?)? = nil,
        content: @escaping (Row) -> AnyView
    ) {
        self.height = height
        self.content = content
        self.visible = visible
        self.didScrollTo = didScrollTo
        self.nativeContent = nativeContent
        let changed = self.revision != revision || abs(layoutWidth - width) > 0.5
        let anchorIndex = geometry.rows(intersecting: visibleRect).first
        let anchorID = anchorIndex.flatMap { self.rows.indices.contains($0) ? self.rows[$0].id : nil }
        let offset = anchorIndex.map { visibleRect.minY - geometry.origins[$0] } ?? 0
        self.rows = rows
        if changed || frame.height != max(geometry.contentHeight, enclosingScrollView?.contentSize.height ?? 0) {
            isUpdating = true
            self.revision = revision
            layoutWidth = width
            if changed {
                geometry = NativePickerLayout(ids: rows.map(\.id), heights: rows.map { height($0, width) })
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
            update(rows: rows, revision: revision, width: scroll.contentSize.width, height: height, visible: visible,
                didScrollTo: didScrollTo ?? { _ in }, nativeContent: nativeContent, content: content)
        } else {
            reconcile(refresh: false)
        }
    }

    func apply(_ request: NativePickerScrollPosition.Request?) {
        guard let request, deliveredRequest != request.sequence,
              let index = geometry.indicesByID[request.id], let scroll = enclosingScrollView else { return }
        deliveredRequest = request.sequence
        pendingDestinationID = request.id
        let row = CGRect(x: 0, y: geometry.origins[index], width: bounds.width, height: geometry.heights[index])
        if let anchor = request.anchor {
            let maximum = max(0, frame.height - scroll.contentSize.height)
            let originY = min(maximum, max(0, row.minY - (scroll.contentSize.height - row.height) * anchor.y))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: originY))
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            scrollToVisible(row)
        }
        reconcile(refresh: false)
    }

    private func reconcile(refresh: Bool) {
        guard let content, enclosingScrollView != nil else { return }
        let range = geometry.rows(intersecting: visibleRect)
        let retained = max(0, range.lowerBound - 1) ..< min(rows.count, range.upperBound + 1)
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
            view.frame = CGRect(x: 0, y: geometry.origins[index], width: bounds.width, height: geometry.heights[index])
            if view.superview == nil { addSubview(view) }
            hosts[row.id] = view
        }
        for view in recycled { remove(view) }
        sortSubviews({ left, right, _ in
            left.frame.minY < right.frame.minY ? .orderedAscending : .orderedDescending
        }, context: nil)
        let nextVisibleIDs = Set(range.map { rows[$0].id })
        if nextVisibleIDs != visibleIDs || pendingDestinationID != nil {
            // Avoid publishing observable section/load state inside an AppKit
            // layout or representable update, as in the timeline coordinator.
            notificationTask?.cancel()
            notificationTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                let currentRange = self.geometry.rows(intersecting: self.visibleRect)
                let entered = currentRange.filter { !self.visibleIDs.contains(self.rows[$0].id) }.map { self.rows[$0] }
                self.visibleIDs = Set(currentRange.map { self.rows[$0].id })
                for row in entered { self.visible?(row) }
                if let destination = self.pendingDestinationID,
                   let index = self.geometry.indicesByID[destination] {
                    self.didScrollTo?(self.rows[index])
                }
                self.pendingDestinationID = nil
            }
        }
    }

    func stop() {
        notificationTask?.cancel()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        for view in hosts.values { remove(view) }
        hosts.removeAll()
        visibleIDs.removeAll()
        content = nil
        visible = nil
        didScrollTo = nil
        nativeContent = nil
    }

    private func remove(_ view: NSView) {
        (view as? NSHostingView<AnyView>)?.rootView = AnyView(EmptyView())
        (view as? any NativePickerReusableRow)?.clear()
        view.removeFromSuperview()
    }
}
