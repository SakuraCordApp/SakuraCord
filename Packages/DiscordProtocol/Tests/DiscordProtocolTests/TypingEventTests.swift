@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

@Test func `guild typing payload uses member and nickname`() throws {
    let payload = try JSONDecoder().decode(TypingStartDTO.self, from: Data(#"""
    {
      "channel_id":"200",
      "guild_id":"100",
      "user_id":"2",
      "timestamp":1784100000,
      "member":{
        "user":{"id":"2","username":"alex","global_name":"Alex"},
        "nick":"Guild Alex",
        "roles":[]
      }
    }
    """#.utf8))
    let user = DiscordTypingEventResolver.resolve(.init(
        typing: payload,
        userID: UserID(rawValue: 2),
        currentUser: nil,
        currentStatus: .online,
        cachedMembers: [:],
        cachedChannels: [],
        cachedMessages: [],
        cachedGuildRoles: [:]
    ))
    #expect(user?.displayName == "Guild Alex")
}

@Test func `DM typing payload uses partial user or recipient cache`() throws {
    let partial = try JSONDecoder().decode(TypingStartDTO.self, from: Data(#"""
    {"channel_id":"400","user_id":"3","timestamp":1784100000,
     "user":{"id":"3","username":"sam","global_name":"Sam"}}
    """#.utf8))
    let partialUser = DiscordTypingEventResolver.resolve(.init(
        typing: partial,
        userID: UserID(rawValue: 3),
        currentUser: nil,
        currentStatus: .online,
        cachedMembers: [:],
        cachedChannels: [],
        cachedMessages: [],
        cachedGuildRoles: [:]
    ))
    #expect(partialUser?.displayName == "Sam")

    let idOnly = try JSONDecoder().decode(
        TypingStartDTO.self,
        from: Data(#"{"channel_id":"401","user_id":"4","timestamp":1784100000}"#.utf8)
    )
    let recipient = User(id: UserID(rawValue: 4), username: "group", displayName: "Group Friend")
    let groupDM = Channel(
        id: ChannelID(rawValue: 401),
        guildID: nil,
        name: "Group",
        kind: .groupDirectMessage,
        recipients: [recipient]
    )
    let cached = DiscordTypingEventResolver.resolve(.init(
        typing: idOnly,
        userID: recipient.id,
        currentUser: nil,
        currentStatus: .online,
        cachedMembers: [:],
        cachedChannels: [groupDM],
        cachedMessages: [],
        cachedGuildRoles: [:]
    ))
    #expect(cached == recipient)
}

@Test func `ID only typing uses guild and message caches without fabricating unknown users`() throws {
    let payload = try JSONDecoder().decode(
        TypingStartDTO.self,
        from: Data(#"{"channel_id":"200","guild_id":"100","user_id":"5","timestamp":1784100000}"#.utf8)
    )
    let cachedUser = User(id: UserID(rawValue: 5), username: "cached", displayName: "Cached Member")
    let member = Member(user: cachedUser, roleName: "Member", status: .online)
    let fromGuild = DiscordTypingEventResolver.resolve(.init(
        typing: payload,
        userID: cachedUser.id,
        currentUser: nil,
        currentStatus: .online,
        cachedMembers: [GuildID(rawValue: 100): [member]],
        cachedChannels: [],
        cachedMessages: [],
        cachedGuildRoles: [:]
    ))
    #expect(fromGuild == cachedUser)

    let message = Message(
        id: MessageID(rawValue: 9),
        channelID: ChannelID(rawValue: 200),
        author: cachedUser,
        content: "cached"
    )
    let fromMessage = DiscordTypingEventResolver.resolve(.init(
        typing: payload,
        userID: cachedUser.id,
        currentUser: nil,
        currentStatus: .online,
        cachedMembers: [:],
        cachedChannels: [],
        cachedMessages: [message],
        cachedGuildRoles: [:]
    ))
    #expect(fromMessage == cachedUser)

    #expect(DiscordTypingEventResolver.resolve(.init(
        typing: payload,
        userID: cachedUser.id,
        currentUser: nil,
        currentStatus: .online,
        cachedMembers: [:],
        cachedChannels: [],
        cachedMessages: [],
        cachedGuildRoles: [:]
    )) == nil)
}
