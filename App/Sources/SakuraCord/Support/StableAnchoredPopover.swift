import AppKit
import SwiftUI

@MainActor
@Observable
final class StablePopoverPresentationContext {
    private(set) var hasFinishedPresenting = false

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
}

enum StablePopoverDismissalBehavior: Equatable {
    case native
    case outsideSourceView
}

struct StablePopoverConfiguration {
    let preferredEdge: NSRectEdge
    let behavior: NSPopover.Behavior
    let animates: Bool
    let ignoresMouseEvents: Bool
    let contentSizing: StablePopoverContentSizing
    let dismissalBehavior: StablePopoverDismissalBehavior
    let stabilizesInitialContentSize: Bool

    static let hover = StablePopoverConfiguration(
        preferredEdge: .minY,
        behavior: .applicationDefined,
        animates: true,
        ignoresMouseEvents: true,
        contentSizing: .constrained(CGSize(width: 400, height: 600)),
        dismissalBehavior: .native,
        stabilizesInitialContentSize: false
    )

    static let intrinsicHoverLabel = StablePopoverConfiguration(
        preferredEdge: .minY,
        behavior: .applicationDefined,
        animates: true,
        ignoresMouseEvents: true,
        contentSizing: .intrinsic,
        dismissalBehavior: .native,
        stabilizesInitialContentSize: false
    )

    static let interactive = StablePopoverConfiguration(
        preferredEdge: .maxX,
        behavior: .transient,
        animates: true,
        ignoresMouseEvents: false,
        contentSizing: .constrained(CGSize(width: 520, height: 760)),
        dismissalBehavior: .native,
        stabilizesInitialContentSize: false
    )

    static let memberProfile = StablePopoverConfiguration(
        preferredEdge: .maxX,
        behavior: .applicationDefined,
        animates: true,
        ignoresMouseEvents: false,
        contentSizing: .constrained(CGSize(width: 520, height: 760)),
        dismissalBehavior: .outsideSourceView,
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

private struct StablePopoverHostedContent<Content: View>: View {
    let content: Content
    let presentationContext: StablePopoverPresentationContext

    var body: some View {
        content.environment(
            \.stablePopoverPresentationContext,
            presentationContext
        )
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
            NSHostingController<StablePopoverHostedContent<Content>>?
        private var presentationContext: StablePopoverPresentationContext?
        private var anchor: StablePopoverAnchor?
        private var anchorSnapshot: StablePopoverAnchorSnapshot?
        private var configuration = StablePopoverConfiguration.hover
        private var onDismiss: () -> Void = {}
        private var showIsScheduled = false
        private var presentationIsScheduled = false
        private var refreshIsScheduled = false
        private var closeIsScheduled = false
        private var shouldPresent = false
        private var generation: UInt64 = 0
        private var geometryObserverTokens: [NSObjectProtocol] = []
        private var dismissalEventMonitor: Any?
        private var latestContent: Content?
        private var presentationIdentity: AnyHashable?
        private var programmaticallyClosingPopovers:
            [ObjectIdentifier: NSPopover] = [:]

        isolated deinit {
            for token in geometryObserverTokens {
                NotificationCenter.default.removeObserver(token)
            }
            if let dismissalEventMonitor {
                NSEvent.removeMonitor(dismissalEventMonitor)
            }
        }

        func update(
            anchor: StablePopoverAnchor,
            anchorSnapshot: StablePopoverAnchorSnapshot?,
            isPresented: Bool,
            configuration: StablePopoverConfiguration,
            onDismiss: @escaping () -> Void,
            presentationIdentity: AnyHashable? = nil,
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
            if replacesPresentedContent {
                generation &+= 1
                resetPresentation()
                installGeometryTracking()
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
                guard let self else { return }
                self.showIsScheduled = false
                guard self.shouldPresent, self.generation == scheduledGeneration else { return }
                self.anchor?.sourceView?.window?.contentView?.layoutSubtreeIfNeeded()
                self.show(content: content)
            }
        }

        private func show(content: Content) {
            guard programmaticallyClosingPopovers.isEmpty else { return }
            guard attachAnchor() != nil else {
                dismissBecauseAnchorIsUnavailable()
                return
            }
            let presentationContext = StablePopoverPresentationContext()
            let hostingController = NSHostingController(
                rootView: StablePopoverHostedContent(
                    content: content,
                    presentationContext: presentationContext
                )
            )
            let popover = NSPopover()
            popover.behavior = configuration.behavior
            popover.animates = configuration.animates
            popover.delegate = self
            popover.contentViewController = hostingController
            self.hostingController = hostingController
            self.presentationContext = presentationContext
            self.popover = popover
            installDismissalMonitorIfNeeded()
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

        private func warmInitialContentSize(
            popover: NSPopover,
            hostingController: NSHostingController<StablePopoverHostedContent<Content>>
        ) {
            switch configuration.contentSizing {
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

        private func installDismissalMonitorIfNeeded() {
            removeDismissalMonitor()
            guard configuration.dismissalBehavior == .outsideSourceView else { return }
            dismissalEventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
            ) { [weak self] event in
                self?.handleDismissalEvent(event) ?? event
            }
        }

        private func handleDismissalEvent(_ event: NSEvent) -> NSEvent? {
            guard shouldPresent else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                dismissFromEventMonitor()
                return nil
            }
            if eventBelongsToPopoverHierarchy(event) {
                return event
            }
            if let sourceView = anchor?.sourceView,
               event.window === sourceView.window,
               sourceView.bounds.contains(
                   sourceView.convert(event.locationInWindow, from: nil)
               )
            {
                return event
            }
            dismissFromEventMonitor()
            return event
        }

        private func eventBelongsToPopoverHierarchy(_ event: NSEvent) -> Bool {
            guard let popoverWindow = popover?.contentViewController?.view.window else {
                return false
            }
            var candidateWindow = event.window
            while let window = candidateWindow {
                if window === popoverWindow {
                    return true
                }
                candidateWindow = window.parent
            }
            return false
        }

        private func dismissFromEventMonitor() {
            let onDismiss = onDismiss
            close()
            onDismiss()
        }

        private func removeDismissalMonitor() {
            guard let dismissalEventMonitor else { return }
            NSEvent.removeMonitor(dismissalEventMonitor)
            self.dismissalEventMonitor = nil
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

        func popoverDidClose(_ notification: Notification) {
            guard let closedPopover = notification.object as? NSPopover else { return }
            let identifier = ObjectIdentifier(closedPopover)
            let closedProgrammatically =
                programmaticallyClosingPopovers.removeValue(forKey: identifier) != nil
            let closedCurrentPopover = popover === closedPopover
            if closedCurrentPopover {
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
            onDismiss()
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
            showIsScheduled = false
            presentationIsScheduled = false
            refreshIsScheduled = false
            closeIsScheduled = false
            if let popover {
                programmaticallyClosingPopovers[ObjectIdentifier(popover)] = popover
                popover.close()
            }
            popover = nil
            hostingController = nil
            presentationContext = nil
            anchorSnapshot = nil
            anchorTracker.detach()
            removeGeometryObservers()
            removeDismissalMonitor()
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
