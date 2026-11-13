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

extension NativeTimelineRowPainter {
    static func pollSurface(in frame: CGRect, cornerRadius radius: CGFloat) {
        NativeTimelineSemanticColor.opacity(.controlBackgroundColor, 0.45).setFill()
        NSBezierPath(concentricRoundedRect: frame, cornerRadius: radius).fill()
        NativeTimelineSemanticColor.opacity(.labelColor, 0.10).setStroke()
        let border = NSBezierPath(concentricRoundedRect: frame.insetBy(dx: 0.5, dy: 0.5), cornerRadius: radius - 0.5)
        border.lineWidth = 1
        border.stroke()
    }

    static func pollButton(_ title: String, in frame: CGRect, control: NativeTimelinePollTarget.Control,
                           state: NativeTimelinePollPresentation, isEnabled: Bool = true, isProminent: Bool = false,
                           bubbleRegion: NativeTimelineBubbleRegion? = nil) {
        let outgoing = bubbleRegion?.isOutgoing == true
        sakuraCordButton(title: title, frame: frame, isHovered: isEnabled && state.hoveredControl == control,
                        pressProgress: state.pressedControl == control ? 1 : 0,
                        colors: [outgoing ? .white.withAlphaComponent(isProminent ? 1 : 0.16) : isProminent ? .sakuraCordAccentColor : .controlColor],
                        foreground: outgoing ? (isProminent ? .sakuraCordAccentColor : .white) : isProminent ? .white : .labelColor, isEnabled: isEnabled)
    }

    static func drawPoll(_ input: NativeTimelineMessageDrawInput) {
        guard let poll = input.row.message.poll, let layout = input.layout.pollLayout else { return }
        let state = input.pollPresentation
        let bubble = input.layout.bubbleRegion
        if let bubble {
            bubbleIntegratedSection(layout.frame, bubbleRegion: bubble, accentColor: nil,
                drawsTopSeparator: layout.frame.minY - bubble.frame.minY > 8.5, drawsNeutralRail: false)
        } else {
            pollSurface(in: layout.frame, cornerRadius: NativeTimelinePollLayout.cornerRadius)
        }
        text(poll.question, in: layout.questionFrame, font: .interfaceSystemFont(ofSize: 15, weight: .semibold),
             color: NativeTimelineBubbleDrawing.foregroundColor(for: bubble), lineBreakMode: .byWordWrapping)
        text(poll.isClosed() ? "" : poll.allowsMultipleAnswers ? "Select one or more answers" : "Select one answer",
             in: layout.instructionFrame, font: .interfaceSystemFont(ofSize: 12), color: NativeTimelineBubbleDrawing.secondaryForegroundColor(for: bubble))
        for region in layout.answers {
            guard let answer = poll.answers.first(where: { $0.id == region.id }) else { continue }
            drawPollAnswer(answer, region: region, poll: poll, state: state, bubbleRegion: bubble)
        }
        drawPollFooter(poll, layout: layout, state: state,
                       isConfirmed: input.row.message.outboxState == .confirmed,
                       canVote: input.model?.canUpdatePollVote(on: input.row.message, removing: !poll.selectedAnswerIDs.isEmpty) != false, bubbleRegion: bubble)
    }

    private static func drawPollAnswer(_ answer: PollAnswer, region: NativeTimelinePollLayout.Answer,
                                       poll: MessagePoll, state: NativeTimelinePollPresentation, bubbleRegion: NativeTimelineBubbleRegion?) {
        let results = state.showsResults(for: poll)
        let selected = results ? poll.selectedAnswerIDs.contains(answer.id) : state.selected.contains(answer.id)
        let highestCount = poll.results?.answerCounts.map(\.count).max() ?? 0
        let winner = poll.isClosed() && highestCount > 0 && poll.count(for: answer.id) == highestCount
        let hovered = state.hoveredControl == .answer(answer.id)
        let outgoing = bubbleRegion?.isOutgoing == true
        let foreground = NativeTimelineBubbleDrawing.foregroundColor(for: bubbleRegion)
        let accent = outgoing ? NSColor.white : .sakuraCordAccentColor
        let path = NSBezierPath(concentricRoundedRect: region.frame, cornerRadius: NativeTimelinePollLayout.answerCornerRadius)
        foreground.withAlphaComponent(outgoing ? (hovered ? 0.18 : 0.10) : (hovered ? 0.08 : 0.045)).setFill()
        path.fill()
        if results {
            let fraction = state.fractions[answer.id] ?? (poll.totalVotes > 0 ? CGFloat(poll.count(for: answer.id)) / CGFloat(poll.totalVotes) : 0)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            ((selected || winner) ? accent.withAlphaComponent(0.25) : foreground.withAlphaComponent(0.12)).setFill()
            CGRect(x: region.frame.minX, y: region.frame.minY, width: region.frame.width * min(1, max(0, fraction)), height: region.frame.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        if selected || winner || (!results && hovered) {
            ((selected || winner) ? accent : foreground.withAlphaComponent(0.24)).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        drawPollEmoji(answer.emoji, frame: region.emojiFrame)
        text(answer.text, in: region.textFrame, font: .interfaceSystemFont(ofSize: 13, weight: .medium),
             color: foreground, lineBreakMode: .byWordWrapping)
        if results {
            drawPollAnswerResult(answer, region: region, poll: poll, selected: selected, bubbleRegion: bubbleRegion)
        } else {
            let box = CGRect(x: region.frame.maxX - InterfaceScale.metric(32), y: region.frame.midY - InterfaceScale.metric(10), width: InterfaceScale.metric(20), height: InterfaceScale.metric(20))
            let radius = InterfaceScale.metric(poll.allowsMultipleAnswers ? 5 : 10)
            let indicator = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
            (selected ? accent : NativeTimelineBubbleDrawing.secondaryForegroundColor(for: bubbleRegion)).setStroke()
            indicator.lineWidth = 1.5
            indicator.stroke()
            if selected {
                accent.setFill()
                if poll.allowsMultipleAnswers {
                    indicator.fill()
                    text("✓", in: box, font: .interfaceSystemFont(ofSize: 14, weight: .semibold), color: outgoing ? .sakuraCordAccentColor : .white, alignment: .center)
                } else {
                    NSBezierPath(ovalIn: box.insetBy(dx: InterfaceScale.metric(4), dy: InterfaceScale.metric(4))).fill()
                }
            }
        }
    }

    private static func drawPollEmoji(_ emoji: EmojiReference?, frame: CGRect?) {
        guard let emoji, let frame else { return }
        if let url = emoji.imageURL(size: 64), let image = mediaImage(for: .media(url, maximumPixelDimension: 64)) {
            image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else if emoji.id == nil {
            text(emoji.name, in: frame, font: .interfaceSystemFont(ofSize: 20), color: .labelColor, lineBreakMode: .byClipping)
        }
    }

    private static func drawPollAnswerResult(_ answer: PollAnswer, region: NativeTimelinePollLayout.Answer,
                                             poll: MessagePoll, selected: Bool, bubbleRegion: NativeTimelineBubbleRegion?) {
        let trailing = InterfaceScale.metric(selected ? 40 : 12)
        let percentageFrame = CGRect(
            x: region.frame.maxX - trailing - InterfaceScale.metric(40),
            y: region.frame.midY - InterfaceScale.metric(10),
            width: InterfaceScale.metric(40),
            height: InterfaceScale.metric(20)
        )
        let count = poll.count(for: answer.id)
        let percentage = poll.totalVotes > 0 ? Int((Double(count) / Double(poll.totalVotes) * 100).rounded()) : 0
        text(poll.results == nil ? "—" : "\(percentage)%", in: percentageFrame,
             font: .interfaceSystemFont(ofSize: 14, weight: .semibold), color: NativeTimelineBubbleDrawing.foregroundColor(for: bubbleRegion), alignment: .right)
        let countFrame = CGRect(
            x: percentageFrame.minX - InterfaceScale.metric(68),
            y: region.frame.midY - InterfaceScale.metric(10),
            width: InterfaceScale.metric(64),
            height: InterfaceScale.metric(20)
        )
        text(poll.results == nil ? "—" : "\(count) \(count == 1 ? "vote" : "votes")", in: countFrame,
             font: .interfaceSystemFont(ofSize: 11, weight: .medium), color: NativeTimelineBubbleDrawing.secondaryForegroundColor(for: bubbleRegion), alignment: .right)
        if selected {
            let box = CGRect(x: region.frame.maxX - InterfaceScale.metric(32), y: region.frame.midY - InterfaceScale.metric(10), width: InterfaceScale.metric(20), height: InterfaceScale.metric(20))
            (bubbleRegion?.isOutgoing == true ? NSColor.white : .sakuraCordAccentColor).setFill()
            NSBezierPath(ovalIn: box).fill()
            text("✓", in: box, font: .interfaceSystemFont(ofSize: 14, weight: .semibold),
                 color: bubbleRegion?.isOutgoing == true ? .sakuraCordAccentColor : .white, alignment: .center)
        }
    }

    private static func drawPollFooter(_ poll: MessagePoll, layout: NativeTimelinePollLayout,
                                       state: NativeTimelinePollPresentation, isConfirmed: Bool, canVote: Bool,
                                       bubbleRegion: NativeTimelineBubbleRegion?) {
        let results = state.showsResults(for: poll)
        pollButton(poll.results == nil ? "— votes" : "\(poll.totalVotes) \(poll.totalVotes == 1 ? "vote" : "votes")",
                   in: layout.votesFrame, control: .votes, state: state, bubbleRegion: bubbleRegion)
        let remaining = max(0, Int((poll.expiry?.timeIntervalSinceNow ?? 0) / 60))
        let time = poll.isClosed() ? "Final results" : remaining >= 1440 ? "\(remaining / 1440)d left" : remaining >= 60 ? "\(remaining / 60)h left" : "\(max(1, remaining))m left"
        text(time, in: layout.expiryFrame, font: .interfaceSystemFont(ofSize: 11),
             color: bubbleRegion?.isOutgoing == true ? NativeTimelineBubbleDrawing.secondaryForegroundColor(for: bubbleRegion) : .tertiaryLabelColor)
        guard !poll.isClosed(), isConfirmed else { return }
        if poll.selectedAnswerIDs.isEmpty {
            pollButton(results ? "Back to vote" : "Show results", in: layout.revealFrame, control: .reveal, state: state, bubbleRegion: bubbleRegion)
        }
        if !results || !poll.selectedAnswerIDs.isEmpty {
            let removing = !poll.selectedAnswerIDs.isEmpty
            let enabled = canVote && (removing || !state.selected.isEmpty)
            pollButton(removing ? "Remove Vote" : "Vote",
                       in: layout.submitFrame, control: .submit, state: state, isEnabled: enabled, isProminent: !removing, bubbleRegion: bubbleRegion)
        }
    }
}
