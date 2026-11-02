import MessageRendering
import SakuraCordModels
import SwiftUI

extension ComposerView {
    var timeMentionContext: TimeMentionContext? {
        if let entry = activeTimeEntry {
            return TimeMentionContext(
                range: NSRange(location: entry.prefix.utf16.count, length: 0),
                query: entry.query.trimmingCharacters(in: .whitespacesAndNewlines),
                rawQuery: entry.query
            )
        }
        guard !isAutocompleteDismissed else { return nil }
        return TimeMentionContext(text: draft, selection: draftSelection)
    }

    var timeCandidates: [DiscordParsedTimeCandidate] {
        guard let context = timeMentionContext else { return [] }
        let reference = timeReferenceDate ?? .now
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

    var allTimeOptions: [DiscordParsedTimeCandidate.Option] {
        timeCandidates.flatMap(\.options)
    }

    func handleTimeAutocomplete(
        _ command: ComposerAutocompleteCommand,
        context: TimeMentionContext
    ) -> Bool {
        let options = allTimeOptions
        guard !options.isEmpty else { return false }
        if command == .previous || command == .next { autocompleteKeyboardSelectionRevision &+= 1 }
        switch command {
        case .previous:
            autocompleteIndex = (autocompleteIndex - 1 + options.count) % options.count
            return true
        case .next:
            autocompleteIndex = (autocompleteIndex + 1) % options.count
            return true
        case .accept, .advance:
            acceptTimeFormat(
                options[min(autocompleteIndex, options.count - 1)],
                context: context
            )
            return true
        case .dismiss:
            if activeTimeEntry != nil {
                cancelTimeEntry()
            } else {
                isAutocompleteDismissed = true
            }
            return true
        default:
            return false
        }
    }

    func acceptActiveTimeEntry() {
        let options = allTimeOptions
        if !options.isEmpty {
            let option = options[min(autocompleteIndex, options.count - 1)]
            acceptTimeFormat(option)
        } else if let entry = activeTimeEntry {
            let text = entry.prefix + "@time " + entry.query + entry.suffix
            activeTimeEntry = nil
            updateDraft(text)
            restoreComposerFocus(selection: NSRange(location: text.utf16.count, length: 0))
        }
    }

    func acceptTimeFormat(
        _ option: DiscordParsedTimeCandidate.Option,
        context: TimeMentionContext? = nil
    ) {
        if let entry = activeTimeEntry {
            let inserted = "\(entry.prefix)\(option.markdownToken) \(entry.suffix)"
            activeTimeEntry = nil
            autocompleteIndex = 0
            isAutocompleteDismissed = true
            updateDraft(inserted)
            let newCursor = (entry.prefix + option.markdownToken + " ").utf16.count
            restoreComposerFocus(selection: NSRange(location: newCursor, length: 0))
        } else if let context {
            draftSelection = insertInDraft(option.markdownToken + " ", replacing: context.range)
            autocompleteIndex = 0
            isAutocompleteDismissed = true
        }
    }

    func cancelTimeEntry() {
        guard let entry = activeTimeEntry else { return }
        let restored = entry.prefix + entry.suffix
        activeTimeEntry = nil
        autocompleteIndex = 0
        isAutocompleteDismissed = true
        updateDraft(restored)
        let newCursor = entry.prefix.utf16.count
        restoreComposerFocus(selection: NSRange(location: newCursor, length: 0))
    }

    func cancelTimeMention(context: TimeMentionContext) {
        if activeTimeEntry != nil {
            cancelTimeEntry()
        } else {
            draftSelection = insertInDraft("", replacing: context.range)
            autocompleteIndex = 0
            isAutocompleteDismissed = true
        }
    }

    func mentionHeading(
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
