import AppKit
import SwiftUI

/// Composer editors report real first-responder changes. AppKit's text
/// editing notifications only bracket edits, so clicking into or away from an
/// editor without typing would otherwise leave composer focus stale.
class ComposerFocusReportingTextView: NSTextView {
    var onFirstResponderChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFirstResponderChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFirstResponderChange?(false) }
        return resigned
    }
}

/// A coordinator that keeps its editor's first-responder status and SwiftUI
/// focus binding in step.
protocol ComposerFocusSyncing: AnyObject {
    var focusBinding: Binding<Bool> { get }
    /// The focus last applied to or reported by the editor.
    var appliedFocus: Bool { get set }
}

extension ComposerFocusSyncing {
    func firstResponderDidChange(_ isFirstResponder: Bool) {
        // Publish after AppKit finishes the responder change, never during
        // a SwiftUI update that triggered it.
        Task { @MainActor [weak self] in
            guard let self else { return }
            appliedFocus = isFirstResponder
            if focusBinding.wrappedValue != isFirstResponder { focusBinding.wrappedValue = isFirstResponder }
        }
    }

    /// Makes `view` first responder when focus turns on and, when focus
    /// turns off while `responder` holds it, clears first responder. An
    /// editor without a `responder` never resigns.
    func applyFocus(to view: NSView, resigning responder: NSResponder?) {
        guard focusBinding.wrappedValue != appliedFocus else { return }
        appliedFocus = focusBinding.wrappedValue
        if focusBinding.wrappedValue {
            Task { @MainActor [weak view] in
                guard let view, focusBinding.wrappedValue else { return }
                view.window?.makeFirstResponder(view)
            }
        } else if let responder, view.window?.firstResponder === responder {
            view.window?.makeFirstResponder(nil)
        }
    }
}
