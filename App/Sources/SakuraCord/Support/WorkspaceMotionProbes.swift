import AppKit
import SwiftUI

/// Named geometry probes for the side chat motion benchmark. Probes are
/// installed only when the benchmark runs; otherwise the modifier returns its
/// content unchanged and the registry stays empty.
@MainActor
final class WorkspaceMotionProbes {
    static let shared = WorkspaceMotionProbes()

    /// Set once at launch, before any view is built, so a probe's presence
    /// never changes a view's structural identity.
    static var isEnabled = false

    struct TimelineSample: Encodable {
        let frame: [Double]
        let documentHeight: Double
        let offsetY: Double
        let distanceFromBottom: Double
        let rows: Int
        /// How many times the timeline has drawn so far.
        let draws: Int
        /// How long the timeline has spent drawing, and laying out rows, so far.
        let drawMS: Double
        let layoutMS: Double
        /// The width the frame's rows are laid out at.
        let contentWidth: Double
    }

    struct TimelineCounts {
        var rows: Int
        var draws: Int
        var drawSeconds: Double
        var layoutSeconds: Double
        var contentWidth: CGFloat = 0
    }

    private final class WeakView {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    private struct Timeline {
        weak var scrollView: NSScrollView?
        let counts: () -> TimelineCounts
    }

    private var probes: [String: [WeakView]] = [:]
    private var timelines: [Timeline] = []

    private init() {}

    func register(_ view: NSView, name: String) {
        probes[name, default: []].removeAll { $0.view == nil || $0.view === view }
        probes[name, default: []].append(WeakView(view))
    }

    func unregister(_ view: NSView, name: String) {
        probes[name]?.removeAll { $0.view == nil || $0.view === view }
    }

    func registerTimeline(_ scrollView: NSScrollView, counts: @escaping () -> TimelineCounts) {
        timelines.removeAll { $0.scrollView == nil || $0.scrollView === scrollView }
        timelines.append(Timeline(scrollView: scrollView, counts: counts))
    }

    /// Window-space rects of the newest on-screen probe for each name.
    func probeFrames(in window: NSWindow) -> [String: [Double]] {
        var frames: [String: [Double]] = [:]
        for (name, views) in probes {
            guard let view = views.last(where: {
                $0.view?.window === window && $0.view?.isHiddenOrHasHiddenAncestor == false
            })?.view else { continue }
            frames[name] = Self.rect(view.convert(view.bounds, to: nil))
        }
        return frames
    }

    func timelineSamples(in window: NSWindow) -> [TimelineSample] {
        timelines.compactMap { timeline in
            guard let scrollView = timeline.scrollView,
                  scrollView.window === window,
                  !scrollView.isHiddenOrHasHiddenAncestor,
                  let documentView = scrollView.documentView
            else { return nil }
            let clip = scrollView.contentView.bounds
            let documentHeight = documentView.frame.height
            let distanceFromBottom = documentView.isFlipped
                ? documentHeight - clip.maxY
                : clip.minY
            let counts = timeline.counts()
            return TimelineSample(
                frame: Self.rect(scrollView.convert(scrollView.bounds, to: nil)),
                documentHeight: documentHeight,
                offsetY: clip.minY,
                distanceFromBottom: distanceFromBottom,
                rows: counts.rows,
                draws: counts.draws,
                drawMS: (counts.drawSeconds * 100_000).rounded() / 100,
                layoutMS: (counts.layoutSeconds * 100_000).rounded() / 100,
                contentWidth: Double(counts.contentWidth)
            )
        }
    }

    private static func rect(_ rect: CGRect) -> [Double] {
        [rect.minX, rect.minY, rect.width, rect.height].map { (Double($0) * 100).rounded() / 100 }
    }
}

extension View {
    /// Reports this view's window frame to the motion benchmark under `name`.
    @ViewBuilder func workspaceMotionProbe(_ name: String) -> some View {
        if WorkspaceMotionProbes.isEnabled {
            background(WorkspaceMotionProbe(name: name))
        } else {
            self
        }
    }
}

private struct WorkspaceMotionProbe: NSViewRepresentable {
    let name: String

    func makeNSView(context _: Context) -> ProbeView {
        ProbeView(name: name)
    }

    func updateNSView(_ view: ProbeView, context _: Context) {
        view.name = name
    }

    final class ProbeView: NSView {
        var name: String {
            didSet {
                guard oldValue != name, window != nil else { return }
                WorkspaceMotionProbes.shared.unregister(self, name: oldValue)
                WorkspaceMotionProbes.shared.register(self, name: name)
            }
        }

        init(name: String) {
            self.name = name
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { nil }

        override func hitTest(_: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                WorkspaceMotionProbes.shared.unregister(self, name: name)
            } else {
                WorkspaceMotionProbes.shared.register(self, name: name)
            }
        }
    }
}
