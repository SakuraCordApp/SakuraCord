import SwiftUI

/// Links for the filed report. Members open the forum post in SakuraCord;
/// everyone else can join the server through the normal invite flow.
struct IssueReportCompletionView: View {
    let model: AppModel
    let close: () -> Void

    private var store: IssueReportStore { model.issueReports }

    var body: some View {
        if let outcome = store.outcome {
            VStack(spacing: InterfaceScale.metric(18)) {
                IssueReportCelebration(kind: store.kind)
                VStack(spacing: InterfaceScale.metric(6)) {
                    Text(outcome.followedExisting
                        ? "You’re following #\(outcome.filed.number)"
                        : "Filed as #\(outcome.filed.number)")
                        .font(.interface(.title2).weight(.bold))
                    Text(message(outcome))
                        .font(.interface(.callout))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, InterfaceScale.metric(24))
                actions(outcome)
                if case let .failed(message) = store.joinState {
                    Text(message)
                        .font(.interface(.caption))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }
                Button("Done", action: close)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, InterfaceScale.metric(28))
            .padding(.bottom, InterfaceScale.metric(20))
            .frame(maxWidth: .infinity)
            .animation(.snappy(duration: 0.35), value: model.isInSakuraCordServer)
            .animation(.snappy(duration: 0.25), value: store.joinState)
        }
    }

    @ViewBuilder
    private func actions(_ outcome: IssueReportStore.Outcome) -> some View {
        GlassEffectContainer(spacing: InterfaceScale.metric(10)) {
            HStack(spacing: InterfaceScale.metric(10)) {
                if model.isInSakuraCordServer {
                    if outcome.filed.threadId != nil {
                        IssueReportActionButton(
                            title: "Open Forum Post",
                            icon: Image("discord", bundle: .module),
                            primary: true
                        ) { model.openIssueReportForumPost() }
                        .transition(.blurReplace)
                    }
                    IssueReportActionButton(
                        title: "View on GitHub",
                        icon: Image("github", bundle: .module)
                    ) { NSWorkspace.shared.open(outcome.filed.issueUrl) }
                } else {
                    IssueReportActionButton(
                        title: "Join SakuraCord Server",
                        icon: Image("discord", bundle: .module),
                        primary: true,
                        isBusy: store.joinState == .joining
                    ) { Task { await model.joinSakuraCordServer() } }
                    .transition(.blurReplace)
                    IssueReportActionButton(
                        title: "View on Tracker",
                        icon: Image(systemName: "list.bullet.rectangle.portrait")
                    ) { NSWorkspace.shared.open(outcome.filed.trackerUrl) }
                }
            }
        }
    }

    private func message(_ outcome: IssueReportStore.Outcome) -> String {
        if outcome.followedExisting {
            return "Your details were added to the existing report. You’ll be pinged in Discord when it’s completed."
        }
        return model.isInSakuraCordServer
            ? "It has a GitHub issue and a forum post. You’ll be pinged there when it’s completed."
            : "It has a GitHub issue and a post in the SakuraCord server. Join to follow the discussion and get pinged when it’s completed."
    }
}

/// A checkmark that lands with a small burst of petals.
private struct IssueReportCelebration: View {
    let kind: IssueReportKind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var landed = false
    @State private var spread = false
    @State private var faded = false

    private static let petalCount = 12

    var body: some View {
        ZStack {
            if !reduceMotion {
                ForEach(0 ..< Self.petalCount, id: \.self) { index in
                    let angle = Angle.degrees(Double(index) / Double(Self.petalCount) * 360 + 8)
                    let distance: CGFloat = index.isMultiple(of: 2) ? 64 : 50
                    Ellipse()
                        .fill(SakuraCordAccentColor.color.gradient)
                        .frame(width: index.isMultiple(of: 3) ? 7 : 9, height: index.isMultiple(of: 3) ? 11 : 14)
                        .rotationEffect(angle + .degrees(spread ? 120 : 0))
                        .offset(
                            x: spread ? cos(angle.radians) * distance : 0,
                            y: spread ? sin(angle.radians) * distance : 0
                        )
                        .scaleEffect(spread ? 1 : 0.2)
                        .opacity(faded ? 0 : (spread ? 0.9 : 0))
                }
            }
            Image(systemName: "checkmark")
                .font(.interfaceSystem(size: 30, weight: .bold))
                .foregroundStyle(SakuraCordAccentColor.labelOnFill)
                .symbolEffect(.bounce, value: landed)
                .frame(width: InterfaceScale.metric(72), height: InterfaceScale.metric(72))
                .glassEffect(.regular.tint(SakuraCordAccentColor.color), in: Circle())
                .scaleEffect(landed ? 1 : 0.4)
                .opacity(landed ? 1 : 0)
        }
        .frame(width: InterfaceScale.metric(150), height: InterfaceScale.metric(120))
        .accessibilityHidden(true)
        .task {
            withAnimation(.spring(duration: 0.5, bounce: 0.45)) { landed = true }
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.easeOut(duration: 0.85)) { spread = true }
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.easeIn(duration: 0.6)) { faded = true }
        }
    }
}
