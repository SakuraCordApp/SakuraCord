import AppKit

enum NativeTimelineLinkAppearance {
    static let hoverUnderlineStyle = NSUnderlineStyle.single.rawValue

    static func applyHover(
        to value: NSMutableAttributedString,
        characterIndex: Int?,
        underlinesAllLinks: Bool = false
    ) {
        if underlinesAllLinks {
            value.enumerateAttribute(.link, in: NSRange(location: 0, length: value.length)) { link, range, _ in
                guard link != nil else { return }
                value.addAttribute(.underlineStyle, value: hoverUnderlineStyle, range: range)
            }
            return
        }
        guard let characterIndex,
              characterIndex >= 0,
              characterIndex < value.length
        else { return }
        var linkRange = NSRange(location: 0, length: 0)
        guard value.attribute(
            .link,
            at: characterIndex,
            longestEffectiveRange: &linkRange,
            in: NSRange(location: 0, length: value.length)
        ) != nil, linkRange.length > 0
        else { return }
        value.addAttribute(
            .underlineStyle,
            value: hoverUnderlineStyle,
            range: linkRange
        )
    }
}
