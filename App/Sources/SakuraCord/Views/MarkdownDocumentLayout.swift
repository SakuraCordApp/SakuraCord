import AppKit
import MessageRendering

/// Lays a document's leaves out as paragraphs styled like Discord's message
/// Markdown, with its lengths in Discord's pixels. Table cells draw quotes,
/// code, rules and tables; every gap is spacing before a paragraph, or a
/// spacer line above the boxes it opens, so boxes have even padding.
struct MarkdownBlockLayout {
    let codeBackground: DiscordMarkdown.AppKitPlan.CodeBackground
    private let output = NSMutableAttributedString()
    private var blocks: [Int: NSTextBlock] = [:]
    private var startedItems: Set<Int> = []
    private var previous: MarkdownLeaf?
    private var previousBlocks: [NSTextBlock] = []
    private var openTable: OpenTable?
    /// Code left to highlight, past which blocks stay plain, as large text files do.
    private var highlightBudget = 128 * 1_024

    private struct OpenTable {
        let identity: Int
        let table: NSTextTable
        let outerBlocks: [NSTextBlock]
        var row: Int
        var column: Int
    }

    private static func px(_ value: CGFloat) -> CGFloat { DiscordRichMessageMetrics.px(value) }
    /// A blank line between paragraphs is one of Discord's 22 px lines.
    private static var paragraphGap: CGFloat { px(22) }
    private static var itemGap: CGFloat { px(4) }
    /// The largest number in each ordered list, and among the footnotes,
    /// so every item in a list leaves its widest marker the same room.
    private let widestOrdinals: [Int: Int]
    private let widestFootnote: Int

    /// Discord's list gutter. Ordered markers get room for two digits, and
    /// a list with wider numbers grows the gutter, as the timeline's does.
    private static func gutter(widestOrdinal: Int?) -> CGFloat {
        guard let widestOrdinal else { return px(16) }
        let marker = ("\(widestOrdinal)." as NSString).size(withAttributes: [.font: orderedMarkerFont]).width
        return max(px(24), ceil(marker) + px(4))
    }

    /// Tabular digits make a number's width follow its length.
    private static var orderedMarkerFont: NSFont {
        .interfaceMonospacedDigitSystemFont(ofSize: MarkdownInlineStyle.bodySize, weight: .regular)
    }

    init(codeBackground: DiscordMarkdown.AppKitPlan.CodeBackground, leaves: [MarkdownLeaf]) {
        self.codeBackground = codeBackground
        var ordinals: [Int: Int] = [:]
        var footnote = 0
        for leaf in leaves {
            if case let .footnote(number) = leaf.kind { footnote = max(footnote, number) }
            var list: Int?
            for container in leaf.containers {
                switch container.kind {
                case .orderedList: list = container.identity
                case .unorderedList: list = nil
                case let .listItem(ordinal): if let list { ordinals[list] = max(ordinals[list] ?? 0, ordinal) }
                default: break
                }
            }
        }
        widestOrdinals = ordinals
        widestFootnote = footnote
    }

    /// Where a leaf sits: the boxes its quotes open, its list indent, and
    /// the marker it starts its list item with.
    private struct Placement {
        var textBlocks: [NSTextBlock] = []
        var indent: CGFloat = 0
        var markerIndent: CGFloat = 0
        var marker: NSAttributedString?
        var isQuoted = false
    }

    mutating func append(_ leaf: MarkdownLeaf) {
        let tableIntent = leaf.containers.first { if case .table = $0.kind { true } else { false } }
        if openTable?.identity != tableIntent?.identity { closeTable() }

        var placement = placement(in: leaf.containers)
        let opensBox = switch leaf.kind {
        case .code, .thematicBreak: true
        case .tableCell: openTable == nil
        default: false
        }
        let spacingBefore = spacing(before: leaf, in: placement, opensBox: opensBox)
        if opensBox, placement.marker != nil {
            // A box can't hold its list item's marker, so the marker takes the line above it.
            emit(NSAttributedString(), placement: placement, font: MarkdownInlineStyle.font(for: .paragraph), spacingBefore: 0)
            placement.marker = nil
            emitSpacer(Self.itemGap, blocks: placement.textBlocks)
        }
        let content = leaf.content
        var font = MarkdownInlineStyle.font(for: leaf.kind)
        var lineHeight = Self.px(22)
        var alignment = NSTextAlignment.natural
        switch leaf.kind {
        case .paragraph:
            if placement.marker != nil, let checkbox = Self.taskCheckbox(in: content) { placement.marker = checkbox }
        case .heading:
            break
        case let .code(language):
            let box = block(leaf.identity) { Self.codeBlock(margin: placement.indent) }
            placement.textBlocks.append(box)
            placement.indent = 0
            font = .monospacedSystemFont(ofSize: InterfaceScale.fontSize(MarkdownInlineStyle.bodySize * 14 / 16), weight: .regular)
            lineHeight = Self.px(18)
            content.setAttributedString(highlighted(content.string, language: language, font: font))
        case .thematicBreak:
            let box = block(leaf.identity) { Self.ruleBlock(margin: placement.indent) }
            placement.textBlocks.append(box)
            placement.indent = 0
            // The rule is the box's edge, not Foundation's "⸻" text.
            content.setAttributedString(NSAttributedString())
            font = .systemFont(ofSize: 1)
            lineHeight = 0
        case let .tableCell(row, column):
            guard let tableIntent, let cell = tableCell(
                in: tableIntent, row: row, column: column, outerBlocks: placement.textBlocks, indent: placement.indent
            ) else { return }
            alignment = cell.alignment
            placement.textBlocks.append(cell.block)
            placement.indent = 0
        case let .footnote(number):
            placement.marker = Self.listMarker(ordinal: number, isOrdered: true, depth: 1, isQuoted: false)
            placement.markerIndent = placement.indent
            placement.indent += Self.gutter(widestOrdinal: widestFootnote)
        }
        DiscordMarkdown.padInlineCode(in: content)

        emit(content, placement: placement, font: font, alignment: alignment, spacingBefore: spacingBefore, lineHeight: lineHeight)
        previous = leaf
    }

    private mutating func emit(
        _ content: NSAttributedString, placement: Placement, font: NSFont, alignment: NSTextAlignment = .natural,
        spacingBefore: CGFloat, lineHeight: CGFloat = px(22)
    ) {
        let style = NSMutableParagraphStyle()
        style.textBlocks = placement.textBlocks
        style.alignment = alignment
        // Discord's line height is a floor, which taller headings exceed.
        style.minimumLineHeight = lineHeight
        style.paragraphSpacingBefore = spacingBefore
        style.firstLineHeadIndent = placement.marker == nil ? placement.indent : placement.markerIndent
        style.headIndent = placement.indent
        // Inline code that opens a paragraph has no preceding character to
        // pad, so the line itself starts inside the code's border.
        if placement.marker == nil, content.length > 0, content.attribute(.discordMarkdownInlineCode, at: 0, effectiveRange: nil) != nil,
           let codeFont = content.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            style.firstLineHeadIndent += DiscordMarkdown.inlineCodePadding(font: codeFont)
        }
        if placement.marker != nil {
            style.tabStops = [
                NSTextTab(textAlignment: .right, location: placement.indent - Self.px(4)),
                NSTextTab(textAlignment: .left, location: placement.indent),
            ]
        }

        let start = output.length
        if let marker = placement.marker {
            output.append(NSAttributedString(string: "\t", attributes: [.font: font]))
            output.append(marker)
            output.append(NSAttributedString(string: "\t", attributes: [.font: font]))
        }
        output.append(content)
        output.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        output.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: output.length - start))
        previousBlocks = placement.textBlocks
    }

    private mutating func placement(in containers: [PresentationIntent.IntentType]) -> Placement {
        var placement = Placement()
        var widestOrdinal: Int?
        var listDepth = 0
        for container in containers {
            switch container.kind {
            case .blockQuote:
                let box = block(container.identity) { [margin = placement.indent] in Self.quoteBlock(margin: margin) }
                placement.textBlocks.append(box)
                placement.indent = 0
                placement.isQuoted = true
            case .orderedList, .unorderedList:
                widestOrdinal = container.kind == .orderedList ? widestOrdinals[container.identity] : nil
                listDepth += 1
            case let .listItem(ordinal):
                placement.markerIndent = placement.indent
                placement.indent += Self.gutter(widestOrdinal: widestOrdinal)
                placement.marker = startedItems.insert(container.identity).inserted
                    ? Self.listMarker(ordinal: ordinal, isOrdered: widestOrdinal != nil, depth: listDepth, isQuoted: placement.isQuoted)
                    : nil
            default:
                break
            }
        }
        return placement
    }

    mutating func finish() -> NSAttributedString {
        closeTable()
        // An empty last paragraph, such as a table's empty last cell, is only its newline.
        if output.string.hasSuffix("\n"), !output.string.hasSuffix("\n\n") {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        return output
    }

    /// The gap before a leaf. Above a box that opens here, a spacer line
    /// outside it holds the gap instead: spacing inside the box would pad
    /// it, and a box's top margin also narrows it.
    private func spacing(before leaf: MarkdownLeaf, in placement: Placement, opensBox: Bool) -> CGFloat {
        guard let previous else { return 0 }
        let gap: CGFloat = switch (leaf.kind, previous.kind) {
        case (.tableCell, .tableCell) where !opensBox: 0
        // Discord sets headings 16 px below what precedes them and 8 px above what follows.
        case (.heading, _): Self.px(16)
        case (_, .heading): Self.px(8)
        case (.footnote, .footnote): Self.itemGap
        default:
            placement.marker != nil && previous.containers.contains { if case .listItem = $0.kind { true } else { false } }
                ? Self.itemGap : Self.paragraphGap
        }
        let firstOpened = placement.textBlocks.firstIndex { block in !previousBlocks.contains { $0 === block } }
        guard opensBox || firstOpened != nil else { return gap }
        emitSpacer(gap, blocks: Array(placement.textBlocks[..<(firstOpened ?? placement.textBlocks.count)]))
        return 0
    }

    private func emitSpacer(_ height: CGFloat, blocks: [NSTextBlock]) {
        guard height > 0 else { return }
        let style = NSMutableParagraphStyle()
        style.textBlocks = blocks
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        output.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 1), .paragraphStyle: style]))
    }

    private mutating func block(_ identity: Int, make: () -> NSTextBlock) -> NSTextBlock {
        if let block = blocks[identity] { return block }
        let block = make()
        blocks[identity] = block
        return block
    }

    // MARK: Tables

    private mutating func tableCell(
        in intent: PresentationIntent.IntentType, row: Int, column: Int, outerBlocks: [NSTextBlock], indent: CGFloat
    ) -> (block: NSTextTableBlock, alignment: NSTextAlignment)? {
        guard case let .table(columns) = intent.kind, column < columns.count else { return nil }
        if openTable == nil {
            let table = NSTextTable()
            table.numberOfColumns = columns.count
            table.collapsesBorders = true
            table.hidesEmptyCells = false
            table.setWidth(indent, type: .absoluteValueType, for: .margin, edge: .minX)
            openTable = OpenTable(identity: intent.identity, table: table, outerBlocks: outerBlocks, row: 0, column: -1)
        }
        fillTable(before: (row, column))
        guard var open = openTable else { return nil }
        (open.row, open.column) = (row, column)
        openTable = open
        let alignment: NSTextAlignment = switch columns[column].alignment {
        case .center: .center
        case .right: .right
        default: .natural
        }
        return (Self.cellBlock(open.table, row: row, column: column), alignment)
    }

    /// Ends the open table, filling its last row.
    private mutating func closeTable() {
        guard let openTable else { return }
        fillTable(before: (openTable.row + 1, 0))
        self.openTable = nil
    }

    /// Foundation leaves out empty cells, which still need their borders, so
    /// this adds every cell from the last one written up to `cell`.
    private mutating func fillTable(before cell: (row: Int, column: Int)) {
        guard var table = openTable else { return }
        let columns = table.table.numberOfColumns
        func position(after cell: (row: Int, column: Int)) -> (row: Int, column: Int) {
            cell.column + 1 < columns ? (cell.row, cell.column + 1) : (cell.row + 1, 0)
        }
        var next = position(after: (table.row, table.column))
        while next < cell {
            let style = NSMutableParagraphStyle()
            style.textBlocks = table.outerBlocks + [Self.cellBlock(table.table, row: next.row, column: next.column)]
            output.append(NSAttributedString(string: "\n", attributes: [
                .font: MarkdownInlineStyle.font(for: .paragraph), .paragraphStyle: style,
            ]))
            (table.row, table.column) = next
            next = position(after: next)
        }
        openTable = table
    }

    /// Discord has no tables, so they take its code blocks' tint and outline.
    private static func cellBlock(_ table: NSTextTable, row: Int, column: Int) -> NSTextTableBlock {
        let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
        cell.setWidth(1, type: .absoluteValueType, for: .border)
        cell.setBorderColor(NativeTimelineRowPainter.discordCodeBorderColor)
        for edge in [NSRectEdge.minX, .maxX] {
            cell.setWidth(px(8), type: .absoluteValueType, for: .padding, edge: edge)
        }
        for edge in [NSRectEdge.minY, .maxY] {
            cell.setWidth(px(4), type: .absoluteValueType, for: .padding, edge: edge)
        }
        if row == 0 { cell.backgroundColor = NativeTimelineRowPainter.discordCodeBackgroundColor }
        return cell
    }

    // MARK: Blocks and markers

    /// A one-cell table to hold a box, standing in for a plain text block,
    /// which collapses to a sliver when first laid out before the view has a width.
    private static func boxTable(margin: CGFloat) -> NSTextTable {
        let table = NSTextTable()
        table.numberOfColumns = 1
        // Automatic layout fits a box to its text; a box fills the line, as in the timeline.
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.setContentWidth(100, type: .percentageValueType)
        table.setWidth(margin, type: .absoluteValueType, for: .margin, edge: .minX)
        return table
    }

    /// Discord's quote: its text starts 16 px after the bar's edge.
    private static func quoteBlock(margin: CGFloat) -> NSTextBlock {
        let block = MarkdownQuoteBox(table: boxTable(margin: margin), startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        block.setWidth(px(16), type: .absoluteValueType, for: .padding, edge: .minX)
        return block
    }

    /// Discord's code block, padded 8 px inside its outline.
    private static func codeBlock(margin: CGFloat) -> NSTextBlock {
        let block = MarkdownCodeBox(table: boxTable(margin: margin), startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        block.setWidth(px(8) + 1, type: .absoluteValueType, for: .padding)
        return block
    }

    private static func ruleBlock(margin: CGFloat) -> NSTextBlock {
        let block = NSTextTableBlock(table: boxTable(margin: margin), startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        block.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
        block.setBorderColor(.separatorColor, for: .minY)
        return block
    }

    /// Discord's markers: tabular numbers, or a 5.5 px disc centred 12 px
    /// before the item's text, hollow once nested.
    private static func listMarker(ordinal: Int, isOrdered: Bool, depth: Int, isQuoted: Bool) -> NSAttributedString {
        let color = isQuoted ? NSColor.secondaryLabelColor : .labelColor
        guard !isOrdered else {
            return NSAttributedString(string: "\(ordinal).", attributes: [.font: orderedMarkerFont, .foregroundColor: color])
        }
        let diameter = px(5.5)
        // The image runs from the disc to the 4 px before the text where markers end.
        let size = NSSize(width: px(8) + diameter / 2, height: diameter)
        let isHollow = depth > 1
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: size, flipped: false) { _ in
            let disc = NSRect(x: 0, y: 0, width: diameter, height: diameter)
            color.set()
            if isHollow {
                let ring = NSBezierPath(ovalIn: disc.insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 1
                ring.stroke()
            } else {
                NSBezierPath(ovalIn: disc).fill()
            }
            return true
        }
        attachment.bounds = CGRect(origin: CGPoint(x: 0, y: (MarkdownInlineStyle.font(for: .paragraph).xHeight - diameter) / 2), size: size)
        return NSAttributedString(attachment: attachment)
    }

    /// GitHub's task list: `[ ]` or `[x]` opening an item becomes its marker.
    private static func taskCheckbox(in content: NSMutableAttributedString) -> NSAttributedString? {
        let text = content.string
        guard text.count > 3, text.hasPrefix("[ ] ") || text.lowercased().hasPrefix("[x] "),
              content.attribute(MarkdownInlineStyle.codeKey, at: 0, effectiveRange: nil) == nil
        else { return nil }
        let isDone = text.lowercased().hasPrefix("[x]")
        content.deleteCharacters(in: NSRange(location: 0, length: 4))
        // Sized to fit the list gutter before the 4 px gap to the text.
        return NSAttributedString(attachment: MarkdownInlineStyle.symbol(
            isDone ? "checkmark.square.fill" : "square", font: .systemFont(ofSize: px(10)),
            colors: isDone ? [.white, .controlAccentColor] : [.secondaryLabelColor]
        ))
    }

    /// Highlights code as a message's code block is, at message text size.
    private mutating func highlighted(_ code: String, language: String?, font: NSFont) -> NSAttributedString {
        let code = code.hasSuffix("\n") ? String(code.dropLast()) : code
        highlightBudget -= code.utf8.count
        guard highlightBudget >= 0 else {
            return NSAttributedString(string: code, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        }
        return NativeTimelineCoreText.scaledMarkdown(
            DiscordMarkdown.appKitCodePlan(code, language: language, on: codeBackground),
            baseFontSize: InterfaceScale.fontSize(MarkdownInlineStyle.bodySize)
        )
    }
}

/// A code block drawn as the timeline draws one: tinted, outlined and rounded.
nonisolated final class MarkdownCodeBox: NSTextTableBlock {
    override func drawBackground(
        withFrame frameRect: NSRect, in controlView: NSView?, characterRange charRange: NSRange, layoutManager: NSLayoutManager
    ) {
        // AppKit draws text on the main thread.
        MainActor.assumeIsolated { NativeTimelineRowPainter.drawCodeChrome(in: frameRect) }
    }
}

/// A quote drawn as the timeline draws one: a rounded 4 px bar beside it.
nonisolated final class MarkdownQuoteBox: NSTextTableBlock {
    override func drawBackground(
        withFrame frameRect: NSRect, in controlView: NSView?, characterRange charRange: NSRange, layoutManager: NSLayoutManager
    ) {
        let bar = NSRect(x: frameRect.minX, y: frameRect.minY, width: DiscordRichMessageMetrics.px(4), height: frameRect.height)
        MainActor.assumeIsolated { NativeTimelineRowPainter.drawQuoteBar(in: bar) }
    }
}

/// Draws inline code's chrome behind its glyphs, which a text view's
/// square background colour can't round or outline.
nonisolated class MarkdownLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        let rects = rects(of: .discordMarkdownInlineCode, forGlyphRange: glyphsToShow, padding: DiscordMarkdown.inlineCodePadding)
            .map { $0.offsetBy(dx: origin.x, dy: origin.y) }
        guard !rects.isEmpty else { return }
        // AppKit draws text on the main thread.
        MainActor.assumeIsolated { rects.forEach(NativeTimelineRowPainter.drawCodeChrome(in:)) }
    }

    /// Each line's run of text marked with `key`, as tall as its line, as the
    /// timeline draws inline code, and as wide as its glyphs plus the padding
    /// for its font. Room before the run is reserved mid-line and at a
    /// paragraph's start, but not on a wrapped line, so there the run's rect
    /// starts at its glyphs.
    func rects(of key: NSAttributedString.Key, forGlyphRange glyphsToShow: NSRange, padding: (NSFont) -> CGFloat = { _ in 0 }) -> [NSRect] {
        guard let textStorage else { return [] }
        var rects: [NSRect] = []
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        textStorage.enumerateAttribute(key, in: characters) { value, range, _ in
            guard value != nil, let font = textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return }
            let padding = padding(font)
            let runGlyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            enumerateLineFragments(forGlyphRange: runGlyphs) { _, line, container, lineGlyphs, _ in
                let glyphs = NSIntersectionRange(lineGlyphs, runGlyphs)
                guard glyphs.length > 0 else { return }
                let bounds = self.boundingRect(forGlyphRange: glyphs, in: container)
                let start = self.characterIndexForGlyph(at: glyphs.location)
                let isWrapped = glyphs.location == lineGlyphs.location
                    && (textStorage.string as NSString).paragraphRange(for: NSRange(location: start, length: 0)).location != start
                let leading = isWrapped ? 0 : padding
                // The timeline's text rect for the line, half a point beyond
                // its bounds, inset by its inline code's point.
                rects.append(NSRect(x: bounds.minX - leading, y: line.minY - 0.5, width: bounds.width + leading, height: line.height + 1)
                    .insetBy(dx: 0, dy: InterfaceScale.metric(1)))
            }
        }
        return rects
    }
}
