import AppKit
import SwiftUI

nonisolated enum StableReactionPickerAnchorPolicy {
    static let freezesAnchorWhilePresented = true
    static let maximumContentSize = CGSize(width: 520, height: 760)

    static func preferredEdge(isInline: Bool) -> NSRectEdge {
        isInline ? .maxX : .minY
    }
}

struct StableReactionPickerPresenter<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let preferredEdge: NSRectEdge
    let accessibilityIdentifier: String
    var behavior: NSPopover.Behavior = .semitransient
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> StableReactionPickerSourceView {
        StableReactionPickerSourceView()
    }

    func updateNSView(_ nsView: StableReactionPickerSourceView, context: Context) {
        context.coordinator.update(
            sourceView: nsView,
            isPresented: isPresented,
            preferredEdge: preferredEdge,
            accessibilityIdentifier: accessibilityIdentifier,
            behavior: behavior,
            content: content(),
            setPresented: { isPresented = $0 }
        )
    }

    static func dismantleNSView(
        _ nsView: StableReactionPickerSourceView,
        coordinator: Coordinator
    ) {
        coordinator.close(notifyBinding: false)
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        private var popover: NSPopover?
        private var hostingController: StablePopoverHostingController<Content>?
        private weak var snapshotAnchor: NSView?
        private weak var returnWindow: NSWindow?
        private weak var returnResponder: NSResponder?
        private var setPresented: ((Bool) -> Void)?
        private var showIsScheduled = false
        private var shouldPresent = false

        func update(
            sourceView: StableReactionPickerSourceView,
            isPresented: Bool,
            preferredEdge: NSRectEdge,
            accessibilityIdentifier: String,
            behavior: NSPopover.Behavior = .semitransient,
            content: Content,
            setPresented: @escaping (Bool) -> Void
        ) {
            self.setPresented = setPresented
            shouldPresent = isPresented
            guard isPresented else {
                close(notifyBinding: false)
                return
            }
            guard popover == nil, !showIsScheduled else { return }
            captureReturnResponder(from: sourceView.window)
            showIsScheduled = true
            Task { @MainActor [weak self, weak sourceView] in
                await Task.yield()
                guard let self, let sourceView else { return }
                self.showIsScheduled = false
                guard self.shouldPresent else { return }
                self.show(
                    sourceView: sourceView,
                    preferredEdge: preferredEdge,
                    accessibilityIdentifier: accessibilityIdentifier,
                    behavior: behavior,
                    content: content
                )
            }
        }

        private func show(
            sourceView: StableReactionPickerSourceView,
            preferredEdge: NSRectEdge,
            accessibilityIdentifier: String,
            behavior: NSPopover.Behavior,
            content: Content
        ) {
            guard popover == nil,
                  let window = sourceView.window,
                  !sourceView.bounds.isEmpty
            else { return }

            captureReturnResponder(from: window)
            sourceView.layoutSubtreeIfNeeded()
            let snapshotAnchor = sourceView.installSnapshotAnchor(in: window)

            let hostingController = StablePopoverHostingController(
                rootView: content,
                dismiss: { [weak self] in
                    self?.close(notifyBinding: true)
                }
            )
            hostingController.view.setAccessibilityIdentifier(accessibilityIdentifier)
            let popover = NSPopover()
            popover.behavior = behavior
            popover.animates = true
            popover.delegate = self
            popover.contentViewController = hostingController

            self.snapshotAnchor = snapshotAnchor
            self.hostingController = hostingController
            self.popover = popover

            let initialSize = sizeStablePopover(
                popover,
                hostingController: hostingController,
                maximumContentSize: Self.maximumContentSize
            )
            let sourceFrame = window.convertToScreen(
                snapshotAnchor.convert(snapshotAnchor.bounds, to: nil)
            )
            let placement = StablePopoverPlacementPolicy.placement(
                sourceFrame: sourceFrame,
                visibleFrame: window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? sourceFrame,
                contentSize: initialSize,
                preferredEdge: preferredEdge
            )
            sizeStablePopover(
                popover,
                hostingController: hostingController,
                maximumContentSize: Self.maximumContentSize,
                placement: placement
            )
            popover.show(
                relativeTo: snapshotAnchor.bounds,
                of: snapshotAnchor,
                preferredEdge: placement.edge
            )
        }

        private static var maximumContentSize: CGSize {
            StableReactionPickerAnchorPolicy.maximumContentSize
        }

        func popoverWillClose(_ notification: Notification) {
            guard Self.currentEventIsEscape else { return }
            restoreReturnResponder()
        }

        func popoverDidClose(_ notification: Notification) {
            finishClosing(notifyBinding: true)
        }

        func close(notifyBinding: Bool) {
            showIsScheduled = false
            shouldPresent = false
            guard let popover else {
                snapshotAnchor?.removeFromSuperview()
                snapshotAnchor = nil
                hostingController = nil
                clearReturnResponder()
                return
            }
            restoreReturnResponder()
            popover.delegate = nil
            popover.performClose(nil)
            restoreReturnResponder()
            finishClosing(notifyBinding: notifyBinding)
        }

        private func finishClosing(notifyBinding: Bool) {
            popover = nil
            hostingController = nil
            snapshotAnchor?.removeFromSuperview()
            snapshotAnchor = nil
            clearReturnResponder()
            guard notifyBinding else { return }
            let setPresented = setPresented
            Task { @MainActor in
                setPresented?(false)
            }
        }

        private func captureReturnResponder(from window: NSWindow?) {
            guard returnWindow == nil, let window else { return }
            returnWindow = window
            returnResponder = window.firstResponder
        }

        private func restoreReturnResponder() {
            guard let window = returnWindow,
                  let responder = returnResponder
            else { return }
            if let view = responder as? NSView,
               view.window !== window
            {
                return
            }
            window.makeFirstResponder(responder)
        }

        private func clearReturnResponder() {
            returnWindow = nil
            returnResponder = nil
        }

        private static var currentEventIsEscape: Bool {
            guard let event = NSApp.currentEvent else { return false }
            return event.type == .keyDown && event.keyCode == 53
        }
    }
}

final class StableReactionPickerSourceView: NSView {
    private let snapshotAnchor = StableReactionPickerSnapshotView()

    func installSnapshotAnchor(in window: NSWindow) -> NSView {
        let rectInWindow = convert(bounds, to: nil)
        if let contentView = window.contentView,
           let container = contentView.superview
        {
            let rectInContent = contentView.convert(rectInWindow, from: nil)
            let frozenFrame = container.convert(rectInContent, from: contentView)
            if snapshotAnchor.superview !== container {
                snapshotAnchor.removeFromSuperview()
                container.addSubview(
                    snapshotAnchor,
                    positioned: .above,
                    relativeTo: contentView
                )
            }
            snapshotAnchor.frame = frozenFrame
        } else {
            if snapshotAnchor.superview !== self {
                snapshotAnchor.removeFromSuperview()
                addSubview(snapshotAnchor)
            }
            snapshotAnchor.frame = bounds
        }
        return snapshotAnchor
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

final class StableReactionPickerSnapshotView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
