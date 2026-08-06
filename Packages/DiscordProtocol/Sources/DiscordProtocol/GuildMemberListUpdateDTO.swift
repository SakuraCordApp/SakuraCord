struct GuildMemberListUpdateDTO: Decodable {
    struct Group: Decodable {
        var id: String
        var count: Int
    }

    struct Operation: Decodable {
        var op: String
        var range: [Int]?
        var index: Int?
        var items: [Item]?
        var item: Item?
    }

    struct Item: Decodable {
        var member: GuildMemberDTO?
        var presence: GuildPresenceDTO?
    }

    var guildID: String
    var id: String
    var memberCount: Int?
    var onlineCount: Int?
    var ops: [Operation]
    var groups: [Group]?

    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id"
        case id
        case memberCount = "member_count"
        case onlineCount = "online_count"
        case ops
        case groups
    }
}
