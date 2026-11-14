import DiscordProtocol
import Foundation
import SakuraCordModels

nonisolated protocol DiscordSignInAuthenticating: Sendable {
    func login(identifier: String, password: String) async throws -> DiscordNativeAuthenticationStep
    func completeMFA(challenge: DiscordMFAChallenge, method: DiscordMFAMethod, code: String) async throws -> PendingDiscordCredential
    func sendSMS(for challenge: DiscordMFAChallenge) async throws
    func completeCaptcha(challenge: DiscordCaptchaChallenge, solutionToken: String) async throws -> DiscordNativeAuthenticationStep
    func cancelCaptcha(challengeID: UUID) async
    func exchangeRemoteAuthTicket(_ ticket: String) async throws -> DiscordRemoteAuthTicketExchangeStep
    func completeRemoteAuthCaptcha(challenge: DiscordCaptchaChallenge, solutionToken: String) async throws -> String
    func acceptRemoteAuthToken(_ token: String) async throws -> PendingDiscordCredential
}

nonisolated protocol DiscordSignInRemoteAuthenticating: Sendable {
    func events() async -> AsyncStream<DiscordRemoteAuthEvent>
    func connect() async
    func restart() async
    func disconnect() async
    func decryptToken(_ encryptedToken: String) async throws -> String
}

extension DiscordSessionAuthenticator: DiscordSignInAuthenticating {}
extension DiscordRemoteAuthManager: DiscordSignInRemoteAuthenticating {}

/// Substitutes the authentication boundary only. The real view owns all form,
/// QR, MFA, error, progress, cancellation, and account-handoff presentation.
/// This actor has no transport, credential store, or persistent state.
actor OfflineSignInService: DiscordSignInAuthenticating, DiscordSignInRemoteAuthenticating {
    private var continuation: AsyncStream<DiscordRemoteAuthEvent>.Continuation?
    private var simulationTask: Task<Void, Never>?
    private static let fixtureToken = "sakuracord-offline-sign-in-fixture"

    nonisolated static func mfaChallenge() -> DiscordMFAChallenge {
        DiscordMFAChallenge(
            ticket: "offline-mfa", loginInstanceID: nil,
            methods: [.totp, .backup, .sms]
        )
    }

    func login(identifier: String, password: String) async throws -> DiscordNativeAuthenticationStep {
        try await Task.sleep(for: .milliseconds(1200))
        guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (8 ... 72).contains(password.count), password != "incorrect"
        else { throw AuthenticationError.invalidCredentials }
        if identifier.lowercased().hasPrefix("mfa") {
            return .mfa(Self.mfaChallenge())
        }
        return try .authenticated(credential())
    }

    func completeMFA(challenge: DiscordMFAChallenge, method: DiscordMFAMethod, code: String) async throws -> PendingDiscordCredential {
        try await Task.sleep(for: .milliseconds(1200))
        guard challenge.methods.contains(method) else { throw AuthenticationError.unsupportedMFA }
        guard method.normalizedCode(code) == (method == .backup ? "abcd1234" : "123456") else {
            throw AuthenticationError.invalidMFACode
        }
        return try credential()
    }

    func sendSMS(for challenge: DiscordMFAChallenge) async throws {
        guard challenge.methods.contains(.sms) else { throw AuthenticationError.unsupportedMFA }
        try await Task.sleep(for: .milliseconds(650))
    }

    func events() -> AsyncStream<DiscordRemoteAuthEvent> {
        continuation?.finish()
        let (stream, continuation) = AsyncStream<DiscordRemoteAuthEvent>.makeStream()
        self.continuation = continuation
        return stream
    }

    func connect() {
        simulationTask?.cancel()
        continuation?.yield(.connecting)
        simulationTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(900))
                // A reserved, non-routable URL; never a real Discord login link.
                continuation?.yield(.qrCode(URL(string: "https://sakuracord.invalid/offline-sign-in/\(UUID().uuidString)")!))
            } catch {}
        }
    }

    func simulateScan() {
        simulationTask?.cancel()
        simulationTask = Task {
            continuation?.yield(.scanned(DiscordRemoteAuthUser(
                id: "offline", discriminator: "0", avatar: nil, username: "Sakura"
            )))
            do {
                try await Task.sleep(for: .seconds(2))
                continuation?.yield(.pendingLogin(ticket: "offline-ticket"))
            } catch {}
        }
    }

    func expireCode() {
        simulationTask?.cancel()
        continuation?.yield(.failed("Create a fresh code to try the offline sign-in again."))
    }

    func restart() { connect() }

    func disconnect() {
        simulationTask?.cancel()
        simulationTask = nil
        continuation?.finish()
        continuation = nil
    }

    func exchangeRemoteAuthTicket(_ ticket: String) async throws -> DiscordRemoteAuthTicketExchangeStep {
        try await Task.sleep(for: .milliseconds(1200))
        return .encryptedToken(Self.fixtureToken)
    }

    func decryptToken(_ encryptedToken: String) -> String { Self.fixtureToken }
    func acceptRemoteAuthToken(_ token: String) throws -> PendingDiscordCredential { try credential() }

    // CAPTCHA is supplied by Discord's hosted SDK and cannot run offline.
    func completeCaptcha(challenge: DiscordCaptchaChallenge, solutionToken: String) throws -> DiscordNativeAuthenticationStep {
        throw AuthenticationError.invalidCaptchaSolution
    }

    func completeRemoteAuthCaptcha(challenge: DiscordCaptchaChallenge, solutionToken: String) throws -> String {
        throw AuthenticationError.invalidCaptchaSolution
    }

    func cancelCaptcha(challengeID: UUID) {}

    private func credential() throws -> PendingDiscordCredential {
        try PendingDiscordCredential(Data(Self.fixtureToken.utf8))
    }
}

actor OfflineCredentialStore: CredentialStore {
    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        throw ChatProviderError.invalidRequest(
            "Credential storage is unavailable in offline testing mode.")
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        throw ChatProviderError.invalidRequest(
            "Credentials are unavailable in offline testing mode.")
    }

    func remove(_ handle: CredentialHandle) async throws {}

    func handles() async throws -> [CredentialHandle] {
        []
    }
}
