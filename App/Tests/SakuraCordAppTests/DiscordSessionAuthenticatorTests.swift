import DiscordProtocol
import Foundation
@testable import SakuraCord
import Testing

@Suite(.serialized)
struct DiscordSessionAuthenticatorTests {
    @Test func `cold password login stops before gateway identity and persistence`() async throws {
        AuthenticationURLProtocol.reset(mode: .passwordSuccess)
        let fingerprints = TestFingerprintStore()
        let authenticator = DiscordSessionAuthenticator(
            session: Self.session(),
            fingerprints: fingerprints
        )

        let step = try await authenticator.login(
            identifier: "person@example.com",
            password: "correct horse battery staple"
        )

        let credential = try #require({
            if case let .authenticated(credential) = step {
                return credential
            }
            return nil
        }())
        #expect(AuthenticationURLProtocol.paths == [
            "/api/v9/apex/experiments",
            "/api/v9/experiments",
            "/api/v9/auth/login"
        ])
        #expect(AuthenticationURLProtocol.apexQuery == ["surface": "2"])
        #expect(AuthenticationURLProtocol.apexInstallationID == nil)
        #expect(AuthenticationURLProtocol.experimentsQuery == ["with_guild_experiments": "true"])
        #expect(AuthenticationURLProtocol.experimentsInstallationID == "server-issued-installation")
        #expect(AuthenticationURLProtocol.experimentsContext == DiscordSessionAuthenticatorTests.loginContext)
        #expect(AuthenticationURLProtocol.loginBody?["login"] as? String == "person@example.com")
        #expect(AuthenticationURLProtocol.loginBody?["password"] as? String == "correct horse battery staple")
        #expect(AuthenticationURLProtocol.loginBody?["undelete"] as? Bool == false)
        #expect(AuthenticationURLProtocol.loginBody?["login_source"] is NSNull)
        #expect(AuthenticationURLProtocol.loginBody?["gift_code_sku_id"] is NSNull)
        #expect(AuthenticationURLProtocol.loginFingerprint == "server-issued-fingerprint")
        #expect(AuthenticationURLProtocol.loginInstallationID == "server-issued-installation")
        #expect(AuthenticationURLProtocol.loginAuthorization == nil)
        #expect(AuthenticationURLProtocol.loginHost == "discordapp.com")
        #expect(AuthenticationURLProtocol.loginReferer == "https://discordapp.com/login")
        #expect(AuthenticationURLProtocol.loginOrigin == "https://discordapp.com")
        #expect(AuthenticationURLProtocol.loginSuperProperties?["client_heartbeat_session_id"] == nil)
        #expect(AuthenticationURLProtocol.loginSuperProperties?["native_build_number"] as? Int == 87_263)
        #expect(AuthenticationURLProtocol.loginSuperProperties?["client_version"] as? String == "0.0.403")
        #expect(AuthenticationURLProtocol.loginSuperProperties?["browser_version"] as? String == "42.7.1")
        #expect(AuthenticationURLProtocol.superPropertiesCount == 3)
        #expect(await fingerprints.load() == "server-issued-fingerprint")
        #expect(await fingerprints.loadInstallationID() == "server-issued-installation")
        await credential.discard()
    }

    @Test func `mfa uses issued ticket and stops before gateway identity`() async throws {
        AuthenticationURLProtocol.reset(mode: .mfaSuccess)
        let fingerprints = TestFingerprintStore(value: "existing-fingerprint")
        let authenticator = DiscordSessionAuthenticator(
            session: Self.session(),
            fingerprints: fingerprints
        )

        let firstStep = try await authenticator.login(
            identifier: "person@example.com",
            password: "correct horse battery staple"
        )
        let challenge = try #require({
            if case let .mfa(challenge) = firstStep {
                return challenge
            }
            return nil
        }())
        #expect(challenge.methods == [.totp, .backup])

        let credential = try await authenticator.completeMFA(
            challenge: challenge,
            method: .totp,
            code: "123 456"
        )

        #expect(AuthenticationURLProtocol.paths == [
            "/api/v9/auth/login",
            "/api/v9/auth/mfa/totp"
        ])
        #expect(AuthenticationURLProtocol.mfaBody?["code"] as? String == "123456")
        #expect(AuthenticationURLProtocol.mfaBody?["ticket"] as? String == "mfa-ticket")
        #expect(AuthenticationURLProtocol.mfaBody?["login_instance_id"] as? String == "login-instance")
        #expect(AuthenticationURLProtocol.mfaBody?["login_source"] is NSNull)
        #expect(AuthenticationURLProtocol.mfaBody?["gift_code_sku_id"] is NSNull)
        #expect(AuthenticationURLProtocol.mfaFingerprint == "existing-fingerprint")
        #expect(AuthenticationURLProtocol.mfaInstallationID == "existing-installation")
        await credential.discard()
    }

    @Test func `captcha replays once with paicord challenge headers`() async throws {
        AuthenticationURLProtocol.reset(mode: .captchaThenSuccess)
        let authenticator = DiscordSessionAuthenticator(
            session: Self.session(),
            fingerprints: TestFingerprintStore(value: "existing-fingerprint")
        )

        let firstStep = try await authenticator.login(
            identifier: "person@example.com",
            password: "correct horse battery staple"
        )
        let challenge = try #require({
            if case let .captcha(challenge) = firstStep {
                return challenge
            }
            return nil
        }())
        #expect(AuthenticationURLProtocol.paths == ["/api/v9/auth/login"])

        let secondStep = try await authenticator.completeCaptcha(
            challenge: challenge,
            solutionToken: "user-completed-solution"
        )

        let credential = try #require({
            if case let .authenticated(credential) = secondStep {
                return credential
            }
            return nil
        }())
        #expect(AuthenticationURLProtocol.paths == [
            "/api/v9/auth/login",
            "/api/v9/auth/login"
        ])
        #expect(AuthenticationURLProtocol.captchaKey == "user-completed-solution")
        #expect(AuthenticationURLProtocol.captchaRQToken == "request-token")
        #expect(AuthenticationURLProtocol.captchaSessionID == "captcha-session")
        await credential.discard()
    }

    @Test func `password login stops at the current official three attempt budget`() async throws {
        AuthenticationURLProtocol.reset(mode: .loginServerFailure)
        let authenticator = DiscordSessionAuthenticator(
            session: Self.session(),
            fingerprints: TestFingerprintStore(value: "existing-fingerprint")
        )

        await #expect(throws: AuthenticationError.transport(status: 500)) {
            try await authenticator.login(
                identifier: "person@example.com",
                password: "correct horse battery staple"
            )
        }

        #expect(AuthenticationURLProtocol.loginRequestCount == 3)
        #expect(AuthenticationURLProtocol.paths == Array(repeating: "/api/v9/auth/login", count: 3))
    }

    @Test func `remote auth exchanges one ticket then waits for gateway identity`() async throws {
        AuthenticationURLProtocol.reset(mode: .remoteAuthSuccess)
        let authenticator = DiscordSessionAuthenticator(
            session: Self.session(),
            fingerprints: TestFingerprintStore(value: "existing-fingerprint")
        )

        let exchange = try await authenticator.exchangeRemoteAuthTicket("approved-ticket")
        let encryptedToken = try #require({
            if case let .encryptedToken(value) = exchange {
                return value
            }
            return nil
        }())
        #expect(encryptedToken == "encrypted-token-fixture")
        let credential = try await authenticator.acceptRemoteAuthToken("remote-session-credential-value")

        #expect(AuthenticationURLProtocol.paths == ["/api/v9/users/@me/remote-auth/login"])
        #expect(AuthenticationURLProtocol.remoteAuthBody?["ticket"] as? String == "approved-ticket")
        #expect(AuthenticationURLProtocol.remoteAuthAuthorization == nil)
        await credential.discard()
    }

    @Test func `remote auth captcha replays ticket once with paicord challenge headers`() async throws {
        AuthenticationURLProtocol.reset(mode: .remoteAuthCaptchaThenSuccess)
        let authenticator = DiscordSessionAuthenticator(
            session: Self.session(),
            fingerprints: TestFingerprintStore(value: "existing-fingerprint")
        )

        let firstExchange = try await authenticator.exchangeRemoteAuthTicket("approved-ticket")
        let challenge = try #require({
            if case let .captcha(value) = firstExchange {
                return value
            }
            return nil
        }())
        #expect(challenge.shouldServeInvisible == true)
        #expect(AuthenticationURLProtocol.paths == ["/api/v9/users/@me/remote-auth/login"])

        let encryptedToken = try await authenticator.completeRemoteAuthCaptcha(
            challenge: challenge,
            solutionToken: "user-completed-remote-solution"
        )

        #expect(encryptedToken == "encrypted-token-fixture")
        #expect(AuthenticationURLProtocol.paths == [
            "/api/v9/users/@me/remote-auth/login",
            "/api/v9/users/@me/remote-auth/login"
        ])
        #expect(AuthenticationURLProtocol.remoteAuthRequestCount == 2)
        #expect(AuthenticationURLProtocol.remoteAuthCaptchaKey == "user-completed-remote-solution")
        #expect(AuthenticationURLProtocol.remoteAuthCaptchaRQToken == "remote-request-token")
        #expect(AuthenticationURLProtocol.remoteAuthCaptchaSessionID == "remote-captcha-session")
        #expect(AuthenticationURLProtocol.remoteAuthAuthorization == nil)
    }

    @Test func `remote auth does not replay A second captcha challenge`() async throws {
        AuthenticationURLProtocol.reset(mode: .remoteAuthCaptchaTwice)
        let authenticator = DiscordSessionAuthenticator(
            session: Self.session(),
            fingerprints: TestFingerprintStore(value: "existing-fingerprint")
        )
        let firstExchange = try await authenticator.exchangeRemoteAuthTicket("approved-ticket")
        let challenge = try #require({
            if case let .captcha(value) = firstExchange {
                return value
            }
            return nil
        }())

        await #expect(throws: AuthenticationError.captchaRequired) {
            try await authenticator.completeRemoteAuthCaptcha(
                challenge: challenge,
                solutionToken: "user-completed-remote-solution"
            )
        }

        #expect(AuthenticationURLProtocol.remoteAuthRequestCount == 2)
        #expect(AuthenticationURLProtocol.paths == [
            "/api/v9/users/@me/remote-auth/login",
            "/api/v9/users/@me/remote-auth/login"
        ])
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthenticationURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static let loginContext = Data(#"{"location":"Login"}"#.utf8).base64EncodedString()
}

private actor TestFingerprintStore: DiscordFingerprintStoring {
    private var value: String?
    private var installationID: String?

    init(value: String? = nil, installationID: String? = nil) {
        self.value = value
        self.installationID = installationID ?? (value == nil ? nil : "existing-installation")
    }

    func load() -> String? {
        value
    }

    func save(_ fingerprint: String) {
        value = fingerprint
    }

    func loadInstallationID() async -> String? {
        installationID
    }

    func saveInstallationID(_ installationID: String) async {
        self.installationID = installationID
    }
}

private final class AuthenticationURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode {
        case passwordSuccess
        case mfaSuccess
        case captchaThenSuccess
        case loginServerFailure
        case remoteAuthSuccess
        case remoteAuthCaptchaThenSuccess
        case remoteAuthCaptchaTwice
    }

    nonisolated(unsafe) static var mode = Mode.passwordSuccess
    nonisolated(unsafe) static var paths: [String] = []
    nonisolated(unsafe) static var apexQuery: [String: String] = [:]
    nonisolated(unsafe) static var apexInstallationID: String?
    nonisolated(unsafe) static var experimentsQuery: [String: String] = [:]
    nonisolated(unsafe) static var experimentsInstallationID: String?
    nonisolated(unsafe) static var experimentsContext: String?
    nonisolated(unsafe) static var loginBody: [String: Any]?
    nonisolated(unsafe) static var mfaBody: [String: Any]?
    nonisolated(unsafe) static var loginFingerprint: String?
    nonisolated(unsafe) static var mfaFingerprint: String?
    nonisolated(unsafe) static var loginInstallationID: String?
    nonisolated(unsafe) static var mfaInstallationID: String?
    nonisolated(unsafe) static var loginAuthorization: String?
    nonisolated(unsafe) static var loginHost: String?
    nonisolated(unsafe) static var loginReferer: String?
    nonisolated(unsafe) static var loginOrigin: String?
    nonisolated(unsafe) static var loginSuperProperties: [String: Any]?
    nonisolated(unsafe) static var superPropertiesCount = 0
    nonisolated(unsafe) static var loginRequestCount = 0
    nonisolated(unsafe) static var captchaKey: String?
    nonisolated(unsafe) static var captchaRQToken: String?
    nonisolated(unsafe) static var captchaSessionID: String?
    nonisolated(unsafe) static var remoteAuthBody: [String: Any]?
    nonisolated(unsafe) static var remoteAuthAuthorization: String?
    nonisolated(unsafe) static var remoteAuthRequestCount = 0
    nonisolated(unsafe) static var remoteAuthCaptchaKey: String?
    nonisolated(unsafe) static var remoteAuthCaptchaRQToken: String?
    nonisolated(unsafe) static var remoteAuthCaptchaSessionID: String?

    static func reset(mode: Mode) {
        self.mode = mode
        paths = []
        apexQuery = [:]
        apexInstallationID = nil
        experimentsQuery = [:]
        experimentsInstallationID = nil
        experimentsContext = nil
        loginBody = nil
        mfaBody = nil
        loginFingerprint = nil
        mfaFingerprint = nil
        loginInstallationID = nil
        mfaInstallationID = nil
        loginAuthorization = nil
        loginHost = nil
        loginReferer = nil
        loginOrigin = nil
        loginSuperProperties = nil
        superPropertiesCount = 0
        loginRequestCount = 0
        captchaKey = nil
        captchaRQToken = nil
        captchaSessionID = nil
        remoteAuthBody = nil
        remoteAuthAuthorization = nil
        remoteAuthRequestCount = 0
        remoteAuthCaptchaKey = nil
        remoteAuthCaptchaRQToken = nil
        remoteAuthCaptchaSessionID = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let path = request.url!.path
        Self.paths.append(path)
        if request.value(forHTTPHeaderField: "X-Super-Properties") != nil {
            Self.superPropertiesCount += 1
        }

        let status: Int
        let body: String
        switch path {
        case "/api/v9/apex/experiments":
            Self.apexQuery = Self.query(from: request)
            Self.apexInstallationID = request.value(forHTTPHeaderField: "X-Installation-ID")
            status = 200
            body = #"{"installation":"server-issued-installation","assignments":{}}"#
        case "/api/v9/experiments":
            Self.experimentsQuery = Self.query(from: request)
            Self.experimentsInstallationID = request.value(forHTTPHeaderField: "X-Installation-ID")
            Self.experimentsContext = request.value(forHTTPHeaderField: "X-Context-Properties")
            status = 200
            body = #"{"fingerprint":"server-issued-fingerprint","assignments":[],"guild_experiments":[]}"#
        case "/api/v9/auth/login":
            Self.loginRequestCount += 1
            Self.loginBody = Self.bodyData(from: request).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            Self.loginFingerprint = request.value(forHTTPHeaderField: "X-Fingerprint")
            Self.loginInstallationID = request.value(forHTTPHeaderField: "X-Installation-ID")
            Self.loginAuthorization = request.value(forHTTPHeaderField: "Authorization")
            Self.loginHost = request.url?.host
            Self.loginReferer = request.value(forHTTPHeaderField: "Referer")
            Self.loginOrigin = request.value(forHTTPHeaderField: "Origin")
            Self.loginSuperProperties = Self.superProperties(from: request)
            Self.captchaKey = request.value(forHTTPHeaderField: "X-Captcha-Key")
            Self.captchaRQToken = request.value(forHTTPHeaderField: "X-Captcha-Rqtoken")
            Self.captchaSessionID = request.value(forHTTPHeaderField: "X-Captcha-Session-Id")
            switch Self.mode {
            case .passwordSuccess:
                status = 200
                body = #"{"token":"test-session-credential-value"}"#
            case .mfaSuccess:
                status = 200
                body = #"{"mfa":true,"ticket":"mfa-ticket","totp":true,"backup":true,"login_instance_id":"login-instance"}"#
            case .captchaThenSuccess:
                if Self.loginRequestCount == 1 {
                    status = 400
                    body = #"{"captcha_key":["captcha-required"],"captcha_service":"hcaptcha","captcha_sitekey":"site-key","captcha_rqdata":"request-data","captcha_rqtoken":"request-token","captcha_session_id":"captcha-session"}"#
                } else {
                    status = 200
                    body = #"{"token":"test-session-credential-value"}"#
                }
            case .loginServerFailure:
                status = 500
                body = #"{"message":"temporary server failure"}"#
            case .remoteAuthSuccess, .remoteAuthCaptchaThenSuccess, .remoteAuthCaptchaTwice:
                status = 500
                body = #"{"message":"unexpected login call"}"#
            }
        case "/api/v9/users/@me/remote-auth/login":
            Self.remoteAuthRequestCount += 1
            Self.remoteAuthBody = Self.bodyData(from: request).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            Self.remoteAuthAuthorization = request.value(forHTTPHeaderField: "Authorization")
            Self.remoteAuthCaptchaKey = request.value(forHTTPHeaderField: "X-Captcha-Key")
            Self.remoteAuthCaptchaRQToken = request.value(forHTTPHeaderField: "X-Captcha-Rqtoken")
            Self.remoteAuthCaptchaSessionID = request.value(forHTTPHeaderField: "X-Captcha-Session-Id")
            if (Self.mode == .remoteAuthCaptchaThenSuccess && Self.remoteAuthRequestCount == 1)
                || Self.mode == .remoteAuthCaptchaTwice
            {
                status = 400
                body = #"{"captcha_key":["captcha-required"],"captcha_service":"hcaptcha","captcha_sitekey":"remote-site-key","captcha_rqdata":"remote-request-data","captcha_rqtoken":"remote-request-token","captcha_session_id":"remote-captcha-session","should_serve_invisible":true}"#
            } else {
                status = 200
                body = #"{"encrypted_token":"encrypted-token-fixture"}"#
            }
        case "/api/v9/auth/mfa/totp":
            Self.mfaBody = Self.bodyData(from: request).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            Self.mfaFingerprint = request.value(forHTTPHeaderField: "X-Fingerprint")
            Self.mfaInstallationID = request.value(forHTTPHeaderField: "X-Installation-ID")
            status = 200
            body = #"{"token":"test-session-credential-value"}"#
        default:
            status = 404
            body = #"{"message":"not found"}"#
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json",
                "X-RateLimit-Reset-After": "0"
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func query(from request: URLRequest) -> [String: String] {
        guard let url = request.url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }

    private static func superProperties(from request: URLRequest) -> [String: Any]? {
        guard let header = request.value(forHTTPHeaderField: "X-Super-Properties"),
              let data = Data(base64Encoded: header)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
