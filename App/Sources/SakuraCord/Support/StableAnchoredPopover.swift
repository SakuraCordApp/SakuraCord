import AppKit
import SwiftUI

nonisolated struct StablePopoverPlacement: Equatable {
    let edge: NSRectEdge
    let availableSpace: CGFloat
}

nonisolated enum StablePopoverPlacementPolicy {
    static let sourceClearance: CGFloat = 18
    static let screenInset: CGFloat = 8

    static func placement(
        sourceFrame: CGRect,
        visibleFrame: CGRect,
        contentSize: CGSize,
        preferredEdge: NSRectEdge
    ) -> StablePopoverPlacement {
        let visibleFrame = visibleFrame.insetBy(dx: screenInset, dy: screenInset)
        let spaces: [NSRectEdge: CGFloat] = [
            .minY: max(0, sourceFrame.minY - visibleFrame.minY),
            .maxY: max(0, visibleFrame.maxY - sourceFrame.maxY),
            .minX: max(0, sourceFrame.minX - visibleFrame.minX),
            .maxX: max(0, visibleFrame.maxX - sourceFrame.maxX)
        ]
        let order = orderedEdges(preferredEdge)
        if let edge = order.first(where: {
            spaces[$0, default: 0] >= requiredSpace(for: $0, contentSize: contentSize)
                && canCenter(
                    contentSize: contentSize,
                    around: sourceFrame,
                    within: visibleFrame,
                    edge: $0
                )
        }) {
            return StablePopoverPlacement(edge: edge, availableSpace: spaces[edge, default: 0])
        }
        if let edge = order.first(where: {
            spaces[$0, default: 0] >= requiredSpace(for: $0, contentSize: contentSize)
        }) {
            return StablePopoverPlacement(edge: edge, availableSpace: spaces[edge, default: 0])
        }
        let edge = order.max {
            let lhs = spaces[$0, default: 0] / requiredSpace(for: $0, contentSize: contentSize)
            let rhs = spaces[$1, default: 0] / requiredSpace(for: $1, contentSize: contentSize)
            return lhs < rhs
        } ?? preferredEdge
        return StablePopoverPlacement(edge: edge, availableSpace: spaces[edge, default: 0])
    }

    static func constrainedContentSize(
        _ contentSize: CGSize,
        placement: StablePopoverPlacement
    ) -> CGSize {
        let available = max(1, placement.availableSpace - sourceClearance)
        switch placement.edge {
        case .minY, .maxY:
            return CGSize(width: contentSize.width, height: min(contentSize.height, available))
        case .minX, .maxX:
            return CGSize(width: min(contentSize.width, available), height: contentSize.height)
        @unknown default:
            return contentSize
        }
    }

    private static func requiredSpace(for edge: NSRectEdge, contentSize: CGSize) -> CGFloat {
        switch edge {
        case .minY, .maxY:
            contentSize.height + sourceClearance
        case .minX, .maxX:
            contentSize.width + sourceClearance
        @unknown default:
            .greatestFiniteMagnitude
        }
    }

    private static func canCenter(
        contentSize: CGSize,
        around sourceFrame: CGRect,
        within visibleFrame: CGRect,
        edge: NSRectEdge
    ) -> Bool {
        switch edge {
        case .minY, .maxY:
            let halfWidth = contentSize.width / 2
            return sourceFrame.midX - halfWidth >= visibleFrame.minX
                && sourceFrame.midX + halfWidth <= visibleFrame.maxX
        case .minX, .maxX:
            let halfHeight = contentSize.height / 2
            return sourceFrame.midY - halfHeight >= visibleFrame.minY
                && sourceFrame.midY + halfHeight <= visibleFrame.maxY
        @unknown default:
            return false
        }
    }

    private static func orderedEdges(_ preferredEdge: NSRectEdge) -> [NSRectEdge] {
        switch preferredEdge {
        case .minY: [.minY, .maxY, .maxX, .minX]
        case .maxY: [.maxY, .minY, .maxX, .minX]
        case .minX: [.minX, .maxX, .minY, .maxY]
        case .maxX: [.maxX, .minX, .minY, .maxY]
        @unknown default: [.minY, .maxY, .maxX, .minX]
        }
    }
}

enum StablePopoverContentSizing {
    case intrinsic
    case constrained(CGSize)
}

struct StablePopoverConfiguration {
    let preferredEdge: NSRectEdge
    let behavior: NSPopover.Behavior
    let animates: Bool
    let ignoresMouseEvents: Bool
    let contentSizing: StablePopoverContentSizing

    static let hover = StablePopoverConfiguration(
        preferredEdge: .minY,
        behavior: .applicationDefined,
        animates: true,
        ignoresMouseEvents: true,
        contentSizing: .constrained(CGSize(width: 400, height: 600))
    )

    static let intrinsicHoverLabel = StablePopoverConfiguration(
        preferredEdge: .minY,
        behavior: .applicationDefined,
        animates: true,
        ignoresMouseEvents: true,
        contentSizing: .intrinsic
    )

    static let interactive = StablePopoverConfiguration(
        preferredEdge: .maxX,
        behavior: .transient,
        animates: true,
        ignoresMouseEvents: false,
        contentSizing: .constrained(CGSize(width: 520, height: 760))
    )
}

nonisolated struct StablePopoverAnchorSnapshot: Equatable, Sendable {
    let mouseLocationInScreen: CGPoint
    let mouseLocationInSource: CGPoint

    func sourceFrameInScreen(sourceSize: CGSize) -> CGRect? {
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              mouseLocationInSource.x >= 0,
              mouseLocationInSource.y >= 0
        else { return nil }

        let frame = CGRect(
            x: mouseLocationInScreen.x - mouseLocationInSource.x,
            y: mouseLocationInScreen.y - (sourceSize.height - mouseLocationInSource.y),
            width: sourceSize.width,
            height: sourceSize.height
        )
        let values = [frame.minX, frame.minY, frame.width, frame.height]
        return values.allSatisfy(\.isFinite) && !frame.isEmpty ? frame : nil
    }
}

@MainActor
final class StablePopoverAnchor {
    private weak var sourceViewStorage: NSView?
    private let sourceRectProvider: () -> CGRect?

    var sourceView: NSView? { sourceViewStorage }

    init(sourceView: NSView, sourceRect: @escaping () -> CGRect?) {
        sourceViewStorage = sourceView
        sourceRectProvider = sourceRect
    }

    func sourceRect() -> CGRect? {
        sourceRectProvider()
    }
}

@MainActor
final class StablePopoverAnchorTracker {
    private(set) weak var sourceView: NSView?
    let anchorView = StablePopoverAnchorView()

    @discardableResult
    func attach(
        to sourceView: NSView,
        sourceRect: CGRect,
        sourceFrameInScreen: CGRect? = nil
    ) -> CGRect? {
        guard let window = sourceView.window,
              let contentView = window.contentView
        else {
            detach()
            return nil
        }

        let frame = sourceFrameInScreen.flatMap {
            Self.frameInWindowContent(
                sourceFrameInScreen: $0,
                window: window,
                contentView: contentView
            )
        } ?? Self.frameInWindowContent(
            sourceView: sourceView,
            sourceRect: sourceRect,
            contentView: contentView
        )
        guard let frame else {
            detach()
            return nil
        }

        self.sourceView = sourceView
        if anchorView.superview !== contentView {
            anchorView.removeFromSuperview()
            contentView.addSubview(anchorView, positioned: .above, relativeTo: nil)
        }
        anchorView.frame = frame
        return frame
    }

    func detach() {
        sourceView = nil
        anchorView.removeFromSuperview()
    }

    static func frameInWindowContent(
        sourceView: NSView,
        sourceRect: CGRect,
        contentView: NSView
    ) -> CGRect? {
        guard let sourceWindow = sourceView.window,
              contentView.window === sourceWindow,
              !sourceRect.isEmpty
        else { return nil }

        let rectInWindow = sourceView.convert(sourceRect, to: nil)
        let rectInContent = contentView.convert(rectInWindow, from: nil)
        let values = [rectInContent.minX, rectInContent.minY, rectInContent.width, rectInContent.height]
        return values.allSatisfy(\.isFinite) && !rectInContent.isEmpty ? rectInContent : nil
    }

    static func frameInWindowContent(
        sourceFrameInScreen: CGRect,
        window: NSWindow,
        contentView: NSView
    ) -> CGRect? {
        guard contentView.window === window, !sourceFrameInScreen.isEmpty else { return nil }
        let rectInWindow = window.convertFromScreen(sourceFrameInScreen)
        let rectInContent = contentView.convert(rectInWindow, from: nil)
        let values = [rectInContent.minX, rectInContent.minY, rectInContent.width, rectInContent.height]
        return values.allSatisfy(\.isFinite) && !rectInContent.isEmpty ? rectInContent : nil
    }
}

@MainActor
@discardableResult
func sizeStablePopover<Content: View>(
    _ popover: NSPopover,
    hostingController: NSHostingController<Content>,
    maximumContentSize: CGSize,
    placement: StablePopoverPlacement? = nil
) -> CGSize {
    let fittingSize = hostingController.sizeThatFits(in: maximumContentSize)
    var contentSize = CGSize(
        width: min(maximumContentSize.width, max(1, fittingSize.width)),
        height: min(maximumContentSize.height, max(1, fittingSize.height))
    )
    if let placement {
        contentSize = StablePopoverPlacementPolicy.constrainedContentSize(
            contentSize,
            placement: placement
        )
    }
    hostingController.view.frame.size = contentSize
    popover.contentSize = contentSize
    return contentSize
}

@MainActor
@discardableResult
func sizeIntrinsicPopover<Content: View>(
    _ popover: NSPopover,
    hostingController: NSHostingController<Content>
) -> CGSize {
    let fittingSize = hostingController.sizeThatFits(
        in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    )
    let contentSize = CGSize(
        width: max(1, fittingSize.width),
        height: max(1, fittingSize.height)
    )
    hostingController.view.frame.size = contentSize
    popover.contentSize = contentSize
    return contentSize
}

struct StableAnchoredPopoverPresenter<Content: View>: NSViewRepresentable {
    let isPresented: Bool
    let anchor: StablePopoverAnchor?
    let anchorSnapshot: StablePopoverAnchorSnapshot?
    let configuration: StablePopoverConfiguration
    let onDismiss: () -> Void
    @ViewBuilder var content: () -> Content

    init(
        isPresented: Bool,
        anchor: StablePopoverAnchor? = nil,
        anchorSnapshot: StablePopoverAnchorSnapshot? = nil,
        configuration: StablePopoverConfiguration,
        onDismiss: @escaping () -> Void = {},
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isPresented = isPresented
        self.anchor = anchor
        self.anchorSnapshot = anchorSnapshot
        self.configuration = configuration
        self.onDismiss = onDismiss
        self.content = content
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> StablePopoverSourceView {
        StablePopoverSourceView()
    }

    func updateNSView(_ nsView: StablePopoverSourceView, context: Context) {
        let resolvedAnchor = anchor ?? StablePopoverAnchor(
            sourceView: nsView,
            sourceRect: { [weak nsView] in nsView?.bounds }
        )
        context.coordinator.update(
            anchor: resolvedAnchor,
            anchorSnapshot: anchorSnapshot,
            isPresented: isPresented,
            configuration: configuration,
            onDismiss: onDismiss,
            content: content()
        )
    }

    static func dismantleNSView(_ nsView: StablePopoverSourceView, coordinator: Coordinator) {
        coordinator.close()
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        private let anchorTracker = StablePopoverAnchorTracker()
        private var popover: NSPopover?
        private var hostingController: NSHostingController<Content>?
        private var anchor: StablePopoverAnchor?
        private var anchorSnapshot: StablePopoverAnchorSnapshot?
        private var configuration = StablePopoverConfiguration.hover
        private var onDismiss: () -> Void = {}
        private var showIsScheduled = false
        private var refreshIsScheduled = false
        private var shouldPresent = false
        private var closesProgrammatically = false
        private var generation: UInt64 = 0

        func update(
            anchor: StablePopoverAnchor,
            anchorSnapshot: StablePopoverAnchorSnapshot?,
            isPresented: Bool,
            configuration: StablePopoverConfiguration,
            onDismiss: @escaping () -> Void,
            content: Content
        ) {
            let sourceChanged = self.anchor?.sourceView !== anchor.sourceView
            self.anchor = anchor
            self.anchorSnapshot = anchorSnapshot
            self.configuration = configuration
            self.onDismiss = onDismiss
            shouldPresent = isPresented

            if sourceChanged {
                generation &+= 1
                resetPresentation()
                installGeometryTracking()
            }
            guard isPresented else {
                close()
                return
            }
            if let hostingController {
                hostingController.rootView = content
                refreshPresentation()
            } else {
                scheduleShow(content: content)
            }
        }

        private func scheduleShow(content: Content) {
            guard !showIsScheduled else { return }
            showIsScheduled = true
            let scheduledGeneration = generation
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                self.showIsScheduled = false
                guard self.shouldPresent, self.generation == scheduledGeneration else { return }
                self.anchor?.sourceView?.window?.contentView?.layoutSubtreeIfNeeded()
                self.show(content: content)
            }
        }

        private func show(content: Content) {
            guard attachAnchor() != nil else {
                dismissBecauseAnchorIsUnavailable()
                return
            }
            let hostingController = NSHostingController(rootView: content)
            let popover = NSPopover()
            popover.behavior = configuration.behavior
            popover.animates = configuration.animates
            popover.delegate = self
            popover.contentViewController = hostingController
            self.hostingController = hostingController
            self.popover = popover
            showPopover()
        }

        private func showPopover() {
            guard let popover, let hostingController,
                  let sourceFrame = anchorFrameInScreen(),
                  let visibleFrame = visibleScreenFrame(for: sourceFrame)
            else { return }

            let initialSize: CGSize
            switch configuration.contentSizing {
            case .intrinsic:
                initialSize = sizeIntrinsicPopover(
                    popover,
                    hostingController: hostingController
                )
            case let .constrained(maximumContentSize):
                initialSize = sizeStablePopover(
                    popover,
                    hostingController: hostingController,
                    maximumContentSize: maximumContentSize
                )
            }
            let placement = StablePopoverPlacementPolicy.placement(
                sourceFrame: sourceFrame,
                visibleFrame: visibleFrame,
                contentSize: initialSize,
                preferredEdge: configuration.preferredEdge
            )
            if case let .constrained(maximumContentSize) = configuration.contentSizing {
                sizeStablePopover(
                    popover,
                    hostingController: hostingController,
                    maximumContentSize: maximumContentSize,
                    placement: placement
                )
            }
            let anchorView = anchorTracker.anchorView
            guard anchorView.window != nil, !anchorView.bounds.isEmpty else { return }
            popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: placement.edge)
            popover.contentViewController?.view.window?.ignoresMouseEvents =
                configuration.ignoresMouseEvents
        }

        private func refreshPresentation() {
            guard shouldPresent, popover != nil else { return }
            guard attachAnchor() != nil else {
                dismissBecauseAnchorIsUnavailable()
                return
            }
            showPopover()
        }

        private func dismissBecauseAnchorIsUnavailable() {
            let onDismiss = onDismiss
            close()
            onDismiss()
        }

        private func attachAnchor() -> CGRect? {
            guard let anchor, let sourceView = anchor.sourceView,
                  let sourceRect = anchor.sourceRect()
            else {
                anchorTracker.detach()
                return nil
            }
            let sourceFrameInScreen = anchorSnapshot?.sourceFrameInScreen(
                sourceSize: sourceRect.size
            )
            return anchorTracker.attach(
                to: sourceView,
                sourceRect: sourceRect,
                sourceFrameInScreen: sourceFrameInScreen
            )
        }

        private func anchorFrameInScreen() -> CGRect? {
            let anchorView = anchorTracker.anchorView
            guard let window = anchorView.window else { return nil }
            return window.convertToScreen(anchorView.convert(anchorView.bounds, to: nil))
        }

        private func visibleScreenFrame(for sourceFrame: CGRect) -> CGRect? {
            if let screen = anchor?.sourceView?.window?.screen {
                return screen.visibleFrame
            }
            return NSScreen.screens.first { $0.frame.contains(sourceFrame.center) }?.visibleFrame
                ?? NSScreen.main?.visibleFrame
        }

        private func installGeometryTracking() {
            NotificationCenter.default.removeObserver(self)
            guard let sourceView = anchor?.sourceView else { return }
            if let sourceView = sourceView as? StablePopoverSourceView {
                sourceView.geometryDidChange = { [weak self, weak sourceView] in
                    guard let self, self.anchor?.sourceView === sourceView else { return }
                    self.scheduleRefresh()
                }
                sourceView.hierarchyDidChange = { [weak self, weak sourceView] in
                    guard let self, self.anchor?.sourceView === sourceView else { return }
                    self.installGeometryTracking()
                    self.scheduleRefresh()
                }
            }

            var observedView: NSView? = sourceView
            while let view = observedView {
                view.postsFrameChangedNotifications = true
                view.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(geometryNotification(_:)),
                    name: NSView.frameDidChangeNotification,
                    object: view
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(geometryNotification(_:)),
                    name: NSView.boundsDidChangeNotification,
                    object: view
                )
                if view === sourceView.window?.contentView { break }
                observedView = view.superview
            }
            if let window = sourceView.window {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(geometryNotification(_:)),
                    name: NSWindow.didResizeNotification,
                    object: window
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(geometryNotification(_:)),
                    name: NSWindow.didMoveNotification,
                    object: window
                )
            }
        }

        @objc private func geometryNotification(_ notification: Notification) {
            scheduleRefresh()
        }

        private func scheduleRefresh() {
            guard shouldPresent, !refreshIsScheduled else { return }
            refreshIsScheduled = true
            let scheduledGeneration = generation
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                self.refreshIsScheduled = false
                guard self.shouldPresent, self.generation == scheduledGeneration else { return }
                self.anchor?.sourceView?.window?.contentView?.layoutSubtreeIfNeeded()
                self.refreshPresentation()
            }
        }

        func popoverDidClose(_ notification: Notification) {
            popover = nil
            hostingController = nil
            anchorTracker.detach()
            guard shouldPresent, !closesProgrammatically else { return }
            shouldPresent = false
            onDismiss()
        }

        func close() {
            shouldPresent = false
            generation &+= 1
            resetPresentation()
            anchor = nil
        }

        private func resetPresentation() {
            showIsScheduled = false
            refreshIsScheduled = false
            closesProgrammatically = true
            popover?.close()
            closesProgrammatically = false
            popover = nil
            hostingController = nil
            anchorSnapshot = nil
            anchorTracker.detach()
            NotificationCenter.default.removeObserver(self)
            if let sourceView = anchor?.sourceView as? StablePopoverSourceView {
                sourceView.geometryDidChange = nil
                sourceView.hierarchyDidChange = nil
            }
        }
    }
}

final class StablePopoverSourceView: NSView {
    var geometryDidChange: (() -> Void)?
    var hierarchyDidChange: (() -> Void)?

    override func layout() {
        super.layout()
        geometryDidChange?()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        hierarchyDidChange?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hierarchyDidChange?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class StablePopoverAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
