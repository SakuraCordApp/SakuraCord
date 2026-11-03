import SwiftUI

struct SakuraCordSignInBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = SakuraCordThemeStore.shared.activeTheme.colors(for: colorScheme)
        SakuraCordAuthenticationTimeline { elapsed in
            Rectangle()
                .fill(colorScheme == .dark ? Color(hex: 0x101018) : Color(hex: 0xF6F5FA))
                .colorEffect(ShaderLibrary.bundle(.module).sakuraSignInLight(
                    .boundingRect,
                    .float(elapsed),
                    .color(colors[0]),
                    .color(colors[colors.count / 2]),
                    .color(colors[colors.count - 1]),
                    .float(colorScheme == .dark ? 1 : 0)
                ))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Keeps animation updates inside each small drawing surface. Both the
/// background and loading surfaces preserve their phase while off screen.
struct SakuraCordAuthenticationTimeline<Content: View>: View {
    @ViewBuilder var content: (TimeInterval) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isWindowVisible = false
    @State private var elapsedTime: TimeInterval = 0
    @State private var resumedAt: TimeInterval?
    @State private var conservesPower = Self.shouldConservePower

    private static var shouldConservePower: Bool {
        let process = ProcessInfo.processInfo
        return process.isLowPowerModeEnabled
            || process.thermalState == .serious
            || process.thermalState == .critical
    }

    var body: some View {
        let paused = reduceMotion || conservesPower || !isWindowVisible
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: paused)) { _ in
            content(elapsedTime + (resumedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0))
        }
        .background {
            WindowVisibilityReader { isWindowVisible = $0 }
        }
        .onAppear { setAnimationRunning(!paused) }
        .onChange(of: paused) { _, paused in
            setAnimationRunning(!paused)
        }
        .onDisappear { setAnimationRunning(false) }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            conservesPower = Self.shouldConservePower
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            conservesPower = Self.shouldConservePower
        }
    }

    private func setAnimationRunning(_ running: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if running {
            if resumedAt == nil { resumedAt = now }
        } else if let resumedAt {
            elapsedTime += now - resumedAt
            self.resumedAt = nil
        }
    }
}

@Animatable
struct SakuraCordSignInReveal: ViewModifier {
    var progress: Double
    @AnimatableIgnored var reduceMotion: Bool

    init(isVisible: Bool, reduceMotion: Bool) {
        progress = isVisible ? 1 : 0
        self.reduceMotion = reduceMotion
    }

    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.9)
    }

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: reduceMotion ? 0 : 12 * (1 - progress))
            .offset(y: reduceMotion ? 0 : 18 * (1 - progress))
            .scaleEffect(reduceMotion ? 1 : 0.985 + 0.015 * progress)
    }
}

struct OfflineSignInControls: View {
    let service: OfflineSignInService
    let canScan: Bool
    let canSimulateMFA: Bool
    let simulateMFA: () -> Void
    let replay: () -> Void

    var body: some View {
        HStack(spacing: InterfaceScale.metric(12)) {
            Label("Offline preview", systemImage: "network.slash")
                .foregroundStyle(.secondary)
            Button("Simulate scan") { Task { await service.simulateScan() } }
                .disabled(!canScan)
            Button("Simulate MFA", action: simulateMFA)
                .disabled(!canSimulateMFA)
            Menu("More") {
                Button("Expire QR code") { Task { await service.expireCode() } }
                    .disabled(!canScan)
                Button("Replay welcome", action: replay)
                Divider()
                Text("Any email + 8–72 character password")
                Text("Authenticator / SMS: 123456")
                Text("Backup code: abcd1234")
                Text("Error: password incorrect")
            }
        }
        .font(.interface(.caption))
        .controlSize(.small)
        .padding(.horizontal, InterfaceScale.metric(14))
        .padding(.vertical, InterfaceScale.metric(8))
        .background(.regularMaterial, in: Capsule())
    }
}
