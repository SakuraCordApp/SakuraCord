import AppKit
import SwiftUI

nonisolated private final class ToolbarSearchFieldDelegateProxy: NSObject, NSSearchFieldDelegate {
    var forwardingDelegate: (any NSSearchFieldDelegate)?
    let didEndSearching: @MainActor (String) -> Void

    init(
        forwardingDelegate: (any NSSearchFieldDelegate)?,
        didEndSearching: @escaping @MainActor (String) -> Void
    ) {
        self.forwardingDelegate = forwardingDelegate
        self.didEndSearching = didEndSearching
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        forwardingDelegate?.searchFieldDidEndSearching?(sender)
        didEndSearching(sender.stringValue)
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

    var panelWidth: CGFloat {
        fieldWidth + trailingInset
    }

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
    let changed: @MainActor (ToolbarSearchFieldMetrics) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(searchText: $searchText, changed: changed)
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
        context.coordinator.changed = changed
        Task { @MainActor in
            context.coordinator.update(window: view.window, changed: changed)
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        var searchText: Binding<String>
        var changed: @MainActor (ToolbarSearchFieldMetrics) -> Void
        private weak var window: NSWindow?
        private weak var searchField: NSSearchField?
        private var observers: [NSObjectProtocol] = []
        private var searchFieldDelegateProxy: ToolbarSearchFieldDelegateProxy?
        private var retryTask: Task<Void, Never>?
        private var lastMetrics = ToolbarSearchFieldMetrics.zero

        init(
            searchText: Binding<String>,
            changed: @escaping @MainActor (ToolbarSearchFieldMetrics) -> Void
        ) {
            self.searchText = searchText
            self.changed = changed
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

        func detach() {
            retryTask?.cancel()
            retryTask = nil
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
            restoreSearchFieldDelegate()
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
        }

        private func observe(_ name: Notification.Name, object: AnyObject?) {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: object,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleMeasurement()
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
                  let contentView = window.contentView,
                  let searchField = toolbarSearchField(in: window),
                  searchField.window === window
            else { return false }

            if self.searchField !== searchField {
                restoreSearchFieldDelegate()
                self.searchField = searchField
                searchField.postsFrameChangedNotifications = true
                observe(NSView.frameDidChangeNotification, object: searchField)
                let proxy = ToolbarSearchFieldDelegateProxy(
                    forwardingDelegate: searchField.delegate
                ) { [weak self] value in
                    guard let self,
                          searchText.wrappedValue != value
                    else { return }
                    searchText.wrappedValue = value
                }
                searchFieldDelegateProxy = proxy
                searchField.delegate = proxy
            }

            let fieldRect = searchField.convert(searchField.bounds, to: nil)
            let contentRect = contentView.convert(contentView.bounds, to: nil)
            let metrics = ToolbarSearchFieldMetrics(
                fieldWidth: fieldRect.width,
                trailingInset: max(0, contentRect.maxX - fieldRect.maxX)
            )
            guard metrics.isValid else { return false }
            if metrics != lastMetrics {
                lastMetrics = metrics
                changed(metrics)
            }
            return true
        }

        private func restoreSearchFieldDelegate() {
            guard let proxy = searchFieldDelegateProxy else { return }
            if searchField?.delegate as AnyObject? === proxy {
                searchField?.delegate = proxy.forwardingDelegate
            }
            searchFieldDelegateProxy = nil
        }

        private func toolbarSearchField(in window: NSWindow) -> NSSearchField? {
            for item in window.toolbar?.items ?? [] {
                if let searchItem = item as? NSSearchToolbarItem {
                    return searchItem.searchField
                }
                if let view = item.view,
                   let searchField = firstSearchField(in: view)
                {
                    return searchField
                }
            }
            guard let frameView = window.contentView?.superview else { return nil }
            return firstSearchField(in: frameView)
        }

        private func firstSearchField(in view: NSView) -> NSSearchField? {
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
}
