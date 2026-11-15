import AppKit
import SakuraCordModels

extension NativeTimelineRowPainter {
    static func pollSurface(in frame: CGRect, cornerRadius radius: CGFloat) {
        NativeTimelineSemanticColor.opacity(.controlBackgroundColor, 0.45).setFill()
        NSBezierPath(concentricRoundedRect: frame, cornerRadius: radius).fill()
        NativeTimelineSemanticColor.opacity(.labelColor, 0.10).setStroke()
        NSBezierPath.strokeHairline(frame, cornerRadius: radius)
    }

    static func pollButton(_ title: String, in frame: CGRect, control: NativeTimelinePollTarget.Control,
                           state: NativeTimelinePollPresentation, isEnabled: Bool = true, isProminent: Bool = false,
                           bubbleRegion: NativeTimelineBubbleRegion? = nil) {
        let outgoing = bubbleRegion?.isOutgoing == true
        gradientButton(title: title, frame: frame, isHovered: isEnabled && state.hoveredControl == control,
                        pressProgress: state.pressedControl == control ? 1 : 0,
                        colors: [outgoing ? .sakuraCordLabelOnAccentColor.withAlphaComponent(isProminent ? 1 : 0.16) : isProminent ? .sakuraCordAccentColor : .controlColor],
                        foreground: outgoing ? (isProminent ? .sakuraCordAccentColor : .sakuraCordLabelOnAccentColor) : isProminent ? .sakuraCordLabelOnAccentColor : .labelColor, isEnabled: isEnabled)
    }

    static func drawPoll(_ input: NativeTimelineMessageDrawInput) {
        guard let poll = input.row.message.poll, let layout = input.layout.pollLayout else { return }
        let state = input.pollPresentation
        let bubble = input.layout.bubbleRegion
        if let bubble {
            bubbleIntegratedSection(layout.frame, bubbleRegion: bubble, accentColor: nil,
                drawsTopSeparator: layout.drawsTopSeparator)
        } else {
            pollSurface(in: layout.frame, cornerRadius: NativeTimelinePollLayout.cornerRadius)
        }
        text(poll.question, in: layout.questionFrame, font: .interfaceSystemFont(ofSize: 15, weight: .semibold),
             color: NativeTimelineBubbleDrawing.foregroundColor(for: bubble), lineBreakMode: .byWordWrapping)
        text(poll.isClosed() ? "" : poll.allowsMultipleAnswers ? "Select one or more answers" : "Select one answer",
             in: layout.instructionFrame, font: .interfaceSystemFont(ofSize: 12), color: NativeTimelineBubbleDrawing.secondaryForegroundColor(for: bubble))
        for region in layout.answers {
            guard let answer = poll.answers.first(where: { $0.id == region.id }) else { continue }
            drawPollAnswer(answer, region: region, poll: poll, state: state, bubbleRegion: bubble,
                           hasAnimatedEmojiOverlay: input.animatedOverlayRoles.contains(.pollAnswer(answer.id)))
        }
        drawPollFooter(poll, layout: layout, state: state,
                       isConfirmed: input.row.message.outboxState == .confirmed,
                       canVote: input.model?.canUpdatePollVote(on: input.row.message, removing: !poll.selectedAnswerIDs.isEmpty) != false, bubbleRegion: bubble)
    }

    private static func drawPollAnswer(_ answer: PollAnswer, region: NativeTimelinePollLayout.Answer,
                                       poll: MessagePoll, state: NativeTimelinePollPresentation, bubbleRegion: NativeTimelineBubbleRegion?,
                                       hasAnimatedEmojiOverlay: Bool) {
        let results = state.showsResults(for: poll)
        let selected = results ? poll.selectedAnswerIDs.contains(answer.id) : state.selected.contains(answer.id)
        let highestCount = poll.results?.answerCounts.map(\.count).max() ?? 0
        let winner = poll.isClosed() && highestCount > 0 && poll.count(for: answer.id) == highestCount
        let hovered = state.hoveredControl == .answer(answer.id)
        let outgoing = bubbleRegion?.isOutgoing == true
        let foreground = NativeTimelineBubbleDrawing.foregroundColor(for: bubbleRegion)
        let accent = outgoing ? NSColor.sakuraCordLabelOnAccentColor : .sakuraCordAccentColor
        let path = NSBezierPath(concentricRoundedRect: region.frame, cornerRadius: NativeTimelinePollLayout.answerCornerRadius)
        foreground.withAlphaComponent(outgoing ? (hovered ? 0.18 : 0.10) : (hovered ? 0.08 : 0.045)).setFill()
        path.fill()
        if results {
            let fraction = state.fractions[answer.id] ?? CGFloat(poll.fraction(for: answer.id))
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
        if !hasAnimatedEmojiOverlay { drawPollEmoji(answer.emoji, frame: region.emojiFrame) }
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
                    text("✓", in: box, font: .interfaceSystemFont(ofSize: 14, weight: .semibold), color: outgoing ? .sakuraCordAccentColor : .sakuraCordLabelOnAccentColor, alignment: .center)
                } else {
                    NSBezierPath(ovalIn: box.insetBy(dx: InterfaceScale.metric(4), dy: InterfaceScale.metric(4))).fill()
                }
            }
        }
    }

    private static func drawPollEmoji(_ emoji: EmojiReference?, frame: CGRect?) {
        guard let emoji, let frame else { return }
        if let key = MediaImageKey.emoji(emoji), let image = MediaImageStore.shared.stillImage(for: key) {
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
        let percentage = Int((poll.fraction(for: answer.id) * 100).rounded())
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
            (bubbleRegion?.isOutgoing == true ? NSColor.sakuraCordLabelOnAccentColor : .sakuraCordAccentColor).setFill()
            NSBezierPath(ovalIn: box).fill()
            text("✓", in: box, font: .interfaceSystemFont(ofSize: 14, weight: .semibold),
                 color: bubbleRegion?.isOutgoing == true ? .sakuraCordAccentColor : .sakuraCordLabelOnAccentColor, alignment: .center)
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
