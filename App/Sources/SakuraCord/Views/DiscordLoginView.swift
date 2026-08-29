import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import DiscordProtocol
import SwiftUI

private enum DiscordLoginField: Hashable {
    case identifier
    case password
    case mfa
}

private enum DiscordCaptchaPurpose: Equatable {
    case credentials
    case remoteAuth
}

struct DiscordLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let showsCancel: Bool
    let networkingEnabled: Bool
    let onConnected: @MainActor (PendingDiscordCredential) async -> String?

    @State private var authenticator: DiscordSessionAuthenticator
    @State private var remoteAuthManager = DiscordRemoteAuthManager()
    @State private var identifier = ""
    @State private var password = ""
    @State private var mfaCode = ""
    @State private var challenge: DiscordMFAChallenge?
    @State private var captchaChallenge: DiscordCaptchaChallenge?
    @State private var captchaPurpose: DiscordCaptchaPurpose?
    @State private var captchaInteractionVisible = false
    @State private var selectedMFAMethod: DiscordMFAMethod?
    @State private var isWorking = false
    @State private var errorTitle: String?
    @State private var errorMessage: String?
    @State private var authenticationTask: Task<Void, Never>?
    @State private var remoteAuthTask: Task<Void, Never>?
    @State private var remoteAuthState: DiscordRemoteAuthPresentationState = .connecting
    @State private var automaticRemoteAuthRestarts = 0
    @State private var isHandingOffCredential = false
    @State private var smsCooldownEndsAt: Date?
    @State private var backgroundAnimationStart = Date()
    @FocusState private var focusedField: DiscordLoginField?

    init(
        showsCancel: Bool,
        networkingEnabled: Bool,
        onConnected: @escaping @MainActor (PendingDiscordCredential) async -> String?
    ) {
        self.showsCancel = showsCancel
        self.networkingEnabled = networkingEnabled
        self.onConnected = onConnected
        _authenticator = State(initialValue: DiscordSessionAuthenticator())
    }

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
                    let elapsed = reduceMotion ? 0 : timeline.date.timeIntervalSince(backgroundAnimationStart)
                    ZStack {
                        SakuraCordAuroraBackdrop(elapsed: elapsed)
                        SakuraCordSakuraPetalField(elapsed: elapsed, size: geometry.size)
                            .accessibilityHidden(true)
                    }
                }
            }
            .ignoresSafeArea()

            GeometryReader { geometry in
                ScrollView {
                    SakuraCordAuthenticationCard {
                        if let challenge {
                            VStack(alignment: .leading, spacing: 18) {
                                DiscordLoginHeader()
                                DiscordMFAForm(
                                    challenge: challenge,
                                    selectedMethod: $selectedMFAMethod,
                                    code: $mfaCode,
                                    isWorking: isWorking,
                                    smsCooldownEndsAt: smsCooldownEndsAt,
                                    focusedField: $focusedField,
                                    submit: submitMFA,
                                    sendSMS: sendSMS,
                                    goBack: resetToCredentials
                                )
                                DiscordLoginStatus(
                                    title: errorTitle,
                                    message: errorMessage
                                )
                            }
                        } else {
                            HStack(alignment: .center, spacing: 32) {
                                VStack(alignment: .leading, spacing: 22) {
                                    DiscordLoginHeader()
                                    DiscordCredentialForm(
                                        identifier: $identifier,
                                        password: $password,
                                        isWorking: isWorking,
                                        focusedField: $focusedField,
                                        submit: submitCredentials
                                    )
                                    DiscordLoginStatus(
                                        title: errorTitle,
                                        message: errorMessage
                                    )
                                }
                                .frame(width: 390, alignment: .leading)

                                Rectangle()
                                    .fill(Color(nsColor: .separatorColor).opacity(0.72))
                                    .frame(width: 1, height: 300)

                                DiscordRemoteAuthPanel(
                                    state: remoteAuthState,
                                    retry: restartRemoteAuth
                                )
                                .frame(width: 236)
                            }
                        }
                    }
                    .frame(maxWidth: challenge == nil ? 800 : 500)
                    .padding(.horizontal, 34)
                    .padding(.vertical, 42)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollIndicators(.hidden)
            }

            windowDragRegion

            if showsCancel {
                SakuraCordAuthenticationCloseButton { dismiss() }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            if let captchaChallenge {
                DiscordCaptchaPresentation(
                    challenge: captchaChallenge,
                    isVisible: $captchaInteractionVisible,
                    cancel: {
                        completeCaptcha(challenge: captchaChallenge, token: nil)
                    },
                    interactionRequired: {
                        captchaInteractionVisible = true
                        if captchaPurpose == .remoteAuth {
                            remoteAuthState = .challenge
                        }
                    },
                    onToken: { token in
                        completeCaptcha(challenge: captchaChallenge, token: token)
                    }
                )
            }
        }
        .frame(minWidth: 860, minHeight: 600)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onAppear {
            backgroundAnimationStart = Date()
            focusedField = .identifier
            if networkingEnabled {
                startRemoteAuth()
            } else {
                remoteAuthState = .disabled
            }
        }
        .onDisappear {
            if !isHandingOffCredential {
                authenticationTask?.cancel()
                remoteAuthTask?.cancel()
            }
            Task { await remoteAuthManager.disconnect() }
            if let captchaChallenge {
                Task { await authenticator.cancelCaptcha(challengeID: captchaChallenge.id) }
            }
        }
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

    private func submitCredentials() {
        guard networkingEnabled else {
            errorTitle = "Sign-in unavailable"
            errorMessage = "Discord networking is disabled for this launch."
            return
        }
        guard !isWorking else { return }
        let submittedIdentifier = identifier
        let submittedPassword = password
        errorTitle = nil
        errorMessage = nil
        isWorking = true
        authenticationTask?.cancel()
        authenticationTask = Task {
            defer { isWorking = false }
            do {
                let step = try await authenticator.login(
                    identifier: submittedIdentifier,
                    password: submittedPassword
                )
                await handle(step)
            } catch is CancellationError {
                return
            } catch {
                errorTitle = "Sign-in stopped"
                errorMessage = error.localizedDescription
                focusedField = .password
            }
        }
    }

    private func completeCaptcha(challenge captcha: DiscordCaptchaChallenge, token: String?) {
        captchaChallenge = nil
        captchaInteractionVisible = false
        let purpose = captchaPurpose
        captchaPurpose = nil
        guard let token else {
            errorTitle = "CAPTCHA cancelled"
            errorMessage = AuthenticationError.invalidCaptchaSolution.localizedDescription
            Task { await authenticator.cancelCaptcha(challengeID: captcha.id) }
            if purpose == .remoteAuth {
                remoteAuthState = .failed("The Discord challenge was cancelled. Create a new code when you’re ready.")
                Task { await remoteAuthManager.disconnect() }
            }
            return
        }
        errorTitle = nil
        errorMessage = nil
        isWorking = true
        authenticationTask?.cancel()
        authenticationTask = Task {
            defer { isWorking = false }
            do {
                switch purpose {
                case .remoteAuth:
                    let encryptedToken = try await authenticator.completeRemoteAuthCaptcha(
                        challenge: captcha,
                        solutionToken: token
                    )
                    try await finishRemoteAuth(encryptedToken: encryptedToken)
                case .credentials, .none:
                    let step = try await authenticator.completeCaptcha(
                        challenge: captcha,
                        solutionToken: token
                    )
                    await handle(step)
                }
            } catch is CancellationError {
                return
            } catch {
                errorTitle = "Challenge submission stopped"
                errorMessage = error.localizedDescription
                if purpose == .remoteAuth {
                    await remoteAuthManager.disconnect()
                    remoteAuthState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func handle(_ step: DiscordNativeAuthenticationStep) async {
        switch step {
        case let .authenticated(credential):
            await finishConnection(credential)
        case let .mfa(value):
            challenge = value
            selectedMFAMethod = value.methods.first
            mfaCode = ""
            focusedField = .mfa
        case let .captcha(value):
            presentCaptcha(value, purpose: .credentials)
        }
    }

    private func submitMFA() {
        guard let challenge, let selectedMFAMethod, !isWorking else { return }
        let submittedCode = mfaCode
        mfaCode = ""
        errorTitle = nil
        errorMessage = nil
        isWorking = true
        authenticationTask?.cancel()
        authenticationTask = Task {
            defer { isWorking = false }
            do {
                let credential = try await authenticator.completeMFA(
                    challenge: challenge,
                    method: selectedMFAMethod,
                    code: submittedCode
                )
                await finishConnection(credential)
            } catch is CancellationError {
                return
            } catch {
                errorTitle = "MFA verification stopped"
                errorMessage = error.localizedDescription
                focusedField = .mfa
            }
        }
    }

    private func sendSMS() {
        guard let challenge, !isWorking else { return }
        errorTitle = nil
        errorMessage = nil
        isWorking = true
        authenticationTask?.cancel()
        authenticationTask = Task {
            defer { isWorking = false }
            do {
                try await authenticator.sendSMS(for: challenge)
                smsCooldownEndsAt = .now.addingTimeInterval(30)
                focusedField = .mfa
            } catch is CancellationError {
                return
            } catch {
                errorTitle = "SMS request stopped"
                errorMessage = error.localizedDescription
            }
        }
    }

    private func finishConnection(_ credential: PendingDiscordCredential) async {
        isHandingOffCredential = true
        if let bootstrapError = await onConnected(credential) {
            isHandingOffCredential = false
            errorTitle = "Account bootstrap stopped"
            errorMessage = bootstrapError
        } else if showsCancel {
            dismiss()
        }
    }

    private func resetToCredentials() {
        authenticationTask?.cancel()
        challenge = nil
        selectedMFAMethod = nil
        mfaCode = ""
        errorTitle = nil
        errorMessage = nil
        focusedField = .password
    }

    private func startRemoteAuth() {
        remoteAuthTask?.cancel()
        remoteAuthState = .connecting
        automaticRemoteAuthRestarts = 0
        remoteAuthTask = Task {
            let events = await remoteAuthManager.events()
            await remoteAuthManager.connect()
            for await event in events {
                guard !Task.isCancelled else { return }
                switch event {
                case .connecting:
                    remoteAuthState = .connecting
                case let .qrCode(url):
                    remoteAuthState = .ready(url)
                case let .scanned(user):
                    remoteAuthState = .scanned(user)
                case let .pendingLogin(ticket):
                    remoteAuthState = .approving
                    do {
                        switch try await authenticator.exchangeRemoteAuthTicket(ticket) {
                        case let .encryptedToken(encryptedToken):
                            try await finishRemoteAuth(encryptedToken: encryptedToken)
                        case let .captcha(value):
                            presentCaptcha(value, purpose: .remoteAuth)
                        }
                        return
                    } catch is CancellationError {
                        return
                    } catch {
                        await remoteAuthManager.disconnect()
                        remoteAuthState = .failed(error.localizedDescription)
                    }
                case .cancelled:
                    if automaticRemoteAuthRestarts < 2 {
                        automaticRemoteAuthRestarts += 1
                        remoteAuthState = .connecting
                        await remoteAuthManager.restart()
                    } else {
                        await remoteAuthManager.disconnect()
                        remoteAuthState = .failed("Discord cancelled this sign-in session. Create a fresh code when you’re ready.")
                    }
                case let .failed(message):
                    remoteAuthState = .failed(message)
                }
            }
        }
    }

    private func restartRemoteAuth() {
        startRemoteAuth()
    }

    private func presentCaptcha(
        _ value: DiscordCaptchaChallenge,
        purpose: DiscordCaptchaPurpose
    ) {
        captchaPurpose = purpose
        // The hCaptcha SDK starts in invisible mode. Reveal its host only when
        // the SDK reports that real user interaction is required, avoiding a
        // blank panel while silent verification is loading or auto-completing.
        captchaInteractionVisible = false
        captchaChallenge = value
        if purpose == .remoteAuth {
            remoteAuthState = .approving
        }
    }

    private func finishRemoteAuth(encryptedToken: String) async throws {
        let token = try await remoteAuthManager.decryptToken(encryptedToken)
        let credential = try await authenticator.acceptRemoteAuthToken(token)
        await remoteAuthManager.disconnect()
        await finishConnection(credential)
    }
}

private struct DiscordLoginHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome home.")
                .font(.title.bold())
                .foregroundStyle(.primary)
            Text("Sign in to pick up where you left off.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct SakuraCordAuthenticationCard<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = SakuraCordThemeStore.shared.activeTheme.colors(for: colorScheme)
        VStack(spacing: 18) { content }
            .padding(36)
            .background(
                .regularMaterial,
                in: ConcentricRectangle(cornerRadius: 18, style: .continuous)
            )
            .background(
                LinearGradient(
                    colors: [colors.first.opacity(0.20), colors.second.opacity(0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: ConcentricRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                ConcentricRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [colors.first.opacity(0.34), .primary.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.42 : 0.18), radius: 30, y: 18)
    }
}

struct SakuraCordAuthenticationCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .frame(width: 32, height: 32)
                .background(.primary.opacity(0.07), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .keyboardShortcut(.cancelAction)
    }
}

struct SakuraCordAuthPrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let theme = SakuraCordThemeStore.shared.committedTheme
        let firstRGB = SakuraCordThemeRGB(
            hue: theme.first.hue,
            saturation: max(0.68, theme.first.saturation),
            brightness: colorScheme == .dark ? 0.78 : 0.60
        ).adjustedForContrast(with: .white, toward: .black)
        let secondRGB = SakuraCordThemeRGB(
            hue: theme.second.hue,
            saturation: max(0.64, theme.second.saturation),
            brightness: colorScheme == .dark ? 0.72 : 0.55
        ).adjustedForContrast(with: .white, toward: .black)
        let first = Color(red: firstRGB.red, green: firstRGB.green, blue: firstRGB.blue)
        let second = Color(red: secondRGB.red, green: secondRGB.green, blue: secondRGB.blue)
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Rectangle())
            .foregroundStyle(.white)
            .background(
                LinearGradient(
                    colors: [first, second],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: ConcentricRectangle(cornerRadius: 10, style: .continuous)
            )
            .shadow(
                color: first.opacity(0.28),
                radius: 12,
                y: 6
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

private struct DiscordCredentialForm: View {
    @Binding var identifier: String
    @Binding var password: String
    let isWorking: Bool
    let focusedField: FocusState<DiscordLoginField?>.Binding
    let submit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Email or phone")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("", text: $identifier)
                    .textContentType(.username)
                    .focused(focusedField, equals: .identifier)
                    .onSubmit { focusedField.wrappedValue = .password }
                    .sakuracordLoginField(
                        isEditorActive: focusedField.wrappedValue == .identifier,
                        onActivate: { focusedField.wrappedValue = .identifier }
                    )
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Password")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                SecureField("", text: $password)
                    .textContentType(.password)
                    .focused(focusedField, equals: .password)
                    .onSubmit(submit)
                    .sakuracordLoginField(
                        isEditorActive: focusedField.wrappedValue == .password,
                        onActivate: { focusedField.wrappedValue = .password }
                    )
            }
            Button(action: submit) {
                Text(isWorking ? "Signing in…" : "Sign in")
            }
            .buttonStyle(SakuraCordAuthPrimaryButtonStyle())
            .opacity(identifier.isEmpty || password.count < 8 || isWorking ? 0.45 : 1)
            .disabled(identifier.isEmpty || password.count < 8 || isWorking)
        }
        .disabled(isWorking)
    }
}

private extension View {
    func sakuracordLoginField(
        isEditorActive: Bool,
        onActivate: @escaping () -> Void
    ) -> some View {
        textFieldStyle(.plain)
            .font(.body)
            .foregroundStyle(.primary)
            .padding(.horizontal, 13)
            .frame(height: 44)
            .background(.background.opacity(0.72), in: ConcentricRectangle(cornerRadius: 10))
            .overlay {
                ConcentricRectangle(cornerRadius: 10)
                    .stroke(.primary.opacity(0.12), lineWidth: 1)
            }
            .background {
                LoginTextEditorStyleBridge(isActive: isEditorActive)
                    .allowsHitTesting(false)
            }
            .contentShape(ConcentricRectangle(cornerRadius: 10, style: .continuous))
            .simultaneousGesture(TapGesture().onEnded(onActivate))
            .tint(SakuraCordAccentColor.color)
    }
}

/// SwiftUI's SecureField does not consistently forward `tint` to the
/// shared AppKit field editor. This bridge only styles that editor while
/// its associated login field is active; SwiftUI remains the text owner.
private struct LoginTextEditorStyleBridge: NSViewRepresentable {
    let isActive: Bool

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard isActive else { return }
        Task { @MainActor [weak nsView] in
            await Task.yield()
            guard let editor = nsView?.window?.firstResponder as? NSTextView else { return }
            editor.insertionPointColor = .sakuraCordAccentColor
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor.sakuraCordTextSelectionBackgroundColor,
                .foregroundColor: NSColor.selectedTextColor,
            ]
        }
    }
}

private enum DiscordRemoteAuthPresentationState {
    case disabled
    case connecting
    case ready(URL)
    case scanned(DiscordRemoteAuthUser?)
    case approving
    case challenge
    case failed(String)
}

private struct DiscordRemoteAuthPanel: View {
    let state: DiscordRemoteAuthPresentationState
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 15) {
            switch state {
            case .disabled:
                remoteAuthSymbol {
                    Image(systemName: "network.slash")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(SakuraCordAccentColor.color)
                }
                title("Sign-in paused")
                detail("Discord networking is disabled for this launch.")

            case .connecting:
                remoteAuthSymbol {
                    ProgressView()
                        .controlSize(.large)
                        .tint(SakuraCordAccentColor.color)
                }
                title("Creating your code")
                detail("Opening a private sign-in session…")

            case let .ready(url):
                DiscordQRCodeView(url: url)
                    .frame(width: 174, height: 174)
                    .clipShape(ConcentricRectangle(cornerRadius: 12, style: .continuous))
                    .padding(6)
                    .background(
                        Color(hex: 0xFFF7FA),
                        in: ConcentricRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .overlay {
                        ConcentricRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(SakuraCordAccentColor.color.opacity(0.32), lineWidth: 1)
                    }
                    .shadow(color: SakuraCordAccentColor.color.opacity(0.18), radius: 18, y: 8)
                title("Scan to sign in")
                detail("Open Discord on your phone and scan this code.")

            case let .scanned(user):
                remoteAuthSymbol {
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(SakuraCordAccentColor.color)
                }
                title(user.map { "Hi, \($0.username)" } ?? "Code scanned")
                detail("Approve the sign-in on your phone to finish.")

            case .approving:
                remoteAuthSymbol {
                    ProgressView()
                        .controlSize(.large)
                        .tint(SakuraCordAccentColor.color)
                }
                title("Opening SakuraCord")
                detail("Your phone approved the sign-in.")

            case .challenge:
                remoteAuthSymbol {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(SakuraCordAccentColor.color)
                }
                title("One more check")
                detail("Complete Discord’s verification to finish signing in.")

            case let .failed(message):
                remoteAuthSymbol {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(SakuraCordAccentColor.color)
                }
                title("That code expired")
                detail(message)
                Button("Create a new code", action: retry)
                    .buttonStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(SakuraCordAccentColor.color)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func title(_ value: String) -> some View {
        Text(value)
            .font(.title3.bold())
            .foregroundStyle(.primary)
    }

    private func detail(_ value: String) -> some View {
        Text(value)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func remoteAuthSymbol(@ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(width: 174, height: 174)
            .background(.background.opacity(0.66), in: ConcentricRectangle(cornerRadius: 18))
            .overlay {
                ConcentricRectangle(cornerRadius: 18)
                    .stroke(SakuraCordAccentColor.color.opacity(0.18), lineWidth: 1)
            }
    }
}

private struct DiscordQRCodeView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                ProgressView()
                    .tint(SakuraCordAccentColor.color)
            }
        }
        .task(id: url) {
            image = DiscordQRCodeRenderer.render(url: url)
        }
        .accessibilityLabel("Discord QR sign-in code")
    }
}

enum DiscordQRCodeRenderer {
    private static let moduleScale = 10
    private static let quietZone = 4

    static func render(url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        // Match Paicord's remote-auth QR density. There is no center overlay,
        // so the additional density of H-level recovery is unnecessary.
        filter.correctionLevel = "L"
        guard let output = filter.outputImage else { return nil }

        let moduleCount = Int(output.extent.width)
        guard moduleCount > 0, Int(output.extent.height) == moduleCount else { return nil }
        let modules = moduleBitmap(output: output, count: moduleCount)
        guard !modules.isEmpty else { return nil }

        let canvasModules = moduleCount + quietZone * 2
        let pixelSize = canvasModules * moduleScale
        guard let context = CGContext(
            data: nil,
            width: pixelSize,
            height: pixelSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let plum = NSColor(calibratedRed: 0.22, green: 0.055, blue: 0.15, alpha: 1).cgColor
        context.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        context.setFillColor(plum)

        let finderOrigins = detectedFinderOrigins(in: modules, count: moduleCount)
        func isDisplayedDataModule(x column: Int, y row: Int) -> Bool {
            guard (0 ..< moduleCount).contains(column), (0 ..< moduleCount).contains(row) else { return false }
            let sourceRow = moduleCount - 1 - row
            guard isDark(modules, count: moduleCount, x: column, y: sourceRow) else { return false }
            return !finderOrigins.contains(where: { finderContains($0, x: column, y: sourceRow) })
        }
        for row in 0 ..< moduleCount {
            for column in 0 ..< moduleCount where isDisplayedDataModule(x: column, y: row) {
                drawDataModule(
                    context: context,
                    x: column,
                    y: row,
                    connectsLeft: isDisplayedDataModule(x: column - 1, y: row),
                    connectsRight: isDisplayedDataModule(x: column + 1, y: row),
                    connectsAbove: isDisplayedDataModule(x: column, y: row + 1),
                    connectsBelow: isDisplayedDataModule(x: column, y: row - 1)
                )
            }
        }
        for origin in finderOrigins {
            drawFinder(
                context: context,
                origin: CGPoint(x: origin.x, y: CGFloat(moduleCount - 7) - origin.y),
                plum: plum
            )
        }

        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: pixelSize, height: pixelSize)
        )
    }

    private static func moduleBitmap(output: CIImage, count: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: count * count * 4)
        CIContext(options: [.useSoftwareRenderer: false]).render(
            output,
            toBitmap: &pixels,
            rowBytes: count * 4,
            bounds: output.extent,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return pixels
    }

    private static func isDark(_ modules: [UInt8], count: Int, x column: Int, y row: Int) -> Bool {
        modules[(row * count + column) * 4] < 128
    }

    private static func detectedFinderOrigins(in modules: [UInt8], count: Int) -> [CGPoint] {
        let last = count - 7
        return [CGPoint(x: 0, y: 0), CGPoint(x: last, y: 0), CGPoint(x: 0, y: last), CGPoint(x: last, y: last)]
            .filter { matchesFinder(in: modules, count: count, origin: $0) }
    }

    private static func matchesFinder(in modules: [UInt8], count: Int, origin: CGPoint) -> Bool {
        let originX = Int(origin.x)
        let originY = Int(origin.y)
        for row in 0 ..< 7 {
            for column in 0 ..< 7 {
                let expectedDark = column == 0 || column == 6 || row == 0 || row == 6
                    || ((2 ... 4).contains(column) && (2 ... 4).contains(row))
                if isDark(modules, count: count, x: originX + column, y: originY + row) != expectedDark {
                    return false
                }
            }
        }
        return true
    }

    private static func finderContains(_ origin: CGPoint, x column: Int, y row: Int) -> Bool {
        let originX = Int(origin.x)
        let originY = Int(origin.y)
        return (originX ..< (originX + 7)).contains(column) && (originY ..< (originY + 7)).contains(row)
    }

    private static func drawDataModule(
        context: CGContext,
        x column: Int,
        y row: Int,
        connectsLeft: Bool,
        connectsRight: Bool,
        connectsAbove: Bool,
        connectsBelow: Bool
    ) {
        let unit = CGFloat(moduleScale)
        let rect = CGRect(
            x: CGFloat(column + quietZone) * unit,
            y: CGFloat(row + quietZone) * unit,
            width: unit,
            height: unit
        )
        let radius = unit * 0.34
        context.addPath(variableRoundedRect(
            rect,
            bottomLeft: !connectsLeft && !connectsBelow ? radius : 0,
            bottomRight: !connectsRight && !connectsBelow ? radius : 0,
            topRight: !connectsRight && !connectsAbove ? radius : 0,
            topLeft: !connectsLeft && !connectsAbove ? radius : 0
        ))
        context.fillPath()
    }

    private static func variableRoundedRect(
        _ rect: CGRect,
        bottomLeft: CGFloat,
        bottomRight: CGFloat,
        topRight: CGFloat,
        topLeft: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + bottomLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - bottomRight, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + bottomRight),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - topRight))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topRight, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topLeft, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - topLeft),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + bottomLeft))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + bottomLeft, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }

    private static func drawFinder(
        context: CGContext,
        origin: CGPoint,
        plum: CGColor
    ) {
        let unit = CGFloat(moduleScale)
        let horizontalPosition = (origin.x + CGFloat(quietZone)) * unit
        let verticalPosition = (origin.y + CGFloat(quietZone)) * unit

        context.setFillColor(plum)
        context.addPath(CGPath(
            roundedRect: CGRect(x: horizontalPosition, y: verticalPosition, width: 7 * unit, height: 7 * unit),
            cornerWidth: 1.45 * unit,
            cornerHeight: 1.45 * unit,
            transform: nil
        ))
        context.fillPath()

        context.saveGState()
        context.setBlendMode(.clear)
        context.addPath(CGPath(
            roundedRect: CGRect(
                x: horizontalPosition + unit,
                y: verticalPosition + unit,
                width: 5 * unit,
                height: 5 * unit
            ),
            cornerWidth: unit,
            cornerHeight: unit,
            transform: nil
        ))
        context.fillPath()
        context.restoreGState()

        context.setFillColor(plum)
        context.addPath(CGPath(
            roundedRect: CGRect(
                x: horizontalPosition + 2 * unit,
                y: verticalPosition + 2 * unit,
                width: 3 * unit,
                height: 3 * unit
            ),
            cornerWidth: 0.7 * unit,
            cornerHeight: 0.7 * unit,
            transform: nil
        ))
        context.fillPath()
    }
}

private struct DiscordMFAForm: View {
    let challenge: DiscordMFAChallenge
    @Binding var selectedMethod: DiscordMFAMethod?
    @Binding var code: String
    let isWorking: Bool
    let smsCooldownEndsAt: Date?
    let focusedField: FocusState<DiscordLoginField?>.Binding
    let submit: () -> Void
    let sendSMS: () -> Void
    let goBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button("Back", systemImage: "chevron.left", action: goBack)
                .buttonStyle(.plain)
            Text("Multi-Factor Authentication")
                .font(.title2.bold())
            Text("Choose a method Discord offered for this login, then enter its code.")
                .foregroundStyle(.secondary)

            Picker("Method", selection: $selectedMethod) {
                ForEach(challenge.methods, id: \.self) { method in
                    Label(method.title, systemImage: method.systemImage).tag(Optional(method))
                }
            }
            .pickerStyle(.segmented)

            TextField(selectedMethod == .backup ? "Backup code" : "6-digit code", text: $code)
                .textFieldStyle(.roundedBorder)
                .focused(focusedField, equals: .mfa)
                .onSubmit(submit)

            if selectedMethod == .sms {
                Button("Send SMS Code", action: sendSMS)
                    .disabled(isWorking || (smsCooldownEndsAt.map { $0 > .now } ?? false))
            }

            Button(action: submit) {
                Text(isWorking ? "Verifying…" : "Verify and Sign In")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(code.isEmpty || isWorking || selectedMethod == nil)
        }
        .disabled(isWorking)
    }
}

private extension DiscordMFAMethod {
    var title: String {
        switch self {
        case .totp: "Authenticator"
        case .backup: "Backup Code"
        case .sms: "SMS"
        }
    }

    var systemImage: String {
        switch self {
        case .totp: "lock.rotation"
        case .backup: "key.fill"
        case .sms: "message.fill"
        }
    }
}

private struct DiscordLoginStatus: View {
    let title: String?
    let message: String?

    var body: some View {
        if let title, let message {
            VStack(alignment: .leading, spacing: 7) {
                Label(title, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                Text(message)
                    .foregroundStyle(Color(hex: 0xF23F42))
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
