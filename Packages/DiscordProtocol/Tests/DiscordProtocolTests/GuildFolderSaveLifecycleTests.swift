@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Synchronization
import Testing

/// Uses the existing serialized suite and its gated settings responses.
extension DirectMessageProviderContractTests {
    @Test(.timeLimit(.minutes(1)))
    func `disconnect drains a rail edit queued behind an active save`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = await guildFolderSaveProvider()
        let gate = StatusRecoveryResponseGate()
        defer { gate.release() }
        DirectMessageURLProtocol.settingsReplies = [
            .init(200, guildFolderSaveResponse([200, 100, 300], version: 2), gate: gate),
            .init(200, guildFolderSaveResponse([300, 200, 100], version: 3)),
        ]
        try await provider.updateGuildRailLayout(guildFolderSaveRail([200, 100, 300]))
        let save = Task { await provider.flushGuildFoldersIfNeeded() }
        #expect(await eventually { gate.didCapture })
        try await provider.updateGuildRailLayout(guildFolderSaveRail([300, 200, 100]))
        let disconnect = Task { await provider.disconnect() }
        // Teardown cancels the pending timer before joining the held request.
        #expect(await eventually { await provider.guildFoldersFlushTask == nil })
        gate.release()
        await disconnect.value
        await save.value

        let requests = DirectMessageURLProtocol.requests.filter { $0.path == "/api/v9/users/@me/settings-proto/1" }
        #expect(requests.count == 2)
        let encoded = try #require(requests.last?.body?["settings"] as? String)
        let settings = try #require(Data(base64Encoded: encoded))
        #expect(DiscordSettingsProto.guildFoldersSettings(in: settings)
            == DiscordSettingsProto.guildFoldersSettings(in: guildFolderSaveProto([300, 200, 100], version: 3)))
        #expect(await provider.pendingGuildFoldersSettings == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [200, 400])
    func `ready reconnect reconciles an active rail save`(status: Int) async throws {
        DirectMessageURLProtocol.reset()
        let provider = await guildFolderSaveProvider()
        let gate = StatusRecoveryResponseGate()
        defer { gate.release() }
        DirectMessageURLProtocol.settingsReplies = [
            .init(status, status == 200 ? guildFolderSaveResponse([200, 100, 300], version: 2)
                : #"{"code":50105,"message":"Invalid user settings data"}"#, gate: gate),
        ]
        try await provider.updateGuildRailLayout(guildFolderSaveRail([200, 100, 300]))
        let save = Task { await provider.flushGuildFoldersIfNeeded() }
        #expect(await eventually { gate.didCapture })
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": .object(["id": .string("2"), "username": .string("fixture")]),
            "guilds": .array(["100", "200", "300"].map { .object(["id": .string($0), "name": .string("Server")]) }),
            "user_settings_proto": .string(guildFolderSaveProto([300, 200, 100], version: 3).base64EncodedString()),
        ]))
        gate.release()
        await save.value
        #expect(await provider.pendingGuildFoldersSettings == nil)
        #expect(await provider.cachedGuildRailItemsForTesting() == guildFolderSaveRail([300, 200, 100]))
        #expect(await provider.guildFoldersFlushTask == nil)

        // Subsequent updates must no longer be hidden behind a pending edit.
        await provider.receiveGatewayDispatchForTesting(name: "USER_SETTINGS_PROTO_UPDATE", data: .object([
            "partial": .bool(true),
            "settings": .object(["type": .number(1), "proto": .string(guildFolderSaveProto([100, 300, 200], version: 4).base64EncodedString())]),
        ]))
        #expect(await provider.cachedGuildRailItemsForTesting() == guildFolderSaveRail([100, 300, 200]))
        #expect(DirectMessageURLProtocol.requests.filter { $0.path == "/api/v9/users/@me/settings-proto/1" }.count == 1)
        await provider.disconnect()
    }

    @Test(.timeLimit(.minutes(1)))
    func `older rail save response preserves newer gateway state and rollback baseline`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = await guildFolderSaveProvider()
        let gate = StatusRecoveryResponseGate()
        defer { gate.release() }
        DirectMessageURLProtocol.settingsReplies = [
            .init(200, guildFolderSaveResponse([200, 100, 300], version: 2), gate: gate),
            .init(400, #"{"code":50105,"message":"Invalid user settings data"}"#),
        ]
        try await provider.updateGuildRailLayout(guildFolderSaveRail([200, 100, 300]))
        let save = Task { await provider.flushGuildFoldersIfNeeded() }
        #expect(await eventually { gate.didCapture })
        let newer = guildFolderSaveProto([300, 200, 100], version: 3)
        await provider.receiveGatewayDispatchForTesting(name: "USER_SETTINGS_PROTO_UPDATE", data: .object([
            "partial": .bool(true),
            "settings": .object(["type": .number(1), "proto": .string(newer.base64EncodedString())]),
        ]))
        gate.release()
        await save.value
        #expect(await provider.cachedGuildRailItemsForTesting() == guildFolderSaveRail([300, 200, 100]))
        #expect(await provider.guildFoldersSettings == DiscordSettingsProto.guildFoldersSettings(in: newer))

        try await provider.updateGuildRailLayout(guildFolderSaveRail([100, 200, 300]))
        await provider.flushGuildFoldersIfNeeded()
        #expect(await provider.cachedGuildRailItemsForTesting() == guildFolderSaveRail([300, 200, 100]))
        await provider.disconnect()
    }

    @Test(.timeLimit(.minutes(1)))
    func `teardown flush fails a CAPTCHA instead of waiting on a human`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = await guildFolderSaveProvider()
        let presentations = CaptchaCounter()
        await provider.setCaptchaHandler { _ in
            presentations.value.withLock { $0 += 1 }
            return "human-solution"
        }
        DirectMessageURLProtocol.settingsReplies = [.init(400, """
            {"captcha_key":["captcha-required"],"captcha_service":"hcaptcha","captcha_sitekey":"site-key"}
            """)]
        try await provider.updateGuildRailLayout(guildFolderSaveRail([200, 100, 300]))
        await provider.disconnect()
        #expect(presentations.value.withLock { $0 } == 0)
        #expect(DirectMessageURLProtocol.requests.filter { $0.path == "/api/v9/users/@me/settings-proto/1" }.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func `teardown withdraws a CAPTCHA a save is already waiting on`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = await guildFolderSaveProvider()
        let presentations = CaptchaCounter(), withdrawals = CaptchaCounter()
        // Like an open sheet, it ends early only when withdrawn.
        await provider.setCaptchaHandler { _ in
            presentations.value.withLock { $0 += 1 }
            if (try? await Task.sleep(for: .seconds(5))) == nil { withdrawals.value.withLock { $0 += 1 } }
            return nil
        }
        DirectMessageURLProtocol.settingsReplies = [.init(400, """
            {"captcha_key":["captcha-required"],"captcha_service":"hcaptcha","captcha_sitekey":"site-key"}
            """)]
        try await provider.updateGuildRailLayout(guildFolderSaveRail([200, 100, 300]))
        let save = Task { await provider.flushGuildFoldersIfNeeded() }
        #expect(await eventually { presentations.value.withLock { $0 } == 1 })
        await provider.disconnect()
        await save.value
        #expect(withdrawals.value.withLock { $0 } == 1)
        #expect(DirectMessageURLProtocol.requests.filter { $0.path == "/api/v9/users/@me/settings-proto/1" }.count == 1)
    }
}

private final class CaptchaCounter: Sendable {
    let value = Mutex(0)
}

private func guildFolderSaveRail(_ ids: [UInt64]) -> [GuildRailItem] {
    ids.map { .guild(GuildID(rawValue: $0)) }
}

private func guildFolderSaveProto(_ ids: [UInt64], version: UInt64) -> Data {
    DiscordSettingsProto.protoLengthDelimitedField(1, DiscordSettingsProto.protoVarintField(3, version))
        + DiscordSettingsProto.protoLengthDelimitedField(14, DiscordSettingsProto.updatingGuildFolders(guildFolderSaveRail(ids), in: Data()))
}

private func guildFolderSaveResponse(_ ids: [UInt64], version: UInt64) -> String {
    "{\"settings\":\"\(guildFolderSaveProto(ids, version: version).base64EncodedString())\"}"
}

private func guildFolderSaveProvider() async -> DiscordRESTProvider {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DirectMessageURLProtocol.self]
    let provider = DiscordRESTProvider(credentials: TestCredentialStore(), handle: CredentialHandle(accountID: "guild-folder-save"),
                                       session: URLSession(configuration: configuration))
    await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
        "user": .object(["id": .string("2"), "username": .string("fixture")]),
        "guilds": .array(["100", "200", "300"].map { .object(["id": .string($0), "name": .string("Server \($0)")]) }),
        "user_settings_proto": .string(guildFolderSaveProto([100, 200, 300], version: 1).base64EncodedString()),
    ]))
    return provider
}
