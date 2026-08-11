import SakuraCordModels

struct DiscordTypingResolutionInput {
    var typing: TypingStartDTO
    var userID: UserID
    var currentUser: User?
    var currentStatus: PresenceStatus
    var cachedMembers: [GuildID: [Member]]
    var cachedChannels: [Channel]
    var cachedMessages: [Message]
    var cachedGuildRoles: [GuildID: [GuildRoleDTO]]
}

enum DiscordTypingEventResolver {
    static func resolve(_ input: DiscordTypingResolutionInput) -> User? {
        let typing = input.typing
        let userID = input.userID
        let currentUser = input.currentUser
        let currentStatus = input.currentStatus
        let cachedMembers = input.cachedMembers
        let cachedChannels = input.cachedChannels
        let cachedMessages = input.cachedMessages
        let cachedGuildRoles = input.cachedGuildRoles
        let guildID = typing.guildID.flatMap(GuildID.init)
        if let member = typing.member,
           let resolved = try? member.domain(
               currentUserID: currentUser?.id,
               currentStatus: currentStatus,
               guildRoles: guildID.flatMap { cachedGuildRoles[$0] } ?? [],
               guildID: guildID
           ).user
        {
            return resolved
        }
        if let user = typing.user, let resolved = try? user.domain() {
            return resolved
        }
        if let guildID,
           let member = cachedMembers[guildID]?.first(where: { $0.id == userID })
        {
            return member.user
        }
        if let recipient = cachedChannels.lazy
            .flatMap(\.recipients)
            .first(where: { $0.id == userID })
        {
            return recipient
        }
        if let author = cachedMessages.first(where: { $0.author.id == userID })?.author {
            return author
        }
        return currentUser?.id == userID ? currentUser : nil
    }
}
