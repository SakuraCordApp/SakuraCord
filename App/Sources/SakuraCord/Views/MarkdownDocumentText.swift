import AppKit
import MessageRendering

extension NSAttributedString.Key {
    /// The name a `#` link in the same document scrolls to: a heading's
    /// GitHub-style slug or a footnote's.
    static let markdownAnchor = NSAttributedString.Key("dev.sakuracord.markdown.anchor")
}

/// A Markdown document, such as a `.md` file or the About pages, laid out the
/// way GitHub renders one. Foundation parses CommonMark with GitHub's tables
/// and strikethrough; this adds task lists, footnotes and common inline HTML,
/// and lays blocks out in text table cells, which need TextKit 1.
enum MarkdownDocumentText {
    nonisolated static func parse(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: MarkdownFootnotes.prepare(markdown), options: options))
            ?? AttributedString(markdown)
    }

    static func make(
        _ document: AttributedString, codeBackground: DiscordMarkdown.AppKitPlan.CodeBackground
    ) -> NSAttributedString {
        var leaves = MarkdownLeaf.leaves(of: document)
        let footnotes = MarkdownFootnotes.extract(from: &leaves)
        var layout = MarkdownBlockLayout(codeBackground: codeBackground, leaves: leaves + footnotes)
        for leaf in leaves {
            layout.append(leaf)
        }
        footnotes.forEach { layout.append($0) }
        return layout.finish()
    }

    /// A read-only view for documents. Their quotes, code blocks and tables
    /// are text table cells, which TextKit 1 lays out.
    static func makeTextView() -> NSTextView {
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.textContainer?.replaceLayoutManager(MarkdownLayoutManager())
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        // Discord underlines links only on hover.
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        return textView
    }

    /// Scrolls to an in-document target, or opens any other link as a
    /// message link would be, which ignores local files and app schemes.
    static func activate(_ link: Any, in textView: NSTextView, at index: Int) -> Bool {
        guard let url = link as? URL else { return true }
        return scrollToAnchor(url, in: textView) || MessageLinkActivator.activate(
            url, model: nil,
            displayedText: textView.textStorage.flatMap { MessageLinkActivator.safetyDisplayedText(in: $0, at: index) }
        )
    }

    /// Scrolls to the heading or footnote a `#` link names, returning
    /// whether the link was one.
    static func scrollToAnchor(_ link: Any, in textView: NSTextView) -> Bool {
        guard let url = link as? URL, url.scheme == nil, url.host() == nil, url.path().isEmpty,
              let fragment = url.fragment(percentEncoded: false)
        else { return false }
        guard let text = textView.textStorage else { return true }
        var target: NSRange?
        text.enumerateAttribute(.markdownAnchor, in: NSRange(location: 0, length: text.length)) { value, range, stop in
            guard let anchor = value as? String, anchor == fragment || anchor == fragment.lowercased() else { return }
            target = range
            stop.pointee = true
        }
        guard let target, let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            return true
        }
        let glyphs = layoutManager.glyphRange(forCharacterRange: target, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        textView.scroll(NSPoint(x: 0, y: max(0, rect.minY + textView.textContainerOrigin.y - InterfaceScale.metric(12))))
        textView.showFindIndicator(for: target)
        return true
    }
}

/// One paragraph-level piece of the document, with the blocks it sits in.
struct MarkdownLeaf {
    enum Kind: Equatable {
        case paragraph
        case heading(level: Int)
        case code(language: String?)
        case thematicBreak
        case tableCell(row: Int, column: Int)
        /// A footnote at the end of the document, which links back to its first reference.
        case footnote(number: Int)
    }

    let kind: Kind
    let identity: Int
    /// The containers around the leaf, outermost first.
    let containers: [PresentationIntent.IntentType]
    var content = NSMutableAttributedString()

    static func leaves(of document: AttributedString) -> [MarkdownLeaf] {
        var leaves: [MarkdownLeaf] = []
        var html = MarkdownInlineHTML()
        var syntheticIdentity = -1
        for run in document.runs {
            let text = String(document[run.range].characters)
            let inline = run.inlinePresentationIntent ?? []
            let components = run.presentationIntent?.components ?? []
            if inline.contains(.blockHTML) {
                // Raw HTML blocks carry only their containers, so each is its own paragraph.
                var leaf = MarkdownLeaf(kind: .paragraph, identity: syntheticIdentity, containers: components.reversed())
                syntheticIdentity -= 1
                leaf.content = MarkdownInlineHTML.blockText(text, font: MarkdownInlineStyle.font(for: .paragraph))
                if leaf.content.length > 0 { leaves.append(leaf) }
                continue
            }
            guard let leafIntent = components.first else { continue }
            if leaves.last?.identity != leafIntent.identity {
                html = MarkdownInlineHTML()
                leaves.append(MarkdownLeaf(
                    kind: kind(of: leafIntent, in: components),
                    identity: leafIntent.identity,
                    containers: components.dropFirst().reversed()
                ))
            }
            let index = leaves.count - 1
            if case .code = leaves[index].kind {
                leaves[index].content.mutableString.append(text)
            } else if inline.contains(.inlineHTML) {
                // Adjacent tags, such as `<b><i>`, arrive as one run.
                for tag in text.matches(of: /<[^>]+>/) {
                    if let replacement = html.apply(tag: String(tag.output), font: MarkdownInlineStyle.font(for: leaves[index].kind)) {
                        leaves[index].content.append(replacement)
                    }
                }
            } else {
                leaves[index].content.append(MarkdownInlineStyle.styled(
                    inline.contains(.lineBreak) ? "\u{2028}" : text,
                    inline: inline, html: html, link: run.link, imageURL: run.imageURL,
                    font: MarkdownInlineStyle.font(for: leaves[index].kind)
                ))
            }
        }
        MarkdownHeadingAnchors.assign(to: &leaves)
        return leaves
    }

    private static func kind(of leaf: PresentationIntent.IntentType, in components: [PresentationIntent.IntentType]) -> Kind {
        switch leaf.kind {
        case let .header(level): return .heading(level: level)
        case let .codeBlock(language): return .code(language: language)
        case .thematicBreak: return .thematicBreak
        case let .tableCell(column):
            let row = components.lazy.compactMap { component -> Int? in
                switch component.kind {
                case .tableHeaderRow: 0
                case let .tableRow(index): index
                default: nil
                }
            }.first ?? 0
            return .tableCell(row: row, column: column)
        default: return .paragraph
        }
    }
}

/// Fonts and inline attributes: emphasis, code, links, images and the inline HTML GitHub allows.
enum MarkdownInlineStyle {
    /// Marks inline and preformatted code, where footnote references aren't read.
    static let codeKey = NSAttributedString.Key("dev.sakuracord.markdown.document-code")
    static let bodySize = InterfaceTypographyMetrics.messageTextSize

    static func font(for kind: MarkdownLeaf.Kind) -> NSFont {
        switch kind {
        // Discord's three heading sizes; deeper levels read as its third.
        case let .heading(level):
            let scale: CGFloat = switch level {
            case 1: 1.5
            case 2: 1.25
            default: 1
            }
            return .interfaceSystemFont(ofSize: bodySize * scale, weight: .bold)
        case .tableCell(row: 0, _):
            return .interfaceSystemFont(ofSize: bodySize, weight: .semibold)
        default:
            return .interfaceSystemFont(ofSize: bodySize)
        }
    }

    static func styled(
        _ text: String, inline: InlinePresentationIntent, html: MarkdownInlineHTML,
        link: URL?, imageURL: URL?, font base: NSFont
    ) -> NSAttributedString {
        let isInlineCode = inline.contains(.code) || html.isCode
        var traits: NSFontTraitMask = []
        if inline.contains(.stronglyEmphasized) || html.isBold { traits.insert(.boldFontMask) }
        if inline.contains(.emphasized) || html.isItalic { traits.insert(.italicFontMask) }
        var font = isInlineCode || html.isPreformatted
            ? NSFont.monospacedSystemFont(ofSize: base.pointSize * 0.85, weight: base.fontDescriptor.symbolicTraits.contains(.bold) ? .semibold : .regular)
            : base
        if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }
        if html.baselineShift != 0 { font = NSFontManager.shared.convert(font, toSize: font.pointSize * 0.75) }

        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        if inline.contains(.strikethrough) || html.isStruck {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if html.isUnderlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if html.isMarked { attributes[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.35) }
        if html.baselineShift != 0 { attributes[.baselineOffset] = html.baselineShift * base.pointSize * 0.35 }
        if isInlineCode { attributes[.discordMarkdownInlineCode] = true }
        if isInlineCode || html.isPreformatted { attributes[codeKey] = true }
        if let link = link ?? html.link { attributes[.link] = link }
        guard let imageURL else { return NSAttributedString(string: text, attributes: attributes) }
        return image(alt: text, url: imageURL, attributes: attributes)
    }

    /// Images aren't fetched, since loading a stranger's file's images would
    /// reveal who opened it. An image shows as a link to itself, unless it
    /// already sits in a link such as a badge.
    static func image(alt: String, url: URL, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        var attributes = attributes
        if attributes[.link] == nil, ["http", "https"].contains(url.scheme?.lowercased()) {
            attributes[.link] = url
        }
        attributes[.foregroundColor] = NSColor.secondaryLabelColor
        let font = attributes[.font] as? NSFont ?? Self.font(for: .paragraph)
        let output = NSMutableAttributedString(attachment: symbol("photo", font: font))
        output.append(NSAttributedString(string: " " + (alt.isEmpty ? url.lastPathComponent : alt)))
        output.addAttributes(attributes, range: NSRange(location: 0, length: output.length))
        return output
    }

    /// A symbol in the text, in palette colours ordered by its layers.
    static func symbol(_ name: String, font: NSFont, colors: [NSColor] = [.secondaryLabelColor]) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        attachment.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular).applying(.init(paletteColors: colors)))
        if let size = attachment.image?.size {
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - size.height) / 2, width: size.width, height: size.height)
        }
        return attachment
    }
}

/// The inline HTML GitHub keeps: each tag styles the text after it until it closes.
struct MarkdownInlineHTML {
    private var open: [(name: String, link: URL?)] = []
    /// Tags whose styling applies to the text inside them.
    private static let styledTags: Set = [
        "a", "b", "strong", "i", "em", "u", "ins", "s", "del", "strike", "code", "kbd", "sup", "sub", "mark", "pre",
        "h1", "h2", "h3", "h4", "h5", "h6", "summary",
    ]
    private static let blockTags: Set = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr", "details", "summary", "ul", "ol", "table", "blockquote", "pre", "hr",
    ]

    var isBold: Bool { isOpen("b", "strong", "h1", "h2", "h3", "h4", "h5", "h6", "summary") }
    var isItalic: Bool { isOpen("i", "em") }
    var isUnderlined: Bool { isOpen("u", "ins") }
    var isStruck: Bool { isOpen("s", "del", "strike") }
    var isCode: Bool { isOpen("code", "kbd") }
    var isPreformatted: Bool { isOpen("pre") }
    var isMarked: Bool { isOpen("mark") }
    var link: URL? { open.last { $0.link != nil }?.link }
    var baselineShift: CGFloat {
        switch open.last(where: { $0.name == "sup" || $0.name == "sub" })?.name {
        case "sup": 1
        case "sub": -1
        default: 0
        }
    }

    private func isOpen(_ names: String...) -> Bool { open.contains { names.contains($0.name) } }

    /// Applies one tag, returning what it stands for in the text: a line
    /// break, or an image's placeholder.
    mutating func apply(tag: String, font: NSFont) -> NSAttributedString? {
        guard let match = tag.wholeMatch(of: /<\s*(\/?)\s*([A-Za-z][A-Za-z0-9]*)([^>]*?)\/?\s*>/) else { return nil }
        let name = match.2.lowercased()
        let attributes = Self.attributes(String(match.3))
        if name == "br" { return NSAttributedString(string: "\u{2028}") }
        if name == "img", let source = attributes["src"].flatMap(URL.init(string:)) {
            var imageAttributes: [NSAttributedString.Key: Any] = [.font: font]
            if let link { imageAttributes[.link] = link }
            return MarkdownInlineStyle.image(alt: attributes["alt"] ?? "", url: source, attributes: imageAttributes)
        }
        if !match.1.isEmpty {
            if let index = open.lastIndex(where: { $0.name == name }) { open.remove(at: index) }
        } else if Self.styledTags.contains(name) {
            open.append((name, name == "a" ? attributes["href"].flatMap(URL.init(string:)) : nil))
        }
        return nil
    }

    /// A raw HTML block as text: comments dropped, block tags as line
    /// breaks, whitespace collapsed outside `<pre>` and entities decoded.
    static func blockText(_ html: String, font: NSFont) -> NSMutableAttributedString {
        var state = MarkdownInlineHTML()
        let output = NSMutableAttributedString()
        var isAtLineStart: Bool { output.length == 0 || output.mutableString.hasSuffix("\u{2028}") }
        var rest = Substring(html)
        while !rest.isEmpty {
            let tag = rest.firstMatch(of: /<!--[\s\S]*?-->|<\/?[A-Za-z][^>]*>/)
            output.append(text(rest[..<(tag?.range.lowerBound ?? rest.endIndex)], state: state, isAtLineStart: isAtLineStart, font: font))
            guard let tag else { break }
            let source = String(tag.output)
            let name = source.firstMatch(of: /^<\/?([A-Za-z0-9]+)/)?.1.lowercased()
            if let name, blockTags.contains(name), !isAtLineStart { output.append(NSAttributedString(string: "\u{2028}")) }
            if !source.hasPrefix("<!--"), let replacement = state.apply(tag: source, font: font) {
                output.append(replacement)
            }
            rest = rest[tag.range.upperBound...]
        }
        while output.string.hasSuffix("\u{2028}") || output.string.hasSuffix(" ") {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        return output
    }

    /// Text between tags. Whitespace collapses as HTML's does, except in
    /// `<pre>`, which drops only the line break that opens it.
    private static func text(
        _ raw: Substring, state: MarkdownInlineHTML, isAtLineStart: Bool, font: NSFont
    ) -> NSAttributedString {
        var text = String(raw)
        if state.isPreformatted {
            if isAtLineStart, text.hasPrefix("\n") { text.removeFirst() }
            text = text.replacing("\n", with: "\u{2028}")
        } else {
            text = text.replacing(/\s+/, with: " ")
            if isAtLineStart, text.hasPrefix(" ") { text.removeFirst() }
        }
        guard !text.isEmpty else { return NSAttributedString() }
        return MarkdownInlineStyle.styled(
            decodingEntities(text), inline: [], html: state, link: nil, imageURL: nil, font: font
        )
    }

    private static func attributes(_ source: String) -> [String: String] {
        var attributes: [String: String] = [:]
        for match in source.matches(of: /([A-Za-z-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/) {
            attributes[match.1.lowercased()] = decodingEntities(String(match.2 ?? match.3 ?? match.4 ?? ""))
        }
        return attributes
    }

    private static let namedEntities = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®",
        "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "middot": "·", "bull": "•", "rarr": "→", "larr": "←",
    ]

    static func decodingEntities(_ text: String) -> String {
        text.replacing(/&(#[xX][0-9A-Fa-f]+|#[0-9]+|[A-Za-z]+);/) { match in
            let name = match.1
            if name.hasPrefix("#") {
                let isHex = name.dropFirst().first.map { $0 == "x" || $0 == "X" } ?? false
                let value = UInt32(isHex ? name.dropFirst(2) : name.dropFirst(), radix: isHex ? 16 : 10)
                return value.flatMap(Unicode.Scalar.init).map { String($0) } ?? String(match.0)
            }
            return namedEntities[String(name)] ?? String(match.0)
        }
    }
}

/// GitHub's heading slugs, which `#` links name.
enum MarkdownHeadingAnchors {
    static func assign(to leaves: inout [MarkdownLeaf]) {
        var used: Set<String> = []
        for index in leaves.indices {
            guard case .heading = leaves[index].kind else { continue }
            let slug = String(leaves[index].content.string.lowercased().compactMap { character -> Character? in
                if character == " " { return "-" }
                return character.isLetter || character.isNumber || character == "-" || character == "_" ? character : nil
            })
            // A repeat takes the next free suffix, so "Foo", "Foo", "Foo-1" are foo, foo-1, foo-1-1.
            var anchor = slug
            var suffix = 0
            while used.contains(anchor) {
                suffix += 1
                anchor = "\(slug)-\(suffix)"
            }
            used.insert(anchor)
            leaves[index].content.addAttribute(.markdownAnchor, value: anchor, range: NSRange(location: 0, length: leaves[index].content.length))
        }
    }
}

/// A fenced code block's opening or closing line: three or more backticks or tildes.
private struct MarkdownFence {
    private let marker: Character
    private let length: Int
    private let isBare: Bool

    /// Any fence sits after its quote markers; an opening one can also start
    /// a list item, as in "- ```md", which a closing one never does.
    nonisolated init?(_ line: String, isOpening: Bool) {
        let containers = isOpening
            ? line.prefixMatch(of: /(?: {0,3}(?:[-*+]|\d{1,9}[.)]) +| {0,3}> ?)*/)?.output.count
            : line.prefixMatch(of: /(?: {0,3}> ?)*/)?.output.count
        let rest = line.dropFirst(containers ?? 0)
        let indent = rest.prefix { $0 == " " }.count
        let trimmed = rest.dropFirst(indent)
        guard indent <= 3, let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let length = trimmed.prefix { $0 == marker }.count
        let info = trimmed.dropFirst(length)
        // A backtick in a backtick fence's info string makes the line inline code instead.
        guard length >= 3, marker == "~" || !info.contains("`") else { return nil }
        self.marker = marker
        self.length = length
        isBare = info.allSatisfy(\.isWhitespace)
    }

    /// A fence closes with the same character, at least as long, and nothing after it.
    nonisolated func closes(_ open: MarkdownFence) -> Bool {
        marker == open.marker && length >= open.length && isBare
    }
}

/// GitHub's footnotes, which Foundation leaves as text: each `[^label]`
/// becomes a numbered link, and the definitions move to the end in the
/// order they're first referenced.
enum MarkdownFootnotes {
    static func extract(from leaves: inout [MarkdownLeaf]) -> [MarkdownLeaf] {
        var definitions: [String: NSMutableAttributedString] = [:]
        leaves.removeAll { leaf in
            guard leaf.kind == .paragraph, let match = leaf.content.string.prefixMatch(of: definitionPrefix) else { return false }
            let label = String(match.1)
            leaf.content.deleteCharacters(in: NSRange(match.range, in: leaf.content.string))
            if definitions[label] == nil { definitions[label] = leaf.content }
            return true
        }
        guard !definitions.isEmpty else { return [] }

        let references = leaves.map { leaf -> [(label: String, range: NSRange)] in
            if case .code = leaf.kind { return [] }
            return leaf.content.string.matches(of: /\[\^([^\]\s]+)\]/).compactMap { match -> (label: String, range: NSRange)? in
                let label = String(match.1)
                let range = NSRange(match.range, in: leaf.content.string)
                guard definitions[label] != nil,
                      leaf.content.attribute(MarkdownInlineStyle.codeKey, at: range.location, effectiveRange: nil) == nil
                else { return nil }
                return (label, range)
            }
        }
        // Numbered in the order first referenced.
        var numbers: [String: Int] = [:]
        var referenced: [(label: String, definition: NSMutableAttributedString)] = []
        for reference in references.joined() where numbers[reference.label] == nil {
            guard let definition = definitions[reference.label] else { continue }
            referenced.append((reference.label, definition))
            numbers[reference.label] = referenced.count
        }
        guard !referenced.isEmpty else { return [] }
        for (leaf, leafReferences) in zip(leaves, references) {
            for reference in leafReferences.reversed() {
                let font = leaf.content.attribute(.font, at: reference.range.location, effectiveRange: nil) as? NSFont
                leaf.content.replaceCharacters(in: reference.range, with: Self.reference(
                    number: numbers[reference.label, default: 0], label: reference.label,
                    font: font ?? MarkdownInlineStyle.font(for: .paragraph)
                ))
            }
        }

        var footnotes = [MarkdownLeaf(kind: .thematicBreak, identity: Int.min, containers: [])]
        for (index, (label, definition)) in referenced.enumerated() {
            var leaf = MarkdownLeaf(kind: .footnote(number: index + 1), identity: Int.min + index + 1, containers: [])
            leaf.content = definition
            let font = MarkdownInlineStyle.font(for: .paragraph)
            leaf.content.append(NSAttributedString(string: " ", attributes: [.font: font]))
            leaf.content.append(NSAttributedString(string: "↩", attributes: link(to: "fnref-" + label, [.font: font])))
            leaf.content.addAttribute(.markdownAnchor, value: "fn-" + label, range: NSRange(location: 0, length: leaf.content.length))
            footnotes.append(leaf)
        }
        return footnotes
    }

    /// Marks a definition, so text that only looks like one stays as written.
    private nonisolated static let marker = "\u{2060}"
    private static let definitionPrefix = /\[\u{2060}\^([^\]\s]+)\]:[ \t]*/

    /// Readies definitions for Foundation, which would read `[^1]: https://…`
    /// as a link reference and hide it. Each definition becomes its own
    /// paragraph opening with an escaped, marked bracket, and an indented
    /// paragraph after it joins it as GitHub's do. Fenced code stays as written.
    nonisolated static func prepare(_ markdown: String) -> String {
        var lines: [String] = []
        var fence: MarkdownFence?
        var isInDefinition = false
        var hasPendingBlank = false
        // `\r\n` is one Character, so lines split on any newline, which also normalizes them.
        for line in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init) {
            if let open = fence {
                if MarkdownFence(line, isOpening: false)?.closes(open) == true { fence = nil }
                lines.append(line)
                continue
            }
            let isBlank = line.allSatisfy(\.isWhitespace)
            if isInDefinition, isBlank {
                hasPendingBlank = true
                continue
            }
            if isInDefinition, hasPendingBlank, line.hasPrefix("    ") || line.hasPrefix("\t") {
                lines[lines.count - 1] += "\\"
                lines.append(line.trimmingPrefix(while: \.isWhitespace).description)
                hasPendingBlank = false
                continue
            }
            if hasPendingBlank {
                // A blank line and an unindented one end the footnote.
                lines.append("")
                isInDefinition = false
            }
            hasPendingBlank = false
            if let opening = MarkdownFence(line, isOpening: true) {
                fence = opening
                isInDefinition = false
            } else if line.contains("[^"), line.prefixMatch(of: /^ {0,3}\[\^[^\]\s]+\]:/) != nil, let bracket = line.firstIndex(of: "[") {
                if !(lines.last?.allSatisfy(\.isWhitespace) ?? true) { lines.append("") }
                lines.append(line[..<bracket] + "\\[" + marker + line[line.index(after: bracket)...])
                isInDefinition = true
                continue
            } else if isBlank {
                isInDefinition = false
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private static func reference(number: Int, label: String, font: NSFont) -> NSAttributedString {
        NSAttributedString(string: "\(number)", attributes: link(to: "fn-" + label, [
            .font: NSFontManager.shared.convert(font, toSize: font.pointSize * 0.75),
            .baselineOffset: font.pointSize * 0.35,
            .markdownAnchor: "fnref-" + label,
        ]))
    }

    /// Adds a link to `#fragment`, percent-encoding the label.
    private static func link(to fragment: String, _ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var components = URLComponents()
        components.fragment = fragment
        var attributes = attributes
        attributes[.link] = components.url
        return attributes
    }
}
