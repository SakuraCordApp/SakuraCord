import Foundation

/// A game in Discord's catalogue: what profile game widgets, game search and
/// game profiles look up. The simulated catalogue holds the games people play.
public struct Game: Sendable {
    public var id: Snowflake
    public var name: String
    public var iconHash: String
}

extension World {
    /// Adds a game to the catalogue once, the first time anyone is seen playing it.
    func addGame(named name: String, releasedAt released: Date) {
        guard !games.contains(where: { $0.name == name }) else { return }
        let iconHash = nextHash()
        registerAsset(iconHash)
        games.append(Game(id: nextID(at: released), name: name, iconHash: iconHash))
    }

    func game(_ id: Snowflake) throws -> Game {
        guard let game = games.first(where: { $0.id == id }) else { throw WorldError.unknown("Application", code: 10002) }
        return game
    }

    /// `GET /games?game_ids=…`: the requested games in the order asked; unknown IDs are left out (inferred).
    func renderGames(_ ids: [Snowflake]) -> JSON {
        .array(ids.compactMap { id in games.first { $0.id == id } }.map { game in
            .object(JSONObject([
                ("id", game.id.json), ("name", .string(game.name)), ("aliases", []), ("icon_hash", .string(game.iconHash)),
                ("executables", []), ("third_party_skus", []), ("overlay", false), ("overlay_warn", false),
                ("overlay_compatibility_hook", false), ("overlay_methods", .null), ("hook", true), ("themes", []),
                ("linked_applications", []), ("media", .object(JSONObject())), ("platform_availability", ["desktop"]),
                ("game_flags", 0),
            ]))
        })
    }

    /// `GET /games/autocomplete`: up to ten games, as captured. Names starting with the query rank
    /// before names containing it (inferred ranking).
    func autocompleteGames(_ query: String) -> JSON {
        // Captured: names with a word starting with the query, ranked by popularity rather than by where the
        // word falls ("mine" puts "This War of Mine" first); catalogue order stands in for popularity.
        let needle = query.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let matches = games.filter { game in
            !needle.isEmpty && game.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(needle) }
        }
        return .array(matches.prefix(10).map { game in
            .object(JSONObject([
                ("id", game.id.json), ("name", .string(game.name)),
                ("icon", .object(JSONObject([("type", "hash"), ("value", .string(game.iconHash))]))),
                ("platform_availability", ["desktop"]),
            ]))
        })
    }

    /// The catalogue's games that `userID` or their friends are playing right now.
    func gamesPlayed(around userID: Snowflake) -> [Snowflake] {
        let friends = (relationships[userID] ?? [:]).values.filter { $0.type == .friend }.map(\.userID)
        let playing = Set(([userID] + friends).flatMap { person in
            (presences[person]?.activities ?? []).filter { $0["type"]?.intValue == 0 }.compactMap { $0["name"]?.stringValue }
        })
        return games.filter { playing.contains($0.name) }.map(\.id)
    }
}
