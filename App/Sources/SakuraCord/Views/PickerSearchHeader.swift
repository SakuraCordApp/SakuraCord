import AppKit
import SwiftUI

/// Shared search chrome for floating pickers; the caller owns text editing and keyboard behavior.
struct PickerSearchHeader<Input: View>: View {
    @Binding var text: String
    let focus: () -> Void
    @ViewBuilder let input: () -> Input

    var body: some View {
        HStack(spacing: ChatChromeMetrics.pickerSearchHeaderSpacing) {
            Image(systemName: "magnifyingglass")
                .font(.interfaceSystem(size: ChatChromeMetrics.pickerSearchHeaderIconSize, weight: .medium))
                .foregroundStyle(.secondary)
            input().frame(maxWidth: .infinity)
            Button {
                text = ""
                focus()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear search")
            .accessibilityLabel("Clear search")
            .opacity(text.isEmpty ? 0 : 1)
            .disabled(text.isEmpty)
            .accessibilityHidden(text.isEmpty)
        }
        .padding(.horizontal, ChatChromeMetrics.pickerSearchHeaderInset)
        .frame(height: ChatChromeMetrics.pickerSearchHeaderHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: focus)
        .accessibilityIdentifier("picker-search")
    }
}

struct EmojiPickerSearchField: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String

    var body: some View {
        PickerSearchHeader(text: $text, focus: { isFocused = true }, input: {
            PickerSearchTextField(
                text: $text,
                isFocused: $isFocused,
                placeholder: placeholder
            )
        })
        .task {
            await Task.yield()
            isFocused = true
        }
    }
}

private struct PickerSearchTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    func makeNSView(context: Context) -> PickerSearchNSTextField {
        let textField = PickerSearchNSTextField()
        textField.delegate = context.coordinator
        textField.placeholderString = placeholder
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .interfaceSystemFont(ofSize: ChatChromeMetrics.pickerSearchHeaderFontSize)
        textField.textColor = .labelColor
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.usesSingleLineMode = true
        textField.isAutomaticTextCompletionEnabled = false
        textField.contentType = NSTextContentType(rawValue: "dev.sakuracord.emoji-search")
        textField.allowsWritingTools = false
        textField.allowsWritingToolsAffordance = false
        textField.setAccessibilityLabel(placeholder)
        return textField
    }

    func updateNSView(_ textField: PickerSearchNSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isFocused = $isFocused
        let font = NSFont.interfaceSystemFont(ofSize: ChatChromeMetrics.pickerSearchHeaderFontSize)
        if textField.font != font { textField.font = font }
        if textField.stringValue != text {
            textField.stringValue = text
        }

        if isFocused {
            textField.requestFirstResponderWhenReady()
            Self.disableCompletionFeatures(in: textField.currentEditor() as? NSTextView)
        } else if textField.window?.firstResponder === textField.currentEditor() {
            textField.window?.makeFirstResponder(nil)
        }
    }

    private static func disableCompletionFeatures(in editor: NSTextView?) {
        guard let editor else { return }
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            isFocused.wrappedValue = true
            Self.configureEditor(from: notification)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text.wrappedValue = textField.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            isFocused.wrappedValue = false
        }

        private static func configureEditor(from notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            let editor = textField.currentEditor() as? NSTextView
            PickerSearchTextField.disableCompletionFeatures(in: editor)
        }
    }
}

private final class PickerSearchNSTextField: NSTextField {
    private var focusRequestIsScheduled = false
    private var didAutofocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            didAutofocus = false
            focusRequestIsScheduled = false
            return
        }
        guard !didAutofocus else { return }
        requestFirstResponderWhenReady()
    }

    func requestFirstResponderWhenReady() {
        guard let window, !focusRequestIsScheduled else { return }
        if window.firstResponder === currentEditor() {
            didAutofocus = true
            return
        }
        focusRequestIsScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            for delay in [0, 80, 140, 220] {
                if delay > 0 {
                    try? await Task.sleep(for: .milliseconds(delay))
                }
                guard let window = self.window else { break }
                window.makeKey()
                _ = window.makeFirstResponder(self)
                await Task.yield()
                if window.firstResponder === currentEditor() {
                    didAutofocus = true
                    break
                }
            }
            focusRequestIsScheduled = false
        }
    }
}
