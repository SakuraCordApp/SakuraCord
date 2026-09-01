import AppKit
import CoreText
import SakuraCordModels

nonisolated struct NativeMemberActivityEmojiRegion: Equatable {
    let rawToken: String
    let frame: CGRect

    var reference: EmojiReference {
        EmojiReference(rawToken: rawToken)
    }
}

nonisolated enum NativeMemberActivityPresentation {
    private static let emojiExpression = RegularExpressionFactory.make(
        #"<(a?):([A-Za-z0-9_~]+):([0-9]+)>"#
    )
    private static let runDelegateKey = NSAttributedString.Key(
        rawValue: kCTRunDelegateAttributeName as String
    )

    static func line(
        _ source: String,
        font: NSFont,
        color: NSColor
    ) -> CTLine {
        let output = NSMutableAttributedString()
        let sourceString = source as NSString
        let matches = emojiExpression.matches(
            in: source,
            range: NSRange(location: 0, length: sourceString.length)
        )
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                output.append(text(
                    sourceString.substring(with: NSRange(
                        location: cursor,
                        length: match.range.location - cursor
                    )),
                    font: font,
                    color: color
                ))
            }
            let rawToken = sourceString.substring(with: match.range)
            var attributes: [NSAttributedString.Key: Any] = [
                .discordEmojiToken: rawToken,
                .font: font,
                .foregroundColor: color,
            ]
            attributes[runDelegateKey] = NativeTimelineRunDelegate.make(
                width: NativeMemberListMetrics.activityEmojiSize,
                height: NativeMemberListMetrics.activityEmojiSize,
                baselineOffset: ComposerEmojiAttributedText.attachmentOriginY(
                    font: font,
                    size: NativeMemberListMetrics.activityEmojiSize
                )
            )
            output.append(NSAttributedString(
                string: "\u{FFFC}",
                attributes: attributes
            ))
            cursor = NSMaxRange(match.range)
        }
        if cursor < sourceString.length {
            output.append(text(
                sourceString.substring(from: cursor),
                font: font,
                color: color
            ))
        }
        return CTLineCreateWithAttributedString(output)
    }

    static func emojiRegions(
        in line: CTLine,
        origin: CGPoint
    ) -> [NativeMemberActivityEmojiRegion] {
        var lineAscent: CGFloat = 0
        CTLineGetTypographicBounds(line, &lineAscent, nil, nil)
        var result: [NativeMemberActivityEmojiRegion] = []
        for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let rawToken = attributes[NSAttributedString.Key.discordEmojiToken]
                as? String
            else { continue }
            let range = CTRunGetStringRange(run)
            guard range.location >= 0 else { continue }
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CGFloat(CTRunGetTypographicBounds(
                run,
                CFRange(location: 0, length: 0),
                &ascent,
                &descent,
                nil
            ))
            let horizontalOffset = origin.x + CTLineGetOffsetForStringIndex(
                line,
                range.location,
                nil
            )
            result.append(NativeMemberActivityEmojiRegion(
                rawToken: rawToken,
                frame: CGRect(
                    x: horizontalOffset,
                    y: origin.y + lineAscent - ascent,
                    width: max(1, width),
                    height: max(1, ascent + descent)
                )
            ))
        }
        return result
    }

    static func references(in source: String?) -> [EmojiReference] {
        guard let source, !source.isEmpty else { return [] }
        let sourceString = source as NSString
        return emojiExpression.matches(
            in: source,
            range: NSRange(location: 0, length: sourceString.length)
        ).map {
            EmojiReference(rawToken: sourceString.substring(with: $0.range))
        }
    }

    static func accessibilityText(_ source: String) -> String {
        let output = NSMutableString(string: source)
        let sourceString = source as NSString
        let matches = emojiExpression.matches(
            in: source,
            range: NSRange(location: 0, length: sourceString.length)
        )
        for match in matches.reversed() {
            let reference = EmojiReference(
                rawToken: sourceString.substring(with: match.range)
            )
            output.replaceCharacters(
                in: match.range,
                with: reference.accessibilityLabel
            )
        }
        return output as String
    }

    private static func text(
        _ value: String,
        font: NSFont,
        color: NSColor
    ) -> NSAttributedString {
        NSAttributedString(
            string: value,
            attributes: [.font: font, .foregroundColor: color]
        )
    }
}
