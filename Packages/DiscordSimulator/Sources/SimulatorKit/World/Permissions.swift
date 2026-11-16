import Foundation

/// Discord permission bits (the documented, stable values).
public struct Permissions: OptionSet, Sendable, Hashable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let createInstantInvite = Permissions(rawValue: 1 << 0)
    public static let kickMembers = Permissions(rawValue: 1 << 1)
    public static let banMembers = Permissions(rawValue: 1 << 2)
    public static let administrator = Permissions(rawValue: 1 << 3)
    public static let manageChannels = Permissions(rawValue: 1 << 4)
    public static let manageGuild = Permissions(rawValue: 1 << 5)
    public static let addReactions = Permissions(rawValue: 1 << 6)
    public static let viewAuditLog = Permissions(rawValue: 1 << 7)
    public static let prioritySpeaker = Permissions(rawValue: 1 << 8)
    public static let stream = Permissions(rawValue: 1 << 9)
    public static let viewChannel = Permissions(rawValue: 1 << 10)
    public static let sendMessages = Permissions(rawValue: 1 << 11)
    public static let sendTTSMessages = Permissions(rawValue: 1 << 12)
    public static let manageMessages = Permissions(rawValue: 1 << 13)
    public static let embedLinks = Permissions(rawValue: 1 << 14)
    public static let attachFiles = Permissions(rawValue: 1 << 15)
    public static let readMessageHistory = Permissions(rawValue: 1 << 16)
    public static let mentionEveryone = Permissions(rawValue: 1 << 17)
    public static let useExternalEmojis = Permissions(rawValue: 1 << 18)
    public static let connect = Permissions(rawValue: 1 << 20)
    public static let speak = Permissions(rawValue: 1 << 21)
    public static let changeNickname = Permissions(rawValue: 1 << 26)
    public static let manageNicknames = Permissions(rawValue: 1 << 27)
    public static let manageRoles = Permissions(rawValue: 1 << 28)
    public static let manageWebhooks = Permissions(rawValue: 1 << 29)
    public static let manageGuildExpressions = Permissions(rawValue: 1 << 30)
    public static let useApplicationCommands = Permissions(rawValue: 1 << 31)
    public static let manageThreads = Permissions(rawValue: 1 << 34)
    public static let createPublicThreads = Permissions(rawValue: 1 << 35)
    public static let createPrivateThreads = Permissions(rawValue: 1 << 36)
    public static let useExternalStickers = Permissions(rawValue: 1 << 37)
    public static let sendMessagesInThreads = Permissions(rawValue: 1 << 38)
    public static let moderateMembers = Permissions(rawValue: 1 << 40)
    public static let sendVoiceMessages = Permissions(rawValue: 1 << 46)
    public static let sendPolls = Permissions(rawValue: 1 << 49)

    public static let all = Permissions(rawValue: (1 << 51) - 1)

    /// The default @everyone grant of a newly created server.
    public static let everyoneDefault: Permissions = [
        .createInstantInvite, .addReactions, .stream, .viewChannel, .sendMessages, .embedLinks, .attachFiles,
        .readMessageHistory, .mentionEveryone, .useExternalEmojis, .connect, .speak, .changeNickname,
        .useApplicationCommands, .createPublicThreads, .createPrivateThreads, .useExternalStickers,
        .sendMessagesInThreads, .sendVoiceMessages, .sendPolls,
    ]

    public static let moderator: Permissions = [
        .kickMembers, .banMembers, .manageMessages, .manageThreads, .moderateMembers, .manageNicknames, .viewAuditLog,
    ]

    public var wireString: String { String(rawValue) }
}

public extension Guild {
    /// Discord's permission algorithm: base from roles (owner and administrator
    /// get everything), then channel overwrites for @everyone, roles, member.
    func permissions(of userID: Snowflake, in channel: Channel? = nil) -> Permissions {
        if userID == ownerID { return .all }
        guard let member = members[userID] else { return [] }
        var base = everyoneRole?.permissions ?? []
        for role in roles where member.roles.contains(role.id) { base.formUnion(role.permissions) }
        if base.contains(.administrator) { return .all }
        guard let channel else { return base }
        var result = base
        if let everyone = channel.overwrites.first(where: { $0.kind == .role && $0.id == id }) {
            result.subtract(everyone.deny)
            result.formUnion(everyone.allow)
        }
        var allow: Permissions = [], deny: Permissions = []
        for overwrite in channel.overwrites where overwrite.kind == .role && member.roles.contains(overwrite.id) {
            allow.formUnion(overwrite.allow)
            deny.formUnion(overwrite.deny)
        }
        result.subtract(deny)
        result.formUnion(allow)
        if let own = channel.overwrites.first(where: { $0.kind == .member && $0.id == userID }) {
            result.subtract(own.deny)
            result.formUnion(own.allow)
        }
        if !result.contains(.viewChannel) { return [] }
        return result
    }
}
