import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import DiscordProtocol
import SwiftUI

private enum DiscordCaptchaPurpose: Equatable {
    case credentials
    case remoteAuth
}

private enum DiscordOnboardingStep: Hashable {
    case welcome
    case theme
}

struct DiscordLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let showsCancel: Bool
    let networkingEnabled: Bool
    let savedAccountIDs: Set<String>
    let onEntranceStarted: @MainActor () -> Void
    let onOnboardingCompleted: @MainActor () -> Void
    let onConnected: @MainActor (PendingDiscordCredential) async -> String?

    @State private var authenticator: any DiscordSignInAuthenticating
    @State private var remoteAuthManager: any DiscordSignInRemoteAuthenticating
    @State private var offlineService: OfflineSignInService?
    @State private var identifier = ""
    @State private var password = ""
    @State private var mfaCode = ""
    @State private var challenge: DiscordMFAChallenge?
    @State private var captchaChallenge: DiscordCaptchaChallenge?
    @State private var captchaPurpose: DiscordCaptchaPurpose?
    @State private var captchaInteractionVisible = false
    @State private var selectedMFAMethod: DiscordMFAMethod?
    @State private var isWorking = false
    @State private var isSendingSMS = false
    @State private var errorTitle: String?
    @State private var errorMessage: String?
    @State private var authenticationTask: Task<Void, Never>?
    @State private var remoteAuthTask: Task<Void, Never>?
    @State private var remoteAuthState: DiscordRemoteAuthPresentationState = .connecting
    @State private var automaticRemoteAuthRestarts = 0
    @State private var isHandingOffCredential = false
    @State private var accountImportState: DiscordAccountImportState?
    @State private var importingAccountID: String?
    @State private var smsCooldownEndsAt: Date?
    @State private var welcomeProgress = 0.0
    @State private var onboardingStep: DiscordOnboardingStep?
    @State private var showsContinue = false
    @State private var playsWelcome: Bool
    @State private var formVisible = false
    @State private var panelVisible = true
    @State private var isTransitioning = false
    @State private var entranceRevision = 0
    @FocusState private var focusedField: DiscordLoginField?

    init(
        showsCancel: Bool,
        networkingEnabled: Bool,
        offlineSignIn: Bool = false,
        savedAccountIDs: Set<String> = [],
        playsWelcome: Bool = false,
        showsOnboarding: Bool = false,
        onEntranceStarted: @escaping @MainActor () -> Void = {},
        onOnboardingCompleted: @escaping @MainActor () -> Void = {},
        onConnected: @escaping @MainActor (PendingDiscordCredential) async -> String?
    ) {
        self.showsCancel = showsCancel
        self.networkingEnabled = networkingEnabled
        self.savedAccountIDs = savedAccountIDs
        self.onEntranceStarted = onEntranceStarted
        self.onOnboardingCompleted = onOnboardingCompleted
        _onboardingStep = State(initialValue: showsOnboarding ? .welcome : nil)
        // Retain this entrance's decision after its launch permission is consumed.
        _playsWelcome = State(initialValue: playsWelcome)
        self.onConnected = onConnected
        let offlineService = offlineSignIn ? OfflineSignInService() : nil
        _offlineService = State(initialValue: offlineService)
        _authenticator = State(initialValue: offlineService.map { $0 as any DiscordSignInAuthenticating }
            ?? DiscordSessionAuthenticator())
        _remoteAuthManager = State(initialValue: offlineService.map { $0 as any DiscordSignInRemoteAuthenticating }
            ?? DiscordRemoteAuthManager())
    }

    var body: some View {
        ZStack {
            SakuraCordSignInBackdrop()
                .ignoresSafeArea()

            if onboardingStep == nil, !formVisible, playsWelcome, !reduceMotion {
                SakuraCordWelcomeSequence(progress: welcomeProgress)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: InterfaceScale.metric(22)) {
                        Group {
                            if onboardingStep == .welcome {
                                Color.clear
                                    .frame(height: SakuraCordWelcomePetalAtlas.displayHeight(for: geometry.size.width))
                                    .overlay {
                                        SakuraCordWelcomeSequence(progress: welcomeProgress)
                                            .frame(width: geometry.size.width, height: geometry.size.height)
                                    }
                                    .allowsHitTesting(false)
                            } else {
                                authenticationCard
                            }
                        }
                        // Change content while hidden, then use the same reveal
                        // as the login, MFA, and account-import stages.
                        .transaction {
                            if onboardingStep != .welcome { $0.animation = nil }
                        }
                        .modifier(SakuraCordSignInReveal(isVisible: panelVisible, reduceMotion: reduceMotion))
                        .accessibilityHidden(!panelVisible)

                        if onboardingStep != nil {
                            GlassEffectContainer {
                                if showsContinue {
                                    SakuraCordOnboardingContinueButton(action: advanceOnboarding)
                                        .id(onboardingStep)
                                }
                            }
                            .frame(height: InterfaceScale.metric(44))
                            .disabled(isTransitioning)
                        }

                        if onboardingStep == nil, challenge == nil, accountImportState == nil,
                           networkingEnabled, offlineService == nil {
                            Button("Import account from Discord", systemImage: "square.and.arrow.down") {
                                beginAccountImport()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .disabled(isWorking)
                            .modifier(SakuraCordSignInReveal(isVisible: panelVisible, reduceMotion: reduceMotion))
                        }
                    }
                    .padding(.horizontal, InterfaceScale.metric(34))
                    .padding(.vertical, InterfaceScale.metric(42))
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    .modifier(SakuraCordSignInReveal(isVisible: formVisible, reduceMotion: reduceMotion))
                    .allowsHitTesting(formVisible && !isTransitioning)
                    .accessibilityHidden(!formVisible)
                }
                .scrollIndicators(.hidden)
            }

            if let offlineService, formVisible, onboardingStep == nil {
                OfflineSignInControls(
                    service: offlineService,
                    canScan: remoteAuthState.isReady && !isWorking && challenge == nil,
                    canSimulateMFA: challenge == nil,
                    simulateMFA: { presentMFA(OfflineSignInService.mfaChallenge()) },
                    replay: replayEntrance
                )
                .disabled(isWorking || isTransitioning)
                .padding(.bottom, InterfaceScale.metric(12))
                .frame(maxHeight: .infinity, alignment: .bottom)
            }

            windowDragRegion

            if showsCancel, challenge == nil, accountImportState == nil {
                SakuraCordAuthenticationCloseButton { dismiss() }
                .padding(InterfaceScale.metric(20))
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
        .frame(minWidth: InterfaceScale.metric(860), minHeight: InterfaceScale.metric(600))
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .task(id: onboardingStep == nil) {
            guard onboardingStep == nil else {
                remoteAuthTask?.cancel()
                await remoteAuthManager.disconnect()
                return
            }
            if networkingEnabled || offlineService != nil {
                startRemoteAuth()
            } else {
                remoteAuthState = .disabled
            }
        }
        .task(id: entranceRevision) { await revealEntrance() }
        .onChange(of: selectedMFAMethod) { _, method in
            if method == .sms { sendSMS() }
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

    private var authenticationCard: some View {
        SakuraCordAuthenticationCard {
            if onboardingStep == .theme {
                GradientThemeEditor(themeStore: .shared, presentation: .onboarding)
            } else if let accountImportState {
                DiscordAccountImportView(
                    state: accountImportState,
                    savedAccountIDs: savedAccountIDs,
                    importingAccountID: importingAccountID,
                    errorMessage: errorMessage,
                    isTransitioning: isTransitioning,
                    goBack: goBackFromImport,
                    retry: loadImportAccounts,
                    selectAccount: importAccount
                )
            } else if let challenge {
                DiscordMFAForm(
                    challenge: challenge,
                    selectedMethod: selectedMFAMethod,
                    code: $mfaCode,
                    isWorking: isWorking,
                    isTransitioning: isTransitioning,
                    isSendingSMS: isSendingSMS,
                    smsCooldownEndsAt: smsCooldownEndsAt,
                    focusedField: $focusedField,
                    errorMessage: errorMessage,
                    selectMethod: selectMFAMethod,
                    submit: submitMFA,
                    sendSMS: sendSMS,
                    goBack: goBackFromMFA
                )
            } else {
                HStack(alignment: .center, spacing: InterfaceScale.metric(32)) {
                    VStack(alignment: .leading, spacing: InterfaceScale.metric(22)) {
                        DiscordLoginHeader()
                        DiscordCredentialForm(
                            identifier: $identifier,
                            password: $password,
                            isWorking: isWorking,
                            canSubmit: canSubmitCredentials,
                            focusedField: $focusedField,
                            submit: submitCredentials
                        )
                        DiscordLoginStatus(
                            title: errorTitle,
                            message: errorMessage
                        )
                    }
                    .frame(width: InterfaceScale.metric(390), alignment: .leading)

                    Rectangle()
                        .fill(Color(nsColor: .separatorColor).opacity(0.72))
                        .frame(width: 1, height: InterfaceScale.metric(300))

                    DiscordRemoteAuthPanel(
                        state: remoteAuthState,
                        retry: restartRemoteAuth
                    )
                    .frame(width: InterfaceScale.metric(236))
                }
            }
        }
        .frame(maxWidth: accountImportState != nil ? 620 : challenge == nil ? 800 : 480)
    }

    private func beginAccountImport() {
        guard !isWorking, !isTransitioning, networkingEnabled else { return }
        remoteAuthTask?.cancel()
        transitionAuthentication {
            errorTitle = nil
            errorMessage = nil
            loadImportAccounts()
        }
    }

    private func loadImportAccounts() {
        authenticationTask?.cancel()
        accountImportState = .loading
        errorMessage = nil
        authenticationTask = Task {
            await remoteAuthManager.disconnect()
            do {
                let accounts = try await DiscordAccountImporter.accounts(excluding: savedAccountIDs)
                try Task.checkCancellation()
                accountImportState = .accounts(accounts)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                accountImportState = .failed(error.localizedDescription)
            }
        }
    }

    private func goBackFromImport() {
        guard !isWorking, !isTransitioning else { return }
        authenticationTask?.cancel()
        transitionAuthentication {
            accountImportState = nil
            errorTitle = nil
            errorMessage = nil
            startRemoteAuth()
        }
    }

    private func importAccount(_ account: DiscordImportAccount) {
        guard !isWorking, !isTransitioning, !savedAccountIDs.contains(account.id) else { return }
        isWorking = true
        importingAccountID = account.id
        errorMessage = nil
        authenticationTask?.cancel()
        authenticationTask = Task {
            defer {
                isWorking = false
                importingAccountID = nil
            }
            do {
                let credential = try await DiscordAccountImporter.credential(for: account)
                guard !Task.isCancelled else {
                    await credential.discard()
                    return
                }
                await finishConnection(credential)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func revealEntrance() async {
        guard !formVisible else { return }
        onEntranceStarted()
        if onboardingStep == .welcome {
            formVisible = true
            if reduceMotion {
                welcomeProgress = 1
                showsContinue = true
                return
            }
            withAnimation(.linear(duration: 4.6)) { welcomeProgress = 1 }
            do {
                try await Task.sleep(for: .milliseconds(4900))
                withAnimation(.themeControlResponse) { showsContinue = true }
            } catch {}
            return
        }
        if reduceMotion {
            formVisible = true
            focusedField = .identifier
            return
        }
        do {
            if !playsWelcome {
                withAnimation(.smooth(duration: 0.65)) { formVisible = true }
                try await Task.sleep(for: .milliseconds(650))
                focusedField = .identifier
                return
            }
            withAnimation(.linear(duration: 4.6)) { welcomeProgress = 1 }
            try await Task.sleep(for: .milliseconds(4900))
            withAnimation(SakuraCordSignInReveal.animation(reduceMotion: reduceMotion)) { formVisible = true }
            try await Task.sleep(for: .milliseconds(900))
            focusedField = .identifier
        } catch {}
    }

    private func replayEntrance() {
        authenticationTask?.cancel()
        identifier = ""
        password = ""
        challenge = nil
        selectedMFAMethod = nil
        mfaCode = ""
        smsCooldownEndsAt = nil
        errorTitle = nil
        errorMessage = nil
        onboardingStep = .welcome
        showsContinue = false
        playsWelcome = true
        welcomeProgress = 0
        formVisible = false
        panelVisible = true
        focusedField = nil
        entranceRevision += 1
    }

    private func advanceOnboarding() {
        guard let onboardingStep, !isTransitioning else { return }
        transitionAuthentication {
            switch onboardingStep {
            case .welcome:
                self.onboardingStep = .theme
            case .theme:
                SakuraCordThemeStore.shared.finishInteraction()
                onOnboardingCompleted()
                self.onboardingStep = nil
            }
        }
    }

    private var windowDragRegion: some View {
        VStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .frame(height: InterfaceScale.metric(52))
                .gesture(WindowDragGesture())
                .allowsWindowActivationEvents(true)
            Spacer(minLength: 0)
        }
    }

    private var canSubmitCredentials: Bool {
        !isWorking && !isTransitioning
            && !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (8 ... 72).contains(password.count)
    }

    private var canSubmitMFA: Bool {
        guard !isWorking, !isTransitioning, let selectedMFAMethod, let challenge,
              challenge.methods.contains(selectedMFAMethod) else { return false }
        return !mfaCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedMFAMethod.normalizedCode(mfaCode).count == selectedMFAMethod.codeLength
    }

    private func submitCredentials() {
        guard canSubmitCredentials else { return }
        guard networkingEnabled || offlineService != nil else {
            errorTitle = "Sign-in unavailable"
            errorMessage = "Discord networking is disabled for this launch."
            return
        }
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
                try Task.checkCancellation()
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
            presentMFA(value)
        case let .captcha(value):
            presentCaptcha(value, purpose: .credentials)
        }
    }

    private func presentMFA(_ value: DiscordMFAChallenge) {
        transitionAuthentication {
            challenge = value
            selectedMFAMethod = nil
            mfaCode = ""
            smsCooldownEndsAt = nil
            errorTitle = nil
            errorMessage = nil
        }
    }

    private func selectMFAMethod(_ method: DiscordMFAMethod?) {
        guard !isWorking, !isTransitioning else { return }
        if let method, challenge?.methods.contains(method) != true { return }
        transitionAuthentication {
            selectedMFAMethod = method
            mfaCode = ""
            errorTitle = nil
            errorMessage = nil
        }
    }

    private func goBackFromMFA() {
        if selectedMFAMethod == nil {
            resetToCredentials()
        } else {
            selectMFAMethod(nil)
        }
    }

    private func transitionAuthentication(_ update: @escaping () -> Void) {
        guard !isTransitioning else { return }
        let hidesOnboardingButton = onboardingStep != nil
        isTransitioning = true
        focusedField = nil
        withAnimation(
            .easeOut(duration: reduceMotion ? 0.12 : 0.18),
            completionCriteria: hidesOnboardingButton ? .removed : .logicallyComplete
        ) {
            panelVisible = false
            if hidesOnboardingButton { showsContinue = false }
        } completion: {
            // Finish the outgoing glass removal before replacing its container.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                update()
                isTransitioning = false
                if onboardingStep != nil || accountImportState != nil {
                    focusedField = nil
                } else if challenge == nil {
                    focusedField = identifier.isEmpty ? .identifier : .password
                } else {
                    focusedField = selectedMFAMethod == nil ? nil : .mfa
                }
            }
            withAnimation(SakuraCordSignInReveal.animation(reduceMotion: reduceMotion)) {
                panelVisible = true
                if onboardingStep == .theme { showsContinue = true }
            }
        }
    }

    private func submitMFA() {
        guard canSubmitMFA, let challenge, let selectedMFAMethod else { return }
        let submittedCode = mfaCode
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
                mfaCode = ""
                focusedField = .mfa
            }
        }
    }

    private func sendSMS() {
        guard let challenge, selectedMFAMethod == .sms, challenge.methods.contains(.sms), !isWorking,
              smsCooldownEndsAt.map({ $0 <= .now }) ?? true else { return }
        errorTitle = nil
        errorMessage = nil
        isWorking = true
        isSendingSMS = true
        authenticationTask?.cancel()
        authenticationTask = Task {
            defer {
                isWorking = false
                isSendingSMS = false
            }
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
        guard !isWorking, !isTransitioning else { return }
        authenticationTask?.cancel()
        transitionAuthentication {
            challenge = nil
            selectedMFAMethod = nil
            mfaCode = ""
            smsCooldownEndsAt = nil
            errorTitle = nil
            errorMessage = nil
        }
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
                    automaticRemoteAuthRestarts = 0
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
                    if remoteAuthState.isReady {
                        // A displayed QR session can expire while the form is
                        // open. Replace it automatically; a failed reconnect
                        // still surfaces an error instead of retrying forever.
                        remoteAuthState = .connecting
                        await remoteAuthManager.restart()
                    } else {
                        remoteAuthState = .failed(message)
                    }
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
        VStack(alignment: .leading, spacing: InterfaceScale.metric(6)) {
            Text("Welcome home.")
                .font(.interface(.title).bold())
                .foregroundStyle(.primary)
            Text("Sign in to pick up where you left off.")
                .font(.interface(.callout))
                .foregroundStyle(.secondary)
        }
    }
}

private struct DiscordCredentialForm: View {
    @Binding var identifier: String
    @Binding var password: String
    let isWorking: Bool
    let canSubmit: Bool
    let focusedField: FocusState<DiscordLoginField?>.Binding
    let submit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(16)) {
            VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
                Text("Email or phone")
                    .font(.interface(.caption).weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("", text: $identifier)
                    .accessibilityLabel("Email or phone")
                    .textContentType(.username)
                    .focused(focusedField, equals: .identifier)
                    .onSubmit { focusedField.wrappedValue = .password }
                    .sakuracordLoginField(
                        isEditorActive: focusedField.wrappedValue == .identifier,
                        onActivate: { focusedField.wrappedValue = .identifier },
                        onDismiss: { focusedField.wrappedValue = nil }
                    )
            }
            VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
                Text("Password")
                    .font(.interface(.caption).weight(.semibold))
                    .foregroundStyle(.secondary)
                SecureField("", text: $password)
                    .accessibilityLabel("Password")
                    .textContentType(.password)
                    .focused(focusedField, equals: .password)
                    .onSubmit(submit)
                    .sakuracordLoginField(
                        isEditorActive: focusedField.wrappedValue == .password,
                        onActivate: { focusedField.wrappedValue = .password },
                        onDismiss: { focusedField.wrappedValue = nil }
                    )
            }
            Button(action: submit) {
                Text(isWorking ? "Signing in…" : "Sign in")
                .font(.interface(.body).weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(34))
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(!canSubmit)
            .authenticationLoading(isWorking, in: Capsule(), intensity: 1.8)
        }
        .disabled(isWorking)
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

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

private struct DiscordRemoteAuthPanel: View {
    let state: DiscordRemoteAuthPresentationState
    let retry: () -> Void

    var body: some View {
        VStack(spacing: InterfaceScale.metric(15)) {
            switch state {
            case .disabled:
                remoteAuthSymbol {
                    Image(systemName: "network.slash")
                        .font(.interfaceSystem(size: 36, weight: .medium))
                        .foregroundStyle(SakuraCordAccentColor.color)
                }
                title("Sign-in paused")
                detail("Discord networking is disabled for this launch.")

            case .connecting:
                remoteAuthSymbol { Color.clear }
                    .authenticationLoading(true, in: RoundedRectangle(cornerRadius: SakuraCordAuthenticationMetrics.controlRadius, style: .continuous), intensity: 1.8)
                title("Creating your code")
                detail("Opening a private sign-in session…")

            case let .ready(url):
                DiscordQRCodeView(url: url)
                    .frame(width: SakuraCordAuthenticationMetrics.qrSize, height: SakuraCordAuthenticationMetrics.qrSize)
                    .clipShape(RoundedRectangle(cornerRadius: SakuraCordAuthenticationMetrics.controlRadius, style: .continuous))
                    .background(
                        Color.white,
                        in: RoundedRectangle(cornerRadius: SakuraCordAuthenticationMetrics.controlRadius, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: SakuraCordAuthenticationMetrics.controlRadius, style: .continuous)
                            .stroke(SakuraCordAccentColor.color.opacity(0.32), lineWidth: 1)
                    }
                    .shadow(color: SakuraCordAccentColor.color.opacity(0.18), radius: InterfaceScale.metric(18), y: 8)
                title("Scan to sign in")
                detail("Open Discord on your phone and scan this code.")

            case let .scanned(user):
                remoteAuthSymbol {
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                        .font(.interfaceSystem(size: 38, weight: .medium))
                        .foregroundStyle(SakuraCordAccentColor.color)
                }
                title(user.map { "Hi, \($0.username)" } ?? "Code scanned")
                detail("Approve the sign-in on your phone to finish.")

            case .approving:
                remoteAuthSymbol { Color.clear }
                    .authenticationLoading(true, in: RoundedRectangle(cornerRadius: SakuraCordAuthenticationMetrics.controlRadius, style: .continuous), intensity: 1.8)
                title("Opening SakuraCord")
                detail("Your phone approved the sign-in.")

            case .challenge:
                remoteAuthSymbol {
                    Image(systemName: "checkmark.shield")
                        .font(.interfaceSystem(size: 38, weight: .medium))
                        .foregroundStyle(SakuraCordAccentColor.color)
                }
                title("One more check")
                detail("Complete Discord’s verification to finish signing in.")

            case let .failed(message):
                remoteAuthSymbol {
                    Image(systemName: "arrow.clockwise")
                        .font(.interfaceSystem(size: 34, weight: .semibold))
                        .foregroundStyle(SakuraCordAccentColor.color)
                }
                title("QR sign-in unavailable")
                detail(message)
                Button("Create a new code", action: retry)
                    .buttonStyle(.plain)
                    .font(.interface(.callout).weight(.semibold))
                    .foregroundStyle(SakuraCordAccentColor.color)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func title(_ value: String) -> some View {
        Text(value)
            .font(.interface(.title3).bold())
            .foregroundStyle(.primary)
    }

    private func detail(_ value: String) -> some View {
        Text(value)
            .font(.interface(.callout))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func remoteAuthSymbol(@ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(width: SakuraCordAuthenticationMetrics.qrSize, height: SakuraCordAuthenticationMetrics.qrSize)
            .background(.background.opacity(0.66), in: RoundedRectangle(cornerRadius: SakuraCordAuthenticationMetrics.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SakuraCordAuthenticationMetrics.controlRadius, style: .continuous)
                    .stroke(SakuraCordAccentColor.color.opacity(0.18), lineWidth: 1)
            }
    }
}

private struct DiscordQRCodeView: View {
    let url: URL
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .foregroundStyle(LinearGradient(
                        colors: DiscordQRCodeRenderer.inkColors(
                            theme: SakuraCordThemeStore.shared.activeTheme,
                            colorScheme: colorScheme
                        ),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
            } else {
                Color.clear
                    .authenticationLoading(true, in: RoundedRectangle(cornerRadius: SakuraCordAuthenticationMetrics.controlRadius, style: .continuous), intensity: 1.8)
            }
        }
        .task(id: url) {
            let rendered = await DiscordQRCodeRenderer.render(url: url)
            guard !Task.isCancelled, let rendered else { return }
            image = NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
        }
        .accessibilityLabel("Discord QR sign-in code")
    }
}

nonisolated enum DiscordQRCodeRenderer {
    @MainActor
    static func inkColors(theme: SakuraCordGradientTheme, colorScheme: ColorScheme) -> [Color] {
        // Start with the backdrop's rendered palette, soften it with neutral ink,
        // then keep every gradient stop dark enough for the white scan surface.
        var palette = theme
        palette.brightness = 1
        return palette.activeColors.map { color in
            let rgb = palette.renderedRGB(color, for: colorScheme == .dark ? .dark : .light)
            .blended(toward: SakuraCordThemeRGB(red: 0.36, green: 0.36, blue: 0.36), fraction: 0.35)
            .adjustedForContrast(with: .white, toward: .black, requiredRatio: 7)
            return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        }
    }

    private static let moduleScale = 10
    private static let quietZone = 4

    // Core Image initialization and module drawing must not block the welcome
    // animation while the remote-auth session supplies its first QR code.
    @concurrent
    static func render(url: URL) async -> CGImage? {
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

        let ink = CGColor(gray: 0, alpha: 1)
        context.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        context.setFillColor(ink)

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
                ink: ink
            )
        }

        return context.makeImage()
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
        ink: CGColor
    ) {
        let unit = CGFloat(moduleScale)
        let horizontalPosition = (origin.x + CGFloat(quietZone)) * unit
        let verticalPosition = (origin.y + CGFloat(quietZone)) * unit

        context.setFillColor(ink)
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

        context.setFillColor(ink)
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

private struct DiscordLoginStatus: View {
    let title: String?
    let message: String?

    var body: some View {
        if let title, let message {
            VStack(alignment: .leading, spacing: InterfaceScale.metric(7)) {
                Label(title, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                Text(message)
                    .foregroundStyle(Color(hex: 0xF23F42))
            }
            .font(.interface(.caption))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
