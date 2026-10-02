import AppKit
import SwiftUI

@MainActor
@Observable
final class StablePopoverPresentationContext {
    private(set) var hasFinishedPresenting = false
    var dismiss: (() -> Void)?
    var contentSizeDidChange: (() -> Void)?
    var preventsDismissal = false
    var escapeAction: (() -> Void)?

    func markPresentationFinished() {
        hasFinishedPresenting = true
    }
}

extension EnvironmentValues {
    @Entry var stablePopoverPresentationContext: StablePopoverPresentationContext?
}

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
    case fixed(CGSize)
}

struct StablePopoverConfiguration {
    let preferredEdge: NSRectEdge
    let behavior: NSPopover.Behavior
    let animates: Bool
    let ignoresMouseEvents: Bool
    let contentSizing: StablePopoverContentSizing
    let stabilizesInitialContentSize: Bool
    var reusesPresentationOnIdentityChange = false

    func fixedContentSize(_ size: CGSize) -> Self {
        Self(preferredEdge: preferredEdge, behavior: behavior, animates: animates,
             ignoresMouseEvents: ignoresMouseEvents, contentSizing: .fixed(size),
             stabilizesInitialContentSize: stabilizesInitialContentSize,
             reusesPresentationOnIdentityChange: reusesPresentationOnIdentityChange)
    }

    static let hover = StablePopoverConfiguration(
        preferredEdge: .minY,
        behavior: .applicationDefined,
        animates: true,
        ignoresMouseEvents: true,
        contentSizing: .constrained(CGSize(width: 400, height: 600)),
        stabilizesInitialContentSize: false
    )

    static let intrinsicHoverLabel = StablePopoverConfiguration(
        preferredEdge: .minY,
        behavior: .applicationDefined,
        animates: true,
        ignoresMouseEvents: true,
        contentSizing: .intrinsic,
        stabilizesInitialContentSize: false
    )

    static let interactive = StablePopoverConfiguration(
        preferredEdge: .maxX,
        behavior: .transient,
        animates: true,
        ignoresMouseEvents: false,
        contentSizing: .constrained(CGSize(width: 520, height: 760)),
        stabilizesInitialContentSize: false
    )

    static let memberProfile = StablePopoverConfiguration(
        preferredEdge: .maxX,
        behavior: .semitransient,
        animates: true,
        ignoresMouseEvents: false,
        contentSizing: .constrained(CGSize(width: 520, height: 760)),
        stabilizesInitialContentSize: true,
        reusesPresentationOnIdentityChange: true
    )

    static let toolbarPanel = StablePopoverConfiguration(
        preferredEdge: .minY,
        behavior: .semitransient,
        animates: true,
        ignoresMouseEvents: false,
        contentSizing: .constrained(CGSize(width: 520, height: 760)),
        stabilizesInitialContentSize: true
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
        if anchorView.frame != frame { anchorView.frame = frame }
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
private func applyPopoverContentSize<Content: View>(_ size: CGSize, to popover: NSPopover, hostingController: NSHostingController<Content>) {
    if hostingController.view.frame.size != size { hostingController.view.frame.size = size }
    if popover.contentSize != size { popover.contentSize = size }
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
    applyPopoverContentSize(contentSize, to: popover, hostingController: hostingController)
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
    applyPopoverContentSize(contentSize, to: popover, hostingController: hostingController)
    return contentSize
}

struct StablePopoverHostedContent<Content: View>: View {
    let content: Content
    let presentationContext: StablePopoverPresentationContext

    var body: some View {
        content.environment(
            \.stablePopoverPresentationContext,
            presentationContext
        )
        .tint(SakuraCordAccentColor.color)
    }
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
        private var hostingController:
            StablePopoverHostingController<StablePopoverHostedContent<Content>>?
        private var presentationContext: StablePopoverPresentationContext?
        private var anchor: StablePopoverAnchor?
        private var anchorSnapshot: StablePopoverAnchorSnapshot?
        private var presentedEdge: NSRectEdge?
        private var presentedAnchorFrame: CGRect?
        private var configuration = StablePopoverConfiguration.hover
        private var onDismiss: () -> Void = {}
        private var showIsScheduled = false
        private var presentationIsScheduled = false
        private var refreshIsScheduled = false
        private var closeIsScheduled = false
        private var shouldPresent = false
        private var generation: UInt64 = 0
        private var geometryObserverTokens: [NSObjectProtocol] = []
        private var outsideClickHandler: ((NSEvent) -> Bool)?
        private var outsideClickMonitor: Any?
        private var deactivateObserver: NSObjectProtocol?
        private var latestContent: Content?
        private var presentationIdentity: AnyHashable?
        private var programmaticallyClosingPopovers:
            [ObjectIdentifier: NSPopover] = [:]

        isolated deinit {
            if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
            if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
            for token in geometryObserverTokens {
                NotificationCenter.default.removeObserver(token)
            }
        }

        func update(
            anchor: StablePopoverAnchor,
            anchorSnapshot: StablePopoverAnchorSnapshot?,
            isPresented: Bool,
            configuration: StablePopoverConfiguration,
            onDismiss: @escaping () -> Void,
            presentationIdentity: AnyHashable? = nil,
            outsideClickHandler: ((NSEvent) -> Bool)? = nil,
            content: Content
        ) {
            let sourceChanged = self.anchor?.sourceView !== anchor.sourceView
            let replacesPresentedContent = isPresented
                && presentationIdentity != nil
                && self.presentationIdentity != nil
                && self.presentationIdentity != presentationIdentity
                && popover != nil
            self.anchor = anchor
            self.anchorSnapshot = anchorSnapshot
            self.configuration = configuration
            self.onDismiss = onDismiss
            self.outsideClickHandler = outsideClickHandler
            shouldPresent = isPresented
            latestContent = content
            self.presentationIdentity = presentationIdentity

            if sourceChanged {
                generation &+= 1
                resetPresentation()
                installGeometryTracking()
            }
            guard isPresented else {
                scheduleClose()
                return
            }
            closeIsScheduled = false
            if replacesPresentedContent, !configuration.reusesPresentationOnIdentityChange {
                generation &+= 1
                resetPresentation()
                installGeometryTracking()
                scheduleShow(content: content)
                return
            }
            if let hostingController {
                guard let presentationContext else { return }
                hostingController.rootView = StablePopoverHostedContent(
                    content: content,
                    presentationContext: presentationContext
                )
                scheduleRefresh()
            } else {
                scheduleShow(content: content)
            }
        }

        private func scheduleShow(content: Content) {
            guard !showIsScheduled else { return }
            showIsScheduled = true
            let scheduledGeneration = generation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(20))
                guard let self, self.generation == scheduledGeneration else { return }
                self.showIsScheduled = false
                guard self.shouldPresent, let latestContent = self.latestContent else { return }
                self.anchor?.sourceView?.window?.contentView?.layoutSubtreeIfNeeded()
                self.show(content: latestContent)
            }
        }

        private func show(content: Content) {
            guard let source = anchor?.sourceView, WindowModalCoordinator.allowsInput(for: source) else {
                dismissBecauseAnchorIsUnavailable()
                return
            }
            // An unshown or already-closed popover emits no didClose notification.
            programmaticallyClosingPopovers = programmaticallyClosingPopovers.filter { $0.value.isShown }
            guard programmaticallyClosingPopovers.isEmpty else { return }
            guard attachAnchor() != nil else {
                dismissBecauseAnchorIsUnavailable()
                return
            }
            let presentationContext = StablePopoverPresentationContext()
            presentationContext.contentSizeDidChange = { [weak self] in self?.scheduleRefresh() }
            presentationContext.dismiss = { [weak self] in
                self?.dismissPresentation()
            }
            let hostingController = StablePopoverHostingController(
                rootView: StablePopoverHostedContent(
                    content: content,
                    presentationContext: presentationContext
                ),
                dismiss: { [weak self] in
                    self?.dismissFromCancelOperation()
                }
            )
            let popover = NSPopover()
            popover.behavior = outsideClickHandler == nil ? configuration.behavior : .applicationDefined
            popover.animates = configuration.animates
            popover.delegate = self
            popover.contentViewController = hostingController
            self.hostingController = hostingController
            self.presentationContext = presentationContext
            self.popover = popover
            installOutsideClickHandling()
            if configuration.stabilizesInitialContentSize {
                warmInitialContentSize(
                    popover: popover,
                    hostingController: hostingController
                )
                schedulePopoverPresentation()
            } else {
                showPopover()
            }
        }

        // Semitransient AppKit popovers consume the first click outside their window.
        // A reusable member card instead lets its source handle a different member
        // immediately, without closing and recreating the popover.
        private func installOutsideClickHandling() {
            guard outsideClickHandler != nil else { return }
            outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self, let popover = self.popover, popover.isShown,
                          event.window !== popover.contentViewController?.view.window,
                          self.popoverShouldClose(popover)
                    else { return false }
                    if self.outsideClickHandler?(event) == true { return true }
                    self.dismissPresentation()
                    return false
                }
                return consumed ? nil : event
            }
            deactivateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismissPresentation() }
            }
        }

        private func removeOutsideClickHandling() {
            if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
            outsideClickMonitor = nil
            if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
            deactivateObserver = nil
        }

        private func warmInitialContentSize(
            popover: NSPopover,
            hostingController: NSHostingController<StablePopoverHostedContent<Content>>
        ) {
            switch configuration.contentSizing {
            case let .fixed(size):
                applyPopoverContentSize(size, to: popover, hostingController: hostingController)
            case .intrinsic:
                sizeIntrinsicPopover(popover, hostingController: hostingController)
            case let .constrained(maximumContentSize):
                sizeStablePopover(
                    popover,
                    hostingController: hostingController,
                    maximumContentSize: maximumContentSize
                )
            }
            hostingController.view.layoutSubtreeIfNeeded()
        }

        private func schedulePopoverPresentation() {
            guard !presentationIsScheduled else { return }
            presentationIsScheduled = true
            let scheduledGeneration = generation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(20))
                guard let self else { return }
                self.presentationIsScheduled = false
                guard self.shouldPresent,
                      self.generation == scheduledGeneration,
                      self.popover != nil
                else { return }
                self.hostingController?.view.layoutSubtreeIfNeeded()
                self.showPopover()
            }
        }

        private func showPopover() {
            guard let popover, let hostingController,
                  let sourceFrame = anchorFrameInScreen(),
                  let visibleFrame = visibleScreenFrame(for: sourceFrame)
            else { return }

            let initialSize: CGSize
            switch configuration.contentSizing {
            case let .fixed(size):
                initialSize = size
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
            if case .fixed = configuration.contentSizing {
                let size = StablePopoverPlacementPolicy.constrainedContentSize(initialSize, placement: placement)
                applyPopoverContentSize(size, to: popover, hostingController: hostingController)
            }
            let anchorView = anchorTracker.anchorView
            guard anchorView.window != nil, !anchorView.bounds.isEmpty else { return }
            // Re-presenting an already shown popover interrupts native scroll elasticity.
            // Reposition only when the anchor actually moves or the preferred edge changes.
            if !popover.isShown || presentedEdge != placement.edge || presentedAnchorFrame != sourceFrame {
                let animates = popover.animates
                if popover.isShown, configuration.reusesPresentationOnIdentityChange {
                    popover.animates = false
                }
                popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: placement.edge)
                popover.animates = animates
                presentedEdge = placement.edge
                presentedAnchorFrame = sourceFrame
            } else if popover.positioningRect != anchorView.bounds {
                popover.positioningRect = anchorView.bounds
            }
            popover.contentViewController?.view.window?.ignoresMouseEvents =
                configuration.ignoresMouseEvents
            if !configuration.ignoresMouseEvents {
                hostingController.monitorEscapeKey(
                    in: popover.contentViewController?.view.window,
                    presentingWindow: anchor?.sourceView?.window
                )
            }
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
            // Modal attachment can invalidate the anchor during updateNSView.
            // Publish the binding change after SwiftUI finishes that update.
            Task { @MainActor in onDismiss() }
        }

        private func dismissFromCancelOperation() {
            guard let popover, popoverShouldClose(popover) else { return }
            if let escapeAction = presentationContext?.escapeAction {
                escapeAction()
            } else {
                dismissPresentation()
            }
        }

        private func dismissPresentation() {
            guard shouldPresent,
                  !PopoverSheetLifecycle.hasSheet(in: popover?.contentViewController?.view.window),
                  !PopoverSheetLifecycle.hasSheet(in: anchor?.sourceView?.window)
            else { return }
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
            removeGeometryObservers()
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
                observeGeometry(name: NSView.frameDidChangeNotification, object: view)
                observeGeometry(name: NSView.boundsDidChangeNotification, object: view)
                if view === sourceView.window?.contentView { break }
                observedView = view.superview
            }
            if let window = sourceView.window {
                let token = NotificationCenter.default.addObserver(forName: WindowModalCoordinator.inputDidChange, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let source = self.anchor?.sourceView,
                              !WindowModalCoordinator.allowsInput(for: source) else { return }
                        self.dismissBecauseAnchorIsUnavailable()
                    }
                }
                geometryObserverTokens.append(token)
                observeGeometry(name: NSWindow.didResizeNotification, object: window)
                observeGeometry(name: NSWindow.didMoveNotification, object: window)
            }
        }

        private func observeGeometry(name: Notification.Name, object: AnyObject) {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: object,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleRefresh()
                }
            }
            geometryObserverTokens.append(token)
        }

        private func removeGeometryObservers() {
            for token in geometryObserverTokens {
                NotificationCenter.default.removeObserver(token)
            }
            geometryObserverTokens.removeAll()
        }

        private func scheduleRefresh() {
            guard shouldPresent, !refreshIsScheduled else { return }
            refreshIsScheduled = true
            let scheduledGeneration = generation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(20))
                guard let self else { return }
                self.refreshIsScheduled = false
                guard self.shouldPresent, self.generation == scheduledGeneration else { return }
                self.anchor?.sourceView?.window?.contentView?.layoutSubtreeIfNeeded()
                self.refreshPresentation()
            }
        }

        func scheduleClose() {
            shouldPresent = false
            guard !closeIsScheduled else { return }
            closeIsScheduled = true
            let scheduledGeneration = generation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(20))
                guard let self else { return }
                self.closeIsScheduled = false
                guard !self.shouldPresent,
                      self.generation == scheduledGeneration
                else { return }
                self.resetPresentation()
                self.anchor = nil
                self.latestContent = nil
                self.presentationIdentity = nil
            }
        }

        func isPresenting(identity: AnyHashable) -> Bool {
            shouldPresent && presentationIdentity == identity
        }

        func popoverShouldClose(_ popover: NSPopover) -> Bool {
            presentationContext?.preventsDismissal != true
                && !PopoverSheetLifecycle.hasSheet(in: popover.contentViewController?.view.window)
                && !PopoverSheetLifecycle.hasSheet(in: anchor?.sourceView?.window)
        }

        func popoverWillClose(_ notification: Notification) {
            guard let closingPopover = notification.object as? NSPopover else { return }
            PopoverSheetLifecycle.cancelSheets(in: closingPopover.contentViewController?.view.window)
        }

        func popoverDidClose(_ notification: Notification) {
            guard let closedPopover = notification.object as? NSPopover else { return }
            let identifier = ObjectIdentifier(closedPopover)
            let closedProgrammatically =
                programmaticallyClosingPopovers.removeValue(forKey: identifier) != nil
            let closedCurrentPopover = popover === closedPopover
            if closedCurrentPopover {
                removeOutsideClickHandling()
                popover = nil
                hostingController = nil
                anchorTracker.detach()
            }
            if closedProgrammatically {
                if shouldPresent,
                   programmaticallyClosingPopovers.isEmpty,
                   let latestContent
                {
                    scheduleShow(content: latestContent)
                }
                return
            }
            guard closedCurrentPopover, shouldPresent else { return }
            shouldPresent = false
            presentationIdentity = nil
            let onDismiss = onDismiss
            Task { @MainActor in onDismiss() }
        }

        func popoverDidShow(_ notification: Notification) {
            guard let shownPopover = notification.object as? NSPopover,
                  shownPopover === popover
            else { return }
            presentationContext?.markPresentationFinished()
        }

        func close() {
            shouldPresent = false
            generation &+= 1
            closeIsScheduled = false
            resetPresentation()
            anchor = nil
            latestContent = nil
            presentationIdentity = nil
        }

        private func resetPresentation() {
            removeOutsideClickHandling()
            showIsScheduled = false
            presentationIsScheduled = false
            refreshIsScheduled = false
            closeIsScheduled = false
            hostingController?.stopMonitoringEscapeKey()
            let closingPopover = popover
            popover = nil
            hostingController = nil
            presentationContext = nil
            anchorSnapshot = nil
            presentedEdge = nil
            presentedAnchorFrame = nil
            anchorTracker.detach()
            // Clear the current presentation before close(), whose delegate can run synchronously.
            // Only shown popovers can deliver a close notification.
            if let closingPopover, closingPopover.isShown {
                programmaticallyClosingPopovers[ObjectIdentifier(closingPopover)] = closingPopover
                closingPopover.close()
            }
            removeGeometryObservers()
            if let sourceView = anchor?.sourceView as? StablePopoverSourceView {
                sourceView.geometryDidChange = nil
                sourceView.hierarchyDidChange = nil
            }
        }
    }
}

extension View {
    func stableMemberProfilePopover<PopoverContent: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> PopoverContent
    ) -> some View {
        overlay {
            StableAnchoredPopoverPresenter(
                isPresented: isPresented.wrappedValue,
                configuration: .memberProfile,
                onDismiss: { isPresented.wrappedValue = false },
                content: content
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
