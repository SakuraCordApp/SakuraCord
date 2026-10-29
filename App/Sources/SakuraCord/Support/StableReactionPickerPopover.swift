import AppKit
import SwiftUI

nonisolated enum StableReactionPickerAnchorPolicy {
    static let freezesAnchorWhilePresented = true
    static var maximumContentSize: CGSize { CGSize(width: InterfaceScale.metric(520), height: InterfaceScale.metric(760)) }

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
        nsView.modalInputChanged = nil
        coordinator.close(notifyBinding: false)
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        private var popover: NSPopover?
        private var hostingController: StablePopoverHostingController<StablePopoverHostedContent<Content>>?
        private var presentationContext: StablePopoverPresentationContext?
        private weak var snapshotAnchor: NSView?
        private weak var returnWindow: NSWindow?
        private weak var returnResponder: NSResponder?
        private var setPresented: ((Bool) -> Void)?
        private var showIsScheduled = false
        private var shouldPresent = false

        var isShown: Bool { popover?.isShown == true }

        func update(
            sourceView: StableReactionPickerSourceView,
            isPresented: Bool,
            preferredEdge: NSRectEdge,
            accessibilityIdentifier: String,
            behavior: NSPopover.Behavior = .semitransient,
            content: Content,
            setPresented: @escaping (Bool) -> Void
        ) {
            sourceView.modalInputChanged = { [weak self, weak sourceView] in
                guard let sourceView, !WindowModalCoordinator.allowsInput(for: sourceView) else { return }
                self?.close(notifyBinding: true)
            }
            self.setPresented = setPresented
            shouldPresent = isPresented
            guard isPresented, WindowModalCoordinator.allowsInput(for: sourceView) else {
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
            guard popover == nil, WindowModalCoordinator.allowsInput(for: sourceView),
                  let window = sourceView.window,
                  !sourceView.bounds.isEmpty
            else { return }

            captureReturnResponder(from: window)
            sourceView.layoutSubtreeIfNeeded()
            let snapshotAnchor = sourceView.installSnapshotAnchor(in: window)

            let presentationContext = StablePopoverPresentationContext()
            presentationContext.dismiss = { [weak self] in self?.close(notifyBinding: true) }
            self.presentationContext = presentationContext
            let hostingController = StablePopoverHostingController(
                rootView: StablePopoverHostedContent(content: content, presentationContext: presentationContext),
                dismiss: { [weak self] in self?.handleEscape() }
            )
            hostingController.view.setAccessibilityIdentifier(accessibilityIdentifier)
            let popover = NSPopover()
            popover.behavior = behavior
            popover.animates = AppMotionPolicy.animates(.overlays)
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
            hostingController.monitorEscapeKey(
                in: popover.contentViewController?.view.window,
                presentingWindow: window
            )
            presentationContext.markPresentationFinished()
        }

        private func handleEscape() {
            guard presentationContext?.preventsDismissal != true else { return }
            if let escapeAction = presentationContext?.escapeAction {
                escapeAction()
            } else {
                close(notifyBinding: true)
            }
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
                presentationContext = nil
                clearReturnResponder()
                return
            }
            restoreReturnResponder()
            popover.delegate = nil
            popover.animates = popover.animates && AppMotionPolicy.animates(.overlays)
            popover.performClose(nil)
            restoreReturnResponder()
            finishClosing(notifyBinding: notifyBinding)
        }

        private func finishClosing(notifyBinding: Bool) {
            popover = nil
            hostingController = nil
            presentationContext = nil
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
               view.window !== window || !WindowModalCoordinator.allowsInput(for: view)
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

final class StableReactionPickerSourceView: NSView, WindowModalInputParticipant {
    var followsScrolling = false
    var modalInputChanged: (() -> Void)?
    func modalInputDidChange() { modalInputChanged?() }

    private let snapshotAnchor = StableReactionPickerSnapshotView()

    var installedSnapshotAnchor: NSView? { snapshotAnchor.superview == nil ? nil : snapshotAnchor }

    func installSnapshotAnchor(in window: NSWindow) -> NSView {
        if followsScrolling, let documentView = enclosingScrollView?.documentView {
            let frozenFrame = documentView.convert(bounds, from: self)
            snapshotAnchor.removeFromSuperview()
            documentView.addSubview(snapshotAnchor)
            snapshotAnchor.frame = frozenFrame
            return snapshotAnchor
        }
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
