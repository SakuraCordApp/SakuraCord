import AppKit
import SwiftUI

/// A data-free representation of the complete chat chrome. The authenticated
/// workspace is not mounted until the live bootstrap has completed, so none of
/// these placeholders can expose stale account state from a previous process.
struct SakuraCordSessionLoadingView: View {
    let state: AppModel.SessionState
    let isOfflineTesting: Bool

    private let pulse = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        SkeletonShimmerTimeline {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                HStack(spacing: 0) {
                    serverRail
                    channelSidebar
                }
                .navigationSplitViewColumnWidth(
                    min: ChatChromeMetrics.serverRailWidth + 190,
                    ideal: ChatChromeMetrics.serverRailWidth + 230,
                    max: ChatChromeMetrics.serverRailWidth + 310
                )
            } detail: {
                workspace
                    .navigationTitle("")
                    .toolbar { detailToolbar }
            }
            .toolbar { conversationToolbar }
            .overlay(alignment: .topLeading) {
                SkeletonShape(cornerRadius: 4, pulse: pulse)
                    .frame(width: 132, height: 14)
                    .offset(
                        x: ChatChromeMetrics.sidebarTitleLeadingOffset,
                        y: ChatChromeMetrics.sidebarTitleTopOffset + 7
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Opening SakuraCord. \(detail)")
    }

    private var serverRail: some View {
        ScrollView {
            VStack(spacing: 10) {
                railItem(cornerRadius: 14, delay: 0)
                Divider().padding(.horizontal, 12)
                ForEach(0 ..< 7, id: \.self) { index in
                    railItem(
                        cornerRadius: index == 0 ? 14 : 22,
                        delay: Double(index + 1) * 0.06
                    )
                }
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .frame(width: ChatChromeMetrics.serverRailWidth)
    }

    private func railItem(cornerRadius: CGFloat, delay: Double) -> some View {
        HStack(spacing: 5) {
            Color.clear.frame(width: 7, height: 40)
            SkeletonShape(cornerRadius: cornerRadius, pulse: pulse, delay: delay)
                .frame(width: 44, height: 44)
        }
        .frame(width: ChatChromeMetrics.serverRailWidth, height: 46, alignment: .leading)
    }

    private var channelSidebar: some View {
        VStack(spacing: 0) {
            List {
                ForEach(0 ..< 3, id: \.self) { section in
                    Section {
                        ForEach(0 ..< (section == 1 ? 4 : 3), id: \.self) { row in
                            HStack(spacing: 8) {
                                SkeletonShape(
                                    cornerRadius: 4,
                                    pulse: pulse,
                                    delay: Double(row + section) * 0.05
                                )
                                .frame(width: 16, height: 16)
                                SkeletonShape(
                                    cornerRadius: 4,
                                    pulse: pulse,
                                    delay: Double(row + section) * 0.05
                                )
                                .frame(width: row.isMultiple(of: 2) ? 112 : 84, height: 12)
                            }
                            .frame(height: 24)
                        }
                    } header: {
                        SkeletonShape(cornerRadius: 3, pulse: pulse, delay: Double(section) * 0.08)
                            .frame(width: section == 1 ? 88 : 68, height: 9)
                            .padding(.top, section == 0 ? 0 : 8)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, ChatChromeMetrics.channelListTopPadding, for: .scrollContent)

            GlassEffectContainer(spacing: 0) {
                HStack(spacing: 9) {
                    SkeletonShape(cornerRadius: 17, pulse: pulse)
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        SkeletonShape(cornerRadius: 4, pulse: pulse)
                            .frame(width: 88, height: 11)
                        SkeletonShape(cornerRadius: 3, pulse: pulse, delay: 0.1)
                            .frame(width: 58, height: 8)
                    }
                    Spacer(minLength: 4)
                    SkeletonShape(cornerRadius: 7, pulse: pulse, delay: 0.15)
                        .frame(width: 22, height: 22)
                }
                .padding(.horizontal, 10)
                .frame(height: ChatChromeMetrics.controlHeight)
                .glassEffect(
                    .regular,
                    in: ConcentricRectangle(
                        corners: .concentric(
                            minimum: .fixed(ChatChromeMetrics.composerMinimumCornerRadius)
                        ),
                        isUniform: true
                    )
                )
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .overlay {
            SidebarChromeSeparator(
                cornerRadius: ChatChromeMetrics.sidebarContentCornerRadius,
                strokeInset: 0.5
            )
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            .allowsHitTesting(false)
        }
    }

    private var workspace: some View {
        HStack(spacing: 0) {
            messageTimeline
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            memberList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var messageTimeline: some View {
        MessageTimelineLoadingSkeleton(
            bottomContentInset: ChatDetailLayoutPolicy.defaultFloatingFooterHeight
        )
        .overlay(alignment: .bottom) {
            SkeletonShape(
                cornerRadius: ChatChromeMetrics.composerMinimumCornerRadius,
                pulse: pulse
            )
            .frame(height: ChatChromeMetrics.controlHeight)
            .padding(.horizontal, ChatChromeMetrics.composerWindowInset)
            .padding(.bottom, ChatChromeMetrics.composerWindowInset)
        }
    }

    private var memberList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(0 ..< 2, id: \.self) { section in
                    SkeletonShape(cornerRadius: 4, pulse: pulse, delay: Double(section) * 0.08)
                        .frame(width: section == 0 ? 92 : 70, height: 11)
                        .padding(.horizontal, 10)
                        .padding(.top, 12)
                        .padding(.bottom, 5)
                    ForEach(0 ..< (section == 0 ? 4 : 3), id: \.self) { index in
                        HStack(spacing: 10) {
                            SkeletonShape(cornerRadius: 17, pulse: pulse, delay: Double(index) * 0.05)
                                .frame(width: 34, height: 34)
                            VStack(alignment: .leading, spacing: 5) {
                                SkeletonShape(cornerRadius: 4, pulse: pulse, delay: Double(index) * 0.05)
                                    .frame(width: index.isMultiple(of: 3) ? 108 : 78, height: 11)
                                if index.isMultiple(of: 2) {
                                    SkeletonShape(cornerRadius: 3, pulse: pulse, delay: Double(index) * 0.05)
                                        .frame(width: 62, height: 8)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(height: 48)
                        .padding(.horizontal, 10)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .frame(width: ChatChromeMetrics.memberListWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    @ToolbarContentBuilder
    private var conversationToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 8) {
                SkeletonShape(cornerRadius: 4, pulse: pulse)
                    .frame(width: 16, height: 16)
                SkeletonShape(cornerRadius: 4, pulse: pulse, delay: 0.08)
                    .frame(width: 112, height: 13)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .visibilityPriority(.high)
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarSpacer(.flexible)
        ToolbarItemGroup {
            ForEach(0 ..< 3, id: \.self) { index in
                SkeletonShape(cornerRadius: 6, pulse: pulse, delay: Double(index) * 0.05)
                    .frame(width: 20, height: 20)
            }
        }
        .visibilityPriority(.high)
    }

    private var detail: String {
        if isOfflineTesting {
            return "Loading offline testing data…"
        }
        switch state {
        case .restoring: return "Checking your saved session…"
        case .connecting: return "Loading your chats…"
        case .signedOut, .workspace: return "Getting things ready…"
        }
    }
}

private struct SkeletonShape: View {
    let cornerRadius: CGFloat
    let pulse: Bool
    var delay = 0.0

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.white.opacity(0.09))
            .skeletonShimmer()
    }
}

// Shared by the signed-out login surface. The session-loading surface above
// intentionally uses only structural placeholders.
struct SakuraCordAuroraBackdrop: View {
    let elapsed: TimeInterval

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x0D0914), Color(hex: 0x1B1022), Color(hex: 0x0B0913)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            GeometryReader { geometry in
                Ellipse()
                    .fill(Color(hex: 0xFF4F96).opacity(0.2))
                    .frame(width: geometry.size.width * 0.72, height: geometry.size.height * 0.68)
                    .blur(radius: 110)
                    .offset(
                        x: -geometry.size.width * 0.2 + sin(elapsed * 0.16) * 34,
                        y: geometry.size.height * 0.48 + cos(elapsed * 0.13) * 28
                    )

                Ellipse()
                    .fill(Color(hex: 0x7A5CFF).opacity(0.13))
                    .frame(width: geometry.size.width * 0.64, height: geometry.size.height * 0.58)
                    .blur(radius: 120)
                    .offset(
                        x: geometry.size.width * 0.6 + cos(elapsed * 0.12) * 38,
                        y: -geometry.size.height * 0.18 + sin(elapsed * 0.15) * 24
                    )

                Ellipse()
                    .fill(Color(hex: 0x58C6D8).opacity(0.07))
                    .frame(width: geometry.size.width * 0.48, height: geometry.size.height * 0.48)
                    .blur(radius: 100)
                    .offset(
                        x: geometry.size.width * 0.52 + sin(elapsed * 0.1) * 30,
                        y: geometry.size.height * 0.58 + cos(elapsed * 0.11) * 24
                    )
            }

            RadialGradient(
                colors: [.clear, Color.black.opacity(0.36)],
                center: .center,
                startRadius: 180,
                endRadius: 800
            )
        }
    }
}

struct SakuraCordSakuraPetalField: View {
    let elapsed: TimeInterval
    let size: CGSize

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, _ in
            for index in 0 ..< 24 {
                let petal = SakuraPetal.motion(index: index, elapsed: elapsed, canvasSize: size)
                context.drawLayer { layer in
                    layer.translateBy(x: petal.position.x, y: petal.position.y)
                    layer.rotate(by: petal.rotation)
                    layer.scaleBy(x: petal.scale, y: petal.scale)
                    layer.opacity = petal.opacity
                    layer.fill(SakuraPetal.path, with: .color(petal.color))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private enum SakuraPetal {
    struct Motion {
        let position: CGPoint
        let rotation: Angle
        let scale: CGFloat
        let opacity: Double
        let color: Color
    }

    static let path: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -9))
        path.addCurve(
            to: CGPoint(x: 0, y: 10),
            control1: CGPoint(x: 8, y: -6),
            control2: CGPoint(x: 8, y: 5)
        )
        path.addCurve(
            to: CGPoint(x: 0, y: -9),
            control1: CGPoint(x: -8, y: 5),
            control2: CGPoint(x: -8, y: -6)
        )
        return path
    }()

    static func motion(index: Int, elapsed: TimeInterval, canvasSize: CGSize) -> Motion {
        let seed = fraction(sin(Double(index + 1) * 12.9898) * 43_758.5453)
        let secondarySeed = fraction(sin(Double(index + 7) * 78.233) * 19_341.274)
        let duration = 10 + seed * 9
        let progress = fraction(elapsed / duration + secondarySeed)
        let baseX = seed * max(canvasSize.width, 1)
        let sway = sin(elapsed * (0.45 + secondarySeed * 0.25) + seed * 12)
            * (22 + seed * 34)
        let width = max(canvasSize.width, 1)
        let horizontalPosition = wrapped(baseX + sway, limit: width)
        let verticalPosition = -30 + progress * (canvasSize.height + 60)
        let depth = 0.45 + secondarySeed * 0.75

        return Motion(
            position: CGPoint(x: horizontalPosition, y: verticalPosition),
            rotation: .radians(elapsed * (0.3 + seed * 0.75) + secondarySeed * .pi * 2),
            scale: depth,
            opacity: 0.18 + seed * 0.38,
            color: index.isMultiple(of: 4) ? Color(hex: 0xFFD1E1) : Color(hex: 0xFF8FBA)
        )
    }

    private static func fraction(_ value: Double) -> Double {
        value - floor(value)
    }

    private static func wrapped(_ value: Double, limit: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: limit)
        return remainder < 0 ? remainder + limit : remainder
    }
}
