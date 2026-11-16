@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

@Test func `global avatar fanout preserves session and only publishes changed indexes`() async throws {
    let provider = DiscordRESTProvider(
        credentials: TestCredentialStore(), handle: CredentialHandle(accountID: "profile-burst"),
        session: URLSession(configuration: .ephemeral)
    )
    let guildIDs = (100 ... 199).map { GuildID(rawValue: UInt64($0)) }
    func user(_ avatar: String) -> JSONValue {
        .object(["id": .string("1"), "username": .string("fixture"),
                 "global_name": .string("Fixture"), "avatar": .string(avatar)])
    }
    func member(_ guildID: GuildID, avatar: String, nickname: String = "Nickname", roles: [String] = []) -> JSONValue {
        .object(["guild_id": .string(guildID.description), "user": user(avatar),
                 "nick": .string(nickname), "roles": .array(roles.map(JSONValue.string)),
                 "joined_at": .string("2025-01-01T00:00:00Z"), "pending": .bool(false)])
    }
    await provider.handleGatewayDispatch(name: "USER_UPDATE", body: user("before"))
    for guildID in guildIDs {
        await provider.handleGatewayDispatch(name: "GUILD_MEMBER_UPDATE", body: member(guildID, avatar: "before"))
    }
    await provider.seedProfileBurstGuildPermissions(guildIDs)
    let stream = await provider.eventStream()
    // Discord sends USER_UPDATE followed by one member update per joined
    // guild. Hold the consumer while this legitimate burst is projected.
    await provider.handleGatewayDispatch(name: "USER_UPDATE", body: user("after"))
    for guildID in guildIDs {
        await provider.handleGatewayDispatch(name: "GUILD_MEMBER_UPDATE", body: member(guildID, avatar: "after"))
    }
    #expect(await provider.cachedGuilds[guildIDs[0]]?.currentUserPermissions == 1_024)
    #expect(await provider.cachedMembers[guildIDs.last!]?.first?.user.avatarURL.path.contains("after") == true)

    // Real nickname and role changes must still propagate and invalidate
    // the old permission snapshot after removing no-op publications.
    await provider.handleGatewayDispatch(name: "GUILD_MEMBER_UPDATE", body: member(
        guildIDs[0], avatar: "after", nickname: "Changed", roles: ["2"]
    ))
    #expect(await provider.cachedGuilds[guildIDs[0]]?.currentUserPermissions == nil)
    await provider.continuation?.finish()
    var invalidated = false
    var nicknameUpdates = 0
    var roleUpdates = 0
    for await event in stream {
        switch event {
        case .sessionInvalidated: invalidated = true
        case .userSearchAliasesChanged(let aliases):
            nicknameUpdates += 1
            #expect(aliases[UserID(rawValue: 1)]?.contains("Changed") == true)
        case let .currentUserRolesChanged(guildID, roles):
            roleUpdates += 1
            #expect(guildID == guildIDs[0])
            #expect(roles == [RoleID(rawValue: 2)])
        default: break
        }
    }
    #expect(!invalidated)
    #expect(nicknameUpdates == 1)
    #expect(roleUpdates == 1)
    await provider.disconnect()
}

private extension DiscordRESTProvider {
    func seedProfileBurstGuildPermissions(_ ids: [GuildID]) {
        for id in ids { cachedGuilds[id] = Guild(id: id, name: "Fixture", currentUserPermissions: 1_024) }
    }
}
