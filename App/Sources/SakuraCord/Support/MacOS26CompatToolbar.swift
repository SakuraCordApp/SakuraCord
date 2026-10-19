// Stand-in for the macOS 27 toolbar visibility priority API.
#if !compiler(>=6.4)
import SwiftUI

enum ToolbarVisibilityPriorityCompat {
    case low, automatic, high
}

extension ToolbarContent {
    // macOS 26 has no priority; the toolbar hides items in its default order.
    func visibilityPriority(_ priority: ToolbarVisibilityPriorityCompat) -> Self { self }
}
#endif
