import AppKit

nonisolated extension NSFont {
    /// One line's height in this font: its ascent, descent and leading.
    var lineHeight: CGFloat {
        ascender - descender + leading
    }

    /// This font's italic face, or the font itself when it has none.
    var italic: NSFont {
        NSFont(descriptor: fontDescriptor.withSymbolicTraits(.italic), size: pointSize) ?? self
    }
}
