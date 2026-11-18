import Foundation

/// Threads and forum posts: creating, searching and the forum list's post data.
enum ThreadRoutes {
    static func register(into routes: inout [String: RouteHandler]) {
        routes["GET /api/v9/channels/{id}/threads/search"] = { context in
            .json(try await context.world.threadSearch(parentID: try context.id(0), request: context.request, viewer: context.userID))
        }

        routes["POST /api/v9/channels/{id}/messages/{id}/threads"] = { context in
            let body = try context.json
            let thread = try await context.world.createThread(
                in: try context.id(0), from: try context.id(1), name: body["name"]?.stringValue ?? "thread", by: context.userID
            )
            return .json(await context.world.renderThread(thread, viewer: context.userID), status: 201)
        }

        routes["POST /api/v9/channels/{id}/threads"] = { context in
            let (body, files) = try MultipartForm.messageBody(context.request)
            let parentID = try context.id(0)
            let parent = try await context.world.channel(parentID)
            var starter: MessageDraft?
            if let message = body["message"] {
                starter = try await MessageRoutes.draft(from: message, channelID: parentID, files: files, world: context.world,
                                                        uploader: context.userID)
            }
            let thread = try await context.world.createThread(
                in: parentID, from: nil, name: body["name"]?.stringValue ?? "post", by: context.userID,
                type: parent.type == .forum || parent.type == .media ? .publicThread : ChannelType(rawValue: Int(body["type"]?.intValue ?? 11)) ?? .publicThread,
                appliedTags: (body["applied_tags"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(Snowflake.init) },
                starter: starter
            )
            // Forum posts answer with the thread and its starter message nested.
            var response = await context.world.renderThread(thread, viewer: context.userID)
            if starter != nil, let first = thread.messages.first {
                response = response.merging(["message": await context.world.renderMessage(first, viewer: context.userID)])
            }
            return .json(response, status: 201)
        }

        routes["POST /api/v9/channels/{id}/post-data"] = { context in
            let ids = (try context.json["thread_ids"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(Snowflake.init) }
            return .json(await context.world.renderPostData(threadIDs: ids, viewer: context.userID))
        }
    }
}
