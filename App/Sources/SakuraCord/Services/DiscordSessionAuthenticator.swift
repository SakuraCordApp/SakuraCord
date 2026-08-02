import DiscordProtocol
import Foundation

nonisolated enum DiscordMFAMethod: String, CaseIterable, Codable, Sendable {
    case totp
    case backup
    case sms
}

nonisolated struct DiscordMFAChallenge: Equatable, Sendable {
    let ticket: String
    let loginInstanceID: String?
    let methods: [DiscordMFAMethod]
}

nonisolated enum DiscordNativeAuthenticationStep: Equatable, Sendable {
    case authenticated(CredentialHandle)
    case mfa(DiscordMFAChallenge)
    case captcha(DiscordCaptchaChallenge)
}

nonisolated enum DiscordRemoteAuthTicketExchangeStep: Equatable, Sendable {
    case encryptedToken(String)
    case captcha(DiscordCaptchaChallenge)
}

nonisolated struct DiscordCaptchaChallenge: Equatable, Identifiable, Sendable {
    let id: UUID
    let siteKey: String
    let rqdata: String?
    let rqtoken: String?
    let sessionID: String?
    let shouldServeInvisible: Bool
}

nonisolated protocol DiscordFingerprintStoring: Sendable {
    func load() async -> String?
    func save(_ fingerprint: String) async
}

actor UserDefaultsDiscordFingerprintStore: DiscordFingerprintStoring {
    nonisolated static let shared = UserDefaultsDiscordFingerprintStore()
    private nonisolated static let key = "dev.sakuracord.discord-fingerprint"

    func load() -> String? {
        UserDefaults.standard.string(forKey: Self.key)
    }

    func save(_ fingerprint: String) {
        UserDefaults.standard.set(fingerprint, forKey: Self.key)
    }
}

actor DiscordSessionAuthenticator {
    private let credentials: any CredentialStore
    private let session: URLSession
    private let fingerprints: any DiscordFingerprintStoring
    private let apiDiagnostics: DiscordAPIDiagnosticStore
    private var pendingCaptchaRequest: PendingCaptchaRequest?
    private var pendingRemoteAuthCaptchaRequest: PendingRemoteAuthCaptchaRequest?

    init(
        credentials: any CredentialStore = KeychainCredentialStore(),
        session: URLSession? = nil,
        fingerprints: (any DiscordFingerprintStoring)? = nil,
        apiDiagnostics: DiscordAPIDiagnosticStore = .shared
    ) {
        self.credentials = credentials
        self.fingerprints = fingerprints ?? UserDefaultsDiscordFingerprintStore.shared
        self.apiDiagnostics = apiDiagnostics
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    func login(identifier: String, password: String) async throws -> DiscordNativeAuthenticationStep {
        let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, (8 ... 72).contains(password.count) else {
            throw AuthenticationError.invalidCredentials
        }

        let fingerprint = try await resolvedFingerprint()
        let body = try JSONEncoder().encode(LoginPayload(
            login: identifier,
            password: password,
            undelete: false
        ))
        let (data, response) = try await send(
            path: "/auth/login",
            method: "POST",
            body: body,
            fingerprint: fingerprint
        )
        if let captcha = captchaChallenge(data: data, response: response) {
            pendingCaptchaRequest = PendingCaptchaRequest(
                challengeID: captcha.id,
                path: "/auth/login",
                body: body,
                fingerprint: fingerprint,
                replayDelay: Self.paicordRetryDelay(response: response, retriesSoFar: 0) ?? 0
            )
            return .captcha(captcha)
        }
        try validateAuthenticationResponse(data: data, response: response)
        let payload = try JSONDecoder().decode(LoginResponse.self, from: data)

        if payload.mfa == true {
            guard let ticket = payload.ticket, !ticket.isEmpty else {
                throw AuthenticationError.invalidResponse
            }
            var methods: [DiscordMFAMethod] = []
            if payload.totp == true {
                methods.append(.totp)
            }
            if payload.backup == true {
                methods.append(.backup)
            }
            if payload.sms == true {
                methods.append(.sms)
            }
            guard !methods.isEmpty else { throw AuthenticationError.unsupportedMFA }
            return .mfa(DiscordMFAChallenge(
                ticket: ticket,
                loginInstanceID: payload.loginInstanceID,
                methods: methods
            ))
        }

        guard let token = payload.token else { throw AuthenticationError.invalidResponse }
        return try await .authenticated(validateAndStore(token: token, fingerprint: fingerprint))
    }

    func completeCaptcha(
        challenge: DiscordCaptchaChallenge,
        solutionToken: String
    ) async throws -> DiscordNativeAuthenticationStep {
        guard let pending = pendingCaptchaRequest,
              pending.challengeID == challenge.id,
              !solutionToken.isEmpty
        else {
            throw AuthenticationError.invalidCaptchaSolution
        }
        pendingCaptchaRequest = nil
        if pending.replayDelay > 0 {
            try await Task.sleep(for: .seconds(pending.replayDelay))
        }
        var headers = ["X-Captcha-Key": solutionToken]
        if let sessionID = challenge.sessionID {
            headers["X-Captcha-Session-Id"] = sessionID
        }
        if let rqtoken = challenge.rqtoken {
            headers["X-Captcha-Rqtoken"] = rqtoken
        }
        let (data, response) = try await send(
            path: pending.path,
            method: "POST",
            body: pending.body,
            fingerprint: pending.fingerprint,
            additionalHeaders: headers,
            retriesAlreadyPerformed: 1
        )
        if captchaChallenge(data: data, response: response) != nil {
            throw AuthenticationError.captchaRequired
        }
        try validateAuthenticationResponse(data: data, response: response)
        let payload = try JSONDecoder().decode(LoginResponse.self, from: data)
        if payload.mfa == true {
            guard let ticket = payload.ticket, !ticket.isEmpty else {
                throw AuthenticationError.invalidResponse
            }
            var methods: [DiscordMFAMethod] = []
            if payload.totp == true {
                methods.append(.totp)
            }
            if payload.backup == true {
                methods.append(.backup)
            }
            if payload.sms == true {
                methods.append(.sms)
            }
            guard !methods.isEmpty else { throw AuthenticationError.unsupportedMFA }
            return .mfa(DiscordMFAChallenge(
                ticket: ticket,
                loginInstanceID: payload.loginInstanceID,
                methods: methods
            ))
        }
        guard let token = payload.token else { throw AuthenticationError.invalidResponse }
        return try await .authenticated(validateAndStore(
            token: token,
            fingerprint: pending.fingerprint
        ))
    }

    func cancelCaptcha(challengeID: UUID) {
        if pendingCaptchaRequest?.challengeID == challengeID {
            pendingCaptchaRequest = nil
        }
        if pendingRemoteAuthCaptchaRequest?.challengeID == challengeID {
            pendingRemoteAuthCaptchaRequest = nil
        }
    }

    func completeMFA(
        challenge: DiscordMFAChallenge,
        method: DiscordMFAMethod,
        code: String
    ) async throws -> CredentialHandle {
        guard challenge.methods.contains(method) else { throw AuthenticationError.unsupportedMFA }
        let normalizedCode = normalized(code: code, for: method)
        guard !normalizedCode.isEmpty else { throw AuthenticationError.invalidMFACode }
        let fingerprint = try await resolvedFingerprint()
        let body = try JSONEncoder().encode(MFAPayload(
            code: normalizedCode,
            ticket: challenge.ticket,
            loginInstanceID: challenge.loginInstanceID
        ))
        let (data, response) = try await send(
            path: "/auth/mfa/\(method.rawValue)",
            method: "POST",
            body: body,
            fingerprint: fingerprint
        )
        try validateAuthenticationResponse(data: data, response: response)
        let payload = try JSONDecoder().decode(LoginResponse.self, from: data)
        guard let token = payload.token else { throw AuthenticationError.invalidResponse }
        return try await validateAndStore(token: token, fingerprint: fingerprint)
    }

    func sendSMS(for challenge: DiscordMFAChallenge) async throws {
        guard challenge.methods.contains(.sms) else { throw AuthenticationError.unsupportedMFA }
        let fingerprint = try await resolvedFingerprint()
        let body = try JSONEncoder().encode(SMSSendPayload(ticket: challenge.ticket))
        let (data, response) = try await send(
            path: "/auth/mfa/sms/send",
            method: "POST",
            body: body,
            fingerprint: fingerprint
        )
        try validateAuthenticationResponse(data: data, response: response)
    }

    func storedFingerprint() async -> String? {
        await fingerprints.load()
    }

    func exchangeRemoteAuthTicket(_ ticket: String) async throws -> DiscordRemoteAuthTicketExchangeStep {
        guard !ticket.isEmpty else { throw AuthenticationError.invalidResponse }
        let body = try JSONEncoder().encode(RemoteAuthTicketPayload(ticket: ticket))
        let (data, response) = try await send(
            path: "/users/@me/remote-auth/login",
            method: "POST",
            body: body
        )
        if let captcha = captchaChallenge(data: data, response: response) {
            pendingRemoteAuthCaptchaRequest = PendingRemoteAuthCaptchaRequest(
                challengeID: captcha.id,
                body: body,
                replayDelay: Self.paicordRetryDelay(response: response, retriesSoFar: 0) ?? 0
            )
            return .captcha(captcha)
        }
        try validateAuthenticationResponse(data: data, response: response)
        return try .encryptedToken(decodeRemoteAuthEncryptedToken(data))
    }

    /// Mirrors Paicord's shared CAPTCHA callback for remote-auth ticket exchange:
    /// one user-completed challenge permits exactly one replay of the same ticket.
    func completeRemoteAuthCaptcha(
        challenge: DiscordCaptchaChallenge,
        solutionToken: String
    ) async throws -> String {
        guard let pending = pendingRemoteAuthCaptchaRequest,
              pending.challengeID == challenge.id,
              !solutionToken.isEmpty
        else {
            throw AuthenticationError.invalidCaptchaSolution
        }
        pendingRemoteAuthCaptchaRequest = nil
        if pending.replayDelay > 0 {
            try await Task.sleep(for: .seconds(pending.replayDelay))
        }
        var headers = ["X-Captcha-Key": solutionToken]
        if let sessionID = challenge.sessionID {
            headers["X-Captcha-Session-Id"] = sessionID
        }
        if let rqtoken = challenge.rqtoken {
            headers["X-Captcha-Rqtoken"] = rqtoken
        }
        let (data, response) = try await send(
            path: "/users/@me/remote-auth/login",
            method: "POST",
            body: pending.body,
            additionalHeaders: headers,
            retriesAlreadyPerformed: 1
        )
        if captchaChallenge(data: data, response: response) != nil {
            throw AuthenticationError.captchaRequired
        }
        try validateAuthenticationResponse(data: data, response: response)
        return try decodeRemoteAuthEncryptedToken(data)
    }

    func acceptRemoteAuthToken(_ token: String) async throws -> CredentialHandle {
        try await validateAndStore(token: token, fingerprint: fingerprints.load())
    }

    private func decodeRemoteAuthEncryptedToken(_ data: Data) throws -> String {
        let payload = try JSONDecoder().decode(RemoteAuthTicketResponse.self, from: data)
        guard !payload.encryptedToken.isEmpty else { throw AuthenticationError.invalidResponse }
        return payload.encryptedToken
    }

    private func resolvedFingerprint() async throws -> String {
        if let stored = await fingerprints.load(), !stored.isEmpty {
            return stored
        }
        let (data, response) = try await send(path: "/experiments", method: "GET")
        guard response.statusCode == 200,
              let payload = try? JSONDecoder().decode(ExperimentsResponse.self, from: data),
              let fingerprint = payload.fingerprint,
              !fingerprint.isEmpty
        else {
            throw AuthenticationError.fingerprintUnavailable
        }
        await fingerprints.save(fingerprint)
        return fingerprint
    }

    private func validateAndStore(token: String, fingerprint: String?) async throws -> CredentialHandle {
        let normalized = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n\r\t"))
        guard normalized.count > 20 else { throw AuthenticationError.invalidCredential }
        let apiVersion = DiscordProductionBaseline.july2026.apiVersion
        var request = URLRequest(url: URL(string: "https://discord.com/api/v\(apiVersion)/users/@me")!)
        request.timeoutInterval = 20
        request.setValue(normalized, forHTTPHeaderField: "Authorization")
        try DiscordClientMetadata(fingerprint: fingerprint).apply(to: &request)
        apiDiagnostics.recordHTTPRequest(
            transport: "authentication",
            method: "GET",
            path: "/users/@me",
            body: nil,
            attempt: 1
        )
        let requestStarted = ContinuousClock.now
        let data: Data
        let rawResponse: URLResponse
        do {
            (data, rawResponse) = try await session.data(for: request)
        } catch {
            apiDiagnostics.recordHTTPFailure(
                transport: "authentication",
                method: "GET",
                path: "/users/@me",
                attempt: 1,
                duration: requestStarted.duration(to: .now),
                error: error
            )
            throw error
        }
        guard let response = rawResponse as? HTTPURLResponse else {
            let error = AuthenticationError.invalidResponse
            apiDiagnostics.recordHTTPFailure(
                transport: "authentication",
                method: "GET",
                path: "/users/@me",
                attempt: 1,
                duration: requestStarted.duration(to: .now),
                error: error
            )
            throw error
        }
        apiDiagnostics.recordHTTPResponse(
            transport: "authentication",
            method: "GET",
            path: "/users/@me",
            attempt: 1,
            response: response,
            body: data,
            duration: requestStarted.duration(to: .now)
        )
        guard response.statusCode == 200 else {
            throw AuthenticationError.rejected
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accountID = object["id"] as? String,
              UInt64(accountID) != nil else { throw AuthenticationError.invalidResponse }
        var credentialData = Data(normalized.utf8)
        defer { credentialData.resetBytes(in: credentialData.indices) }
        return try await credentials.store(credentialData, accountID: accountID)
    }

    private func send(
        path: String,
        method: String,
        body: Data? = nil,
        fingerprint: String? = nil,
        additionalHeaders: [String: String] = [:],
        retriesAlreadyPerformed: Int = 0
    ) async throws -> (Data, HTTPURLResponse) {
        let apiVersion = DiscordProductionBaseline.july2026.apiVersion
        let url = URL(string: "https://discord.com/api/v\(apiVersion)\(path)")!
        let maximumRetries = 3

        for attempt in retriesAlreadyPerformed ... maximumRetries {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 20
            request.httpBody = body
            if body != nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            for (name, value) in additionalHeaders {
                request.setValue(value, forHTTPHeaderField: name)
            }
            try DiscordClientMetadata(fingerprint: fingerprint).apply(to: &request)
            apiDiagnostics.recordHTTPRequest(
                transport: "authentication",
                method: method,
                path: path,
                body: body,
                attempt: attempt + 1
            )
            let requestStarted = ContinuousClock.now
            let data: Data
            let rawResponse: URLResponse
            do {
                (data, rawResponse) = try await session.data(for: request)
            } catch {
                apiDiagnostics.recordHTTPFailure(
                    transport: "authentication",
                    method: method,
                    path: path,
                    attempt: attempt + 1,
                    duration: requestStarted.duration(to: .now),
                    error: error
                )
                throw error
            }
            guard let response = rawResponse as? HTTPURLResponse else {
                let error = AuthenticationError.invalidResponse
                apiDiagnostics.recordHTTPFailure(
                    transport: "authentication",
                    method: method,
                    path: path,
                    attempt: attempt + 1,
                    duration: requestStarted.duration(to: .now),
                    error: error
                )
                throw error
            }
            apiDiagnostics.recordHTTPResponse(
                transport: "authentication",
                method: method,
                path: path,
                attempt: attempt + 1,
                response: response,
                body: data,
                duration: requestStarted.duration(to: .now)
            )
            let retryStatuses = [429, 500, 502, 504]
            if retryStatuses.contains(response.statusCode),
               attempt < maximumRetries,
               let retryDelay = Self.paicordRetryDelay(response: response, retriesSoFar: attempt)
            {
                try await Task.sleep(for: .seconds(retryDelay))
                continue
            }
            return (data, response)
        }
        throw AuthenticationError.invalidResponse
    }

    private func validateAuthenticationResponse(data: Data, response: HTTPURLResponse) throws {
        guard (200 ..< 300).contains(response.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if object?["captcha_key"] != nil || object?["captcha_sitekey"] != nil {
                throw AuthenticationError.captchaRequired
            }
            if response.statusCode == 429 {
                throw AuthenticationError.rateLimited(Self.retryAfter(data: data, response: response))
            }
            let code = (object?["code"] as? NSNumber)?.intValue
            if response.statusCode == 401 || response.statusCode == 403
                || object?["suspended_user_token"] != nil
                || object?["required_actions"] != nil
                || code.map({ [20013, 40002, 40007].contains($0) }) == true
            {
                throw AuthenticationError.accountRestricted
            }
            if code == 60008 {
                throw AuthenticationError.invalidMFACode
            }
            if response.statusCode == 400 {
                throw AuthenticationError.invalidCredentials
            }
            throw AuthenticationError.transport(status: response.statusCode)
        }
    }

    private func captchaChallenge(data: Data, response: HTTPURLResponse) -> DiscordCaptchaChallenge? {
        guard !(200 ..< 300).contains(response.statusCode),
              let payload = try? JSONDecoder().decode(CaptchaResponse.self, from: data),
              let siteKey = payload.siteKey,
              !siteKey.isEmpty else { return nil }
        return DiscordCaptchaChallenge(
            id: UUID(),
            siteKey: siteKey,
            rqdata: payload.rqdata,
            rqtoken: payload.rqtoken,
            sessionID: payload.sessionID,
            shouldServeInvisible: payload.shouldServeInvisible ?? false
        )
    }

    private func normalized(code: String, for method: DiscordMFAMethod) -> String {
        switch method {
        case .totp, .sms:
            String(code.filter(\.isNumber).prefix(6))
        case .backup:
            String(code.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        }
    }

    private static func retryAfter(data: Data, response: HTTPURLResponse) -> TimeInterval {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let bodyValue = (object?["retry_after"] as? NSNumber)?.doubleValue
        let headerValue = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        return max(bodyValue ?? 0, headerValue ?? 0, 1)
    }

    private static func paicordRetryDelay(
        response: HTTPURLResponse,
        retriesSoFar: Int
    ) -> TimeInterval? {
        let header = response.value(forHTTPHeaderField: "X-RateLimit-Reset-After")
            ?? response.value(forHTTPHeaderField: "Retry-After")
        if let header, let delay = TimeInterval(header) {
            return delay <= 6 ? delay : nil
        }
        return 0.2 + 0.5 * pow(2, Double(retriesSoFar + 1))
    }
}

private nonisolated struct PendingCaptchaRequest: Sendable {
    let challengeID: UUID
    let path: String
    let body: Data
    let fingerprint: String
    let replayDelay: TimeInterval
}

private nonisolated struct PendingRemoteAuthCaptchaRequest: Sendable {
    let challengeID: UUID
    let body: Data
    let replayDelay: TimeInterval
}

private nonisolated struct LoginPayload: Encodable {
    let login: String
    let password: String
    let undelete: Bool
}

private nonisolated struct MFAPayload: Encodable {
    let code: String
    let ticket: String
    let loginInstanceID: String?

    enum CodingKeys: String, CodingKey {
        case code, ticket
        case loginInstanceID = "login_instance_id"
    }
}

private nonisolated struct SMSSendPayload: Encodable {
    let ticket: String
}

private nonisolated struct ExperimentsResponse: Decodable {
    let fingerprint: String?
}

private nonisolated struct RemoteAuthTicketPayload: Encodable {
    let ticket: String
}

private nonisolated struct RemoteAuthTicketResponse: Decodable {
    let encryptedToken: String

    enum CodingKeys: String, CodingKey {
        case encryptedToken = "encrypted_token"
    }
}

private nonisolated struct LoginResponse: Decodable {
    let token: String?
    let ticket: String?
    let mfa: Bool?
    let totp: Bool?
    let sms: Bool?
    let backup: Bool?
    let loginInstanceID: String?

    enum CodingKeys: String, CodingKey {
        case token, ticket, mfa, totp, sms, backup
        case loginInstanceID = "login_instance_id"
    }
}

private nonisolated struct CaptchaResponse: Decodable {
    let siteKey: String?
    let rqdata: String?
    let rqtoken: String?
    let sessionID: String?
    let shouldServeInvisible: Bool?

    enum CodingKeys: String, CodingKey {
        case siteKey = "captcha_sitekey"
        case rqdata = "captcha_rqdata"
        case rqtoken = "captcha_rqtoken"
        case sessionID = "captcha_session_id"
        case shouldServeInvisible = "should_serve_invisible"
    }
}

nonisolated enum AuthenticationError: LocalizedError, Equatable {
    case invalidCredentials
    case invalidCredential
    case invalidMFACode
    case fingerprintUnavailable
    case captchaRequired
    case invalidCaptchaSolution
    case rateLimited(TimeInterval)
    case accountRestricted
    case unsupportedMFA
    case rejected
    case invalidResponse
    case transport(status: Int)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: "Check your email or phone number and password, then try again."
        case .invalidCredential: "Discord signed in, but did not return a usable session credential."
        case .invalidMFACode: "That authentication code was not accepted."
        case .fingerprintUnavailable: "Discord did not issue the pre-login fingerprint required for a normal sign-in."
        case .captchaRequired: "Discord returned another CAPTCHA challenge after completion, so SakuraCord stopped without replaying again."
        case .invalidCaptchaSolution: "The CAPTCHA was cancelled or did not return a usable solution."
        case let .rateLimited(delay): "Discord rate-limited sign-in. Wait at least \(Int(delay.rounded(.up))) seconds before trying again."
        case .accountRestricted: "Discord returned an account restriction, verification, or authorization stop. SakuraCord will not retry this session."
        case .unsupportedMFA: "This account requires an MFA method SakuraCord cannot complete natively. Use the official Discord client."
        case .rejected: "Discord rejected the new account session. SakuraCord stopped without retrying."
        case .invalidResponse: "Discord returned an invalid sign-in response. SakuraCord stopped without retrying."
        case let .transport(status): "Discord returned HTTP \(status) during sign-in."
        }
    }
}
