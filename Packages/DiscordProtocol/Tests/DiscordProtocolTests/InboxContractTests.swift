import Foundation
import SakuraCordModels
import Testing
@testable import DiscordProtocol

struct InboxContractTests {
    @Test func `mentions preserve the raw page cursor when a message cannot decode`() async throws {
        let provider = stubbedProvider(InboxContractURLProtocol.self, token: "inbox-contract", accountID: "inbox-contract")
        let page = try await provider.inboxMentions(
            InboxMentionQuery(guildID: GuildID(rawValue: 100), includesRoles: false, includesEveryone: true),
            before: MessageID(rawValue: 500)
        )
        #expect(page.messages.count == 24)
        #expect(page.hasMore)
        #expect(page.threads.first?.name == "Mention thread")
        #expect(page.messages.first?.guildID == GuildID(rawValue: 100))
        #expect(page.nextBefore == MessageID(rawValue: 276))
        try await provider.dismissInboxMention(MessageID(rawValue: 300))
    }

    @Test func `inbox protobuf patches preserve unknown siblings and channel settings`() throws {
        let initial = Data([0x12, 4, 8, 1, 16, 1, 0x78, 7])
        let first = DiscordInboxSettingsProto.updatingCollapsed(true, channelID: ChannelID(rawValue: 200), guildID: GuildID(rawValue: 100), in: initial)
        let merged = DiscordSettingsProto.mergingPartialFrecencySettings(first, into: initial)
        let second = DiscordInboxSettingsProto.updatingCollapsed(true, channelID: ChannelID(rawValue: 201), guildID: GuildID(rawValue: 100), in: merged)
        let third = DiscordInboxSettingsProto.updatingCollapsed(false, channelID: ChannelID(rawValue: 200), guildID: GuildID(rawValue: 100), in: second)
        #expect(DiscordInboxSettingsProto.settings(in: third).collapsedChannelIDs == [ChannelID(rawValue: 201)])
        let tab = DiscordInboxSettingsProto.updatingTab(.unread, in: merged)
        #expect(tab == Data([0x12, 4, 16, 1, 8, 2]))
        let complete = DiscordSettingsProto.mergingPartialFrecencySettings(tab, into: merged)
        #expect(complete.contains(7))
        #expect(DiscordInboxSettingsProto.settings(in: complete).tab == .unread)
        #expect(DiscordInboxSettingsProto.settings(in: complete).collapsedChannelIDs == [ChannelID(rawValue: 200)])
    }

    @Test func `gateway mention dismissal is independent of a channel read acknowledgement`() async throws {
        let provider = stubbedProvider(InboxContractURLProtocol.self, token: "inbox-contract", accountID: "inbox-contract")
        let pair = SessionEventBuffer<ClientEvent>(overflowEvent: .connectionChanged(.disconnected))
        await provider.installInboxTestEvents(pair)
        _ = await provider.handleGatewayMessageEvent(name: "RECENT_MENTION_DELETE", body: .object(["message_id": .string("300")]))
        pair.finish()
        var received: [ClientEvent] = []
        for await event in pair.stream { received.append(event) }
        #expect(received.count == 1)
        guard case .inboxMentionDismissed(MessageID(rawValue: 300)) = received.first else {
            Issue.record("Mention dismissal must not produce channel read state")
            return
        }
    }

    @Test func `event acknowledgements and interest use their distinct captured routes`() async throws {
        let provider = stubbedProvider(InboxContractURLProtocol.self, token: "inbox-contract", accountID: "inbox-contract")
        let guildID = GuildID(rawValue: 100)
        let eventID = ScheduledEventID(rawValue: 500)
        let event = InboxScheduledEvent(id: eventID, guildID: guildID, name: "Fixture", startTime: .now)
        try await provider.acknowledgeInboxEvents(in: guildID, through: eventID)
        #expect(try await provider.inboxEventInterests(in: guildID) == [eventID])
        try await provider.setInboxEventInterested(true, event: event)
        try await provider.setInboxEventInterested(false, event: event)
        try await provider.acknowledgeBulk([
            BulkReadStateAcknowledgement(channelID: ChannelID(rawValue: 100), messageID: MessageID(rawValue: 500), readStateType: 1),
            BulkReadStateAcknowledgement(channelID: ChannelID(rawValue: 200), messageID: MessageID(rawValue: 300))
        ])
    }

    @Test func `READY event read states use last acked ID and badge count rather than channel fields`() async throws {
        let provider = stubbedProvider(InboxContractURLProtocol.self, token: "inbox-contract", accountID: "inbox-contract")
        let ready = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"guilds":[],"read_state":{"version":17444,"entries":[
          {"id":"100","read_state_type":1,"last_acked_id":"500","badge_count":2},
          {"id":"200","last_message_id":"300","mention_count":9}
        ]}}
        """#.utf8))
        await provider.applyReadyInboxEvents(ready)
        let state = await provider.inboxScheduledEvents
        #expect(state.readStates[GuildID(rawValue: 100)] == InboxEventReadState(
            lastAcknowledgedID: ScheduledEventID(rawValue: 500), mentionCount: 2, version: 17444
        ))
        #expect(state.readStates[GuildID(rawValue: 200)] == nil)
    }

    @Test(arguments: [false, true])
    func `fresh Inbox forum pages cannot complete from a partial cache`(fails: Bool) async throws {
        let provider = stubbedProvider(InboxContractURLProtocol.self, token: "inbox-contract", accountID: "inbox-contract")
        let channel = Channel(id: ChannelID(rawValue: fails ? 401 : 400), guildID: GuildID(rawValue: 100), name: "Forum", kind: .forum)
        let cached = ForumPost(thread: MessageThreadSummary(id: ChannelID(rawValue: 410), guildID: channel.guildID, parentID: channel.id, name: "Already read"))
        await provider.seedForumChannelForTesting(channel, posts: [cached])
        do {
            let page = try await provider.forumPosts(in: channel.id, query: ForumPostQuery(sortOrder: .creationDate, requiresFreshPage: true))
            #expect(!fails, "A failed request must not turn cached posts into a complete Inbox page")
            #expect(page.posts.contains { $0.id == ChannelID(rawValue: 420) })
            #expect(page.hasMore)
            #expect(page.nextOffset == 1)
        } catch {
            #expect(fails)
        }
        await provider.disconnect()
    }
}

private final class InboxContractURLProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let body: Data
        let status: Int
        if url.path == "/api/v9/channels/400/threads/search" {
            body = Data(#"""
            {"threads":[{"id":"420","guild_id":"100","parent_id":"400","type":11,"name":"Unread post",
              "thread_metadata":{"archived":false,"locked":false,"auto_archive_duration":1440}}],"has_more":true}
            """#.utf8)
            status = 200
        } else if url.path == "/api/v9/channels/401/threads/search" {
            body = Data(#"{"message":"Missing Access","code":50001}"#.utf8)
            status = 403
        } else if url.path == "/api/v9/channels/400/post-data" || url.path == "/api/v9/channels/401/post-data" {
            body = Data(#"{"threads":{}}"#.utf8)
            status = 200
        } else if url.path == "/api/v9/guilds/100/ack/1/500" {
            #expect(request.httpMethod == "POST")
            #expect(requestJSON() as? [String: String] == [:])
            body = Data("{}".utf8)
            status = 200
        } else if url.path == "/api/v9/users/@me/scheduled-events" {
            #expect(request.httpMethod == "GET")
            #expect(url.query == "guild_ids=100")
            body = Data(#"[{"guild_scheduled_event_id":"500","user_id":"1","response":1}]"#.utf8)
            status = 200
        } else if url.path == "/api/v9/guilds/100/scheduled-events/500/users/@me" {
            if request.httpMethod == "PUT" {
                #expect(requestJSON() as? [String: Int] == ["response": 1])
            } else {
                #expect(request.httpMethod == "DELETE")
                #expect(request.httpBody == nil)
            }
            body = request.httpMethod == "PUT" ? Data("{}".utf8) : Data()
            status = request.httpMethod == "PUT" ? 200 : 204
        } else if url.path == "/api/v9/read-states/ack-bulk" {
            #expect(request.httpMethod == "POST")
            let values = requestJSON() as? [String: [[String: Any]]]
            #expect(values?["read_states"]?.compactMap { $0["read_state_type"] as? Int } == [1, 0])
            #expect(values?["read_states"]?.compactMap { $0["channel_id"] as? String } == ["100", "200"])
            body = Data()
            status = 204
        } else if request.httpMethod == "GET", url.path == "/api/v9/channels/200" {
            body = Data(#"""
            {"id":"200","guild_id":"100","parent_id":"199","name":"Mention thread","type":11,
             "thread_metadata":{"archived":false,"locked":false,"auto_archive_duration":1440}}
            """#.utf8)
            status = 200
        } else if request.httpMethod == "GET" {
            #expect(url.path == "/api/v9/users/@me/mentions")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") }) == ["limit": "25", "before": "500", "guild_id": "100", "roles": "false", "everyone": "true"])
            let messages = (0 ..< 25).map { index in
                if index == 24 { return "{\"id\":\"276\"}" }
                return """
                {"id":"\(300 - index)","channel_id":"200","author":{"id":"1","username":"actor"},
                "content":"mention","timestamp":"2026-09-20T00:00:00Z"}
                """
            }
            body = Data(("[" + messages.joined(separator: ",") + "]").utf8)
            status = 200
        } else {
            #expect(request.httpMethod == "DELETE")
            #expect(url.path == "/api/v9/users/@me/mentions/300")
            #expect(request.httpBody == nil)
            body = Data()
            status = 204
        }
        respond(status: status, body: body)
    }
    private func requestJSON() -> Any? {
        let data = request.bodyData ?? Data()
        return try? JSONSerialization.jsonObject(with: data)
    }

    override func stopLoading() {}
}

private extension DiscordRESTProvider {
    func installInboxTestEvents(_ value: SessionEventBuffer<ClientEvent>) { continuation = value }
}
