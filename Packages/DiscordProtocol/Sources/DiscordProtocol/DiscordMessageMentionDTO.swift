import Foundation
import SakuraCordModels

struct MessageMentionDTO: Decodable {
    private struct PartialMemberDTO: Decodable {
        var nick: String?
        var avatar: String?
    }

    private var user: UserDTO
    private var member: PartialMemberDTO?

    private enum CodingKeys: String, CodingKey { case member }

    init(from decoder: Decoder) throws {
        user = try UserDTO(from: decoder)
        member = try decoder.container(keyedBy: CodingKeys.self)
            .decodeIfPresent(PartialMemberDTO.self, forKey: .member)
    }

    func domain(guildID: GuildID?) throws -> User {
        var value = try user.domain()
        if let nickname = member?.nick?.trimmingCharacters(in: .whitespacesAndNewlines),
           !nickname.isEmpty
        {
            value.displayName = nickname
        }
        if let guildID, let avatarHash = member?.avatar,
           let guildAvatarURL = DiscordCDN.guildMemberAvatar(guildID, userID: value.id, hash: avatarHash)
        {
            value.avatarURL = guildAvatarURL
        }
        return value
    }

    var searchIndexUser: UserDTO { user }
}
