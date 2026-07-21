import AppKit
import Foundation
import SwiftUI

public enum DiscordMarkdown {
    private static let appKitCache = AppKitMarkdownRenderCache()

    public static func attributed(_ source: String) -> AttributedString {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var output = AttributedString()

        for (index, rawLine) in lines.enumerated() {
            if index > 0 {
                output.append(AttributedString("\n"))
            }
            let (text, headingLevel) = heading(in: String(rawLine))
            var line = (try? AttributedString(
                markdown: text,
                options: .init(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )) ?? AttributedString(text)

            if let headingLevel {
                line.font = switch headingLevel {
                case 1: .title2.bold()
                case 2: .title3.bold()
                default: .headline
                }
            }
            styleInlineCode(in: &line)
            output.append(line)
        }
        return output
    }

    public static func appKitAttributed(
        _ source: String,
        baseFontSize: CGFloat = 15
    ) -> NSAttributedString {
        if let cached = appKitCache.value(for: source, baseFontSize: baseFontSize) {
            return cached
        }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let output = NSMutableAttributedString()

        for (index, rawLine) in lines.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(string: "\n"))
            }
            let (text, headingLevel) = heading(in: String(rawLine))
            let parsed = (try? AttributedString(
                markdown: text,
                options: .init(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )) ?? AttributedString(text)
            let line = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
            applyAppKitStyles(
                to: line,
                baseFont: appKitFont(headingLevel: headingLevel, baseFontSize: baseFontSize)
            )
            output.append(line)
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        output.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: output.length)
        )
        let result = NSAttributedString(attributedString: output)
        appKitCache.insert(result, for: source, baseFontSize: baseFontSize)
        return result
    }

    private static func heading(in line: String) -> (String, Int?) {
        if line.hasPrefix("### ") {
            return (String(line.dropFirst(4)), 3)
        }
        if line.hasPrefix("## ") {
            return (String(line.dropFirst(3)), 2)
        }
        if line.hasPrefix("# ") {
            return (String(line.dropFirst(2)), 1)
        }
        return (line, nil)
    }

    private static func styleInlineCode(in value: inout AttributedString) {
        for run in value.runs where run.inlinePresentationIntent?.contains(.code) == true {
            value[run.range].font = .system(.body, design: .monospaced)
            value[run.range].backgroundColor = Color.secondary.opacity(0.16)
        }
    }

    private static func appKitFont(headingLevel: Int?, baseFontSize: CGFloat) -> NSFont {
        switch headingLevel {
        case 1: NSFont.systemFont(ofSize: 22, weight: .bold)
        case 2: NSFont.systemFont(ofSize: 18, weight: .bold)
        case 3: NSFont.systemFont(ofSize: 15, weight: .semibold)
        default: NSFont.systemFont(ofSize: baseFontSize)
        }
    }

    private static func applyAppKitStyles(to value: NSMutableAttributedString, baseFont: NSFont) {
        let intentKey = NSAttributedString.Key("NSInlinePresentationIntent")
        let fullRange = NSRange(location: 0, length: value.length)
        value.addAttributes(
            [.font: baseFont, .foregroundColor: NSColor.labelColor],
            range: fullRange
        )
        value.enumerateAttribute(intentKey, in: fullRange) { rawValue, range, _ in
            let intent = (rawValue as? NSNumber)?.intValue ?? 0
            var font = baseFont
            if intent & 1 != 0 {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            if intent & 2 != 0 {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if intent & 4 != 0 {
                font = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
                value.addAttribute(
                    .backgroundColor,
                    value: NSColor.secondaryLabelColor.withAlphaComponent(0.16),
                    range: range
                )
            }
            value.addAttribute(.font, value: font, range: range)
            if intent & 32 != 0 {
                value.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        value.removeAttribute(intentKey, range: fullRange)
        value.removeAttribute(NSAttributedString.Key("SwiftUI.Font"), range: fullRange)
        value.removeAttribute(NSAttributedString.Key("SwiftUI.BackgroundColor"), range: fullRange)
    }
}

private final class AppKitMarkdownRenderCache: @unchecked Sendable {
    private let values = NSCache<AppKitMarkdownCacheKey, NSAttributedString>()

    init() {
        values.countLimit = 2_000
        values.totalCostLimit = 12 * 1024 * 1024
    }

    func value(for source: String, baseFontSize: CGFloat) -> NSAttributedString? {
        values.object(forKey: AppKitMarkdownCacheKey(source: source, baseFontSize: baseFontSize))
    }

    func insert(_ value: NSAttributedString, for source: String, baseFontSize: CGFloat) {
        values.setObject(
            value,
            forKey: AppKitMarkdownCacheKey(source: source, baseFontSize: baseFontSize),
            cost: max(source.utf8.count, value.length * 2)
        )
    }
}

private final class AppKitMarkdownCacheKey: NSObject {
    let source: String
    let baseFontSize: CGFloat

    init(source: String, baseFontSize: CGFloat) {
        self.source = source
        self.baseFontSize = baseFontSize
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(source)
        hasher.combine(baseFontSize)
        return hasher.finalize()
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? AppKitMarkdownCacheKey else { return false }
        return source == other.source && baseFontSize == other.baseFontSize
    }
}
