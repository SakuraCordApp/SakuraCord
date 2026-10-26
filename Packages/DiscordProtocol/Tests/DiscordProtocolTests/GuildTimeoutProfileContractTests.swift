import Foundation
import SakuraCordModels
import Testing
@testable import DiscordProtocol

extension DirectMessageProviderContractTests {
    @Test(.timeLimit(.minutes(1)), arguments: ["profile", "nickname"])
    func `delayed server identity responses retain a newer membership timeout`(operation: String) async throws {
        DirectMessageURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DirectMessageURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: DirectMessageCredentialStore(), handle: CredentialHandle(accountID: "dm-contract"),
            session: URLSession(configuration: configuration)
        )
        let account: JSONValue = .object([
            "id": .string("2"), "username": .string("maya"), "global_name": .string("Maya"),
        ])
        let guildID = GuildID(rawValue: 10)
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": account, "guilds": .array([]),
        ]))
        let scope = ProfileEditingScope.server(guildID)
        if operation == "profile" { _ = try await provider.profileEditingSnapshot(in: scope) }
        let gate = StatusRecoveryResponseGate()
        defer { gate.release() }
        DirectMessageURLProtocol.memberIdentityReplies.withLock {
            $0 = [.init(200, #"{"user":{"id":"2","username":"maya"},"roles":[],"nick":"Saved","communication_disabled_until":null}"#, gate: gate)]
        }
        let save = Task {
            if operation == "profile" {
                var changes = ProfileEditChanges()
                changes.identity.name = .set("Saved")
                try await provider.saveProfileChanges(changes, in: scope) { _ in }
            } else {
                #expect(try await provider.setNickname("Saved", in: guildID) == "Saved")
            }
        }
        let started = await eventually { gate.didCapture }
        guard started else {
            gate.release(); save.cancel(); _ = await save.result; await provider.disconnect()
            try #require(started, "The identity PATCH must be held before the newer member update")
            return
        }
        let expiry = "2030-01-01T00:00:00.000Z"
        let member: JSONValue = .object([
            "user": account, "roles": .array([]), "communication_disabled_until": .string(expiry),
        ])
        // Chunk hydration does not use direct member-event revisions. Nickname
        // reconciliation must also preserve timeout evidence from that source.
        let event: JSONValue = operation == "profile" ? .object([
            "guild_id": .string("10"), "user": account, "roles": .array([]),
            "communication_disabled_until": .string(expiry),
        ]) : .object([
            "guild_id": .string("10"), "members": .array([member]),
            "chunk_index": .number(0), "chunk_count": .number(1),
        ])
        await provider.receiveGatewayDispatchForTesting(
            name: operation == "profile" ? "GUILD_MEMBER_UPDATE" : "GUILD_MEMBERS_CHUNK", data: event
        )
        gate.release()
        try await save.value
        let saved = try #require(await provider.cachedMembers[guildID]?.first { $0.id.rawValue == 2 })
        #expect(saved.guildNickname == "Saved")
        #expect(saved.communicationDisabledUntil == DiscordDate.parse(expiry))
        await #expect(throws: ChatProviderError.self) {
            try await provider.requireGuildCommunication(in: .init(rawValue: 41), guildID: guildID)
        }
        #expect(DirectMessageURLProtocol.requests.filter { $0.method == "PATCH" }.count == 1)
        await provider.disconnect()
    }
}
