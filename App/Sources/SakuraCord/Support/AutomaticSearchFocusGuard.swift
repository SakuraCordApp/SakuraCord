import AppKit

/// Replacing the workspace while switching accounts can leave the toolbar
/// search field as the window's only text input, and macOS then focuses it,
/// opening its suggestions. Armed for a switch, the guard tells such focus
/// apart from the reader's own: theirs follows a click, key press or menu
/// command within the last second. The first focus the reader gives disarms it.
@MainActor
final class AutomaticSearchFocusGuard {
    private var monitor: Any?
    private var menuObserver: NSObjectProtocol?
    private var lastReaderInput: TimeInterval = -.infinity

    private(set) var isArmed = false

    /// Whether focus arriving now follows the reader's own input.
    var focusFollowsReaderInput: Bool {
        ProcessInfo.processInfo.systemUptime - lastReaderInput < 1
    }

    func arm() {
        isArmed = true
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                self?.lastReaderInput = event.timestamp
                return event
            }
        }
        if menuObserver == nil {
            // Menu tracking consumes its clicks before local monitors see them.
            menuObserver = NotificationCenter.default.addObserver(
                forName: NSMenu.didSendActionNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.lastReaderInput = ProcessInfo.processInfo.systemUptime }
            }
        }
    }

    isolated deinit {
        disarm()
    }

    func disarm() {
        isArmed = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) }
        menuObserver = nil
    }

    /// Returns focus from a window toolbar's search field to its window.
    func releaseToolbarSearchFieldFocus() {
        for window in NSApp.windows {
            guard let editor = window.firstResponder as? NSText,
                  let field = editor.delegate as? NSSearchField,
                  window.toolbar?.items.contains(where: { ($0 as? NSSearchToolbarItem)?.searchField === field }) == true
            else { continue }
            window.makeFirstResponder(nil)
        }
    }
}
