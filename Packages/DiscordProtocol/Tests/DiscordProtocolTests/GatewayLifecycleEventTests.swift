@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

@Suite(.serialized)
struct GatewayLifecycleEventTests {
    private struct FeatureCase {
        var name: String
        var kind: GatewayFeatureEvent.Kind
        var operation: GatewayFeatureEvent.Operation
    }

    private let guildID = GuildID(rawValue: 100)
    private let textChannelID = ChannelID(rawValue: 200)
    private let forumChannelID = ChannelID(rawValue: 201)
    private let voiceChannelID = ChannelID(rawValue: 202)
    private let currentUserID = UserID(rawValue: 1)

    @Test func `guild channel role member and user lifecycle reconciles cached state`() async {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "READY",
            data: .object([
                "user": user(id: "1", username: "before", globalName: "Before"),
                "guilds": .array([]),
            ])
        )

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE",
            data: guildCreatePayload(includesUnavailable: false)
        )
        #expect(await provider.cachedGuildForTesting(guildID: guildID)?.name == "Lifecycle Guild")
        #expect(await provider.cachedGuildsForTesting().map(\.id) == [guildID])
        #expect(await provider.cachedChannelForTesting(channelID: textChannelID)?.category == "Info")
        #expect(
            await provider.cachedChannelForTesting(channelID: textChannelID)?
                .permissionOverwrites?.first?.allow == 1_024
        )
        #expect(await provider.cachedGuildRolesForTesting(guildID: guildID).count == 2)
        #expect(await provider.cachedMembersForTesting(guildID: guildID).first?.roleName == "Reader")

        await verifyCreateDispatches(on: provider)

        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_UPDATE",
            data: channel(
                id: "200", type: 0, name: "renamed", parentID: "299",
                overwrites: [["id": .string("100"), "type": .number(0),
                              "allow": .string("2048"), "deny": .string("1024")]]
            )
        )
        let updatedChannel = await provider.cachedChannelForTesting(channelID: textChannelID)
        #expect(updatedChannel?.name == "renamed")
        #expect(updatedChannel?.permissionOverwrites?.first?.allow == 2_048)
        #expect(updatedChannel?.permissionOverwrites?.first?.deny == 1_024)

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_ROLE_UPDATE",
            data: .object([
                "guild_id": .string("100"),
                "role": role(id: "101", name: "Updated Reader", position: 3, hoist: true),
            ])
        )
        #expect(
            await provider.cachedGuildRolesForTesting(guildID: guildID)
                .first(where: { $0.id == RoleID(rawValue: 101) })?.name == "Updated Reader"
        )
        #expect(await provider.cachedMembersForTesting(guildID: guildID).first?.roleName == "Updated Reader")

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_UPDATE",
            data: .object([
                "guild_id": .string("100"),
                "user": user(id: "1", username: "before", globalName: "Before"),
                "nick": .string("Guild Nick"),
                "roles": .array([.string("101")]),
            ])
        )
        #expect(await provider.cachedMembersForTesting(guildID: guildID).first?.user.displayName == "Guild Nick")

        await provider.receiveGatewayDispatchForTesting(
            name: "USER_UPDATE",
            data: user(id: "1", username: "after", globalName: "After")
        )
        #expect(await provider.currentUserForTesting()?.username == "after")
        let memberAfterUserUpdate = await provider.cachedMembersForTesting(guildID: guildID).first
        #expect(memberAfterUserUpdate?.user.displayName == "Guild Nick")
        #expect(memberAfterUserUpdate?.globalDisplayName == "After")

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_ROLE_DELETE",
            data: .object(["guild_id": .string("100"), "role_id": .string("101")])
        )
        #expect(await provider.cachedGuildRolesForTesting(guildID: guildID).count == 1)
        #expect(await provider.cachedMembersForTesting(guildID: guildID).first?.roleIDs.isEmpty == true)

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_REMOVE",
            data: .object([
                "guild_id": .string("100"),
                "user": user(id: "1", username: "after", globalName: "After"),
            ])
        )
        #expect(await provider.cachedMembersForTesting(guildID: guildID).isEmpty)
    }

    @Test func `guild unavailable differs from leaving and create adds a new guild`() async {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(name: "GUILD_CREATE", data: guildCreatePayload())

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_UPDATE",
            data: .object([
                "id": .string("100"), "name": .string("Renamed Guild"),
                "rules_channel_id": .string("200"),
            ])
        )
        #expect(await provider.cachedGuildForTesting(guildID: guildID)?.name == "Renamed Guild")
        #expect(await provider.cachedGuildForTesting(guildID: guildID)?.rulesChannelID == textChannelID)

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_DELETE",
            data: .object(["id": .string("100"), "unavailable": .bool(true)])
        )
        #expect(await provider.cachedGuildForTesting(guildID: guildID)?.isUnavailable == true)
        #expect(await provider.cachedGuildsForTesting().map(\.id) == [guildID])

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE",
            data: guildCreatePayload(includesUnavailable: false)
        )
        #expect(await provider.cachedGuildForTesting(guildID: guildID)?.isUnavailable == false)

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_DELETE",
            data: .object(["id": .string("100")])
        )
        #expect(await provider.cachedGuildForTesting(guildID: guildID) == nil)
        #expect(await provider.cachedGuildsForTesting().isEmpty)
        #expect(await provider.cachedChannelForTesting(channelID: textChannelID) == nil)
    }

    @Test func `pins bulk deletes thread counts and voice metadata reconcile`() async {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "READY",
            data: .object([
                "user": user(id: "1", username: "current", globalName: "Current"),
                "guilds": .array([]),
            ])
        )
        await provider.receiveGatewayDispatchForTesting(name: "GUILD_CREATE", data: guildCreatePayload())

        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_PINS_UPDATE",
            data: .object([
                "guild_id": .string("100"), "channel_id": .string("200"),
                "last_pin_timestamp": .string("2026-08-03T12:00:00.000000+00:00"),
            ])
        )
        #expect(await provider.cachedChannelForTesting(channelID: textChannelID)?.lastPinTimestamp != nil)

        await provider.receiveGatewayDispatchForTesting(
            name: "VOICE_CHANNEL_STATUS_UPDATE",
            data: .object([
                "guild_id": .string("100"), "id": .string("202"),
                "status": .string("Office hours"),
            ])
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "VOICE_CHANNEL_START_TIME_UPDATE",
            data: .object([
                "guild_id": .string("100"), "id": .string("202"),
                "voice_start_time": .number(1_775_390_400),
            ])
        )
        let voice = await provider.cachedChannelForTesting(channelID: voiceChannelID)
        #expect(voice?.voiceStatus == "Office hours")
        #expect(voice?.voiceStartTime != nil)

        await provider.receiveGatewayDispatchForTesting(
            name: "THREAD_CREATE",
            data: .object([
                "id": .string("250"), "guild_id": .string("100"),
                "parent_id": .string("201"), "type": .number(11),
                "name": .string("A thread"), "member_count": .number(2),
            ])
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "THREAD_MEMBERS_UPDATE",
            data: .object([
                "id": .string("250"), "guild_id": .string("100"),
                "member_count": .number(7),
                "added_members": .array([
                    .object([
                        "id": .string("250"), "user_id": .string("1"),
                        "flags": .number(4), "muted": .bool(false),
                    ])
                ]),
                "removed_member_ids": .array([]),
            ])
        )
        #expect(
            await provider.cachedForumPostForTesting(threadID: ChannelID(rawValue: 250))?
                .thread.memberCount == 7
        )
        #expect(
            await provider.cachedForumPostForTesting(threadID: ChannelID(rawValue: 250))?
                .thread.notificationSettings?.flags == 4
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "THREAD_MEMBERS_UPDATE",
            data: .object([
                "id": .string("250"), "guild_id": .string("100"),
                "member_count": .number(6), "added_members": .array([]),
                "removed_member_ids": .array([.string("1")]),
            ])
        )
        #expect(
            await provider.cachedForumPostForTesting(threadID: ChannelID(rawValue: 250))?
                .thread.notificationSettings == nil
        )

        let author = User(id: currentUserID, username: "author", displayName: "Author")
        let firstMessageID = MessageID(rawValue: 301)
        let secondMessageID = MessageID(rawValue: 302)
        await provider.seedMessageForTesting(
            Message(id: firstMessageID, channelID: textChannelID, author: author, content: "one")
        )
        await provider.seedMessageForTesting(
            Message(id: secondMessageID, channelID: textChannelID, author: author, content: "two")
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "MESSAGE_DELETE_BULK",
            data: .object([
                "channel_id": .string("200"),
                "ids": .array([.string("301"), .string("302")]),
            ])
        )
        #expect(await provider.cachedMessageForTesting(messageID: firstMessageID) == nil)
        #expect(await provider.cachedMessageForTesting(messageID: secondMessageID) == nil)

        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_DELETE",
            data: .object(["id": .string("200"), "guild_id": .string("100")])
        )
        #expect(await provider.cachedChannelForTesting(channelID: textChannelID) == nil)
    }

    @Test func `rate limited event records bounded gateway cooldown`() async {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "RATE_LIMITED",
            data: .object([
                "opcode": .number(8), "retry_after": .number(30),
                "meta": .object(["guild_id": .string("100")]),
            ])
        )
        #expect(await provider.gatewayOpcodeIsRateLimitedForTesting(8))
        #expect(!(await provider.gatewayOpcodeIsRateLimitedForTesting(37)))
    }

    @Test func `dispatch reconciliation has zero HTTP request budget`() async {
        GatewayDispatchCountingURLProtocol.requestCount = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayDispatchCountingURLProtocol.self]
        let provider = makeProvider(session: URLSession(configuration: configuration))

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE", data: guildCreatePayload()
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_UPDATE",
            data: channel(id: "200", type: 0, name: "renamed")
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_UPDATE",
            data: .object([
                "guild_id": .string("100"),
                "user": user(id: "1", username: "current", globalName: "Current"),
                "roles": .array([.string("101")]),
            ])
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_SCHEDULED_EVENT_UPDATE",
            data: .object(["id": .string("900"), "guild_id": .string("100")])
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_DELETE", data: .object(["id": .string("100")])
        )

        #expect(GatewayDispatchCountingURLProtocol.requestCount == 0)
    }

    @Test func `unsupported feature families cross the typed gateway boundary`() async {
        let provider = makeProvider()
        let events = await provider.eventStream()
        var iterator = events.makeAsyncIterator()
        let cases: [FeatureCase] = [
            .init(name: "GUILD_SOUNDBOARD_SOUND_CREATE", kind: .soundboard, operation: .create),
            .init(name: "GUILD_SOUNDBOARD_SOUND_UPDATE", kind: .soundboard, operation: .update),
            .init(name: "GUILD_SOUNDBOARD_SOUND_DELETE", kind: .soundboard, operation: .delete),
            .init(name: "GUILD_SOUNDBOARD_SOUNDS_UPDATE", kind: .soundboard, operation: .replace),
            .init(name: "GUILD_SCHEDULED_EVENT_CREATE", kind: .scheduledEvent, operation: .create),
            .init(name: "GUILD_SCHEDULED_EVENT_UPDATE", kind: .scheduledEvent, operation: .update),
            .init(name: "GUILD_SCHEDULED_EVENT_DELETE", kind: .scheduledEvent, operation: .delete),
            .init(name: "GUILD_SCHEDULED_EVENT_USER_ADD", kind: .scheduledEvent, operation: .add),
            .init(name: "GUILD_SCHEDULED_EVENT_USER_REMOVE", kind: .scheduledEvent, operation: .remove),
            .init(name: "GUILD_SCHEDULED_EVENT_EXCEPTION_CREATE", kind: .scheduledEvent, operation: .create),
            .init(name: "GUILD_SCHEDULED_EVENT_EXCEPTION_UPDATE", kind: .scheduledEvent, operation: .update),
            .init(name: "GUILD_SCHEDULED_EVENT_EXCEPTION_DELETE", kind: .scheduledEvent, operation: .delete),
            .init(name: "GUILD_SCHEDULED_EVENT_EXCEPTIONS_DELETE", kind: .scheduledEvent, operation: .delete),
            .init(name: "STAGE_INSTANCE_CREATE", kind: .stageInstance, operation: .create),
            .init(name: "STAGE_INSTANCE_UPDATE", kind: .stageInstance, operation: .update),
            .init(name: "STAGE_INSTANCE_DELETE", kind: .stageInstance, operation: .delete),
            .init(name: "MESSAGE_POLL_VOTE_ADD", kind: .pollVote, operation: .add),
            .init(name: "MESSAGE_POLL_VOTE_REMOVE", kind: .pollVote, operation: .remove),
            .init(name: "INTEGRATION_CREATE", kind: .integration, operation: .create),
            .init(name: "INTEGRATION_UPDATE", kind: .integration, operation: .update),
            .init(name: "INTEGRATION_DELETE", kind: .integration, operation: .delete),
            .init(name: "GUILD_INTEGRATIONS_UPDATE", kind: .integration, operation: .replace),
            .init(name: "WEBHOOKS_UPDATE", kind: .webhook, operation: .update),
            .init(name: "AUTO_MODERATION_RULE_CREATE", kind: .autoModeration, operation: .create),
            .init(name: "AUTO_MODERATION_RULE_UPDATE", kind: .autoModeration, operation: .update),
            .init(name: "AUTO_MODERATION_RULE_DELETE", kind: .autoModeration, operation: .delete),
            .init(name: "AUTO_MODERATION_ACTION_EXECUTION", kind: .autoModeration, operation: .execute),
            .init(name: "AUTO_MODERATION_MENTION_RAID_DETECTION", kind: .autoModeration, operation: .execute),
            .init(name: "ENTITLEMENT_CREATE", kind: .entitlement, operation: .create),
            .init(name: "ENTITLEMENT_UPDATE", kind: .entitlement, operation: .update),
            .init(name: "ENTITLEMENT_DELETE", kind: .entitlement, operation: .delete),
            .init(name: "SUBSCRIPTION_CREATE", kind: .subscription, operation: .create),
            .init(name: "SUBSCRIPTION_UPDATE", kind: .subscription, operation: .update),
            .init(name: "SUBSCRIPTION_DELETE", kind: .subscription, operation: .delete),
        ]

        for featureCase in cases {
            var payload: [String: JSONValue] = [
                "id": .string("900"), "guild_id": .string("100"),
                "channel_id": .string("200"), "user_id": .string("1"),
            ]
            if featureCase.kind == .pollVote { payload["answer_id"] = .number(3) }
            await provider.receiveGatewayDispatchForTesting(
                name: featureCase.name,
                data: .object(payload)
            )
            guard case .gatewayFeatureChanged(let event) = await iterator.next() else {
                Issue.record("\(featureCase.name) did not publish a typed feature event")
                continue
            }
            #expect(event.kind == featureCase.kind)
            #expect(event.operation == featureCase.operation)
            #expect(event.guildID == guildID)
            #expect(event.channelID == textChannelID)
            #expect(event.entityID == "900")
            #expect(event.relatedID == (featureCase.kind == .pollVote ? "3" : nil))
            #expect(event.userID == currentUserID)
        }

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_STICKERS_UPDATE",
            data: .object([
                "guild_id": .string("100"),
                "stickers": .array([
                    .object([
                        "id": .string("901"), "name": .string("Sakura"),
                        "format_type": .number(1), "guild_id": .string("100"),
                    ])
                ]),
            ])
        )
        guard case .gatewayFeatureChanged(let stickerEvent) = await iterator.next() else {
            Issue.record("GUILD_STICKERS_UPDATE did not publish a typed feature event")
            return
        }
        #expect(stickerEvent.kind == .stickers)
        #expect(stickerEvent.operation == .replace)
        #expect(await provider.cachedGuildStickersForTesting(guildID: guildID).first?.name == "Sakura")
    }

    private func verifyCreateDispatches(on provider: DiscordRESTProvider) async {
        let createdChannelID = ChannelID(rawValue: 203)
        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_CREATE",
            data: channel(id: "203", type: 0, name: "created")
        )
        #expect(await provider.cachedChannelForTesting(channelID: createdChannelID)?.name == "created")

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_ROLE_CREATE",
            data: .object([
                "guild_id": .string("100"),
                "role": role(id: "102", name: "New Role", position: 1, hoist: true),
            ])
        )
        #expect(await provider.cachedGuildRolesForTesting(guildID: guildID).count == 3)
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_ADD",
            data: .object([
                "guild_id": .string("100"),
                "user": user(id: "2", username: "added", globalName: "Added"),
                "roles": .array([.string("102")]),
            ])
        )
        #expect(await provider.cachedMembersForTesting(guildID: guildID).count == 2)
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_REMOVE",
            data: .object([
                "guild_id": .string("100"),
                "user": user(id: "2", username: "added", globalName: "Added"),
            ])
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_ROLE_DELETE",
            data: .object(["guild_id": .string("100"), "role_id": .string("102")])
        )
        #expect(await provider.cachedMembersForTesting(guildID: guildID).count == 1)
        #expect(await provider.cachedGuildRolesForTesting(guildID: guildID).count == 2)
    }

    private func makeProvider(
        session: URLSession = URLSession(configuration: .ephemeral)
    ) -> DiscordRESTProvider {
        DiscordRESTProvider(
            credentials: GatewayLifecycleCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: session
        )
    }

    private func guildCreatePayload(includesUnavailable: Bool = true) -> JSONValue {
        var payload: [String: JSONValue] = [
            "id": .string("100"), "name": .string("Lifecycle Guild"),
            "permissions": .string("1024"),
            "channels": .array([
                channel(id: "299", type: 4, name: "Info", position: 0),
                channel(
                    id: "200", type: 0, name: "general", parentID: "299",
                    overwrites: [["id": .string("100"), "type": .number(0),
                                  "allow": .string("1024"), "deny": .string("0")]]
                ),
                channel(id: "201", type: 15, name: "forum", position: 2),
                channel(id: "202", type: 2, name: "Voice", position: 3),
            ]),
            "roles": .array([
                role(id: "100", name: "@everyone", position: 0, hoist: false),
                role(id: "101", name: "Reader", position: 2, hoist: true),
            ]),
            "members": .array([
                .object([
                    "user": user(id: "1", username: "before", globalName: "Before"),
                    "roles": .array([.string("101")]),
                ])
            ]),
            "threads": .array([]), "voice_states": .array([]), "emojis": .array([]),
        ]
        if includesUnavailable { payload["unavailable"] = .bool(false) }
        return .object(payload)
    }

    private func channel(
        id: String, type: Int, name: String, parentID: String? = nil,
        position: Int = 1, overwrites: [[String: JSONValue]] = []
    ) -> JSONValue {
        var value: [String: JSONValue] = [
            "id": .string(id), "guild_id": .string("100"),
            "type": .number(Double(type)), "name": .string(name),
            "position": .number(Double(position)),
            "permission_overwrites": .array(overwrites.map(JSONValue.object)),
        ]
        if let parentID { value["parent_id"] = .string(parentID) }
        return .object(value)
    }

    private func role(id: String, name: String, position: Int, hoist: Bool) -> JSONValue {
        .object([
            "id": .string(id), "name": .string(name),
            "position": .number(Double(position)), "hoist": .bool(hoist),
            "permissions": .string("1024"),
        ])
    }

    private func user(id: String, username: String, globalName: String) -> JSONValue {
        .object([
            "id": .string(id), "username": .string(username),
            "global_name": .string(globalName),
        ])
    }
}

private actor GatewayLifecycleCredentialStore: CredentialStore {
    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        CredentialHandle(accountID: accountID)
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        Data("unused".utf8)
    }

    func remove(_ handle: CredentialHandle) async throws {}
    func handles() async throws -> [CredentialHandle] { [] }
}

private final class GatewayDispatchCountingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestCount = 0

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1
        client?.urlProtocol(
            self,
            didFailWithError: URLError(.dataNotAllowed)
        )
    }

    override func stopLoading() {}
}
