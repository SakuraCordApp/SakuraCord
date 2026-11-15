import Foundation
import SakuraCordModels

struct GuildProfileTagDTO: Decodable {
    var tag: String?
    var badge: String?

    func domain(guildID: GuildID) -> PrimaryGuildIdentity? {
        guard let tag else { return nil }
        return PrimaryGuildIdentity(
            guildID: guildID, tag: tag,
            badgeURL: badge.flatMap { DiscordCDN.guildTagBadge(guildID, hash: $0) }
        )
    }
}
