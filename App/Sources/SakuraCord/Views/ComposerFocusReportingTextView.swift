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

/// A composer editor that takes pasted files when its destination accepts
/// them. AppKit validates Paste and Services against
/// `readablePasteboardTypes`, then reads the first available type through
/// `readSelection(from:type:)`. Destinations that cannot take files omit the
/// attachment types, so the clipboard's text representation is pasted
/// instead.
class ComposerAttachmentPasteTextView: ComposerFocusReportingTextView {
    var onReceiveAttachments: ((_ attachments: ComposerIncomingAttachments, _ isInstant: Bool) -> Bool)?
    var canReceiveAttachments: (() -> Bool)?

    var receivesAttachments: Bool {
        isEditable && onReceiveAttachments != nil && canReceiveAttachments?() != false
    }

    /// The text types the editor pastes when no attachment type is read.
    var textPasteboardTypes: [NSPasteboard.PasteboardType] { super.readablePasteboardTypes }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        receivesAttachments
            ? ComposerPasteboardAttachments.readableTypes + textPasteboardTypes
            : textPasteboardTypes
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard ComposerPasteboardAttachments.readableTypes.contains(type) else {
            return readTextSelection(from: pasteboard, type: type)
        }
        // Declining lets AppKit read the next available type.
        guard receivesAttachments, let onReceiveAttachments,
              let attachments = ComposerPasteboardAttachments.attachments(from: pasteboard, type: type)
        else { return false }
        return onReceiveAttachments(attachments, false)
    }

    func readTextSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        super.readSelection(from: pasteboard, type: type)
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
