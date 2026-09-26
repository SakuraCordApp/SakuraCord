import AppKit
import Foundation
import SakuraCordModels
import SwiftUI

public extension NSAttributedString.Key {
    /// Paragraph-level metadata consumed by the native timeline painter.
    static let discordMarkdownBlock = NSAttributedString.Key(
        "dev.sakuracord.markdown.block"
    )

    /// Marks hidden spoiler text. The value is an NSNumber boolean.
    static let discordMarkdownSpoiler = NSAttributedString.Key(
        "dev.sakuracord.markdown.spoiler"
    )

    /// Marks inline code for the native painter's rounded Discord treatment.
    static let discordMarkdownInlineCode = NSAttributedString.Key(
        "dev.sakuracord.markdown.inline-code"
    )

    /// Marks the logical bullet that the native painter replaces with
    /// Discord's larger filled list marker.
    static let discordMarkdownListMarker = NSAttributedString.Key(
        "dev.sakuracord.markdown.list-marker"
    )
}

public enum DiscordMarkdown {
    public struct AppKitPlan: Hashable, Sendable {
        public struct Line: Hashable, Sendable {
            fileprivate let runs: [InlineRun]
            fileprivate let block: Block
        }

        fileprivate enum Block: Hashable, Sendable {
            case paragraph
            case heading(Int)
            case subtext
            case quote
            case unorderedList
            case orderedList
            case code(language: String?)
        }

        fileprivate struct InlineRun: Hashable, Sendable {
            fileprivate let text: String
            fileprivate let traits: InlineTraits
            fileprivate let link: URL?
            fileprivate let color: SemanticColor?
        }

        fileprivate struct InlineTraits: OptionSet, Hashable, Sendable {
            let rawValue: UInt8

            static let bold = Self(rawValue: 1 << 0)
            static let italic = Self(rawValue: 1 << 1)
            static let underline = Self(rawValue: 1 << 2)
            static let strikethrough = Self(rawValue: 1 << 3)
            static let inlineCode = Self(rawValue: 1 << 4)
            static let spoiler = Self(rawValue: 1 << 5)
            static let listMarker = Self(rawValue: 1 << 6)
        }

        fileprivate enum SemanticColor: Int, Hashable, Sendable {
            case jsonKey
            case jsonString
            case jsonNumber
            case jsonKeyword
        }

        public let lines: [Line]

        fileprivate init(lines: [Line]) {
            self.lines = lines
        }
    }

    /// Content ranges in the original Markdown, excluding their surrounding delimiters.
    /// Editors use these UTF-16 ranges without converting the draft to rendered text.
    public struct SourceFormat: Sendable {
        public let range: NSRange
        public let delimiter: String
        public let isBold: Bool
        public let isItalic: Bool
        public let isUnderlined: Bool
    }

    public static func sourceFormats(_ source: String) -> [SourceFormat] {
        // No supported style can begin without one of these ASCII markers.
        guard source.utf8.contains(42) || source.utf8.contains(95) else { return [] }
        // NSTextStorage can vend UTF-16-backed strings. Normalize once instead of
        // paying for bridged character access throughout the recursive scan.
        var source = source
        source.makeContiguousUTF8()
        var formats: [SourceFormat] = []
        var segmentStart = source.startIndex
        var inCodeFence = false
        let collect: (Range<String.Index>, AppKitPlan.InlineTraits, String) -> Void = { range, traits, delimiter in
            guard !traits.isDisjoint(with: [.bold, .italic, .underline]) else { return }
            formats.append(SourceFormat(
                range: NSRange(range, in: source),
                delimiter: delimiter,
                isBold: traits.contains(.bold),
                isItalic: traits.contains(.italic),
                isUnderlined: traits.contains(.underline)
            ))
        }
        let collector = SourceFormatCollector(source: source, collect: collect)
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("```") else { continue }
            if !inCodeFence {
                _ = inlineRuns(source[segmentStart ..< line.startIndex], inheritedTraits: [], inheritedLink: nil, sourceCollector: collector)
            }
            inCodeFence.toggle()
            segmentStart = line.endIndex
        }
        if !inCodeFence {
            _ = inlineRuns(source[segmentStart...], inheritedTraits: [], inheritedLink: nil, sourceCollector: collector)
        }
        return formats
    }

    private struct Delimiter {
        let marker: String
        let traits: AppKitPlan.InlineTraits
    }

    private static let delimiters: [Delimiter] = [
        Delimiter(marker: "||", traits: .spoiler),
        Delimiter(marker: "~~", traits: .strikethrough),
        Delimiter(marker: "***", traits: [.bold, .italic]),
        // Discord resolves three underscores as nested underline + italic.
        // Unlike three asterisks, it does not add a bold trait.
        Delimiter(marker: "___", traits: [.italic, .underline]),
        Delimiter(marker: "__", traits: .underline),
        Delimiter(marker: "**", traits: .bold),
        Delimiter(marker: "*", traits: .italic),
        Delimiter(marker: "_", traits: .italic),
    ]

    private static let appKitCache = AppKitMarkdownRenderCache()
    private static let codeForegroundColor = NSColor(
        srgbRed: 219 / 255,
        green: 222 / 255,
        blue: 225 / 255,
        alpha: 1
    )

    public static func attributed(_ source: String) -> AttributedString {
        let plan = appKitPlan(source)
        var output = AttributedString()
        for (lineIndex, line) in plan.lines.enumerated() {
            if lineIndex > 0 {
                output.append(AttributedString("\n"))
            }
            for run in line.runs {
                var value = AttributedString(run.text)
                if run.traits.contains(.bold) {
                    value.font = .body.bold()
                }
                if run.traits.contains(.italic) {
                    value.font = .body.italic()
                }
                if run.traits.contains(.underline) {
                    value.underlineStyle = .single
                }
                if run.traits.contains(.strikethrough) {
                    value.strikethroughStyle = .single
                }
                if run.traits.contains(.inlineCode) {
                    value.font = .system(.body, design: .monospaced)
                    value.backgroundColor = Color.secondary.opacity(0.16)
                }
                value.link = run.link
                output.append(value)
            }
        }
        return output
    }

    /// Personal profile widgets allow emphasis, underline and links, but no
    /// message-only blocks, code, spoilers, strike-through or emoji parsing.
    public static func profileWidgetAttributed(_ source: String, font: Font = .body, links: Bool = true) -> AttributedString {
        let runs = inlineRuns(source[...], inheritedTraits: [], inheritedLink: nil, widgetRules: true)
        var output = AttributedString()
        for run in runs {
            var value = AttributedString(run.text)
            var runFont = font
            if run.traits.contains(.bold) { runFont = runFont.bold() }
            if run.traits.contains(.italic) { runFont = runFont.italic() }
            value.font = runFont
            if run.traits.contains(.underline) { value.underlineStyle = .single }
            if links { value.link = run.link }
            output.append(value)
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
        let result = appKitAttributed(
            appKitPlan(source),
            baseFontSize: baseFontSize
        )
        appKitCache.insert(result, for: source, baseFontSize: baseFontSize)
        return result
    }

    public static func appKitPlan(_ source: String) -> AppKitPlan {
        let rawLines = source.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        var lines: [AppKitPlan.Line] = []
        lines.reserveCapacity(rawLines.count)
        var codeLanguage: String?
        var isInCodeFence = false
        var isInMultilineQuote = false

        for rawLine in rawLines {
            let line = String(rawLine)
            if line.hasPrefix("```") {
                if isInCodeFence {
                    isInCodeFence = false
                    codeLanguage = nil
                } else {
                    isInCodeFence = true
                    let suffix = line.dropFirst(3)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    codeLanguage = suffix.isEmpty ? nil : suffix.lowercased()
                }
                continue
            }

            if isInCodeFence {
                lines.append(
                    AppKitPlan.Line(
                        runs: codeRuns(line, language: codeLanguage),
                        block: .code(language: codeLanguage)
                    )
                )
                continue
            }

            if isInMultilineQuote {
                if line.isEmpty {
                    isInMultilineQuote = false
                } else {
                    lines.append(
                        DiscordMarkdown.line(line, block: .quote)
                    )
                    continue
                }
            }
            if line.hasPrefix(">>> ") {
                isInMultilineQuote = true
                lines.append(
                    DiscordMarkdown.line(
                        String(line.dropFirst(4)),
                        block: .quote
                    )
                )
                continue
            }

            lines.append(planLine(line))
        }

        // Discord shows the literal opening fence when a message never closes
        // it. Keep malformed input visible instead of silently discarding it.
        if isInCodeFence {
            let language = codeLanguage.map { $0.isEmpty ? "" : $0 } ?? ""
            let opening = "```" + language
            let fence = AppKitPlan.Line(
                runs: [
                    AppKitPlan.InlineRun(
                        text: opening,
                        traits: [],
                        link: nil,
                        color: nil
                    )
                ],
                block: .paragraph
            )
            let firstCodeIndex = lines.lastIndex {
                if case .code = $0.block { return false }
                return true
            }.map { $0 + 1 } ?? 0
            lines.insert(fence, at: firstCodeIndex)
        }

        return AppKitPlan(lines: lines)
    }

    public static func appKitAttributed(
        _ plan: AppKitPlan,
        baseFontSize: CGFloat = 15
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()

        for (lineIndex, linePlan) in plan.lines.enumerated() {
            appendLineSeparator(
                to: output,
                before: lineIndex,
                plan: plan,
                baseFontSize: baseFontSize
            )
            output.append(attributedLine(
                linePlan,
                index: lineIndex,
                plan: plan,
                baseFontSize: baseFontSize
            ))
        }

        return NSAttributedString(attributedString: output)
    }

    private static func appendLineSeparator(
        to output: NSMutableAttributedString,
        before lineIndex: Int,
        plan: AppKitPlan,
        baseFontSize: CGFloat
    ) {
        guard lineIndex > 0 else { return }
        let previousLine = plan.lines[lineIndex - 1]
        if previousLine.runs.isEmpty {
            output.append(
                NSAttributedString(
                    string: "\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: baseFontSize),
                        .foregroundColor: NSColor.labelColor,
                        .paragraphStyle: blankParagraphStyle(),
                    ]
                )
            )
        } else {
            output.append(NSAttributedString(string: "\n"))
        }
    }

    private static func attributedLine(
        _ linePlan: AppKitPlan.Line,
        index lineIndex: Int,
        plan: AppKitPlan,
        baseFontSize: CGFloat
    ) -> NSAttributedString {
        let line = NSMutableAttributedString()
        for run in linePlan.runs {
            line.append(NSAttributedString(
                string: run.text,
                attributes: attributes(
                    for: run,
                    block: linePlan.block,
                    baseFontSize: baseFontSize
                )
            ))
        }
        let startsCodeBlock = isCodeBlock(linePlan)
            && (lineIndex == plan.lines.startIndex
                || !isCodeBlock(plan.lines[lineIndex - 1]))
        let endsCodeBlock = isCodeBlock(linePlan)
            && (lineIndex == plan.lines.index(before: plan.lines.endIndex)
                || !isCodeBlock(plan.lines[lineIndex + 1]))
        let startsListBlock = isListBlock(linePlan)
            && (lineIndex == plan.lines.startIndex
                || !isSameListBlock(linePlan, plan.lines[lineIndex - 1]))
        let startsInlineCodeLine = lineIndex > plan.lines.startIndex
            && !plan.lines[lineIndex - 1].runs.isEmpty
            && isInlineCodeOnlyLine(linePlan)
        let paragraph = paragraphStyle(
            for: linePlan.block,
            startsListBlock: startsListBlock,
            startsInlineCodeLine: startsInlineCodeLine,
            startsCodeBlock: startsCodeBlock,
            endsCodeBlock: endsCodeBlock
        )
        let fullRange = NSRange(location: 0, length: line.length)
        if fullRange.length > 0 {
            line.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
            if let blockName = blockAttribute(for: linePlan.block) {
                line.addAttribute(.discordMarkdownBlock, value: blockName, range: fullRange)
            }
        }
        return line
    }

    private static func attributes(
        for run: AppKitPlan.InlineRun,
        block: AppKitPlan.Block,
        baseFontSize: CGFloat
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: appKitFont(block: block, traits: run.traits, baseFontSize: baseFontSize),
            .foregroundColor: foregroundColor(block: block, semanticColor: run.color),
        ]
        if case .code = block, run.color == nil {
            attributes[.foregroundColor] = codeForegroundColor
        }
        if run.traits.contains(.underline) {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if run.traits.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if run.traits.contains(.inlineCode) {
            attributes[.discordMarkdownInlineCode] = NSNumber(value: true)
            attributes[.foregroundColor] = codeForegroundColor
        }
        if run.traits.contains(.listMarker) {
            attributes[.discordMarkdownListMarker] = NSNumber(value: true)
            attributes[.foregroundColor] = NSColor.clear
        }
        if let link = run.link {
            attributes[.link] = link
            attributes[.foregroundColor] = NSColor.linkColor
        }
        if run.traits.contains(.spoiler) {
            let spoilerColor = NSColor.secondaryLabelColor.withAlphaComponent(0.42)
            attributes[.backgroundColor] = spoilerColor
            attributes[.foregroundColor] = NSColor.clear
            attributes[.underlineColor] = NSColor.clear
            attributes[.strikethroughColor] = NSColor.clear
            attributes[.discordMarkdownSpoiler] = NSNumber(value: true)
        }
        return attributes
    }

    private static func planLine(_ source: String) -> AppKitPlan.Line {
        if source.hasPrefix("### ") {
            return line(
                String(source.dropFirst(4)),
                block: .heading(3)
            )
        }
        if source.hasPrefix("## ") {
            return line(
                String(source.dropFirst(3)),
                block: .heading(2)
            )
        }
        if source.hasPrefix("# ") {
            return line(
                String(source.dropFirst(2)),
                block: .heading(1)
            )
        }
        if source.hasPrefix("-# ") {
            return line(
                String(source.dropFirst(3)),
                block: .subtext
            )
        }
        if source.hasPrefix(">>> ") {
            return line(
                String(source.dropFirst(4)),
                block: .quote
            )
        }
        if source.hasPrefix("> ") {
            return line(
                String(source.dropFirst(2)),
                block: .quote
            )
        }
        if source.hasPrefix("- ") || source.hasPrefix("* ") {
            return unorderedListLine(
                source.dropFirst(2)
            )
        }
        if let ordered = orderedListContent(source) {
            return line(
                ordered.marker + ordered.content,
                block: .orderedList
            )
        }
        return line(source, block: .paragraph)
    }

    private static func unorderedListLine(
        _ content: Substring
    ) -> AppKitPlan.Line {
        var runs = [
            AppKitPlan.InlineRun(
                text: "•",
                traits: .listMarker,
                link: nil,
                color: nil
            ),
            AppKitPlan.InlineRun(
                text: " ",
                traits: [],
                link: nil,
                color: nil
            ),
        ]
        runs.append(
            contentsOf: inlineRuns(
                content,
                inheritedTraits: [],
                inheritedLink: nil
            )
        )
        return AppKitPlan.Line(
            runs: runs,
            block: .unorderedList
        )
    }

    private static func line(
        _ source: String,
        block: AppKitPlan.Block
    ) -> AppKitPlan.Line {
        AppKitPlan.Line(
            runs: inlineRuns(
                source[...],
                inheritedTraits: [],
                inheritedLink: nil
            ),
            block: block
        )
    }

    private static func orderedListContent(
        _ source: String
    ) -> (marker: String, content: Substring)? {
        var cursor = source.startIndex
        while cursor < source.endIndex, source[cursor].isNumber {
            cursor = source.index(after: cursor)
        }
        guard cursor > source.startIndex,
              cursor < source.endIndex,
              source[cursor] == "."
        else { return nil }
        let space = source.index(after: cursor)
        guard space < source.endIndex, source[space] == " " else {
            return nil
        }
        return (
            String(source[...space]),
            source[source.index(after: space)...]
        )
    }

    private static func inlineRuns(
        _ source: Substring,
        inheritedTraits: AppKitPlan.InlineTraits,
        inheritedLink: URL?,
        widgetRules: Bool = false,
        sourceCollector: SourceFormatCollector? = nil
    ) -> [AppKitPlan.InlineRun] {
        var result: [AppKitPlan.InlineRun] = []
        var plain = ""
        var cursor = source.startIndex

        func flushPlain() {
            guard !plain.isEmpty else { return }
            appendPlainRuns(
                plain,
                traits: inheritedTraits,
                link: inheritedLink,
                to: &result
            )
            plain.removeAll(keepingCapacity: true)
        }

        while cursor < source.endIndex {
            if sourceCollector != nil {
                guard let candidate = source[cursor...].firstIndex(where: isComposerSyntaxCharacter) else { break }
                cursor = candidate
            }
            if source[cursor] == "\\" {
                let next = source.index(after: cursor)
                if next < source.endIndex {
                    plain.append(source[next])
                    cursor = source.index(after: next)
                    continue
                }
            }

            if !widgetRules, source[cursor] == "`",
               let close = nextInlineTerminator("`", in: source, from: source.index(after: cursor), collector: sourceCollector)
            {
                flushPlain()
                result.append(
                    AppKitPlan.InlineRun(
                        text: String(source[source.index(after: cursor) ..< close]),
                        traits: inheritedTraits.union(.inlineCode),
                        link: inheritedLink,
                        color: nil
                    )
                )
                cursor = source.index(after: close)
                continue
            }

            if inheritedLink == nil,
               let autolink = angleBracketAutolink(
                   in: source,
                   at: cursor,
                   traits: inheritedTraits,
                   sourceCollector: sourceCollector
               )
            {
                flushPlain()
                result.append(autolink.run)
                cursor = autolink.endIndex
                continue
            }

            if let link = markdownLink(
                in: source,
                at: cursor,
                inheritedTraits: inheritedTraits,
                widgetRules: widgetRules,
                sourceCollector: sourceCollector
            )
            {
                flushPlain()
                result.append(contentsOf: link.runs)
                cursor = link.endIndex
                continue
            }

            if inheritedLink == nil,
               sourceCollector == nil || source[cursor...].hasPrefix("http://") || source[cursor...].hasPrefix("https://"),
               let autolink = bareAutolink(
                   in: source,
                   at: cursor,
                   traits: inheritedTraits,
                   anchored: sourceCollector != nil
               )
            {
                flushPlain()
                result.append(autolink.run)
                cursor = autolink.endIndex
                continue
            }

            if sourceCollector == nil || isComposerDelimiterCharacter(source[cursor]),
               let match = delimitedRuns(
                in: source,
                at: cursor,
                inheritedTraits: inheritedTraits,
                inheritedLink: inheritedLink,
                widgetRules: widgetRules,
                sourceCollector: sourceCollector
            ) {
                flushPlain()
                result.append(contentsOf: match.runs)
                cursor = match.endIndex
                continue
            }

            if sourceCollector == nil { plain.append(source[cursor]) }
            cursor = source.index(after: cursor)
        }

        flushPlain()
        return result
    }

    private static func angleBracketAutolink(
        in source: Substring,
        at cursor: String.Index,
        traits: AppKitPlan.InlineTraits,
        sourceCollector: SourceFormatCollector? = nil
    ) -> (run: AppKitPlan.InlineRun, endIndex: String.Index)? {
        guard source[cursor] == "<",
              let close = nextInlineTerminator(">", in: source, from: source.index(after: cursor), collector: sourceCollector),
              let url = MessageLinkPolicy.allowedURL(
                  from: String(source[cursor ... close])
              )
        else { return nil }

        return (
            AppKitPlan.InlineRun(
                text: String(
                    source[source.index(after: cursor) ..< close]
                ),
                traits: traits,
                link: url,
                color: nil
            ),
            source.index(after: close)
        )
    }

    private static func markdownLink(
        in source: Substring,
        at cursor: String.Index,
        inheritedTraits: AppKitPlan.InlineTraits,
        widgetRules: Bool = false,
        sourceCollector: SourceFormatCollector? = nil
    ) -> (runs: [AppKitPlan.InlineRun], endIndex: String.Index)? {
        guard let target = markdownLinkTarget(in: source, at: cursor, collector: sourceCollector) else { return nil }
        return (
            inlineRuns(
                source[target.label],
                inheritedTraits: inheritedTraits,
                inheritedLink: target.url,
                widgetRules: widgetRules,
                sourceCollector: sourceCollector
            ),
            target.end
        )
    }

    private static func nextInlineTerminator(
        _ character: Character, in source: Substring, from start: String.Index, collector: SourceFormatCollector?
    ) -> String.Index? {
        if let collector { return collector.next(character, from: start, before: source.endIndex) }
        return source[start...].firstIndex(of: character)
    }

    private static func markdownLinkTarget(
        in source: Substring, at cursor: String.Index, collector: SourceFormatCollector?
    ) -> MarkdownLinkTarget? {
        guard source[cursor] == "[",
              let labelEnd = nextInlineTerminator("]", in: source, from: cursor, collector: collector)
        else { return nil }
        let openingParenthesis = source.index(after: labelEnd)
        guard openingParenthesis < source.endIndex,
              source[openingParenthesis] == "(",
              let closingParenthesis = nextInlineTerminator(")", in: source, from: openingParenthesis, collector: collector),
              let url = MessageLinkPolicy.allowedURL(
                  from: String(
                      source[
                          source.index(after: openingParenthesis)
                              ..< closingParenthesis
                      ]
                  )
              )
        else { return nil }
        return MarkdownLinkTarget(
            label: source.index(after: cursor) ..< labelEnd,
            url: url,
            end: source.index(after: closingParenthesis)
        )
    }

    private static func bareAutolink(
        in source: Substring,
        at cursor: String.Index,
        traits: AppKitPlan.InlineTraits,
        anchored: Bool = false
    ) -> (run: AppKitPlan.InlineRun, endIndex: String.Index)? {
        guard let match = firstURL(in: source[cursor...], anchored: anchored),
              match.range.lowerBound == cursor
        else { return nil }

        return (
            AppKitPlan.InlineRun(
                text: String(source[match.range]),
                traits: traits,
                link: match.url,
                color: nil
            ),
            match.range.upperBound
        )
    }

    private static func delimitedRuns(
        in source: Substring,
        at cursor: String.Index,
        inheritedTraits: AppKitPlan.InlineTraits,
        inheritedLink: URL?,
        widgetRules: Bool = false,
        sourceCollector: SourceFormatCollector? = nil
    ) -> (runs: [AppKitPlan.InlineRun], endIndex: String.Index)? {
        for delimiter in delimiters
        where source[cursor...].hasPrefix(delimiter.marker) {
            if widgetRules, !delimiter.traits.isDisjoint(with: [.strikethrough, .spoiler]) { continue }
            let contentStart = source.index(
                cursor,
                offsetBy: delimiter.marker.count
            )
            // Only the composer source-range traversal uses nested matching.
            // Message rendering retains its original delimiter matching exactly.
            let closingRange = if let sourceCollector {
                composerClosingDelimiter(delimiter.marker, in: source, after: contentStart, collector: sourceCollector)
            } else {
                source.range(of: delimiter.marker, range: contentStart ..< source.endIndex)
            }
            guard contentStart <= source.endIndex,
                  let closingRange,
                  closingRange.lowerBound > contentStart
            else { continue }
            sourceCollector?.collect(contentStart ..< closingRange.lowerBound, inheritedTraits.union(delimiter.traits), delimiter.marker)
            return (
                inlineRuns(
                    source[contentStart ..< closingRange.lowerBound],
                    inheritedTraits: inheritedTraits.union(delimiter.traits),
                    inheritedLink: inheritedLink,
                    widgetRules: widgetRules,
                    sourceCollector: sourceCollector
                ),
                closingRange.upperBound
            )
        }
        return nil
    }

    // Ignore literal markers when matching a composer's surrounding format.
    // This affects recognition only; editing may still target any selected text.
    private static func composerLiteralEnd(
        in source: Substring, at cursor: String.Index, collector: SourceFormatCollector
    ) -> String.Index? {
        let next = source.index(after: cursor)
        if source[cursor] == "\\", next < source.endIndex {
            return source.index(after: next)
        }
        if source[cursor] == "`", let close = collector.next("`", from: next, before: source.endIndex) {
            return source.index(after: close)
        }
        if let link = markdownLinkTarget(in: source, at: cursor, collector: collector) {
            return link.end
        }
        if let link = angleBracketAutolink(in: source, at: cursor, traits: [], sourceCollector: collector) {
            return link.endIndex
        }
        return nil
    }

    private static func composerClosingDelimiter(
        _ marker: String, in source: Substring, after start: String.Index,
        collector: SourceFormatCollector,
        enclosingMarkers: Set<String> = []
    ) -> Range<String.Index>? {
        let openMarkers = enclosingMarkers.union([marker])
        var cursor = start
        while cursor < source.endIndex {
            guard let candidateIndex = source[cursor...].firstIndex(where: isComposerSyntaxCharacter) else { return nil }
            cursor = candidateIndex
            if let end = composerLiteralEnd(in: source, at: cursor, collector: collector) {
                cursor = end
                continue
            }
            guard isComposerDelimiterCharacter(source[cursor]),
                  let candidate = delimiters.first(where: { source[cursor...].hasPrefix($0.marker) }) else {
                cursor = source.index(after: cursor)
                continue
            }
            var runEnd = source.index(after: cursor)
            while runEnd < source.endIndex, source[runEnd] == source[cursor] {
                runEnd = source.index(after: runEnd)
            }
            let runLength = source.distance(from: cursor, to: runEnd)
            let canOpen = runEnd < source.endIndex && !source[runEnd].isWhitespace
            let closesCurrent = source[cursor...].hasPrefix(marker)
            // An unmatched inner opener cannot consume a parent's closer. A
            // combined closing run can close both only if it has enough marks.
            if enclosingMarkers.contains(where: {
                source[cursor...].hasPrefix($0)
                    && (!closesCurrent || ($0.count > marker.count && runLength < $0.count + marker.count))
            }) {
                return nil
            }
            // A triple closing run is consumed from the inside out: the inner
            // * in **bold *italic*** closes first, leaving ** for its parent.
            if closesCurrent, runLength != 2 || marker.count != 1 || !canOpen {
                return cursor ..< source.index(cursor, offsetBy: marker.count)
            }
            // Skip complete nested spans before looking for our own closing
            // pair. In *__**text**__*, the inner ** cannot close the outer *.
            // A style already open is a closer, not another recursive opener.
            if !openMarkers.contains(candidate.marker), canOpen,
               let nestedClose = composerClosingDelimiter(
                   candidate.marker, in: source,
                   after: source.index(cursor, offsetBy: candidate.marker.count),
                   collector: collector,
                   enclosingMarkers: openMarkers
               ) {
                cursor = nestedClose.upperBound
                continue
            }
            if closesCurrent {
                return cursor ..< source.index(cursor, offsetBy: marker.count)
            }
            cursor = runEnd
        }
        return nil
    }

    private static func appendPlainRuns(
        _ source: String,
        traits: AppKitPlan.InlineTraits,
        link: URL?,
        to output: inout [AppKitPlan.InlineRun]
    ) {
        guard link == nil else {
            output.append(
                AppKitPlan.InlineRun(
                    text: source,
                    traits: traits,
                    link: link,
                    color: nil
                )
            )
            return
        }

        var remainder = source[...]
        while let match = firstURL(in: remainder) {
            if match.range.lowerBound > remainder.startIndex {
                output.append(
                    AppKitPlan.InlineRun(
                        text: String(remainder[..<match.range.lowerBound]),
                        traits: traits,
                        link: nil,
                        color: nil
                    )
                )
            }
            output.append(
                AppKitPlan.InlineRun(
                    text: String(remainder[match.range]),
                    traits: traits,
                    link: match.url,
                    color: nil
                )
            )
            remainder = remainder[match.range.upperBound...]
        }
        if !remainder.isEmpty {
            output.append(
                AppKitPlan.InlineRun(
                    text: String(remainder),
                    traits: traits,
                    link: nil,
                    color: nil
                )
            )
        }
    }

    private static func firstURL(
        in source: Substring, anchored: Bool = false
    ) -> (range: Range<String.Index>, url: URL)? {
        let candidates = ["https://", "http://"].compactMap { prefix -> Range<String.Index>? in
            if anchored {
                guard source.hasPrefix(prefix) else { return nil }
                return source.startIndex ..< source.index(source.startIndex, offsetBy: prefix.count)
            }
            return source.range(of: prefix)
        }
        guard let prefix = candidates.min(by: {
            $0.lowerBound < $1.lowerBound
        }) else { return nil }
        var end = prefix.upperBound
        var parenthesisDepth = 0
        scan: while end < source.endIndex {
            let character = source[end]
            if character.isWhitespace || "]<>".contains(character) {
                break
            }
            if character == ")" {
                guard parenthesisDepth > 0 else { break scan }
                parenthesisDepth -= 1
            } else if character == "(" {
                parenthesisDepth += 1
            }
            end = source.index(after: end)
        }
        while end > prefix.upperBound {
            let previous = source.index(before: end)
            guard ".,!?;:".contains(source[previous]) else { break }
            end = previous
        }
        let range = prefix.lowerBound ..< end
        guard let url = MessageLinkPolicy.allowedURL(
            from: String(source[range])
        ) else {
            return nil
        }
        return (range, url)
    }

    private static func codeRuns(
        _ source: String,
        language: String?
    ) -> [AppKitPlan.InlineRun] {
        if source.contains("\u{001B}") {
            // Discord's current renderer does not interpret ANSI SGR in this
            // fixture. The control character itself has no visible glyph,
            // while the bracketed escape payload remains literal.
            return [
                AppKitPlan.InlineRun(
                    text: source.replacingOccurrences(
                        of: "\u{001B}",
                        with: ""
                    ),
                    traits: [],
                    link: nil,
                    color: nil
                )
            ]
        }
        if language == "json" {
            return jsonRuns(source)
        }
        return [
            AppKitPlan.InlineRun(
                text: source,
                traits: [],
                link: nil,
                color: nil
            )
        ]
    }

    private static func jsonRuns(_ source: String) -> [AppKitPlan.InlineRun] {
        var output: [AppKitPlan.InlineRun] = []
        var cursor = source.startIndex
        while cursor < source.endIndex {
            if source[cursor] == "\"" {
                var end = source.index(after: cursor)
                var escaped = false
                while end < source.endIndex {
                    if source[end] == "\"", !escaped {
                        end = source.index(after: end)
                        break
                    }
                    escaped = source[end] == "\\" && !escaped
                    if source[end] != "\\" {
                        escaped = false
                    }
                    end = source.index(after: end)
                }
                output.append(
                    AppKitPlan.InlineRun(
                        text: String(source[cursor ..< end]),
                        traits: [],
                        link: nil,
                        color: jsonStringColor(
                            in: source,
                            after: end
                        )
                    )
                )
                cursor = end
                continue
            }
            if source[cursor].isNumber || source[cursor] == "-" {
                var end = source.index(after: cursor)
                while end < source.endIndex,
                      source[end].isNumber || ".eE+-".contains(source[end])
                {
                    end = source.index(after: end)
                }
                output.append(
                    AppKitPlan.InlineRun(
                        text: String(source[cursor ..< end]),
                        traits: [],
                        link: nil,
                        color: .jsonNumber
                    )
                )
                cursor = end
                continue
            }
            let tail = source[cursor...]
            if let keyword = ["true", "false", "null"].first(
                where: { tail.hasPrefix($0) }
            ) {
                output.append(
                    AppKitPlan.InlineRun(
                        text: keyword,
                        traits: [],
                        link: nil,
                        color: .jsonKeyword
                    )
                )
                cursor = source.index(cursor, offsetBy: keyword.count)
                continue
            }

            var end = source.index(after: cursor)
            while end < source.endIndex,
                  source[end] != "\"",
                  !source[end].isNumber,
                  !source[end...].hasPrefix("true"),
                  !source[end...].hasPrefix("false"),
                  !source[end...].hasPrefix("null")
            {
                end = source.index(after: end)
            }
            output.append(
                AppKitPlan.InlineRun(
                    text: String(source[cursor ..< end]),
                    traits: [],
                    link: nil,
                    color: nil
                )
            )
            cursor = end
        }
        return output
    }

    private static func jsonStringColor(
        in source: String,
        after stringEnd: String.Index
    ) -> AppKitPlan.SemanticColor {
        var lookahead = stringEnd
        while lookahead < source.endIndex,
              source[lookahead].isWhitespace
        {
            lookahead = source.index(after: lookahead)
        }
        return lookahead < source.endIndex && source[lookahead] == ":"
            ? .jsonKey
            : .jsonString
    }

    private static func appKitFont(
        block: AppKitPlan.Block,
        traits: AppKitPlan.InlineTraits,
        baseFontSize: CGFloat
    ) -> NSFont {
        let size: CGFloat
        let defaultWeight: NSFont.Weight
        switch block {
        case let .heading(level):
            switch level {
            case 1:
                size = max(baseFontSize, 24)
                defaultWeight = .bold
            case 2:
                size = max(baseFontSize, 20)
                defaultWeight = .bold
            default:
                size = max(baseFontSize, 16)
                defaultWeight = .semibold
            }
        case .subtext:
            size = min(baseFontSize, 12)
            defaultWeight = .regular
        case .code:
            size = min(baseFontSize, 14)
            defaultWeight = .regular
        default:
            size = baseFontSize
            defaultWeight = traits.contains(.bold) ? .semibold : .regular
        }

        var font = if case .code = block {
            NSFont.monospacedSystemFont(
                ofSize: size,
                weight: traits.contains(.bold) ? .bold : defaultWeight
            )
        } else if traits.contains(.inlineCode) {
            NSFont.monospacedSystemFont(
                ofSize: size,
                weight: traits.contains(.bold) ? .semibold : .regular
            )
        } else {
            NSFont.systemFont(
                ofSize: size,
                weight: traits.contains(.bold) ? .semibold : defaultWeight
            )
        }
        if traits.contains(.italic) {
            font = NSFontManager.shared.convert(
                font,
                toHaveTrait: .italicFontMask
            )
        }
        return font
    }

    private static func foregroundColor(
        block: AppKitPlan.Block,
        semanticColor: AppKitPlan.SemanticColor?
    ) -> NSColor {
        switch semanticColor {
        case .jsonKey: NSColor(
            red: 0.31,
            green: 0.63,
            blue: 0.98,
            alpha: 1
        )
        case .jsonString: NSColor(
            red: 0.64,
            green: 0.82,
            blue: 0.53,
            alpha: 1
        )
        case .jsonNumber: NSColor(
            red: 0.94,
            green: 0.56,
            blue: 0.31,
            alpha: 1
        )
        case .jsonKeyword: NSColor(red: 0.45, green: 0.72, blue: 0.96, alpha: 1)
        case nil:
            if case .subtext = block {
                NSColor.secondaryLabelColor
            } else {
                NSColor.labelColor
            }
        }
    }

    private static func isCodeBlock(
        _ line: AppKitPlan.Line
    ) -> Bool {
        if case .code = line.block {
            return true
        }
        return false
    }

    private static func isListBlock(
        _ line: AppKitPlan.Line
    ) -> Bool {
        switch line.block {
        case .unorderedList, .orderedList:
            true
        default:
            false
        }
    }

    private static func isSameListBlock(
        _ lhs: AppKitPlan.Line,
        _ rhs: AppKitPlan.Line
    ) -> Bool {
        switch (lhs.block, rhs.block) {
        case (.unorderedList, .unorderedList),
             (.orderedList, .orderedList):
            true
        default:
            false
        }
    }

    private static func isInlineCodeOnlyLine(
        _ line: AppKitPlan.Line
    ) -> Bool {
        guard case .paragraph = line.block,
              !line.runs.isEmpty
        else {
            return false
        }
        return line.runs.allSatisfy {
            $0.traits.contains(.inlineCode)
        }
    }

    private static func paragraphStyle(
        for block: AppKitPlan.Block,
        startsListBlock: Bool,
        startsInlineCodeLine: Bool,
        startsCodeBlock: Bool,
        endsCodeBlock: Bool
    ) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        switch block {
        case .heading:
            paragraph.paragraphSpacingBefore = 4
            paragraph.paragraphSpacing = 2
        case .subtext:
            paragraph.lineSpacing = 0
        case .quote:
            paragraph.firstLineHeadIndent = 12
            paragraph.headIndent = 12
        case .unorderedList, .orderedList:
            paragraph.firstLineHeadIndent = 2
            paragraph.headIndent = 20
            paragraph.minimumLineHeight = 26
            paragraph.maximumLineHeight = 26
            paragraph.paragraphSpacingBefore =
                startsListBlock ? 4 : 0
        case .code:
            paragraph.firstLineHeadIndent = 8
            paragraph.headIndent = 8
            paragraph.tailIndent = -8
            paragraph.minimumLineHeight = 18
            paragraph.maximumLineHeight = 18
            paragraph.paragraphSpacingBefore =
                startsCodeBlock ? 17 : 0
            paragraph.paragraphSpacing =
                endsCodeBlock ? 4 : 0
        case .paragraph:
            paragraph.paragraphSpacingBefore =
                startsInlineCodeLine ? 5 : 0
        }
        return paragraph
    }

    private static func blankParagraphStyle() -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 26
        paragraph.maximumLineHeight = 26
        return paragraph
    }

    private static func blockAttribute(
        for block: AppKitPlan.Block
    ) -> NSString? {
        switch block {
        case .quote: "quote"
        case .code: "code"
        default: nil
        }
    }
}

private extension DiscordMarkdown {
    static func isComposerSyntaxCharacter(_ character: Character) -> Bool {
        switch character {
        case "\\", "`", "[", "<", "*", "_", "~", "|", "h": true
        default: false
        }
    }

    static func isComposerDelimiterCharacter(_ character: Character) -> Bool {
        switch character {
        case "*", "_", "~", "|": true
        default: false
        }
    }

    struct MarkdownLinkTarget {
        let label: Range<String.Index>
        let url: URL
        let end: String.Index
    }

    /// Per-parse lookup table: unfinished syntax must not repeatedly search the
    /// remainder of the draft for the same closing bracket or backtick.
    final class SourceFormatCollector {
        let collect: (Range<String.Index>, AppKitPlan.InlineTraits, String) -> Void
        private var terminators: [Character: [String.Index]] = [:]

        init(source: String, collect: @escaping (Range<String.Index>, AppKitPlan.InlineTraits, String) -> Void) {
            self.collect = collect
            for index in source.indices {
                let character = source[index]
                switch character {
                case "]", ")", ">", "`": terminators[character, default: []].append(index)
                default: break
                }
            }
        }

        func next(_ character: Character, from start: String.Index, before end: String.Index) -> String.Index? {
            guard let indices = terminators[character] else { return nil }
            var lower = 0
            var upper = indices.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if indices[middle] < start { lower = middle + 1 } else { upper = middle }
            }
            guard lower < indices.count, indices[lower] < end else { return nil }
            return indices[lower]
        }
    }
}

private final class AppKitMarkdownRenderCache: @unchecked Sendable {
    private let values = NSCache<AppKitMarkdownCacheKey, NSAttributedString>()

    init() {
        values.countLimit = 2_000
        values.totalCostLimit = 12 * 1024 * 1024
    }

    func value(for source: String, baseFontSize: CGFloat) -> NSAttributedString? {
        values.object(
            forKey: AppKitMarkdownCacheKey(
                source: source,
                baseFontSize: baseFontSize
            )
        )
    }

    func insert(
        _ value: NSAttributedString,
        for source: String,
        baseFontSize: CGFloat
    ) {
        values.setObject(
            value,
            forKey: AppKitMarkdownCacheKey(
                source: source,
                baseFontSize: baseFontSize
            ),
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
        guard let other = object as? AppKitMarkdownCacheKey else {
            return false
        }
        return source == other.source && baseFontSize == other.baseFontSize
    }
}

public extension DiscordMarkdown {
    /// Discord invite cards are client-derived, including bare links and links inside angle brackets.
    /// Reuse the Markdown parser so code blocks and inline code never initiate preview requests.
    static func serverInviteReferences(in source: String) -> [ServerInviteReference] {
        guard source.contains("discord.gg/") || source.contains("discord.com/invite/")
                || source.contains("discordapp.com/invite/") else { return [] }
        var result: [ServerInviteReference] = []
        var seen: Set<String> = []
        for line in appKitPlan(source).lines {
            if case .code = line.block { continue }
            for run in line.runs where !run.traits.contains(.inlineCode) {
                let candidates = run.link.map { [$0.absoluteString] }
                    ?? run.text.components(separatedBy: .whitespacesAndNewlines)
                for candidate in candidates {
                    let candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                    guard candidate.contains("/"), let reference = ServerInviteReference(candidate),
                          seen.insert(reference.code).inserted else { continue }
                    result.append(reference)
                    if result.count == 10 { return result }
                }
            }
        }
        return result
    }

}
