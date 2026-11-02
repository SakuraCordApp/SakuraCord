import AppKit
import SakuraCordModels
import SwiftUI

/// The one curve the composer grows and shrinks on when its chrome changes,
/// such as staging attachments or starting a reply. The timeline glides its
/// rows on the same curve, so the transcript stays attached to the
/// composer's top edge instead of jumping ahead of it.
enum ComposerResizeMotion {
    static let duration: TimeInterval = 0.4
    /// Long enough for the composer's new height to reach the timeline.
    static let signalLifetime: TimeInterval = 0.3

    static var animation: Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }

    static let glideCurve = NativeTimelineGlideCurve(
        x1: 0.22, y1: 1, x2: 0.36, y2: 1, duration: duration
    )

    /// Attachment tiles settle with a little life; they don't change the
    /// composer's height, so they need not share its curve.
    static var tile: Animation { .spring(duration: 0.42, bounce: 0.22) }
    static var hover: Animation { .snappy(duration: 0.2) }

    static var isReduced: Bool {
        !AppMotionPolicy.animatesUncategorized
    }
}

/// What determines the composer's height apart from the text being typed.
/// Changes to it animate; typing grows the field at once.
struct ComposerChromeKey: Equatable {
    var conversationID: ChannelID?
    var attachmentIDs: [UUID]
    var replyID: MessageID?
    var hasActiveCommand: Bool
    var hasTranslationHeader: Bool
}
