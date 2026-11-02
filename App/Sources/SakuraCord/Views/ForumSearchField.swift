import AppKit
import SwiftUI

/// The forum's search field, built as the message composer is: an AppKit
/// text field in interactive glass, focused from an AppKit surface behind it.
/// Clicking the board takes focus from it, as the board takes first responder.
struct ForumSearchField: View {
    @Binding var text: String
    @State private var input = ForumSearchInput.Handle()

    var body: some View {
        HStack(spacing: InterfaceScale.metric(6)) {
            Image(systemName: "magnifyingglass")
                .font(.interface(.body))
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
            ZStack(alignment: .leading) {
                ForumSearchInput(text: $text, handle: input)
                // SwiftUI draws the placeholder, as the composer's, so it
                // scales with the glass as it responds; AppKit redraws its
                // own placeholder at each step and it wiggles.
                if text.isEmpty {
                    Text("Search posts")
                        .font(.interface(.body))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, ForumTagChipMetrics.horizontalPadding)
        .frame(height: ForumTagChipMetrics.height)
        .background { ComposerFocusSurface(focus: input.focus) }
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

private struct ForumSearchInput: NSViewRepresentable {
    @Binding var text: String
    let handle: Handle

    /// Lets the surface behind the field focus it.
    @MainActor
    final class Handle {
        weak var field: NSTextField?

        func focus() {
            guard let field, field.currentEditor() == nil else { return }
            field.window?.makeFirstResponder(field)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.setAccessibilityPlaceholderValue("Search posts")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityIdentifier("forum-search")
        handle.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.fontScale != InterfaceScale.factor {
            coordinator.fontScale = InterfaceScale.factor
            field.font = .interfaceSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize)
        }
        // Only a change from outside the field rewrites it, such as clearing
        // or a channel switch; one made mid-composition ends the composition,
        // so its next edit cannot write the old query back.
        guard text != coordinator.reportedText else { return }
        (field.currentEditor() as? NSTextView)?.unmarkText()
        field.stringValue = text
        coordinator.reportedText = text
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ForumSearchInput
        /// The text this field last reported, to tell its own edits from others.
        var reportedText = ""
        /// The interface size the field's font was made for; each edit updates the view.
        var fontScale: CGFloat?

        init(_ parent: ForumSearchInput) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            reportedText = field.stringValue
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            ((notification.object as? NSTextField)?.currentEditor() as? NSTextView)?
                .applySakuraCordTextSelectionAppearance()
        }

        /// Escape clears the search and leaves the field, as the toolbar
        /// search field's Escape returns focus to the window.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText() else {
                return false
            }
            control.stringValue = ""
            reportedText = ""
            parent.text = ""
            control.window?.makeFirstResponder(nil)
            return true
        }
    }
}
