import AppKit
import SwiftUI

@MainActor
final class ComponentChoiceOverlayController {
    private static let width: CGFloat = 372
    private static let height: CGFloat = 360

    private var host: ComponentChoiceOverlayHost?
    private var eventMonitor: Any?
    private var resizeObserver: NSObjectProtocol?
    private var scrollObserver: NSObjectProtocol?
    private weak var anchorView: NSView?
    private var anchorRectProvider: (() -> CGRect?)?
    private var resultPlacement: SelectionFieldResultPlacement = .below
    private let initialSelection: [String]
    private var selection: [String]
    private let minimumSelectionCount: Int
    private let maximumSelectionCount: Int
    private let submit: ([String]) -> Void
    private let onClose: () -> Void
    private var submitted = false
    private var closed = false

    init(
        initialSelection: [String],
        minimumSelectionCount: Int,
        maximumSelectionCount: Int,
        submit: @escaping ([String]) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.initialSelection = initialSelection
        selection = initialSelection
        self.minimumSelectionCount = max(0, minimumSelectionCount)
        self.maximumSelectionCount = max(1, maximumSelectionCount)
        self.submit = submit
        self.onClose = onClose
    }

    static func placement(
        for anchorRect: CGRect,
        in anchorView: NSView
    ) -> SelectionFieldResultPlacement {
        let viewport = anchorView.visibleRect
        let spaceBelow = viewport.maxY - anchorRect.maxY
        return spaceBelow >= height ? .below : .above
    }

    func present(
        rootView: AnyView,
        in anchorView: NSView,
        placement: SelectionFieldResultPlacement,
        anchorRectProvider: @escaping () -> CGRect?
    ) {
        self.anchorView = anchorView
        self.anchorRectProvider = anchorRectProvider
        resultPlacement = placement

        guard let anchorRect = anchorRectProvider() else {
            close()
            return
        }

        let host = ComponentChoiceOverlayHost(rootView: rootView)
        host.sizingOptions = []
        host.frame = overlayFrame(
            relativeTo: anchorRect,
            placement: placement
        )
        anchorView.addSubview(host, positioned: .above, relativeTo: nil)
        self.host = host
        installEventMonitor()

        if let clipView = anchorView.enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.repositionWithAnchor()
                }
            }
        }
        if let window = anchorView.window {
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.close()
                }
            }
        }
    }

    func updateSelection(_ value: [String]) {
        selection = value
    }

    func submitSingleSelection(_ value: [String]) {
        selection = value
        guard selectionIsValid else {
            NSSound.beep()
            return
        }
        submitted = true
        submit(value)
        close(commit: false)
    }

    func close(commit: Bool = true) {
        guard !closed else { return }
        closed = true
        if commit,
           !submitted,
           selection != initialSelection,
           selectionIsValid
        {
            submitted = true
            submit(selection)
        }
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }
        host?.removeFromSuperview()
        host = nil
        onClose()
    }

    func repositionWithAnchor() {
        guard let host,
              let anchorView,
              let anchorRect = anchorRectProvider?()
        else {
            close()
            return
        }
        guard anchorView.visibleRect.intersects(anchorRect) else {
            close()
            return
        }
        let frame = overlayFrame(
            relativeTo: anchorRect,
            placement: resultPlacement
        )
        if host.frame != frame {
            host.frame = frame
        }
    }

    private var selectionIsValid: Bool {
        selection.count >= minimumSelectionCount
            && selection.count <= maximumSelectionCount
    }

    private func overlayFrame(
        relativeTo anchorRect: CGRect,
        placement: SelectionFieldResultPlacement
    ) -> CGRect {
        let size = CGSize(
            width: max(Self.width, anchorRect.width),
            height: Self.height
        )
        let originY = placement == .below
            ? anchorRect.minY
            : anchorRect.maxY - size.height
        return CGRect(
            origin: CGPoint(x: anchorRect.minX, y: originY),
            size: size
        )
    }

    private func installEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                close()
                return nil
            }
            guard let host else {
                close()
                return event
            }
            let point = host.convert(event.locationInWindow, from: nil)
            if host.bounds.contains(point) { return event }
            close()
            return event
        }
    }
}

@MainActor
private final class ComponentChoiceOverlayHost: NSHostingView<AnyView> {
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
}
