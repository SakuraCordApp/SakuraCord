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
    let rowHeight: (Row, CGFloat) -> CGFloat
    var becameVisible: (Row) -> Void = { _ in }
    var didScrollTo: (Row) -> Void = { _ in }
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
        scroll.hasVerticalScroller = showsIndicators
        canvas.update(
            rows: rows, revision: revision, width: scroll.contentSize.width,
            height: rowHeight, visible: becameVisible,
            didScrollTo: didScrollTo,
            nativeContent: { row, reused in nativeContent?(row, reused, environment) },
            content: { row in AnyView(content(row).environment(\.self, environment).id(row.id)) }
        )
        canvas.apply(position.request)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Void) {
        (scroll as? NativePickerScrollView)?.finishScroll()
        (scroll.documentView as? NativePickerCanvas<Row>)?.stop()
        scroll.documentView = nil
    }
}

@MainActor protocol NativePickerReusableRow: AnyObject {
    func clear()
}

final class NativePickerScrollView: NSScrollView {
    private var ownsScrollActivity = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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
        super.scrollWheel(with: event)
    }
}
