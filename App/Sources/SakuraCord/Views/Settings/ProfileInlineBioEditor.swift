import AppKit
import SwiftUI

/// The editor shows the bio's source with its emoji in one native text view.
/// Only focus and the floating accessories change when editing starts.
struct ProfileInlineBioEditor: View {
    @Binding var value: String
    let displayValue: String?
    let model: AppModel
    @State private var interaction = ProfileBioTextInteraction()
    @State private var originalValue = ""
    @State private var isEditing = false
    @State private var hasTyped = false
    @State private var showsEmojiPicker = false
    @State private var isEmojiPickerActive = false
    @State private var pickedEmoji: String?

    var body: some View {
        ProfileRichTextView(source: visibleValue, editing: ProfileBioTextEditing(
            interaction: interaction, isActive: isEditing,
            onChange: { hasTyped = true; value = $0 },
            onBegin: {
                guard !isEditing else { return }
                originalValue = value
                hasTyped = false
                isEditing = true
            },
            onEnd: {
                guard isEditing, !isEmojiPickerActive else { return }
                if hasTyped { value = value.trimmingCharacters(in: .whitespacesAndNewlines) }
                isEditing = false
            },
            onCancel: {
                value = originalValue
                isEditing = false
                interaction.blur()
            }
        ))
        .profileEditorTextHover(isEditing: isEditing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            if visibleValue.isEmpty {
                Text("Add a bio", bundle: #bundle).font(.interfaceSystem(size: 14)).foregroundStyle(.secondary)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isEditing { accessories.offset(y: InterfaceScale.metric(22)) }
        }
    }

    private var visibleValue: String { isEditing && hasTyped ? value : displayValue ?? value }

    private var accessories: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            Button("Add Emoji", systemImage: "face.smiling") {
                interaction.captureSelection()
                pickedEmoji = nil
                isEmojiPickerActive = true
                showsEmojiPicker = true
            }
            .buttonStyle(.plain).labelStyle(.iconOnly)
            .windowModal(isPresented: $showsEmojiPicker, title: "Emoji") {
                EmojiPickerView(model: model, useCase: .profile, dismiss: { showsEmojiPicker = false }, select: { activation in
                    switch activation.selection {
                    case let .native(emoji): pickedEmoji = emoji
                    case let .custom(emoji): pickedEmoji = emoji.messageToken
                    }
                    showsEmojiPicker = false
                })
                .onDisappear {
                    isEmojiPickerActive = false
                    interaction.resume(inserting: pickedEmoji)
                    pickedEmoji = nil
                }
            }
            Text("\(visibleValue.utf16.count)/300")
                .font(.interface(.caption2).monospacedDigit())
                .foregroundStyle(visibleValue.utf16.count > 300 ? .red : .secondary)
        }
        .padding(.horizontal, InterfaceScale.metric(6)).padding(.vertical, InterfaceScale.metric(3))
        .glassEffect(.regular, in: .capsule)
    }
}

struct ProfileBioTextEditing {
    let interaction: ProfileBioTextInteraction
    let isActive: Bool
    let onChange: (String) -> Void
    let onBegin: () -> Void
    let onEnd: () -> Void
    let onCancel: () -> Void
}

@MainActor
final class ProfileBioTextInteraction {
    weak var textView: NSTextView?
    private var selection = NSRange(location: 0, length: 0)

    func captureSelection() { selection = textView?.selectedRange() ?? selection }

    func resume(inserting emoji: String?) {
        guard let textView, let window = textView.window else { return }
        window.makeFirstResponder(textView)
        let length = textView.string.utf16.count
        let location = min(selection.location, length)
        let range = NSRange(location: location, length: min(selection.length, length - location))
        textView.setSelectedRange(range)
        if let emoji {
            let attributed = ProfileInlineAttributedText.make(
                source: emoji, font: .interfaceSystemFont(ofSize: 14), color: .labelColor,
                emojiImages: [:], stylesLinks: false
            )
            textView.insertText(attributed, replacementRange: range)
        }
    }

    func blur() { textView?.window?.makeFirstResponder(nil) }
}
