import AppKit
import MessageRendering

/// Lays a document's leaves out as paragraphs. Table cells draw quotes,
/// code, rules and tables; every gap is spacing before a paragraph, or the
/// top margin of the first table it opens, so boxes have even padding.
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

    private static let paragraphGap = InterfaceScale.metric(10)
    private static let itemGap = InterfaceScale.metric(4)
    private static let markerWidth = InterfaceScale.metric(26)

    init(codeBackground: DiscordMarkdown.AppKitPlan.CodeBackground) {
        self.codeBackground = codeBackground
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
        let content = leaf.content
        var font = MarkdownInlineStyle.font(for: leaf.kind)
        var alignment = NSTextAlignment.natural
        switch leaf.kind {
        case .paragraph:
            if placement.marker != nil, let checkbox = Self.taskCheckbox(in: content) { placement.marker = checkbox }
        case .heading:
            break
        case let .code(language):
            // A marker would sit inside the box, which already shows the item's indent.
            placement.marker = nil
            let box = block(leaf.identity) { [margin = placement.indent] in Self.codeBlock(margin: margin) }
            placement.textBlocks.append(box)
            placement.indent = 0
            font = .monospacedSystemFont(ofSize: InterfaceScale.fontSize(12), weight: .regular)
            content.setAttributedString(highlighted(content.string, language: language, font: font))
        case .thematicBreak:
            placement.marker = nil
            let box = block(leaf.identity) { [margin = placement.indent] in Self.ruleBlock(margin: margin) }
            placement.textBlocks.append(box)
            placement.indent = 0
            // The rule is the box's edge, not Foundation's "⸻" text.
            content.setAttributedString(NSAttributedString())
            font = .systemFont(ofSize: 1)
        case let .tableCell(row, column):
            guard let tableIntent, let cell = tableCell(
                in: tableIntent, row: row, column: column, outerBlocks: placement.textBlocks, indent: placement.indent
            ) else { return }
            alignment = cell.alignment
            placement.marker = nil
            placement.textBlocks.append(cell.block)
            placement.indent = 0
        case let .footnote(number):
            placement.marker = Self.listMarker(ordinal: number, isOrdered: true, depth: 1)
            placement.markerIndent = placement.indent
            placement.indent += Self.markerWidth
        }
        if placement.isQuoted { Self.mute(content) }

        let style = NSMutableParagraphStyle()
        style.textBlocks = placement.textBlocks
        style.alignment = alignment
        style.lineSpacing = leaf.kind == .thematicBreak ? 0 : InterfaceScale.metric(2)
        style.paragraphSpacingBefore = spacing(before: leaf, opening: placement.textBlocks, isItemStart: placement.marker != nil)
        style.firstLineHeadIndent = placement.marker == nil ? placement.indent : placement.markerIndent
        style.headIndent = placement.indent
        if placement.marker != nil {
            style.tabStops = [
                NSTextTab(textAlignment: .right, location: placement.indent - InterfaceScale.metric(7)),
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
        previous = leaf
        previousBlocks = placement.textBlocks
    }

    private mutating func placement(in containers: [PresentationIntent.IntentType]) -> Placement {
        var placement = Placement()
        var isOrdered = false
        var listDepth = 0
        for container in containers {
            switch container.kind {
            case .blockQuote:
                let box = block(container.identity) { [margin = placement.indent] in Self.quoteBlock(margin: margin) }
                placement.textBlocks.append(box)
                placement.indent = 0
                placement.isQuoted = true
            case .orderedList, .unorderedList:
                isOrdered = container.kind == .orderedList
                listDepth += 1
            case let .listItem(ordinal):
                placement.markerIndent = placement.indent
                placement.indent += Self.markerWidth
                placement.marker = startedItems.insert(container.identity).inserted
                    ? Self.listMarker(ordinal: ordinal, isOrdered: isOrdered, depth: listDepth)
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

    /// The gap before a leaf, which moves to the top margin of the first
    /// block it opens, so the gap sits outside that block.
    private func spacing(before leaf: MarkdownLeaf, opening textBlocks: [NSTextBlock], isItemStart: Bool) -> CGFloat {
        guard let previous else { return 0 }
        let gap: CGFloat = switch (leaf.kind, previous.kind) {
        case (.tableCell, .tableCell) where openTable != nil && previousBlocks.last.map(Self.table(of:)) === openTable?.table: 0
        case let (.heading(level), _): InterfaceScale.metric(level <= 2 ? 20 : 14)
        case (.footnote, .footnote): Self.itemGap
        default:
            isItemStart && previous.containers.contains { if case .listItem = $0.kind { true } else { false } }
                ? Self.itemGap : Self.paragraphGap
        }
        let opened = textBlocks.map(Self.table(of:)).first { block in !previousBlocks.contains { Self.table(of: $0) === block } }
        guard let opened else { return gap }
        opened.setWidth(gap, type: .absoluteValueType, for: .margin, edge: .minY)
        return 0
    }

    private static func table(of block: NSTextBlock) -> NSTextBlock {
        (block as? NSTextTableBlock)?.table ?? block
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

    private static func cellBlock(_ table: NSTextTable, row: Int, column: Int) -> NSTextTableBlock {
        let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
        cell.setWidth(1, type: .absoluteValueType, for: .border)
        cell.setBorderColor(.separatorColor)
        for edge in [NSRectEdge.minX, .maxX] {
            cell.setWidth(InterfaceScale.metric(10), type: .absoluteValueType, for: .padding, edge: edge)
        }
        for edge in [NSRectEdge.minY, .maxY] {
            cell.setWidth(InterfaceScale.metric(5), type: .absoluteValueType, for: .padding, edge: edge)
        }
        if row == 0 {
            cell.backgroundColor = .quaternarySystemFill
        } else if row.isMultiple(of: 2) {
            cell.backgroundColor = .quinarySystemFill
        }
        return cell
    }

    // MARK: Blocks and markers

    /// A one-cell table, standing in for a plain text block, which collapses
    /// to a sliver when first laid out before the view has a width.
    private static func box(margin: CGFloat) -> NSTextTableBlock {
        let table = NSTextTable()
        table.numberOfColumns = 1
        table.setWidth(margin, type: .absoluteValueType, for: .margin, edge: .minX)
        return NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
    }

    private static func quoteBlock(margin: CGFloat) -> NSTextBlock {
        let block = box(margin: margin)
        block.setWidth(InterfaceScale.metric(3), type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(.tertiaryLabelColor, for: .minX)
        block.setWidth(InterfaceScale.metric(12), type: .absoluteValueType, for: .padding, edge: .minX)
        return block
    }

    private static func codeBlock(margin: CGFloat) -> NSTextBlock {
        let block = box(margin: margin)
        block.backgroundColor = .quaternarySystemFill
        for edge in [NSRectEdge.minX, .maxX, .minY, .maxY] {
            block.setWidth(InterfaceScale.metric(edge == .minX || edge == .maxX ? 12 : 10), type: .absoluteValueType, for: .padding, edge: edge)
        }
        return block
    }

    private static func ruleBlock(margin: CGFloat) -> NSTextBlock {
        let block = box(margin: margin)
        block.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
        block.setBorderColor(.separatorColor, for: .minY)
        return block
    }

    private static func listMarker(ordinal: Int, isOrdered: Bool, depth: Int) -> NSAttributedString {
        let bullets = ["•", "◦", "▪"]
        return NSAttributedString(
            string: isOrdered ? "\(ordinal)." : bullets[(depth - 1) % bullets.count],
            attributes: [
                .font: NSFont.interfaceMonospacedDigitSystemFont(ofSize: MarkdownInlineStyle.bodySize, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
    }

    /// GitHub's task list: `[ ]` or `[x]` opening an item becomes its marker.
    private static func taskCheckbox(in content: NSMutableAttributedString) -> NSAttributedString? {
        let text = content.string
        guard text.count > 3, text.hasPrefix("[ ] ") || text.lowercased().hasPrefix("[x] "),
              content.attribute(MarkdownInlineStyle.codeKey, at: 0, effectiveRange: nil) == nil
        else { return nil }
        let isDone = text.lowercased().hasPrefix("[x]")
        let font = content.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? MarkdownInlineStyle.font(for: .paragraph)
        content.deleteCharacters(in: NSRange(location: 0, length: 4))
        return NSAttributedString(attachment: MarkdownInlineStyle.symbol(
            isDone ? "checkmark.square.fill" : "square", font: font,
            colors: isDone ? [.white, .controlAccentColor] : [.secondaryLabelColor]
        ))
    }

    private mutating func highlighted(_ code: String, language: String?, font: NSFont) -> NSAttributedString {
        let code = code.hasSuffix("\n") ? String(code.dropLast()) : code
        highlightBudget -= code.utf8.count
        guard highlightBudget >= 0 else {
            return NSAttributedString(string: code, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        }
        return NativeTimelineCoreText.scaledMarkdown(
            DiscordMarkdown.appKitCodePlan(code, language: language, on: codeBackground), baseFontSize: font.pointSize
        )
    }

    /// Quotes read in secondary text, as on GitHub; links keep their colour.
    private static func mute(_ content: NSMutableAttributedString) {
        content.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: content.length)) { color, range, _ in
            if color as? NSColor == .labelColor { content.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range) }
        }
    }
}
