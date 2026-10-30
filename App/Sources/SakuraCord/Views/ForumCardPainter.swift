import AppKit
import CoreText
import SakuraCordModels

/// Interactive regions inside a card, in card coordinates. The painter and
/// the board's pointer handling share them, so hit targets always match what
/// is drawn.
struct ForumCardRegions: Equatable {
    var statusRowFrame: CGRect?
    var titleFrame: CGRect = .zero
    var excerptFrame: CGRect?
    var thumbnailFrame: CGRect?
    var heroFrame: CGRect?
    var reactionRegionFrame: CGRect?
    var timestampFrame: CGRect?
    /// Where hovering shows the exact date: last activity in list, the
    /// posted time row in gallery.
    var exactDateFrame: CGRect?
    var countFrame: CGRect?
    /// The "•" between the message count and the last activity in list.
    var footerSeparatorFrame: CGRect?
    /// Measured width of the message count's digits inside `countFrame`.
    var countTextWidth: CGFloat = 0
    var footerFrame: CGRect = .zero
    /// Rounded bars the card's loading shimmer is masked to.
    var skeletonFrames: [CGRect] = []
}

/// Live interaction state that changes how a card draws.
struct ForumCardInteraction: Equatable {
    var isReactionHovered = false
    var isRetryHovered = false
}

/// Draws forum board cards with Core Graphics and Core Text into the current
/// flipped graphics context. Card size never depends on what is drawn here.
@MainActor
enum ForumCardPainter {
    /// Fonts and the NEW badge size depend only on the interface size, so
    /// they are built once per size instead of on every paint.
    private struct Fonts {
        let scale = InterfaceScale.factor
        let regular = NSFont.interfaceSystemFont(ofSize: 12)
        let semibold = NSFont.interfaceSystemFont(ofSize: 12, weight: .semibold)
        let badge: NSFont
        let newBadgeSize: CGSize

        init() {
            let badge = NSFont.interfaceSystemFont(ofSize: 10, weight: .bold)
            self.badge = badge
            newBadgeSize = CGSize(
                width: ceil(NativeTimelineRowLayout.measuredTextWidth("NEW", font: badge) + InterfaceScale.metric(16)),
                height: InterfaceScale.metric(18)
            )
        }
    }

    private static var cachedFonts = Fonts()
    private static var fonts: Fonts {
        if cachedFonts.scale != InterfaceScale.factor { cachedFonts = Fonts() }
        return cachedFonts
    }

    private static var tagFont: NSFont { fonts.semibold }
    private static var footerFont: NSFont { fonts.regular }
    private static var footerEmphasisFont: NSFont { fonts.semibold }
    private static var captionFont: NSFont { fonts.regular }
    private static var badgeFont: NSFont { fonts.badge }
    static var newBadgeSize: CGSize { fonts.newBadgeSize }
    /// Matches the shared skeleton style's resting fill; the shimmer above
    /// the bars uses it too.
    static let skeletonFill = NSColor.labelColor.withAlphaComponent(0.09)
    private static let bullet = " • "
    static let newBadgeFill = NSColor(srgbRed: 0xC9 / 255, green: 0xD2 / 255, blue: 1, alpha: 1)
    static let newBadgeText = NSColor(srgbRed: 0x58 / 255, green: 0x65 / 255, blue: 0xF2 / 255, alpha: 1)

    // MARK: Regions

    static func regions(
        for presentation: ForumCardPresentation?,
        mode: ForumLayout,
        size: CGSize,
        titleLines: Int,
        metrics: ForumBoardMetrics
    ) -> ForumCardRegions {
        mode == .gallery
            ? galleryRegions(for: presentation, size: size, metrics: metrics)
            : listRegions(for: presentation, size: size, titleLines: titleLines, metrics: metrics)
    }

    private static func listRegions(
        for presentation: ForumCardPresentation?,
        size: CGSize,
        titleLines: Int,
        metrics: ForumBoardMetrics
    ) -> ForumCardRegions {
        var regions = ForumCardRegions()
        let padding = metrics.cardPadding
        let hasThumbnail = presentation?.thumbnail != nil
        let textMaxX = size.width - padding - (hasThumbnail ? metrics.thumbnailSize + metrics.thumbnailSpacing : 0)
        var cursorY = padding
        let hasStatusRow = presentation?.hasStatusRow ?? true
        if hasStatusRow {
            regions.statusRowFrame = CGRect(x: padding, y: cursorY, width: textMaxX - padding, height: metrics.statusRowHeight)
            cursorY += metrics.statusRowHeight + metrics.statusRowSpacing
        }
        // The card reserves title lines for the narrowest case (thumbnail and
        // NEW badge). The excerpt follows the lines actually drawn; any spare
        // reservation sits below the excerpt, above the fixed footer.
        let lines = presentation.map { drawnTitleLines($0, width: textMaxX - padding, reserved: titleLines, metrics: metrics) } ?? 1
        regions.titleFrame = CGRect(
            x: padding, y: cursorY, width: textMaxX - padding,
            height: CGFloat(lines) * metrics.titleLineHeight
        )
        cursorY = regions.titleFrame.maxY + metrics.titleSpacing
        regions.footerFrame = CGRect(
            x: padding,
            y: size.height - padding - metrics.footerHeight,
            width: size.width - padding * 2,
            height: metrics.footerHeight
        )
        // A line with a mention or emoji is taller than body text, and a
        // two-line slot cut a second such line off. The excerpt draws no
        // more than its lines, so its slot runs down to the footer.
        let excerptFrame = CGRect(
            x: padding, y: cursorY, width: textMaxX - padding,
            height: max(CGFloat(metrics.excerptLines) * metrics.excerptLineHeight, regions.footerFrame.minY - cursorY)
        )
        regions.excerptFrame = excerptFrame
        if hasThumbnail {
            regions.thumbnailFrame = CGRect(
                x: size.width - padding - metrics.thumbnailSize,
                y: padding,
                width: metrics.thumbnailSize,
                height: metrics.thumbnailSize
            )
        }
        guard let presentation else {
            regions.skeletonFrames = placeholderListBars(regions: regions, metrics: metrics)
            return regions
        }
        layoutFooter(presentation, in: &regions, alignsReactionTrailing: false)
        if presentation.excerpt == .pending {
            regions.skeletonFrames = excerptBars(in: excerptFrame, metrics: metrics)
        }
        return regions
    }

    private static func drawnTitleLines(
        _ presentation: ForumCardPresentation,
        width: CGFloat,
        reserved: Int,
        metrics: ForumBoardMetrics
    ) -> Int {
        let badgeReserve = presentation.isNew ? newBadgeSize.width + InterfaceScale.metric(8) : 0
        let lines = ForumTitleLineCounter.count(
            presentation.title,
            width: max(1, width - badgeReserve),
            font: metrics.titleFont,
            maximumLines: reserved
        )
        return min(max(1, reserved), lines)
    }

    private static func galleryRegions(
        for presentation: ForumCardPresentation?,
        size: CGSize,
        metrics: ForumBoardMetrics
    ) -> ForumCardRegions {
        var regions = ForumCardRegions()
        let padding = metrics.cardPadding
        let innerWidth = size.width - padding * 2
        regions.statusRowFrame = CGRect(x: padding, y: padding, width: innerWidth, height: metrics.galleryHeaderHeight)
        // The author and posted time row shows the exact posting date on hover.
        regions.exactDateFrame = regions.statusRowFrame
        var cursorY = padding + metrics.galleryHeaderHeight + metrics.statusRowSpacing
        regions.titleFrame = CGRect(x: padding, y: cursorY, width: innerWidth, height: metrics.galleryTitleHeight)
        cursorY = regions.titleFrame.maxY + metrics.statusRowSpacing
        regions.heroFrame = CGRect(x: padding, y: cursorY, width: innerWidth, height: metrics.galleryHeroHeight)
        regions.footerFrame = CGRect(
            x: padding,
            y: size.height - padding - metrics.footerHeight,
            width: innerWidth,
            height: metrics.footerHeight
        )
        guard let presentation else {
            let title = regions.titleFrame
            regions.skeletonFrames = [
                CGRect(x: padding, y: padding + 3, width: innerWidth * 0.42, height: metrics.galleryHeaderHeight - 6),
                CGRect(x: title.minX, y: title.minY + 5, width: title.width * 0.78, height: metrics.titleLineHeight - 10),
                regions.heroFrame ?? .zero,
                CGRect(x: padding, y: regions.footerFrame.minY + 6, width: InterfaceScale.metric(54), height: metrics.footerHeight - 12),
            ]
            return regions
        }
        layoutFooter(presentation, in: &regions, alignsReactionTrailing: true)
        if presentation.hero == .pending, let hero = regions.heroFrame {
            regions.skeletonFrames = [hero]
        }
        return regions
    }

    private static func layoutFooter(
        _ presentation: ForumCardPresentation,
        in regions: inout ForumCardRegions,
        alignsReactionTrailing: Bool
    ) {
        let footer = regions.footerFrame
        let spacing = InterfaceScale.metric(12)
        var cursorX = footer.minX
        if let summary = presentation.reaction {
            let size = NativeTimelineRowLayout.reactionSize(summary.reaction, showsReactors: false)
            let originX = alignsReactionTrailing ? footer.maxX - size.width : cursorX
            regions.reactionRegionFrame = CGRect(x: originX, y: footer.midY - size.height / 2, width: size.width, height: size.height)
            if !alignsReactionTrailing { cursorX += size.width + spacing }
        }
        let countTextWidth = NativeTimelineRowLayout.measuredTextWidth(presentation.messageCount.formatted(), font: footerFont)
        let countWidth = countContentWidth(presentation, textWidth: countTextWidth)
        regions.countFrame = CGRect(x: cursorX, y: footer.minY, width: countWidth, height: footer.height)
        regions.countTextWidth = countTextWidth
        if !alignsReactionTrailing {
            cursorX += countWidth
            let separatorWidth = ceil(NativeTimelineRowLayout.measuredTextWidth(bullet, font: footerFont))
            regions.footerSeparatorFrame = CGRect(x: cursorX, y: footer.minY, width: separatorWidth, height: footer.height)
            cursorX += separatorWidth
            let text = presentation.relativeTimeText(isGallery: false)
            let width = ceil(NativeTimelineRowLayout.measuredTextWidth(text, font: footerFont)) + 2
            regions.timestampFrame = CGRect(x: cursorX, y: footer.minY, width: width, height: footer.height)
            regions.exactDateFrame = regions.timestampFrame
        }
    }

    private static func excerptBars(in frame: CGRect, metrics: ForumBoardMetrics) -> [CGRect] {
        let barHeight = round(metrics.excerptLineHeight * 0.5)
        return (0 ..< metrics.excerptLines).map { line in
            let lineY = frame.minY + CGFloat(line) * metrics.excerptLineHeight
            let fraction: CGFloat = line == metrics.excerptLines - 1 ? 0.58 : 0.92
            return CGRect(
                x: frame.minX,
                y: lineY + (metrics.excerptLineHeight - barHeight) / 2,
                width: floor(frame.width * fraction),
                height: barHeight
            )
        }
    }

    private static func placeholderListBars(regions: ForumCardRegions, metrics: ForumBoardMetrics) -> [CGRect] {
        var bars: [CGRect] = []
        if let status = regions.statusRowFrame {
            bars.append(CGRect(x: status.minX, y: status.minY, width: InterfaceScale.metric(74), height: status.height))
            bars.append(CGRect(x: status.minX + InterfaceScale.metric(82), y: status.minY, width: InterfaceScale.metric(58), height: status.height))
        }
        let title = regions.titleFrame
        bars.append(CGRect(
            x: title.minX,
            y: title.minY + metrics.titleLineHeight * 0.2,
            width: floor(title.width * 0.64),
            height: round(metrics.titleLineHeight * 0.6)
        ))
        if let excerpt = regions.excerptFrame {
            bars += excerptBars(in: excerpt, metrics: metrics)
        }
        let footer = regions.footerFrame
        bars.append(CGRect(x: footer.minX, y: footer.minY, width: InterfaceScale.metric(58), height: footer.height))
        bars.append(CGRect(
            x: footer.minX + InterfaceScale.metric(70),
            y: footer.midY - InterfaceScale.metric(6),
            width: InterfaceScale.metric(90),
            height: InterfaceScale.metric(12)
        ))
        return bars
    }

    private static func countContentWidth(_ presentation: ForumCardPresentation, textWidth: CGFloat) -> CGFloat {
        let iconWidth = InterfaceScale.metric(14) + InterfaceScale.metric(4)
        var width = iconWidth + textWidth
        if let unreadCountText = presentation.unreadCountText {
            width += InterfaceScale.metric(4) + NativeTimelineRowLayout.measuredTextWidth(
                "(\(unreadCountText) New)", font: footerEmphasisFont
            )
        }
        return ceil(width) + 1
    }

    // MARK: Drawing

    struct DrawInput {
        let presentation: ForumCardPresentation
        let mode: ForumLayout
        let regions: ForumCardRegions
        let titleLines: Int
        let excerpt: ForumPostPreviewTextRenderer?
        let interaction: ForumCardInteraction
        let model: AppModel?
        let metrics: ForumBoardMetrics
        /// Media whose download failed; a failed video poster falls back to
        /// the file tile.
        let failedMedia: Set<NativeTimelineMediaKey>
    }

    static func draw(_ input: DrawInput, on canvas: ForumCardCanvas) {
        let presentation = input.presentation
        let regions = input.regions
        let metrics = input.metrics
        if input.mode == .gallery {
            drawGalleryHeader(presentation, in: regions.statusRowFrame ?? .zero, on: canvas)
            drawTitle(presentation, in: regions.titleFrame, maximumLines: metrics.maximumTitleLines, metrics: metrics, on: canvas)
            if let hero = regions.heroFrame {
                drawHero(presentation, in: hero, excerpt: input.excerpt, failedMedia: input.failedMedia, on: canvas)
            }
        } else {
            if let status = regions.statusRowFrame {
                drawStatusRow(presentation, in: status, on: canvas)
            }
            let drawnLines = max(1, Int((regions.titleFrame.height / metrics.titleLineHeight).rounded()))
            drawTitle(presentation, in: regions.titleFrame, maximumLines: min(input.titleLines, drawnLines), metrics: metrics, on: canvas)
            if let excerptFrame = regions.excerptFrame {
                drawExcerpt(presentation, in: excerptFrame, renderer: input.excerpt, metrics: metrics, on: canvas)
            }
            if let thumbnail = presentation.thumbnail, let frame = regions.thumbnailFrame {
                drawMedia(
                    thumbnail,
                    in: frame,
                    style: MediaStyle(cornerRadius: InterfaceScale.metric(11), isCompact: true),
                    failedMedia: input.failedMedia,
                    on: canvas
                )
            }
        }
        drawFooter(presentation, regions: regions, interaction: input.interaction, model: input.model, on: canvas)
    }

    /// Skeleton bars, drawn beneath the shimmer layer that animates over them.
    static func drawSkeleton(_ frames: [CGRect], on canvas: ForumCardCanvas) {
        for frame in frames {
            canvas.fill(frame, cornerRadius: min(InterfaceScale.metric(7), frame.height / 2), color: skeletonFill)
        }
    }

    private static func drawStatusRow(_ presentation: ForumCardPresentation, in frame: CGRect, on canvas: ForumCardCanvas) {
        var cursorX = frame.minX
        let iconSize = InterfaceScale.metric(14)
        for (shown, symbol) in [(presentation.isPinned, "pin.fill"), (presentation.isLocked, "lock.fill")] where shown {
            drawStatusIcon(symbol, at: CGPoint(x: cursorX, y: frame.midY), size: iconSize, on: canvas)
            cursorX += iconSize + InterfaceScale.metric(7)
        }
        drawTags(
            presentation.tags,
            in: CGRect(x: cursorX, y: frame.minY, width: frame.maxX - cursorX, height: frame.height),
            style: .standard,
            on: canvas
        )
    }

    /// A pin or lock mark, centered vertically on `origin.y`.
    private static func drawStatusIcon(_ symbol: String, at origin: CGPoint, size: CGFloat, on canvas: ForumCardCanvas) {
        canvas.symbol(
            symbol,
            in: CGRect(x: origin.x, y: origin.y - size / 2, width: size, height: size),
            color: .secondaryLabelColor,
            inset: 0,
            weight: .semibold
        )
    }

    enum TagStyle {
        case standard
        case overMedia
    }

    /// Fits as many tag chips as the width allows, ending with "+N" for the
    /// rest. Chips never wrap, so the status row height stays fixed.
    static func drawTags(
        _ tags: [ForumCardPresentation.Tag],
        in frame: CGRect,
        style: TagStyle,
        maximumVisible: Int = 5,
        on canvas: ForumCardCanvas
    ) {
        guard !tags.isEmpty, frame.width > 0 else { return }
        let spacing = InterfaceScale.metric(6)
        let widths = tags.map { tagWidth($0) }
        var visible = min(tags.count, maximumVisible)
        func overflowWidth(_ hidden: Int) -> CGFloat {
            hidden > 0 ? chipWidth(text: "+\(hidden)", hasEmoji: false) + spacing : 0
        }
        while visible > 0 {
            let total = widths.prefix(visible).reduce(0, +) + CGFloat(visible - 1) * spacing
                + overflowWidth(tags.count - visible)
            if total <= frame.width { break }
            visible -= 1
        }
        var cursorX = frame.minX
        for (tag, width) in zip(tags.prefix(visible), widths) {
            drawChip(
                text: tag.name,
                emoji: tag.emoji,
                frame: CGRect(x: cursorX, y: frame.minY, width: width, height: frame.height),
                style: style,
                on: canvas
            )
            cursorX += width + spacing
        }
        let hidden = tags.count - visible
        if hidden > 0 {
            let text = "+\(hidden)"
            let width = min(chipWidth(text: text, hasEmoji: false), frame.maxX - cursorX)
            guard width > 0 else { return }
            drawChip(text: text, emoji: nil, frame: CGRect(x: cursorX, y: frame.minY, width: width, height: frame.height), style: style, on: canvas)
        }
    }

    private static func tagWidth(_ tag: ForumCardPresentation.Tag) -> CGFloat {
        chipWidth(text: tag.name, hasEmoji: tag.emoji != nil)
    }

    private static func chipWidth(text: String, hasEmoji: Bool) -> CGFloat {
        let padding = InterfaceScale.metric(9)
        let emoji = hasEmoji ? InterfaceScale.metric(14) + InterfaceScale.metric(4) : 0
        let textWidth = min(NativeTimelineRowLayout.measuredTextWidth(text, font: tagFont), InterfaceScale.metric(160))
        return ceil(padding * 2 + emoji + textWidth)
    }

    private static func drawChip(
        text: String,
        emoji: ForumTagEmojiPresentation?,
        frame: CGRect,
        style: TagStyle,
        on canvas: ForumCardCanvas
    ) {
        let radius = frame.height / 2
        switch style {
        case .standard:
            canvas.fill(frame, cornerRadius: radius, color: NSColor.labelColor.withAlphaComponent(0.07))
            canvas.stroke(frame, cornerRadius: radius, color: NSColor.labelColor.withAlphaComponent(0.1))
        case .overMedia:
            canvas.fill(frame, cornerRadius: radius, color: NSColor.black.withAlphaComponent(0.58))
        }
        let padding = InterfaceScale.metric(9)
        var cursorX = frame.minX + padding
        if let emoji {
            let size = InterfaceScale.metric(14)
            drawEmoji(emoji, in: CGRect(x: cursorX, y: frame.midY - size / 2, width: size, height: size), on: canvas)
            cursorX += size + InterfaceScale.metric(4)
        }
        let color: NSColor = style == .overMedia ? .white : .labelColor
        let lineHeight = ForumBoardMetrics.lineHeight(of: tagFont)
        canvas.text(
            text,
            in: CGRect(x: cursorX, y: frame.midY - lineHeight / 2, width: max(0, frame.maxX - padding - cursorX), height: lineHeight),
            font: tagFont,
            color: color
        )
    }

    static func drawEmoji(_ emoji: ForumTagEmojiPresentation, in frame: CGRect, on canvas: ForumCardCanvas) {
        switch emoji {
        case let .unicode(value):
            canvas.image(ComponentUnicodeEmojiRenderer.image(for: value), in: frame, cornerRadius: 0, fillsFrame: false)
        case .custom:
            if let key = emoji.mediaKey, let image = NativeTimelineRowPainter.mediaImage(for: key) {
                canvas.image(image, in: frame, cornerRadius: 0, fillsFrame: false)
            } else {
                canvas.fillOval(frame.insetBy(dx: 1, dy: 1), color: NSColor.labelColor.withAlphaComponent(0.1))
            }
        }
    }

    // MARK: Title

    private static func drawTitle(
        _ presentation: ForumCardPresentation,
        in frame: CGRect,
        maximumLines: Int,
        metrics: ForumBoardMetrics,
        on canvas: ForumCardCanvas
    ) {
        let color: NSColor = presentation.isEmphasized ? .labelColor : .secondaryLabelColor
        let spacing = InterfaceScale.metric(8)
        canvas.lines(
            presentation.title,
            font: metrics.titleFont,
            color: color,
            in: frame,
            lineHeight: metrics.titleLineHeight,
            maximumLines: max(1, maximumLines),
            lastLineReserve: presentation.isNew ? newBadgeSize.width + spacing : 0,
            badge: presentation.isNew
                ? ForumCardCanvas.Badge(
                    size: newBadgeSize,
                    spacing: spacing,
                    fill: newBadgeFill,
                    text: "NEW",
                    font: badgeFont,
                    textColor: newBadgeText
                )
                : nil
        )
    }

    // MARK: Excerpt and hero

    /// Bumps when the excerpt renderer's drawing changes; the origin is
    /// relative to the clip, so a moving excerpt keeps its bitmap.
    private struct ExcerptKey: Hashable {
        let revision: Int
        let originX: CGFloat
        let originY: CGFloat
    }

    private static func drawExcerptText(
        _ renderer: ForumPostPreviewTextRenderer?,
        at origin: CGPoint,
        clip: CGRect,
        on canvas: ForumCardCanvas
    ) {
        guard let renderer else { return }
        if canvas.laysOutExcerptsOffMain, let text = renderer.workerText(scale: canvas.scale) {
            canvas.excerpt(text, at: origin, width: renderer.size.width, clippedTo: clip)
            return
        }
        canvas.prerendered(key: ExcerptKey(revision: renderer.displayRevision, originX: origin.x - clip.minX, originY: origin.y - clip.minY), clip: clip) {
            renderer.draw(at: origin)
        }
    }

    private static func drawExcerpt(
        _ presentation: ForumCardPresentation,
        in frame: CGRect,
        renderer: ForumPostPreviewTextRenderer?,
        metrics: ForumBoardMetrics,
        on canvas: ForumCardCanvas
    ) {
        switch presentation.excerpt {
        case .pending:
            return
        case .empty:
            let text = presentation.thumbnail == nil ? "No message" : "Attachment"
            canvas.text(
                text,
                in: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: metrics.excerptLineHeight),
                font: metrics.excerptFont,
                color: .tertiaryLabelColor
            )
        case .deleted, .message:
            // Markdown lines can be taller than body text; the slot clips.
            drawExcerptText(renderer, at: frame.origin, clip: frame, on: canvas)
        }
    }

    private static func drawHero(
        _ presentation: ForumCardPresentation,
        in frame: CGRect,
        excerpt: ForumPostPreviewTextRenderer?,
        failedMedia: Set<NativeTimelineMediaKey>,
        on canvas: ForumCardCanvas
    ) {
        let radius = InterfaceScale.metric(12)
        canvas.fill(frame, cornerRadius: radius, color: NSColor.labelColor.withAlphaComponent(0.06))
        switch presentation.hero {
        case .pending:
            break
        case let .media(media):
            drawMedia(media, in: frame, style: MediaStyle(cornerRadius: radius, isCompact: false), failedMedia: failedMedia, on: canvas)
        case .text, .deleted:
            // The preview stays inside the hero, above its tag row.
            let tagReserve = presentation.tags.isEmpty ? 0 : InterfaceScale.metric(34)
            drawExcerptText(
                excerpt,
                at: CGPoint(x: frame.minX + InterfaceScale.metric(16), y: frame.minY + InterfaceScale.metric(14)),
                clip: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - InterfaceScale.metric(14) - tagReserve),
                on: canvas
            )
        case .empty:
            let size = InterfaceScale.metric(34)
            canvas.symbol(
                "bubble.left.and.text.bubble.right",
                in: CGRect(x: frame.midX - size / 2, y: frame.midY - size / 2, width: size, height: size),
                color: .tertiaryLabelColor,
                inset: 0,
                weight: .medium
            )
        }
        let chipHeight = InterfaceScale.metric(24)
        let inset = InterfaceScale.metric(10)
        let isOverMedia: Bool = if case .media = presentation.hero { true } else { false }
        drawTags(
            presentation.tags,
            in: CGRect(x: frame.minX + inset, y: frame.maxY - inset - chipHeight, width: frame.width - inset * 2, height: chipHeight),
            style: isOverMedia ? .overMedia : .standard,
            maximumVisible: 3,
            on: canvas
        )
        canvas.stroke(frame.insetBy(dx: 0.5, dy: 0.5), cornerRadius: radius, color: NSColor.separatorColor.withAlphaComponent(0.65))
    }

    struct MediaStyle {
        let cornerRadius: CGFloat
        let isCompact: Bool
    }

    static func drawMedia(
        _ media: ForumCardPresentation.Media,
        in frame: CGRect,
        style: MediaStyle,
        failedMedia: Set<NativeTimelineMediaKey>,
        on canvas: ForumCardCanvas
    ) {
        let cornerRadius = style.cornerRadius
        let isCompact = style.isCompact
        canvas.fill(frame, cornerRadius: cornerRadius, color: NSColor.labelColor.withAlphaComponent(0.06))
        switch media {
        case let .image(key):
            if let image = NativeTimelineRowPainter.mediaImage(for: key) {
                canvas.image(image, in: frame, cornerRadius: cornerRadius, fillsFrame: true)
            }
        case let .video(poster, filename):
            if let poster, let image = NativeTimelineRowPainter.mediaImage(for: poster) {
                canvas.image(image, in: frame, cornerRadius: cornerRadius, fillsFrame: true)
                let badge = InterfaceScale.metric(34)
                let badgeFrame = CGRect(x: frame.midX - badge / 2, y: frame.midY - badge / 2, width: badge, height: badge)
                canvas.fillOval(badgeFrame, color: NSColor.black.withAlphaComponent(0.55))
                canvas.symbol("play.fill", in: badgeFrame, color: .white, inset: InterfaceScale.metric(10), weight: .semibold)
            } else if poster.map(failedMedia.contains) ?? true {
                drawFileTile(symbol: "play.rectangle.fill", filename: filename, in: frame, isCompact: isCompact, on: canvas)
            }
        case let .audio(filename):
            drawFileTile(symbol: "waveform", filename: filename, in: frame, isCompact: isCompact, on: canvas)
        case let .file(filename):
            drawFileTile(symbol: "doc.fill", filename: filename, in: frame, isCompact: isCompact, on: canvas)
        case .spoiler:
            let size = InterfaceScale.metric(isCompact ? 20 : 26)
            let labelHeight = ForumBoardMetrics.lineHeight(of: badgeFont)
            let total = size + InterfaceScale.metric(6) + labelHeight
            canvas.symbol(
                "eye.slash.fill",
                in: CGRect(x: frame.midX - size / 2, y: frame.midY - total / 2, width: size, height: size),
                color: .secondaryLabelColor,
                inset: 0
            )
            canvas.text(
                "SPOILER",
                in: CGRect(x: frame.minX, y: frame.midY - total / 2 + size + InterfaceScale.metric(6), width: frame.width, height: labelHeight),
                font: badgeFont,
                color: .secondaryLabelColor,
                alignment: .center,
                lineBreakMode: .byClipping
            )
        }
        canvas.stroke(frame.insetBy(dx: 0.5, dy: 0.5), cornerRadius: cornerRadius, color: NSColor.separatorColor.withAlphaComponent(0.6))
    }

    private static func drawFileTile(
        symbol: String,
        filename: String,
        in frame: CGRect,
        isCompact: Bool,
        on canvas: ForumCardCanvas
    ) {
        let size = InterfaceScale.metric(isCompact ? 22 : 30)
        let lineHeight = ForumBoardMetrics.lineHeight(of: captionFont)
        let total = size + InterfaceScale.metric(7) + lineHeight * 2
        let top = frame.midY - total / 2
        canvas.symbol(
            symbol,
            in: CGRect(x: frame.midX - size / 2, y: top, width: size, height: size),
            color: .secondaryLabelColor,
            inset: 0
        )
        let inset = InterfaceScale.metric(8)
        canvas.lines(
            filename,
            font: captionFont,
            color: .secondaryLabelColor,
            in: CGRect(x: frame.minX + inset, y: top + size + InterfaceScale.metric(7), width: frame.width - inset * 2, height: lineHeight * 2),
            lineHeight: lineHeight,
            maximumLines: 2
        )
    }

    // MARK: Header and footer

    private static func drawGalleryHeader(_ presentation: ForumCardPresentation, in frame: CGRect, on canvas: ForumCardCanvas) {
        let iconSize = InterfaceScale.metric(12)
        var trailing = frame.maxX
        for (shown, symbol) in [(presentation.isLocked, "lock.fill"), (presentation.isPinned, "pin.fill")] where shown {
            trailing -= iconSize
            drawStatusIcon(symbol, at: CGPoint(x: trailing, y: frame.midY), size: iconSize, on: canvas)
            trailing -= InterfaceScale.metric(6)
        }
        let lineHeight = ForumBoardMetrics.lineHeight(of: captionFont)
        let textY = frame.midY - lineHeight / 2
        var cursorX = frame.minX
        let posted = presentation.relativeTimeText(isGallery: true)
        let postedWidth = ceil(NativeTimelineRowLayout.measuredTextWidth(posted, font: captionFont)) + 1
        if let author = presentation.galleryAuthor {
            let bulletWidth = ceil(NativeTimelineRowLayout.measuredTextWidth(bullet, font: captionFont))
            let available = max(0, trailing - InterfaceScale.metric(6) - cursorX - postedWidth - bulletWidth)
            let font = ProfileNameFontCache.font(id: author.fontID, fallback: captionFont)
            ProfileNameFontLoader.shared.request(id: author.fontID)
            if let dot = author.roleDotColor {
                let dotSize = InterfaceScale.metric(7)
                canvas.fillOval(CGRect(x: cursorX, y: frame.midY - dotSize / 2, width: dotSize, height: dotSize), color: dot)
                cursorX += dotSize + InterfaceScale.metric(4)
            }
            let nameWidth = min(available, ceil(NativeTimelineRowLayout.measuredTextWidth(author.name, font: font)) + 1)
            let nameHeight = ForumBoardMetrics.lineHeight(of: font)
            canvas.text(
                author.name,
                in: CGRect(x: cursorX, y: frame.midY - nameHeight / 2, width: nameWidth, height: nameHeight),
                font: font,
                color: author.color ?? .labelColor
            )
            cursorX += nameWidth
            canvas.text(bullet, in: CGRect(x: cursorX, y: textY, width: bulletWidth, height: lineHeight), font: captionFont, color: .tertiaryLabelColor)
            cursorX += bulletWidth
        }
        canvas.text(
            posted,
            in: CGRect(x: cursorX, y: textY, width: max(0, min(postedWidth, trailing - cursorX)), height: lineHeight),
            font: captionFont,
            color: .secondaryLabelColor
        )
    }

    /// Everything the shared reaction pill draws from besides its frame, so
    /// its cached bitmap redraws when any of it changes, including when its
    /// emoji finishes loading.
    private struct ReactionPillKey: Hashable {
        let reaction: Reaction
        let emojiURL: URL?
        let isEmojiLoaded: Bool
        let isHovered: Bool
        let isDisabled: Bool
        let accent: [CGFloat]
    }

    private static func reactionPillKey(
        _ summary: ForumCardPresentation.ReactionSummary,
        isHovered: Bool,
        model: AppModel?
    ) -> ReactionPillKey {
        let reaction = summary.reaction
        let emojiURL = MessageReactionPresentation.emojiURL(for: reaction, customEmojiURLsByID: model?.customEmojiURLsByID ?? [:])
        return ReactionPillKey(
            reaction: reaction,
            emojiURL: emojiURL,
            isEmojiLoaded: emojiURL.map { NativeTimelineRowPainter.mediaImage(for: .media($0, maximumPixelDimension: 64)) != nil } ?? false,
            isHovered: isHovered,
            isDisabled: summary.isDisabled,
            accent: NSColor.sakuraCordAccentColor.cgColor.components ?? []
        )
    }

    private static func drawFooter(
        _ presentation: ForumCardPresentation,
        regions: ForumCardRegions,
        interaction: ForumCardInteraction,
        model: AppModel?,
        on canvas: ForumCardCanvas
    ) {
        if let summary = presentation.reaction, let frame = regions.reactionRegionFrame {
            let isHovered = interaction.isReactionHovered && !summary.isDisabled
            // The pill comes from the timeline's AppKit painter, so it is
            // pre-rendered here rather than on the worker.
            canvas.prerendered(key: reactionPillKey(summary, isHovered: isHovered, model: model), clip: frame.insetBy(dx: -1, dy: -1)) {
                if summary.isDisabled {
                    NSGraphicsContext.current?.cgContext.setAlpha(0.45)
                }
                NativeTimelineRowPainter.reaction(
                    NativeTimelineRowLayout.reactionRegion(summary.reaction, frame: frame, showsReactors: false),
                    model: model,
                    isHovered: isHovered,
                    hasAnimatedEmojiOverlay: false
                )
            }
        }
        if let frame = regions.countFrame {
            let lineHeight = ForumBoardMetrics.lineHeight(of: footerFont)
            let iconSize = InterfaceScale.metric(13)
            canvas.symbol(
                "bubble.left.fill",
                in: CGRect(x: frame.minX, y: frame.midY - iconSize / 2, width: iconSize, height: iconSize),
                color: .secondaryLabelColor,
                inset: 0
            )
            var cursorX = frame.minX + InterfaceScale.metric(14) + InterfaceScale.metric(4)
            let countWidth = ceil(regions.countTextWidth) + 1
            canvas.text(
                presentation.messageCount.formatted(),
                in: CGRect(x: cursorX, y: frame.midY - lineHeight / 2, width: countWidth, height: lineHeight),
                font: footerFont,
                color: .secondaryLabelColor
            )
            cursorX += countWidth + InterfaceScale.metric(3)
            if let unreadCountText = presentation.unreadCountText {
                canvas.text(
                    "(\(unreadCountText) New)",
                    in: CGRect(x: cursorX, y: frame.midY - lineHeight / 2, width: max(0, frame.maxX - cursorX), height: lineHeight),
                    font: footerEmphasisFont,
                    color: .sakuraCordAccentColor
                )
            }
        }
        if let frame = regions.footerSeparatorFrame {
            let lineHeight = ForumBoardMetrics.lineHeight(of: footerFont)
            canvas.text(
                bullet,
                in: CGRect(x: frame.minX, y: frame.midY - lineHeight / 2, width: frame.width, height: lineHeight),
                font: footerFont,
                color: .tertiaryLabelColor,
                alignment: .center,
                lineBreakMode: .byClipping
            )
        }
        if let frame = regions.timestampFrame {
            let lineHeight = ForumBoardMetrics.lineHeight(of: footerFont)
            canvas.text(
                presentation.relativeTimeText(isGallery: false),
                in: CGRect(x: frame.minX, y: frame.midY - lineHeight / 2, width: frame.width, height: lineHeight),
                font: footerFont,
                color: .secondaryLabelColor
            )
        }
    }

    // MARK: Board chrome

    static func drawSectionHeader(_ title: String, in frame: CGRect, on canvas: ForumCardCanvas) {
        let font = NSFont.interfaceSystemFont(ofSize: 11, weight: .bold)
        let lineHeight = ForumBoardMetrics.lineHeight(of: font)
        canvas.text(
            title.uppercased(),
            in: CGRect(x: frame.minX + InterfaceScale.metric(2), y: frame.maxY - lineHeight - InterfaceScale.metric(4), width: frame.width, height: lineHeight),
            font: font,
            color: .secondaryLabelColor
        )
    }

    /// The failed-page notice; returns its retry button frame.
    static func paginationRetryFrame(in frame: CGRect) -> CGRect {
        let font = NSFont.interfaceSystemFont(ofSize: 13, weight: .medium)
        let width = ceil(NativeTimelineRowLayout.measuredTextWidth("Try Again", font: font)) + InterfaceScale.metric(24)
        let height = InterfaceScale.metric(28)
        return CGRect(x: frame.maxX - InterfaceScale.metric(12) - width, y: frame.midY - height / 2, width: width, height: height)
    }

    static func drawPaginationError(_ message: String, in frame: CGRect, isRetryHovered: Bool, on canvas: ForumCardCanvas) {
        canvas.fill(frame, cornerRadius: InterfaceScale.metric(12), color: NSColor.labelColor.withAlphaComponent(0.06))
        let iconSize = InterfaceScale.metric(16)
        canvas.symbol(
            "exclamationmark.triangle.fill",
            in: CGRect(x: frame.minX + InterfaceScale.metric(12), y: frame.midY - iconSize / 2, width: iconSize, height: iconSize),
            color: .systemOrange,
            inset: 0
        )
        let retry = paginationRetryFrame(in: frame)
        let textX = frame.minX + InterfaceScale.metric(12) + iconSize + InterfaceScale.metric(10)
        let titleFont = NSFont.interfaceSystemFont(ofSize: 13, weight: .semibold)
        let titleHeight = ForumBoardMetrics.lineHeight(of: titleFont)
        let detailHeight = ForumBoardMetrics.lineHeight(of: captionFont)
        let top = frame.midY - (titleHeight + detailHeight) / 2
        canvas.text(
            "Couldn’t load more posts",
            in: CGRect(x: textX, y: top, width: retry.minX - textX - 8, height: titleHeight),
            font: titleFont,
            color: .labelColor
        )
        canvas.text(
            message,
            in: CGRect(x: textX, y: top + titleHeight, width: retry.minX - textX - 8, height: detailHeight),
            font: captionFont,
            color: .secondaryLabelColor
        )
        canvas.fill(retry, cornerRadius: retry.height / 2, color: NSColor.labelColor.withAlphaComponent(isRetryHovered ? 0.16 : 0.1))
        let font = NSFont.interfaceSystemFont(ofSize: 13, weight: .medium)
        let lineHeight = ForumBoardMetrics.lineHeight(of: font)
        canvas.text(
            "Try Again",
            in: CGRect(x: retry.minX, y: retry.midY - lineHeight / 2, width: retry.width, height: lineHeight),
            font: font,
            color: .labelColor,
            alignment: .center,
            lineBreakMode: .byClipping
        )
    }
}
