import SwiftUI

/// The native report flow. Rows sit 8 points inside the 32-point panel, so
/// their 24-point corners and nested 16-point controls stay concentric.
struct IssueReportView: View {
    let model: AppModel
    @Environment(\.windowModalContext) private var modalContext
    @Environment(\.windowModalAvailableSize) private var availableSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var movesForward = true

    private var store: IssueReportStore { model.issueReports }

    var body: some View {
        VStack(spacing: 0) {
            IssueReportHeader(store: store, navigate: navigate) { modalContext?() }
            Divider()
            content
            if store.step != .done, store.definition != nil {
                IssueReportErrorBanner(message: store.error)
                Divider()
                footer
            }
        }
        .frame(width: min(580, availableSize.width))
        .windowModalDismissDisabled(store.isSubmitting)
        .animation(.snappy(duration: 0.3), value: store.error)
        .animation(.snappy(duration: 0.3), value: store.isSubmitting)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(IssueReportKindBadge.title(store.kind))
    }

    @ViewBuilder
    private var content: some View {
        switch store.formState {
        case .loading where store.form == nil:
            VStack(spacing: InterfaceScale.metric(12)) {
                ProgressView()
                Text("Loading the report form…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(240))
        case let .failed(message) where store.form == nil:
            IssueReportUnavailableView(kind: store.kind, message: message) {
                store.loadForm(force: true)
            }
        default:
            steps
        }
    }

    private var steps: some View {
        ZStack {
            switch store.step {
            case .describe:
                scrolling { IssueReportDescribeStep(model: model) }
                    .transition(stepTransition)
            case .details:
                scrolling { IssueReportDetailsStep(model: model) }
                    .transition(stepTransition)
            case .review:
                scrolling { IssueReportReviewStep(model: model, navigate: navigate) }
                    .transition(stepTransition)
            case .done:
                IssueReportCompletionView(model: model) { modalContext?(allowsDisabled: true) }
                    .transition(AnyTransition(.blurReplace).combined(with: .scale(scale: 0.96)))
            }
        }
        .clipped()
        .disabled(store.isSubmitting)
        .opacity(store.isSubmitting ? 0.55 : 1)
    }

    private func scrolling(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView(.vertical) {
            GlassEffectContainer(spacing: InterfaceScale.metric(8)) {
                content()
                    .padding(InterfaceScale.metric(8))
            }
        }
        .scrollBounceBehavior(.always, axes: .vertical)
        .frame(maxHeight: min(600, max(220, availableSize.height - 170)))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: movesForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: movesForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private var footer: some View {
        HStack(spacing: InterfaceScale.metric(10)) {
            if store.step == .describe {
                ModalGlassButton(symbol: "xmark", label: "Cancel") { modalContext?() }
            } else {
                ModalGlassButton(symbol: "chevron.left", label: "Back") {
                    navigate(forward: false) { store.goBack() }
                }
                .keyboardShortcut("[", modifiers: .command)
            }
            Spacer(minLength: InterfaceScale.metric(12))
            if store.pendingAttachmentLoads > 0 {
                IssueReportProgressLabel(phase: .preparing)
            } else if let phase = store.phase {
                IssueReportProgressLabel(phase: phase)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            if store.step == .review {
                ModalGlassButton(
                    symbol: store.kind == .bug ? "paperplane.fill" : "sparkles",
                    label: store.definition?.submitLabel.localizedCapitalized ?? "Submit",
                    primary: true
                ) { model.submitIssueReport() }
                .disabled(store.isSubmitting)
                .keyboardShortcut(.return, modifiers: .command)
            } else {
                ModalGlassButton(symbol: "chevron.right", label: "Continue", primary: true) {
                    navigate(forward: true) { store.advance() }
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(InterfaceScale.metric(12))
    }

    private func navigate(forward: Bool, _ change: () -> Void) {
        movesForward = forward
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.34)) { change() }
    }
}

private struct IssueReportHeader: View {
    let store: IssueReportStore
    let navigate: (Bool, () -> Void) -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: InterfaceScale.metric(12)) {
            IssueReportKindBadge(kind: store.kind, size: InterfaceScale.metric(40))
            VStack(alignment: .leading, spacing: 1) {
                Text(IssueReportKindBadge.title(store.kind))
                    .font(.interface(.title3).weight(.semibold))
                    .contentTransition(.opacity)
                Text(subtitle)
                    .font(.interface(.callout))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            .animation(.snappy, value: store.kind)
            .animation(.snappy, value: store.step)
            Spacer(minLength: InterfaceScale.metric(12))
            if store.step != .done, store.definition != nil {
                IssueReportStepIndicator(step: store.step) { target in
                    navigate(false) { store.go(to: target) }
                }
            }
            HoverCloseButton(help: "Close", accessibilityIdentifier: "issue-report-close", action: close)
                .disabled(store.isSubmitting)
        }
        .padding(.leading, InterfaceScale.metric(16))
        .padding(.trailing, InterfaceScale.metric(12))
        .padding(.vertical, InterfaceScale.metric(12))
    }

    private var subtitle: String {
        switch store.step {
        case .describe: store.kind == .bug ? "What went wrong?" : "What would you like?"
        case .details: store.kind == .bug ? "Screenshots and diagnostics" : "Mockups and details"
        case .review: "Check it over"
        case .done: store.outcome?.followedExisting == true ? "Following" : "Sent"
        }
    }
}

/// Capsules for the three editing steps; completed steps can be revisited.
private struct IssueReportStepIndicator: View {
    let step: IssueReportStore.Step
    let select: (IssueReportStore.Step) -> Void

    var body: some View {
        HStack(spacing: InterfaceScale.metric(5)) {
            ForEach([IssueReportStore.Step.describe, .details, .review], id: \.self) { item in
                Button { select(item) } label: {
                    Capsule()
                        .fill(item <= step ? AnyShapeStyle(SakuraCordAccentColor.color) : AnyShapeStyle(.quaternary))
                        .opacity(item < step ? 0.55 : 1)
                        .frame(width: item == step ? 24 : 8, height: InterfaceScale.metric(8))
                        .padding(.vertical, InterfaceScale.metric(6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item >= step)
                .help(Self.title(item))
                .accessibilityLabel(Self.title(item))
                .accessibilityAddTraits(item == step ? .isSelected : [])
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.35), value: step)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(step.rawValue + 1) of 3")
    }

    static func title(_ step: IssueReportStore.Step) -> String {
        switch step {
        case .describe: "Describe"
        case .details: "Details"
        case .review: "Review"
        case .done: "Done"
        }
    }
}

struct IssueReportKindBadge: View {
    let kind: IssueReportKind
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: Self.symbol(kind))
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: size, height: size)
            .glassEffect(.regular.tint(SakuraCordAccentColor.color), in: Circle())
            .animation(.snappy, value: kind)
            .accessibilityHidden(true)
    }

    static func symbol(_ kind: IssueReportKind) -> String {
        kind == .bug ? "ladybug.fill" : "lightbulb.max.fill"
    }

    static func title(_ kind: IssueReportKind) -> String {
        kind == .bug ? "Report a Bug" : "Suggest a Feature"
    }
}

private struct IssueReportProgressLabel: View {
    let phase: IssueReportStore.Phase

    var body: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.interface(.callout))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        .animation(.snappy, value: phase)
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        switch phase {
        case .preparing: "Preparing attachments…"
        case .signingIn: "Confirming your Discord account…"
        case .sending: "Sending…"
        }
    }
}

private struct IssueReportErrorBanner: View {
    let message: String?

    var body: some View {
        if let message, !message.isEmpty {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.interface(.callout))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, InterfaceScale.metric(18))
                .padding(.vertical, InterfaceScale.metric(10))
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

private struct IssueReportUnavailableView: View {
    let kind: IssueReportKind
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: InterfaceScale.metric(14)) {
            Image(systemName: "icloud.slash")
                .font(.interfaceSystem(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(spacing: InterfaceScale.metric(4)) {
                Text("Reporting is unavailable").font(.interface(.headline))
                Text(message)
                    .font(.interface(.callout))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: InterfaceScale.metric(10)) {
                ModalGlassButton(symbol: "safari", label: "Use the Website") {
                    NSWorkspace.shared.open(IssueReportLink.current(kind).url)
                }
                ModalGlassButton(symbol: "arrow.clockwise", label: "Try Again", primary: true, action: retry)
            }
        }
        .padding(InterfaceScale.metric(28))
        .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(240))
    }
}
