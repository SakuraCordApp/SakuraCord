@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

@Suite(.serialized)
struct AccountDetailsContractTests {
    @Test func `private account updates preserve omitted fields and clear explicit nulls`() throws {
        let decoder = JSONDecoder()
        let original = try #require(decoder.decode(DiscordAccountDetailsDTO.self, from: Data(
            #"{"id":"1","username":"nova","email":"nova@example.com","phone":"+12025550123","mfa_enabled":true}"#.utf8
        )).domain())
        let sparse = try decoder.decode(DiscordAccountDetailsDTO.self, from: Data(#"{"id":"1","username":"new-name"}"#.utf8))
        let updated = try #require(sparse.domain(merging: original))
        #expect(updated.username == "new-name")
        #expect(updated.email == original.email && updated.phoneNumber == original.phoneNumber)
        #expect(updated.isMFAEnabled)
        let cleared = try decoder.decode(DiscordAccountDetailsDTO.self, from: Data(#"{"id":"1","email":null,"phone":null,"mfa_enabled":false}"#.utf8))
        #expect(cleared.domain(merging: updated)?.email == nil)
        #expect(cleared.domain(merging: updated)?.phoneNumber == nil)
        #expect(cleared.domain(merging: updated)?.isMFAEnabled == false)
        let foreign = try decoder.decode(DiscordAccountDetailsDTO.self, from: Data(#"{"id":"2","username":"other"}"#.utf8))
        #expect(foreign.domain(merging: original) == nil)
        #expect(sparse.domain() == nil)
    }

    @Test(arguments: [true, false])
    func `account reads reuse READY and follow observed device contract without mutations`(completeReady: Bool) async throws {
        let capture = RequestRecorder(AccountReadURLProtocol.captured)
        let provider = stubbedProvider(AccountReadURLProtocol.self, token: capture.id)
        let privateFields = completeReady ? #","email":"nova@example.com","phone":null,"mfa_enabled":true"# : ""
        let ready = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"user":{"id":"1","username":"nova"\(privateFields)},
         "auth_session_id_hash":"current","guilds":[],"private_channels":[],"users":[]}
        """.utf8))
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: ready)
        let details = try await provider.accountDetails()
        #expect(details.username == "nova" && details.isMFAEnabled)
        #expect(details.phoneNumber == nil)
        #expect(capture.requests.count == (completeReady ? 0 : 1))

        let devices = try await provider.accountDevices()
        #expect(devices.map(\.id) == ["current", "older"])
        #expect(devices.first?.isCurrentSession == true)
        #expect(devices.last?.isCurrentSession == false)
        #expect(devices.last?.location == "192.0.2.1")
        #expect(devices.first?.lastUsedAt != nil)
        let requests = capture.requests
        #expect(requests.map(\.path) == (completeReady
            ? ["/api/v9/auth/sessions"]
            : ["/api/v9/users/@me", "/api/v9/auth/sessions"]))
        #expect(requests.allSatisfy { $0.method == "GET" && $0.url?.query == nil && $0.httpBody == nil })

        await provider.receiveGatewayDispatchForTesting(name: "USER_UPDATE", data: .object([
            "id": .string("1"), "email": .null, "mfa_enabled": .bool(false),
        ]))
        let updated = try await provider.accountDetails()
        #expect(updated.email == nil && !updated.isMFAEnabled)
        #expect(updated.username == "nova")
        await provider.disconnect()
        await #expect(throws: ChatProviderError.self) { try await provider.accountDetails() }
    }
}

private final class AccountReadURLProtocol: URLProtocol, @unchecked Sendable {
    static let captured = Notification.Name("AccountReadContractCapturedRequest")
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        NotificationCenter.default.post(name: Self.captured, object: request)
        let body = request.url?.path == "/api/v9/users/@me"
            ? #"{"id":"1","username":"nova","email":"nova@example.com","phone":null,"mfa_enabled":true}"#
            : #"""
        {"user_sessions":[
          {"id_hash":"older","approx_last_used_time":"2026-09-17T10:00:00+00:00","client_info":{"os":"iOS","platform":"Discord iOS","ip":"192.0.2.1"}},
          {"id_hash":"current","approx_last_used_time":"2026-09-18T10:00:00.123456+00:00","client_info":{"os":"Mac OS X","platform":"Discord Client","location":"Example City"}}
        ]}
        """#
        respond(status: 200, body: Data(body.utf8))
    }

    override func stopLoading() {}
}
