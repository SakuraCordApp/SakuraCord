import CoreGraphics

/// `size` scaled to fit inside `frame`, or to fill it, centred on it.
nonisolated func aspectRect(for size: CGSize, in frame: CGRect, fillsFrame: Bool) -> CGRect {
    let scale = fillsFrame
        ? max(frame.width / size.width, frame.height / size.height)
        : min(frame.width / size.width, frame.height / size.height)
    return CGRect(
        x: frame.midX - size.width * scale / 2,
        y: frame.midY - size.height * scale / 2,
        width: size.width * scale,
        height: size.height * scale
    )
}
