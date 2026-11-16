import SakuraCordModels
import SwiftUI

struct MessageTimelineScrollRequest: Equatable {
    enum Target: Equatable {
        case top
        case bottom
        case message(MessageID, anchor: UnitPoint)
        /// A reading position: the message at the top of the viewport and
        /// its offset from the viewport's top edge.
        case readingPosition(MessageID, offsetFromViewportTop: CGFloat)
    }

    let id = UUID()
    let target: Target
    /// Glides to a loaded target instead of cutting to it.
    var isAnimated = false
}

nonisolated enum TimelineHistoryDirection: CaseIterable, Sendable {
    case earlier
    case later
}
