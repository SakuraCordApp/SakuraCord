import AppKit
import AVFoundation
import Combine
import CoreText
import ImageIO
import Lottie
import QuartzCore
import SakuraCordModels
import SwiftUI

extension NativeTimelineRowPainter {
    private struct SingleLineTextInput {
        let sourceLine: CTLine
        let sourceWidth: CGFloat
        let frame: CGRect
        let font: NSFont
        let color: NSColor
        let alignment: NSTextAlignment
        let lineBreakMode: NSLineBreakMode
        let concealedSpoilerRanges: [NSRange]
        let context: CGContext
    }

    static func mediaPlayGlyph(in frame: CGRect) {
        guard let image = NativeTimelineSystemSymbolCache.configuredImage(
            named: "play.circle.fill",
            pointSize: 36,
            weight: .regular,
            color: .white
        ) else { return }
        let imageSize = image.size
        let imageFrame = CGRect(
            x: frame.midX - imageSize.width / 2,
            y: frame.midY - imageSize.height / 2,
            width: imageSize.width,
            height: imageSize.height
        )
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        shadow.set()
        image.draw(in: imageFrame)
        NSGraphicsContext.restoreGraphicsState()
        // A single tint fills the symbol's knocked-out triangle, so it is
        // drawn again in a contrasting color.
        guard let triangle = NativeTimelineSystemSymbolCache.configuredImage(
            named: "play.fill",
            pointSize: 15,
            weight: .regular,
            color: NSColor.black.withAlphaComponent(0.75)
        ) else { return }
        triangle.draw(in: CGRect(
            // The triangle's visual centre sits left of its bounding box.
            x: frame.midX - triangle.size.width / 2 + 1.5,
            y: frame.midY - triangle.size.height / 2,
            width: triangle.size.width,
            height: triangle.size.height
        ))
    }

    static func text(
        _ value: String,
        in frame: CGRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left,
        lineBreakMode: NSLineBreakMode = .byTruncatingTail,
        isInteractiveHovered: Bool = false,
        concealedSpoilerRanges: [NSRange] = []
    ) {
        guard frame.width > 0, frame.height > 0 else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        var attributed = coreTextValue(
            value,
            font: font,
            color: color,
            alignment: alignment,
            lineBreakMode: lineBreakMode,
            isInteractiveHovered: isInteractiveHovered
        )
        if !concealedSpoilerRanges.isEmpty {
            let concealed = NSMutableAttributedString(attributedString: attributed as NSAttributedString)
            for range in concealedSpoilerRanges {
                NativeTimelineSpoilerAppearance.concealText(in: concealed, range: range)
            }
            attributed = concealed as CFAttributedString
        }
        let sourceLine = CTLineCreateWithAttributedString(attributed)
        let sourceWidth = CGFloat(CTLineGetTypographicBounds(sourceLine, nil, nil, nil))
        let usesSingleLine = !value.contains("\n")
            && (lineBreakMode != .byWordWrapping || sourceWidth <= frame.width)
        if usesSingleLine {
            drawSingleLineText(SingleLineTextInput(
                sourceLine: sourceLine,
                sourceWidth: sourceWidth,
                frame: frame,
                font: font,
                color: color,
                alignment: alignment,
                lineBreakMode: lineBreakMode,
                concealedSpoilerRanges: concealedSpoilerRanges,
                context: context
            ))
        } else {
            drawMultilineText(attributed, in: frame, context: context)
        }
    }

    private static func coreTextValue(
        _ value: String,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment,
        lineBreakMode: NSLineBreakMode,
        isInteractiveHovered: Bool
    ) -> CFAttributedString {
        var textAlignment: CTTextAlignment = switch alignment {
        case .center: .center
        case .right: .right
        case .justified: .justified
        case .natural: .natural
        default: .left
        }
        var breakMode: CTLineBreakMode = switch lineBreakMode {
        case .byCharWrapping: .byCharWrapping
        case .byClipping: .byClipping
        case .byTruncatingHead: .byTruncatingHead
        case .byTruncatingMiddle: .byTruncatingMiddle
        case .byWordWrapping: .byWordWrapping
        default: .byTruncatingTail
        }
        let paragraph = withUnsafePointer(to: &textAlignment) { alignmentPointer in
            withUnsafePointer(to: &breakMode) { breakPointer in
                let settings = [
                    CTParagraphStyleSetting(
                        spec: .alignment,
                        valueSize: MemoryLayout<CTTextAlignment>.size,
                        value: alignmentPointer
                    ),
                    CTParagraphStyleSetting(
                        spec: .lineBreakMode,
                        valueSize: MemoryLayout<CTLineBreakMode>.size,
                        value: breakPointer
                    ),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        // NSFont and CTFont are toll-free bridged. Recreating the font from
        // `fontName` turns system fonts into `.SFNS-*` names, which
        // CoreText explicitly rejects and may substitute with Times New Roman.
        let coreFont = font as CTFont
        var attributes: [CFString: Any] = [
            kCTFontAttributeName: coreFont,
            kCTForegroundColorAttributeName: color.cgColor,
            kCTParagraphStyleAttributeName: paragraph,
        ]
        if isInteractiveHovered {
            attributes[kCTUnderlineStyleAttributeName] =
                NativeTimelineLinkAppearance.hoverUnderlineStyle
        }
        return CFAttributedStringCreate(
            nil,
            value as CFString,
            attributes as CFDictionary
        )!
    }

    private static func drawSingleLineText(_ input: SingleLineTextInput) {
        let sourceLine = input.sourceLine
        let sourceWidth = input.sourceWidth
        let frame = input.frame
        let font = input.font
        let color = input.color
        let alignment = input.alignment
        let lineBreakMode = input.lineBreakMode
        let context = input.context
        let line = truncatedLine(
            sourceLine,
            sourceWidth: sourceWidth,
            maximumWidth: frame.width,
            font: font,
            color: color,
            lineBreakMode: lineBreakMode
        )
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let horizontalPosition: CGFloat = switch alignment {
        case .center: max(0, (frame.width - lineWidth) / 2)
        case .right: max(0, frame.width - lineWidth)
        default: 0
        }
        let baseline = max(descent, (frame.height - ascent - descent - leading) / 2 + descent)
        for range in input.concealedSpoilerRanges {
            let startX = CTLineGetOffsetForStringIndex(sourceLine, range.location, nil)
            let endX = min(
                CTLineGetOffsetForStringIndex(sourceLine, NSMaxRange(range), nil),
                lineWidth
            )
            guard endX > startX else { continue }
            let fragment = CGRect(
                x: frame.minX + horizontalPosition + startX,
                y: frame.maxY - baseline - ascent,
                width: endX - startX,
                height: ascent + descent
            )
            let box = NativeTimelineTextSpoilerGeometry.coverFrame(fragment, clippedTo: frame)
            guard !box.isNull else { continue }
            NativeTimelineSpoilerAppearance.textBackgroundColor(isHovered: false).setFill()
            NSBezierPath(
                roundedRect: box,
                xRadius: NativeTimelineSpoilerAppearance.textCornerRadius,
                yRadius: NativeTimelineSpoilerAppearance.textCornerRadius
            ).fill()
        }
        context.saveGState()
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: horizontalPosition, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func truncatedLine(
        _ sourceLine: CTLine,
        sourceWidth: CGFloat,
        maximumWidth: CGFloat,
        font: NSFont,
        color: NSColor,
        lineBreakMode: NSLineBreakMode
    ) -> CTLine {
        guard sourceWidth > maximumWidth,
              lineBreakMode == .byTruncatingHead
                || lineBreakMode == .byTruncatingMiddle
                || lineBreakMode == .byTruncatingTail
        else { return sourceLine }
        let token = CTLineCreateWithAttributedString(CFAttributedStringCreate(
            nil,
            "…" as CFString,
            [
                kCTFontAttributeName: font as CTFont,
                kCTForegroundColorAttributeName: color.cgColor,
            ] as CFDictionary
        )!)
        let truncation: CTLineTruncationType = switch lineBreakMode {
        case .byTruncatingHead: .start
        case .byTruncatingMiddle: .middle
        default: .end
        }
        return CTLineCreateTruncatedLine(sourceLine, Double(maximumWidth), truncation, token)
            ?? sourceLine
    }

    private static func drawMultilineText(
        _ attributed: CFAttributedString,
        in frame: CGRect,
        context: CGContext
    ) {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(
            rect: CGRect(origin: .zero, size: frame.size),
            transform: nil
        )
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )
        context.saveGState()
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        CTFrameDraw(textFrame, context)
        context.restoreGState()
    }

    static func attributedText(
        _ box: NativeTimelineAttributedTextBox,
        in frame: CGRect,
        model: AppModel?,
        selectionRange: NSRange? = nil,
        hoveredMentionCharacterIndex: Int? = nil,
        hoveredLinkCharacterIndex: Int? = nil,
        hoveredSpoilerRangeLocation: Int? = nil,
        revealedSpoilerLocations: Set<Int> = []
    ) {
        var drawingFrame = frame
        drawingFrame.size.height += box.layoutHeightAdjustment
        attributedText(
            box.value,
            framesetter: box.framesetter,
            in: drawingFrame,
            model: model,
            selectionRange: selectionRange,
            hoveredMentionCharacterIndex:
                hoveredMentionCharacterIndex,
            hoveredLinkCharacterIndex:
                hoveredLinkCharacterIndex,
            hoveredSpoilerRangeLocation:
                hoveredSpoilerRangeLocation,
            revealedSpoilerLocations: revealedSpoilerLocations
        )
    }

    static func attributedText(
        _ value: NSAttributedString,
        in frame: CGRect,
        model: AppModel?
    ) {
        attributedText(
            value,
            framesetter: CTFramesetterCreateWithAttributedString(value),
            in: frame,
            model: model
        )
    }

    static func attributedText(
        _ value: NSAttributedString,
        framesetter: CTFramesetter,
        in frame: CGRect,
        model: AppModel?,
        mentionBackgroundColor: NSColor? = nil,
        selectionRange: NSRange? = nil,
        hoveredMentionCharacterIndex: Int? = nil,
        hoveredLinkCharacterIndex: Int? = nil,
        hoveredSpoilerRangeLocation: Int? = nil,
        revealedSpoilerLocations: Set<Int> = []
    ) {
        guard frame.width > 0, frame.height > 0,
              let context = NSGraphicsContext.current?.cgContext
        else { return }
        let (drawingValue, drawingFramesetter) = preparedDrawingText(
            value,
            framesetter: framesetter,
            hoveredLinkCharacterIndex: hoveredLinkCharacterIndex,
            underlinesLinks: model?.accessibilitySettings.underlinesLinks == true,
            revealedSpoilerLocations: revealedSpoilerLocations
        )
        let path = CGPath(rect: CGRect(origin: .zero, size: frame.size), transform: nil)
        let textFrame = CTFramesetterCreateFrame(
            drawingFramesetter,
            CFRange(location: 0, length: drawingValue.length),
            path,
            nil
        )
        drawMarkdownBlocks(
            in: textFrame,
            outerFrame: frame,
            attributedText: drawingValue,
            hoveredSpoilerRangeLocation: hoveredSpoilerRangeLocation
        )
        drawTextSelection(
            selectionRange,
            in: textFrame,
            outerFrame: frame,
            attributedText: drawingValue
        )
        context.saveGState()
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        CTFrameDraw(textFrame, context)
        context.restoreGState()
        drawInlineAttachments(
            in: textFrame,
            outerFrame: frame,
            attributedText: drawingValue,
            model: model,
            mentionBackgroundColor: mentionBackgroundColor,
            selectionRange: selectionRange,
            hoveredMentionCharacterIndex: hoveredMentionCharacterIndex
        )
    }

    private static func preparedDrawingText(
        _ value: NSAttributedString,
        framesetter: CTFramesetter,
        hoveredLinkCharacterIndex: Int?,
        underlinesLinks: Bool,
        revealedSpoilerLocations: Set<Int>
    ) -> (NSAttributedString, CTFramesetter) {
        let fullRange = NSRange(location: 0, length: value.length)
        let spoilerRanges = NativeTimelineTextSpoilers.ranges(in: value)
        var hasUnderlinedLinks = false
        if underlinesLinks {
            value.enumerateAttribute(.link, in: fullRange) { link, _, stop in
                guard link != nil else { return }
                hasUnderlinedLinks = true
                stop.pointee = true
            }
        }
        if spoilerRanges.isEmpty, hoveredLinkCharacterIndex == nil, !hasUnderlinedLinks {
            return (value, framesetter)
        }
        let drawing = NSMutableAttributedString(attributedString: value)
        NativeTimelineLinkAppearance.applyHover(
            to: drawing,
            characterIndex: hoveredLinkCharacterIndex,
            underlinesAllLinks: underlinesLinks
        )
        // Conceal last so no earlier color adjustment can repaint hidden text.
        for range in spoilerRanges {
            if revealedSpoilerLocations.contains(range.location) {
                drawing.removeAttribute(.discordMarkdownSpoiler, range: range)
            } else {
                NativeTimelineSpoilerAppearance.concealText(in: drawing, range: range)
            }
        }
        return (drawing, CTFramesetterCreateWithAttributedString(drawing))
    }

    private static func drawTextSelection(
        _ selectionRange: NSRange?,
        in textFrame: CTFrame,
        outerFrame: CGRect,
        attributedText: NSAttributedString
    ) {
        if let selectionRange, selectionRange.length > 0 {
            textSelectionHighlightColor.setFill()
            for backgroundRange
                in NativeTimelineTextSelectionGeometry.backgroundRanges(
                    in: attributedText,
                    selectionRange: selectionRange
                )
            {
                for selectionRect in NativeTimelineTextSelectionGeometry.rects(
                    in: textFrame,
                    outerFrame: outerFrame,
                    range: backgroundRange
                ) {
                    selectionRect.fill()
                }
            }
        }
    }

    private struct MarkdownDecorationRects {
        var quotes: [CGRect] = []
        var inlineCode: [CGRect] = []
        var spoilers: [(CGRect, Bool)] = []
        var listMarkers: [CGRect] = []
    }

    static func drawMarkdownBlocks(
        in textFrame: CTFrame,
        outerFrame: CGRect,
        attributedText: NSAttributedString,
        hoveredSpoilerRangeLocation: Int? = nil
    ) {
        guard attributedText.length > 0 else { return }
        let decorations = markdownDecorationRects(
            in: textFrame,
            outerFrame: outerFrame,
            attributedText: attributedText,
            hoveredSpoilerRangeLocation: hoveredSpoilerRangeLocation
        )
        let codeBlocks = NativeTimelineCodeBlockGeometry.regions(
            in: textFrame,
            outerFrame: outerFrame,
            value: attributedText
        )
        drawInlineCodeDecorations(decorations.inlineCode)
        drawSpoilerDecorations(decorations.spoilers)
        drawCodeBlockDecorations(codeBlocks)
        drawListMarkerDecorations(decorations.listMarkers)
        drawQuoteDecorations(decorations.quotes, outerFrame: outerFrame)
    }

    private static func markdownDecorationRects(
        in textFrame: CTFrame,
        outerFrame: CGRect,
        attributedText: NSAttributedString,
        hoveredSpoilerRangeLocation: Int?
    ) -> MarkdownDecorationRects {
        let fullRange = NSRange(location: 0, length: attributedText.length)
        var result = MarkdownDecorationRects()
        attributedText.enumerateAttribute(
            .discordMarkdownInlineCode,
            in: fullRange
        ) { rawValue, range, _ in
            guard (rawValue as? NSNumber)?.boolValue == true else {
                return
            }
            result.inlineCode.append(
                contentsOf:
                    NativeTimelineTextSelectionGeometry.rects(
                        in: textFrame,
                        outerFrame: outerFrame,
                        range: range
                )
            )
        }
        for range in NativeTimelineTextSpoilers.ranges(in: attributedText) {
            result.spoilers.append(
                contentsOf:
                    NativeTimelineTextSpoilerGeometry.rects(
                        in: textFrame,
                        outerFrame: outerFrame,
                        range: range
                    ).map {
                        (
                            $0,
                            hoveredSpoilerRangeLocation == range.location
                        )
                    }
            )
        }
        attributedText.enumerateAttribute(
            .discordMarkdownListMarker,
            in: fullRange
        ) { rawValue, range, _ in
            guard (rawValue as? NSNumber)?.boolValue == true else {
                return
            }
            result.listMarkers.append(
                contentsOf:
                    NativeTimelineTextSelectionGeometry.rects(
                        in: textFrame,
                        outerFrame: outerFrame,
                        range: range
                    )
            )
        }
        attributedText.enumerateAttribute(
            .discordMarkdownBlock,
            in: fullRange
        ) { rawValue, range, _ in
            guard let block = rawValue as? String else { return }
            let rects = NativeTimelineTextSelectionGeometry.rects(
                in: textFrame,
                outerFrame: outerFrame,
                range: range
            )
            switch block {
            case "quote":
                result.quotes.append(contentsOf: rects)
            default:
                break
            }
        }
        return result
    }

    private static func drawInlineCodeDecorations(_ rects: [CGRect]) {
        for inlineRect in rects {
            let backgroundFrame = inlineRect.insetBy(dx: -4, dy: -2)
            discordCodeBackgroundColor.setFill()
            NSBezierPath(
                concentricRoundedRect: backgroundFrame,
                cornerRadius: 4
            ).fill()
            discordCodeBorderColor.setStroke()
            let border = NSBezierPath(
                concentricRoundedRect: backgroundFrame.insetBy(dx: 0.5, dy: 0.5),
                cornerRadius: 4
            )
            border.lineWidth = 1
            border.stroke()
        }
    }

    private static func drawSpoilerDecorations(_ rects: [(CGRect, Bool)]) {
        for (spoilerRect, isHovered) in rects {
            let backgroundFrame = spoilerRect
            NativeTimelineSpoilerAppearance.textBackgroundColor(
                isHovered: isHovered
            ).setFill()
            NSBezierPath(
                concentricRoundedRect: backgroundFrame,
                cornerRadius:
                    NativeTimelineSpoilerAppearance.textCornerRadius
            ).fill()
        }
    }

    private static func drawCodeBlockDecorations(
        _ codeBlocks: [NativeTimelineCodeBlockRegion]
    ) {
        for codeBlock in codeBlocks {
            let backgroundFrame = codeBlock.backgroundFrame
            discordCodeBackgroundColor.setFill()
            NSBezierPath(
                concentricRoundedRect: backgroundFrame,
                cornerRadius: 4
            ).fill()
            discordCodeBorderColor.setStroke()
            let border = NSBezierPath(
                concentricRoundedRect: backgroundFrame.insetBy(dx: 0.5, dy: 0.5),
                cornerRadius: 4
            )
            border.lineWidth = 1
            border.stroke()
        }
    }

    private static func drawListMarkerDecorations(_ rects: [CGRect]) {
        NSColor.labelColor.setFill()
        for markerRect in rects {
            let diameter: CGFloat = 6
            NSBezierPath(ovalIn: CGRect(
                x: markerRect.midX - diameter / 2,
                y: markerRect.midY - diameter / 2,
                width: diameter,
                height: diameter
            )).fill()
        }
    }

    private static func drawQuoteDecorations(
        _ rects: [CGRect],
        outerFrame: CGRect
    ) {
        for group in verticallyContiguousGroups(rects) {
            guard let union = group.reduce(nil, {
                ($0 as CGRect?)?.union($1) ?? $1
            }) else { continue }
            let bar = CGRect(
                x: outerFrame.minX + 1,
                y: union.minY - 1,
                width: 4,
                height: union.height + 2
            )
            NSColor.secondaryLabelColor.withAlphaComponent(0.65).setFill()
            NSBezierPath(
                roundedRect: bar,
                xRadius: 2,
                yRadius: 2
            ).fill()
        }
    }

    static let discordCodeBackgroundColor = NSColor(
        srgbRed: 13 / 255,
        green: 14 / 255,
        blue: 27 / 255,
        alpha: 1
    )

    static let discordCodeBorderColor = NSColor(
        srgbRed: 46 / 255,
        green: 47 / 255,
        blue: 59 / 255,
        alpha: 1
    )

    static func verticallyContiguousGroups(
        _ rects: [CGRect]
    ) -> [[CGRect]] {
        let sorted = rects.sorted {
            if abs($0.minY - $1.minY) >= 0.5 {
                return $0.minY < $1.minY
            }
            return $0.minX < $1.minX
        }
        var groups: [[CGRect]] = []
        for rect in sorted {
            guard let last = groups.last,
                  let union = last.reduce(nil, {
                      ($0 as CGRect?)?.union($1) ?? $1
                  }),
                  rect.minY - union.maxY <= 4
            else {
                groups.append([rect])
                continue
            }
            groups[groups.count - 1].append(rect)
        }
        return groups
    }

    enum InlineAttachmentDraw {
        case image(NSImage, CGRect, selectionFrame: CGRect?)
        case mention(
            MentionPresentation,
            CGRect,
            characterIndex: Int,
            selectionFrame: CGRect?
        )
        case emojiFallback(CGRect, selectionFrame: CGRect?)

        var selectionFrame: CGRect? {
            switch self {
            case let .image(_, _, selectionFrame),
                 let .mention(_, _, _, selectionFrame),
                 let .emojiFallback(_, selectionFrame):
                selectionFrame
            }
        }
    }

    private struct InlineAttachmentContext {
        let textFrame: CTFrame
        let outerFrame: CGRect
        let attributedText: NSAttributedString
        let model: AppModel?
        let selectionRange: NSRange?
    }

    static func drawInlineAttachments(
        in textFrame: CTFrame,
        outerFrame: CGRect,
        attributedText: NSAttributedString,
        model: AppModel?,
        mentionBackgroundColor: NSColor? = nil,
        selectionRange: NSRange?,
        hoveredMentionCharacterIndex: Int?
    ) {
        let draws = inlineAttachmentDraws(
            in: textFrame,
            outerFrame: outerFrame,
            attributedText: attributedText,
            model: model,
            selectionRange: selectionRange
        )
        for draw in draws {
            renderInlineAttachment(
                draw,
                mentionBackgroundColor: mentionBackgroundColor,
                hoveredMentionCharacterIndex: hoveredMentionCharacterIndex
            )
        }
    }

    private static func inlineAttachmentDraws(
        in textFrame: CTFrame,
        outerFrame: CGRect,
        attributedText: NSAttributedString,
        model: AppModel?,
        selectionRange: NSRange?
    ) -> [InlineAttachmentDraw] {
        let lines = CTFrameGetLines(textFrame) as NSArray
        guard lines.count > 0 else { return [] }
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(
            textFrame,
            CFRange(location: 0, length: lines.count),
            &origins
        )
        var draws: [InlineAttachmentDraw] = []
        draws.reserveCapacity(4)
        let context = InlineAttachmentContext(
            textFrame: textFrame,
            outerFrame: outerFrame,
            attributedText: attributedText,
            model: model,
            selectionRange: selectionRange
        )

        for index in 0 ..< lines.count {
            let line = coreTextLine(lines[index])
            let lineOrigin = origins[index]
            let runs = CTLineGetGlyphRuns(line) as NSArray
            for case let run as CTRun in runs {
                if let draw = inlineAttachmentDraw(
                    for: run,
                    line: line,
                    lineOrigin: lineOrigin,
                    context: context
                ) {
                    draws.append(draw)
                }
            }
        }
        return draws
    }

    private static func inlineAttachmentDraw(
        for run: CTRun,
        line: CTLine,
        lineOrigin: CGPoint,
        context: InlineAttachmentContext
    ) -> InlineAttachmentDraw? {
        let textFrame = context.textFrame
        let outerFrame = context.outerFrame
        let attributedText = context.attributedText
        let model = context.model
        let selectionRange = context.selectionRange
        let range = CTRunGetStringRange(run)
        guard range.location >= 0, range.location < attributedText.length else { return nil }
        let mention = (attributedText.attribute(
            .nativeTimelineMention,
            at: range.location,
            effectiveRange: nil
        ) as? NativeTimelineMentionBox)?.presentation
        let emojiToken = attributedText.attribute(
            .discordEmojiToken,
            at: range.location,
            effectiveRange: nil
        ) as? String
        guard mention != nil || emojiToken != nil else { return nil }
        let isHiddenSpoiler = attributedText.attribute(
            .discordMarkdownSpoiler,
            at: range.location,
            effectiveRange: nil
        ) != nil
        guard !isHiddenSpoiler else { return nil }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTRunGetTypographicBounds(
            run, CFRange(location: 0, length: 0), &ascent, &descent, nil
        ))
        let horizontalOffset = lineOrigin.x
            + CTLineGetOffsetForStringIndex(line, range.location, nil)
        let size = CGSize(width: max(1, width), height: max(1, ascent + descent))
        let frame = CGRect(
            x: outerFrame.minX + horizontalOffset,
            y: outerFrame.maxY - (lineOrigin.y - descent) - size.height,
            width: size.width,
            height: size.height
        )
        let selectionFrame = inlineAttachmentSelectionFrame(
            range: range,
            selectionRange: selectionRange,
            textFrame: textFrame,
            outerFrame: outerFrame
        )
        if let mention {
            return .mention(
                mention, frame, characterIndex: range.location, selectionFrame: selectionFrame
            )
        }
        guard let emojiToken,
              let image = inlineEmojiImage(token: emojiToken, model: model)
        else { return .emojiFallback(frame, selectionFrame: selectionFrame) }
        return .image(image, frame, selectionFrame: selectionFrame)
    }

    private static func inlineAttachmentSelectionFrame(
        range: CFRange,
        selectionRange: NSRange?,
        textFrame: CTFrame,
        outerFrame: CGRect
    ) -> CGRect? {
        guard NativeTimelineTextSelectionGeometry.intersects(
            characterRange: range,
            selectionRange: selectionRange
        ) else { return nil }
        return NativeTimelineTextSelectionGeometry.rects(
            in: textFrame,
            outerFrame: outerFrame,
            range: NSRange(location: range.location, length: max(1, range.length))
        ).first
    }

    private static func renderInlineAttachment(
        _ draw: InlineAttachmentDraw,
        mentionBackgroundColor: NSColor?,
        hoveredMentionCharacterIndex: Int?
    ) {
        switch draw {
        case let .image(image, frame, _):
            drawImage(image, in: frame, cornerRadius: 0, fillsFrame: false)
        case let .mention(presentation, frame, characterIndex, _):
            drawMention(
                presentation,
                in: frame,
                isHovered: hoveredMentionCharacterIndex == characterIndex,
                backgroundColor: mentionBackgroundColor
            )
        case let .emojiFallback(frame, _):
            text(
                "🙂",
                in: frame,
                font: .systemFont(ofSize: max(11, frame.height * 0.8)),
                color: .labelColor,
                alignment: .center
            )
        }
        if let selectionFrame = draw.selectionFrame {
            attachmentSelectionHighlightColor.setFill()
            selectionFrame.fill()
        }
    }

    static var textSelectionHighlightColor: NSColor {
        NSColor.sakuraCordTextSelectionBackgroundColor
    }

    static var attachmentSelectionHighlightColor: NSColor {
        NSColor.sakuraCordTextSelectionBackgroundColor.withAlphaComponent(0.5)
    }

    static func drawMention(
        _ presentation: MentionPresentation,
        in frame: CGRect,
        isHovered: Bool,
        backgroundColor: NSColor? = nil
    ) {
        let color = roleColor(presentation.colorHex) ?? .sakuraCordAccentColor
        let labelColor = backgroundColor.map {
            contrastingMentionTextColor(
                mentionColor: color,
                isHovered: isHovered,
                backgroundColor: $0
            )
        } ?? color
        let shape = NSBezierPath(
            concentricRoundedRect: frame,
            cornerRadius: 5.5
        )
        color.withAlphaComponent(
            NativeTimelineMentionAppearance.backgroundAlpha(
                isHovered: isHovered
            )
        ).setFill()
        shape.fill()
        if case .role = presentation.target,
           SakuraCordAccentColor.usesAccentFallback(
               forRoleColorHex: presentation.colorHex
           )
        {
            color.withAlphaComponent(isHovered ? 0.9 : 0.7).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }

        var labelX = frame.minX + 6
        if let systemImage = presentation.systemImage {
            let iconSize = max(10, frame.height - 7)
            let iconFrame = CGRect(
                x: labelX,
                y: frame.midY - iconSize / 2,
                width: iconSize,
                height: iconSize
            )
            if let image = NativeTimelineSystemSymbolCache.configuredImage(
                named: systemImage,
                pointSize: iconSize,
                weight: .semibold,
                color: color
            ) {
                drawImage(
                    image,
                    in: iconFrame,
                    cornerRadius: 0,
                    fillsFrame: false
                )
            }
            labelX = iconFrame.maxX + 4
        } else if case .user = presentation.target {
            let avatarSize = max(10, frame.height - 6)
            let avatarFrame = CGRect(
                x: labelX,
                y: frame.midY - avatarSize / 2,
                width: avatarSize,
                height: avatarSize
            )
            if let url = presentation.avatarURL,
               let image = mediaImage(for: .avatar(url))
            {
                drawImage(
                    image,
                    in: avatarFrame,
                    cornerRadius: avatarSize / 2,
                    fillsFrame: true
                )
            } else {
                color.withAlphaComponent(0.38).setFill()
                NSBezierPath(ovalIn: avatarFrame).fill()
            }
            labelX = avatarFrame.maxX + 4
        }
        text(
            presentation.label,
            in: CGRect(
                x: labelX,
                y: frame.minY,
                width: max(1, frame.maxX - labelX - 6),
                height: frame.height
            ),
            font: .systemFont(ofSize: 15, weight: .semibold),
            color: labelColor
        )
    }

    private static func contrastingMentionTextColor(
        mentionColor: NSColor,
        isHovered: Bool,
        backgroundColor: NSColor
    ) -> NSColor {
        guard let mention = mentionColor.usingColorSpace(.deviceRGB),
              let background = backgroundColor.usingColorSpace(.deviceRGB)
        else { return .white }

        let alpha = NativeTimelineMentionAppearance.backgroundAlpha(
            isHovered: isHovered
        )
        let red = mention.redComponent * alpha
            + background.redComponent * (1 - alpha)
        let green = mention.greenComponent * alpha
            + background.greenComponent * (1 - alpha)
        let blue = mention.blueComponent * alpha
            + background.blueComponent * (1 - alpha)
        let luminance = 0.2126 * linearSRGB(red)
            + 0.7152 * linearSRGB(green)
            + 0.0722 * linearSRGB(blue)
        let blackContrast = (luminance + 0.05) / 0.05
        let whiteContrast = 1.05 / (luminance + 0.05)
        return whiteContrast >= blackContrast ? .white : .black
    }

    private static func linearSRGB(_ component: CGFloat) -> CGFloat {
        let component = min(max(component, 0), 1)
        if component <= 0.04045 {
            return component / 12.92
        }
        return pow((component + 0.055) / 1.055, 2.4)
    }

    static func inlineEmojiImage(
        token: String,
        model: AppModel?
    ) -> NSImage? {
        let reference = EmojiReference(rawToken: token)
        if let url =
            reference.id.flatMap({ model?.customEmojiURLsByID[$0] })
                ?? reference.imageURL(size: 64),
           let image = mediaImage(
               for: .media(url, maximumPixelDimension: 64)
           )
        {
            return image
        }
        return nil
    }

    static func roleColor(_ value: UInt32?) -> NSColor? {
        guard let value, value != 0 else { return nil }
        return NSColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    static func measuredTextWidth(
        _ value: String,
        font: NSFont
    ) -> CGFloat {
        let attributed = NSAttributedString(
            string: value,
            attributes: [.font: font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

}
