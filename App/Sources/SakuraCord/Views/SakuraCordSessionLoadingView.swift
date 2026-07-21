import AppKit
import SwiftUI

struct SakuraCordSessionLoadingView: View {
    let state: AppModel.SessionState
    let isOfflineTesting: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var animationStart = Date()

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
                let elapsed = reduceMotion ? 0 : timeline.date.timeIntervalSince(animationStart)

                ZStack {
                    SakuraCordAuroraBackdrop(elapsed: elapsed)
                    SakuraCordSakuraPetalField(elapsed: elapsed, size: geometry.size)
                        .accessibilityHidden(true)

                    loadingHero(elapsed: elapsed)
                        .padding(48)
                        .scaleEffect(appeared ? 1 : 0.94)
                        .opacity(appeared ? 1 : 0)

                    windowDragRegion
                }
            }
        }
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onAppear {
            animationStart = Date()
            guard !reduceMotion else {
                appeared = true
                return
            }
            withAnimation(.spring(duration: 0.9, bounce: 0.22)) {
                appeared = true
            }
        }
    }

    private func loadingHero(elapsed: TimeInterval) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 112, height: 112)
                    .offset(y: reduceMotion ? 0 : sin(elapsed * 1.25) * 3)
                    .shadow(color: Color.black.opacity(0.36), radius: 28, y: 15)
                    .accessibilityHidden(true)
            }
            .padding(.bottom, 20)

            Text("Opening SakuraCord")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .tracking(-0.5)
                .foregroundStyle(.white)

            HStack(spacing: 11) {
                LoadingPulse(elapsed: elapsed, reduceMotion: reduceMotion)
                Text(detail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(.top, 13)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Opening SakuraCord. \(detail)")
    }

    private var windowDragRegion: some View {
        VStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .frame(height: 52)
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
            Spacer(minLength: 0)
        }
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

private struct LoadingPulse: View {
    let elapsed: TimeInterval
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0 ..< 3, id: \.self) { index in
                let phase = reduceMotion ? Double(index) * 0.5 : elapsed * 3.2 - Double(index) * 0.7
                let amount = (sin(phase) + 1) / 2
                Circle()
                    .fill(Color(hex: 0xFF86B5))
                    .frame(width: 5, height: 5)
                    .scaleEffect(0.78 + amount * 0.32)
                    .opacity(0.38 + amount * 0.62)
            }
        }
        .accessibilityHidden(true)
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
        let sway = sin(elapsed * (0.45 + secondarySeed * 0.25) + seed * 12) * (22 + seed * 34)
        let width = max(canvasSize.width, 1)
        let x = wrapped(baseX + sway, limit: width)
        let y = -30 + progress * (canvasSize.height + 60)
        let depth = 0.45 + secondarySeed * 0.75

        return Motion(
            position: CGPoint(x: x, y: y),
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
