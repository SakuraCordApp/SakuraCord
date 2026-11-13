import AppKit
import SwiftUI

/// Only the query is editable; selecting or replacing text never deletes chips.
struct SelectionFieldSearchInput: NSViewRepresentable {
    @Binding var query: String
    let placeholder: String
    let wantsFocus: Bool
    let searches: Bool
    let activate: () -> Void
    let move: (Int) -> Void
    let accept: () -> Void
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.font = .interfaceSystemFont(ofSize: ChatChromeMetrics.pickerSearchHeaderFontSize)
        field.focusRingType = .none
        field.isAutomaticTextCompletionEnabled = false
        field.allowsWritingTools = false
        field.allowsWritingToolsAffordance = false
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        let font = NSFont.interfaceSystemFont(ofSize: ChatChromeMetrics.pickerSearchHeaderFontSize)
        if field.font != font { field.font = font }
        field.isEditable = searches
        field.isSelectable = searches
        if field.stringValue != query { field.stringValue = query }
        if wantsFocus, !coordinator.requestedFocus {
            coordinator.requestedFocus = true
            Task { @MainActor [weak field, weak coordinator] in
                guard let field, coordinator?.parent.wantsFocus == true else { return }
                field.window?.makeFirstResponder(field)
                if let window = field.window, let coordinator {
                    coordinator.escapeRegistration = PopoverEscapeKeyCoordinator.shared.register(
                        popoverWindow: window, presentingWindow: nil
                    ) { [weak field, weak coordinator] in
                        if let editor = field?.currentEditor() as? NSTextView, editor.hasMarkedText() {
                            editor.unmarkText()
                        } else { coordinator?.parent.dismiss() }
                    }
                }
            }
        } else if !wantsFocus {
            coordinator.requestedFocus = false
            coordinator.escapeRegistration = nil
            if field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SelectionFieldSearchInput
        var requestedFocus = false
        var escapeRegistration: PopoverEscapeKeyRegistration?
        init(_ parent: SelectionFieldSearchInput) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.activate()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.query = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText(),
                  NSApp.currentEvent?.modifierFlags.isDisjoint(with: [.command, .control, .option]) != false else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.accept()
            case #selector(NSResponder.cancelOperation(_:)): parent.dismiss()
            default: return false
            }
            return true
        }
    }
}
