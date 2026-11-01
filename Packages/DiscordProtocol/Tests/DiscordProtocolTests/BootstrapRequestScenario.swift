@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

func readyWorkspaceReplayEvents(
    untilReadyIn events: AsyncStream<ClientEvent>
) async -> [ClientEvent] {
    var replays: [ClientEvent] = []
    for await event in events {
        if event == .connectionChanged(.ready) {
            return replays
        }
        switch event {
        case .snapshotChanged,
             .readStateSnapshot,
             .notificationModeChanged,
             .notificationSettingsChanged,
             .channelsChanged:
            replays.append(event)
        default:
            break
        }
    }
    return replays
}

struct BootstrapRequestScenario {
    var anonymisesFileNames = false
    var run: Void {
        get async throws {
        RateLimitURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let credentials = TestCredentialStore()
        let socket = ReadyGatewaySocket()
        await socket.push(gatewayMessage(
            op: 10, data: .object(["heartbeat_interval": .number(60_000)])
        ))
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "session_id": .string("request-contract-session"),
                "resume_gateway_url": .string("wss://gateway.discord.gg"),
                "user": .object([
                    "id": .string("1"),
                    "username": .string("tester"),
                    "global_name": .string("Tester"),
                    "avatar": .null,
                ]),
                "guilds": .array([
                    .object([
                        "id": .string("100"),
                        "name": .string("Guild"),
                        "icon": .null,
                        "owner_id": .string("999"),
                        "permissions": .string("1024"),
                        "default_message_notifications": .number(1),
                    ])
                ]),
                "users": .array([
                    .object([
                        "id": .string("2"),
                        "username": .string("maya"),
                        "global_name": .string("Maya"),
                        "avatar": .null,
                    ])
                ]),
                "private_channels": .array([
                    .object([
                        "id": .string("401"),
                        "type": .number(1),
                        "last_message_id": .string("601"),
                        "recipient_ids": .array([.string("2")]),
                    ])
                ]),
            ]),
            sequence: 1,
            eventName: "READY"
        ))
        let provider = DiscordRESTProvider(
            credentials: credentials,
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration),
            gatewayTransport: ReadyGatewayTransport(socket: socket),
            usesEmojiDiskCache: false,
            anonymisesUploadFilenames: { [anonymisesFileNames] in anonymisesFileNames }
        )
        let events = await provider.eventStream()
        let connected = Task { () -> Bool in
            for await event in events {
                if case .connectionChanged(.ready) = event { return true }
            }
            return false
        }

        let snapshot = try await provider.bootstrap()
        #expect(await connected.value)
        #expect(snapshot.currentUser.id == UserID(rawValue: 1))
        #expect(snapshot.guilds.count == 1)
        #expect(snapshot.channels.map(\.id) == [ChannelID(rawValue: 401)])
        #expect(snapshot.channels.first?.name == "Maya")
        #expect(snapshot.channels.first?.recipients.map(\.id) == [
            UserID(rawValue: 2)
        ])
        #expect(snapshot.guildRailItems == [.guild(GuildID(rawValue: 100))])
        #expect(snapshot.guilds.first?.isOwnedByCurrentUser == false)
        #expect(snapshot.guilds.first?.currentUserPermissions == 1024)
        #expect(RateLimitURLProtocol.currentUserRequests == 0)
        #expect(RateLimitURLProtocol.guildListAttempts == 0)
        #expect(RateLimitURLProtocol.privateChannelListRequests == 0)
        #expect(RateLimitURLProtocol.guildChannelRequests == 0)
        #expect(RateLimitURLProtocol.settingsRequestCount == 0)
        #expect(RateLimitURLProtocol.settingsMethod == nil)

        async let firstChannels = provider.channels(in: GuildID(rawValue: 100))
        async let secondChannels = provider.channels(in: GuildID(rawValue: 100))
        let (channels, duplicateChannels) = try await (firstChannels, secondChannels)
        #expect(channels.first?.name == "general")
        #expect(duplicateChannels == channels)
        #expect(channels.first?.category == "CHAT")
        #expect(channels.first?.permissionOverwrites?.isEmpty == true)
        #expect(RateLimitURLProtocol.guildChannelRequests == 1)

        async let firstRoles = provider.roles(in: GuildID(rawValue: 100))
        async let secondRoles = provider.roles(in: GuildID(rawValue: 100))
        let (roles, duplicateRoles) = try await (firstRoles, secondRoles)
        #expect(roles.first { $0.id == RoleID(rawValue: 100) }?.permissions == 1024)
        #expect(duplicateRoles == roles)
        #expect(RateLimitURLProtocol.guildRoleRequests == 1)

        let emojiGuildID = GuildID(rawValue: 987_654_321_012_345_678)
        async let firstEmojis = provider.emojis(in: emojiGuildID)
        async let secondEmojis = provider.emojis(in: emojiGuildID)
        let (emojis, duplicateEmojis) = try await (firstEmojis, secondEmojis)
        #expect(emojis.isEmpty)
        #expect(duplicateEmojis == emojis)
        #expect(RateLimitURLProtocol.guildEmojiRequests == 1)

        async let firstEmojiSettings = provider.emojiUserSettings()
        async let secondEmojiSettings = provider.emojiUserSettings()
        let (emojiSettings, duplicateEmojiSettings) = try await (
            firstEmojiSettings, secondEmojiSettings
        )
        #expect(duplicateEmojiSettings == emojiSettings)
        #expect(RateLimitURLProtocol.emojiSettingsRequests == 1)

        let history = Task {
            try await provider.messages(in: ChannelID(rawValue: 200), before: nil, limit: 50)
        }
        #expect(await eventually { await socket.sentPayload(opcode: 8) != nil })
        let historyGatewayData = try #require(await socket.sentPayload(opcode: 8))
        let historyGatewayPayload = try #require(
            JSONSerialization.jsonObject(with: historyGatewayData) as? [String: Any]
        )
        let historyRequest = try #require(historyGatewayPayload["d"] as? [String: Any])
        #expect(historyRequest["guild_id"] as? String == "100")
        #expect(historyRequest["user_ids"] as? [String] == ["4"])
        #expect(historyRequest["presences"] as? Bool == false)
        #expect(historyRequest["nonce"] == nil)
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "guild_id": .string("100"),
                "members": .array([
                    .object([
                        "user": .object([
                            "id": .string("4"),
                            "username": .string("history-author"),
                            "global_name": .string("History Author"),
                            "avatar": .null
                        ]),
                        "nick": .string("Colored Author"),
                        "roles": .array([.string("101")])
                    ])
                ]),
                "chunk_index": .number(0),
                "chunk_count": .number(1)
            ]),
            sequence: 2,
            eventName: "GUILD_MEMBERS_CHUNK"
        ))
        let historyPage = try await history.value
        let historyMessage = try #require(historyPage.messages.first)
        #expect(historyMessage.guildID == GuildID(rawValue: 100))
        #expect(historyMessage.guildMember?.nickname == "Colored Author")
        #expect(historyMessage.guildMember?.roleIDs == [RoleID(rawValue: 101)])
        #expect(historyPage.resolvedMembers.map(\.id) == [UserID(rawValue: 4)])
        #expect(historyPage.hasCompleteMemberResolution)
        let historyMemberRequests = await socket.sentPayloadCount(opcode: 8)
        _ = try await provider.messages(in: ChannelID(rawValue: 200), before: nil, limit: 50)
        #expect(await socket.sentPayloadCount(opcode: 8) == historyMemberRequests)

        let memberSearch = Task {
            try await provider.searchMembers(
                in: GuildID(rawValue: 100), query: "maya", limit: 125
            )
        }
        #expect(await eventually {
            await socket.sentPayloadCount(opcode: 8) > historyMemberRequests
        })
        let gatewayData = try #require(await socket.sentPayload(opcode: 8))
        let gatewayPayload = try #require(
            JSONSerialization.jsonObject(with: gatewayData) as? [String: Any]
        )
        #expect((gatewayPayload["op"] as? NSNumber)?.intValue == 8)
        let searchData = try #require(gatewayPayload["d"] as? [String: Any])
        #expect(searchData["guild_id"] as? [String] == ["100"])
        #expect(searchData["query"] as? String == "maya")
        #expect((searchData["limit"] as? NSNumber)?.intValue == 100)
        #expect(searchData["presences"] as? Bool == true)
        #expect(Set(searchData.keys) == ["guild_id", "query", "limit", "presences"])
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "guild_id": .string("100"),
                "members": .array([
                    .object([
                        "user": .object([
                            "id": .string("2"),
                            "username": .string("maya"),
                            "global_name": .string("Maya"),
                            "avatar": .null
                        ]),
                        "nick": .string("Maya"),
                        "roles": .array([.string("101")])
                    ]),
                    .object([
                        "user": .object([
                            "id": .string("3"),
                            "username": .string("mayabot"),
                            "global_name": .string("Maya Bot"),
                            "avatar": .null
                        ]),
                        "nick": .string("Maya Bot"),
                        "roles": .array([.string("101")])
                    ])
                ]),
                "chunk_index": .number(0),
                "chunk_count": .number(1)
            ]),
            sequence: 2,
            eventName: "GUILD_MEMBERS_CHUNK"
        ))
        let memberMatches = try await memberSearch.value
        #expect(memberMatches.map(\.user.displayName) == ["Maya", "Maya Bot"])
        #expect((await provider.currentMessageSearchUsers()).contains {
            $0.id == UserID(rawValue: 2)
        })
        let indexedQuickSwitcherMembers =
            await provider.currentQuickSwitcherGuildMemberUserIDs()
        #expect(indexedQuickSwitcherMembers[GuildID(rawValue: 100)] == [
            // GuildMemberStore retains READY insertion order, then appends
            // query-member chunks in their returned order.
            UserID(rawValue: 4), UserID(rawValue: 2), UserID(rawValue: 3),
        ])
        #expect(RateLimitURLProtocol.memberSearchRequestCount == 0)

        let memberRequestCount = await socket.sentPayloadCount(opcode: 8)
        try await provider.requestQuickSwitcherMembers(
            in: GuildID(rawValue: 100), query: "HEN", limit: 125
        )
        #expect(await socket.sentPayloadCount(opcode: 8) == memberRequestCount + 1)
        let quickSwitcherGatewayData = try #require(await socket.sentPayload(opcode: 8))
        let quickSwitcherGatewayPayload = try #require(
            JSONSerialization.jsonObject(with: quickSwitcherGatewayData) as? [String: Any]
        )
        let quickSwitcherSearch = try #require(
            quickSwitcherGatewayPayload["d"] as? [String: Any]
        )
        #expect(quickSwitcherSearch["guild_id"] as? [String] == ["100"])
        #expect(quickSwitcherSearch["query"] as? String == "hen")
        #expect((quickSwitcherSearch["limit"] as? NSNumber)?.intValue == 100)
        #expect(quickSwitcherSearch["presences"] as? Bool == true)
        #expect(Set(quickSwitcherSearch.keys) == [
            "guild_id", "query", "limit", "presences",
        ])

        await provider.updateClientAppState(isFocused: false)
        let clientAppState = await provider.clientAppStateForTesting()
        #expect(clientAppState == "unfocused")
        try await provider.sendTyping(in: ChannelID(rawValue: 200))
        #expect(RateLimitURLProtocol.typingRequestCount == 1)
        #expect(RateLimitURLProtocol.typingMethod == "POST")
        #expect(RateLimitURLProtocol.typingHadBody == false)
        #expect(RateLimitURLProtocol.typingSuperProperties != nil)

        let draft = SendMessageDraft(channelID: ChannelID(rawValue: 200), content: "hello")
        let sent = try await provider.send(draft)
        #expect(sent.content == "hello")
        #expect(draft.nonce.count <= 25)
        #expect(RateLimitURLProtocol.sentNonce == draft.nonce)
        #expect(RateLimitURLProtocol.sentEnforceNonce)
        #expect(RateLimitURLProtocol.messageContextProperties == DiscordClientMetadata.messageContextHeader)
        let encodedProperties = try #require(RateLimitURLProtocol.messageSuperProperties)
        let propertiesData = try #require(Data(base64Encoded: encodedProperties))
        let properties = try #require(JSONSerialization.jsonObject(with: propertiesData) as? [String: Any])
        #expect(properties["browser"] as? String == "Discord Client")
        #expect(properties["browser_user_agent"] as? String == RateLimitURLProtocol.messageUserAgent)
        #expect((properties["client_build_number"] as? NSNumber)?.intValue == DiscordProductionBaseline.current.webBuildNumber)

        let mentionDraft = SendMessageDraft(
            channelID: ChannelID(rawValue: 200),
            content: "hello <@2>",
            nonce: "mention-contract-nonce"
        )
        let requestsBeforeMentionSend = RateLimitURLProtocol.messageRequestCount
        _ = try await provider.send(mentionDraft)
        #expect(RateLimitURLProtocol.messageRequestCount == requestsBeforeMentionSend + 1)
        #expect(RateLimitURLProtocol.messageMethod == "POST")
        #expect(RateLimitURLProtocol.messagePath == "/api/v9/channels/200/messages")
        let mentionBody = try #require(RateLimitURLProtocol.sentMessageBody)
        #expect(Set(mentionBody.keys) == [
            "content", "nonce", "enforce_nonce", "tts", "flags", "mobile_network_type",
        ])
        #expect(mentionBody["content"] as? String == "hello <@2>")
        #expect(mentionBody["nonce"] as? String == mentionDraft.nonce)
        #expect(mentionBody["enforce_nonce"] as? Bool == true)
        #expect(mentionBody["attachments"] == nil)
        #expect(mentionBody["tts"] as? Bool == false)
        #expect((mentionBody["flags"] as? NSNumber)?.intValue == 0)
        #expect(mentionBody["mobile_network_type"] as? String == "unknown")
        #expect(mentionBody["allowed_mentions"] == nil)

        let stickerDraft = SendMessageDraft(
            channelID: ChannelID(rawValue: 200),
            content: "",
            nonce: "sticker-contract-nonce",
            stickerIDs: ["123456789012345678"]
        )
        let requestsBeforeStickerSend = RateLimitURLProtocol.messageRequestCount
        _ = try await provider.send(stickerDraft)
        #expect(RateLimitURLProtocol.messageRequestCount == requestsBeforeStickerSend + 1)
        let stickerBody = try #require(RateLimitURLProtocol.sentMessageBody)
        #expect(Set(stickerBody.keys) == [
            "content", "nonce", "tts", "flags", "mobile_network_type", "sticker_ids",
        ])
        #expect(stickerBody["content"] as? String == "")
        #expect(stickerBody["nonce"] as? String == stickerDraft.nonce)
        #expect(stickerBody["enforce_nonce"] == nil)
        #expect(stickerBody["sticker_ids"] as? [String] == ["123456789012345678"])

        let reply = try await provider.send(SendMessageDraft(
            channelID: ChannelID(rawValue: 200),
            content: "reply",
            replyTo: MessageID(rawValue: 299)
        ))
        #expect(reply.replyTo == MessageID(rawValue: 299))
        #expect(reply.replyPreview?.author.displayName == "Original Author")
        #expect(reply.replyPreview?.content == "original message")
        let replyBody = try #require(RateLimitURLProtocol.sentMessageBody)
        let reference = try #require(
            replyBody["message_reference"] as? [String: Any]
        )
        #expect((reference["type"] as? NSNumber)?.intValue == 0)
        #expect(reference["message_id"] as? String == "299")
        #expect(reference["channel_id"] as? String == "200")
        #expect(replyBody["allowed_mentions"] == nil)

        let quietReply = try await provider.send(SendMessageDraft(
            channelID: ChannelID(rawValue: 200),
            content: "quiet reply",
            replyTo: MessageID(rawValue: 299),
            mentionsRepliedUser: false
        ))
        let quietReplyBody = try #require(RateLimitURLProtocol.sentMessageBody)
        let allowedMentions = try #require(
            quietReplyBody["allowed_mentions"] as? [String: Any]
        )
        #expect(allowedMentions["replied_user"] as? Bool == false)
        #expect(allowedMentions["parse"] as? [String] == [
            "users", "roles", "everyone",
        ])

        _ = try await provider.edit(quietReply, content: "edited reply")
        let quietEditBody = try #require(RateLimitURLProtocol.sentMessageBody)
        #expect(quietEditBody["content"] as? String == "edited reply")
        let quietEditMentions = try #require(quietEditBody["allowed_mentions"] as? [String: Any])
        #expect(quietEditMentions["replied_user"] as? Bool == false)
        #expect(quietEditMentions["parse"] as? [String] == ["users", "roles", "everyone"])

        var pingingReply = quietReply
        pingingReply.mentionedUsers = try [#require(quietReply.replyPreview?.author)]
        _ = try await provider.edit(pingingReply, content: "edited reply")
        #expect(try #require(RateLimitURLProtocol.sentMessageBody)["allowed_mentions"] == nil)

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("sakuracord-upload-test.txt")
        try Data("attachment".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        var previewAttachment = ForumPostAttachment(url: fileURL).applyingFilenamePrivacy(anonymisesFileNames)
        _ = try await provider.send(SendMessageDraft(
            channelID: ChannelID(rawValue: 200),
            content: "with file",
            attachments: [previewAttachment]
        ))
        #expect(RateLimitURLProtocol.uploadHadAuthorization == false)
        #expect(RateLimitURLProtocol.sentUploadedFilename == "discord-upload-token")
        let attachments = try #require(RateLimitURLProtocol.sentMessageBody?["attachments"] as? [[String: Any]])
        let uploadedName = try #require(attachments.first?["filename"] as? String)
        #expect(uploadedName == previewAttachment.filename)
        if anonymisesFileNames {
            #expect(uploadedName != fileURL.lastPathComponent)
            #expect((uploadedName as NSString).pathExtension == "txt")
            #expect(UUID(uuidString: (uploadedName as NSString).deletingPathExtension) != nil)
        } else {
            #expect(uploadedName == fileURL.lastPathComponent)
        }
        if anonymisesFileNames {
            previewAttachment.setFilenameAnonymised(false)
            _ = try await provider.send(SendMessageDraft(
                channelID: ChannelID(rawValue: 200), content: "original name", attachments: [previewAttachment]
            ))
            let restoredAttachments = try #require(RateLimitURLProtocol.sentMessageBody?["attachments"] as? [[String: Any]])
            #expect(restoredAttachments.first?["filename"] as? String == fileURL.lastPathComponent)
        }
        #expect(await credentials.credentialReadCount == 1)
        await provider.disconnect()
        }
    }
}
