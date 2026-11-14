import SakuraCordModels
import SwiftUI

struct ProfileAvatarExpansion: ViewModifier {
    var openProfile: (() -> Void)?
    @State private var isHovered = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if let openProfile {
            Button(action: openProfile) {
                content.overlay {
                    Circle().fill(.black.opacity(isHovered ? 0.22 : 0))
                        .allowsHitTesting(false)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .pointerStyle(.link)
            .onModalHover { isHovered = $0 }
            .help("Open full profile")
            .accessibilityLabel("Open full profile")
        } else {
            content
        }
    }
}

struct ProfileQuickMessageView: View {
    let displayName: String
    let send: (String, String) async -> Bool
    var releaseNonce: (String) -> Void = { _ in }
    /// Called as a send starts. The returned action opens the conversation
    /// after a confirmed send, while the card is open.
    var conversationOpener: (() -> () -> Void)?
    @Environment(\.stablePopoverPresentationContext) private var popoverPresentationContext
    @State private var isPresented = false
    @State private var draft = ""
    @State private var nonce = ClientNonce.make()
    @State private var isSending = false
    @State private var failure: LocalizedStringResource?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(6)) {
            // The error sits above the field so the field stays docked
            // against the card's bottom corners.
            if let failure {
                Text(failure)
                    .font(.interface(.caption))
                    .foregroundStyle(.secondary)
                    .padding(.leading, ProfileQuickMessageMetrics.fieldPadding + ProfileQuickMessageMetrics.textInset)
            }
            HStack(spacing: InterfaceScale.metric(6)) {
                TextField("Message @\(displayName)", text: Binding(
                    get: { draft },
                    set: {
                        draft = $0
                        failure = nil
                    }
                ))
                    .textFieldStyle(.plain)
                    .font(.interface(.body))
                    .focused($isFocused)
                    .onSubmit(submit)
                    .disabled(isSending)
                    .padding(.leading, ProfileQuickMessageMetrics.textInset)
                // Stays tinted while sending; `submit` ignores repeat presses.
                ProfileQuickMessageSendButton(isSending: isSending, action: submit)
                    .disabled(!hasDraft)
            }
            .padding(ProfileQuickMessageMetrics.fieldPadding)
            .background {
                // Clicking the field's padding focuses the text, like a native field.
                ProfileQuickMessageMetrics.fieldShape
                    .fill(.quaternary.opacity(isFocused ? 0.75 : 0.5))
                    .onTapGesture { isFocused = true }
            }
            .overlay {
                ProfileQuickMessageMetrics.fieldShape
                    .stroke(isFocused ? AnyShapeStyle(.tint.opacity(0.7)) : AnyShapeStyle(.separator), lineWidth: 1)
                    .padding(0.5)
                    .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.15), value: isFocused)
        }
        .onChange(of: draft) { _, _ in
            if !isSending {
                releaseNonce(nonce)
                nonce = ClientNonce.make()
            }
        }
        .onAppear { isPresented = true }
        .onDisappear {
            isPresented = false
            releaseNonce(nonce)
        }
    }

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard !isSending, hasDraft else { return }
        let content = draft
        let submissionNonce = nonce
        let openConversation = conversationOpener?()
        isSending = true
        failure = nil
        Task { @MainActor in
            let sent = await send(content, submissionNonce)
            if sent {
                releaseNonce(submissionNonce)
                draft = ""
                nonce = ClientNonce.make()
            } else {
                failure = "Couldn't send message. Try again."
            }
            isSending = false
            // A card the user already closed must not pull them away later.
            if sent, isPresented, let openConversation {
                popoverPresentationContext?.dismiss?()
                openConversation()
            }
        }
    }
}

enum ProfileQuickMessageMetrics {
    static var buttonSize: CGFloat { InterfaceScale.metric(28) }
    static var textInset: CGFloat { InterfaceScale.metric(10) }

    // The card's surface radius doesn't scale with Interface Size, so the
    // insets between it, the field, and the button don't either. That keeps
    // all three on one corner center at every scale.

    /// Distance from the card's inner surface to the field, along the sides and bottom.
    static let cardInset: CGFloat = 6
    static let fieldPadding: CGFloat = 4

    static var fieldShape: ConcentricRectangle {
        ConcentricRectangle(cornerRadius: MemberProfilePopover<EmptyView>.surfaceCornerRadius - cardInset)
    }

    static var buttonShape: ConcentricRectangle {
        ConcentricRectangle(cornerRadius: MemberProfilePopover<EmptyView>.surfaceCornerRadius - cardInset - fieldPadding)
    }
}

private struct ProfileQuickMessageSendButton: View {
    let isSending: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            if isSending {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "paperplane.fill")
                    .font(.interfaceSystem(size: 12, weight: .semibold))
            }
        }
        .buttonStyle(ProfileQuickMessageSendButtonStyle(isHovering: isHovering))
        .onModalHover { isHovering = $0 }
        .help("Send message")
        .accessibilityLabel("Send message")
    }
}

private struct ProfileQuickMessageSendButtonStyle: ButtonStyle {
    let isHovering: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let shape = ProfileQuickMessageMetrics.buttonShape
        // Both states keep the same layers and only animate their opacity and
        // color, so enabling the button fades instead of swapping styles.
        configuration.label
            .foregroundStyle(isEnabled ? SakuraCordAccentColor.labelOnFill : Color(nsColor: .tertiaryLabelColor))
            .frame(width: ProfileQuickMessageMetrics.buttonSize, height: ProfileQuickMessageMetrics.buttonSize)
            .background {
                ZStack {
                    shape.fill(.quaternary)
                    shape.fill(.tint).opacity(isEnabled ? 1 : 0)
                }
            }
            .overlay {
                shape.fill(stateOverlay(isPressed: configuration.isPressed)).allowsHitTesting(false)
            }
            .contentShape(shape)
            .scaleEffect(scale(isPressed: configuration.isPressed))
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.18), value: isEnabled)
            .pointerStyle(isEnabled ? .link : nil)
    }

    private func scale(isPressed: Bool) -> CGFloat {
        guard isEnabled, !reduceMotion else { return 1 }
        if isPressed { return 0.92 }
        return isHovering ? 1.06 : 1
    }

    private func stateOverlay(isPressed: Bool) -> Color {
        guard isEnabled else { return .clear }
        if isPressed { return .black.opacity(0.18) }
        return isHovering ? .white.opacity(0.16) : .clear
    }
}
