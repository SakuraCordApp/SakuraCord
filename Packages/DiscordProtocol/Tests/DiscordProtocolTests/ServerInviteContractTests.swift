import Foundation
import Synchronization
import Testing
import SakuraCordModels
@testable import DiscordProtocol

struct ServerInviteContractTests {
    @Test(arguments: ["valid", "onboarding"])
    func `invite preview and acceptance retain profile and use current Gateway context`(code: String) async throws {
        let capture = InviteRequestCapture()
        let provider = try await makeProvider(capture.id)
        let reference = try #require(ServerInviteReference(code))
        let preview = try await provider.serverInvite(reference)
        #expect(preview.brandColor == 0xff1c90)
        #expect(preview.traits.first?.label == "Testing")
        #expect(preview.inviter?.displayName == "Invite Maker")
        #expect(preview.inviter?.username == "maker")
        #expect(preview.inviter?.avatarURL?.absoluteString == "https://cdn.discordapp.com/avatars/902/avatar.webp?size=32")
        let accepted = try await provider.acceptServerInvite(reference, messageID: .init(rawValue: 42))
        #expect(accepted.invite == preview)
        #expect(!accepted.requiresVerification)
        let requests = capture.requests
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "POST"])
        let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(Set(query.map(\.name)) == ["with_counts", "with_expiration", "with_permissions"])
        #expect(query.allSatisfy { $0.value == "true" })
        let body = try JSONDecoder().decode([String: String].self, from: requests[2].httpBody!)
        #expect(body == ["session_id": "invite-session", "invite_instance_id": "42:\(code)"])
        let context = try #require(Data(base64Encoded: requests[2].value(forHTTPHeaderField: "X-Context-Properties")!))
        let object = try #require(JSONSerialization.jsonObject(with: context) as? [String: Any])
        #expect(object["location"] as? String == "Invite Button Embed")
        #expect(object["location_guild_id"] as? String == "900")
        #expect(object["location_channel_type"] as? Int == 0)
        await provider.disconnect()
    }

    @Test(arguments: ["invalid", "banned", "limited", "revoked"])
    func `invite restrictions and failures stay bounded and keep account networking alive`(code: String) async throws {
        let capture = InviteRequestCapture()
        let provider = try await makeProvider(capture.id)
        let reference = try #require(ServerInviteReference(code))
        await #expect(throws: ServerInviteError.self) {
            _ = try await provider.acceptServerInvite(reference, messageID: nil)
        }
        let expectedWrites = code == "invalid" ? 0 : 1
        #expect(capture.requests.filter { $0.httpMethod == "POST" }.count == expectedWrites)
        #expect(!DiscordRESTProvider.isSafetyStop(status: 400, discordCode: 40007, method: "POST", data: Data(), path: "/invites/banned"))
        #expect(DiscordRESTProvider.isSafetyStop(status: 400, discordCode: 40007, method: "POST",
            data: Data(#"{"captcha_key":["challenge"]}"#.utf8), path: "/invites/banned"))
        #expect(await !provider.requestSafetyCircuitIsOpen)
        _ = try await provider.serverInvite(try #require(ServerInviteReference("valid")))
        await provider.disconnect()
    }

    @Test func `members never accept again and only confirmed nonowners can leave`() async throws {
        let capture = InviteRequestCapture()
        let provider = try await makeProvider(capture.id)
        let guildID = GuildID(rawValue: 900)
        await provider.seedInviteGuild(owner: true)
        _ = try await provider.acceptServerInvite(try #require(ServerInviteReference("valid")), messageID: nil)
        #expect(capture.requests.count == 1)
        await #expect(throws: ServerInviteError.self) { try await provider.leaveGuild(guildID) }
        #expect(capture.requests.count == 1)
        await provider.seedInviteGuild(owner: false)
        try await provider.leaveGuild(guildID)
        let request = try #require(capture.requests.last)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/v9/users/@me/guilds/900")
        #expect(try JSONDecoder().decode([String: Bool].self, from: request.httpBody!) == ["lurking": false])
        #expect(await provider.cachedGuilds[guildID] != nil) // Gateway, not REST, removes membership.
        await provider.disconnect()
    }

    @Test func `invite CAPTCHA resumes the original request once without stopping account traffic`() async throws {
        let capture = InviteRequestCapture()
        let provider = try await makeProvider(capture.id)
        let reference = try #require(ServerInviteReference("captcha"))
        let accepted = try await provider.acceptServerInvite(reference, messageID: .init(rawValue: 42)) { challenge in
            #expect(challenge.siteKey == "site-key")
            #expect(challenge.rqdata == "request-data")
            #expect(challenge.rqtoken == "request-token")
            #expect(challenge.sessionID == "captcha-session")
            #expect(challenge.shouldServeInvisible)
            #expect(await !provider.requestSafetyCircuitIsOpen)
            _ = try await provider.serverInvite(try #require(ServerInviteReference("valid")))
            return "human-solution"
        }
        #expect(accepted.invite.guildID == .init(rawValue: 900))
        let requests = capture.requests
        #expect(requests.map(\.httpMethod) == ["GET", "POST", "GET", "POST"])
        let original = requests[1], replay = requests[3]
        #expect(original.url == replay.url)
        #expect(try JSONDecoder().decode([String: String].self, from: original.httpBody!)
            == JSONDecoder().decode([String: String].self, from: replay.httpBody!))
        #expect(original.value(forHTTPHeaderField: "X-Context-Properties") == replay.value(forHTTPHeaderField: "X-Context-Properties"))
        #expect(original.value(forHTTPHeaderField: "X-Captcha-Key") == nil)
        #expect(replay.value(forHTTPHeaderField: "X-Captcha-Key") == "human-solution")
        #expect(replay.value(forHTTPHeaderField: "X-Captcha-Rqtoken") == "request-token")
        #expect(replay.value(forHTTPHeaderField: "X-Captcha-Session-Id") == "captcha-session")
        #expect(await !provider.requestSafetyCircuitIsOpen)
        await provider.disconnect()
    }

    @Test(arguments: ["captchaCancel", "captchaEmpty", "captchaDisconnect", "captchaRepeated", "captchaLimited", "captchaTimeout", "captchaNoHandler"])
    func `cancelled stale or rejected CAPTCHA cannot cause an automatic join loop`(code: String) async throws {
        let capture = InviteRequestCapture()
        let provider = try await makeProvider(capture.id)
        let reference = try #require(ServerInviteReference(code))
        let handler: DiscordCaptchaHandler = { _ in
            if code == "captchaCancel" { throw CancellationError() }
            if code == "captchaDisconnect" { await provider.disconnect() }
            return code == "captchaEmpty" ? "  " : "human-solution"
        }
        await #expect(throws: (any Error).self) {
            _ = try await provider.acceptServerInvite(reference, messageID: nil, captchaHandler: code == "captchaNoHandler" ? nil : handler)
        }
        let completed = ["captchaRepeated", "captchaLimited", "captchaTimeout"].contains(code)
        #expect(capture.requests.filter { $0.httpMethod == "POST" }.count == (completed ? 2 : 1))
        if code != "captchaDisconnect" {
            #expect(await !provider.requestSafetyCircuitIsOpen)
        }
        await provider.disconnect()
    }

    @Test func `only supported invite challenges bypass the account safety circuit`() {
        let data = Data(InviteURLProtocol.challenge.utf8)
        #expect(!DiscordRESTProvider.isSafetyStop(status: 400, discordCode: nil, method: "POST", data: data, path: "/invites/code"))
        #expect(DiscordRESTProvider.isSafetyStop(status: 400, discordCode: nil, method: "POST", data: data, path: "/channels/900/messages"))
        #expect(DiscordRESTProvider.isSafetyStop(status: 400, discordCode: 40002, method: "POST", data: data, path: "/invites/code"))
        for body in [#"{"captcha_key":["required"]}"#, InviteURLProtocol.challenge.replacingOccurrences(of: "hcaptcha", with: "unsupported")] {
            #expect(DiscordRESTProvider.isSafetyStop(status: 400, discordCode: nil, method: "POST", data: Data(body.utf8), path: "/invites/code"))
        }
    }

    private func makeProvider(_ accountID: String) async throws -> DiscordRESTProvider {
        let socket = ReadyGatewaySocket()
        await socket.push(gatewayMessage(op: 10, data: .object(["heartbeat_interval": .number(60_000)])))
        await socket.push(gatewayMessage(op: 0, data: .object([
            "session_id": .string("invite-session"), "resume_gateway_url": .string("wss://gateway.discord.gg")
        ]), sequence: 1, eventName: "READY"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InviteURLProtocol.self]
        let provider = DiscordRESTProvider(credentials: InviteCredentialStore(), handle: .init(accountID: accountID),
            session: URLSession(configuration: configuration), gatewayTransport: ReadyGatewayTransport(socket: socket),
            installationID: "fixture-installation")
        try await provider.startGateway()
        #expect(await eventually { await provider.gatewaySession?.snapshot().sessionID == "invite-session" })
        return provider
    }
}

private extension DiscordRESTProvider {
    func seedInviteGuild(owner: Bool) {
        cachedGuilds[.init(rawValue: 900)] = Guild(id: .init(rawValue: 900), name: "Test", isOwnedByCurrentUser: owner)
    }
}

private actor InviteCredentialStore: CredentialStore {
    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle { .init(accountID: accountID) }
    func credential(for handle: CredentialHandle) async throws -> Data { Data(handle.accountID.utf8) }
    func remove(_ handle: CredentialHandle) async throws {}
    func handles() async throws -> [CredentialHandle] { [] }
}

private final class InviteRequestCapture {
    let id = UUID().uuidString
    private final class Storage: Sendable { let requests = Mutex<[URLRequest]>([]) }
    private let storage = Storage()
    private var observer: (any NSObjectProtocol)?
    init() {
        let storage = storage, id = id
        observer = NotificationCenter.default.addObserver(forName: InviteURLProtocol.captured, object: nil, queue: nil) { notification in
            guard let request = notification.object as? URLRequest, request.value(forHTTPHeaderField: "Authorization") == id else { return }
            storage.requests.withLock { $0.append(request) }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    var requests: [URLRequest] { storage.requests.withLock { $0 } }
}

private final class InviteURLProtocol: URLProtocol, @unchecked Sendable {
    static let captured = Notification.Name("ServerInviteContractRequest")
    static let challenge = """
    {"captcha_key":["captcha-required"],"captcha_service":"hcaptcha","captcha_sitekey":"site-key",
     "captcha_rqdata":"request-data","captcha_rqtoken":"request-token","captcha_session_id":"captcha-session","should_serve_invisible":true}
    """
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
        }
        var capturedRequest = request
        capturedRequest.httpBody = data
        NotificationCenter.default.post(name: Self.captured, object: capturedRequest)
        let code = request.url!.lastPathComponent
        let write = request.httpMethod == "POST"
        let hasSolution = request.value(forHTTPHeaderField: "X-Captcha-Key") != nil
        if write && code == "captchaTimeout" && hasSolution {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let challenged = write && code.hasPrefix("captcha") && (!hasSolution || code == "captchaRepeated")
        let status = challenged ? 400 : write && code == "captchaLimited" ? 429
            : code == "invalid" ? 404 : write && code == "banned" ? 403
            : write && code == "limited" ? 429 : write && code == "revoked" ? 404
            : request.httpMethod == "DELETE" ? 204 : 200
        let features = code == "onboarding" ? #"["GUILD_ONBOARDING"]"# : "[]"
        let body: String
        switch status {
        case 400: body = Self.challenge
        case 404: body = #"{"code":10006,"message":"Unknown Invite"}"#
        case 403: body = #"{"code":40007,"message":"The user is banned from this guild."}"#
        case 429: body = #"{"retry_after":0.01,"global":false}"#
        default:
            body = write ? #"{"guild":{"id":"900"},"new_member":true}"# : """
            {"type":0,"guild":{"id":"900","name":"Test","features":\(features)},
             "channel":{"id":"901","type":0},"approximate_member_count":2,"approximate_presence_count":0,
             "inviter":{"id":"902","username":"maker","global_name":"Invite Maker","avatar":"avatar"},
             "profile":{"brand_color_primary":"#ff1c90","custom_banner_hash":"banner",
               "traits":[{"label":"Testing","emoji_name":"white_check_mark","position":0}]}}
            """
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if status != 204 { client?.urlProtocol(self, didLoad: Data(body.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
