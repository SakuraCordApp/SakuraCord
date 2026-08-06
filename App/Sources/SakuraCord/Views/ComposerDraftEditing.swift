import Foundation
import SakuraCordModels

nonisolated struct ComposerDraftEdit: Equatable {
    let text: String
    let selection: NSRange
}

nonisolated enum ComposerPlaceholderPolicy {
    static func text(
        channelName: String,
        channelKind: ChannelKindValue?,
        destination: MessageComposerDestination
    ) -> String {
        if destination == .channel,
           channelKind == .directMessage
            || channelKind == .groupDirectMessage
        {
            return "Message @\(channelName)"
        }
        return "Message #\(channelName)"
    }
}

nonisolated enum ComposerDraftEditing {
    static func insert(
        _ insertedText: String,
        into source: String,
        replacing selection: NSRange?
    ) -> ComposerDraftEdit {
        let resolved = resolvedRange(selection, in: source)
        var value = source
        let range = Range(resolved, in: value) ?? (value.endIndex ..< value.endIndex)
        value.replaceSubrange(range, with: insertedText)
        return ComposerDraftEdit(
            text: value,
            selection: NSRange(location: resolved.location + insertedText.utf16.count, length: 0)
        )
    }

    static func insertCustomEmoji(
        _ token: String,
        into source: String,
        replacing selection: NSRange?
    ) -> ComposerDraftEdit {
        insert(token, into: source, replacing: selection)
    }

    private static func resolvedRange(_ selection: NSRange?, in source: String) -> NSRange {
        let end = NSRange(location: source.utf16.count, length: 0)
        guard let selection,
              selection.location != NSNotFound,
              selection.location >= 0,
              selection.length >= 0,
              selection.location <= source.utf16.count,
              selection.length <= source.utf16.count - selection.location,
              Range(selection, in: source) != nil
        else { return end }
        return selection
    }
}
