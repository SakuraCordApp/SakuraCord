import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class NativePickerScrollPosition {
    struct Request {
        let sequence: UInt64
        let id: String
        let anchor: UnitPoint?
    }

    private(set) var request: Request?

    func scrollTo(_ id: String, anchor: UnitPoint? = nil) {
        request = Request(sequence: (request?.sequence ?? 0) &+ 1, id: id, anchor: anchor)
    }
}

struct NativePickerScrollReader<Content: View>: View {
    @State private var position = NativePickerScrollPosition()
    @ViewBuilder let content: (NativePickerScrollPosition) -> Content

    var body: some View { content(position) }
}

/// The same bounded-overlay strategy used by the member and message canvases:
/// exact row origins, binary viewport lookup, and recycled native rows or hosts
/// for visible interactive content. Cell views keep their menus, animations,
/// accessibility and hit targets; scrolling never measures intervening rows.
struct NativePickerDocument<Row: Identifiable, Content: View>: NSViewRepresentable where Row.ID == String {
    let rows: [Row]
    let revision: Int
    let position: NativePickerScrollPosition
    var showsIndicators = true
    var capturesOverlayPointer = false
    let rowHeight: (Row, CGFloat) -> CGFloat
    var pinnedHeader: ((Row) -> Bool)?
    var becameVisible: (Row) -> Void = { _ in }
    var didScrollTo: (Row) -> Void = { _ in }
    var topVisibleRowChanged: (Row) -> Void = { _ in }
    var pointerRowChanged: ((Row) -> Void)?
    var rowActivated: ((Row) -> Void)?
    var nativeContent: ((Row, NSView?, EnvironmentValues) -> NSView?)?
    @ViewBuilder let content: (Row) -> Content
    @Environment(\.self) private var environment

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NativePickerScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = NativePickerCanvas<Row>()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let canvas = scroll.documentView as? NativePickerCanvas<Row> else { return }
        (scroll as? NativePickerScrollView)?.capturesOverlayPointer = capturesOverlayPointer
        scroll.hasVerticalScroller = showsIndicators
        canvas.update(
            rows: rows, revision: revision, width: scroll.contentSize.width,
            height: rowHeight, visible: becameVisible, pinnedHeader: pinnedHeader,
            didScrollTo: didScrollTo, topVisibleRowChanged: topVisibleRowChanged, pointerRowChanged: pointerRowChanged,
            rowActivated: rowActivated,
            nativeContent: { row, reused in nativeContent?(row, reused, environment) },
            content: { row in AnyView(content(row).environment(\.self, environment).id(row.id)) }
        )
        canvas.apply(position.request)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Void) {
        (scroll as? NativePickerScrollView)?.stop()
        (scroll.documentView as? NativePickerCanvas<Row>)?.stop()
        scroll.documentView = nil
    }
}

@MainActor protocol NativePickerReusableRow: AnyObject {
    func clear()
}

@MainActor protocol NativePickerViewport: AnyObject {
    func viewportDidLayout()
    func synchronizePointerHighlight(at location: NSPoint?)
    var activatesRowsOnClick: Bool { get }
    func rowID(at locationInWindow: NSPoint) -> String?
    func activateRow(id: String)
}

final class NativePickerScrollView: NSScrollView {
    private var ownsScrollActivity = false
    var capturesOverlayPointer = false { didSet { updatePointerMonitor() } }
    private var pointerMonitor: Any?
    private weak var pressedView: NSView?
    private var pressedRowID: String?

    override func layout() {
        super.layout()
        (documentView as? any NativePickerViewport)?.viewportDidLayout()
    }

    func stop() {
        finishScroll()
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
        pressedView = nil
        pressedRowID = nil
    }

    private func updatePointerMonitor() {
        guard capturesOverlayPointer, window != nil else {
            if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
            pointerMonitor = nil
            return
        }
        guard pointerMonitor == nil else { return }
        // The composer overlay extends beyond its parent's AppKit hit-test bounds.
        // Route only pointer events inside this scroll view; keyboard focus stays in the editor.
        pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, event.window === self.window, !self.isHiddenOrHasHiddenAncestor,
                      WindowModalCoordinator.allowsInput(for: self) else { return false }
                let inside = self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                let viewport = self.documentView as? any NativePickerViewport
                if event.type == .leftMouseUp, self.releasePress(event, inside: inside) { return true }
                if event.type == .mouseMoved {
                    (self.documentView as? any NativePickerViewport)?.synchronizePointerHighlight(at: event.locationInWindow)
                }
                guard inside else { return false }
                if let scroller = self.verticalScroller, !scroller.isHidden,
                   scroller.bounds.contains(scroller.convert(event.locationInWindow, from: nil)) {
                    return false
                }
                let target = self.documentView.flatMap { $0.hitTest($0.convert(event.locationInWindow, from: nil)) }
                switch event.type {
                case .mouseMoved:
                    target?.mouseMoved(with: event)
                    // Let the covered timeline clear its old hover; its region
                    // guard prevents it from highlighting anything underneath.
                    return false
                case .leftMouseDown where viewport?.activatesRowsOnClick == true:
                    self.pressedRowID = viewport?.rowID(at: event.locationInWindow)
                case .leftMouseDown:
                    self.pressedView = target
                    target?.mouseDown(with: event)
                case .leftMouseUp: target?.mouseUp(with: event)
                case .scrollWheel: self.scrollWheel(with: event)
                default: break
                }
                return true
            }
            return consumed ? nil : event
        }
    }

    /// Completes a press that began in this list, even if released outside it.
    private func releasePress(_ event: NSEvent, inside: Bool) -> Bool {
        if let pressedRowID {
            self.pressedRowID = nil
            let viewport = documentView as? any NativePickerViewport
            if inside, viewport?.rowID(at: event.locationInWindow) == pressedRowID {
                viewport?.activateRow(id: pressedRowID)
            }
            return true
        }
        guard let pressedView else { return false }
        self.pressedView = nil
        pressedView.mouseUp(with: event)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePointerMonitor()
        NotificationCenter.default.removeObserver(self, name: NSScrollView.willStartLiveScrollNotification, object: self)
        NotificationCenter.default.removeObserver(self, name: NSScrollView.didEndLiveScrollNotification, object: self)
        finishScroll()
        guard window != nil else { finishScroll(); return }
        NotificationCenter.default.addObserver(self, selector: #selector(beginScroll), name: NSScrollView.willStartLiveScrollNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(finishScroll), name: NSScrollView.didEndLiveScrollNotification, object: self)
    }

    @objc private func beginScroll() {
        guard !ownsScrollActivity else { return }
        ownsScrollActivity = true
        AppScrollWorkGate.beginActivity()
    }

    @objc func finishScroll() {
        guard ownsScrollActivity else { return }
        ownsScrollActivity = false
        AppScrollWorkGate.endActivity()
    }

    override func scrollWheel(with event: NSEvent) {
        guard WindowModalCoordinator.allowsInput(for: self) else { return }
        (documentView as? any NativePickerViewport)?.synchronizePointerHighlight(at: event.locationInWindow)
        super.scrollWheel(with: event)
    }
}
