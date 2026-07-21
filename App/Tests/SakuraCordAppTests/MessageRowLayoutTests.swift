import AppKit
@testable import SakuraCord
import SwiftUI
import Testing

@MainActor
@Test func `first message content placement stays fixed when highlight padding is restored`() {
    let geometry = MessageRowLayoutMetrics.geometry(contentHeight: 38, startsGroup: true)

    #expect(geometry.externalTopSeparation == 9)
    #expect(geometry.highlightTopInset == 3)
    #expect(geometry.highlightBottomInset == 3)
    #expect(geometry.contentHeight == 38)
    #expect(geometry.contentMinY == 12)
    #expect(geometry.rowHeight == 53)
    #expect(geometry.highlightMinY == geometry.externalTopSeparation)
    #expect(geometry.highlightMaxY == geometry.rowHeight)
}

@MainActor
@Test(arguments: RepresentativeMessageRow.allCases)
func `row variants have the same final visible highlight spacing`(_ row: RepresentativeMessageRow) {
    let geometry = MessageRowLayoutMetrics.geometry(
        contentHeight: row.contentHeight,
        startsGroup: row.startsGroup,
        hasReplyPreview: row.hasReplyPreview,
        isEditing: row.isEditing
    )

    #expect(geometry.contentHeight == row.contentHeight)
    #expect(geometry.visibleHighlightTopInset == 3)
    #expect(geometry.visibleHighlightBottomInset == 3)
    #expect(geometry.visibleHighlightTopInset == geometry.visibleHighlightBottomInset)
    #expect(geometry.contentMinY == (row.startsGroup ? 12 : geometry.highlightTopInset))
}

@MainActor
@Test func `grouped row adds balanced padding without external separation`() {
    let geometry = MessageRowLayoutMetrics.geometry(contentHeight: 18, startsGroup: false)

    #expect(
        MessageRowLayoutMetrics.separation(startsGroup: false, highlightTopInset: 3) == 0
    )
    #expect(geometry.highlightTopInset == 3)
    #expect(geometry.highlightBottomInset == 3)
    #expect(geometry.highlightTopInset == geometry.highlightBottomInset)
    #expect(geometry.highlightMinY == 0)
    #expect(geometry.rowHeight == geometry.contentHeight + 6)
}

@MainActor
@Test(arguments: CompensatedMessageRow.allCases)
func `intrinsic reply and edit padding is not doubled`(_ row: CompensatedMessageRow) {
    let insets = MessageRowLayoutMetrics.highlightInsets(
        hasReplyPreview: row.hasReplyPreview,
        isEditing: row.isEditing
    )
    let geometry = MessageRowLayoutMetrics.geometry(
        contentHeight: 120,
        startsGroup: true,
        hasReplyPreview: row.hasReplyPreview,
        isEditing: row.isEditing
    )

    #expect(insets.top + insets.intrinsicTop == 3)
    #expect(insets.bottom + insets.intrinsicBottom == 3)
    #expect(geometry.visibleHighlightTopInset == 3)
    #expect(geometry.visibleHighlightBottomInset == 3)
}

@MainActor
@Test func `grouped message chrome matches the one line message height`() {
    let textHeight = fittingHeight(
        CustomEmojiRichText(content: "A compact grouped message", emojiSize: 22),
        width: 420
    )

    #expect(textHeight == MessageRowLayoutMetrics.compactContentHeight)
    #expect(MessageRowLayoutMetrics.avatarColumnHeight(startsGroup: false) == textHeight)
    #expect(
        MessageRowLayoutMetrics.avatarColumnHeight(startsGroup: true)
            == MessageRowLayoutMetrics.avatarDiameter
    )
}

@MainActor
@Test func `multiline message height follows the proposed row width`() {
    let content = String(
        repeating: "Hover highlighting must follow every wrapped line of message content. ",
        count: 4
    )
    let narrowHeight = fittingHeight(
        CustomEmojiRichText(content: content, emojiSize: 22),
        width: 240
    )
    let wideHeight = fittingHeight(
        CustomEmojiRichText(content: content, emojiSize: 22),
        width: 640
    )

    #expect(narrowHeight > wideHeight)
    #expect(wideHeight > MessageRowLayoutMetrics.compactContentHeight)
}

@Test func `rich message text never forwards invalid AppKit widths`() {
    #expect(RichMessageTextMeasurement.constrainedWidth(nil) == nil)
    #expect(RichMessageTextMeasurement.constrainedWidth(.infinity) == nil)
    #expect(RichMessageTextMeasurement.constrainedWidth(.nan) == nil)
    #expect(RichMessageTextMeasurement.constrainedWidth(0) == 1)
    #expect(RichMessageTextMeasurement.constrainedWidth(420) == 420)
    #expect(
        RichMessageTextMeasurement.constrainedWidth(20_000)
            == RichMessageTextMeasurement.maximumWidth
    )
}

@MainActor
private func fittingHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
    let host = NSHostingView(rootView: view.frame(width: width, alignment: .leading))
    host.layoutSubtreeIfNeeded()
    return host.fittingSize.height
}

enum RepresentativeMessageRow: CaseIterable, Sendable {
    case ordinaryFirstMessage
    case groupedTextMessage
    case reply
    case largeAttachment
    case reactions
    case multilineNarrowMessage
    case editMode

    var startsGroup: Bool {
        self != .groupedTextMessage
    }

    var hasReplyPreview: Bool {
        self == .reply
    }

    var isEditing: Bool {
        self == .editMode
    }

    var contentHeight: CGFloat {
        switch self {
        case .ordinaryFirstMessage: 38
        case .groupedTextMessage: 18
        case .reply: 64
        case .largeAttachment: 560
        case .reactions: 76
        case .multilineNarrowMessage: 112
        case .editMode: 144
        }
    }
}

enum CompensatedMessageRow: CaseIterable, Sendable {
    case reply
    case edit
    case replyWhileEditing

    var hasReplyPreview: Bool {
        self == .reply || self == .replyWhileEditing
    }

    var isEditing: Bool {
        self == .edit || self == .replyWhileEditing
    }
}
