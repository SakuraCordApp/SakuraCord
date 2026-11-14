import AppKit
import CoreText
@testable import SakuraCord
import Testing

@MainActor @Test(arguments: [CGFloat(80), 160, 320], [CGFloat(11), 15, 24, 36])
func `spoiler fragments stay separate and route hits to their own identity`(width: CGFloat, fontSize: CGFloat) throws {
    let sources = [
        "||one|| ||two||", "||one||||two||", "||above||\n||below||",
        "||A long hidden sentence wrapping across several lines|| ||next||",
        "||[link](https://example.com) 😀 <:wave:456>|| ||**bold** and *italic*||"
    ]
    for source in sources {
        let value = NativeTimelineCoreText.make(
            prepared: RichMessageAttributedText.prepare(source: source), emojiSize: fontSize + 3,
            baseFontSize: fontSize, mentionPresentations: [:]
        )
        let frame = CGRect(x: 10, y: 20, width: width, height: 1_000)
        let framesetter = CTFramesetterCreateWithAttributedString(value)
        let ranges = NativeTimelineTextSpoilers.ranges(in: value)
        let regions = NativeTimelineTextHitTester.spoilerRegions(value: value, framesetter: framesetter, frame: frame)
        #expect(Set(regions.map(\.range)) == Set(ranges))
        for (index, region) in regions.enumerated() {
            #expect(frame.contains(region.frame))
            for other in regions.dropFirst(index + 1) {
                #expect(region.frame.intersection(other.frame).isEmpty)
            }
            let hit = NativeTimelineTextHitTester.hit(value: value, framesetter: framesetter, frame: frame,
                point: CGPoint(x: region.frame.midX, y: region.frame.midY))
            #expect(hit?.spoilerRange == region.range)
        }
        if ranges.count == 2 {
            #expect(NativeTimelineTextSpoilers.hiddenRanges(in: value, revealedLocations: [ranges[0].location]) == [ranges[1]])
        }
    }
}

@MainActor @Test(arguments: [CGFloat(80), 160, 320], [CGFloat(11), 15, 24, 36])
func `selectable spoiler fragments preserve separate masked identities`(width: CGFloat, fontSize: CGFloat) throws {
    let source = "||one||||two||\n||above||\n||below||\n||Long hidden text wrapping over several lines [link](https://example.com) 😀 <:wave:456>||"
    let value = NSMutableAttributedString(attributedString: RichMessageAttributedText.make(
        source: source, emojiSize: fontSize + 3, baseFontSize: fontSize, mentionPresentations: [:]
    ))
    let ranges = NativeTimelineTextSpoilers.ranges(in: value)
    RichMessageAttributedText.concealSpoilers(in: value)
    #expect(NativeTimelineTextSpoilers.ranges(in: value) == ranges)
    for range in ranges {
        value.enumerateAttributes(in: range) { attributes, _, _ in
            #expect(attributes[.link] == nil)
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                #expect(!(attachment is MentionTextAttachment))
                #expect(attachment.image?.accessibilityDescription == nil)
            }
            #expect((attributes[.foregroundColor] as? NSColor)?.alphaComponent == 0)
        }
    }
    let view = RichMessageNSTextView(frame: CGRect(x: 0, y: 0, width: width, height: 1_000))
    view.textContainerInset = .zero
    view.textContainer?.lineFragmentPadding = 0
    view.textContainer?.containerSize = view.bounds.size
    view.textStorage?.setAttributedString(value)
    let rects = SelectableTextSpoilerGeometry.rects(in: view)
    #expect(rects.count >= ranges.count)
    let manager = try #require(view.layoutManager)
    let container = try #require(view.textContainer)
    var lineBounds: [CGRect] = []
    manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { rect, _, _, _, _ in
        lineBounds.append(rect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y))
    }
    for (index, rect) in rects.enumerated() {
        #expect(view.bounds.contains(rect))
        #expect(lineBounds.contains { $0.contains(rect) })
        for other in rects.dropFirst(index + 1) {
            #expect(rect.intersection(other).isEmpty)
        }
    }
}

@MainActor @Test func `forum spoiler covers stay inside their preview and reveal independently`() throws {
    let store = NativeTimelineSpoilerRevealStore()
    let preview = ForumPostPreviewTextView()
    preview.configure(.init(messageID: .init(rawValue: 8_610),
        source: "||one||||two||\n||above||\n||a longer wrapped spoiler below||",
        mentionPresentations: [:], fontSize: 24, emojiSize: 27, maximumNumberOfLines: 8,
        isEmphasized: false, underlinesLinks: false, prefix: nil), revealStore: store)
    preview.frame = CGRect(origin: .zero, size: preview.measuredSize(proposedWidth: 140))
    let ranges = NativeTimelineTextSpoilers.ranges(in: preview.contentForTesting)
    let frames = ranges.flatMap { preview.hiddenSpoilerFrames(for: $0) }
    #expect(frames.count >= ranges.count)
    for (index, frame) in frames.enumerated() {
        #expect(preview.bounds.contains(frame))
        for other in frames.dropFirst(index + 1) { #expect(frame.intersection(other).isEmpty) }
    }
    for range in ranges {
        for frame in preview.hiddenSpoilerFrames(for: range) {
            #expect(preview.hiddenSpoilerLocation(at: CGPoint(x: frame.midX, y: frame.midY)) == range.location)
        }
    }
    #expect(preview.accessibilityValue() as? String == "SpoilerSpoiler\nSpoiler\nSpoiler")
}
