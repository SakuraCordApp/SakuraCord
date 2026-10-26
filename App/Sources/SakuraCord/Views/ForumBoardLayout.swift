import AppKit
import CoreText
import SakuraCordModels

/// Geometry for the forum board: the native canvas that lists a forum's posts
/// as cards (list) or tiles (gallery).
///
/// The layout is a pure function of data known when a post first appears:
/// its title, its applied tags and pin/lock status, the layout mode, the
/// width and the interface scale. Everything that arrives later — the starter
/// message and its excerpt, thumbnail and reactions, emoji images, display
/// name fonts, read state — only fills slots whose size is already reserved,
/// so cards never resize or move after first paint as data arrives.
struct ForumBoardMetrics: Equatable {
    let scale: CGFloat
    let contentInset: CGFloat
    let cardSpacing: CGFloat
    let cardPadding: CGFloat
    let cardCornerRadius: CGFloat
    let statusRowHeight: CGFloat
    let statusRowSpacing: CGFloat
    let titleFont: NSFont
    let titleLineHeight: CGFloat
    let maximumTitleLines: Int
    let titleSpacing: CGFloat
    let excerptFont: NSFont
    let excerptLineHeight: CGFloat
    let excerptLines: Int
    let footerSpacing: CGFloat
    let footerHeight: CGFloat
    let thumbnailSize: CGFloat
    let thumbnailSpacing: CGFloat
    let newBadgeWidth: CGFloat
    let sectionHeaderHeight: CGFloat
    let paginationStatusHeight: CGFloat
    let galleryMinimumColumnWidth: CGFloat
    let galleryCardHeight: CGFloat
    let galleryHeaderHeight: CGFloat
    let galleryHeroHeight: CGFloat
    let galleryTitleHeight: CGFloat
    let gallerySpacing: CGFloat

    static func current() -> Self {
        let titleFont = NSFont.interfaceSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize,
            weight: .semibold
        )
        let excerptFont = NSFont.interfacePreferredFont(forTextStyle: .body)
        let titleLineHeight = ceil(lineHeight(of: titleFont))
        let cardPadding = InterfaceScale.metric(14)
        let statusRowSpacing = InterfaceScale.metric(9)
        let footerSpacing = InterfaceScale.metric(10)
        let galleryHeaderHeight = InterfaceScale.metric(18)
        let galleryHeroHeight = InterfaceScale.metric(220)
        let galleryCardHeight = cardPadding * 2 + galleryHeaderHeight + statusRowSpacing * 2
            + titleLineHeight * 2 + galleryHeroHeight + footerSpacing + MessageReactionMetrics.pillHeight
        return Self(
            scale: InterfaceScale.factor,
            contentInset: InterfaceScale.metric(14),
            cardSpacing: InterfaceScale.metric(10),
            cardPadding: cardPadding,
            cardCornerRadius: InterfaceScale.metric(14),
            statusRowHeight: InterfaceScale.metric(24),
            statusRowSpacing: statusRowSpacing,
            titleFont: titleFont,
            titleLineHeight: titleLineHeight,
            maximumTitleLines: 2,
            titleSpacing: InterfaceScale.metric(5),
            excerptFont: excerptFont,
            excerptLineHeight: ceil(lineHeight(of: excerptFont)),
            excerptLines: 2,
            footerSpacing: footerSpacing,
            footerHeight: MessageReactionMetrics.pillHeight,
            thumbnailSize: InterfaceScale.metric(92),
            thumbnailSpacing: InterfaceScale.metric(14),
            newBadgeWidth: InterfaceScale.metric(44),
            sectionHeaderHeight: InterfaceScale.metric(34),
            paginationStatusHeight: InterfaceScale.metric(64),
            galleryMinimumColumnWidth: InterfaceScale.metric(300),
            galleryCardHeight: ceil(galleryCardHeight),
            galleryHeaderHeight: galleryHeaderHeight,
            galleryHeroHeight: galleryHeroHeight,
            galleryTitleHeight: titleLineHeight * 2,
            gallerySpacing: InterfaceScale.metric(12)
        )
    }

    static func lineHeight(of font: NSFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }

    /// The text width a list card's title wraps within. It always leaves room
    /// for a thumbnail, whose presence is unknown until the starter message
    /// loads, and for the NEW badge, which read state can clear later.
    func listTitleWrapWidth(cardWidth: CGFloat) -> CGFloat {
        max(1, cardWidth - cardPadding * 2 - thumbnailSize - thumbnailSpacing - newBadgeWidth)
    }

    func galleryTitleWrapWidth(cardWidth: CGFloat) -> CGFloat {
        max(1, cardWidth - cardPadding * 2 - newBadgeWidth)
    }
}

/// The first-paint inputs that decide a card's size. Two posts with equal
/// inputs always lay out identically, whatever else they carry.
nonisolated struct ForumCardGeometryInput: Hashable, Sendable {
    let id: ChannelID
    let title: String
    let hasStatusRow: Bool

    init(post: ForumPost) {
        id = post.id
        title = post.thread.name
        hasStatusRow = !post.thread.appliedTagIDs.isEmpty
            || post.thread.isPinned
            || post.thread.isLocked
    }
}

nonisolated enum ForumBoardItem: Hashable, Sendable {
    nonisolated enum Identifier: Hashable, Sendable {
        case post(ChannelID)
        case olderPostsHeader
        case placeholder(Int)
        case paginationStatus
    }

    case post(ForumCardGeometryInput)
    /// Divides active posts from closed (archived) ones.
    case olderPostsHeader
    /// A loading card with a post's exact geometry, ordinal-keyed so the same
    /// placeholders persist while a page loads.
    case placeholder(Int)
    /// The failed-page notice with its retry action.
    case paginationStatus

    var id: Identifier {
        switch self {
        case let .post(input): .post(input.id)
        case .olderPostsHeader: .olderPostsHeader
        case let .placeholder(index): .placeholder(index)
        case .paginationStatus: .paginationStatus
        }
    }

    var postID: ChannelID? {
        if case let .post(input) = self { return input.id }
        return nil
    }
}

struct ForumBoardLayout {
    struct Entry {
        let item: ForumBoardItem
        let frame: CGRect
        /// Title lines the card reserves; zero for non-post items.
        let titleLines: Int
    }

    let width: CGFloat
    let entries: [Entry]
    let contentHeight: CGFloat
    let indexByID: [ForumBoardItem.Identifier: Int]
    /// Entries sorted by `frame.minY` share a row in gallery mode; the row
    /// starts let a visible range be found by binary search either way.
    private let rowStarts: [RowStart]

    private struct RowStart {
        let minY: CGFloat
        let maxY: CGFloat
        let firstIndex: Int
    }

    /// The index of the entry in the row above or below `index`'s whose centre
    /// is nearest to it, or the first or last entry when no such row exists.
    static func adjacentRowIndex(from index: Int, down: Bool, in frames: [CGRect]) -> Int {
        let current = frames[index]
        let candidates = frames.indices.filter {
            down ? frames[$0].minY > current.minY : frames[$0].minY < current.minY
        }
        guard let rowY = down
            ? candidates.map({ frames[$0].minY }).min()
            : candidates.map({ frames[$0].minY }).max()
        else { return down ? frames.count - 1 : 0 }
        return candidates.filter { frames[$0].minY == rowY }
            .min { abs(frames[$0].midX - current.midX) < abs(frames[$1].midX - current.midX) } ?? index
    }

    func entry(for id: ForumBoardItem.Identifier) -> Entry? {
        indexByID[id].map { entries[$0] }
    }

    /// Entries intersecting `rect`, in document order.
    func entries(intersecting rect: CGRect) -> ArraySlice<Entry> {
        guard !rowStarts.isEmpty, rect.maxY > 0, rect.minY < contentHeight else { return [] }
        var low = 0
        var high = rowStarts.count
        while low < high {
            let middle = (low + high) / 2
            if rowStarts[middle].maxY < rect.minY { low = middle + 1 } else { high = middle }
        }
        guard low < rowStarts.count else { return [] }
        var lastRow = low
        while lastRow + 1 < rowStarts.count, rowStarts[lastRow + 1].minY <= rect.maxY {
            lastRow += 1
        }
        let start = rowStarts[low].firstIndex
        let end = lastRow + 1 < rowStarts.count ? rowStarts[lastRow + 1].firstIndex : entries.count
        return entries[start ..< end]
    }

    static func make(
        items: [ForumBoardItem],
        mode: ForumLayout,
        width proposedWidth: CGFloat,
        metrics: ForumBoardMetrics,
        titleLines: (String, CGFloat) -> Int
    ) -> Self {
        let width = max(proposedWidth, metrics.galleryMinimumColumnWidth * 0.6)
        let innerWidth = max(1, width - metrics.contentInset * 2)
        var entries: [Entry] = []
        entries.reserveCapacity(items.count)
        var rowStarts: [RowStart] = []
        var cursorY = metrics.contentInset

        func appendFullWidth(_ item: ForumBoardItem, height: CGFloat, lines: Int = 0) {
            if !entries.isEmpty { cursorY += metrics.cardSpacing }
            let frame = CGRect(x: metrics.contentInset, y: cursorY, width: innerWidth, height: height)
            rowStarts.append(RowStart(minY: frame.minY, maxY: frame.maxY, firstIndex: entries.count))
            entries.append(Entry(item: item, frame: frame, titleLines: lines))
            cursorY = frame.maxY
        }

        switch mode {
        case .gallery:
            let spacing = metrics.gallerySpacing
            let columns = max(1, Int((innerWidth + spacing) / (metrics.galleryMinimumColumnWidth + spacing)))
            let columnWidth = floor((innerWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns))
            var column = 0
            var rowY = cursorY
            func closeRow() {
                guard column > 0 else { return }
                cursorY = rowY + metrics.galleryCardHeight
                column = 0
            }
            for item in items {
                switch item {
                case .post, .placeholder:
                    if column == 0 {
                        rowY = entries.isEmpty ? cursorY : cursorY + spacing
                        rowStarts.append(RowStart(minY: rowY, maxY: rowY + metrics.galleryCardHeight, firstIndex: entries.count))
                    }
                    let frame = CGRect(
                        x: metrics.contentInset + CGFloat(column) * (columnWidth + spacing),
                        y: rowY,
                        width: columnWidth,
                        height: metrics.galleryCardHeight
                    )
                    var lines = 0
                    if case let .post(input) = item {
                        lines = min(
                            metrics.maximumTitleLines,
                            max(1, titleLines(input.title, metrics.galleryTitleWrapWidth(cardWidth: columnWidth)))
                        )
                    }
                    entries.append(Entry(item: item, frame: frame, titleLines: lines))
                    column += 1
                    if column == columns { closeRow() }
                case .olderPostsHeader:
                    closeRow()
                    appendFullWidth(item, height: metrics.sectionHeaderHeight)
                case .paginationStatus:
                    closeRow()
                    appendFullWidth(item, height: metrics.paginationStatusHeight)
                }
            }
            closeRow()
        case .list, .defaultLayout:
            for item in items {
                switch item {
                case let .post(input):
                    let lines = min(
                        metrics.maximumTitleLines,
                        max(1, titleLines(input.title, metrics.listTitleWrapWidth(cardWidth: innerWidth)))
                    )
                    appendFullWidth(
                        item,
                        height: listCardHeight(titleLines: lines, hasStatusRow: input.hasStatusRow, metrics: metrics),
                        lines: lines
                    )
                case .placeholder:
                    appendFullWidth(item, height: listCardHeight(titleLines: 1, hasStatusRow: true, metrics: metrics))
                case .olderPostsHeader:
                    appendFullWidth(item, height: metrics.sectionHeaderHeight)
                case .paginationStatus:
                    appendFullWidth(item, height: metrics.paginationStatusHeight)
                }
            }
        }

        var indexByID: [ForumBoardItem.Identifier: Int] = [:]
        indexByID.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            indexByID[entry.item.id] = index
        }
        return Self(
            width: width,
            entries: entries,
            contentHeight: cursorY + metrics.contentInset,
            indexByID: indexByID,
            rowStarts: rowStarts
        )
    }

    static func listCardHeight(titleLines: Int, hasStatusRow: Bool, metrics: ForumBoardMetrics) -> CGFloat {
        var height = metrics.cardPadding
        if hasStatusRow {
            height += metrics.statusRowHeight + metrics.statusRowSpacing
        }
        height += CGFloat(titleLines) * metrics.titleLineHeight
        height += metrics.titleSpacing
        height += CGFloat(metrics.excerptLines) * metrics.excerptLineHeight
        height += metrics.footerSpacing + metrics.footerHeight
        height += metrics.cardPadding
        return ceil(max(height, metrics.thumbnailSize + metrics.cardPadding * 2))
    }
}

/// Counts the lines a title wraps to with Core Text's own line breaking,
/// stopping once the cap is reached. Results are cached by text and width.
nonisolated final class ForumTitleLineCounter: @unchecked Sendable {
    private struct Key: Hashable {
        let title: String
        let width: Int
    }

    private let font: NSFont
    private let maximumLines: Int
    private var cache: [Key: Int] = [:]
    /// Each title's width on one line, which does not depend on the board
    /// width, so a resize re-measures no titles; nil when only the
    /// typesetter can count it.
    private var singleLineWidths: [String: CGFloat?] = [:]

    init(font: NSFont, maximumLines: Int) {
        self.font = font
        self.maximumLines = maximumLines
    }

    func lines(_ title: String, width: CGFloat) -> Int {
        let width = width.rounded(.down)
        if let count = fastCount(title, width: width) { return count }
        let key = Key(title: title, width: Int(width))
        if let cached = cache[key] { return cached }
        let value = Self.count(title, width: width, font: font, maximumLines: maximumLines)
        if cache.count > 8_192 { cache.removeAll(keepingCapacity: true) }
        cache[key] = value
        return value
    }

    /// With at most two lines, a title takes one line when it fits on one
    /// and two otherwise. Widths too close to call, and titles with line
    /// breaks or a single character, take the typesetter's answer.
    private func fastCount(_ title: String, width: CGFloat) -> Int? {
        guard maximumLines <= 2,
              let singleLineWidth = singleLineWidths[title] ?? measureSingleLine(title)
        else { return nil }
        let width = max(1, width)
        if singleLineWidth <= width - 0.5 { return 1 }
        if singleLineWidth > width + 0.5 { return maximumLines }
        return nil
    }

    private func measureSingleLine(_ title: String) -> CGFloat? {
        var value: CGFloat?
        // One character never wraps, however narrow the width.
        if title.count > 1, !title.contains(where: \.isNewline) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: [.font: font]))
            value = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
        }
        if singleLineWidths.count > 8_192 { singleLineWidths.removeAll(keepingCapacity: true) }
        singleLineWidths[title] = value
        return value
    }

    static func count(_ title: String, width: CGFloat, font: NSFont, maximumLines: Int) -> Int {
        guard !title.isEmpty else { return 1 }
        let attributed = NSAttributedString(string: title, attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = attributed.length
        var location = 0
        var lines = 0
        while location < length, lines < maximumLines {
            let count = CTTypesetterSuggestLineBreak(typesetter, location, Double(max(1, width)))
            guard count > 0 else { break }
            location += count
            lines += 1
        }
        return max(1, lines)
    }
}
