import AppKit
import SwiftUI

/// AppKit text views retain first responder when a SwiftUI background is clicked.
/// Let the clicked control act first so editing accessories can retain focus.
struct ProfileEditorFocusDismissal: NSViewRepresentable {
    func makeNSView(context: Context) -> FocusView { FocusView() }
    func updateNSView(_ view: FocusView, context: Context) {}

    static func dismantleNSView(_ view: FocusView, coordinator: ()) { view.stopMonitoring() }

    final class FocusView: NSView {
        private var monitor: Any?
        private weak var textToBlur: NSTextView?
        private weak var textOwner: AnyObject?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addAppLocalMonitor(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                guard let self, WindowModalCoordinator.allowsInput(for: self) else { return event }
                if event.type == .leftMouseUp {
                    let text = self.textToBlur
                    let owner = self.textOwner
                    self.textToBlur = nil
                    DispatchQueue.main.async { [weak text] in
                        // The field editor is shared between text fields, so a click that moved
                        // editing to another field leaves the same view with a new delegate.
                        guard let text, WindowModalCoordinator.allowsInput(for: text), let window = text.window,
                              window.firstResponder === text, text.delegate === owner else { return }
                        window.makeFirstResponder(nil)
                    }
                    return event
                }
                self.textToBlur = nil
                guard let window = self.window, event.window === window,
                      let text = window.firstResponder as? NSTextView else { return event }
                let point = text.convert(event.locationInWindow, from: nil)
                guard !text.visibleRect.contains(point) else { return event }
                // A field editor can be inset inside its text field. Clicking that
                // field's padding must still position the caret, not finish editing.
                if let field = text.delegate as? NSTextField,
                   field.bounds.contains(field.convert(event.locationInWindow, from: nil)) { return event }
                self.textToBlur = text
                self.textOwner = text.delegate
                return event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            textToBlur = nil
        }
    }
}
