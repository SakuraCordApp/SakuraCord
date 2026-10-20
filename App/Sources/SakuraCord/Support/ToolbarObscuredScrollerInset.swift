import AppKit

extension NSScrollView {
    /// Content scrolls beneath the window toolbar's glass, but the overlay
    /// scroller starts below it. Call from `tile()`; the inset follows the
    /// scroll view's position, the window's toolbar and full-screen changes.
    /// Returns whether the obscured height changed.
    @discardableResult
    func keepScrollerBelowWindowToolbar() -> Bool {
        guard let window else { return false }
        let frameInWindow = convert(bounds, to: nil)
        let obscuredHeight = max(0, frameInWindow.maxY - window.contentLayoutRect.maxY)
        guard abs(scrollerInsets.top - obscuredHeight) > 0.25 else { return false }
        var insets = scrollerInsets
        insets.top = obscuredHeight
        scrollerInsets = insets
        return true
    }
}
