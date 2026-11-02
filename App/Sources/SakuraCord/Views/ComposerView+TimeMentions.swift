import MessageRendering
import SakuraCordModels
import SwiftUI

enum TimeMentionCoordinator {
    struct ReplacementResult {
        let text: String
        let selection: NSRange
    }

    static func context(
        entry: TimeMentionEntry?,
        text: String,
        selection: NSRange?,
        isDismissed: Bool
    ) -> TimeMentionContext? {
        if let entry {
            return TimeMentionContext(
                range: NSRange(location: entry.prefix.utf16.count, length: 0),
                query: entry.query.trimmingCharacters(in: .whitespacesAndNewlines),
                rawQuery: entry.query
            )
        }
        guard !isDismissed else { return nil }
        return TimeMentionContext(text: text, selection: selection)
    }

    static func candidates(
        for context: TimeMentionContext?,
        referenceDate: Date?
    ) -> [DiscordParsedTimeCandidate] {
        guard let context else { return [] }
        let reference = referenceDate ?? .now
        let parsed = DiscordNaturalLanguageTimeParser.candidates(
            for: context.query,
            referenceDate: reference,
            now: reference
        )
        if parsed.isEmpty {
            return DiscordNaturalLanguageTimeParser.candidates(
                for: "",
                referenceDate: reference,
                now: reference
            )
        }
        return parsed
    }

    static func allOptions(
        for candidates: [DiscordParsedTimeCandidate]
    ) -> [DiscordParsedTimeCandidate.Option] {
        candidates.flatMap(\.options)
    }

    static func handleAutocomplete(
        _ command: ComposerAutocompleteCommand,
        options: [DiscordParsedTimeCandidate.Option],
        currentIndex: inout Int,
        keyboardRevision: inout Int,
        onAccept: (DiscordParsedTimeCandidate.Option) -> Void,
        onDismiss: () -> Void
    ) -> Bool {
        guard !options.isEmpty else { return false }
        if command == .previous || command == .next {
            keyboardRevision &+= 1
        }
        switch command {
        case .previous:
            currentIndex = (currentIndex - 1 + options.count) % options.count
            return true
        case .next:
            currentIndex = (currentIndex + 1) % options.count
            return true
        case .accept, .advance:
            onAccept(options[min(currentIndex, options.count - 1)])
            return true
        case .dismiss:
            onDismiss()
            return true
        default:
            return false
        }
    }

    static func accept(
        option: DiscordParsedTimeCandidate.Option,
        entry: TimeMentionEntry?,
        context: TimeMentionContext?,
        currentText: String
    ) -> ReplacementResult {
        if let entry {
            let inserted = "\(entry.prefix)\(option.markdownToken) \(entry.suffix)"
            let cursor = (entry.prefix + option.markdownToken + " ").utf16.count
            return ReplacementResult(text: inserted, selection: NSRange(location: cursor, length: 0))
        } else if let context {
            let nsText = currentText as NSString
            let replacement = option.markdownToken + " "
            let inserted = nsText.replacingCharacters(in: context.range, with: replacement)
            let cursor = context.range.location + replacement.utf16.count
            return ReplacementResult(text: inserted, selection: NSRange(location: cursor, length: 0))
        } else {
            return ReplacementResult(text: currentText, selection: NSRange(location: currentText.utf16.count, length: 0))
        }
    }

    static func acceptActiveEntry(
        entry: TimeMentionEntry,
        selectedOption: DiscordParsedTimeCandidate.Option?
    ) -> ReplacementResult {
        if let selectedOption {
            let inserted = "\(entry.prefix)\(selectedOption.markdownToken) \(entry.suffix)"
            let cursor = (entry.prefix + selectedOption.markdownToken + " ").utf16.count
            return ReplacementResult(text: inserted, selection: NSRange(location: cursor, length: 0))
        } else {
            let text = entry.prefix + "@time " + entry.query + entry.suffix
            return ReplacementResult(text: text, selection: NSRange(location: text.utf16.count, length: 0))
        }
    }

    static func cancelActiveEntry(entry: TimeMentionEntry) -> ReplacementResult {
        let restored = entry.prefix + entry.suffix
        return ReplacementResult(text: restored, selection: NSRange(location: entry.prefix.utf16.count, length: 0))
    }

    static func restoredDraftText(for entry: TimeMentionEntry) -> String {
        let raw = entry.query.isEmpty ? "@time " : "@time \(entry.query)"
        return "\(entry.prefix)\(raw)\(entry.suffix)"
    }

    static func mentionHeading(
        for context: MentionAutocompleteContext,
        suggestions: [MentionAutocompleteSuggestion]
    ) -> String {
        switch context.kind {
        case .channel:
            return "TEXT CHANNELS"
        case .member:
            if suggestions.allSatisfy({ $0.id == "special:time" }) {
                return "SPECIAL MENTIONS"
            }
            if suggestions.first?.id == "special:time" {
                return "MATCHING @\(context.query.uppercased())"
            }
            return MentionAutocompleteSuggestionFactory.memberHeading(query: context.query)
        }
    }
}

extension ComposerView {
    var timeMentionContext: TimeMentionContext? {
        TimeMentionCoordinator.context(
            entry: activeTimeEntry,
            text: draft,
            selection: draftSelection,
            isDismissed: isAutocompleteDismissed
        )
    }

    var timeCandidates: [DiscordParsedTimeCandidate] {
        TimeMentionCoordinator.candidates(
            for: timeMentionContext,
            referenceDate: timeReferenceDate
        )
    }

    var allTimeOptions: [DiscordParsedTimeCandidate.Option] {
        TimeMentionCoordinator.allOptions(for: timeCandidates)
    }

    func handleTimeAutocomplete(
        _ command: ComposerAutocompleteCommand,
        context: TimeMentionContext
    ) -> Bool {
        TimeMentionCoordinator.handleAutocomplete(
            command,
            options: allTimeOptions,
            currentIndex: &autocompleteIndex,
            keyboardRevision: &autocompleteKeyboardSelectionRevision,
            onAccept: { acceptTimeFormat($0, context: context) },
            onDismiss: {
                if activeTimeEntry != nil {
                    cancelTimeEntry()
                } else {
                    isAutocompleteDismissed = true
                }
            }
        )
    }

    func acceptActiveTimeEntry() {
        guard let entry = activeTimeEntry else { return }
        let option = allTimeOptions.indices.contains(autocompleteIndex)
            ? allTimeOptions[autocompleteIndex]
            : allTimeOptions.first
        let result = TimeMentionCoordinator.acceptActiveEntry(
            entry: entry,
            selectedOption: option
        )
        activeTimeEntry = nil
        autocompleteIndex = 0
        isAutocompleteDismissed = true
        updateDraft(result.text)
        restoreComposerFocus(selection: result.selection)
    }

    func acceptTimeFormat(
        _ option: DiscordParsedTimeCandidate.Option,
        context: TimeMentionContext? = nil
    ) {
        let result = TimeMentionCoordinator.accept(
            option: option,
            entry: activeTimeEntry,
            context: context,
            currentText: draft
        )
        activeTimeEntry = nil
        autocompleteIndex = 0
        isAutocompleteDismissed = true
        updateDraft(result.text)
        restoreComposerFocus(selection: result.selection)
    }

    func cancelTimeEntry() {
        guard let entry = activeTimeEntry else { return }
        let result = TimeMentionCoordinator.cancelActiveEntry(entry: entry)
        activeTimeEntry = nil
        autocompleteIndex = 0
        isAutocompleteDismissed = true
        updateDraft(result.text)
        restoreComposerFocus(selection: result.selection)
    }

    func mentionHeading(
        for context: MentionAutocompleteContext,
        suggestions: [MentionAutocompleteSuggestion]
    ) -> String {
        TimeMentionCoordinator.mentionHeading(for: context, suggestions: suggestions)
    }
}
