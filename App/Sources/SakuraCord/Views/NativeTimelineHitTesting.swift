import CoreGraphics

nonisolated enum NativeTimelineHoverHitTesting {
    static let coreTextOpticalOffset: CGFloat = 1

    static func pointerFrame(
        for highlightFrame: CGRect?
    ) -> CGRect? {
        highlightFrame?.offsetBy(
            dx: 0,
            dy: coreTextOpticalOffset
        )
    }

    static func contains(
        _ point: CGPoint,
        in highlightFrame: CGRect?
    ) -> Bool {
        pointerFrame(for: highlightFrame)?.contains(point) == true
    }

    static func contains(
        _ point: CGPoint,
        rowOrigin: CGFloat,
        highlightFrame: CGRect?
    ) -> Bool {
        contains(
            CGPoint(x: point.x, y: point.y - rowOrigin),
            in: highlightFrame
        )
    }
}

nonisolated enum NativeTimelineReactionClickHitTesting {
    enum Target: Equatable, Sendable {
        case reaction(index: Int)
        case add
    }

    static func target(
        at point: CGPoint,
        reactionFrames: [CGRect],
        addReactionFrame: CGRect?
    ) -> Target? {
        if let index = reactionFrames.firstIndex(where: {
            $0.contains(point)
        }) {
            return .reaction(index: index)
        }
        if addReactionFrame?.contains(point) == true {
            return .add
        }
        return nil
    }
}
