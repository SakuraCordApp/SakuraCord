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
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }

    static func make(
        _ document: AttributedString, codeBackground: DiscordMarkdown.AppKitPlan.CodeBackground
    ) -> NSAttributedString {
        var leaves = MarkdownLeaf.leaves(of: document)
        let footnotes = MarkdownFootnotes.extract(from: &leaves)
        var layout = MarkdownBlockLayout(codeBackground: codeBackground)
        for leaf in leaves {
            layout.append(leaf)
        }
        footnotes.forEach { layout.append($0) }
        return layout.finish()
    }

    /// Scrolls to an in-document target, or opens any other link as a
    /// message link would be, which ignores local files and app schemes.
    static func activate(_ link: Any, in textView: NSTextView, at index: Int) -> Bool {
        guard let url = link as? URL else { return true }
        guard url.scheme == nil, url.host() == nil, url.path().isEmpty, let fragment = url.fragment(percentEncoded: false) else {
            return MessageLinkActivator.activate(
                url, model: nil,
                displayedText: MessageLinkActivator.safetyDisplayedText(in: textView.attributedString(), at: index)
            )
        }
        let text = textView.attributedString()
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
        case footnote(number: Int, label: String)
    }

    var kind: Kind
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
                if let replacement = html.apply(tag: text, font: MarkdownInlineStyle.font(for: leaves[index].kind)) {
                    leaves[index].content.append(replacement)
                }
            } else {
                let styled = NSMutableAttributedString(attributedString: MarkdownInlineStyle.styled(
                    inline.contains(.lineBreak) ? "\u{2028}" : text,
                    inline: inline, html: html, link: run.link, imageURL: run.imageURL,
                    font: MarkdownInlineStyle.font(for: leaves[index].kind)
                ))
                if inline.contains(.softBreak) {
                    styled.addAttribute(MarkdownFootnotes.lineStartKey, value: true, range: NSRange(location: 0, length: styled.length))
                }
                leaves[index].content.append(styled)
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
    /// Marks inline code, where footnote references aren't read.
    static let codeKey = NSAttributedString.Key("dev.sakuracord.markdown.document-code")
    static let bodySize: CGFloat = 13

    static func font(for kind: MarkdownLeaf.Kind) -> NSFont {
        switch kind {
        case let .heading(level):
            let sizes: [CGFloat] = [24, 19, 16, 14, 13, 12]
            return .interfaceSystemFont(ofSize: sizes[min(max(level, 1), 6) - 1], weight: .semibold)
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
        let isCode = inline.contains(.code) || html.isCode
        var traits: NSFontTraitMask = []
        if inline.contains(.stronglyEmphasized) || html.isBold { traits.insert(.boldFontMask) }
        if inline.contains(.emphasized) || html.isItalic { traits.insert(.italicFontMask) }
        var font = isCode
            ? NSFont.monospacedSystemFont(ofSize: base.pointSize * 0.9, weight: base.fontDescriptor.symbolicTraits.contains(.bold) ? .semibold : .regular)
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
        if isCode {
            attributes[.backgroundColor] = NSColor.tertiarySystemFill
            attributes[codeKey] = true
        }
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
        let output = NSMutableAttributedString(attachment: symbol("photo", font: attributes[.font] as? NSFont))
        output.append(NSAttributedString(string: " " + (alt.isEmpty ? url.lastPathComponent : alt)))
        output.addAttributes(attributes, range: NSRange(location: 0, length: output.length))
        return output
    }

    /// A symbol in the text, in palette colours ordered by its layers.
    static func symbol(_ name: String, font: NSFont?, colors: [NSColor] = [.secondaryLabelColor]) -> NSTextAttachment {
        let font = font ?? .interfaceSystemFont(ofSize: bodySize)
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
    private static let styledTags: Set = ["a", "b", "strong", "i", "em", "u", "ins", "s", "del", "strike", "code", "kbd", "sup", "sub", "mark"]
    private static let blockTags: Set = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr", "details", "summary", "ul", "ol", "table", "blockquote", "pre", "hr",
    ]

    var isBold: Bool { isOpen("b", "strong", "h1", "h2", "h3", "h4", "h5", "h6", "summary") }
    var isItalic: Bool { isOpen("i", "em") }
    var isUnderlined: Bool { isOpen("u", "ins") }
    var isStruck: Bool { isOpen("s", "del", "strike") }
    var isCode: Bool { isOpen("code", "kbd") }
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
        } else if Self.styledTags.contains(name) || Self.blockTags.contains(name) {
            open.append((name, name == "a" ? attributes["href"].flatMap(URL.init(string:)) : nil))
        }
        return nil
    }

    /// A raw HTML block as text: comments dropped, block tags as line
    /// breaks, whitespace collapsed and entities decoded.
    static func blockText(_ html: String, font: NSFont) -> NSMutableAttributedString {
        var state = MarkdownInlineHTML()
        let output = NSMutableAttributedString()
        func breakLine() {
            if output.length > 0, !output.string.hasSuffix("\u{2028}") { output.append(NSAttributedString(string: "\u{2028}")) }
        }
        var rest = Substring(html)
        while !rest.isEmpty {
            guard let tag = rest.firstMatch(of: /<!--[\s\S]*?-->|<[^>]+>/) else {
                output.append(text(rest, state: state, font: font))
                break
            }
            output.append(text(rest[..<tag.range.lowerBound], state: state, font: font))
            let source = String(tag.output)
            let name = source.firstMatch(of: /^<\s*\/?\s*([A-Za-z0-9]+)/)?.1.lowercased()
            if let name, blockTags.contains(name) { breakLine() }
            if !source.hasPrefix("<!--"), let replacement = state.apply(tag: source, font: font) {
                output.append(replacement)
            }
            rest = rest[tag.range.upperBound...]
        }
        while let last = output.string.unicodeScalars.last, last == "\u{2028}" || CharacterSet.whitespaces.contains(last) {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        while let first = output.string.unicodeScalars.first, first == "\u{2028}" || CharacterSet.whitespaces.contains(first) {
            output.deleteCharacters(in: NSRange(location: 0, length: 1))
        }
        return output
    }

    private static func text(_ raw: Substring, state: MarkdownInlineHTML, font: NSFont) -> NSAttributedString {
        let collapsed = String(raw.replacing(/\s+/, with: " "))
        guard !collapsed.isEmpty else { return NSAttributedString() }
        return MarkdownInlineStyle.styled(
            decodingEntities(collapsed), inline: [], html: state, link: nil, imageURL: nil, font: font
        )
    }

    private static func attributes(_ source: String) -> [String: String] {
        var attributes: [String: String] = [:]
        for match in source.matches(of: /([A-Za-z-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/) {
            attributes[match.1.lowercased()] = String(match.2 ?? match.3 ?? match.4 ?? "")
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
        var used: [String: Int] = [:]
        for index in leaves.indices {
            guard case .heading = leaves[index].kind else { continue }
            let slug = String(leaves[index].content.string.lowercased().compactMap { character -> Character? in
                if character == " " { return "-" }
                return character.isLetter || character.isNumber || character == "-" || character == "_" ? character : nil
            })
            let count = used[slug, default: 0]
            used[slug] = count + 1
            let anchor = count == 0 ? slug : "\(slug)-\(count)"
            leaves[index].content.addAttribute(.markdownAnchor, value: anchor, range: NSRange(location: 0, length: leaves[index].content.length))
        }
    }
}

/// GitHub's footnotes, which Foundation leaves as text: each `[^label]`
/// becomes a numbered link, and the definitions move to the end in the
/// order they're first referenced.
enum MarkdownFootnotes {
    static func extract(from leaves: inout [MarkdownLeaf]) -> [MarkdownLeaf] {
        var definitions: [String: NSMutableAttributedString] = [:]
        leaves.removeAll { leaf in
            guard leaf.kind == .paragraph, leaf.content.string.prefixMatch(of: definitionPrefix) != nil else { return false }
            for definition in definitionLines(leaf.content) {
                guard let match = definition.string.prefixMatch(of: definitionPrefix) else { continue }
                let label = String(match.1)
                definition.deleteCharacters(in: NSRange(match.range, in: definition.string))
                if definitions[label] == nil { definitions[label] = definition }
            }
            return true
        }
        guard !definitions.isEmpty else { return [] }

        let references = leaves.map { leaf in
            leaf.content.string.matches(of: /\[\^([^\]\s]+)\]/).compactMap { match -> (label: String, range: NSRange)? in
                let label = String(match.1)
                let range = NSRange(match.range, in: leaf.content.string)
                guard definitions[label] != nil,
                      leaf.content.attribute(MarkdownInlineStyle.codeKey, at: range.location, effectiveRange: nil) == nil
                else { return nil }
                return (label, range)
            }
        }
        var order: [String] = []
        for label in references.joined().map(\.label) where !order.contains(label) {
            order.append(label)
        }
        guard !order.isEmpty else { return [] }
        for (leaf, leafReferences) in zip(leaves, references) {
            for reference in leafReferences.reversed() {
                leaf.content.replaceCharacters(in: reference.range, with: Self.reference(
                    number: (order.firstIndex(of: reference.label) ?? 0) + 1, label: reference.label,
                    font: leaf.content.attribute(.font, at: reference.range.location, effectiveRange: nil) as? NSFont
                ))
            }
        }

        var footnotes = [MarkdownLeaf(kind: .thematicBreak, identity: Int.min, containers: [])]
        for (index, label) in order.enumerated() {
            var leaf = MarkdownLeaf(kind: .footnote(number: index + 1, label: label), identity: Int.min + index + 1, containers: [])
            leaf.content = definitions[label] ?? NSMutableAttributedString()
            let font = MarkdownInlineStyle.font(for: .paragraph)
            leaf.content.append(NSAttributedString(string: " ", attributes: [.font: font]))
            leaf.content.append(NSAttributedString(string: "↩", attributes: link(to: "fnref-" + label, [.font: font])))
            leaf.content.addAttribute(.markdownAnchor, value: "fn-" + label, range: NSRange(location: 0, length: leaf.content.length))
            footnotes.append(leaf)
        }
        return footnotes
    }

    /// Marks a soft line break, where a definition written on the next line starts.
    static let lineStartKey = NSAttributedString.Key("dev.sakuracord.markdown.soft-break")
    private static let definitionPrefix = /\[\^([^\]\s]+)\]:[ \t]*/

    /// Definitions on consecutive lines share one paragraph; each starts after a soft break.
    private static func definitionLines(_ paragraph: NSAttributedString) -> [NSMutableAttributedString] {
        let text = paragraph.string as NSString
        var lines: [NSMutableAttributedString] = []
        var start = 0
        paragraph.enumerateAttribute(lineStartKey, in: NSRange(location: 0, length: paragraph.length)) { value, range, _ in
            let next = NSMaxRange(range)
            guard value != nil, text.substring(from: next).prefixMatch(of: definitionPrefix) != nil else { return }
            lines.append(NSMutableAttributedString(attributedString: paragraph.attributedSubstring(from: NSRange(location: start, length: range.location - start))))
            start = next
        }
        lines.append(NSMutableAttributedString(attributedString: paragraph.attributedSubstring(from: NSRange(location: start, length: paragraph.length - start))))
        return lines
    }

    private static func reference(number: Int, label: String, font: NSFont?) -> NSAttributedString {
        let font = font ?? MarkdownInlineStyle.font(for: .paragraph)
        return NSAttributedString(string: "\(number)", attributes: link(to: "fn-" + label, [
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
