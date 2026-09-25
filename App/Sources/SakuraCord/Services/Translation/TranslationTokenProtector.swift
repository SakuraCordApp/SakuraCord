import Foundation
import MessageRendering

/// Replaces Discord syntax that must survive translation verbatim (mentions,
/// custom emoji, links, code, timestamps) with private-use placeholders, then
/// restores it in the provider's output.
nonisolated struct TranslationTokenProtector: Equatable, Sendable {
    nonisolated enum Mode: Sendable {
        /// Every placeholder must come back exactly once; used for drafts the user will send.
        case strict
        /// Restores whatever survived; used for read-only message translations.
        case lenient
    }

    let original: String
    let providerText: String
    let tokens: [String]

    init(_ text: String) {
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        var output = ""
        var tokens: [String] = []
        var cursor = text.startIndex
        for match in Self.protectedExpression.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text), matchRange.lowerBound >= cursor else { continue }
            output += text[cursor ..< matchRange.lowerBound]
            output += Self.placeholder(tokens.count)
            tokens.append(String(text[matchRange]))
            cursor = matchRange.upperBound
        }
        output += text[cursor...]
        original = text
        providerText = output
        self.tokens = tokens
    }

    var hasTranslatableText: Bool {
        providerText.unicodeScalars.contains { scalar in
            CharacterSet.letters.contains(scalar) && !Self.placeholderScalars.contains(scalar)
        }
    }

    func restore(_ translated: String, mode: Mode) throws -> String {
        guard !tokens.isEmpty else { return translated }
        let range = NSRange(translated.startIndex ..< translated.endIndex, in: translated)
        var output = ""
        var cursor = translated.startIndex
        var restored = Set<Int>()
        for match in Self.placeholderExpression.matches(in: translated, range: range) {
            guard let matchRange = Range(match.range, in: translated),
                  let digitsRange = Range(match.range(at: 1), in: translated),
                  let index = Self.index(from: translated[digitsRange]),
                  tokens.indices.contains(index)
            else { continue }
            if restored.contains(index), mode == .strict { throw TranslationError.protectedTokenChanged }
            output += translated[cursor ..< matchRange.lowerBound]
            output += tokens[index]
            restored.insert(index)
            cursor = matchRange.upperBound
        }
        output += translated[cursor...]
        if mode == .strict, restored.count != tokens.count { throw TranslationError.protectedTokenChanged }
        return output
    }

    private static func placeholder(_ index: Int) -> String {
        "\u{E000}\(index)\u{E001}"
    }

    private static func index(from digits: Substring) -> Int? {
        // Providers occasionally return full-width digits for placeholders.
        let value = String(digits)
        return Int(value.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? value)
    }

    private static let placeholderScalars = CharacterSet(charactersIn: "\u{E000}\u{E001}")

    private static let placeholderExpression = RegularExpressionFactory.make(
        "\u{E000}\\s*([0-9\u{FF10}-\u{FF19}]+)\\s*\u{E001}"
    )

    private static let protectedExpression = RegularExpressionFactory.make(
        [
            #"```[\s\S]*?```"#,
            #"`[^`\n]+`"#,
            #"\[[^\]\n]*\]\(https?://(?:cdn|media)\.discordapp\.(?:com|net)/emojis/[^)\s]+\)"#,
            #"<a?:[A-Za-z0-9_]+:[0-9]+>"#,
            RenderedMention.tokenPattern,
            #"<t:-?[0-9]+(?::[tTdDfFR])?>"#,
            #"</[^\s<>:][^<>:]*:[0-9]+>"#,
            #"<id:[a-z]+>"#,
            #"@(?:everyone|here)\b"#,
            #"<?https?://[^\s<>]+>?"#,
        ].joined(separator: "|")
    )
}
