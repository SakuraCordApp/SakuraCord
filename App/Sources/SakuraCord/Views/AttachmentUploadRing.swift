import AppKit
import SwiftUI

/// The ring a file shows while it uploads, from its composer tile, through
/// its flight into the timeline, to its place in the sent message.
nonisolated enum AttachmentUploadRing {
    static var diameter: CGFloat { InterfaceScale.metric(28) }
    static var lineWidth: CGFloat { InterfaceScale.metric(2.5) }
    static let trackOpacity = 0.3
    /// How much an uploading image or tile darkens under its ring.
    static let dimOpacity = 0.3
    /// A sliver stays visible at the start, so the ring reads as progress.
    static func visibleFraction(_ fraction: Double) -> Double {
        min(max(fraction, 0.02), 1)
    }
}

struct AttachmentUploadRingView: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(AttachmentUploadRing.trackOpacity), lineWidth: AttachmentUploadRing.lineWidth)
            Circle()
                .trim(from: 0, to: AttachmentUploadRing.visibleFraction(fraction))
                .stroke(.white, style: StrokeStyle(lineWidth: AttachmentUploadRing.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: fraction)
        }
        .frame(width: AttachmentUploadRing.diameter, height: AttachmentUploadRing.diameter)
    }
}

/// The same ring for layers that fly or sit over the timeline, so a byte
/// update moves only its stroke.
nonisolated final class AttachmentUploadRingLayer: CALayer {
    private let track = CAShapeLayer()
    private let progress = CAShapeLayer()

    var fraction: Double = 0 {
        didSet {
            guard fraction != oldValue else { return }
            progress.strokeEnd = AttachmentUploadRing.visibleFraction(fraction)
        }
    }

    var color: CGColor = .white {
        didSet { applyColor() }
    }

    override init() {
        super.init()
        let diameter = AttachmentUploadRing.diameter
        bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        for layer in [track, progress] {
            layer.fillColor = nil
            layer.lineWidth = AttachmentUploadRing.lineWidth
            layer.lineCap = .round
            addSublayer(layer)
        }
        progress.strokeEnd = AttachmentUploadRing.visibleFraction(0)
        applyColor()
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        // Starts at the top and runs clockwise in this unflipped layer.
        let path = CGMutablePath()
        path.addArc(
            center: CGPoint(x: bounds.midX, y: bounds.midY), radius: bounds.width / 2 - AttachmentUploadRing.lineWidth / 2,
            startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [track, progress] {
            layer.frame = bounds
            layer.path = path
        }
        CATransaction.commit()
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func applyColor() {
        track.strokeColor = color.copy(alpha: AttachmentUploadRing.trackOpacity)
        progress.strokeColor = color
    }
}
