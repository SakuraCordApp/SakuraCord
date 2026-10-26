import CoreGraphics

nonisolated struct NativeTimelineReactionCountTransition {
    let from: Int
    let to: Int
    let progress: CGFloat
}

nonisolated enum NativeTimelineReactionCountBaseline {
    static func canAnimate(
        hasCapturedVisibleCounts: Bool,
        hasStoredSnapshot: Bool
    ) -> Bool {
        hasCapturedVisibleCounts || hasStoredSnapshot
    }

    static func previousCount(
        capturedCount: Int?,
        storedCountBeforeUpdate: Int?,
        messageExistedBeforeUpdate: Bool,
        messageWasPreviouslyVisible: Bool,
        currentCount: Int
    ) -> Int {
        if let capturedCount {
            return capturedCount
        }
        if let storedCountBeforeUpdate {
            return storedCountBeforeUpdate
        }
        if messageExistedBeforeUpdate {
            return 0
        }
        return messageWasPreviouslyVisible ? 0 : currentCount
    }
}

nonisolated enum NativeTimelineReactionAddControlGeometry {
    static func iconFrame(in frame: CGRect) -> CGRect {
        let size = InterfaceScale.metric(18)
        // Center the visible smile rather than the private symbol's font box.
        let opticalOffset = InterfaceScale.metric(1)
        return CGRect(
            x: frame.midX - size / 2,
            y: frame.midY - size / 2 - opticalOffset,
            width: size,
            height: size
        )
    }
}

nonisolated enum NativeTimelineSymbolGeometry {
    static func opticallyFitted(
        sourceSize: CGSize,
        alignmentRect: CGRect,
        in target: CGRect
    ) -> CGRect {
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              target.width > 0,
              target.height > 0
        else { return target }
        let scale = min(
            target.width / sourceSize.width,
            target.height / sourceSize.height
        )
        let size = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        let fitted = CGRect(
            x: target.midX - size.width / 2,
            y: target.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        guard alignmentRect.width > 0,
              alignmentRect.height > 0
        else { return fitted }
        // SF Symbols carry an alignment rect describing the center AppKit
        // uses when laying the symbol out beside native controls. NSImage's
        // low-level draw API ignores it, leaving several symbols visibly a
        // fraction of a point high or left. Apply that optical center here.
        return fitted.offsetBy(
            dx: (sourceSize.width / 2 - alignmentRect.midX) * scale,
            dy: (sourceSize.height / 2 - alignmentRect.midY) * scale
        )
    }
}
