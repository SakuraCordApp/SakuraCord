import AppKit
import SwiftUI

@MainActor
private enum ToolbarSearchFieldLocator {
    static func searchToolbarItem(in window: NSWindow) -> NSSearchToolbarItem? {
        window.toolbar?.items.first { $0 is NSSearchToolbarItem }
            as? NSSearchToolbarItem
    }

    static func searchField(in window: NSWindow) -> NSSearchField? {
        if let searchItem = searchToolbarItem(in: window) {
            return searchItem.searchField
        }
        for item in window.toolbar?.items ?? [] {
            if let view = item.view,
               let searchField = firstSearchField(in: view)
            {
                return searchField
            }
        }
        guard let frameView = window.contentView?.superview else { return nil }
        return firstSearchField(in: frameView)
    }

    private static func firstSearchField(in view: NSView) -> NSSearchField? {
        if let searchField = view as? NSSearchField {
            return searchField
        }
        for subview in view.subviews {
            if let searchField = firstSearchField(in: subview) {
                return searchField
            }
        }
        return nil
    }
}

private final class ToolbarSearchFieldSkeletonOverlay: NSView {
    private let shimmerLayer = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        shimmerLayer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmerLayer.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(shimmerLayer)
        updateColorsForEffectiveAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateColorsForEffectiveAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColorsForEffectiveAppearance()
    }

    private func updateColorsForEffectiveAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor
                .withAlphaComponent(0.09).cgColor
            shimmerLayer.colors = [
                NSColor.clear.cgColor,
                NSColor.labelColor.withAlphaComponent(0.04).cgColor,
                NSColor.labelColor.withAlphaComponent(0.2).cgColor,
                NSColor.labelColor.withAlphaComponent(0.04).cgColor,
                NSColor.clear.cgColor,
            ]
        }
    }

    override func layout() {
        super.layout()
        shimmerLayer.frame = bounds.insetBy(dx: -bounds.width, dy: 0)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              shimmerLayer.animation(forKey: "skeletonShimmer") == nil
        else { return }
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = -bounds.width
        animation.toValue = bounds.width
        animation.duration = SkeletonShimmerStyle.duration
        animation.repeatCount = .infinity
        shimmerLayer.add(animation, forKey: "skeletonShimmer")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

struct ToolbarSearchFieldLoadingStyler: NSViewRepresentable {
    let isActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        Task { @MainActor in
            context.coordinator.update(window: view.window, isActive: isActive)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        Task { @MainActor in
            context.coordinator.update(window: view.window, isActive: isActive)
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private weak var searchField: NSSearchField?
        private var originalAlphaValue: CGFloat?
        private var originalIsEnabled: Bool?
        private var overlay: ToolbarSearchFieldSkeletonOverlay?
        private var retryTask: Task<Void, Never>?

        func update(window: NSWindow?, isActive: Bool) {
            retryTask?.cancel()
            retryTask = nil
            guard isActive else {
                restore()
                return
            }
            retryTask = Task { @MainActor [weak self, weak window] in
                guard let self else { return }
                for _ in 0 ..< 12 {
                    guard !Task.isCancelled, let window else { return }
                    if let field = ToolbarSearchFieldLocator.searchField(in: window) {
                        presentSkeleton(over: field)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
        }

        func detach() {
            retryTask?.cancel()
            retryTask = nil
            restore()
        }

        private func presentSkeleton(over field: NSSearchField) {
            if searchField !== field {
                restore()
                searchField = field
                originalAlphaValue = field.alphaValue
                originalIsEnabled = field.isEnabled
            }
            field.alphaValue = 0
            field.isEnabled = false

            guard overlay == nil, let superview = field.superview else { return }
            let overlay = ToolbarSearchFieldSkeletonOverlay(frame: .zero)
            overlay.translatesAutoresizingMaskIntoConstraints = false
            superview.addSubview(overlay, positioned: .above, relativeTo: field)
            NSLayoutConstraint.activate([
                overlay.leadingAnchor.constraint(equalTo: field.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: field.trailingAnchor),
                overlay.topAnchor.constraint(equalTo: field.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            ])
            self.overlay = overlay
        }

        private func restore() {
            overlay?.removeFromSuperview()
            overlay = nil
            if let searchField {
                if let originalAlphaValue {
                    searchField.alphaValue = originalAlphaValue
                }
                if let originalIsEnabled {
                    searchField.isEnabled = originalIsEnabled
                }
            }
            searchField = nil
            originalAlphaValue = nil
            originalIsEnabled = nil
        }
    }
}

nonisolated private final class SendableNotificationObject: @unchecked Sendable {
    let value: AnyObject?

    init(_ value: AnyObject?) {
        self.value = value
    }
}

nonisolated private final class ToolbarSearchFieldDelegateProxy: NSObject, NSSearchFieldDelegate {
    var forwardingDelegate: (any NSSearchFieldDelegate)?
    let didBeginEditing: @MainActor () -> Void
    let didEndSearching: @MainActor () -> Void
    let didEndEditing: @MainActor () -> Void
    let handleCommand: @MainActor (NSTextView, Selector) -> Bool

    init(
        forwardingDelegate: (any NSSearchFieldDelegate)?,
        didBeginEditing: @escaping @MainActor () -> Void,
        didEndSearching: @escaping @MainActor () -> Void,
        didEndEditing: @escaping @MainActor () -> Void,
        handleCommand: @escaping @MainActor (NSTextView, Selector) -> Bool
    ) {
        self.forwardingDelegate = forwardingDelegate
        self.didBeginEditing = didBeginEditing
        self.didEndSearching = didEndSearching
        self.didEndEditing = didEndEditing
        self.handleCommand = handleCommand
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        forwardingDelegate?.searchFieldDidEndSearching?(sender)
        didEndSearching()
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        forwardingDelegate?.controlTextDidBeginEditing?(notification)
        didBeginEditing()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        forwardingDelegate?.controlTextDidEndEditing?(notification)
        didEndEditing()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if handleCommand(textView, commandSelector) { return true }
        return forwardingDelegate?.control?(
            control,
            textView: textView,
            doCommandBy: commandSelector
        ) ?? false
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector)
            || forwardingDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if forwardingDelegate?.responds(to: selector) == true {
            return forwardingDelegate
        }
        return super.forwardingTarget(for: selector)
    }
}

struct ToolbarSearchFieldMetrics: Equatable {
    static let zero = ToolbarSearchFieldMetrics(fieldWidth: 0, trailingInset: 0)

    let fieldWidth: CGFloat
    let trailingInset: CGFloat

    var isValid: Bool {
        fieldWidth.isFinite
            && trailingInset.isFinite
            && fieldWidth > 0
            && trailingInset >= 0
    }
}

/// Reads SwiftUI's native toolbar search geometry and bridges its public
/// end-search delegate event without duplicating the field or its layout.
struct ToolbarSearchFieldGeometryReader: NSViewRepresentable {
    @Binding var searchText: String
    @Binding var searchTokens: [MessageSearchToken]
    @Binding var isSearchFocused: Bool
    let isToolbarItemVisible: Bool
    let didUseBuiltInClear: @MainActor () -> Void
    let didEndEditing: @MainActor () -> Void
    let pasteCanonicalSyntax: @MainActor (String) -> MessageSearchTokenParser.Result
    let changed: @MainActor (ToolbarSearchFieldMetrics) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            searchText: $searchText,
            searchTokens: $searchTokens,
            isSearchFocused: $isSearchFocused,
            isToolbarItemVisible: isToolbarItemVisible,
            didUseBuiltInClear: didUseBuiltInClear,
            didEndEditing: didEndEditing,
            pasteCanonicalSyntax: pasteCanonicalSyntax,
            changed: changed
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        Task { @MainActor in
            context.coordinator.update(window: view.window, changed: changed)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.searchText = $searchText
        context.coordinator.searchTokens = $searchTokens
        context.coordinator.isSearchFocused = $isSearchFocused
        context.coordinator.isToolbarItemVisible = isToolbarItemVisible
        context.coordinator.didUseBuiltInClear = didUseBuiltInClear
        context.coordinator.didEndEditing = didEndEditing
        context.coordinator.pasteCanonicalSyntax = pasteCanonicalSyntax
        context.coordinator.changed = changed
        if let window = view.window {
            context.coordinator.applyToolbarItemVisibility(in: window)
        }
        Task { @MainActor in
            context.coordinator.update(window: view.window, changed: changed)
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        private struct MenuPatch {
            let item: NSMenuItem
            let target: AnyObject?
            let action: Selector?
        }

        var searchText: Binding<String>
        var searchTokens: Binding<[MessageSearchToken]>
        var isSearchFocused: Binding<Bool>
        var isToolbarItemVisible: Bool
        var didUseBuiltInClear: @MainActor () -> Void
        var didEndEditing: @MainActor () -> Void
        var pasteCanonicalSyntax: @MainActor (String) -> MessageSearchTokenParser.Result
        var changed: @MainActor (ToolbarSearchFieldMetrics) -> Void
        private weak var window: NSWindow?
        private weak var searchField: NSSearchField?
        private weak var searchToolbarItem: NSSearchToolbarItem?
        private var originalSearchToolbarItemIsHidden: Bool?
        private var appliedSearchToolbarItemIsHidden: Bool?
        private weak var sizedSearchToolbarItem: NSSearchToolbarItem?
        private weak var sizedSearchField: NSSearchField?
        private var originalPreferredSearchFieldWidth: CGFloat?
        private var appliedPreferredSearchFieldWidth: CGFloat?
        private var searchFieldWidthConstraint: NSLayoutConstraint?
        private var observers: [NSObjectProtocol] = []
        private var searchFieldDelegateProxy: ToolbarSearchFieldDelegateProxy?
        private var retryTask: Task<Void, Never>?
        private var keyMonitor: Any?
        private var mouseMonitor: Any?
        private var nativeClearPointerActivationPending = false
        private var keyboardClearFocusRestorationPending = false
        private var cancelButtonCell: NSButtonCell?
        private weak var cancelButtonTarget: AnyObject?
        private var cancelButtonAction: Selector?
        private var lastMetrics = ToolbarSearchFieldMetrics.zero
        private var mainMenuPatches: [MenuPatch] = []
        private var trackingMenuPatches: [MenuPatch] = []

        init(
            searchText: Binding<String>,
            searchTokens: Binding<[MessageSearchToken]>,
            isSearchFocused: Binding<Bool>,
            isToolbarItemVisible: Bool,
            didUseBuiltInClear: @escaping @MainActor () -> Void,
            didEndEditing: @escaping @MainActor () -> Void,
            pasteCanonicalSyntax: @escaping @MainActor (String) -> MessageSearchTokenParser.Result,
            changed: @escaping @MainActor (ToolbarSearchFieldMetrics) -> Void
        ) {
            self.searchText = searchText
            self.searchTokens = searchTokens
            self.isSearchFocused = isSearchFocused
            self.isToolbarItemVisible = isToolbarItemVisible
            self.didUseBuiltInClear = didUseBuiltInClear
            self.didEndEditing = didEndEditing
            self.pasteCanonicalSyntax = pasteCanonicalSyntax
            self.changed = changed
            super.init()
        }

        func update(
            window: NSWindow?,
            changed: @escaping @MainActor (ToolbarSearchFieldMetrics) -> Void
        ) {
            self.changed = changed
            if self.window !== window {
                attach(to: window)
            }
            scheduleMeasurement()
        }

        func applyToolbarItemVisibility(in window: NSWindow) {
            _ = updateSearchToolbarItemVisibility(in: window)
        }

        func detach() {
            retryTask?.cancel()
            retryTask = nil
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
                self.mouseMonitor = nil
            }
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
            restoreSearchFieldDelegate()
            restoreSearchToolbarItemVisibility()
            restoreSearchToolbarItemSizing()
            restoreMenuPatches(&mainMenuPatches)
            restoreMenuPatches(&trackingMenuPatches)
            searchField = nil
            window = nil
            lastMetrics = .zero
        }

        private func attach(to window: NSWindow?) {
            detach()
            self.window = window
            guard let window else { return }
            observe(NSWindow.didResizeNotification, object: window)
            observe(NSWindow.didEndLiveResizeNotification, object: window)
            observe(NSMenu.didBeginTrackingNotification, object: nil)
            observe(NSMenu.didEndTrackingNotification, object: nil)
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let eventObject = SendableNotificationObject(event)
                let handled = MainActor.assumeIsolated {
                    guard let event = eventObject.value as? NSEvent else { return false }
                    return self?.handleClipboardShortcut(event) == true
                }
                return handled ? nil : event
            }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                let eventObject = SendableNotificationObject(event)
                MainActor.assumeIsolated {
                    guard let self,
                          let event = eventObject.value as? NSEvent,
                          event.window === self.window,
                          let field = self.searchField,
                          let cell = field.cell as? NSSearchFieldCell
                    else { return }
                    let point = field.convert(event.locationInWindow, from: nil)
                    self.nativeClearPointerActivationPending = cell
                        .cancelButtonRect(forBounds: field.bounds)
                        .contains(point)
                }
                return event
            }
        }

        private func observe(_ name: Notification.Name, object: AnyObject?) {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: object,
                queue: .main
            ) { [weak self] notification in
                let notificationObject = SendableNotificationObject(
                    notification.object as AnyObject?
                )
                Task { @MainActor [weak self, notificationObject] in
                    guard let self else { return }
                    if name == NSMenu.didBeginTrackingNotification,
                       let menu = notificationObject.value as? NSMenu,
                       self.activeSearchEditor != nil
                    {
                        self.restoreMenuPatches(&self.trackingMenuPatches)
                        self.patchMenu(menu, storingIn: &self.trackingMenuPatches)
                    } else if name == NSMenu.didEndTrackingNotification {
                        self.restoreMenuPatches(&self.trackingMenuPatches)
                    } else {
                        self.scheduleMeasurement()
                    }
                }
            }
            observers.append(observer)
        }

        private func scheduleMeasurement() {
            retryTask?.cancel()
            retryTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for _ in 0 ..< 12 {
                    guard !Task.isCancelled else { return }
                    if measure() {
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
        }

        @discardableResult
        private func measure() -> Bool {
            guard let window,
                  updateSearchToolbarItemVisibility(in: window)
            else { return false }
            guard isToolbarItemVisible else {
                updateMetrics(.zero)
                return true
            }
            guard
                  let contentView = window.contentView,
                  let searchField = ToolbarSearchFieldLocator.searchField(in: window),
                  searchField.window === window
            else { return false }

            if self.searchField !== searchField {
                restoreSearchFieldDelegate()
                self.searchField = searchField
                searchField.postsFrameChangedNotifications = true
                observe(NSView.frameDidChangeNotification, object: searchField)
                let proxy = ToolbarSearchFieldDelegateProxy(
                    forwardingDelegate: searchField.delegate,
                    didBeginEditing: { [weak self] in
                        guard let self else { return }
                        isSearchFocused.wrappedValue = true
                        installMainMenuPatches()
                    },
                    didEndSearching: { [weak self] in
                        guard let self,
                              nativeClearPointerActivationPending
                                || currentEventTargetsNativeClearButton
                        else { return }
                        nativeClearPointerActivationPending = false
                        didUseBuiltInClear()
                    },
                    didEndEditing: { [weak self] in
                        guard let self else { return }
                        restoreMenuPatches(&mainMenuPatches)
                        guard !keyboardClearFocusRestorationPending else { return }
                        didEndEditing()
                    },
                    handleCommand: { [weak self] editor, selector in
                        self?.handleCommand(editor, selector: selector) ?? false
                    }
                )
                searchFieldDelegateProxy = proxy
                searchField.delegate = proxy
                installNativeClearButtonAction(in: searchField)
            }
            if searchField.currentEditor() != nil {
                installMainMenuPatches()
            }

            let fieldRect = searchField.convert(searchField.bounds, to: nil)
            let contentRect = contentView.convert(contentView.bounds, to: nil)
            let metrics = ToolbarSearchFieldMetrics(
                fieldWidth: fieldRect.width,
                trailingInset: max(0, contentRect.maxX - fieldRect.maxX)
            )
            guard metrics.isValid else { return false }
            updateMetrics(metrics)
            return true
        }

        private func updateSearchToolbarItemVisibility(
            in window: NSWindow
        ) -> Bool {
            guard let item = ToolbarSearchFieldLocator.searchToolbarItem(
                in: window
            ) else { return false }
            if searchToolbarItem !== item {
                restoreSearchToolbarItemVisibility()
                searchToolbarItem = item
                originalSearchToolbarItemIsHidden = item.isHidden
            }
            if sizedSearchToolbarItem !== item
                || sizedSearchField !== item.searchField
            {
                _ = updateSearchToolbarItemSizing(
                    item,
                    width: ChatChromeMetrics.toolbarSearchMaximumFieldWidth
                )
            }
            let isHidden = isToolbarItemVisible
                ? (originalSearchToolbarItemIsHidden ?? false)
                : true
            item.isHidden = isHidden
            appliedSearchToolbarItemIsHidden = isHidden
            return true
        }

        private func updateSearchToolbarItemSizing(
            _ item: NSSearchToolbarItem,
            width: CGFloat
        ) -> Bool {
            if sizedSearchToolbarItem !== item {
                restoreSearchToolbarItemSizing()
                sizedSearchToolbarItem = item
                originalPreferredSearchFieldWidth =
                    item.preferredWidthForSearchField
            }

            let field = item.searchField
            if sizedSearchField !== field {
                searchFieldWidthConstraint?.isActive = false
                sizedSearchField = field
                let constraint = field.widthAnchor.constraint(
                    equalToConstant: width
                )
                constraint.identifier = "SakuraCord.ToolbarSearchFieldWidth"
                constraint.isActive = true
                searchFieldWidthConstraint = constraint
            } else if let searchFieldWidthConstraint,
                      abs(searchFieldWidthConstraint.constant - width) > 0.5
            {
                searchFieldWidthConstraint.constant = width
            } else {
                return false
            }

            item.preferredWidthForSearchField = width
            appliedPreferredSearchFieldWidth = width
            return true
        }

        private func restoreSearchToolbarItemVisibility() {
            if let searchToolbarItem,
               let originalSearchToolbarItemIsHidden,
               let appliedSearchToolbarItemIsHidden,
               searchToolbarItem.isHidden == appliedSearchToolbarItemIsHidden
            {
                searchToolbarItem.isHidden = originalSearchToolbarItemIsHidden
            }
            searchToolbarItem = nil
            originalSearchToolbarItemIsHidden = nil
            appliedSearchToolbarItemIsHidden = nil
        }

        private func restoreSearchToolbarItemSizing() {
            searchFieldWidthConstraint?.isActive = false
            searchFieldWidthConstraint = nil
            sizedSearchField = nil
            if let sizedSearchToolbarItem,
               let originalPreferredSearchFieldWidth,
               let appliedPreferredSearchFieldWidth,
               sizedSearchToolbarItem.preferredWidthForSearchField
                == appliedPreferredSearchFieldWidth
            {
                sizedSearchToolbarItem.preferredWidthForSearchField =
                    originalPreferredSearchFieldWidth
            }
            sizedSearchToolbarItem = nil
            originalPreferredSearchFieldWidth = nil
            appliedPreferredSearchFieldWidth = nil
        }

        private func updateMetrics(_ metrics: ToolbarSearchFieldMetrics) {
            guard metrics != lastMetrics else { return }
            lastMetrics = metrics
            changed(metrics)
        }

        private func restoreSearchFieldDelegate() {
            restoreNativeClearButtonAction()
            guard let proxy = searchFieldDelegateProxy else { return }
            if searchField?.delegate as AnyObject? === proxy {
                searchField?.delegate = proxy.forwardingDelegate
            }
            searchFieldDelegateProxy = nil
        }

        private func installNativeClearButtonAction(in searchField: NSSearchField) {
            guard let cell = searchField.cell as? NSSearchFieldCell,
                  let cancel = cell.cancelButtonCell
            else { return }
            cancelButtonCell = cancel
            cancelButtonTarget = cancel.target as AnyObject?
            cancelButtonAction = cancel.action
            cancel.target = self
            cancel.action = #selector(nativeClearButtonActivated(_:))
        }

        private func restoreNativeClearButtonAction() {
            guard let cancelButtonCell,
                  cancelButtonCell.target === self
            else {
                self.cancelButtonCell = nil
                cancelButtonTarget = nil
                cancelButtonAction = nil
                return
            }
            cancelButtonCell.target = cancelButtonTarget
            cancelButtonCell.action = cancelButtonAction
            self.cancelButtonCell = nil
            cancelButtonTarget = nil
            cancelButtonAction = nil
        }

        @objc private func nativeClearButtonActivated(_ sender: Any?) {
            if let cancelButtonAction {
                NSApp.sendAction(
                    cancelButtonAction,
                    to: cancelButtonTarget,
                    from: sender
                )
            }
            nativeClearPointerActivationPending = false
            didUseBuiltInClear()
        }

        private func handleCommand(_ editor: NSTextView, selector: Selector) -> Bool {
            guard isSearchFocused.wrappedValue,
                  editor.window === searchField?.window
            else { return false }
            switch selector {
            case #selector(NSText.copy(_:)):
                return copySearchSelection(in: editor)
            case #selector(NSText.cut(_:)):
                return cutSearchSelection(in: editor)
            case #selector(NSText.paste(_:)):
                return pasteCanonicalSyntax(in: editor)
            default:
                return false
            }
        }

        private func handleClipboardShortcut(_ event: NSEvent) -> Bool {
            nativeClearPointerActivationPending = false
            guard let editor = activeSearchEditor else { return false }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.isEmpty,
               event.keyCode == 51 || event.keyCode == 117,
               deletionWillEmptyEditor(editor, keyCode: event.keyCode)
            {
                restoreSearchFocusAfterKeyboardClear()
                return false
            }
            guard modifiers == .command,
                  let character = event.charactersIgnoringModifiers?.lowercased()
            else { return false }
            switch character {
            case "c":
                return copySearchSelection(in: editor)
            case "x":
                return cutSearchSelection(in: editor)
            case "v":
                return pasteCanonicalSyntax(in: editor)
            default:
                return false
            }
        }

        private var currentEventTargetsNativeClearButton: Bool {
            guard let event = NSApp.currentEvent,
                  event.type == .leftMouseDown || event.type == .leftMouseUp,
                  event.window === window,
                  let field = searchField,
                  let cell = field.cell as? NSSearchFieldCell
            else { return false }
            let point = field.convert(event.locationInWindow, from: nil)
            return cell.cancelButtonRect(forBounds: field.bounds).contains(point)
        }

        @objc private func copyMessageSearch(_ sender: Any?) {
            guard let editor = activeSearchEditor,
                  copySearchSelection(in: editor)
            else {
                forward(#selector(NSText.copy(_:)), sender: sender)
                return
            }
        }

        @objc private func cutMessageSearch(_ sender: Any?) {
            guard let editor = activeSearchEditor,
                  cutSearchSelection(in: editor)
            else {
                forward(#selector(NSText.cut(_:)), sender: sender)
                return
            }
        }

        @objc private func pasteMessageSearch(_ sender: Any?) {
            guard let editor = activeSearchEditor else {
                forward(#selector(NSText.paste(_:)), sender: sender)
                return
            }
            if !pasteCanonicalSyntax(in: editor) {
                editor.paste(sender)
            }
        }

        private var activeSearchEditor: NSTextView? {
            guard isSearchFocused.wrappedValue,
                  let editor = searchField?.currentEditor() as? NSTextView,
                  editor === window?.firstResponder
            else { return nil }
            return editor
        }

        private func copySearchSelection(in editor: NSTextView) -> Bool {
            guard let value = canonicalSelection(in: editor) else { return false }
            writeToPasteboard(value)
            return true
        }

        private func cutSearchSelection(in editor: NSTextView) -> Bool {
            guard let value = canonicalSelection(in: editor) else { return false }
            let emptiesEditor = editor.selectedRange().length == editor.string.utf16.count
            editor.delete(nil)
            writeToPasteboard(value)
            if emptiesEditor {
                restoreSearchFocusAfterKeyboardClear()
            }
            return true
        }

        private func deletionWillEmptyEditor(_ editor: NSTextView, keyCode: UInt16) -> Bool {
            let selection = editor.selectedRange()
            let length = editor.string.utf16.count
            if selection.length == length { return true }
            guard selection.length == 0, length == 1 else { return false }
            return keyCode == 51 ? selection.location == 1 : selection.location == 0
        }

        private func restoreSearchFocusAfterKeyboardClear() {
            keyboardClearFocusRestorationPending = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(20))
                guard let self else { return }
                guard let searchField, let window else {
                    keyboardClearFocusRestorationPending = false
                    return
                }
                isSearchFocused.wrappedValue = true
                window.makeFirstResponder(searchField)
                installMainMenuPatches()
                try? await Task.sleep(for: .milliseconds(50))
                keyboardClearFocusRestorationPending = false
            }
        }

        private func pasteCanonicalSyntax(in editor: NSTextView) -> Bool {
            guard let value = NSPasteboard.general.string(forType: .string) else {
                return false
            }
            let parsed = pasteCanonicalSyntax(value)
            guard !parsed.tokens.isEmpty else { return false }
            var tokens = searchTokens.wrappedValue
            for token in parsed.tokens where !tokens.contains(token) {
                tokens.append(token)
            }
            editor.insertText(parsed.text, replacementRange: editor.selectedRange())
            let text = editor.string.replacingOccurrences(
                of: "\u{FFFC}",
                with: ""
            )
            // AppKit dispatches the field editor's native change notification
            // after insertText returns. Apply semantic state on the following
            // main-actor turn so that notification cannot overwrite the tokens
            // we just reconstructed from the canonical clipboard syntax.
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                searchText.wrappedValue = text
                searchTokens.wrappedValue = tokens
            }
            return true
        }

        private func installMainMenuPatches() {
            guard mainMenuPatches.isEmpty, let menu = NSApp.mainMenu else { return }
            patchMenu(menu, storingIn: &mainMenuPatches)
        }

        private func patchMenu(_ menu: NSMenu, storingIn patches: inout [MenuPatch]) {
            for item in menu.items {
                if let submenu = item.submenu {
                    patchMenu(submenu, storingIn: &patches)
                }
                let replacement: Selector? = switch item.action {
                case #selector(NSText.copy(_:)): #selector(copyMessageSearch(_:))
                case #selector(NSText.cut(_:)): #selector(cutMessageSearch(_:))
                case #selector(NSText.paste(_:)): #selector(pasteMessageSearch(_:))
                default: nil
                }
                guard let replacement else { continue }
                patches.append(MenuPatch(item: item, target: item.target, action: item.action))
                item.target = self
                item.action = replacement
            }
        }

        private func restoreMenuPatches(_ patches: inout [MenuPatch]) {
            for patch in patches where patch.item.target === self {
                patch.item.target = patch.target
                patch.item.action = patch.action
            }
            patches.removeAll()
        }

        private func forward(_ selector: Selector, sender: Any?) {
            _ = window?.firstResponder?.tryToPerform(selector, with: sender)
        }

        private func canonicalSelection(in editor: NSTextView) -> String? {
            MessageSearchClipboardSerialization.canonicalSelection(
                editorString: editor.string,
                selectedRange: editor.selectedRange(),
                tokens: searchTokens.wrappedValue
            )
        }

        private func writeToPasteboard(_ value: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }

    }
}
