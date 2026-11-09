import AppKit
import SwiftUI

/// A forum post's title. Its editor reads pasted files and images as
/// attachments, as the body's text view does, so every way of pasting
/// (Command-V, Edit > Paste, a context menu) treats them alike.
struct ForumPostTitleField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let canReceiveAttachments: () -> Bool
    let receiveAttachments: (ComposerIncomingAttachments) -> Void
    /// Return and Tab move on to the body.
    let submit: () -> Void

    private static let maximumLineCount = 3

    private static var font: NSFont {
        .interfaceSystemFont(ofSize: 19, weight: .semibold)
    }

    private static var placeholder: NSAttributedString {
        NSAttributedString(
            string: String(localized: "Post title"),
            attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> TitleField {
        let field = TitleField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = false
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.maximumNumberOfLines = Self.maximumLineCount
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(String(localized: "Title"))
        field.delegate = context.coordinator
        field.editor.onFirstResponderChange = { [weak coordinator = context.coordinator] in
            coordinator?.firstResponderDidChange($0)
        }
        return field
    }

    func updateNSView(_ field: TitleField, context: Context) {
        context.coordinator.parent = self
        field.editor.canReceiveAttachments = canReceiveAttachments
        field.editor.receiveAttachments = receiveAttachments
        // Follows Interface Size and accent changes, as the body does.
        if field.font != Self.font {
            field.font = Self.font
            field.placeholderAttributedString = Self.placeholder
        }
        field.editor.applySakuraCordTextSelectionAppearance()
        // The editor owns text still being composed with an input method.
        if !field.editor.hasMarkedText(), field.stringValue != text { field.stringValue = text }
        context.coordinator.applyFocus(to: field)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: TitleField, context: Context) -> CGSize? {
        guard let width = proposal.width, let cell = field.cell?.copy() as? NSCell else { return nil }
        func height(of string: String) -> CGFloat {
            cell.stringValue = string
            return cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height
        }
        let lineCap = height(of: Array(repeating: "X", count: Self.maximumLineCount).joined(separator: "\n"))
        return CGSize(width: width, height: min(height(of: text.isEmpty ? "X" : text), lineCap))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ForumPostTitleField
        private var appliedFocus = false

        init(parent: ForumPostTitleField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                parent.submit()
                return true
            // A title stays on one line.
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
                return true
            default:
                return false
            }
        }

        func firstResponderDidChange(_ isFirstResponder: Bool) {
            // Publish after AppKit finishes the responder change, never during
            // a SwiftUI update that triggered it.
            Task { @MainActor [weak self] in
                guard let self else { return }
                appliedFocus = isFirstResponder
                if parent.isFocused != isFirstResponder { parent.isFocused = isFirstResponder }
            }
        }

        func applyFocus(to field: TitleField) {
            guard parent.isFocused != appliedFocus else { return }
            appliedFocus = parent.isFocused
            if parent.isFocused {
                Task { @MainActor [weak field] in
                    guard let field, parent.isFocused else { return }
                    field.window?.makeFirstResponder(field)
                }
            } else if field.window?.firstResponder === field.editor {
                field.window?.makeFirstResponder(nil)
            }
        }
    }

    final class TitleField: NSTextField {
        let editor: TitleEditor = {
            let editor = TitleEditor()
            editor.isFieldEditor = true
            editor.isRichText = false
            editor.allowsUndo = true
            return editor
        }()

        override static var cellClass: AnyClass? {
            get { TitleCell.self }
            set {}
        }
    }

    /// Hands the field its own editor rather than the window's shared one.
    final class TitleCell: NSTextFieldCell {
        override func fieldEditor(for controlView: NSView) -> NSTextView? {
            (controlView as? TitleField)?.editor
        }
    }

    final class TitleEditor: ComposerFocusReportingTextView {
        var canReceiveAttachments: (() -> Bool)?
        var receiveAttachments: ((ComposerIncomingAttachments) -> Void)?

        private var receivesAttachments: Bool {
            isEditable && receiveAttachments != nil && canReceiveAttachments?() != false
        }

        override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
            receivesAttachments
                ? ComposerPasteboardAttachments.readableTypes + super.readablePasteboardTypes
                : super.readablePasteboardTypes
        }

        override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
            guard ComposerPasteboardAttachments.readableTypes.contains(type) else {
                return super.readSelection(from: pasteboard, type: type)
            }
            // Declining lets AppKit read the next available type.
            guard receivesAttachments, let receiveAttachments,
                  let attachments = ComposerPasteboardAttachments.attachments(from: pasteboard, type: type)
            else { return false }
            receiveAttachments(attachments)
            return true
        }
    }
}
