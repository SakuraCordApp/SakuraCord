import Foundation

/// Discord's names for Unicode emoji, from its client's emoji table.
public enum DiscordEmojiNames {
    private struct Table: Decodable {
        /// Each emoji's unique name, skin-toned variants included, with the
        /// emoji and the unique name of its base emoji.
        var entries: [String: [String]]
        /// The emoji for every other name `:name:` accepts: aliases such as
        /// `+1`, and skin tones written as `thumbsup::skin-tone-1`.
        var aliases: [String: String]
    }

    private static let table: Table = {
        guard let url = Bundle.module.url(forResource: "discord-emoji-names", withExtension: "json"),
              let data = try? Data(contentsOf: url), let table = try? JSONDecoder().decode(Table.self, from: data)
        else { return Table(entries: [:], aliases: [:]) }
        return table
    }()

    /// Each emoji's unique name, with the emoji and its base emoji's unique name.
    public static var entries: [String: [String]] { table.entries }

    /// The `:name:` at `start` that Discord's emoji rule,
    /// `/^:([^\s:]+?(?:::skin-tone-\d)?):/`, turns into an emoji, and where
    /// it ends. An unknown name stays text.
    static func shortcode(in source: Substring, at start: String.Index) -> (text: String, end: String.Index)? {
        guard source[start] == ":" else { return nil }
        let nameStart = source.index(after: start)
        guard let nameEnd = source[nameStart...].firstIndex(where: { $0 == ":" || $0.isWhitespace }),
              nameEnd > nameStart, source[nameEnd] == ":"
        else { return nil }
        var name = source[nameStart ..< nameEnd]
        // A skin tone continues the name, as in `thumbsup::skin-tone-1`.
        let toneMarker = "::skin-tone-"
        if source[nameEnd...].hasPrefix(toneMarker) {
            let digit = source.index(nameEnd, offsetBy: toneMarker.count)
            if digit < source.endIndex, source[digit].isASCII, source[digit].isNumber,
               source[source.index(after: digit)...].first == ":" {
                name = source[nameStart ... digit]
            }
        }
        let key = String(name)
        guard let emoji = table.entries[key]?.first ?? table.aliases[key] else { return nil }
        // ©, ® and a few others draw as text unless asked for as emoji.
        let presented = emoji.unicodeScalars.count == 1 && emoji.unicodeScalars.first?.properties.isEmojiPresentation == false
            ? emoji + "\u{FE0F}" : emoji
        // Past the closing colon.
        return (presented, source.index(after: name.endIndex))
    }
}
