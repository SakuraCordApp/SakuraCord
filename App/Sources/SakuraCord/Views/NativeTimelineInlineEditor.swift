import AppKit
import CoreText
import MessageRendering
import SakuraCordModels
import SwiftUI

/// The text of a message being edited inline, shared by its editor and
/// its Cancel and Save controls.
@Observable
final class NativeTimelineInlineEditDraft {
    var text: String
    /// Saved, and waiting for the timeline to show it.
    var isSaving = false
    /// Emoji suggestions open below the editor when there is no room above.
    var showsSuggestionsBelow = false

    init(text: String) {
        self.text = text
    }
}

/// Edits a message's text where the timeline draws it, in the same type,
/// without a field around it; the timeline keeps drawing the rest of the row.
struct NativeTimelineEditingMessageContent: View {
    let model: AppModel
    let message: Message
    @Bindable var draft: NativeTimelineInlineEditDraft
    /// An outgoing bubble's accent fill, which takes white text and caret.
    let isOnOutgoingBubble: Bool
    let save: (String) -> Void
    let cancel: () -> Void
    let editorHeightDidChange: (CGFloat) -> Void
    let draftDidChange: () -> Void

    var body: some View {
        InlineMessageEditor(
            model: model,
            message: message,
            text: $draft.text,
            canEdit: model.guildTimeoutUntil(in: message.channelID, guildID: message.guildID) == nil,
            save: {
                guard model.guildTimeoutUntil(in: message.channelID, guildID: message.guildID) == nil,
                      let value = MessageEditInputPolicy.submission(from: draft.text)
                else { return }
                save(value)
            },
            cancel: cancel,
            isOnOutgoingBubble: isOnOutgoingBubble,
            suggestionsBelow: draft.showsSuggestionsBelow,
            editorHeightDidChange: editorHeightDidChange
        )
        .disabled(draft.isSaving)
        .onChange(of: draft.text) { draftDidChange() }
    }
}

/// Cancel and Save for an inline edit, in the place of the row's hover actions.
struct NativeTimelineInlineEditControls: View {
    let draft: NativeTimelineInlineEditDraft
    let canEdit: () -> Bool
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        HoverActionPill {
            InlineEditTextButton(title: "Cancel", key: "esc", action: cancel)
                .keyboardShortcut(.cancelAction)
                .accessibilityHint("Discards your changes. Keyboard shortcut: Escape.")
            let canSave = canEdit() && MessageEditInputPolicy.submission(from: draft.text) != nil
            InlineEditTextButton(title: "Save", key: "↵", action: save)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint(
                    canSave
                        ? "Saves your edited message. Keyboard shortcut: Return."
                        : "Enter message text before saving."
                )
                .disabled(!canSave)
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Edit message")
    }
}

struct InlineMessageEditorComposerActions {
    let onSubmit: () -> Void
    let onEscape: () -> Void
}

private struct InlineMessageEditor: View {
    let model: AppModel
    /// The message being edited, whose mentioned users resolve its mentions.
    let message: Message
    @Binding var text: String
    let canEdit: Bool
    let save: () -> Void
    let cancel: () -> Void
    let isOnOutgoingBubble: Bool
    let suggestionsBelow: Bool
    let editorHeightDidChange: (CGFloat) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: NSRange?
    @State private var isFocused = true
    @State private var autocompleteIndex = 0
    @State private var isAutocompleteDismissed = false
    @State private var timeQueryDate = Date.now
    @State private var timeQueryNeedsPick = false
    @State private var timeKeyboardSelectionRevision = 0
    @State private var timestampClock = RelativeTimestampDisplayClock()
    @State private var emojiSuggestionCache = ColonAutocompleteSuggestionCache()

    /// Game names and people resolve as they do in the message, and update
    /// as games load.
    private var mentionPresentations: [String: MentionPresentation] {
        _ = model.timelinePresentationRevision
        // The message as it is now: an update while editing can bring newer
        // details for the people it mentions.
        let current = model.retainedMessage(channelID: message.channelID, messageID: message.id) ?? message
        let values = MessageMentionResolver(model: model, message: current).presentations(in: text)
        return text.contains(":R>") ? TimestampMentionPresentation.refreshed(values, source: text, at: timestampClock.date) : values
    }

    private var composerActions: InlineMessageEditorComposerActions {
        InlineMessageEditorComposerActions(
            onSubmit: save,
            onEscape: cancel
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(4)) {
            if !suggestionsBelow { suggestionList }
            ComposerTextView(
                text: text,
                placeholder: "Edit message",
                sendWithReturn: MessageEditInputPolicy.sendsWithReturn,
                generalInputSettings: model.generalInputSettings,
                mentionPresentations: mentionPresentations,
                onTextChange: { text = $0 },
                onSubmit: composerActions.onSubmit,
                onEscape: composerActions.onEscape,
                onAutocompleteCommand: handleAutocomplete,
                capturesUnfocusedTyping: true,
                maximumHeight: .greatestFiniteMagnitude,
                insertionPointColor: isOnOutgoingBubble ? .sakuraCordLabelOnAccentColor : nil,
                textStyle: MessageEditLayoutMetrics.textStyle(isOnOutgoingBubble: isOnOutgoingBubble),
                scrolls: false,
                accessibilityHint: "Press Return to save, Shift-Return for a new line, or Escape to cancel.",
                selection: $selection,
                isFocused: $isFocused
            )
                // The timeline sets an outgoing bubble's text in white.
                .environment(\.colorScheme, isOnOutgoingBubble ? .dark : colorScheme)
                .disabled(!canEdit)
                .onGeometryChange(for: CGFloat.self, of: \.size.height, action: editorHeightDidChange)
                .onExitCommand(perform: cancel)
            if suggestionsBelow { suggestionList }
        }
        .onChange(of: text) { _, _ in
            isAutocompleteDismissed = false
            timeQueryNeedsPick = false
            autocompleteIndex = 0
        }
        .onChange(of: timeContext?.query) { timeQueryDate = .now }
        // A relative time counts on while it is edited, as in the composer.
        .onChange(of: text.contains(":R>"), initial: true) { _, counts in
            counts ? timestampClock.start() : timestampClock.stop()
        }
        .onDisappear { timestampClock.stop() }
        .onChange(of: selection) { _, _ in
            isAutocompleteDismissed = false
            autocompleteIndex = 0
        }
    }

    @ViewBuilder
    private var suggestionList: some View {
        if let timeContext, case let rows = timeRows, timeQueryNeedsPick || !rows.isEmpty {
            ComposerTimeFormatPicker(
                query: timeContext.query,
                rows: rows,
                needsPick: timeQueryNeedsPick,
                selectedIndex: autocompleteIndex,
                cornerRadius: ChatChromeMetrics.composerCornerRadius,
                keyboardSelectionRevision: timeKeyboardSelectionRevision,
                select: { insertTimestamp($0.token, context: timeContext) },
                highlight: { autocompleteIndex = $0 }
            )
        } else if let context, !suggestions.isEmpty {
            EmojiAutocompleteList(
                suggestions: suggestions,
                selectedIndex: autocompleteIndex,
                highlight: { autocompleteIndex = $0 },
                select: { accept($0, context: context) }
            )
        }
    }

    private var context: ColonAutocompleteContext? {
        !canEdit || isAutocompleteDismissed ? nil : ColonAutocompleteContext(text: text, selection: selection)
    }

    private var suggestions: [ColonAutocompleteSuggestion] {
        guard let context else { return [] }
        return emojiSuggestionCache.suggestions(query: context.query, model: model)
    }

    private var timeContext: KeywordMentionContext? {
        !canEdit || isAutocompleteDismissed || context != nil ? nil : KeywordMentionContext(.time, text: text, selection: selection)
    }

    private var timeRows: [ComposerTimeFormatPicker.Row] {
        timeContext.map {
            ComposerTimeFormatPicker.rows(for: $0.query, now: timeQueryDate)
        } ?? []
    }

    /// Keys while times match what is typed after `@time `, as in the composer.
    private func handleTimeAutocomplete(_ command: ComposerAutocompleteCommand, context: KeywordMentionContext) -> Bool {
        let rows = timeRows
        if command == .previous || command == .next { timeKeyboardSelectionRevision &+= 1 }
        switch command {
        case .previous where !rows.isEmpty:
            autocompleteIndex = (autocompleteIndex - 1 + rows.count) % rows.count
        case .next where !rows.isEmpty:
            autocompleteIndex = (autocompleteIndex + 1) % rows.count
        case .accept, .advance:
            guard !rows.isEmpty else {
                timeQueryNeedsPick = true
                return true
            }
            insertTimestamp(rows[min(autocompleteIndex, rows.count - 1)].token, context: context)
        case .dismiss: isAutocompleteDismissed = true
        default: return false
        }
        return true
    }

    private func insertTimestamp(_ token: DiscordTimestampToken, context: KeywordMentionContext) {
        let replacement = token.rawToken + " "
        text = (text as NSString).replacingCharacters(in: context.range, with: replacement)
        selection = NSRange(location: context.range.location + replacement.utf16.count, length: 0)
    }

    private func handleAutocomplete(_ command: ComposerAutocompleteCommand) -> Bool {
        if let timeContext { return handleTimeAutocomplete(command, context: timeContext) }
        let suggestions = self.suggestions
        guard let context, !suggestions.isEmpty else { return false }
        return command.route(&autocompleteIndex, count: suggestions.count) {
            accept(suggestions[$0], context: context)
        } dismiss: {
            isAutocompleteDismissed = true
        }
    }

    private func accept(_ suggestion: ColonAutocompleteSuggestion, context: ColonAutocompleteContext) {
        let value = text as NSString
        text = value.replacingCharacters(in: context.range, with: suggestion.value)
        selection = NSRange(
            location: context.range.location + suggestion.value.utf16.count, length: 0
        )
        isAutocompleteDismissed = true
    }
}

/// A text action drawn as the row's hover actions are.
private struct InlineEditTextButton: View {
    let title: LocalizedStringKey
    let key: LocalizedStringKey
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HoverActionControlLabel {
                HStack(spacing: InterfaceScale.metric(4)) {
                    Text(title)
                        .font(.interface(.caption).weight(.semibold))
                    Text(key)
                        .font(.interface(.caption2).monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, MessageEditLayoutMetrics.keycapHorizontalPadding)
                        .padding(.vertical, MessageEditLayoutMetrics.keycapVerticalPadding)
                        .background(.quaternary, in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(4), style: .continuous))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, MessageEditLayoutMetrics.actionHorizontalPadding)
            }
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
    }
}
