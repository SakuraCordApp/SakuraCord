import AppKit
import SwiftUI

/// Where the workspace's columns are in the window, published by
/// `WorkspaceColumnsView` each time it places them, on every frame of a
/// motion. `WorkspaceTitlebarView` places each column's toolbar items from
/// it in the same frame, so they move with their column.
@MainActor
final class WorkspaceColumnsGeometry {
    struct Column: Equatable {
        let id: String
        /// In window coordinates.
        let minX: CGFloat
        let maxX: CGFloat
        let isFullWidth: Bool
        /// How far a full-width side chat has widened from the pane: 0 in the
        /// pane, 1 at full width.
        let widening: CGFloat
    }

    static let shared = WorkspaceColumnsGeometry()

    /// The conversation's span in window coordinates, or nil without one.
    private(set) var conversation: ClosedRange<CGFloat>?
    private(set) var columns: [Column] = []
    private var observers: [WeakObserver] = []

    private struct WeakObserver {
        weak var view: WorkspaceTitlebarView?
    }

    private init() {}

    func update(conversation: ClosedRange<CGFloat>?, columns: [Column]) {
        guard conversation != self.conversation || columns != self.columns else { return }
        self.conversation = conversation
        self.columns = columns
        observers.removeAll { $0.view == nil }
        for observer in observers {
            observer.view?.placeGroups()
        }
    }

    fileprivate func observe(_ view: WorkspaceTitlebarView) {
        observers.removeAll { $0.view == nil || $0.view === view }
        observers.append(WeakObserver(view: view))
    }
}

/// The workspace's toolbar items, each with the column it belongs to: the
/// conversation's title and actions at the conversation's edges, and each
/// side chat's title and actions on the side chat. They move with their
/// column on every frame of a motion rather than being replaced, as one
/// window toolbar would replace them.
///
/// It is one toolbar item spanning the detail area. Inside it each group is
/// its own SwiftUI hosting view, placed by `WorkspaceTitlebarView` from
/// `WorkspaceColumnsGeometry`, so a motion updates no view graph.
struct WorkspaceTitlebar: NSViewRepresentable {
    struct Group {
        /// `conversationID` or the column's `WorkspaceTrailingColumn` id.
        let id: String
        let title: AnyView
        let actions: AnyView
        /// The actions a side chat shows at full width; they replace
        /// `actions` as it widens.
        var fullWidthActions: AnyView?
    }

    static let conversationID = "conversation"

    let groups: [Group]
    /// Whether the window toolbar shows its search field. The field keeps
    /// its place at the trailing edge; it fades out over a thread pane as it
    /// opens, and back, on the columns' frames.
    let showsSearch: Bool

    func makeNSView(context _: Context) -> Anchor {
        Anchor()
    }

    func updateNSView(_ anchor: Anchor, context: Context) {
        anchor.overlay.apply(groups, showsSearch: showsSearch, environment: context.environment)
    }

    static func dismantleNSView(_ anchor: Anchor, coordinator _: ()) {
        anchor.overlay.removeFromSuperview()
    }

    /// Installs the items over the window's titlebar. The toolbar would lay
    /// out an item of its own, and fit it among its other items, on every
    /// change; over it, the items are placed only by their columns.
    final class Anchor: NSView {
        let overlay = WorkspaceTitlebarView()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let titlebar = window?.standardWindowButton(.closeButton)?.superview else {
                overlay.removeFromSuperview()
                return
            }
            guard overlay.superview !== titlebar else { return }
            overlay.frame = titlebar.bounds
            overlay.autoresizingMask = [.width, .height]
            titlebar.addSubview(overlay)
        }
    }
}

final class WorkspaceTitlebarView: NSView {
    private final class Island {
        let host: NSHostingController<AnyView>
        /// What moves with the column; the hosting view sits still in it.
        let container = MovingHostContainerView()
        /// The content's ideal size, which its layout reports.
        let measurement = IslandMeasurement()
        var size: CGSize { measurement.size }
        /// Actions end at the island's trailing edge: given less than their
        /// ideal width, they take a narrower variant there.
        let isTrailing: Bool

        init(_ content: AnyView, isTrailing: Bool = false) {
            host = NSHostingController(rootView: AnyView(EmptyView()))
            host.sizingOptions = []
            // Placed by frame, without autoresizing constraints: every change
            // to those reached the window's SwiftUI layouts as the columns
            // moved.
            host.view.translatesAutoresizingMaskIntoConstraints = false
            container.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(host.view)
            self.isTrailing = isTrailing
            setContent(content)
        }

        func setContent(_ content: AnyView) {
            host.rootView = AnyView(IdealSizeLayout(measurement: measurement, isTrailing: isTrailing) { content })
        }
    }

    private final class GroupViews {
        /// Clips the group to the part of its column not covered by another.
        let clip = TitlebarClipView()
        let title: Island
        let actions: Island
        var fullWidthActions: Island?
        /// The title's width when its side chat was last in the pane.
        var paneTitleWidth: CGFloat?

        init(_ group: WorkspaceTitlebar.Group) {
            title = Island(group.title)
            actions = Island(group.actions, isTrailing: true)
            clip.translatesAutoresizingMaskIntoConstraints = false
            clip.addSubview(title.container)
            clip.addSubview(actions.container)
        }
    }

    private var groups: [String: GroupViews] = [:]
    /// Groups whose column the workspace has placed.
    private var placedColumnIDs: Set<String> = []
    private var order: [String] = []

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        WorkspaceColumnsGeometry.shared.observe(self)
        // The toolbar re-hosts its search field, in fresh glass, whenever
        // its items change, as they do when a side chat shows or hides the
        // field: fade the new glass before it draws.
        for name in [NSToolbar.willAddItemNotification, NSToolbar.didRemoveItemNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(toolbarItemsDidChange(_:)), name: name, object: nil
            )
        }
        // Assistive apps find the items where the toolbar's were.
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(
        _ groups: [WorkspaceTitlebar.Group],
        showsSearch: Bool,
        environment: EnvironmentValues
    ) {
        self.showsSearch = showsSearch
        // A side chat's items stay while its column is still sliding away,
        // as they were: updates within the change that closes it can come
        // before the column is listed as leaving.
        let ids = Set(groups.map(\.id))
        presentedGroupIDs = ids
        let gone = self.order.filter { !ids.contains($0) && $0 != WorkspaceTitlebar.conversationID }
        // Without a motion, one side chat replaced another in the same pane:
        // its items take over the old ones in place.
        var replaced = WorkspaceLayoutMotion.isMoving ? [] : gone
        let leaving = replaced.isEmpty
            ? gone.filter { id in WorkspaceColumnsGeometry.shared.columns.contains { $0.id == id } }
            : []
        removeGroups { !ids.contains($0) && !leaving.contains($0) && !replaced.contains($0) }
        for group in groups {
            if self.groups[group.id] == nil, group.id != WorkspaceTitlebar.conversationID,
               let old = replaced.popLast(), let views = self.groups.removeValue(forKey: old)
            {
                self.groups[group.id] = views
            }
            let views = self.groups[group.id] ?? {
                let views = GroupViews(group)
                for island in [views.title, views.actions] { observe(island) }
                addSubview(views.clip)
                self.groups[group.id] = views
                return views
            }()
            views.title.setContent(
                AnyView(
                    group.title
                        .workspaceMotionProbe(
                            (group.id == WorkspaceTitlebar.conversationID ? "tb.conversation" : "tb.side") + ".title"
                        )
                        .environment(\.self, environment)
                )
            )
            views.actions.setContent(
                AnyView(
                    group.actions
                        .workspaceMotionProbe(
                            (group.id == WorkspaceTitlebar.conversationID ? "tb.conversation" : "tb.side") + ".actions"
                        )
                        .environment(\.self, environment)
                )
            )
            if let fullWidthActions = group.fullWidthActions {
                let island = views.fullWidthActions ?? {
                    let island = Island(fullWidthActions, isTrailing: true)
                    observe(island)
                    views.clip.addSubview(island.container)
                    views.fullWidthActions = island
                    return island
                }()
                island.setContent(
                    AnyView(
                        fullWidthActions
                            .workspaceMotionProbe("tb.side.fullActions")
                            .environment(\.self, environment)
                    )
                )
            } else if let island = views.fullWidthActions {
                island.container.removeFromSuperview()
                views.fullWidthActions = nil
            }
        }
        removeGroups { replaced.contains($0) }
        // Later groups are in front: a side chat covers the conversation and
        // one arriving covers one leaving.
        order = leaving + groups.map(\.id)
        for id in order {
            if let clip = self.groups[id]?.clip { addSubview(clip) }
        }
        placeGroups()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // The toolbar's search field outlives the workspace: it shows again
        // wherever the window goes next.
        if newWindow !== window { fadeSearch(1) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func layout() {
        super.layout()
        placeGroups()
    }

    /// Places the groups again once an island has measured its content.
    private func observe(_ island: Island) {
        island.measurement.changed = { [weak self] in self?.placeGroups() }
    }

    private func removeGroups(where shouldRemove: (String) -> Bool) {
        for (id, views) in groups where shouldRemove(id) {
            views.clip.removeFromSuperview()
            groups[id] = nil
        }
        order.removeAll { groups[$0] == nil }
    }

    /// Places each group on its column, as the column is now.
    func placeGroups() {
        guard window != nil else { return }
        // In the frame that moves the groups, as the columns do. Moving an
        // item lays nothing out; only those resized have layouts to update.
        defer {
            for view in resizedItems { view.layoutSubtreeIfNeeded() }
            resizedItems.removeAll()
        }
        let geometry = WorkspaceColumnsGeometry.shared
        // A side chat's items leave with its column, once it has had one.
        let columnIDs = Set(geometry.columns.map(\.id))
        removeGroups { id in
            id != WorkspaceTitlebar.conversationID && placedColumnIDs.contains(id) && !columnIDs.contains(id)
        }
        placedColumnIDs.formUnion(columnIDs.intersection(groups.keys))
        placedColumnIDs.formIntersection(groups.keys)
        // A full-width side chat covers the conversation from its leading
        // edge as it widens.
        let leadingLimit = leadingControlsMaxX
        let fullWidth = geometry.columns.last(where: \.isFullWidth)
        let inset = ChatChromeMetrics.toolbarItemEdgeInset
        // Search sits at the window's trailing edge, as the toolbar's own
        // field does, beneath a thread pane, which covers it as it moves; a
        // full-width side chat leaves room for it, so it fades back as one
        // widens.
        let searchCover = searchCoverMinX(geometry)
        let searchAlpha = searchVisibility(geometry, coverMinX: searchCover)
        _ = searchItemView
        // Items stop before the field while it shows, or will once a pane
        // leaves; they never pass it to come back.
        let searchMinX = showsSearch || searchAlpha > 0 ? searchFieldMinX : nil
        let searchLimit = (searchMinX ?? bounds.maxX + inset) - inset
        let hasSideConversation = geometry.columns.contains { $0.id.hasPrefix("side-") }
        let windowMaxX = convert(CGPoint(x: bounds.maxX, y: 0), to: nil).x
        for id in order {
            guard let views = groups[id] else { continue }
            // In window coordinates.
            let span: ClosedRange<CGFloat>
            var visibleMaxX: CGFloat
            var widening: CGFloat = 0
            var isFullWidth = false
            var endsAtSearch = true
            if id == WorkspaceTitlebar.conversationID {
                guard var conversation = geometry.conversation else { continue }
                // Beside the member list or search results, which the field
                // sits over, the conversation's items end at the field, as
                // the window toolbar's do: the list starts a point before it,
                // and items that followed its edge moved as it opened.
                if searchMinX != nil, searchAlpha >= 1, !hasSideConversation {
                    conversation = conversation.lowerBound ... max(conversation.upperBound, windowMaxX)
                }
                span = conversation
                visibleMaxX = min(span.upperBound, fullWidth?.minX ?? .infinity)
            } else {
                guard let column = geometry.columns.first(where: { $0.id == id }) else { continue }
                span = column.minX ... column.maxX
                visibleMaxX = span.upperBound
                if column.isFullWidth { widening = column.widening }
                isFullWidth = column.isFullWidth
                endsAtSearch = column.isFullWidth
            }
            // Clear of the window's controls and the sidebar button, which
            // the column reaches when the sidebar is hidden.
            let minX = max(convert(CGPoint(x: span.lowerBound, y: 0), from: nil).x, leadingLimit)
            // A pane beyond the window's edge keeps its items with it.
            var maxX = convert(CGPoint(x: span.upperBound, y: 0), from: nil).x
            if !endsAtSearch { visibleMaxX = maxX } else { maxX = min(maxX, bounds.maxX) }
            visibleMaxX = convert(CGPoint(x: visibleMaxX, y: 0), from: nil).x
            // The conversation's items, and a full-width side chat's, end
            // before the search field; a pane's own actions stay at its edge.
            let searchInset = endsAtSearch ? max(0, maxX - searchLimit) : 0
            if id == WorkspaceTitlebar.conversationID { maxX -= searchInset }
            let clipX = minX.rounded(.down)
            views.clip.frame = CGRect(x: clipX, y: 0, width: max(0, visibleMaxX - clipX), height: bounds.height)
            place(
                views,
                width: maxX - clipX,
                widening: widening,
                fullWidthInset: id == WorkspaceTitlebar.conversationID ? 0 : searchInset,
                fills: id != WorkspaceTitlebar.conversationID,
                isFullWidth: isFullWidth
            )
        }
        fadeSearch(searchAlpha)
        coverSearch(at: searchCover)
    }

    /// Where a thread pane in front of the search field begins, in window
    /// coordinates, less an item inset: the pane's items are translucent,
    /// and their glass refracts what lies just beside it.
    private func searchCoverMinX(_ geometry: WorkspaceColumnsGeometry) -> CGFloat? {
        guard AppMotionPolicy.animates(.overlays) else { return nil }
        let paneMinX = geometry.columns.lazy
            .filter { $0.id.hasPrefix("side-thread") && !$0.isFullWidth }.map(\.minX).min()
        return paneMinX.map { $0 - ChatChromeMetrics.toolbarItemEdgeInset }
    }

    /// Whether a thread pane covers the whole search field.
    private func coversSearch(at coverMinX: CGFloat?) -> Bool {
        guard let coverMinX, let fieldMinX = searchFieldMinX else { return false }
        return coverMinX <= convert(CGPoint(x: fieldMinX, y: 0), to: nil).x
    }

    private func coverSearch(at coverMinX: CGFloat?) {
        guard let glass = searchItemView else { return }
        let visibleWidth = coverMinX.map { glass.convert(CGPoint(x: $0, y: 0), from: nil).x - glass.bounds.minX }
        // Glass with a mask of its own hides as soon as the pane reaches it.
        if !glass.showLeading(visibleWidth), let visibleWidth, visibleWidth < glass.bounds.width {
            fadeSearch(0)
        }
    }

    /// How much of the search field shows: none once a thread pane covers
    /// it, and in between while a side chat widens, unless the reader turned
    /// off overlay motion: it then shows as the presentation leaves it,
    /// whatever the columns do.
    private func searchVisibility(_ geometry: WorkspaceColumnsGeometry, coverMinX: CGFloat?) -> CGFloat {
        guard showsSearch || WorkspaceLayoutMotion.isMoving else { return 0 }
        guard AppMotionPolicy.animates(.overlays) else {
            let hidden = geometry.columns.contains {
                $0.id.hasPrefix("side-thread") && !$0.isFullWidth && presentedGroupIDs.contains($0.id)
            }
            return hidden ? 0 : 1
        }
        if coversSearch(at: coverMinX) { return 0 }
        var covered: CGFloat = 0
        for column in geometry.columns where column.id.hasPrefix("side-thread") && column.isFullWidth {
            covered = max(covered, 1 - column.widening)
        }
        return 1 - covered
    }

    private var showsSearch = false
    /// The groups the workspace lists now, not those still sliding away.
    private var presentedGroupIDs: Set<String> = []
    private weak var searchField: NSSearchField?

    /// Where the window's own leading controls end in this view: its
    /// buttons and the toolbar's leading items, such as the sidebar button.
    /// A workspace motion moves none of them, so its frames reuse the first
    /// frame's.
    private var leadingControlsMaxX: CGFloat {
        if WorkspaceLayoutMotion.isMoving, let cachedLeadingControlsMaxX { return cachedLeadingControlsMaxX }
        let maxX = measuredLeadingControlsMaxX
        cachedLeadingControlsMaxX = maxX
        return maxX
    }

    private var cachedLeadingControlsMaxX: CGFloat?

    private var measuredLeadingControlsMaxX: CGFloat {
        guard let window else { return 0 }
        var maxX: CGFloat = 0
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let view = window.standardWindowButton(button), !view.isHiddenOrHasHiddenAncestor {
                maxX = max(maxX, convert(view.bounds, from: view).maxX)
            }
        }
        for item in window.toolbar?.items ?? [] where !(item is NSSearchToolbarItem) {
            guard let view = item.view, view.window === window, !view.isHiddenOrHasHiddenAncestor else { continue }
            let frame = convert(view.bounds, from: view)
            // Only items at the leading edge, before the workspace's.
            if frame.minX < bounds.midX / 2 { maxX = max(maxX, frame.maxX) }
        }
        return maxX > 0 ? maxX + ChatChromeMetrics.toolbarItemEdgeInset : 0
    }

    /// The toolbar's search field, with the glass the toolbar draws for it.
    private var searchItemView: NSView? {
        guard let window else { return nil }
        if searchField?.window !== window {
            searchField = ToolbarSearchFieldLocator.searchField(in: window)
        }
        guard let searchField, searchField.window === window else { return nil }
        // Found once per glass the toolbar hosts the field in.
        if let searchGlass, searchGlass.window === window, searchField.isDescendant(of: searchGlass) {
            return searchGlass
        }
        // The field's item with the glass platter the toolbar draws behind
        // it, so neither shows while the field is faded out.
        var view: NSView? = searchField
        var itemViewer: NSView?
        while let candidate = view {
            let name = String(describing: type(of: candidate))
            if name.contains("Platter") {
                searchGlass = candidate
                return candidate
            }
            if itemViewer == nil, name.contains("ItemViewer") { itemViewer = candidate }
            view = candidate.superview
        }
        searchGlass = itemViewer
        return itemViewer ?? searchField
    }

    private weak var searchGlass: NSView?

    /// Where the toolbar's search field starts in this view, if the toolbar
    /// has it, shown or faded out.
    private var searchFieldMinX: CGFloat? {
        guard let searchField, searchField.window === window else { return nil }
        return convert(searchField.bounds, from: searchField).minX
    }

    private func fadeSearch(_ alpha: CGFloat) {
        // The field fades too: it keeps its alpha when the toolbar moves it
        // into new glass.
        // Hidden is reconciled on its own: the toolbar can show the view again
        // without touching its alpha, and a matching alpha must not skip that.
        let hidden = alpha < 0.01
        for view in [searchItemView, searchField].compactMap(\.self) {
            if view.alphaValue != alpha { view.alphaValue = alpha }
            if view.isHidden != hidden { view.isHidden = hidden }
        }
    }

    @objc private func toolbarItemsDidChange(_ notification: Notification) {
        guard let toolbar = notification.object as? NSToolbar, toolbar === window?.toolbar else { return }
        // The re-hosted field draws in its new glass before it can be placed
        // below: keep it out of sight until then if a pane covers it.
        // The field being replaced may already be gone, leaving its place
        // unknown.
        let coverMinX = searchCoverMinX(WorkspaceColumnsGeometry.shared)
        if let item = notification.userInfo?["item"] as? NSSearchToolbarItem,
           coverMinX != nil, searchFieldMinX == nil || coversSearch(at: coverMinX) {
            item.searchField.alphaValue = 0
        }
        placeGroups()
        // The added item's view arrives after this notification.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.placeGroups() }
        }
    }

    /// Places a group's title at its column's leading edge and its actions
    /// at the trailing edge, within its clip view.
    /// - Parameter fullWidthInset: How far before the trailing edge a
    ///   full-width side chat's actions end, at the search field.
    private func place(
        _ views: GroupViews, width: CGFloat, widening: CGFloat, fullWidthInset: CGFloat, fills: Bool, isFullWidth: Bool
    ) {
        let inset = ChatChromeMetrics.toolbarItemEdgeInset
        let height = bounds.height
        // A narrow column keeps room for its title; its actions gather into
        // their overflow menu instead (`conversationTitlebarActions`).
        let actionsLimit = max(0, width - inset * 3 - InterfaceScale.metric(96))
        let actionsWidth = min(views.actions.size.width, actionsLimit) * (1 - widening)
            + (min(views.fullWidthActions?.size.width ?? 0, actionsLimit) + fullWidthInset) * widening
        let unmeasured = CGSize(width: 1, height: height)
        for (island, alpha, trailing) in [
            (views.actions, 1 - widening, 0),
            (views.fullWidthActions, widening, fullWidthInset),
        ] {
            guard let island else { continue }
            // Whole points wide, so its edges rest on whole points too.
            let size = island.size == .zero
                ? unmeasured
                : CGSize(width: min(island.size.width.rounded(.up), actionsLimit.rounded()), height: island.size.height)
            setFrame(of: island.container, CGRect(
                x: width - trailing - inset - size.width,
                y: ((height - size.height) / 2).rounded(),
                width: size.width,
                height: size.height
            ))
            island.container.alphaValue = alpha
            island.container.isHidden = alpha < 0.01
        }
        // A side chat's title fills the pane up to its actions; at full width
        // it takes only the width it needs, like the conversation's.
        let available = max(0, width - actionsWidth - inset * 3)
        let titleSize = views.title.size == .zero ? unmeasured : views.title.size
        let natural = min(titleSize.width, available)
        // As the side chat widens, the title goes from the pane's width to
        // its own; it never first grows with the column.
        if !isFullWidth { views.paneTitleWidth = available }
        let filled = isFullWidth ? min(available, views.paneTitleWidth ?? available) : available
        let titleWidth = fills ? filled * (1 - widening) + natural * widening : natural
        setFrame(of: views.title.container, CGRect(
            x: inset,
            y: ((height - titleSize.height) / 2).rounded(),
            width: titleWidth,
            height: titleSize.height
        ))
    }

    /// On whole points, so items rest on the same pixels whatever their
    /// column's edge, and never land between pixels as they move.
    private func setFrame(of view: NSView, _ frame: CGRect) {
        var frame = frame
        frame.origin.x = frame.origin.x.rounded()
        guard view.frame != frame else { return }
        if view.frame.size != frame.size { resizedItems.append(view) }
        view.frame = frame
    }

    /// Items `placeGroups` resized, which it lays out before it returns.
    private var resizedItems: [NSView] = []

    /// Empty space between the items moves the window, as the toolbar's own
    /// does.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        // Items in front first; a group's empty clip view takes nothing.
        for view in subviews.reversed() where !view.isHidden {
            if let hit = view.hitTest(local), !(hit is TitlebarClipView) { return hit }
        }
        return nil
    }
}

private final class TitlebarClipView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
}

/// An island's ideal size, which its layout reports as it lays out, so it is
/// never laid out at a measuring size in view.
nonisolated private final class IslandMeasurement: @unchecked Sendable {
    var size = CGSize.zero
    /// Called on the main thread after the size changes.
    var changed: (@MainActor () -> Void)?
}

/// Lays its content out in whatever frame it is given and reports the
/// content's ideal size, so a title that fills its frame still measures
/// only as wide as its text.
nonisolated private struct IdealSizeLayout: Layout {
    let measurement: IslandMeasurement
    let isTrailing: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: subviews.first?.sizeThatFits(.unspecified) ?? .zero)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard let content = subviews.first else { return }
        let proposal = ProposedViewSize(bounds.size)
        let minX = isTrailing ? bounds.maxX - content.sizeThatFits(proposal).width : bounds.minX
        content.place(at: CGPoint(x: minX, y: bounds.minY), proposal: proposal)
        let ideal = content.sizeThatFits(.unspecified)
        guard ideal != measurement.size else { return }
        measurement.size = ideal
        let measurement = measurement
        DispatchQueue.main.async { MainActor.assumeIsolated { measurement.changed?() } }
    }
}
