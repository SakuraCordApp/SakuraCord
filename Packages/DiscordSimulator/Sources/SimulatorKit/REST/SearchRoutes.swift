import Foundation

/// Direct-message search (`POST /users/@me/messages/search/tabs`), paged by a timestamp cursor.
enum SearchRoutes {
    static func register(into routes: inout [String: RouteHandler]) {
        routes["POST /api/v9/users/@me/messages/search/tabs"] = { context in
            .json(try await context.world.searchPrivateChannels(try context.json, viewer: context.userID))
        }
    }
}

extension World {
    func searchPrivateChannels(_ body: JSON, viewer: Snowflake) throws -> JSON {
        let tab = body["tabs"]?["messages"] ?? .object(JSONObject())
        let requested = (body["channel_ids"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(Snowflake.init) }
        let scope = requested.isEmpty ? openPrivateChannels[viewer] ?? [] : requested
        var searched: [Channel] = []
        for id in scope {
            let channel = try channel(id)
            guard channel.type.isPrivate, canView(viewer, channel) else { throw WorldError.missingAccess }
            searched.append(channel)
        }
        let text = tab["content"]?.stringValue?.lowercased() ?? ""
        let authors = Set((tab["author_id"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(Snowflake.init) })
        let cursor = tab["cursor"]?["timestamp"]?.stringValue.flatMap(Snowflake.init)
        let ascending = tab["sort_order"]?.stringValue == "asc"
        var hits = searched.flatMap(\.messages).filter { message in
            (text.isEmpty || message.content.lowercased().contains(text)) && (authors.isEmpty || authors.contains(message.authorID))
        }
        hits.sort { ascending ? $0.id < $1.id : $0.id > $1.id }
        let total = hits.count
        if let cursor { hits = hits.filter { ascending ? $0.id > cursor : $0.id < cursor } }
        let offset = Int(tab["offset"]?.intValue ?? 0)
        let page = Array(hits.dropFirst(offset).prefix(Int(tab["limit"]?.intValue ?? 25)))
        var result = JSONObject([
            ("messages", .array(page.map { .array([renderMessage($0, viewer: viewer).merging(["hit": true])]) })),
            ("channels", .array(searched.filter { channel in page.contains { $0.channelID == channel.id } }.map { renderChannel($0, viewer: viewer) })),
            ("total_results", .int(total)), ("time_spent_ms", 12),
        ])
        if let last = page.last { result["cursor"] = .object(JSONObject([("timestamp", last.id.json), ("type", "timestamp")])) }
        return .object(JSONObject([
            ("analytics_id", .string(nextHash())), ("doing_deep_historical_index", false),
            ("tabs", .object(JSONObject([("messages", .object(result))]))),
        ]))
    }
}
