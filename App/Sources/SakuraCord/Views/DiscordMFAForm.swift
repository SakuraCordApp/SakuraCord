import SwiftUI

/// The challenge owns the available methods; this view only navigates between
/// the method chooser and the selected method's input. Authentication stays in
/// the login view's single submission path.
struct DiscordMFAForm: View {
    let challenge: DiscordMFAChallenge
    let selectedMethod: DiscordMFAMethod?
    @Binding var code: String
    let isWorking: Bool
    let isTransitioning: Bool
    let isSendingSMS: Bool
    let smsCooldownEndsAt: Date?
    let focusedField: FocusState<DiscordLoginField?>.Binding
    let errorMessage: String?
    let selectMethod: (DiscordMFAMethod?) -> Void
    let submit: () -> Void
    let sendSMS: () -> Void
    let goBack: () -> Void

    var body: some View {
        VStack(spacing: InterfaceScale.metric(28)) {
            header

            ZStack {
                if let selectedMethod {
                    verificationInput(for: selectedMethod)
                } else {
                    methodChoices
                }
            }
            .padding(InterfaceScale.metric(2))
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.2), value: errorMessage)
        .onExitCommand(perform: goBack)
        .onChange(of: focusedField.wrappedValue) { _, field in
            guard field == nil, !isWorking, !isTransitioning, selectedMethod != nil else { return }
            focusedField.wrappedValue = .mfa
        }
    }

    private var header: some View {
        VStack(spacing: InterfaceScale.metric(10)) {
            Text("Multi-Factor Authentication")
                .font(.interface(.title2).bold())
                .foregroundStyle(.primary)
            Text(selectedMethod?.instructions ?? "Choose how to verify your sign-in.")
                .font(.interface(.subheadline))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, InterfaceScale.metric(36))
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topLeading) {
            Button(action: goBack) {
                Image(systemName: selectedMethod == nil ? "xmark" : "chevron.left")
                    .font(.interface(.body).weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: InterfaceScale.metric(18), height: InterfaceScale.metric(18))
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.regular)
            .disabled(isWorking)
            .help(selectedMethod == nil ? "Back to sign in" : "Choose another method")
            .accessibilityLabel(selectedMethod == nil ? "Back to sign in" : "Choose another method")
            .keyboardShortcut(selectedMethod == nil ? .cancelAction : nil)
        }
    }

    private var methodChoices: some View {
        VStack(spacing: InterfaceScale.metric(12)) {
            ForEach(challenge.methods, id: \.self) { method in
                Button {
                    selectMethod(method)
                } label: {
                    Label(method.title, systemImage: method.systemImage)
                        .font(.interface(.body).weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(28))
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
        }
        .disabled(isWorking)
    }

    private func verificationInput(for method: DiscordMFAMethod) -> some View {
        VStack(spacing: InterfaceScale.metric(16)) {
            segmentedCodeInput(for: method)
                .disabled(isWorking)

            if method == .sms {
                smsSendControl
            }

            VStack(spacing: InterfaceScale.metric(8)) {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .transition(.opacity)
                }
                Text(status(for: method))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .font(.interface(.caption))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(28))
        }
    }

    private func segmentedCodeInput(for method: DiscordMFAMethod) -> some View {
        ZStack {
            TextField("", text: normalizedInput(for: method))
                .accessibilityLabel(method == .backup ? "Backup code" : method == .sms ? "SMS code" : "Authentication code")
                .accessibilityValue(displayedCode(for: method))
                .accessibilityHint(method == .backup
                    ? "Enter eight letters or numbers in two groups of four. The code is verified automatically."
                    : "Enter six digits. The code is verified automatically.")
                .textFieldStyle(.plain)
                .textContentType(method == .backup ? nil : .oneTimeCode)
                .focused(focusedField, equals: .mfa)
                .onSubmit(submit)
                .opacity(0.01)

            HStack(spacing: method == .backup ? InterfaceScale.metric(6) : InterfaceScale.metric(10)) {
                ForEach(0 ..< method.codeLength, id: \.self) { index in
                    if method == .backup, index == 4 {
                        Text("-")
                            .font(.interface(.title3).monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: InterfaceScale.metric(10))
                    }
                    codeCell(at: index, method: method)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .frame(height: InterfaceScale.metric(58))
        .contentShape(Rectangle())
        .onTapGesture { focusedField.wrappedValue = .mfa }
        .pointerStyle(.horizontalText)
    }

    private func displayedCode(for method: DiscordMFAMethod) -> String {
        guard method == .backup else { return code }
        let uppercase = code.uppercased()
        return uppercase.count > 4 ? String(uppercase.prefix(4)) + "-" + uppercase.dropFirst(4) : uppercase
    }

    private func codeCell(at index: Int, method: DiscordMFAMethod) -> some View {
        let characters = Array(code.uppercased())
        let isCurrent = focusedField.wrappedValue == .mfa && !isWorking && index == min(characters.count, method.codeLength - 1)
        let radius: CGFloat = method == .backup ? InterfaceScale.metric(14) : InterfaceScale.metric(18)
        return ZStack {
            RoundedRectangle(cornerRadius: radius)
                .fill(.background.opacity(0.72))
            if index < characters.count {
                Text(String(characters[index]))
                    .font(.interfaceSystem(size: method == .backup ? 22 : 25, weight: .medium, design: .monospaced))
            } else if isCurrent {
                Capsule()
                    .fill(SakuraCordAccentColor.color)
                    .frame(width: InterfaceScale.metric(2), height: InterfaceScale.metric(22))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: radius)
                .stroke(
                    isCurrent ? SakuraCordAccentColor.focusRing : .primary.opacity(0.12),
                    lineWidth: 1
                )
        }
        .frame(maxWidth: .infinity)
        .opacity(isWorking ? 0.5 : 1)
        .authenticationLoading(isWorking && !isSendingSMS, in: RoundedRectangle(cornerRadius: radius))
    }

    private var smsSendControl: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(ceil(smsCooldownEndsAt?.timeIntervalSince(context.date) ?? 0)))
            HStack(spacing: InterfaceScale.metric(12)) {
                Button("Resend code", action: sendSMS)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.regular)
                    .disabled(isWorking || remaining > 0)

                if remaining > 0 {
                    Text("Available in \(remaining)s")
                        .font(.interface(.caption))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func normalizedInput(for method: DiscordMFAMethod) -> Binding<String> {
        Binding(
            get: { code },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                let filtered = method == .backup
                    ? String(trimmed.filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
                    : trimmed
                code = method.normalizedCode(filtered)
                if code.count == method.codeLength { submit() }
            }
        )
    }

    private func status(for method: DiscordMFAMethod) -> String {
        if isSendingSMS { return "Sending your code…" }
        if isWorking { return "Verifying…" }
        if method == .backup { return "Each backup code can only be used once." }
        if method == .sms {
            return smsCooldownEndsAt == nil
                ? "Use Resend code to try again."
                : "Code sent. Your code is verified automatically."
        }
        return "Your code is verified automatically."
    }

}

private extension DiscordMFAMethod {
    var title: String {
        switch self {
        case .totp: "Authenticator App"
        case .backup: "Backup Code"
        case .sms: "Text Message"
        }
    }

    var instructions: String {
        switch self {
        case .totp: "Enter the 6-digit code from your authenticator app."
        case .backup: "Enter one of your 8-character backup codes."
        case .sms: "Enter the 6-digit code sent to your phone."
        }
    }

    var systemImage: String {
        switch self {
        case .totp: "lock.rotation"
        case .backup: "key"
        case .sms: "message"
        }
    }
}
