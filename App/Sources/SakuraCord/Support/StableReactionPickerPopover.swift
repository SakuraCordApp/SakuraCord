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
        private var hostingController: NSHostingController<Content>?
        private weak var snapshotAnchor: NSView?
        private var setPresented: ((Bool) -> Void)?
        private var showIsScheduled = false
        private var shouldPresent = false

        func update(
            sourceView: NSView,
            isPresented: Bool,
            preferredEdge: NSRectEdge,
            accessibilityIdentifier: String,
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
                    content: content
                )
            }
        }

        private func show(
            sourceView: NSView,
            preferredEdge: NSRectEdge,
            accessibilityIdentifier: String,
            content: Content
        ) {
            guard popover == nil,
                  let window = sourceView.window,
                  let contentView = window.contentView
            else { return }

            let anchorRectInWindow = sourceView.convert(sourceView.bounds, to: nil)
            let frozenFrame = contentView.convert(anchorRectInWindow, from: nil)
            let snapshotAnchor = StableReactionPickerSnapshotView(frame: frozenFrame)
            contentView.addSubview(snapshotAnchor, positioned: .above, relativeTo: nil)

            let hostingController = NSHostingController(rootView: content)
            hostingController.view.setAccessibilityIdentifier(accessibilityIdentifier)
            let popover = NSPopover()
            popover.behavior = .transient
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
                return
            }
            popover.delegate = nil
            popover.performClose(nil)
            finishClosing(notifyBinding: notifyBinding)
        }

        private func finishClosing(notifyBinding: Bool) {
            popover = nil
            hostingController = nil
            snapshotAnchor?.removeFromSuperview()
            snapshotAnchor = nil
            guard notifyBinding else { return }
            let setPresented = setPresented
            Task { @MainActor in
                setPresented?(false)
            }
        }
    }
}

final class StableReactionPickerSourceView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class StableReactionPickerSnapshotView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
