import AppKit
import SwiftUI

/// The workspace's conversation, side chat and inspector, each in its own
/// SwiftUI hosting view inside one AppKit container that moves them.
///
/// Why this layer exists: a side chat or the member list slides in while the
/// conversation beside it resizes live. Driven by SwiftUI, every frame of
/// that motion re-ran the window's view graph, moved hundreds of layers and
/// relaid out the workspace: about 30 ms of main-thread work per frame on an
/// 8 GB Mac in Release, so fewer than a third of the motion's frames reached
/// the screen. Here a display link sets the islands' frames directly. The
/// window's SwiftUI graph does nothing per frame; only the conversation's
/// island lays out at its new width, and a sliding column moves as one view.
///
/// The columns follow `WorkspaceMotionPhase`: each column's reveal and the
/// widening are targets this view springs toward with the workspace spring,
/// or jumps to when the update that sets them is not animated.
///
/// Setting `SakuraCordSwiftUIWorkspaceColumns` switches back to the SwiftUI
/// layout (`WorkspaceColumnsLayout`) for comparison.
struct WorkspaceColumnsHost: NSViewRepresentable {
    struct Column {
        let id: String
        let isSideConversation: Bool
        let isFullWidth: Bool
        /// Leaving: its width is no longer measured.
        var isDeparting: Bool
        let content: AnyView
    }

    enum Widening {
        /// A full-width side chat starts from the pane's width…
        case starting
        /// …and grows to fill the workspace.
        case arriving
    }

    static let isEnabled = !UserDefaults.standard.bool(forKey: "SakuraCordSwiftUIWorkspaceColumns")
    /// Each column's own coordinate space, which moves with its island.
    static let columnSpace = "SakuraCordWorkspaceColumn"

    let conversation: AnyView
    /// Back to front: departing columns first, so an arriving one covers them.
    let columns: [Column]
    let widening: Widening?
    /// Receives the frame the columns report with
    /// `SupplementaryPaneFramePreferenceKey`, where the column rests, in
    /// the window's SwiftUI global coordinates. Preferences do not leave a
    /// hosting view, so this carries them out.
    let supplementaryPaneFrameChanged: (CGRect) -> Void

    func makeNSView(context _: Context) -> WorkspaceColumnsView {
        WorkspaceColumnsView()
    }

    func updateNSView(_ view: WorkspaceColumnsView, context: Context) {
        let transaction = context.transaction
        view.apply(
            self,
            environment: context.environment,
            animates: transaction.animation != nil && !transaction.disablesAnimations
        )
    }

    static func dismantleNSView(_ view: WorkspaceColumnsView, coordinator _: ()) {
        view.stopMotion()
    }
}

/// A value that follows the workspace spring toward a target and can be
/// retargeted mid-flight, keeping its velocity.
private struct SpringTrack {
    private(set) var target: CGFloat
    private var origin: CGFloat
    /// When the motion started, or nil until its first frame. A column's
    /// first frame can take a while to lay out; the motion starts after it
    /// rather than jumping ahead by however long it took.
    private var start: CFTimeInterval?
    private var initialVelocity: CGFloat = 0

    init(at value: CGFloat) {
        target = value
        origin = value
    }

    private static var spring: Spring { ChatChromeMetrics.sidebarSpring }

    func value(at time: CFTimeInterval) -> CGFloat {
        value(at: time, provisionalStart: nil)
    }

    /// Where the motion has the value at `time`, taking a motion still
    /// waiting for its first frame to start at `provisionalStart`.
    func value(at time: CFTimeInterval, provisionalStart: CFTimeInterval?) -> CGFloat {
        guard origin != target else { return target }
        guard let start = start ?? provisionalStart else { return origin }
        let progress = Self.spring.value(
            target: 1.0,
            initialVelocity: Double(initialVelocity / (target - origin)),
            time: max(0, time - start)
        )
        return origin + (target - origin) * CGFloat(progress)
    }

    private func velocity(at time: CFTimeInterval) -> CGFloat {
        guard origin != target else { return 0 }
        guard let start else { return initialVelocity }
        let velocity = Self.spring.velocity(
            target: 1.0,
            initialVelocity: Double(initialVelocity / (target - origin)),
            time: max(0, time - start)
        )
        return (target - origin) * CGFloat(velocity)
    }

    func isSettled(at time: CFTimeInterval) -> Bool {
        origin == target || start != nil && abs(value(at: time) - target) < 0.0005 && abs(velocity(at: time)) < 0.005
    }

    /// Starts a motion that is waiting for its first frame.
    /// - Returns: Whether it started.
    mutating func startIfNeeded(at time: CFTimeInterval) -> Bool {
        guard start == nil, origin != target else { return false }
        start = time
        return true
    }

    mutating func move(to newTarget: CGFloat, at time: CFTimeInterval, animated: Bool) {
        // Later updates that keep the target leave a running motion alone.
        guard newTarget != target else { return }
        guard animated else {
            self = SpringTrack(at: newTarget)
            return
        }
        let current = value(at: time)
        initialVelocity = velocity(at: time)
        origin = current
        target = newTarget
        start = nil
    }
}

final class WorkspaceColumnsView: NSView {
    private struct Island {
        let host: ColumnHostingView
        /// What moves: the hosting view sits still inside it.
        var view: NSView { host.container }
        var column: WorkspaceColumnsHost.Column
        var reveal: SpringTrack
    }

    private var conversation: NSHostingController<AnyView>?
    /// Shows the conversation as far as the columns leave it. While a column
    /// slides over the wider conversation, nothing of the conversation shows
    /// beneath the translucent column, as beside it at rest.
    private let conversationClip = ConversationClipView()
    /// A side chat pane kept for the next one to open (`apply`).
    private var pooledPane: ColumnHostingView?
    /// The member list and search results, kept hidden after they leave
    /// for the next time they open: built from nothing, their first frames
    /// held up the motion while the render server drew every row anew.
    private var pooledInspectors: [String: ColumnHostingView] = [:]
    /// Back to front.
    private var islands: [Island] = []
    private var widening: SpringTrack?
    /// Between `WorkspaceLayoutMotion.willChangeColumns` and the end of
    /// the change's turn of the run loop.
    private var columnsAreChanging = false
    /// The conversation's frame beside the columns, before it recedes.
    private var conversationFrame = CGRect.zero
    /// How far, as a share of its width, the conversation drifts as a
    /// widening side chat covers it.
    private static let recedeDistance: CGFloat = 0.25
    /// The columns the workspace last listed; others are leaving.
    private var listedColumnIDs: Set<String> = []
    private var supplementaryPaneFrameChanged: (CGRect) -> Void = { _ in }
    private var reportedPaneFrame = CGRect.zero
    private var displayLink: CADisplayLink?

    /// Column widths, measured when the columns change rather than on every
    /// frame of a motion.
    private var paneWidth: CGFloat = 0
    private var inspectorWidth: CGFloat = 0
    private var conversationMinimum: CGFloat = 0
    /// Whether the conversation's minimum width needs measuring again.
    private var needsMeasurement = true
    /// The Interface Size the conversation's minimum width was measured at.
    private var measuredScale = InterfaceScale.factor

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(revealDidChange(_:)),
            name: WorkspaceLayoutMotion.revealDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(columnsWillChange),
            name: WorkspaceLayoutMotion.willChangeColumns,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(motionDidBegin), name: WorkspaceLayoutMotion.didBegin, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(motionDidSettle), name: WorkspaceLayoutMotion.didSettle, object: nil
        )
    }

    /// Marks the trailing column leaving before a change that may close it,
    /// so it keeps what it shows: a closed column's content is gone by the
    /// time it starts to leave.
    @objc private func columnsWillChange() {
        for island in islands where !island.column.isFullWidth {
            island.host.setContent(island.host.content, isLeaving: true)
        }
        // Updates within the change can add the arriving column before its
        // reveal is set; it starts out of view, not in place.
        columnsAreChanging = true
        DispatchQueue.main.async { [weak self] in self?.columnsAreChanging = false }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        for island in islands { island.host.discard() }
        pooledPane?.discard()
        for host in pooledInspectors.values { host.discard() }
    }

    @objc private func motionDidBegin() {
        needsMeasurement = true
    }

    /// Lets go of the columns that left, and lets the ones that stayed
    /// update again. The workspace lists only the columns that remain, and
    /// does not update when a motion settles.
    @objc private func motionDidSettle() {
        needsMeasurement = true
        for island in islands where !listedColumnIDs.contains(island.column.id) {
            remove(island)
        }
        islands.removeAll { !listedColumnIDs.contains($0.column.id) }
        for island in islands where island.host.isLeaving {
            island.host.setContent(island.host.content, isLeaving: false)
        }
        layoutColumns(at: CACurrentMediaTime())
    }

    /// Takes a column out. The last side chat pane stays, out of the window,
    /// for the next one: a pane built from nothing costs most of a motion's
    /// first frame. Out of the window, as a closed pane was before pooling,
    /// it takes no events and plays no media; `apply` puts it back.
    private func remove(_ island: Island) {
        if island.column.isSideConversation, !island.column.isFullWidth, pooledPane == nil {
            island.view.removeFromSuperview()
            pooledPane = island.host
        } else if !island.column.isSideConversation {
            island.view.removeFromSuperview()
            pooledInspectors[island.column.id]?.discard()
            pooledInspectors[island.column.id] = island.host
        } else {
            island.host.discard()
        }
    }

    /// Moves the columns toward their reveals. This bypasses the view graph:
    /// updating it to start a motion cost several frames.
    @objc private func revealDidChange(_ notification: Notification) {
        let animates = notification.userInfo?[WorkspaceLayoutMotion.animatesKey] as? Bool ?? false
        let reveal = WorkspaceMotionPhase.shared.unobservedReveal
        let now = CACurrentMediaTime()
        for index in islands.indices {
            let target = reveal[islands[index].column.id] ?? 1
            islands[index].reveal.move(to: target, at: now, animated: animates)
            let host = islands[index].host
            if animates, target == 1, host.isLeaving { host.setContent(host.content, isLeaving: false) }
        }
        // A widening side chat starts to grow once its first layout is in.
        if var track = widening, WorkspaceMotionPhase.shared.unobservedWideningHasArrived {
            track.move(to: 1, at: now, animated: animates)
            widening = track
        }
        // Posted inside the motion's `withAnimation`, which this view's own
        // spring replaces: a column resized in it, such as the conversation
        // the member list uncovers, had SwiftUI animate its content to the
        // new size and lay it out again on every frame.
        withTransaction(Transaction(animation: nil)) { layoutColumns(at: now) }
        if isAnimating(at: now) { startMotion() }
    }

    func apply(_ spec: WorkspaceColumnsHost, environment: EnvironmentValues, animates: Bool) {
        let now = CACurrentMediaTime()
        supplementaryPaneFrameChanged = spec.supplementaryPaneFrameChanged

        if measuredScale != InterfaceScale.factor {
            measuredScale = InterfaceScale.factor
            needsMeasurement = true
        }
        let conversationRoot = AnyView(spec.conversation.environment(\.self, environment))
        if let conversation {
            conversation.rootView = conversationRoot
        } else {
            let host = Self.makeHost(conversationRoot)
            conversationClip.addSubview(host.view)
            addSubview(conversationClip, positioned: .below, relativeTo: nil)
            conversation = host
        }

        let ids = Set(spec.columns.map(\.id))
        // A column marked leaving before the change stays, behind the rest:
        // updates within the change can run before it is listed as
        // departing, and removing it then rebuilt its content from nothing.
        var updated = islands.filter { island in
            !ids.contains(island.column.id) && !island.column.isFullWidth && island.host.isLeaving
                && WorkspaceLayoutMotion.isMoving
        }.map { island in
            var island = island
            island.column.isDeparting = true
            return island
        }
        let heldIDs = Set(updated.map(\.column.id))
        // Columns that have gone first, so a side chat that replaces another
        // in place takes over its pane.
        for island in islands where !ids.contains(island.column.id) && !heldIDs.contains(island.column.id) {
            remove(island)
        }
        islands.removeAll { !ids.contains($0.column.id) && !heldIDs.contains($0.column.id) }
        listedColumnIDs = ids
        for column in spec.columns {
            let root = AnyView(
                column.content
                    .environment(\.paneFrameIsColumnLocal, true)
                    .environment(\.self, environment)
                    .coordinateSpace(.named(WorkspaceColumnsHost.columnSpace))
            )
            if var island = islands.first(where: { $0.column.id == column.id }) {
                // A column marked leaving before the change stays so until
                // it comes back in or the motion settles: updates within the
                // change can run before the column is listed as departing.
                let isLeaving = column.isDeparting || island.host.isLeaving && WorkspaceLayoutMotion.isMoving
                island.host.setContent(root, isLeaving: isLeaving)
                if island.column.isDeparting != column.isDeparting
                    || island.column.isFullWidth != column.isFullWidth
                {
                    needsMeasurement = true
                }
                island.host.showsFullWidth(column.isSideConversation && column.isFullWidth)
                island.column = column
                updated.append(island)
            } else {
                let reveal = WorkspaceMotionPhase.shared.unobservedReveal[column.id] ?? (columnsAreChanging ? 0 : 1)
                updated.append(Island(host: makeHost(for: column, root), column: column, reveal: SpringTrack(at: reveal)))
                needsMeasurement = true
            }
        }
        islands = updated
        for island in islands {
            island.host.paneFrameChanged = { [weak self] host in self?.columnReported(by: host) }
        }
        var below: NSView? = conversation.map { _ in conversationClip }
        for island in islands {
            let view = island.view
            if view.superview !== self
                || subviews.firstIndex(of: view)! < below.flatMap { subviews.firstIndex(of: $0) } ?? 0
            {
                addSubview(view, positioned: .above, relativeTo: below)
            }
            below = view
        }

        switch spec.widening {
        case nil: widening = nil
        case .starting: widening = SpringTrack(at: 0)
        case .arriving:
            var track = widening ?? SpringTrack(at: 0)
            track.move(to: 1, at: now, animated: animates)
            widening = track
        }

        layoutColumns(at: now)
        // A column that arrives builds and measures its content now, out of
        // view, rather than on the motion's first frame.
        let arriving = islands.filter { !$0.host.extent.isMeasured }
        if !arriving.isEmpty {
            for island in arriving { island.host.layoutSubtreeIfNeeded() }
            needsMeasurement = true
            layoutColumns(at: now)
        }
        if isAnimating(at: now) { startMotion() }
    }

    /// A hosting view for a column that arrives: the pooled pane, for a
    /// side chat pane, or a new one.
    private func makeHost(for column: WorkspaceColumnsHost.Column, _ root: AnyView) -> ColumnHostingView {
        if !column.isSideConversation, let pooled = pooledInspectors.removeValue(forKey: column.id) {
            pooled.presentation += 1
            pooled.setContent(root, isLeaving: false)
            return pooled
        }
        guard column.isSideConversation, !column.isFullWidth, let pooled = pooledPane else {
            let host = ColumnHostingView(content: root, sharesExtent: column.isSideConversation)
            host.showsFullWidth(column.isSideConversation && column.isFullWidth)
            return host
        }
        pooledPane = nil
        pooled.presentation += 1
        pooled.setContent(root, isLeaving: false)
        return pooled
    }

    func stopMotion() {
        displayLink?.invalidate()
        displayLink = nil
    }

    override func layout() {
        super.layout()
        // While the display link places the columns, a layout pass between
        // its frames has nothing to move, and placed them for now rather
        // than for the frame's display time: a step back.
        if displayLink != nil, placedBounds == bounds { return }
        layoutColumns(at: CACurrentMediaTime())
    }

    /// The bounds the columns were last placed in.
    private var placedBounds: CGRect?

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { needsMeasurement = true }
        super.setFrameSize(newSize)
    }

    private static func makeHost(_ root: AnyView) -> NSHostingController<AnyView> {
        let host = NSHostingController(rootView: root)
        // This view sets every frame; the hosting view never asks for one.
        host.sizingOptions = []
        host.view.translatesAutoresizingMaskIntoConstraints = false
        return host
    }

    private func startMotion() {
        guard displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
        // Every frame the screen can show, up to 120 Hz on ProMotion, and
        // never fewer than 60 (or 80 on ProMotion): a lower minimum lets the
        // system halve the rate under load. The motion is evaluated by time,
        // so any rate places it correctly.
        let rate = Float(window?.screen?.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(rate, 80), maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func displayLinkDidFire(_ link: CADisplayLink) {
        var started = widening?.startIfNeeded(at: link.timestamp) ?? false
        for index in islands.indices where islands[index].reveal.startIfNeeded(at: link.timestamp) {
            started = true
        }
        // Columns leave once the motion settles, which must not come before
        // they are out of view.
        if started { WorkspaceLayoutMotion.extendSettling() }
        // Placed for the moment the frame reaches the screen.
        let time = link.targetTimestamp
        layoutColumns(at: time)
        if !isAnimating(at: time) { stopMotion() }
    }

    private func isAnimating(at time: CFTimeInterval) -> Bool {
        islands.contains { !$0.reveal.isSettled(at: time) } || widening.map { !$0.isSettled(at: time) } ?? false
    }

    /// Reads the columns' widths from their last layout.
    private func measureColumns() {
        let height = bounds.height
        let inspector = islands.last { !$0.column.isSideConversation && !$0.column.isDeparting }?.host.extent
        if let inspector, inspector.isMeasured {
            inspectorWidth = inspector.ideal
        }
        guard let pane = islands.last(where: {
            $0.column.isSideConversation && !$0.column.isFullWidth && !$0.column.isDeparting
        })?.host.extent, pane.isMeasured, bounds.width > 0 else { return }
        if needsMeasurement {
            needsMeasurement = false
            conversationMinimum = conversation?.sizeThatFits(in: CGSize(width: 0, height: height)).width ?? 0
        }
        // As an HStack does, give the pane its widest size the
        // conversation's minimum width leaves room for.
        let available = max(0, bounds.width - (inspector == nil ? 0 : inspectorWidth) - conversationMinimum)
        paneWidth = min(max(available, pane.minimum), pane.maximum)
    }

    private func width(of column: WorkspaceColumnsHost.Column) -> CGFloat {
        column.isSideConversation
            ? max(paneWidth, ChatChromeMetrics.sideConversationMinimumWidth)
            : max(inspectorWidth, ChatChromeMetrics.memberListWidth)
    }

    /// The width at `time` of the column that holds `view`, on the pixel
    /// grid, as `layoutColumns` will place it; nil for a column whose width
    /// the motion does not change.
    private func columnWidth(of view: NSView, at time: CFTimeInterval) -> CGFloat? {
        if let conversation = conversation?.view, view.isDescendant(of: conversation) {
            return conversationWidth(at: time, provisionalStart: time)
        }
        guard let fullWidth = islands.last(where: \.column.isFullWidth), view.isDescendant(of: fullWidth.view)
        else { return nil }
        let paneWidth = max(paneWidth, ChatChromeMetrics.sideConversationMinimumWidth)
        var inspectorCovered: CGFloat = 0
        for island in islands where !island.column.isFullWidth && !island.column.isSideConversation {
            let shown = width(of: island.column) * island.reveal.value(at: time, provisionalStart: time)
            inspectorCovered = max(inspectorCovered, shown)
        }
        let trailingEdge = bounds.maxX - inspectorCovered
        let recede = widening?.value(at: time, provisionalStart: time) ?? 1
        let width = paneWidth + (trailingEdge - paneWidth) * recede
        return backingAlignedRect(
            CGRect(x: trailingEdge - width, y: 0, width: width, height: bounds.height), options: .alignAllEdgesNearest
        ).width
    }

    /// The conversation's width at `time`, on the pixel grid, as
    /// `layoutColumns` will place it.
    private func conversationWidth(at time: CFTimeInterval, provisionalStart: CFTimeInterval) -> CGFloat {
        var covered: CGFloat = 0
        if islands.contains(where: \.column.isFullWidth) {
            covered = max(paneWidth, ChatChromeMetrics.sideConversationMinimumWidth)
        } else {
            for island in islands {
                let shown = width(of: island.column) * island.reveal.value(at: time, provisionalStart: provisionalStart)
                covered = max(covered, shown)
            }
        }
        let frame = CGRect(x: 0, y: 0, width: max(0, bounds.width - covered), height: bounds.height)
        return backingAlignedRect(frame, options: .alignAllEdgesNearest).width
    }

    /// Lets a timeline that a column slides over follow the column.
    private func publishWidthPath(at time: CFTimeInterval) {
        WorkspaceConversationWidthPath.shared.update(isMoving: isAnimating(at: time)) { [weak self] view in
            self?.columnWidth(of: view, at: time)
        }
    }

    /// Places every island where the motion has it at `time`.
    private func layoutColumns(at time: CFTimeInterval) {
        placedBounds = bounds
        publishWidthPath(at: time)
        measureColumns()
        let bounds = bounds
        // How much of the trailing edge the columns cover, which the
        // conversation gives up, and how much of it inspectors cover, which
        // a full-width side chat gives up.
        var covered: CGFloat = 0
        var inspectorCovered: CGFloat = 0
        for island in islands where !island.column.isFullWidth {
            let width = width(of: island.column)
            let shown = width * island.reveal.value(at: time)
            covered = max(covered, shown)
            if !island.column.isSideConversation { inspectorCovered = max(inspectorCovered, shown) }
            setFrame(of: island.view, CGRect(x: bounds.maxX - shown, y: 0, width: width, height: bounds.height))
        }
        // Columns are translucent, so a column that leaves beneath one that
        // arrives fades as the arriving one comes in, rather than showing
        // through it.
        var arriving: CGFloat = 0
        for island in islands.reversed() where !island.column.isFullWidth {
            island.view.alphaValue = island.column.isDeparting ? 1 - arriving : 1
            if !island.column.isDeparting { arriving = max(arriving, island.reveal.value(at: time)) }
        }
        // How far a widening side chat has covered the conversation.
        var recede: CGFloat = 0
        if let fullWidth = islands.last(where: \.column.isFullWidth) {
            let paneWidth = max(paneWidth, ChatChromeMetrics.sideConversationMinimumWidth)
            let trailingEdge = bounds.maxX - inspectorCovered
            recede = widening?.value(at: time) ?? 1
            let width = paneWidth + (trailingEdge - paneWidth) * recede
            setFrame(of: fullWidth.view, CGRect(x: trailingEdge - width, y: 0, width: width, height: bounds.height))
            // The conversation keeps the width it had beside the pane while
            // the side chat widens over it.
            covered = paneWidth
        }
        conversationFrame = CGRect(x: 0, y: 0, width: max(0, bounds.width - covered), height: bounds.height)
        // Beneath a widening side chat, the conversation recedes: it drifts
        // toward the leading edge and fades as it is covered, rather than
        // vanishing at once. Moving it changes no size, so it lays nothing out.
        var hostFrame = conversationFrame.offsetBy(dx: -conversationFrame.width * Self.recedeDistance * recede, dy: 0)
        // While only the member list or search results move, the
        // conversation keeps the wider of its widths and the column slides
        // over it: laying the conversation out again on every frame took
        // most of each frame. Its timeline follows the uncovered width
        // (`WorkspaceConversationWidthPath`) and re-wraps live.
        if let host = conversation?.view, movesOnlyInspectors(at: time),
           WorkspaceConversationWidthPath.shared.hasFollower(in: host)
        {
            let settled = conversationWidth(at: time + 60, provisionalStart: time)
            hostFrame.size.width = min(bounds.width, max(hostFrame.width, settled, host.frame.width))
        }
        setFrame(of: conversationClip, CGRect(
            x: hostFrame.minX, y: 0, width: min(hostFrame.width, conversationFrame.width), height: bounds.height
        ))
        setFrame(of: conversation?.view, CGRect(origin: .zero, size: hostFrame.size))
        WorkspaceConversationCover.shared.update(
            trailingInset: max(0, (conversation?.view.frame.width ?? 0) - conversationFrame.width)
        )
        conversation?.view.alphaValue = 1 - recede
        // Lay the resized columns out now, in the frame that moves them: left
        // to the window, a resized hosting view lays out in a later pass and
        // shows its new layout a frame late. A column that only moves has
        // nothing to lay out; asking laid its hosting view out on every frame.
        for view in resizedViews { view.layoutSubtreeIfNeeded() }
        resizedViews.removeAll()
        reportPaneFrame()
        publishGeometry(at: time)
    }

    /// Whether the only columns in motion are inspectors (the member list,
    /// search results), which cover the conversation without a side chat
    /// changing.
    private func movesOnlyInspectors(at time: CFTimeInterval) -> Bool {
        guard widening.map({ $0.isSettled(at: time) }) ?? true else { return false }
        var moves = false
        for island in islands where !island.reveal.isSettled(at: time) {
            guard !island.column.isSideConversation, !island.column.isFullWidth else { return false }
            moves = true
        }
        return moves
    }

    /// Tells the toolbar where the columns are, so their items move with
    /// them in the same frame.
    private func publishGeometry(at time: CFTimeInterval) {
        guard window != nil else { return }
        // Where the conversation rests: its items do not recede with it.
        let conversationFrame = conversation.map { _ in convert(conversationFrame, to: nil) }
        let widening = widening?.value(at: time) ?? 1
        WorkspaceColumnsGeometry.shared.update(
            conversation: conversationFrame.map { $0.minX ... $0.maxX },
            columns: islands.map { island in
                let frame = convert(island.view.frame, to: nil)
                return WorkspaceColumnsGeometry.Column(
                    id: island.column.id,
                    minX: frame.minX,
                    maxX: frame.maxX,
                    isFullWidth: island.column.isFullWidth,
                    widening: island.column.isFullWidth ? widening : 0
                )
            }
        )
    }

    /// On the pixel grid: a column between pixels blurs, and its scroll
    /// views align their bounds to the grid in ways they are not built for.
    private func setFrame(of view: NSView?, _ frame: CGRect) {
        guard let view else { return }
        let frame = backingAlignedRect(frame, options: .alignAllEdgesNearest)
        guard view.frame != frame else { return }
        if view.frame.size != frame.size { resizedViews.append(view) }
        view.frame = frame
    }

    /// Views `layoutColumns` resized, which it lays out before it returns.
    private var resizedViews: [NSView] = []

    /// A pooled column keeps its report for when it returns, but only a
    /// placed one reports to the toolbar.
    private func columnReported(by host: ColumnHostingView) {
        guard islands.contains(where: { $0.host === host }) else { return }
        reportPaneFrame()
    }

    /// A point in this view in the window's SwiftUI global coordinates.
    private func rootOrigin(of point: CGPoint) -> CGPoint? {
        guard let root = window?.contentView else { return nil }
        var origin = convert(point, to: root)
        if !root.isFlipped { origin.y = root.bounds.height - origin.y }
        return origin
    }

    /// Reports the frontmost column's pane frame where its column rests, as
    /// the SwiftUI layout did, so the toolbar does not follow the motion.
    private func reportPaneFrame() {
        var frame = CGRect.zero
        if let island = islands.last(where: { $0.host.paneFrame != .zero }),
           let origin = rootOrigin(of: CGPoint(
               x: island.column.isFullWidth ? 0 : bounds.maxX - width(of: island.column),
               y: 0
           ))
        {
            // On the pixel grid: the frame picks up rounding error as the
            // column moves, and the toolbar lays out again for any change.
            let scale = window?.backingScaleFactor ?? 2
            let resting = island.host.paneFrame.offsetBy(dx: origin.x, dy: origin.y)
            frame = CGRect(
                x: (resting.minX * scale).rounded() / scale,
                y: (resting.minY * scale).rounded() / scale,
                width: (resting.width * scale).rounded() / scale,
                height: (resting.height * scale).rounded() / scale
            )
        }
        guard frame != reportedPaneFrame else { return }
        reportedPaneFrame = frame
        // Reports can come in the middle of a SwiftUI update.
        DispatchQueue.main.async { [weak self] in
            guard let self, reportedPaneFrame == frame else { return }
            supplementaryPaneFrameChanged(frame)
        }
    }
}

/// Clips the conversation without resizing it (`WorkspaceColumnsView`).
private final class ConversationClipView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        autoresizesSubviews = false
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
}

/// Holds a hosting view and moves it: a hosting view that moves updates its
/// view graph, as anything in it may depend on where it is in the window,
/// on every frame of a motion. Its subviews fill it.
final class MovingHostContainerView: NSView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        for subview in subviews where subview.frame.size != newSize {
            subview.frame = CGRect(origin: .zero, size: newSize)
        }
    }
}

/// A column's hosting view.
private final class ColumnHostingView: NSHostingView<AnyView> {
    let container = MovingHostContainerView()

    /// The widths the column's content takes, measured as it lays out.
    let extent = ColumnExtent()
    /// The column's content, without how this view presents it.
    private(set) var content = AnyView(EmptyView())
    /// Whether the column is leaving: it shows what it showed when it began
    /// to (`isLeavingWorkspace`) and takes no events.
    private(set) var isLeaving = false
    /// What the column last reported with `SupplementaryPaneFramePreferenceKey`,
    /// in its own space, kept while it is pooled too: reused at the size it
    /// reported last, the column reports no change, and so nothing new.
    private(set) var paneFrame = CGRect.zero
    /// Called after `paneFrame` changes.
    var paneFrameChanged: ((ColumnHostingView) -> Void)?

    /// - Parameter sharesExtent: Whether its widths are the same for every
    ///   column of its kind, as a side chat pane's are, so a new one reuses
    ///   the last one's instead of measuring its content again.
    convenience init(content: AnyView, sharesExtent: Bool) {
        self.init(rootView: AnyView(EmptyView()))
        extent.isShared = sharesExtent
        // This view's frame is set from outside; it never asks for one.
        sizingOptions = []
        translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(self)
        setContent(content, isLeaving: false)
    }

    /// While a side chat shows at full width, its column measures no widths:
    /// it has none of its own, and shared with the next pane they made that
    /// pane as wide as the window. It keeps its pane's widths for when it
    /// returns to the pane.
    func showsFullWidth(_ isFullWidth: Bool) {
        extent.isPaused = isFullWidth
    }

    /// Takes the column out of the window. The container holds this view
    /// as its subview while this view owns the container; leaving it breaks
    /// that cycle.
    func discard() {
        container.removeFromSuperview()
        removeFromSuperview()
    }

    /// Advances each time the pool hands this view out again, so its
    /// content presents as a newly opened pane does.
    var presentation = 0

    func setContent(_ content: AnyView, isLeaving: Bool) {
        self.content = content
        self.isLeaving = isLeaving
        rootView = AnyView(
            ColumnMeasuringLayout(extent: extent) {
                content
                    .environment(\.isLeavingWorkspace, isLeaving)
                    .environment(\.columnPresentation, presentation)
                    .onPreferenceChange(SupplementaryPaneFramePreferenceKey.self) { [weak self] frame in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            self.paneFrame = frame
                            self.paneFrameChanged?(self)
                        }
                    }
            }
        )
    }

    override func layout() {
        let widths = (extent.minimum, extent.ideal, extent.maximum)
        super.layout()
        // Measured again, as after an Interface Size change: the workspace
        // places its columns for the new widths.
        if widths != (extent.minimum, extent.ideal, extent.maximum) { container.superview?.needsLayout = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isLeaving ? nil : super.hitTest(point)
    }
}

/// How wide a column's content can be: at least `minimum`, ideally `ideal`
/// and at most `maximum`.
nonisolated private final class ColumnExtent: @unchecked Sendable {
    var minimum: CGFloat = 0
    var ideal: CGFloat = 0
    var maximum: CGFloat = 0
    var height: CGFloat = 0
    /// The Interface Size the widths were measured at.
    var scale: CGFloat = 0
    var isMeasured = false
    var isShared = false
    /// Measures nothing while set (`ColumnHostingView.showsFullWidth`).
    var isPaused = false

    /// The last shared measurement, which takes laying out a whole pane.
    nonisolated(unsafe) private static var shared: ColumnExtent?

    /// Takes the shared measurement for this height and Interface Size, if
    /// there is one.
    func adoptShared(height: CGFloat, scale: CGFloat) -> Bool {
        guard isShared, let shared = Self.shared, shared.height == height, shared.scale == scale else { return false }
        minimum = shared.minimum
        ideal = shared.ideal
        maximum = shared.maximum
        self.height = height
        self.scale = scale
        isMeasured = true
        return true
    }

    /// Shares a copy: this column can go on to measure other widths, for
    /// one when it shows a side chat at full width.
    func share() {
        guard isShared, maximum.isFinite else { return }
        let copy = ColumnExtent()
        copy.minimum = minimum
        copy.ideal = ideal
        copy.maximum = maximum
        copy.height = height
        copy.scale = scale
        copy.isMeasured = true
        Self.shared = copy
    }
}

/// Fills its bounds with its content and records the content's widths, so
/// the column's width is known without measuring it separately.
nonisolated private struct ColumnMeasuringLayout: Layout {
    let extent: ColumnExtent

    func sizeThatFits(proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard let content = subviews.first else { return }
        content.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        // Once per height and Interface Size: the widths come from the
        // column's frame, not from what it shows.
        let height = bounds.height
        let scale = InterfaceScale.factor
        guard !extent.isPaused, !extent.isMeasured || extent.height != height || extent.scale != scale else { return }
        if extent.adoptShared(height: height, scale: scale) { return }
        extent.minimum = content.sizeThatFits(ProposedViewSize(width: 0, height: height)).width
        extent.ideal = content.sizeThatFits(ProposedViewSize(width: nil, height: height)).width
        extent.maximum = content.sizeThatFits(ProposedViewSize(width: .infinity, height: height)).width
        extent.height = height
        extent.scale = scale
        extent.isMeasured = true
        extent.share()
    }
}

extension EnvironmentValues {
    /// Whether this view is in a workspace column that is sliding away
    /// (`WorkspaceColumnsHost`). Until it is out of view it keeps showing
    /// what it showed, though the model has closed it.
    @Entry var isLeavingWorkspace = false
}

/// How much of the conversation's trailing edge a column slides over
/// while the conversation keeps its wider width (`WorkspaceColumnsView`).
/// Views at the conversation's trailing edge, such as the composer
/// (`ConversationFooterHost`), stay clear of it on every frame, outside
/// the conversation's view graph.
final class WorkspaceConversationCover {
    static let shared = WorkspaceConversationCover()
    /// Posted on the main thread, in the frame that moves the columns.
    static let didChange = Notification.Name("SakuraCordWorkspaceConversationCoverDidChange")
    private(set) var trailingInset: CGFloat = 0

    private init() {}

    func update(trailingInset: CGFloat) {
        guard trailingInset != self.trailingInset else { return }
        self.trailingInset = trailingInset
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

/// How wide the workspace's columns are on each frame of a motion, so a
/// timeline that a column slides over re-wraps for the width it shows.
@MainActor
final class WorkspaceConversationWidthPath {
    static let shared = WorkspaceConversationWidthPath()
    /// Posted on the main thread for each frame the columns are placed for
    /// while they move, and once as they stop.
    static let didAdvance = Notification.Name("SakuraCordWorkspaceWidthPathDidAdvance")

    private(set) var isMoving = false
    /// The width, on the last placed frame, of the column holding a view.
    private var width: (NSView) -> CGFloat? = { _ in nil }
    /// Timelines that follow the path rather than their frame.
    private let followers = NSHashTable<NSView>.weakObjects()

    private init() {}

    /// Registers a timeline that re-wraps for the width the path gives it
    /// (`didAdvance`), so a column may slide over it rather than resize it.
    func follow(_ view: NSView) {
        followers.add(view)
    }

    /// Whether `container` shows a timeline that follows the path.
    func hasFollower(in container: NSView) -> Bool {
        followers.allObjects.contains {
            $0.window != nil && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 && $0.isDescendant(of: container)
        }
    }

    func update(isMoving: Bool, width: @escaping (NSView) -> CGFloat?) {
        let stops = !isMoving && self.isMoving
        self.isMoving = isMoving
        self.width = width
        // Before the columns are placed for this frame: a timeline whose
        // column covers it rather than resizing it follows from here.
        if isMoving || stops { NotificationCenter.default.post(name: Self.didAdvance, object: self) }
    }

    /// The width of the column holding `view` on the last placed frame;
    /// nil if the motion does not change it.
    func width(of view: NSView) -> CGFloat? {
        width(view)
    }
}

extension EnvironmentValues {
    /// Which presentation of a pooled column this is (`ColumnHostingView`):
    /// a pane reused for a conversation it showed before presents it anew,
    /// as one built for it would, focusing its composer.
    @Entry var columnPresentation = 0
}
