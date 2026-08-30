import AppKit
import AVFoundation
import Combine
import CoreText
import ImageIO
import Lottie
import QuartzCore
import SakuraCordModels
import SwiftUI

final class NativeTimelineMenuAction: NSObject {
    let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func performAction() {
        handler()
    }
}

struct NativeTimelineTextHit {
    let characterIndex: Int
    let url: URL?
    let mention: MentionPresentation?
    let spoilerRange: NSRange?
}

private struct NativeTimelineTextLinkHitRegion {
    let characterIndex: Int
    let url: URL
    let spoilerRange: NSRange?
    let frame: CGRect
}

struct NativeTimelineTextSpoilerHitRegion {
    let range: NSRange
    let frame: CGRect
}

enum NativeTimelineTextGeometry {
    static func messageContentDrawingFrame(_ frame: CGRect) -> CGRect {
        var drawingFrame = frame
        drawingFrame.size.height = max(drawingFrame.height + 1, 20)
        return drawingFrame
    }
}

enum NativeTimelineLinkAppearance {
    static let hoverUnderlineStyle = NSUnderlineStyle.single.rawValue

    static func applyHover(
        to value: NSMutableAttributedString,
        characterIndex: Int?
    ) {
        guard let characterIndex,
              characterIndex >= 0,
              characterIndex < value.length
        else { return }
        var linkRange = NSRange(location: 0, length: 0)
        guard value.attribute(
            .link,
            at: characterIndex,
            effectiveRange: &linkRange
        ) != nil, linkRange.length > 0
        else { return }
        value.addAttribute(
            .underlineStyle,
            value: hoverUnderlineStyle,
            range: linkRange
        )
    }
}

enum NativeTimelineBeginningText {
    static func title(
        _ beginning: NativeTimelineBeginning
    ) -> NativeTimelineAttributedTextBox {
        box(
            beginning.title,
            font: .systemFont(
                ofSize: NSFont.preferredFont(
                    forTextStyle: .largeTitle
                ).pointSize,
                weight: .bold
            ),
            color: .labelColor
        )
    }

    static func description(
        _ beginning: NativeTimelineBeginning
    ) -> NativeTimelineAttributedTextBox {
        box(
            beginning.description,
            font: .preferredFont(forTextStyle: .body),
            color: .secondaryLabelColor
        )
    }

    static func box(
        _ value: String,
        font: NSFont,
        color: NSColor
    ) -> NativeTimelineAttributedTextBox {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return NativeTimelineAttributedTextBox(
            NSAttributedString(
                string: value,
                attributes: [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: paragraph,
                ]
            )
        )
    }
}

nonisolated enum NativeTimelineTextSelectionGeometry {
    static func interactionFrame(
        contentFrame: CGRect,
        rowOrigin: CGFloat,
        canvasWidth: CGFloat
    ) -> CGRect {
        CGRect(
            x: contentFrame.minX,
            y: rowOrigin + contentFrame.minY,
            width: max(1, canvasWidth - contentFrame.minX),
            height: max(1, contentFrame.height)
        )
    }

    static func intersects(
        characterRange: CFRange,
        selectionRange: NSRange?
    ) -> Bool {
        guard let selectionRange else { return false }
        return NSIntersectionRange(
            selectionRange,
            NSRange(
                location: characterRange.location,
                length: max(1, characterRange.length)
            )
        ).length > 0
    }

    static func backgroundRanges(
        in value: NSAttributedString,
        selectionRange: NSRange
    ) -> [NSRange] {
        let available = NSRange(location: 0, length: value.length)
        let selection = NSIntersectionRange(selectionRange, available)
        guard selection.length > 0 else { return [] }

        var attachments: [NSRange] = []
        value.enumerateAttributes(in: selection) { attributes, range, _ in
            guard attributes[.discordEmojiToken] != nil
                    || attributes[.nativeTimelineMention] != nil
            else { return }
            let clipped = NSIntersectionRange(range, selection)
            if clipped.length > 0 {
                attachments.append(clipped)
            }
        }
        guard !attachments.isEmpty else { return [selection] }
        attachments.sort {
            $0.location == $1.location
                ? $0.length < $1.length
                : $0.location < $1.location
        }

        var result: [NSRange] = []
        var cursor = selection.location
        let selectionEnd = NSMaxRange(selection)
        for attachment in attachments {
            if attachment.location > cursor {
                result.append(NSRange(
                    location: cursor,
                    length: attachment.location - cursor
                ))
            }
            cursor = max(cursor, NSMaxRange(attachment))
        }
        if cursor < selectionEnd {
            result.append(NSRange(
                location: cursor,
                length: selectionEnd - cursor
            ))
        }
        return result
    }

    static func rects(
        in textFrame: CTFrame,
        outerFrame: CGRect,
        range: NSRange
    ) -> [CGRect] {
        guard range.length > 0 else { return [] }
        let lines = CTFrameGetLines(textFrame) as NSArray
        guard lines.count > 0 else { return [] }
        var origins = Array(
            repeating: CGPoint.zero,
            count: lines.count
        )
        CTFrameGetLineOrigins(
            textFrame,
            CFRange(location: 0, length: lines.count),
            &origins
        )
        let selectionStart = range.location
        let selectionEnd = NSMaxRange(range)
        var result: [CGRect] = []
        result.reserveCapacity(lines.count)

        for index in 0 ..< lines.count {
            let line = coreTextLine(lines[index])
            let lineRange = CTLineGetStringRange(line)
            let lineStart = lineRange.location
            let lineEnd = lineRange.location + lineRange.length
            let start = max(selectionStart, lineStart)
            let end = min(selectionEnd, lineEnd)
            guard start < end else { continue }

            let origin = origins[index]
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(
                line,
                &ascent,
                &descent,
                &leading
            )
            let startOffset = CTLineGetOffsetForStringIndex(
                line,
                start,
                nil
            )
            let endOffset = CTLineGetOffsetForStringIndex(
                line,
                end,
                nil
            )
            let minX = outerFrame.minX
                + origin.x
                + min(startOffset, endOffset)
            let width = max(1, abs(endOffset - startOffset))
            result.append(CGRect(
                x: minX,
                y: outerFrame.maxY - origin.y - ascent - 0.5,
                width: width,
                height: max(1, ascent + descent + 1)
            ))
        }
        return result
    }
}

nonisolated struct NativeTimelineCodeBlockRegion: Equatable {
    let range: NSRange
    let backgroundFrame: CGRect
    let copyButtonFrame: CGRect
    let content: String
}

nonisolated enum NativeTimelineCodeBlockGeometry {
    struct LineRange {
        let range: NSRange
        let startsBlock: Bool
    }

    static func regions(
        value: NSAttributedString,
        framesetter: CTFramesetter,
        frame: CGRect
    ) -> [NativeTimelineCodeBlockRegion] {
        guard value.length > 0,
              frame.width > 0,
              frame.height > 0,
              containsCodeBlock(value)
        else { return [] }
        let path = CGPath(
            rect: CGRect(origin: .zero, size: frame.size),
            transform: nil
        )
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: value.length),
            path,
            nil
        )
        return regions(
            in: textFrame,
            outerFrame: frame,
            value: value
        )
    }

    static func regions(
        in textFrame: CTFrame,
        outerFrame: CGRect,
        value: NSAttributedString
    ) -> [NativeTimelineCodeBlockRegion] {
        guard value.length > 0 else { return [] }
        let fullRange = NSRange(location: 0, length: value.length)
        var lines: [LineRange] = []
        value.enumerateAttribute(
            .discordMarkdownBlock,
            in: fullRange
        ) { rawValue, range, _ in
            guard rawValue as? String == "code",
                  range.length > 0
            else { return }
            let paragraph = value.attribute(
                .paragraphStyle,
                at: range.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
            lines.append(LineRange(
                range: range,
                startsBlock:
                    (paragraph?.paragraphSpacingBefore ?? 0) > 0
            ))
        }
        guard !lines.isEmpty else { return [] }

        var groups: [[LineRange]] = []
        for line in lines {
            if line.startsBlock || groups.isEmpty {
                groups.append([line])
            } else {
                groups[groups.count - 1].append(line)
            }
        }

        let source = value.string as NSString
        return groups.compactMap { group in
            guard let first = group.first,
                  let last = group.last
            else { return nil }
            let range = NSRange(
                location: first.range.location,
                length: NSMaxRange(last.range)
                    - first.range.location
            )
            let rects = group.flatMap {
                NativeTimelineTextSelectionGeometry.rects(
                    in: textFrame,
                    outerFrame: outerFrame,
                    range: $0.range
                )
            }
            guard let firstRect = rects.first else { return nil }
            let union = rects.dropFirst().reduce(firstRect) {
                $0.union($1)
            }
            let backgroundFrame = CGRect(
                x: outerFrame.minX,
                y: union.minY
                    - NativeTimelineMarkdownChromeMetrics
                        .codeBlockInset,
                width: outerFrame.width,
                height: union.height
                    + NativeTimelineMarkdownChromeMetrics
                        .codeBlockInset * 2
            )
            let buttonWidth: CGFloat = 28
            let buttonFrame = CGRect(
                x: max(
                    backgroundFrame.minX,
                    backgroundFrame.maxX - buttonWidth - 4
                ),
                y: backgroundFrame.minY + 4,
                width: buttonWidth,
                height: buttonWidth
            )
            return NativeTimelineCodeBlockRegion(
                range: range,
                backgroundFrame: backgroundFrame,
                copyButtonFrame: buttonFrame,
                content: source.substring(with: range)
            )
        }
    }

    static func containsCodeBlock(
        _ value: NSAttributedString
    ) -> Bool {
        var result = false
        value.enumerateAttribute(
            .discordMarkdownBlock,
            in: NSRange(location: 0, length: value.length),
            options: .longestEffectiveRangeNotRequired
        ) { rawValue, _, stop in
            guard rawValue as? String == "code" else { return }
            result = true
            stop.pointee = true
        }
        return result
    }
}

enum NativeTimelineTextHitTester {
    static func spoilerRegions(
        value: NSAttributedString,
        framesetter: CTFramesetter,
        frame: CGRect
    ) -> [NativeTimelineTextSpoilerHitRegion] {
        guard value.length > 0,
              frame.width > 0,
              frame.height > 0
        else { return [] }
        let path = CGPath(
            rect: CGRect(origin: .zero, size: frame.size),
            transform: nil
        )
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: value.length),
            path,
            nil
        )
        return spoilerRegions(
            value: value,
            textFrame: textFrame,
            frame: frame
        )
    }

    private static func spoilerRegions(
        value: NSAttributedString,
        textFrame: CTFrame,
        frame: CGRect
    ) -> [NativeTimelineTextSpoilerHitRegion] {
        var result: [NativeTimelineTextSpoilerHitRegion] = []
        value.enumerateAttribute(
            .discordMarkdownSpoiler,
            in: NSRange(location: 0, length: value.length)
        ) { rawValue, range, _ in
            guard (rawValue as? NSNumber)?.boolValue == true else {
                return
            }
            result.append(contentsOf:
                NativeTimelineTextSelectionGeometry.rects(
                    in: textFrame,
                    outerFrame: frame,
                    range: range
                ).map {
                    NativeTimelineTextSpoilerHitRegion(
                        range: range,
                        frame: $0.insetBy(dx: -2, dy: -1)
                    )
                }
            )
        }
        return result
    }

    static func linkFrames(
        value: NSAttributedString,
        framesetter: CTFramesetter,
        frame: CGRect
    ) -> [CGRect] {
        guard value.length > 0,
              frame.width > 0,
              frame.height > 0
        else { return [] }
        let path = CGPath(
            rect: CGRect(origin: .zero, size: frame.size),
            transform: nil
        )
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: value.length),
            path,
            nil
        )
        return linkRegions(
            value: value,
            textFrame: textFrame,
            outerFrame: frame
        ).map(\.frame)
    }

    private static func linkRegions(
        value: NSAttributedString,
        textFrame: CTFrame,
        outerFrame: CGRect
    ) -> [NativeTimelineTextLinkHitRegion] {
        var result: [NativeTimelineTextLinkHitRegion] = []
        value.enumerateAttribute(
            .link,
            in: NSRange(location: 0, length: value.length)
        ) { rawLink, range, _ in
            guard let url = linkURL(from: rawLink) else { return }
            var spoilerRange = NSRange(location: 0, length: 0)
            let isSpoiler = (
                value.attribute(
                    .discordMarkdownSpoiler,
                    at: range.location,
                    effectiveRange: &spoilerRange
                ) as? NSNumber
            )?.boolValue == true
            let frames = bridgedLinkFrames(
                NativeTimelineTextSelectionGeometry.rects(
                    in: textFrame,
                    outerFrame: outerFrame,
                    range: range
                )
            )
            result.append(contentsOf: frames.map {
                NativeTimelineTextLinkHitRegion(
                    characterIndex: range.location,
                    url: url,
                    spoilerRange:
                        isSpoiler && spoilerRange.length > 0
                            ? spoilerRange
                            : nil,
                    frame: $0
                )
            })
        }
        return result
    }

    private static func bridgedLinkFrames(
        _ frames: [CGRect]
    ) -> [CGRect] {
        let frames = frames.sorted {
            $0.minY == $1.minY
                ? $0.minX < $1.minX
                : $0.minY < $1.minY
        }
        guard var previous = frames.first else { return [] }
        var result = [previous]
        for current in frames.dropFirst() {
            let gapHeight = current.minY - previous.maxY
            if gapHeight > 0 {
                let minX = min(previous.minX, current.minX)
                let maxX = max(previous.maxX, current.maxX)
                result.append(CGRect(
                    x: minX,
                    y: previous.maxY,
                    width: max(1, maxX - minX),
                    height: gapHeight
                ))
            }
            result.append(current)
            previous = current
        }
        return result
    }

    private static func linkURL(from rawLink: Any?) -> URL? {
        switch rawLink {
        case let value as URL:
            value
        case let value as NSURL:
            value as URL
        case let value as String:
            URL(string: value)
        default:
            nil
        }
    }

    static func mention(
        value: NSAttributedString,
        framesetter: CTFramesetter,
        frame: CGRect,
        point: CGPoint
    ) -> MentionPresentation? {
        hit(
            value: value,
            framesetter: framesetter,
            frame: frame,
            point: point
        )?.mention
    }

    static func mentionRegions(
        value: NSAttributedString,
        framesetter: CTFramesetter,
        frame: CGRect
    ) -> [NativeTimelineMentionHitRegion] {
        guard value.length > 0,
              frame.width > 0,
              frame.height > 0
        else { return [] }
        let path = CGPath(
            rect: CGRect(origin: .zero, size: frame.size),
            transform: nil
        )
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: value.length),
            path,
            nil
        )
        let lines = CTFrameGetLines(textFrame) as NSArray
        guard lines.count > 0 else { return [] }
        var origins = Array(
            repeating: CGPoint.zero,
            count: lines.count
        )
        CTFrameGetLineOrigins(
            textFrame,
            CFRange(location: 0, length: lines.count),
            &origins
        )
        var result: [NativeTimelineMentionHitRegion] = []
        for index in 0 ..< lines.count {
            let line = coreTextLine(lines[index])
            let lineOrigin = origins[index]
            for case let run as CTRun
                in CTLineGetGlyphRuns(line) as NSArray
            {
                let range = CTRunGetStringRange(run)
                guard range.location >= 0,
                      range.location < value.length,
                      let mention = (
                          value.attribute(
                              .nativeTimelineMention,
                              at: range.location,
                              effectiveRange: nil
                          ) as? NativeTimelineMentionBox
                      )?.presentation
                else { continue }
                result.append(NativeTimelineMentionHitRegion(
                    characterIndex: range.location,
                    presentation: mention,
                    frame: inlineAttachmentFrame(
                        run: run,
                        line: line,
                        lineOrigin: lineOrigin,
                        outerFrame: frame
                    )
                ))
            }
        }
        return result
    }

    static func mentionAnchorFrame(
        box: NativeTimelineAttributedTextBox,
        frame: CGRect,
        characterIndex: Int,
        rawToken: String
    ) -> CGRect? {
        var drawingFrame = frame
        drawingFrame.size.height += box.layoutHeightAdjustment
        return mentionAnchorFrame(
            value: box.value,
            framesetter: box.framesetter,
            frame: drawingFrame,
            characterIndex: characterIndex,
            rawToken: rawToken
        )
    }

    static func rangeFrame(
        value: NSAttributedString,
        framesetter: CTFramesetter,
        frame: CGRect,
        range: NSRange
    ) -> CGRect? {
        guard value.length > 0,
              range.location >= 0,
              range.length > 0,
              NSMaxRange(range) <= value.length,
              frame.width > 0,
              frame.height > 0
        else { return nil }
        let path = CGPath(
            rect: CGRect(origin: .zero, size: frame.size),
            transform: nil
        )
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: value.length),
            path,
            nil
        )
        let lines = CTFrameGetLines(textFrame) as NSArray
        guard lines.count > 0 else { return nil }
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(
            textFrame,
            CFRange(location: 0, length: lines.count),
            &origins
        )
        var result: CGRect?
        for lineIndex in 0 ..< lines.count {
            let line = coreTextLine(lines[lineIndex])
            let lineRange = NSRange(
                location: CTLineGetStringRange(line).location,
                length: CTLineGetStringRange(line).length
            )
            let intersection = NSIntersectionRange(lineRange, range)
            guard intersection.length > 0 else { continue }
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(
                line,
                &ascent,
                &descent,
                &leading
            )
            let lineOrigin = origins[lineIndex]
            let startX = lineOrigin.x + CTLineGetOffsetForStringIndex(
                line,
                intersection.location,
                nil
            )
            let endX = lineOrigin.x + CTLineGetOffsetForStringIndex(
                line,
                NSMaxRange(intersection),
                nil
            )
            let height = max(1, ascent + descent + leading)
            let localBottom = lineOrigin.y - descent
            let segment = CGRect(
                x: frame.minX + min(startX, endX),
                y: frame.maxY - localBottom - height,
                width: max(1, abs(endX - startX)),
                height: height
            )
            result = result.map { $0.union(segment) } ?? segment
        }
        guard let result,
              [result.minX, result.minY, result.width, result.height]
                .allSatisfy(\.isFinite),
              !result.isEmpty
        else { return nil }
        return result
    }

    static func mentionAnchorFrame(
        value: NSAttributedString,
        framesetter: CTFramesetter,
        frame: CGRect,
        characterIndex: Int,
        rawToken: String
    ) -> CGRect? {
        guard value.length > 0,
              value.string.indices.isEmpty == false,
              value.length > characterIndex,
              characterIndex >= 0,
              frame.width > 0,
              frame.height > 0
        else { return nil }
        var effectiveRange = NSRange(location: 0, length: 0)
        guard let mention = value.attribute(
            .nativeTimelineMention,
            at: characterIndex,
            effectiveRange: &effectiveRange
        ) as? NativeTimelineMentionBox,
            mention.presentation.rawToken == rawToken,
            effectiveRange.length > 0
        else { return nil }

        let path = CGPath(
            rect: CGRect(origin: .zero, size: frame.size),
            transform: nil
        )
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: value.length),
            path,
            nil
        )
        let lines = CTFrameGetLines(textFrame) as NSArray
        guard lines.count > 0 else { return nil }
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(
            textFrame,
            CFRange(location: 0, length: lines.count),
            &origins
        )
        var anchor: CGRect?
        for lineIndex in 0 ..< lines.count {
            let line = coreTextLine(lines[lineIndex])
            let lineOrigin = origins[lineIndex]
            for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
                let range = CTRunGetStringRange(run)
                guard range.location <= characterIndex,
                      characterIndex
                        < range.location + max(1, range.length)
                else { continue }
                anchor = inlineAttachmentFrame(
                    run: run,
                    line: line,
                    lineOrigin: lineOrigin,
                    outerFrame: frame
                )
                break
            }
            if anchor != nil { break }
        }
        guard let anchor else { return nil }
        let values = [
            anchor.minX,
            anchor.minY,
            anchor.width,
            anchor.height,
        ]
        return values.allSatisfy(\.isFinite) && !anchor.isEmpty
            ? anchor
            : nil
    }

    static func inlineAttachmentFrame(
        run: CTRun,
        line: CTLine,
        lineOrigin: CGPoint,
        outerFrame: CGRect
    ) -> CGRect {
        let range = CTRunGetStringRange(run)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTRunGetTypographicBounds(
            run,
            CFRange(location: 0, length: 0),
            &ascent,
            &descent,
            &leading
        ))
        let horizontalPosition = lineOrigin.x + CTLineGetOffsetForStringIndex(
            line,
            range.location,
            nil
        )
        let height = max(1, ascent + descent)
        let localBottom = lineOrigin.y - descent
        return CGRect(
            x: outerFrame.minX + horizontalPosition,
            y: outerFrame.maxY - localBottom - height,
            width: max(1, width),
            height: height
        )
    }

    static func hit(
        box: NativeTimelineAttributedTextBox,
        frame: CGRect,
        point: CGPoint
    ) -> NativeTimelineTextHit? {
        var drawingFrame = frame
        drawingFrame.size.height += box.layoutHeightAdjustment
        return hit(
            value: box.value,
            framesetter: box.framesetter,
            frame: drawingFrame,
            point: point
        )
    }

    static var textHitOperation:
        @MainActor (NSAttributedString, CTFramesetter, CGRect, CGPoint) -> NativeTimelineTextHit?
    {
        { value, framesetter, frame, point in
        guard value.length > 0,
              frame.width > 0,
              frame.height > 0,
              frame.contains(point)
        else { return nil }

        let path = CGPath(
            rect: CGRect(origin: .zero, size: frame.size),
            transform: nil
        )
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: value.length),
            path,
            nil
        )
        let lines = CTFrameGetLines(textFrame) as NSArray
        guard lines.count > 0 else { return nil }
        var origins = Array(
            repeating: CGPoint.zero,
            count: lines.count
        )
        CTFrameGetLineOrigins(
            textFrame,
            CFRange(location: 0, length: lines.count),
            &origins
        )
        let paintedSpoiler = spoilerRegions(
            value: value,
            textFrame: textFrame,
            frame: frame
        ).first(where: { $0.frame.contains(point) })
        // Inline mentions are taller than the surrounding text line. Check
        // their exact painted run rectangles first so the whole visible pill,
        // including its top and bottom padding, is clickable.
        for index in 0 ..< lines.count {
            let line = coreTextLine(lines[index])
            let lineOrigin = origins[index]
            for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
                let range = CTRunGetStringRange(run)
                let attachmentFrame = inlineAttachmentFrame(
                    run: run,
                    line: line,
                    lineOrigin: lineOrigin,
                    outerFrame: frame
                )
                guard range.location >= 0,
                      range.location < value.length,
                      attachmentFrame.contains(point)
                else { continue }
                var spoilerRange = NSRange(location: 0, length: 0)
                let isSpoiler = (
                    value.attribute(
                        .discordMarkdownSpoiler,
                        at: range.location,
                        effectiveRange: &spoilerRange
                    ) as? NSNumber
                )?.boolValue == true
                let mention = (
                    value.attribute(
                        .nativeTimelineMention,
                        at: range.location,
                        effectiveRange: nil
                    ) as? NativeTimelineMentionBox
                )?.presentation
                let effectiveSpoilerRange =
                    paintedSpoiler?.range
                    ?? (isSpoiler && spoilerRange.length > 0
                        ? spoilerRange
                        : nil)
                if let effectiveSpoilerRange {
                    return NativeTimelineTextHit(
                        characterIndex: range.location,
                        url: nil,
                        mention: mention,
                        spoilerRange: effectiveSpoilerRange
                    )
                }
                guard let mention else { continue }
                return NativeTimelineTextHit(
                    characterIndex: range.location,
                    url: nil,
                    mention: mention,
                    spoilerRange: nil
                )
            }
        }
        if let link = linkRegions(
            value: value,
            textFrame: textFrame,
            outerFrame: frame
        ).first(where: { $0.frame.contains(point) }) {
            return NativeTimelineTextHit(
                characterIndex: link.characterIndex,
                url: link.url,
                mention: nil,
                spoilerRange: link.spoilerRange
            )
        }
        let local = CGPoint(
            x: point.x - frame.minX,
            y: frame.maxY - point.y
        )
        for index in 0 ..< lines.count {
            let line = coreTextLine(lines[index])
            let origin = origins[index]
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(
                line,
                &ascent,
                &descent,
                &leading
            ))
            guard local.y >= origin.y - descent,
                  local.y <= origin.y + ascent + leading,
                  local.x >= origin.x,
                  local.x <= origin.x + max(1, width)
            else { continue }

            let stringIndex = CTLineGetStringIndexForPosition(
                line,
                CGPoint(x: local.x - origin.x, y: 0)
            )
            guard stringIndex != kCFNotFound else { return nil }
            let lineRange = CTLineGetStringRange(line)
            guard lineRange.length > 0 else { return nil }
            let characterIndex = min(
                value.length - 1,
                max(
                    lineRange.location,
                    min(
                        stringIndex,
                        lineRange.location + lineRange.length - 1
                    )
                )
            )
            let mention = (
                value.attribute(
                    .nativeTimelineMention,
                    at: characterIndex,
                    effectiveRange: nil
                ) as? NativeTimelineMentionBox
            )?.presentation
            let rawLink = value.attribute(
                .link,
                at: characterIndex,
                effectiveRange: nil
            )
            var spoilerRange = NSRange(location: 0, length: 0)
            let isSpoiler = (
                value.attribute(
                    .discordMarkdownSpoiler,
                    at: characterIndex,
                    effectiveRange: &spoilerRange
                ) as? NSNumber
            )?.boolValue == true
            let url = linkURL(from: rawLink)
            return NativeTimelineTextHit(
                characterIndex: characterIndex,
                url: url,
                mention: mention,
                spoilerRange:
                    isSpoiler && spoilerRange.length > 0
                        ? spoilerRange
                        : nil
            )
        }
        if let paintedSpoiler {
            return NativeTimelineTextHit(
                characterIndex: paintedSpoiler.range.location,
                url: nil,
                mention: nil,
                spoilerRange: paintedSpoiler.range
            )
        }
        return nil

        }
    }

    static func hit(
        value: NSAttributedString,
        framesetter: CTFramesetter,
        frame: CGRect,
        point: CGPoint
    ) -> NativeTimelineTextHit? {
        textHitOperation(value, framesetter, frame, point)
    }

    static func caretIndex(
        box: NativeTimelineAttributedTextBox,
        frame: CGRect,
        point: CGPoint,
        clampsToText: Bool
    ) -> Int? {
        var drawingFrame = frame
        drawingFrame.size.height += box.layoutHeightAdjustment
        return caretIndex(
            value: box.value,
            framesetter: box.framesetter,
            frame: drawingFrame,
            point: point,
            clampsToText: clampsToText
        )
    }

    static var clampedCaretIndexOperation:
        @MainActor (NSAttributedString, CTFramesetter, CGRect, CGPoint, Bool) -> Int?
    {
        { value, framesetter, frame, point, clampsToText in
        guard value.length > 0,
              frame.width > 0,
              frame.height > 0,
              clampsToText || frame.contains(point)
        else { return nil }
        let path = CGPath(
            rect: CGRect(origin: .zero, size: frame.size),
            transform: nil
        )
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: value.length),
            path,
            nil
        )
        let lines = CTFrameGetLines(textFrame) as NSArray
        guard lines.count > 0 else { return nil }
        var origins = Array(
            repeating: CGPoint.zero,
            count: lines.count
        )
        CTFrameGetLineOrigins(
            textFrame,
            CFRange(location: 0, length: lines.count),
            &origins
        )
        let local = CGPoint(
            x: point.x - frame.minX,
            y: frame.maxY - point.y
        )
        if clampsToText {
            let firstLine = coreTextLine(lines[0])
            let lastLine = coreTextLine(lines[lines.count - 1])
            let firstOrigin = origins[0]
            let lastOrigin = origins[lines.count - 1]
            var firstAscent: CGFloat = 0
            var firstDescent: CGFloat = 0
            var firstLeading: CGFloat = 0
            _ = CTLineGetTypographicBounds(
                firstLine,
                &firstAscent,
                &firstDescent,
                &firstLeading
            )
            var lastAscent: CGFloat = 0
            var lastDescent: CGFloat = 0
            var lastLeading: CGFloat = 0
            _ = CTLineGetTypographicBounds(
                lastLine,
                &lastAscent,
                &lastDescent,
                &lastLeading
            )
            if local.y > firstOrigin.y + firstAscent + firstLeading {
                return max(0, CTLineGetStringRange(firstLine).location)
            }
            if local.y < lastOrigin.y - lastDescent {
                let range = CTLineGetStringRange(lastLine)
                return min(value.length, range.location + range.length)
            }
        }
        var selectedLineIndex: Int?
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for index in 0 ..< lines.count {
            let line = coreTextLine(lines[index])
            let origin = origins[index]
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(
                line,
                &ascent,
                &descent,
                &leading
            )
            let lower = origin.y - descent
            let upper = origin.y + ascent + leading
            if local.y >= lower, local.y <= upper {
                selectedLineIndex = index
                break
            }
            guard clampsToText else { continue }
            let distance = local.y < lower
                ? lower - local.y
                : local.y - upper
            if distance < nearestDistance {
                nearestDistance = distance
                selectedLineIndex = index
            }
        }
        guard let selectedLineIndex else { return nil }
        let line = coreTextLine(lines[selectedLineIndex])
        let origin = origins[selectedLineIndex]
        let lineRange = CTLineGetStringRange(line)
        guard lineRange.length > 0 else { return nil }
        let width = CGFloat(CTLineGetTypographicBounds(
            line,
            nil,
            nil,
            nil
        ))
        if !clampsToText,
           local.x < origin.x || local.x > origin.x + max(1, width)
        {
            return nil
        }
        if local.x <= origin.x {
            return lineRange.location
        }
        if local.x >= origin.x + width {
            return min(
                value.length,
                lineRange.location + lineRange.length
            )
        }
        let index = CTLineGetStringIndexForPosition(
            line,
            CGPoint(x: local.x - origin.x, y: 0)
        )
        guard index != kCFNotFound else { return nil }
        return min(value.length, max(0, index))

        }
    }

    static func caretIndex(
        value: NSAttributedString,
        framesetter: CTFramesetter,
        frame: CGRect,
        point: CGPoint,
        clampsToText: Bool
    ) -> Int? {
        clampedCaretIndexOperation(value, framesetter, frame, point, clampsToText)
    }
}
