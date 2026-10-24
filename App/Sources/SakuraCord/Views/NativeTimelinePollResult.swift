import AppKit
import SakuraCordModels

nonisolated extension NativeTimelineRowPainter {
    static func drawPollResult(_ input: NativeTimelineMessageDrawInput) {
        guard let result = input.row.message.pollResultSummary, let frame = input.layout.pollResultFrame else { return }
        pollSurface(in: frame, cornerRadius: NativeTimelinePollLayout.resultCornerRadius(in: frame))
        let label = result.winner ?? (result.totalVotes == 0 ? "There was no winner" : "The results were tied")
        text(label, in: CGRect(
            x: frame.minX + InterfaceScale.metric(17),
            y: frame.minY + InterfaceScale.metric(12),
            width: frame.width - InterfaceScale.metric(125),
            height: InterfaceScale.metric(22)
        ),
             font: .interfaceSystemFont(ofSize: 14, weight: .semibold), color: .labelColor)
        let percentage = result.totalVotes > 0 ? Int((Double(result.winnerVotes) / Double(result.totalVotes) * 100).rounded()) : 0
        let detail = result.winner != nil ? "Winning answer · \(percentage)%" : result.totalVotes > 0 ? "\(percentage)%" : ""
        text(detail, in: CGRect(
            x: frame.minX + InterfaceScale.metric(17),
            y: frame.minY + InterfaceScale.metric(36),
            width: frame.width - InterfaceScale.metric(125),
            height: InterfaceScale.metric(16)
        ),
             font: .interfaceSystemFont(ofSize: 12), color: .secondaryLabelColor)
        let button = NativeTimelinePollLayout.resultButtonFrame(in: frame)
        pollButton("View Poll", in: button, control: .original, state: input.pollPresentation)
    }
}
