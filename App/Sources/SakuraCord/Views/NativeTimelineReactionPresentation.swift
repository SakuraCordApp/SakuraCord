import CoreGraphics

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
