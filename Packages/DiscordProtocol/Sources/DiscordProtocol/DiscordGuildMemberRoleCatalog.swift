import SakuraCordModels

struct GuildMemberRoleCatalog {
    struct Entry {
        let sourceIndex: Int
        let dto: GuildRoleDTO
        let domain: GuildRole?
    }

    private let entriesByID: [String: [Entry]]

    init(_ roles: [GuildRoleDTO]) {
        entriesByID = Dictionary(grouping: roles.enumerated().map { index, role in
            Entry(sourceIndex: index, dto: role, domain: role.domain)
        }, by: { $0.dto.id })
    }

    func entries(matching roleIDs: Set<String>) -> [Entry] {
        var entries: [Entry] = []
        entries.reserveCapacity(roleIDs.count)
        for roleID in roleIDs {
            entries.append(contentsOf: entriesByID[roleID] ?? [])
        }
        entries.sort { $0.sourceIndex < $1.sourceIndex }
        return entries
    }
}
