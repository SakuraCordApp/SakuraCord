import AppKit
import SwiftUI

/// Only non-grid rows need measurement. Cache their exact SwiftUI fitting size
/// when catalog text or available width changes, never during scrolling.
@MainActor
final class NativePickerRowMeasurement {
    private var width: CGFloat = -1
    private var heights: [String: CGFloat] = [:]

    func height<Content: View>(key: String, width: CGFloat, @ViewBuilder content: () -> Content) -> CGFloat {
        if abs(self.width - width) > 0.5 {
            self.width = width
            heights.removeAll(keepingCapacity: true)
        }
        if let height = heights[key] { return height }
        let host = NSHostingView(rootView: content().frame(width: max(1, width)).fixedSize(horizontal: false, vertical: true))
        let height = host.fittingSize.height
        if heights.count >= 512 { heights.removeAll(keepingCapacity: true) }
        heights[key] = height
        return height
    }
}
