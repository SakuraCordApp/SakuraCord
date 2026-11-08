import AppKit
import Foundation
import SakuraCordModels
import SwiftUI

public extension NSAttributedString.Key {
    /// Paragraph-level metadata consumed by the native timeline painter.
    static let discordMarkdownBlock = NSAttributedString.Key(
        "dev.sakuracord.markdown.block"
    )

    /// Marks spoiler text. The value is an NSNumber that identifies one
    /// spoiler, so adjacent spoilers such as `||a||||b||` stay separate
    /// attribute runs. Values are deterministic for the same source.
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

    /// Marks Markdown syntax in a draft's source, which an editor hides
    /// unless the caret is in or beside the span it formats. The value is an
    /// NSValue range: the character's offset into that span, and the span's
    /// length.
    static let discordMarkdownSyntax = NSAttributedString.Key(
        "dev.sakuracord.markdown.syntax"
    )

    /// One of Discord's CSS pixels at this text's size: its body font size
    /// over Discord's 16. Code blocks, quotes, and list markers carry it so
    /// the painter sizes their chrome with the text. An NSNumber.
    static let discordMarkdownEm = NSAttributedString.Key(
        "dev.sakuracord.markdown.em"
    )
}

public enum DiscordMarkdown {
    public struct AppKitPlan: Hashable, Sendable {
        public struct Line: Hashable, Sendable {
            fileprivate var runs: [InlineRun]
            fileprivate let block: Block
            /// Inside a `>` or `>>>` block quote, which can hold any
            /// non-code block, as in Discord.
            fileprivate var isQuoted = false
            /// The widest number in this item's ordered list, which sizes
            /// the gutter so every item's text shares one column.
            fileprivate var widestMarker = ""
        }

        fileprivate enum Block: Hashable, Sendable {
            case paragraph
            case heading(Int)
            case subtext
            /// A list item at its nesting depth, starting from zero.
            case listItem(level: Int, isOrdered: Bool)
            /// One line of a fenced block; `isFirstLine` separates adjacent fences.
            case code(language: String?, isFirstLine: Bool)
        }

        struct InlineRun: Hashable, Sendable {
            let text: String
            let traits: InlineTraits
            let link: URL?
            let color: SemanticColor?
            /// Identifies the spoiler containing this run by the line and UTF-8
            /// offset of its opening delimiter. Spoilers never nest, since each
            /// one closes at the nearest delimiter.
            var spoilerID: Int?
            /// A link written as <…>, which Discord never previews.
            var suppressesPreview = false
        }

        struct InlineTraits: OptionSet, Hashable, Sendable {
            let rawValue: UInt8

            static let bold = Self(rawValue: 1 << 0)
            static let italic = Self(rawValue: 1 << 1)
            static let underline = Self(rawValue: 1 << 2)
            static let strikethrough = Self(rawValue: 1 << 3)
            static let inlineCode = Self(rawValue: 1 << 4)
            static let spoiler = Self(rawValue: 1 << 5)
            static let listMarker = Self(rawValue: 1 << 6)
        }

        enum SemanticColor: Int, Hashable, Sendable {
            case jsonKey
            case jsonString
            case jsonNumber
            case jsonKeyword
            case codeKeyword
            case codeTitle
            case codeString
            case codeNumber
            case codeOperator
            case codeComment
        }

        /// What a file's code reads on when that isn't the appearance it is
        /// drawn in, as on the media viewer's panel inside its dark chrome.
        public enum CodeBackground: Hashable, Sendable {
            case dark
            case light
        }

        public let lines: [Line]
        /// Pins the code colours to that background; a message's own code
        /// follows the appearance it is drawn in.
        fileprivate let codeBackground: CodeBackground?

        fileprivate init(lines: [Line], codeBackground: CodeBackground? = nil) {
            self.lines = lines
            self.codeBackground = codeBackground
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
            guard !traits.isDisjoint(with: [.bold, .italic, .underline]), !traits.contains(.inlineCode) else { return }
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
        // Text after a fence that never closes is text, as Discord shows it.
        _ = inlineRuns(source[segmentStart...], inheritedTraits: [], inheritedLink: nil, sourceCollector: collector)
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

    /// A text file planned as one fenced block in `language`, so its lines are
    /// highlighted as a message's code block is, whatever fences it contains.
    public static func appKitCodePlan(
        _ source: String, language: String?, on background: AppKitPlan.CodeBackground
    ) -> AppKitPlan {
        let language = language?.lowercased()
        return AppKitPlan(lines: source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map {
            AppKitPlan.Line(
                runs: codeRuns(String($1), language: language),
                block: .code(language: language, isFirstLine: $0 == 0)
            )
        }, codeBackground: background)
    }

    public static func appKitPlan(_ source: String) -> AppKitPlan {
        var lines: [AppKitPlan.Line] = []
        var unclosedFence: String?
        var list = ListNesting()

        forEachSourceLine(source) { rawLine, kind in
            switch kind {
            case let .fence(opening):
                unclosedFence = opening
                list = ListNesting()
            case let .code(language, isFirstLine):
                lines.append(AppKitPlan.Line(
                    runs: codeRuns(String(rawLine), language: language),
                    block: .code(language: language, isFirstLine: isFirstLine)
                ))
            case let .text(content, isQuoted):
                if lines.last.map({ $0.isQuoted != isQuoted }) == true {
                    list = ListNesting()
                }
                var line = planLine(content, list: &list)
                line.isQuoted = isQuoted
                lines.append(line)
            }
        }

        // Discord shows the literal opening fence when a message never closes
        // it. Keep malformed input visible instead of silently discarding it.
        if let unclosedFence {
            let fence = AppKitPlan.Line(
                runs: [
                    AppKitPlan.InlineRun(
                        text: unclosedFence,
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

        alignOrderedMarkers(&lines)
        return AppKitPlan(lines: qualifyingSpoilerIDs(lines))
    }

    /// How message rendering reads one line of source.
    private enum SourceLine {
        /// A fence that opens a block, as its literal opening with the
        /// language, or that closes one.
        case fence(opening: String?)
        case code(language: String?, isFirstLine: Bool)
        /// Text after any quote prefix.
        case text(Substring, isQuoted: Bool)
    }

    private static func forEachSourceLine(_ source: String, _ body: (Substring, SourceLine) -> Void) {
        var codeLanguage: String?
        var isInCodeFence = false
        var startsCodeFence = false
        var isInMultilineQuote = false
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if rawLine.hasPrefix("```") {
                isInCodeFence.toggle()
                startsCodeFence = isInCodeFence
                let suffix = rawLine.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
                codeLanguage = isInCodeFence && !suffix.isEmpty ? suffix.lowercased() : nil
                body(rawLine, .fence(opening: isInCodeFence ? "```" + (codeLanguage ?? "") : nil))
            } else if isInCodeFence {
                body(rawLine, .code(language: codeLanguage, isFirstLine: startsCodeFence))
                startsCodeFence = false
            } else {
                // `>>>` quotes the rest of the message, blank lines included.
                var content = rawLine
                var isQuoted = isInMultilineQuote
                if !isQuoted, content.hasPrefix(">>> ") {
                    isInMultilineQuote = true
                    isQuoted = true
                    content = content.dropFirst(4)
                } else if !isQuoted, content.hasPrefix("> ") {
                    isQuoted = true
                    content = content.dropFirst(2)
                } else if !isQuoted, let quoted = quoteContent(content) {
                    isQuoted = true
                    content = quoted
                }
                body(rawLine, .text(content, isQuoted: isQuoted))
            }
        }
    }

    /// The text after a `>` quote marker that Swift reads as part of a
    /// larger character. Embed providers put invisible variation selectors
    /// beside the marker, which merge with it, so it is read by scalar. A line
    /// of only the marker and such spacers is a blank line inside the quote.
    /// A lone `>` is not a quote, as in Discord.
    private static func quoteContent(_ line: Substring) -> Substring? {
        let scalars = line.unicodeScalars
        guard scalars.first == ">" else { return nil }
        let marker = scalars.dropFirst()
        let rest = marker.drop { $0.properties.isDefaultIgnorableCodePoint }
        if rest.startIndex != marker.startIndex,
           rest.allSatisfy({ CharacterSet.whitespaces.contains($0) || $0.properties.isDefaultIgnorableCodePoint })
        {
            // Empty, but still a slice of the line: the source styler
            // measures syntax from the line's start to the content's.
            return line[line.endIndex...]
        }
        guard rest.first == " " else { return nil }
        return Substring(rest.dropFirst().drop { $0.properties.isDefaultIgnorableCodePoint })
    }

    /// Gives every item of an ordered list the list's widest marker. A list
    /// ends at a line that is not one of its items or nested beneath them.
    private static func alignOrderedMarkers(_ lines: inout [AppKitPlan.Line]) {
        var open: [Int: [Int]] = [:]
        func close(from level: Int) {
            for (listLevel, indices) in open where listLevel >= level {
                let widest = indices.map { lines[$0].runs[0].text }.max { $0.count < $1.count } ?? ""
                for index in indices {
                    lines[index].widestMarker = widest
                }
                open[listLevel] = nil
            }
        }
        for index in lines.indices {
            if index > 0, lines[index - 1].isQuoted != lines[index].isQuoted {
                close(from: 0)
            }
            guard case let .listItem(level, isOrdered) = lines[index].block else {
                close(from: 0)
                continue
            }
            close(from: level + 1)
            if isOrdered {
                open[level, default: []].append(index)
            }
        }
        close(from: 0)
    }

    /// `usesMessageLineHeight` gives paragraphs and list items Discord's
    /// message line height; embeds and previews keep natural lines.
    /// `reservesCodeCopyButton` ends a code block's first lines before the
    /// copy button the timeline shows in the block's top-trailing corner.
    public static func appKitAttributed(
        _ plan: AppKitPlan,
        baseFontSize: CGFloat = 15,
        usesMessageLineHeight: Bool = false,
        reservesCodeCopyButton: Bool = false
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let metrics = BlockMetrics(
            baseFontSize: baseFontSize,
            usesMessageLineHeight: usesMessageLineHeight,
            reservesCodeCopyButton: reservesCodeCopyButton,
            codeAppearance: plan.codeBackground.flatMap { NSAppearance(named: $0 == .light ? .aqua : .darkAqua) }
        )

        var previousParagraph: NSParagraphStyle?
        for (lineIndex, linePlan) in plan.lines.enumerated() {
            let paragraph = paragraphStyle(for: linePlan, index: lineIndex, in: plan.lines, metrics: metrics)
            if let previousParagraph {
                // An empty line is a paragraph of only its newline, which
                // then carries the line's height and spacing.
                let previous = plan.lines[lineIndex - 1]
                var separator: [NSAttributedString.Key: Any] = [:]
                // A break between quoted lines keeps one quote range.
                if previous.runs.isEmpty || previous.isQuoted && linePlan.isQuoted {
                    if previous.runs.isEmpty { separator[.font] = NSFont.systemFont(ofSize: baseFontSize) }
                    separator[.paragraphStyle] = previousParagraph
                    separator[.discordMarkdownBlock] = blockName(for: previous)
                    separator[.discordMarkdownEm] = NSNumber(value: metrics.em)
                }
                output.append(NSAttributedString(string: "\n", attributes: separator))
            }
            output.append(attributedLine(linePlan, paragraph: paragraph, metrics: metrics))
            previousParagraph = paragraph
        }

        return NSAttributedString(attributedString: output)
    }

    private static func attributedLine(
        _ linePlan: AppKitPlan.Line,
        paragraph: NSParagraphStyle,
        metrics: BlockMetrics
    ) -> NSAttributedString {
        let line = NSMutableAttributedString()
        for (index, run) in linePlan.runs.enumerated() {
            var text = run.text
            var runAttributes = attributes(for: run, in: linePlan, metrics: metrics)
            // Tab stops place the marker in Discord's list gutter and align
            // wrapped item text with its first line.
            if case let .listItem(_, isOrdered) = linePlan.block {
                if index == 0, isOrdered {
                    text = "\t" + text
                    runAttributes[.font] = metrics.orderedMarkerFont
                } else if index == 1 {
                    text = "\t"
                }
            }
            line.append(NSAttributedString(
                string: text,
                attributes: runAttributes
            ))
        }
        let fullRange = NSRange(location: 0, length: line.length)
        guard fullRange.length > 0 else { return line }
        line.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
        if let blockName = blockName(for: linePlan) {
            line.addAttribute(.discordMarkdownBlock, value: blockName, range: fullRange)
            line.addAttribute(.discordMarkdownEm, value: NSNumber(value: metrics.em), range: fullRange)
        }
        padInlineCode(in: line)
        return line
    }

    private static func blockName(for line: AppKitPlan.Line) -> NSString? {
        if case .code = line.block { return "code" }
        return line.isQuoted ? "quote" : nil
    }

    /// The room inline code's border takes on each side.
    public static func inlineCodePadding(font: NSFont) -> CGFloat {
        font.pointSize * 0.2 + 1
    }

    /// Discord pads inline code inside its border. Kerning after the
    /// preceding character and after the code reserves that padding, so the
    /// painted background never covers neighbouring text.
    public static func padInlineCode(in line: NSMutableAttributedString) {
        let source = line.string as NSString
        line.enumerateAttribute(
            .discordMarkdownInlineCode,
            in: NSRange(location: 0, length: line.length)
        ) { value, range, _ in
            guard value != nil, range.length > 0,
                  let font = line.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            else { return }
            let padding = inlineCodePadding(font: font)
            let last = source.rangeOfComposedCharacterSequence(at: NSMaxRange(range) - 1)
            line.addAttribute(.kern, value: padding, range: last)
            if range.location > 0 {
                let previous = source.rangeOfComposedCharacterSequence(at: range.location - 1)
                line.addAttribute(.kern, value: padding, range: previous)
            }
        }
    }

    private static func attributes(
        for run: AppKitPlan.InlineRun,
        in line: AppKitPlan.Line,
        metrics: BlockMetrics
    ) -> [NSAttributedString.Key: Any] {
        var color = foregroundColor(for: line, semanticColor: run.color)
        if let appearance = metrics.codeAppearance {
            appearance.performAsCurrentDrawingAppearance { color = NSColor(cgColor: color.cgColor) ?? color }
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: appKitFont(block: line.block, traits: run.traits, metrics: metrics),
            .foregroundColor: color,
        ]
        if run.traits.contains(.underline) {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if run.traits.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if run.traits.contains(.inlineCode) {
            attributes[.discordMarkdownInlineCode] = NSNumber(value: true)
        }
        if run.traits.contains(.listMarker), case let .listItem(level, _) = line.block {
            attributes[.discordMarkdownListMarker] = NSNumber(value: level)
            attributes[.discordMarkdownEm] = NSNumber(value: metrics.em)
            attributes[.foregroundColor] = NSColor.clear
        }
        if let link = run.link {
            attributes[.link] = link
            attributes[.foregroundColor] = NSColor.linkColor
        }
        if run.traits.contains(.spoiler) {
            attributes[.discordMarkdownSpoiler] = NSNumber(value: run.spoilerID ?? 0)
        }
        return attributes
    }

    /// The open lists above the current item, so items nest by indentation
    /// and keep the kind and numbering of the list they continue.
    private struct ListNesting {
        struct Level {
            let indentation: Int
            let isOrdered: Bool
            var nextNumber: Int
        }

        var levels: [Level] = []

        /// Discord renders a list with the first item's kind and numbers
        /// items consecutively from the first item's number.
        mutating func item(indentation: Int, number: Int?) -> (block: AppKitPlan.Block, marker: String) {
            while let last = levels.last, indentation < last.indentation {
                levels.removeLast()
            }
            if levels.last.map({ indentation > $0.indentation }) ?? true {
                levels.append(Level(indentation: indentation, isOrdered: number != nil, nextNumber: number ?? 1))
            }
            let index = levels.count - 1
            let level = levels[index]
            // Saturates, so a number such as `9223372036854775807.` cannot trap.
            levels[index].nextNumber = min(level.nextNumber, .max - 1) + 1
            return (
                .listItem(level: index, isOrdered: level.isOrdered),
                level.isOrdered ? "\(level.nextNumber)." : "•"
            )
        }
    }

    private static func planLine(_ source: Substring, list: inout ListNesting) -> AppKitPlan.Line {
        if let item = listItemContent(source) {
            let indentation = source.prefix { $0 == " " }.count
            let (block, marker) = list.item(indentation: indentation, number: item.number)
            let isBulleted = if case .listItem(_, false) = block { true } else { false }
            let runs = [
                AppKitPlan.InlineRun(
                    text: marker,
                    traits: isBulleted ? .listMarker : [],
                    link: nil,
                    color: nil
                ),
                AppKitPlan.InlineRun(text: " ", traits: [], link: nil, color: nil),
            ] + inlineRuns(item.content, inheritedTraits: [], inheritedLink: nil)
            return AppKitPlan.Line(runs: runs, block: block)
        }
        list = ListNesting()
        if let candidate = blockPrefixes.first(where: { source.hasPrefix($0.prefix) }) {
            return line(source.dropFirst(candidate.prefix.count), block: candidate.block)
        }
        return line(source, block: .paragraph)
    }

    private static let blockPrefixes: [(prefix: String, block: AppKitPlan.Block)] = [
        ("### ", .heading(3)), ("## ", .heading(2)), ("# ", .heading(1)), ("-# ", .subtext),
    ]

    private static func line(
        _ source: Substring,
        block: AppKitPlan.Block
    ) -> AppKitPlan.Line {
        AppKitPlan.Line(
            runs: inlineRuns(
                source,
                inheritedTraits: [],
                inheritedLink: nil
            ),
            block: block
        )
    }

    /// `- item`, `* item` or `1. item` after any indentation.
    private static func listItemContent(
        _ source: Substring
    ) -> (number: Int?, content: Substring)? {
        let marker = source.drop { $0 == " " }
        if marker.hasPrefix("- ") || marker.hasPrefix("* ") {
            return (nil, marker.dropFirst(2))
        }
        let digits = marker.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty,
              marker.dropFirst(digits.count).hasPrefix(". "),
              let number = Int(digits)
        else { return nil }
        return (number, marker.dropFirst(digits.count + 2))
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
                result.append(inlineCodeRun(
                    source[source.index(after: cursor) ..< close],
                    traits: inheritedTraits, link: inheritedLink, sourceCollector: sourceCollector
                ))
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
                sourceCollector?.collectLink?(source.index(after: cursor) ..< source.index(before: autolink.endIndex), autolink.endIndex)
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
                color: nil,
                suppressesPreview: true
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
        sourceCollector?.collectLink?(target.label, target.end)
        var runs = inlineRuns(
            source[target.label],
            inheritedTraits: inheritedTraits,
            inheritedLink: target.url,
            widgetRules: widgetRules,
            sourceCollector: sourceCollector
        )
        if target.suppressesPreview {
            for index in runs.indices where runs[index].link == target.url { runs[index].suppressesPreview = true }
        }
        return (runs, target.end)
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
            end: source.index(after: closingParenthesis),
            suppressesPreview: source[source.index(after: openingParenthesis)...].first == "<"
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
            // Message rendering retains its original delimiter matching exactly,
            // except that a spoiler, like Discord's `\|\|([\s\S]+?)\|\|`, holds at
            // least one character before its nearest closing delimiter.
            let isSpoiler = delimiter.traits.contains(.spoiler)
            let closingRange = if let sourceCollector, sourceCollector.matchesComposerDelimiters {
                composerClosingDelimiter(delimiter.marker, in: source, after: contentStart, collector: sourceCollector)
            } else if isSpoiler {
                contentStart < source.endIndex
                    ? source.range(
                        of: delimiter.marker,
                        range: source.index(after: contentStart) ..< source.endIndex
                    )
                    : nil
            } else {
                source.range(of: delimiter.marker, range: contentStart ..< source.endIndex)
            }
            guard contentStart <= source.endIndex,
                  let closingRange,
                  closingRange.lowerBound > contentStart
            else { continue }
            sourceCollector?.collect(contentStart ..< closingRange.lowerBound, inheritedTraits.union(delimiter.traits), delimiter.marker)
            var runs = inlineRuns(
                source[contentStart ..< closingRange.lowerBound],
                inheritedTraits: inheritedTraits.union(delimiter.traits),
                inheritedLink: inheritedLink,
                widgetRules: widgetRules,
                sourceCollector: sourceCollector
            )
            if isSpoiler {
                let spoilerID = source.base.utf8.distance(from: source.base.startIndex, to: cursor)
                for index in runs.indices {
                    runs[index].spoilerID = spoilerID
                }
            }
            return (runs, closingRange.upperBound)
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

    static func firstURL(
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

    /// Discord's block metrics, scaled from its 16 px body text to this
    /// text's base size: every length is Discord's CSS pixels times `em`.
    private struct BlockMetrics {
        let baseFontSize: CGFloat
        /// One of Discord's CSS pixels at this text's size.
        var em: CGFloat { baseFontSize / 16 }
        var listIndent: CGFloat { px(16) }
        var orderedMarkerGap: CGFloat { px(4) }
        var quoteIndent: CGFloat { px(16) }
        var codeInset: CGFloat { px(8) }
        /// Discord's 22 px line for 16 px message text, as a floor under
        /// paragraphs and list items; zero outside messages.
        let bodyLineHeight: CGFloat
        /// The empty line Discord leaves after a closing code fence.
        let emptyLineHeight: CGFloat
        /// Discord's 18 px code line.
        var codeLineHeight: CGFloat { px(18) }
        let reservesCodeCopyButton: Bool
        /// The appearance a pinned plan's colours resolve in.
        let codeAppearance: NSAppearance?
        /// Room at the end of a code block's first lines for the timeline's
        /// copy button: a square filling a one-line block less a 4 px inset,
        /// kept that inset from the block's edge.
        var codeCopyButtonReserve: CGFloat {
            reservesCodeCopyButton ? codeLineHeight + codeInset * 2 - px(4) : 0
        }

        init(
            baseFontSize: CGFloat, usesMessageLineHeight: Bool, reservesCodeCopyButton: Bool,
            codeAppearance: NSAppearance?
        ) {
            self.baseFontSize = baseFontSize
            self.reservesCodeCopyButton = reservesCodeCopyButton
            self.codeAppearance = codeAppearance
            let font = NSFont.systemFont(ofSize: baseFontSize)
            bodyLineHeight = usesMessageLineHeight ? baseFontSize / 16 * 22 : 0
            emptyLineHeight = usesMessageLineHeight
                ? bodyLineHeight
                : ceil(font.ascender - font.descender + font.leading) + 1
            orderedMarkerFont = .monospacedDigitSystemFont(ofSize: baseFontSize, weight: .regular)
        }

        func px(_ value: CGFloat) -> CGFloat { value * em }

        /// Tabular digits make a number's width follow its length, so the
        /// longest marker in a list is also the widest.
        let orderedMarkerFont: NSFont

        /// CSS margins: headings 16 above (8 when first) and 8 below, lists
        /// 4 around every item, code blocks 6 above their border.
        func margins(_ line: AppKitPlan.Line, isFirst: Bool) -> (top: CGFloat, bottom: CGFloat) {
            switch line.block {
            case .heading: (px(isFirst ? 8 : 16), px(8))
            case .listItem: (px(4), px(4))
            case .code: (px(6), 0)
            case .paragraph, .subtext: (0, 0)
            }
        }

        /// Space above a line: adjacent margins collapse as in CSS, quotes
        /// add 4 around themselves, and code text sits inside its padding.
        func spacingBefore(_ index: Int, in lines: [AppKitPlan.Line]) -> CGFloat {
            let line = lines[index]
            let isFirstCodeLine = if case .code(_, true) = line.block { true } else { false }
            let codeTop = isFirstCodeLine ? codeInset : 0
            guard index > 0 else {
                return max(margins(line, isFirst: true).top, line.isQuoted ? px(4) : 0) + codeTop
            }
            let previous = lines[index - 1]
            let quoteMargin = previous.isQuoted != line.isQuoted ? px(4) : 0
            if case .code = previous.block {
                if case .code(_, false) = line.block { return 0 }
                return codeInset + emptyLineHeight + max(margins(line, isFirst: false).top, quoteMargin) + codeTop
            }
            return max(
                margins(previous, isFirst: false).bottom,
                margins(line, isFirst: false).top,
                quoteMargin
            ) + codeTop
        }
    }

    private static func appKitFont(
        block: AppKitPlan.Block,
        traits: AppKitPlan.InlineTraits,
        metrics: BlockMetrics
    ) -> NSFont {
        let base = metrics.baseFontSize
        let (size, defaultWeight): (CGFloat, NSFont.Weight) = switch block {
        case .heading(1): (base * 1.5, .bold)
        case .heading(2): (base * 1.25, .bold)
        case .heading: (base, .bold)
        case .subtext, .code: (base * 0.875, .regular)
        case .paragraph, .listItem: (base, traits.contains(.bold) ? .semibold : .regular)
        }

        var font = if case .code = block {
            NSFont.monospacedSystemFont(
                ofSize: size,
                weight: traits.contains(.bold) ? .bold : defaultWeight
            )
        } else if traits.contains(.inlineCode) {
            NSFont.monospacedSystemFont(
                ofSize: size * 0.85,
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

    /// Discord's dark-theme code colours, each with a darker variant that
    /// keeps 4.5:1 contrast on the translucent code fill over the lightest
    /// and dimmest light-appearance backgrounds, bubbles included.
    private enum CodePalette {
        static let jsonKey = color(dark: 0x4FA1FA, light: 0x0A5AB4)
        static let jsonString = color(dark: 0xA3D187, light: 0x1A6A35)
        static let jsonNumber = color(dark: 0xF08F4F, light: 0x9A4100)
        static let jsonKeyword = color(dark: 0x73B8F5, light: 0x0A5AB4)
        static let keyword = color(dark: 0xF67774, light: 0xA8302A)
        static let title = color(dark: 0x8195FB, light: 0x3F4FC0)
        static let string = color(dark: 0x57AF74, light: 0x1A6A35)
        static let number = color(dark: 0xE18752, light: 0x9A4100)
        static let `operator` = color(dark: 0xFC8884, light: 0xA8302A)
        static let comment = color(dark: 0x888991, light: 0x5C5E66)

        private static func color(dark: UInt32, light: UInt32) -> NSColor {
            let dark = srgb(dark)
            let light = srgb(light)
            return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
        }

        private static func srgb(_ hex: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat(hex >> 16 & 0xFF) / 255,
                green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }

    private static func foregroundColor(
        for line: AppKitPlan.Line,
        semanticColor: AppKitPlan.SemanticColor?
    ) -> NSColor {
        switch semanticColor {
        case .jsonKey: CodePalette.jsonKey
        case .jsonString: CodePalette.jsonString
        case .jsonNumber: CodePalette.jsonNumber
        case .jsonKeyword: CodePalette.jsonKeyword
        case .codeKeyword: CodePalette.keyword
        case .codeTitle: CodePalette.title
        case .codeString: CodePalette.string
        case .codeNumber: CodePalette.number
        case .codeOperator: CodePalette.operator
        case .codeComment: CodePalette.comment
        case nil:
            switch line.block {
            case .subtext: NSColor.secondaryLabelColor
            case .heading: NSColor.labelColor
            // Quoted text, apart from headings, is slightly muted.
            default: line.isQuoted ? quotedTextColor : NSColor.labelColor
            }
        }
    }

    /// Label color at 0.7 alpha. Resolved per appearance when drawn, so a
    /// quote built in one appearance stays readable in the other.
    private static let quotedTextColor = NSColor(name: nil) { appearance in
        NSColor(
            white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 1 : 0,
            alpha: 0.7
        )
    }

    private static func paragraphStyle(
        for line: AppKitPlan.Line,
        index: Int,
        in lines: [AppKitPlan.Line],
        metrics: BlockMetrics
    ) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        // Discord's message lines sit one line height apart; elsewhere the
        // natural line gets a point of leading.
        paragraph.lineSpacing = metrics.bodyLineHeight > 0 ? 0 : 1
        paragraph.paragraphSpacingBefore = metrics.spacingBefore(index, in: lines)
        let indent = line.isQuoted ? metrics.quoteIndent : 0
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        switch line.block {
        case .subtext:
            paragraph.lineSpacing = 0
        case let .listItem(level, isOrdered):
            // Discord hangs wide numbers into the message margin; Core Text
            // cannot draw left of its frame, so the gutter grows instead.
            let markerWidth = isOrdered
                ? (line.widestMarker as NSString).size(withAttributes: [.font: metrics.orderedMarkerFont]).width
                : 0
            let gutter = max(metrics.listIndent, ceil(markerWidth) + metrics.orderedMarkerGap)
            let textIndent = indent + metrics.listIndent * CGFloat(level) + gutter
            paragraph.minimumLineHeight = metrics.bodyLineHeight
            paragraph.firstLineHeadIndent = textIndent - gutter
            paragraph.headIndent = textIndent
            paragraph.tabStops = (isOrdered
                ? [NSTextTab(textAlignment: .right, location: textIndent - metrics.orderedMarkerGap)]
                : []) + [NSTextTab(textAlignment: .left, location: textIndent)]
        case let .code(_, isFirstLine):
            paragraph.lineSpacing = 0
            paragraph.firstLineHeadIndent = metrics.codeInset
            paragraph.headIndent = metrics.codeInset
            // The copy button's square reaches into a block's second line,
            // so both of its first lines end before it.
            let isSecondLine = if index > 0, case .code(_, true) = lines[index - 1].block { true } else { false }
            paragraph.tailIndent = -metrics.codeInset - (isFirstLine || isSecondLine ? metrics.codeCopyButtonReserve : 0)
            // Discord sets code left to right in any script, which also keeps
            // that room at the end the button sits on.
            paragraph.baseWritingDirection = .leftToRight
            paragraph.minimumLineHeight = metrics.codeLineHeight
            paragraph.maximumLineHeight = metrics.codeLineHeight
        case .paragraph:
            paragraph.minimumLineHeight = metrics.bodyLineHeight
        case .heading:
            // Discord's headings keep its 1.375 line height at their own size.
            paragraph.minimumLineHeight = appKitFont(block: line.block, traits: [], metrics: metrics).pointSize * 1.375
        }
        // Inline code that opens a line has no preceding character to pad,
        // so the line itself starts inside the code's border.
        if line.runs.first?.traits.contains(.inlineCode) == true {
            let font = appKitFont(block: line.block, traits: .inlineCode, metrics: metrics)
            paragraph.firstLineHeadIndent += inlineCodePadding(font: font)
        }
        return paragraph
    }
}

extension DiscordMarkdown {
    /// Literal code ranges use the same delimiter rules as message rendering.
    static func sourceCodeRanges(_ source: String) -> [NSRange] {
        guard source.utf8.contains(96) else { return [] }
        var source = source
        source.makeContiguousUTF8()
        var ranges: [NSRange] = []
        let collector = SourceFormatCollector(source: source, matchesComposerDelimiters: false) { range, traits, _ in
            if traits.contains(.inlineCode) { ranges.append(NSRange(range, in: source)) }
        }
        var inCodeFence = false
        var inMultilineQuote = false
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                inCodeFence.toggle()
                ranges.append(NSRange(line.startIndex ..< line.endIndex, in: source))
            } else if inCodeFence {
                ranges.append(NSRange(line.startIndex ..< line.endIndex, in: source))
            } else {
                if line.isEmpty { inMultilineQuote = false }
                // planLine removes a list marker before parsing inline syntax;
                // multiline quote continuations instead retain their whole line.
                let content = line.hasPrefix("* ") && !inMultilineQuote ? line.dropFirst(2) : line
                _ = inlineRuns(content, inheritedTraits: [], inheritedLink: nil, sourceCollector: collector)
                if line.hasPrefix(">>> ") { inMultilineQuote = true }
            }
        }
        return ranges
    }
}

public extension DiscordMarkdown {
    /// `source` as an editor whose document stays Markdown shows it: every
    /// character kept, set in the fonts, colours and block metrics message
    /// rendering gives it. Its syntax is dimmed and marked with
    /// `discordMarkdownSyntax`, so an editor can hide it outside the span
    /// the caret is in. Plain paragraphs keep `attributes`, the editor's own
    /// style. A colour other than the label colour, as on an outgoing
    /// bubble, colours all of the text.
    static func appKitSourceAttributed(
        _ source: String,
        attributes: [NSAttributedString.Key: Any],
        baseFontSize: CGFloat,
        usesMessageLineHeight: Bool
    ) -> NSMutableAttributedString {
        var source = source
        source.makeContiguousUTF8()
        let text = NSMutableAttributedString(string: source, attributes: attributes)
        // No styled syntax can begin without one of these ASCII markers.
        guard source.utf8.contains(where: { "*_~|`[#><".utf8.contains($0) }) else { return text }
        // A message's code blocks keep room for the timeline's copy button.
        SourceStyler(source: source, text: text, attributes: attributes, metrics: BlockMetrics(
            baseFontSize: baseFontSize, usesMessageLineHeight: usesMessageLineHeight,
            reservesCodeCopyButton: usesMessageLineHeight, codeAppearance: nil
        )).run()
        return text
    }

    /// Styles a draft's source line by line with message rendering's own
    /// line reading, inline collector and metrics.
    private final class SourceStyler {
        let source: String
        let text: NSMutableAttributedString
        let metrics: BlockMetrics
        let plainParagraph: NSParagraphStyle
        let textColor: NSColor?
        let syntaxColor: NSColor
        /// The message's lines so far; fences are not lines once rendered.
        var lines: [AppKitPlan.Line] = []
        var line = AppKitPlan.Line(runs: [], block: .paragraph)
        var linkLabel: NSRange?
        var fences: [NSRange] = []
        /// Whether the previous source line was code, inside a fence.
        var followsCode = false
        /// The room a closing fence keeps for its block's bottom padding,
        /// which the next line's spacing then leaves out.
        var closingFenceHeight: CGFloat = 0

        init(source: String, text: NSMutableAttributedString, attributes: [NSAttributedString.Key: Any], metrics: BlockMetrics) {
            self.source = source
            self.text = text
            self.metrics = metrics
            plainParagraph = attributes[.paragraphStyle] as? NSParagraphStyle ?? .default
            textColor = (attributes[.foregroundColor] as? NSColor).flatMap { $0 == .labelColor ? nil : $0 }
            syntaxColor = textColor?.withAlphaComponent(0.72) ?? .secondaryLabelColor
        }

        func run() {
            // Delimiters pair as the composer's formatting does, nesting as
            // Discord does. Formats arrive parents first, so a nested format's
            // traits replace its parent's, and its delimiters are marked after
            // the parent's content.
            let collector = SourceFormatCollector(source: source) { [self] range, traits, delimiter in
                let content = NSRange(range, in: source)
                let width = delimiter.utf16.count
                let span = NSRange(location: content.location - width, length: content.length + 2 * width)
                style(content, as: traits)
                markSyntax(NSRange(location: span.location, length: width), of: span)
                markSyntax(NSRange(location: NSMaxRange(content), length: width), of: span)
            }
            collector.collectLink = { [self] label, end in
                let labelRange = NSRange(label, in: source)
                let span = NSRange(source.index(before: label.lowerBound) ..< end, in: source)
                linkLabel = labelRange
                text.addAttribute(.foregroundColor, value: NSColor.linkColor, range: labelRange)
                markSyntax(NSRange(location: span.location, length: 1), of: span)
                markSyntax(NSRange(location: NSMaxRange(labelRange), length: NSMaxRange(span) - NSMaxRange(labelRange)), of: span)
            }
            // Until its closing fence is typed, a code block is plain text, as
            // Discord shows it: the open fence literal and the lines after it
            // as text.
            var openFence: String.Index?
            for line in source.split(separator: "\n", omittingEmptySubsequences: false) where line.hasPrefix("```") {
                openFence = openFence == nil ? line.startIndex : nil
            }
            forEachSourceLine(source) { rawLine, kind in
                guard let openFence, rawLine.startIndex >= openFence else {
                    return styleLine(rawLine, kind: kind, collector: collector)
                }
                styleLine(rawLine, kind: .text(rawLine, isQuoted: false), collector: collector, isLiteral: rawLine.startIndex == openFence)
            }
            for fence in fences {
                markSyntax(fence, of: fence)
            }
            if let textColor {
                text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                    if value as? NSColor !== syntaxColor { text.addAttribute(.foregroundColor, value: textColor, range: range) }
                }
            }
        }

        /// A literal line is a plain paragraph with no syntax, as an open fence is.
        private func styleLine(_ rawLine: Substring, kind: SourceLine, collector: SourceFormatCollector, isLiteral: Bool = false) {
            let range = NSRange(rawLine.startIndex ..< rawLine.endIndex, in: source)
            // A paragraph's newline carries its paragraph's attributes.
            let paragraphRange = NSRange(location: range.location, length: min(range.length + 1, text.length - range.location))
            defer { followsCode = if case .code = kind { true } else { false } }
            switch kind {
            case let .fence(opening):
                fences.append(range)
                text.addAttribute(.font, value: appKitFont(block: .code(language: nil, isFirstLine: false), traits: [], metrics: metrics), range: range)
                // Hidden, a fence's line takes no room; message rendering
                // has no line for it.
                text.addAttribute(.discordMarkdownBlock, value: "fence" as NSString, range: paragraphRange)
                // Shown, a closing fence sits below its block's padding; an
                // empty block has none.
                guard opening == nil, followsCode else { return }
                closingFenceHeight = metrics.codeInset
                setParagraph(spacing: closingFenceHeight, for: paragraphRange)
                return
            case let .code(language, isFirstLine):
                line = AppKitPlan.Line(runs: codeRuns(String(rawLine), language: language), block: .code(language: language, isFirstLine: isFirstLine))
                style(range)
                var location = range.location
                for run in line.runs {
                    let length = run.text.utf16.count
                    if run.color != nil { style(NSRange(location: location, length: length), color: run.color) }
                    location += length
                }
            case .text where isLiteral:
                line = AppKitPlan.Line(runs: [], block: .paragraph)
            case let .text(content, isQuoted):
                let item = listItemContent(content)
                let prefix = item == nil ? blockPrefixes.first(where: { content.hasPrefix($0.prefix) }) : nil
                let body = item?.content ?? content.dropFirst(prefix?.prefix.count ?? 0)
                line = AppKitPlan.Line(runs: [], block: prefix?.block ?? .paragraph, isQuoted: isQuoted)
                if line.block != .paragraph || isQuoted { style(range) }
                // A list's marker reads as itself rather than as syntax.
                let syntax = NSRange(rawLine.startIndex ..< (item == nil ? body : content).startIndex, in: source)
                if syntax.length > 0 { markSyntax(syntax, of: syntax) }
                _ = inlineRuns(body, inheritedTraits: [], inheritedLink: nil, sourceCollector: collector)
            }
            lines.append(line)
            let spacing = metrics.spacingBefore(lines.count - 1, in: lines) - closingFenceHeight
            closingFenceHeight = 0
            let codeIndent = padInlineCode(in: range)
            if line.block == .paragraph, !line.isQuoted {
                setParagraph(spacing: spacing, firstLineIndent: codeIndent, for: paragraphRange)
            } else {
                let base = paragraphStyle(for: line, index: lines.count - 1, in: lines, metrics: metrics)
                setParagraph(base: base, spacing: spacing, firstLineIndent: codeIndent, for: paragraphRange)
            }
            if let blockName = blockName(for: line) {
                text.addAttributes([.discordMarkdownBlock: blockName, .discordMarkdownEm: NSNumber(value: metrics.em)], range: paragraphRange)
            }
        }

        private func style(_ range: NSRange, as traits: AppKitPlan.InlineTraits = [], color: AppKitPlan.SemanticColor? = nil) {
            let run = AppKitPlan.InlineRun(text: "", traits: traits, link: nil, color: color)
            text.addAttributes(attributes(for: run, in: line, metrics: metrics), range: range)
            // A format inside a link's label, which arrives right after the
            // link, keeps the link's colour.
            if let linkLabel, NSIntersectionRange(linkLabel, range).length > 0 {
                text.addAttribute(.foregroundColor, value: NSColor.linkColor, range: NSIntersectionRange(linkLabel, range))
            }
        }

        /// Each syntax character records its place in `span`, which stays
        /// the same as text before or after the span changes.
        private func markSyntax(_ range: NSRange, of span: NSRange) {
            text.addAttribute(.foregroundColor, value: syntaxColor, range: range)
            for index in range.location ..< NSMaxRange(range) {
                let place = NSRange(location: index - span.location, length: span.length)
                text.addAttribute(.discordMarkdownSyntax, value: NSValue(range: place), range: NSRange(location: index, length: 1))
            }
        }

        /// Sets `base`, or the plain style the text already has, with the
        /// line's spacing before it and its code indent.
        private func setParagraph(base: NSParagraphStyle? = nil, spacing: CGFloat, firstLineIndent: CGFloat = 0, for range: NSRange) {
            guard base != nil || spacing != 0 || firstLineIndent != 0 else { return }
            let paragraph = NSMutableParagraphStyle()
            paragraph.setParagraphStyle(base ?? plainParagraph)
            paragraph.paragraphSpacingBefore = spacing
            paragraph.firstLineHeadIndent += firstLineIndent
            text.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }

        /// Pads the line's inline code as message rendering does: after its
        /// last character, and before it on the last character shown ahead
        /// of it, since hidden syntax takes no room, or, when nothing is
        /// shown ahead of it on the line, by the indent returned.
        private func padInlineCode(in line: NSRange) -> CGFloat {
            var indent: CGFloat = 0
            let string = text.string as NSString
            text.enumerateAttribute(.discordMarkdownInlineCode, in: line) { value, range, _ in
                guard value != nil, let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
                let padding = inlineCodePadding(font: font)
                text.addAttribute(.kern, value: padding, range: string.rangeOfComposedCharacterSequence(at: NSMaxRange(range) - 1))
                var previous = range.location - 1
                while previous >= line.location, text.attribute(.discordMarkdownSyntax, at: previous, effectiveRange: nil) != nil {
                    previous -= 1
                }
                if previous < line.location {
                    indent = padding
                } else {
                    text.addAttribute(.kern, value: padding, range: string.rangeOfComposedCharacterSequence(at: previous))
                }
            }
            return indent
        }
    }
}

public extension DiscordMarkdown {
    /// Source that renders `text` literally: every ASCII punctuation mark is
    /// escaped, so no markdown, mention or emoji syntax survives. Bare URLs
    /// still link, as plain text does.
    static func escaped(_ text: String) -> String {
        text.reduce(into: "") { output, character in
            if character.isASCII, character.isPunctuation || character.isSymbol { output.append("\\") }
            output.append(character)
        }
    }
}

public extension DiscordMarkdown.AppKitPlan.Line {
    /// Headings keep their size where Discord shrinks the rest of the text,
    /// as inside a Components V2 container.
    var isHeading: Bool {
        if case .heading = block { true } else { false }
    }
}

private extension DiscordMarkdown {
    static func inlineCodeRun(
        _ source: Substring, traits: AppKitPlan.InlineTraits, link: URL?, sourceCollector: SourceFormatCollector?
    ) -> AppKitPlan.InlineRun {
        sourceCollector?.collect(source.startIndex ..< source.endIndex, traits.union(.inlineCode), "`")
        return AppKitPlan.InlineRun(text: String(source), traits: traits.union(.inlineCode), link: link, color: nil)
    }

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
        /// Written as [label](<url>), which Discord never previews.
        var suppressesPreview = false
    }

    /// Per-parse lookup table: unfinished syntax must not repeatedly search the
    /// remainder of the draft for the same closing bracket or backtick.
    final class SourceFormatCollector {
        let collect: (Range<String.Index>, AppKitPlan.InlineTraits, String) -> Void
        /// A masked link's label and the end of its target.
        var collectLink: ((Range<String.Index>, String.Index) -> Void)?
        let matchesComposerDelimiters: Bool
        private var terminators: [Character: [String.Index]] = [:]

        init(source: String, matchesComposerDelimiters: Bool = true, collect: @escaping (Range<String.Index>, AppKitPlan.InlineTraits, String) -> Void) {
            self.collect = collect
            self.matchesComposerDelimiters = matchesComposerDelimiters
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
    /// Visible emoji-bearing text for send-time usage tracking. Code and link
    /// destinations are not parsed as emoji by Discord's outgoing parser.
    static func emojiUsageText(in source: String) -> String {
        appKitPlan(source).lines.flatMap { line -> [String] in
            if case .code = line.block { return [] }
            return line.runs.filter { !$0.traits.contains(.inlineCode) }.map(\.text)
        }.joined(separator: " ")
    }

    /// Discord invite cards are client-derived, including bare links and links inside angle brackets.
    /// Code and spoiler text never initiate preview requests or expose invite cards.
    static func serverInviteReferences(in source: String) -> [ServerInviteReference] {
        guard source.contains("discord.gg/") || source.contains("discord.com/invite/")
                || source.contains("discordapp.com/invite/") else { return [] }
        var result: [ServerInviteReference] = []
        var seen: Set<String> = []
        for line in appKitPlan(source).lines {
            if case .code = line.block { continue }
            for run in line.runs where run.traits.isDisjoint(with: [.inlineCode, .spoiler]) {
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

public extension DiscordMarkdown {
    /// Spoiler identifiers start as offsets within a line. Qualify them by
    /// line so every spoiler in the message has its own identifier.
    fileprivate static func qualifyingSpoilerIDs(_ lines: [AppKitPlan.Line]) -> [AppKitPlan.Line] {
        var lines = lines
        for lineIndex in lines.indices
        where lines[lineIndex].runs.contains(where: { $0.spoilerID != nil }) {
            var runs = lines[lineIndex].runs
            for runIndex in runs.indices {
                runs[runIndex].spoilerID = runs[runIndex].spoilerID.map {
                    lineIndex << 32 | $0
                }
            }
            lines[lineIndex].runs = runs
        }
        return lines
    }

    /// Rendered text and whether it is inside a spoiler.
    struct PlainTextRun: Hashable, Sendable {
        public let text: String
        /// Identifies the spoiler containing the run, as the spoiler
        /// attribute does; adjacent spoilers have different identifiers.
        public let spoilerID: Int?

        public var isSpoiler: Bool { spoilerID != nil }
    }

    /// The rendered plain text, as ``attributed(_:)`` produces it, split into
    /// runs that record the spoiler state message rendering gives them.
    static func plainTextRuns(_ source: String) -> [PlainTextRun] {
        var result: [PlainTextRun] = []
        for (lineIndex, line) in appKitPlan(source).lines.enumerated() {
            if lineIndex > 0 {
                result.append(PlainTextRun(text: "\n", spoilerID: nil))
            }
            for run in line.runs {
                result.append(PlainTextRun(
                    text: run.text,
                    spoilerID: run.traits.contains(.spoiler) ? run.spoilerID ?? 0 : nil
                ))
            }
        }
        return result
    }

    /// A rendered link, whether all of its text is inside one spoiler, and
    /// whether it was written as <…>, which Discord never previews.
    struct LinkOccurrence: Hashable, Sendable {
        public let url: URL
        public let isSpoiler: Bool
        public let suppressesPreview: Bool
    }

    /// The links message rendering produces, in document order, with the
    /// spoiler state it gives them. Consecutive runs of one link are one
    /// occurrence, so adjacent links to the same URL merge, unless one was
    /// written as <…> and the other not: those are two links.
    static func linkOccurrences(_ source: String) -> [LinkOccurrence] {
        var result: [LinkOccurrence] = []
        for line in appKitPlan(source).lines {
            var previous: AppKitPlan.InlineRun?
            for run in line.runs {
                defer { previous = run }
                guard let link = run.link else { continue }
                let isSpoiler = run.traits.contains(.spoiler)
                if link == previous?.link, run.suppressesPreview == previous?.suppressesPreview,
                   let last = result.popLast() {
                    result.append(LinkOccurrence(
                        url: link,
                        isSpoiler: last.isSpoiler && isSpoiler
                            && run.spoilerID == previous?.spoilerID,
                        suppressesPreview: run.suppressesPreview
                    ))
                } else {
                    result.append(LinkOccurrence(url: link, isSpoiler: isSpoiler, suppressesPreview: run.suppressesPreview))
                }
            }
        }
        return result
    }
}
