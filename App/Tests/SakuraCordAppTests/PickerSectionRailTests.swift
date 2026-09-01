import SakuraCordModels
import Testing
@testable import SakuraCord

@Test func `picker guilds follow server rail folders then place current guild first`() {
    let first = Guild(id: GuildID(rawValue: 1), name: "First")
    let second = Guild(id: GuildID(rawValue: 2), name: "Second")
    let current = Guild(id: GuildID(rawValue: 3), name: "Current")
    let unlisted = Guild(id: GuildID(rawValue: 4), name: "Unlisted")
    let guildsByID = Dictionary(uniqueKeysWithValues: [first, second, current].map {
        ($0.id, $0)
    })

    let ordered = PickerSectionGuildOrdering.orderedGuilds(
        railItems: [
            .folder(GuildFolder(id: 10, guildIDs: [second.id, first.id])),
            .guild(current.id),
        ],
        guildsByID: guildsByID,
        fallbackGuilds: [current, unlisted, first, second],
        currentGuildID: current.id
    )

    #expect(ordered.map(\.id) == [current.id, second.id, first.id, unlisted.id])
}

@Test func `soundboard keeps empty guilds so its server rail matches emoji ordering`() {
    let first = Guild(id: GuildID(rawValue: 1), name: "First")
    let current = Guild(id: GuildID(rawValue: 2), name: "Current")
    let third = Guild(id: GuildID(rawValue: 3), name: "Third")
    let guilds = [first, current, third]

    let ordered = SoundboardPickerContentPolicy.guilds(
        railItems: guilds.map { .guild($0.id) },
        guildsByID: Dictionary(uniqueKeysWithValues: guilds.map { ($0.id, $0) }),
        fallbackGuilds: guilds,
        currentGuildID: current.id
    )

    #expect(ordered.map(\.id) == [current.id, first.id, third.id])
}
