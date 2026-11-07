import AppKit
import Observation
import SakuraCordModels
import SwiftUI

/// One draggable rail row as the drag overlay sees it.
nonisolated struct ServerRailRow: Equatable {
    let id: GuildRailItem.RailIdentifier
    /// The open folder a server row sits inside.
    let folderID: Int64?
    let isExpandedFolder: Bool
    let frame: CGRect
}

struct ServerRailRowAnchor {
    let id: GuildRailItem.RailIdentifier
    let folderID: Int64?
    let isExpandedFolder: Bool
    let bounds: Anchor<CGRect>
}

struct ServerRailRowsPreferenceKey: PreferenceKey {
    static let defaultValue: [ServerRailRowAnchor] = []

    static func reduce(value: inout [ServerRailRowAnchor], nextValue: () -> [ServerRailRowAnchor]) {
        value.append(contentsOf: nextValue())
    }
}

/// What releasing a dragged row at a point would do.
nonisolated enum ServerRailDropTarget: Equatable {
    case insert(GuildRailDestination, indicatorY: CGFloat)
    /// Onto a standalone server: the two become a new folder.
    case combine(GuildID, frame: CGRect)
    /// Onto a folder's button: the server joins the end of that folder.
    case addToFolder(Int64, frame: CGRect)

    /// The middle half of a row means "onto"; its outer quarters, and the
    /// gaps between rows, mean "between". Rows inside an open folder only
    /// take servers between them.
    static func resolve(
        pointer: CGPoint,
        source: GuildRailItem.RailIdentifier,
        rows: [ServerRailRow],
        rootIDs: [GuildRailItem.RailIdentifier]
    ) -> ServerRailDropTarget? {
        let rows = rows.sorted { $0.frame.minY < $1.frame.minY }
        guard let first = rows.first, let last = rows.last,
              pointer.x > first.frame.minX - 80, pointer.x < first.frame.maxX + 120,
              pointer.y > first.frame.minY - 60, pointer.y < last.frame.maxY + 80
        else { return nil }

        func following(_ id: GuildRailItem.RailIdentifier) -> GuildRailItem.RailIdentifier? {
            rootIDs.firstIndex(of: id).flatMap { rootIDs[($0 + 1)...].first }
        }
        func root(before id: GuildRailItem.RailIdentifier?, at indicatorY: CGFloat) -> ServerRailDropTarget {
            .insert(GuildRailDestination(container: .root, before: id), indicatorY: indicatorY)
        }
        func rootID(of row: ServerRailRow) -> GuildRailItem.RailIdentifier {
            row.folderID.map { .folder($0) } ?? row.id
        }

        guard let row = rows.first(where: { pointer.y < $0.frame.maxY + 5 }) else {
            // Below everything, including the padding under an open folder.
            return rootID(of: last) == source ? nil : root(before: nil, at: last.frame.maxY + (last.folderID == nil ? 5 : 12))
        }
        let position = (pointer.y - row.frame.minY) / max(row.frame.height, 1)

        if case .folder = source {
            // A folder only moves between top-level items, so an open folder
            // under the pointer counts as one block.
            let target = rootID(of: row)
            guard target != source else { return nil }
            let block = rows.filter { rootID(of: $0) == target }
            let top = block.first?.frame.minY ?? row.frame.minY
            let bottom = block.last?.frame.maxY ?? row.frame.maxY
            return pointer.y < (top + bottom) / 2
                ? root(before: target, at: top - 5)
                : root(before: following(target), at: bottom + 5)
        }

        guard row.id != source else { return nil }
        if let folderID = row.folderID {
            if position < 0.5 {
                return .insert(
                    GuildRailDestination(container: .folder(folderID), before: row.id),
                    indicatorY: row.frame.minY - 4
                )
            }
            let members = rows.filter { $0.folderID == folderID }
            let next = members.firstIndex(of: row).flatMap { members[($0 + 1)...].first }?.id
            return .insert(
                GuildRailDestination(container: .folder(folderID), before: next),
                indicatorY: row.frame.maxY + 4
            )
        }
        if position < 0.25 { return root(before: row.id, at: row.frame.minY - 5) }
        switch row.id {
        case .guild(let guildID):
            if position <= 0.75 { return .combine(guildID, frame: row.frame) }
        case .folder(let folderID):
            if position <= 0.75 { return .addToFolder(folderID, frame: row.frame) }
            if row.isExpandedFolder {
                return .insert(
                    GuildRailDestination(
                        container: .folder(folderID),
                        before: rows.first { $0.folderID == folderID }?.id
                    ),
                    indicatorY: row.frame.maxY + 4
                )
            }
        }
        return root(before: following(row.id), at: row.frame.maxY + 5)
    }
}

/// A released row travelling from where it was let go to its slot.
nonisolated struct ServerRailFlight: Equatable {
    let id: GuildRailItem.RailIdentifier
    let start: CGRect
    let token = UUID()

    static let liftedScale: CGFloat = 1.06
}

/// Owns one drag of a rail row. The rail draws the dragged row itself, in an
/// overlay above the neighbouring panes, because SwiftUI's reordering cannot
/// drop one item onto another and places a dropped item without animation.
@Observable
final class ServerRailDragController {
    /// Rows observe only the dragged row and the flight. Pointer movement
    /// publishes `pointer`, which only the overlay reads.
    private(set) var draggedID: GuildRailItem.RailIdentifier?
    private(set) var flight: ServerRailFlight?
    /// The pointer in window coordinates, so the rail scrolling underneath a
    /// still pointer does not move it.
    private(set) var pointer = CGPoint.zero
    /// Where the pointer took hold of the row, measured from the row's origin.
    private(set) var grab: CGSize?

    @ObservationIgnored private var startPointer = CGPoint.zero
    /// The rail's visible area in window coordinates. Row frames are relative
    /// to its origin.
    @ObservationIgnored private(set) var viewport = CGRect.zero
    @ObservationIgnored private(set) var rows: [ServerRailRow] = []
    @ObservationIgnored private weak var scrollView: NSScrollView?
    @ObservationIgnored private var autoscrollTask: Task<Void, Never>?
    @ObservationIgnored var rootIDs: [GuildRailItem.RailIdentifier] = []
    @ObservationIgnored var perform: (GuildRailItem.RailIdentifier, ServerRailDropTarget) -> Void = { _, _ in }
    /// A drag ends with a mouse-up that the row's button would otherwise
    /// treat as a click.
    @ObservationIgnored private(set) var swallowsClick = false
    /// While the rail scrolls, rows passing under a resting pointer do not
    /// take hover; following it re-rendered every row the scroll carried by.
    /// Rows observe it only to take the hover they skipped once it ends.
    var isScrolling = false

    var isTracking: Bool { draggedID != nil || flight != nil }

    /// The pointer relative to the rail's visible area.
    var localPointer: CGPoint {
        CGPoint(x: pointer.x - viewport.minX, y: pointer.y - viewport.minY)
    }

    /// Where the dragged copy of a row is drawn: held at the point it was
    /// grabbed, wherever the row itself has scrolled to.
    func previewFrame(for row: ServerRailRow) -> CGRect {
        guard let grab else {
            return row.frame.offsetBy(dx: pointer.x - startPointer.x, dy: pointer.y - startPointer.y)
        }
        return CGRect(
            origin: CGPoint(x: localPointer.x - grab.width, y: localPointer.y - grab.height),
            size: row.frame.size
        )
    }

    /// Scrolls the rail while a dragged row is held near its top or bottom
    /// edge. This drives the rail's AppKit scroll view directly, so ordinary
    /// scrolling keeps its unmodified behavior.
    private func startAutoscroll() {
        scrollView = Self.scrollViewUnderPointer()
        autoscrollTask?.cancel()
        autoscrollTask = Task { [weak self] in
            while !Task.isCancelled, self?.draggedID != nil {
                try? await Task.sleep(for: .milliseconds(16))
                self?.autoscroll()
            }
        }
    }

    private func autoscroll() {
        guard draggedID != nil, let scrollView, let window = scrollView.window,
              let document = scrollView.documentView
        else { return }
        let point = scrollView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let insets = scrollView.contentInsets
        let fromTop = (scrollView.isFlipped ? point.y - scrollView.bounds.minY : scrollView.bounds.maxY - point.y)
            - insets.top
        let fromBottom = scrollView.bounds.height - insets.top - insets.bottom - fromTop
        let edge: CGFloat = 48
        let speed: CGFloat = 14
        var step: CGFloat = 0
        if fromTop < edge {
            step = -speed * min(1, (edge - fromTop) / edge)
        } else if fromBottom < edge {
            step = speed * min(1, (edge - fromBottom) / edge)
        }
        guard step != 0 else { return }

        let clipView = scrollView.contentView
        var origin = clipView.bounds.origin
        // Offsets run downward from the top of the content.
        let offset = clipView.isFlipped
            ? origin.y + insets.top
            : document.frame.height - clipView.bounds.height + insets.top - origin.y
        let maximum = max(0, document.frame.height - clipView.bounds.height + insets.top + insets.bottom)
        let target = min(max(offset + step, 0), maximum)
        guard abs(target - offset) > 0.01 else { return }
        origin.y += clipView.isFlipped ? target - offset : offset - target
        clipView.scroll(to: origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    /// The innermost scroll view under the pointer, which at the start of a
    /// drag is the rail's own.
    private static func scrollViewUnderPointer() -> NSScrollView? {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let content = window.contentView else { return nil }
        let pointer = window.mouseLocationOutsideOfEventStream
        var best: (view: NSScrollView, area: CGFloat)?
        var pending: [NSView] = [content]
        while let view = pending.popLast() {
            pending.append(contentsOf: view.subviews)
            guard let scrollView = view as? NSScrollView, !scrollView.isHiddenOrHasHiddenAncestor else { continue }
            let frame = scrollView.convert(scrollView.bounds, to: nil)
            let area = frame.width * frame.height
            if frame.contains(pointer), area > 0, area < best?.area ?? .infinity {
                best = (scrollView, area)
            }
        }
        return best?.view
    }

    func layout(rows: [ServerRailRow], viewport: CGRect) {
        self.rows = rows
        self.viewport = viewport
        if grab == nil, let row = rows.first(where: { $0.id == draggedID }) {
            grab = CGSize(
                width: startPointer.x - viewport.minX - row.frame.minX,
                height: startPointer.y - viewport.minY - row.frame.minY
            )
        }
    }

    func changed(_ id: GuildRailItem.RailIdentifier, _ value: DragGesture.Value) {
        if draggedID == nil {
            guard flight == nil else { return }
            draggedID = id
            grab = nil
            startPointer = value.startLocation
            swallowsClick = true
            startAutoscroll()
        }
        guard draggedID == id else { return }
        pointer = value.location
    }

    func ended(_ id: GuildRailItem.RailIdentifier, _ value: DragGesture.Value) {
        guard draggedID == id else { return }
        pointer = value.location
        let row = rows.first { $0.id == id }
        let target = row.flatMap { _ in
            ServerRailDropTarget.resolve(pointer: localPointer, source: id, rows: rows, rootIDs: rootIDs)
        }
        draggedID = nil
        autoscrollTask?.cancel()
        autoscrollTask = nil
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            swallowsClick = false
        }
        if let row {
            let flight = ServerRailFlight(id: id, start: previewFrame(for: row))
            self.flight = flight
            // The flight normally ends itself; never leave a row hidden.
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                finishFlight(flight.token)
            }
        }
        if let target {
            withAnimation(ServerRailAnimations.reorder) { perform(id, target) }
        }
    }

    func finishFlight(_ token: UUID) {
        if flight?.token == token { flight = nil }
    }
}

/// Makes a rail row draggable and, while a drag is in progress, reports its
/// frame so the overlay can find drop targets.
struct ServerRailDraggableRow: ViewModifier {
    let id: GuildRailItem.RailIdentifier
    var folderID: Int64?
    var isExpandedFolder = false
    @Environment(ServerRailDragController.self) private var drag

    func body(content: Content) -> some View {
        let isTracking = drag.isTracking
        content
            .opacity(drag.flight?.id == id ? 0 : drag.draggedID == id ? 0.3 : 1)
            .anchorPreference(key: ServerRailRowsPreferenceKey.self, value: .bounds) { bounds in
                isTracking
                    ? [ServerRailRowAnchor(id: id, folderID: folderID, isExpandedFolder: isExpandedFolder, bounds: bounds)]
                    : []
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .global)
                    .onChanged { drag.changed(id, $0) }
                    .onEnded { drag.ended(id, $0) }
            )
    }
}

/// Draws the dragged row, where it would land, and its flight into place.
struct ServerRailDragOverlay<Preview: View>: View {
    let rows: [ServerRailRow]
    /// The rail's visible area in window coordinates.
    let viewport: CGRect
    let rootIDs: [GuildRailItem.RailIdentifier]
    /// The collapsed folder that now holds a server without a row of its own.
    let enclosingFolder: (GuildRailItem.RailIdentifier) -> GuildRailItem.RailIdentifier?
    let drag: ServerRailDragController
    @ViewBuilder let preview: (GuildRailItem.RailIdentifier) -> Preview

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let id = drag.draggedID, let row = rows.first(where: { $0.id == id }) {
                if let target = ServerRailDropTarget.resolve(
                    pointer: CGPoint(x: drag.pointer.x - viewport.minX, y: drag.pointer.y - viewport.minY),
                    source: id, rows: rows, rootIDs: rootIDs
                ) {
                    indicator(for: target)
                }
                let frame = drag.previewFrame(for: row)
                preview(id)
                    .frame(width: row.frame.width, height: row.frame.height)
                    .scaleEffect(ServerRailFlight.liftedScale)
                    .shadow(color: .black.opacity(0.3), radius: InterfaceScale.metric(8), y: 4)
                    .position(x: frame.midX, y: frame.midY)
                    .transition(.identity)
            }
            if let flight = drag.flight {
                if let slot = rows.first(where: { $0.id == flight.id }) {
                    ServerRailFlightView(start: flight.start, end: slot.frame, vanishes: false) {
                        preview(flight.id)
                    } finished: {
                        drag.finishFlight(flight.token)
                    }
                    .id(flight.token)
                    .transition(.identity)
                } else if let folder = enclosingFolder(flight.id),
                          let slot = rows.first(where: { $0.id == folder })
                {
                    ServerRailFlightView(start: flight.start, end: slot.frame, vanishes: true) {
                        preview(flight.id)
                    } finished: {
                        drag.finishFlight(flight.token)
                    }
                    .id(flight.token)
                    .transition(.identity)
                }
            }
        }
        .onChange(of: rows, initial: true) { _, rows in drag.layout(rows: rows, viewport: viewport) }
        .onChange(of: viewport) { _, viewport in drag.layout(rows: rows, viewport: viewport) }
        .onChange(of: rootIDs, initial: true) { _, rootIDs in drag.rootIDs = rootIDs }
    }

    @ViewBuilder
    private func indicator(for target: ServerRailDropTarget) -> some View {
        switch target {
        case .insert(_, let indicatorY):
            Capsule()
                .fill(SakuraCordAccentColor.color)
                .frame(width: InterfaceScale.metric(40), height: InterfaceScale.metric(4))
                .position(x: ChatChromeMetrics.serverRailWidth / 2, y: indicatorY)
        case .combine(_, let frame), .addToFolder(_, let frame):
            RoundedRectangle(cornerRadius: InterfaceScale.metric(17), style: .continuous)
                .fill(SakuraCordAccentColor.color.opacity(0.22))
                .strokeBorder(SakuraCordAccentColor.color, lineWidth: 2)
                .frame(width: InterfaceScale.metric(52), height: InterfaceScale.metric(52))
                .position(x: frame.minX + ChatChromeMetrics.serverRailWidth / 2, y: frame.midY)
        }
    }
}

private struct ServerRailFlightView<Content: View>: View {
    let start: CGRect
    let end: CGRect
    /// Shrinks away into a collapsed folder instead of settling into a slot.
    let vanishes: Bool
    @ViewBuilder let content: () -> Content
    let finished: () -> Void
    @State private var hasLanded = false

    var body: some View {
        let frame = hasLanded ? end : start
        content()
            .frame(width: start.width, height: start.height)
            // Starts exactly as the dragged row looked when it was released.
            .scaleEffect(hasLanded ? (vanishes ? 0.4 : 1) : ServerRailFlight.liftedScale)
            .shadow(color: .black.opacity(hasLanded ? 0 : 0.3), radius: InterfaceScale.metric(8), y: 4)
            .opacity(hasLanded && vanishes ? 0 : 1)
            .position(x: frame.midX, y: frame.midY)
            .onAppear {
                withAnimation(ServerRailAnimations.reorder) {
                    hasLanded = true
                } completion: {
                    finished()
                }
            }
    }
}
