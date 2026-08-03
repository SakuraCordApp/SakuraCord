import SwiftUI

nonisolated enum SkeletonShimmerStyle {
    static let duration = 1.4
    static let minimumFrameInterval = 1.0 / 30.0
    static let bandWidthFraction = 0.72
    static let startingOffsetFraction = -0.68
    static let travelFraction = 1.58

    static func phase(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: duration) / duration
    }
}

private extension EnvironmentValues {
    @Entry var skeletonShimmerPhase: Double?
}

struct SkeletonShimmerTimeline<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: SkeletonShimmerStyle.minimumFrameInterval,
                paused: reduceMotion
            )
        ) { timeline in
            content.environment(
                \.skeletonShimmerPhase,
                reduceMotion ? nil : SkeletonShimmerStyle.phase(at: timeline.date)
            )
        }
    }
}

private struct SkeletonShimmerModifier: ViewModifier {
    @Environment(\.skeletonShimmerPhase) private var phase

    func body(content: Content) -> some View {
        content.overlay {
            if let phase {
                GeometryReader { proxy in
                    let width = max(proxy.size.width, 1)
                    LinearGradient(
                        colors: [
                            .clear,
                            Color.primary.opacity(0.18),
                            Color.primary.opacity(0.92),
                            Color.primary.opacity(0.18),
                            .clear,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(
                        width: width
                            * SkeletonShimmerStyle.bandWidthFraction
                    )
                    .offset(
                        x: width
                            * (
                                SkeletonShimmerStyle.startingOffsetFraction
                                    + SkeletonShimmerStyle.travelFraction
                                    * phase
                            )
                    )
                }
                .mask(content)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    func skeletonShimmer() -> some View {
        modifier(SkeletonShimmerModifier())
    }
}
