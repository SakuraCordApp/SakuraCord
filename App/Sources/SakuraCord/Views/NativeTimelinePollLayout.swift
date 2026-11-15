import AppKit
import CoreText
import SakuraCordModels

struct NativeTimelinePollLayout {
    struct Answer {
        let id: Int
        let frame: CGRect
        let textFrame: CGRect
        let emojiFrame: CGRect?
    }
    let frame: CGRect
    let questionFrame: CGRect
    let instructionFrame: CGRect
    let answers: [Answer]
    let votesFrame: CGRect
    let expiryFrame: CGRect
    let revealFrame: CGRect
    let submitFrame: CGRect
    var drawsTopSeparator = false

    /// Footer buttons sit 16 points from the card edges, and answers 16 points
    /// inside it, so both radii stay concentric with the 32-point capsules.
    static var inset: CGFloat { InterfaceScale.metric(16) }
    static var cornerRadius: CGFloat { inset + NativeTimelineComponentButtonMetrics.height / 2 }
    static var answerCornerRadius: CGFloat { cornerRadius - inset }

    init(poll: MessagePoll, x originX: CGFloat, y originY: CGFloat, width availableWidth: CGFloat, integratesWithBubble: Bool = false) {
        let width = integratesWithBubble ? availableWidth : min(InterfaceScale.metric(456), availableWidth)
        let inset = integratesWithBubble ? 0 : Self.inset
        let inner = max(1, width - inset * 2)
        var cursor = originY + inset
        let questionHeight = Self.height(poll.question, width: inner, font: .interfaceSystemFont(ofSize: 15, weight: .semibold))
        questionFrame = CGRect(x: originX + inset, y: cursor, width: inner, height: questionHeight)
        cursor += questionHeight + InterfaceScale.metric(5)
        instructionFrame = CGRect(x: originX + inset, y: cursor, width: inner, height: poll.isClosed() ? 0 : InterfaceScale.metric(17))
        cursor += InterfaceScale.metric(poll.isClosed() ? 7 : 29)
        answers = poll.answers.map { answer in
            let emojiWidth: CGFloat = answer.emoji == nil ? 0 : InterfaceScale.metric(30)
            let reserved = InterfaceScale.metric(poll.selectedAnswerIDs.contains(answer.id) ? 156 : 128)
            let textWidth = max(1, inner - reserved - emojiWidth)
            let height = max(
                InterfaceScale.metric(50),
                Self.height(answer.text, width: textWidth, font: .interfaceSystemFont(ofSize: 13))
                    + InterfaceScale.metric(24)
            )
            let rect = CGRect(x: originX + inset, y: cursor, width: inner, height: height)
            defer { cursor += height + InterfaceScale.metric(8) }
            return Answer(id: answer.id, frame: rect,
                          textFrame: CGRect(
                              x: rect.minX + InterfaceScale.metric(12) + emojiWidth,
                              y: rect.minY + InterfaceScale.metric(12),
                              width: textWidth,
                              height: height - InterfaceScale.metric(24)
                          ),
                          emojiFrame: answer.emoji == nil ? nil : CGRect(
                              x: rect.minX + InterfaceScale.metric(12),
                              y: rect.midY - InterfaceScale.metric(11),
                              width: InterfaceScale.metric(22),
                              height: InterfaceScale.metric(22)
                          ))
        }
        cursor += InterfaceScale.metric(4)
        let stacksFooter = inner < InterfaceScale.metric(384) && !poll.isClosed()
        votesFrame = CGRect(x: originX + inset, y: cursor, width: min(InterfaceScale.metric(80), inner), height: NativeTimelineComponentButtonMetrics.height)
        expiryFrame = CGRect(x: originX + inset + InterfaceScale.metric(88), y: cursor,
                             width: max(0, inner - (stacksFooter || poll.isClosed() ? InterfaceScale.metric(88) : InterfaceScale.metric(294))), height: NativeTimelineComponentButtonMetrics.height)
        if stacksFooter { cursor += InterfaceScale.metric(38) }
        let submitWidth = min(InterfaceScale.metric(94), inner * 0.45)
        submitFrame = CGRect(x: originX + width - inset - submitWidth, y: cursor, width: submitWidth, height: NativeTimelineComponentButtonMetrics.height)
        let revealWidth = min(InterfaceScale.metric(120), max(0, inner - submitWidth - InterfaceScale.metric(6)))
        revealFrame = CGRect(x: submitFrame.minX - InterfaceScale.metric(6) - revealWidth, y: cursor, width: revealWidth, height: NativeTimelineComponentButtonMetrics.height)
        frame = CGRect(x: originX, y: originY, width: width,
                       height: cursor + NativeTimelineComponentButtonMetrics.height + inset - originY)
    }

    static func resultButtonFrame(in frame: CGRect) -> CGRect {
        let height = NativeTimelineComponentButtonMetrics.height
        return CGRect(x: frame.maxX - resultInset(in: frame) - InterfaceScale.metric(86), y: frame.midY - height / 2, width: InterfaceScale.metric(86), height: height)
    }

    /// The result card's radius keeps its vertically centered button concentric.
    static func resultCornerRadius(in frame: CGRect) -> CGFloat {
        resultInset(in: frame) + NativeTimelineComponentButtonMetrics.height / 2
    }

    private static func resultInset(in frame: CGRect) -> CGFloat {
        max(0, (frame.height - NativeTimelineComponentButtonMetrics.height) / 2)
    }

    private static func height(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
        let value = NSAttributedString(string: text, attributes: [.font: font])
        let setter = CTFramesetterCreateWithAttributedString(value)
        return ceil(CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil,
                     CGSize(width: width, height: .greatestFiniteMagnitude), nil).height)
    }
}

struct NativeTimelinePollPresentation {
    static let voteAnimationDuration: TimeInterval = 0.48
    var selected: Set<Int> = []
    var revealsResults = false
    var hoveredControl: NativeTimelinePollTarget.Control?
    var pressedControl: NativeTimelinePollTarget.Control?
    var fractions: [Int: CGFloat] = [:]

    func showsResults(for poll: MessagePoll) -> Bool {
        revealsResults || poll.isClosed() || !poll.selectedAnswerIDs.isEmpty
    }
}

struct NativeTimelinePollTarget: Equatable {
    enum Control: Equatable { case answer(Int), votes, reveal, submit, original }
    let messageID: MessageID
    let control: Control
}
