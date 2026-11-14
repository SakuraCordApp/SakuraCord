import AppKit

nonisolated extension NSFont {
    /// One line's height in this font: its ascent, descent and leading.
    var lineHeight: CGFloat {
        ascender - descender + leading
    }
}
