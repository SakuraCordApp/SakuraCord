import AppKit

extension NSView {
    /// The first view of `type` in a depth-first walk from this view.
    func firstDescendant<View: NSView>(of type: View.Type) -> View? {
        if let match = self as? View {
            return match
        }
        for child in subviews {
            if let match = child.firstDescendant(of: type) {
                return match
            }
        }
        return nil
    }
}
