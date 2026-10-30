import AppKit
import CoreText

/// Covers stay inside their typographic fragment. Insetting rather than
/// expanding leaves a seam between adjacent identities and wrapped lines.
nonisolated enum NativeTimelineTextSpoilerGeometry {
    /// CoreText gives fractional typographic extents; TextKit rounds its line
    /// allocation. Use the same point boundaries for covers, not glyph layout.
    static func alignedVertically(_ fragment: CGRect) -> CGRect {
        let top = fragment.minY.rounded()
        let bottom = fragment.maxY.rounded()
        return CGRect(x: fragment.minX, y: top, width: fragment.width, height: max(0, bottom - top))
    }

    static func coverFrame(_ fragment: CGRect, clippedTo bounds: CGRect) -> CGRect {
        let clipped = fragment.intersection(bounds)
        guard !clipped.isNull, !clipped.isEmpty else { return .null }
        return clipped.insetBy(
            dx: min(0.5, clipped.width / 4),
            dy: min(0.5, clipped.height / 4)
        )
    }

    private static func glyphBounds(in line: CTLine, range: NSRange) -> ClosedRange<CGFloat>? {
        var lower = CGFloat.infinity
        var upper = -CGFloat.infinity
        for value in CTLineGetGlyphRuns(line) as NSArray {
            let run = unsafeDowncast(value as AnyObject, to: CTRun.self)
            let runRange = CTRunGetStringRange(run)
            guard NSIntersectionRange(range, NSRange(location: runRange.location, length: runRange.length)).length > 0 else { continue }
            let count = CTRunGetGlyphCount(run)
            var positions = Array(repeating: CGPoint.zero, count: count)
            var advances = Array(repeating: CGSize.zero, count: count)
            var indices = Array(repeating: CFIndex(0), count: count)
            CTRunGetPositions(run, CFRange(), &positions)
            CTRunGetAdvances(run, CFRange(), &advances)
            CTRunGetStringIndices(run, CFRange(), &indices)
            for index in 0 ..< count where NSLocationInRange(indices[index], range) {
                let start = positions[index].x
                let end = start + advances[index].width
                lower = min(lower, min(start, end))
                upper = max(upper, max(start, end))
            }
        }
        // Caret offsets split kerning adjustments at range boundaries. Glyph
        // advances match TextKit's enclosed glyph range without changing text.
        return lower.isFinite && upper > lower ? lower ... upper : nil
    }

    static func rects(in textFrame: CTFrame, outerFrame: CGRect, range: NSRange) -> [CGRect] {
        let lines = CTFrameGetLines(textFrame) as NSArray
        guard range.length > 0, lines.count > 0 else { return [] }
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(textFrame, CFRange(location: 0, length: lines.count), &origins)
        let lineBounds = (0 ..< lines.count).map { index -> CGRect in
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(coreTextLine(lines[index]), &ascent, &descent, nil)
            return alignedVertically(CGRect(
                x: 0, y: outerFrame.height - origins[index].y - ascent,
                width: outerFrame.width, height: ascent + descent
            )).offsetBy(dx: outerFrame.minX, dy: outerFrame.minY)
        }
        return (0 ..< lines.count).compactMap { index in
            let line = coreTextLine(lines[index])
            let lineRange = CTLineGetStringRange(line)
            let start = max(range.location, lineRange.location)
            let end = min(NSMaxRange(range), lineRange.location + lineRange.length)
            guard start < end else { return nil }
            guard let horizontal = glyphBounds(in: line, range: NSRange(location: start, length: end - start)) else { return nil }
            var fragment = lineBounds[index]
            fragment.origin.x += origins[index].x + horizontal.lowerBound
            fragment.size.width = horizontal.upperBound - horizontal.lowerBound
            // Explicit line-height settings can bring typographic bounds closer
            // than their natural spacing. Share that space without overlapping.
            var minY = max(outerFrame.minY, fragment.minY)
            var maxY = min(outerFrame.maxY, fragment.maxY)
            if index > 0 {
                minY = max(minY, (lineBounds[index - 1].maxY + fragment.minY) / 2)
            }
            if index + 1 < lines.count {
                maxY = min(maxY, (fragment.maxY + lineBounds[index + 1].minY) / 2)
            }
            guard maxY > minY else { return nil }
            let bounds = CGRect(x: outerFrame.minX, y: minY, width: outerFrame.width, height: maxY - minY)
            let cover = coverFrame(fragment, clippedTo: bounds)
            return cover.isNull ? nil : cover
        }
    }
}

@MainActor
enum SelectableTextSpoilerGeometry {
    static func rects(in view: NSTextView) -> [CGRect] {
        guard let storage = view.textStorage, let manager = view.layoutManager,
              let container = view.textContainer else { return [] }
        manager.ensureLayout(for: container)
        let origin = view.textContainerOrigin
        let bounds = CGRect(origin: origin, size: container.containerSize).intersection(view.bounds)
        return NativeTimelineTextSpoilers.ranges(in: storage).flatMap { range in
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            return rects(forGlyphRange: glyphs, manager: manager, container: container,
                         origin: origin, bounds: bounds)
        }
    }

    static func rects(
        forGlyphRange glyphs: NSRange, manager: NSLayoutManager, container: NSTextContainer,
        origin: CGPoint = .zero, bounds: CGRect
    ) -> [CGRect] {
        var result: [CGRect] = []
        // TextKit coalesces equal-width enclosing rectangles across lines.
        // Enumerate one line at a time so every wrapped fragment keeps a seam.
        manager.enumerateLineFragments(forGlyphRange: glyphs) { lineRect, _, _, lineGlyphs, _ in
            let intersection = NSIntersectionRange(glyphs, lineGlyphs)
            guard intersection.length > 0 else { return }
            let lineBounds = NativeTimelineTextSpoilerGeometry.alignedVertically(lineRect)
                .offsetBy(dx: origin.x, dy: origin.y).intersection(bounds)
            manager.enumerateEnclosingRects(
                forGlyphRange: intersection,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { rect, _ in
                let cover = NativeTimelineTextSpoilerGeometry.coverFrame(
                    NativeTimelineTextSpoilerGeometry.alignedVertically(rect)
                        .offsetBy(dx: origin.x, dy: origin.y), clippedTo: lineBounds
                )
                if !cover.isNull { result.append(cover) }
            }
        }
        return result
    }

    static func hiddenSpoilerRange(at point: CGPoint, in view: NSTextView) -> NSRange? {
        guard let storage = view.textStorage, let manager = view.layoutManager,
              let container = view.textContainer else { return nil }
        manager.ensureLayout(for: container)
        let origin = view.textContainerOrigin
        let bounds = CGRect(origin: origin, size: container.containerSize).intersection(view.bounds)
        let ranges = NativeTimelineTextSpoilers.ranges(in: storage)
        guard !ranges.isEmpty else { return nil }
        for range in ranges {
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let frames = rects(
                forGlyphRange: glyphs, manager: manager, container: container,
                origin: origin, bounds: bounds
            )
            if frames.contains(where: { $0.contains(point) }) {
                return range
            }
        }
        return nil
    }

    static func draw(in view: NSTextView, dirtyRect: CGRect) {
        NativeTimelineSpoilerAppearance.textBackgroundColor(isHovered: false).setFill()
        for rect in rects(in: view) where rect.intersects(dirtyRect) {
            NSBezierPath(concentricRoundedRect: rect,
                         cornerRadius: NativeTimelineSpoilerAppearance.textCornerRadius).fill()
        }
    }
}
