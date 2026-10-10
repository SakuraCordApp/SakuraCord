import Foundation
import SakuraCordModels
import Testing
@testable import DiscordProtocol

@Suite(.serialized)
struct DirectMessageProviderContractTests {
    @Test func `widget game search coalesces normalized requests and retains failed query cooldown`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": .object(["id": .string("2"), "username": .string("maya")]), "guilds": .array([])
        ]))
        async let first = provider.searchProfileWidgetGames(query: "  Test_Game  ")
        async let second = provider.searchProfileWidgetGames(query: "test game")
        let results = try await (first, second)
        #expect(results.0.map(\.id) == ["21"])
        #expect(results.1 == results.0)
        #expect(DirectMessageURLProtocol.requests.count == 1)
        #expect(DirectMessageURLProtocol.requests.first?.query == [CapturedQueryItem(name: "q", value: "test game")])
        _ = try await provider.searchProfileWidgetGames(query: "test game")
        #expect(DirectMessageURLProtocol.requests.count == 1)
        for _ in 0 ..< 2 {
            await #expect(throws: ChatProviderError.self) { try await provider.searchProfileWidgetGames(query: "unavailable") }
        }
        #expect(DirectMessageURLProtocol.requests.count == 2)
        await provider.disconnect()
    }

    @Test func `game profiles hydrate filtered similar games and cache announcement reads per session`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": .object(["id": .string("2"), "username": .string("maya"), "nsfw_allowed": .bool(false)]), "guilds": .array([])
        ]))
        #expect(try await provider.similarProfileGames(to: "700136079562375258").isEmpty)
        #expect(DirectMessageURLProtocol.requests.isEmpty)
        let similar = try await provider.similarProfileGames(to: "21")
        #expect(similar.map(\.id) == ["22"])
        #expect(DirectMessageURLProtocol.requests.map(\.path) == [
            "/api/v9/content-inventory/users/@me/similar-games/21", "/api/v9/games"
        ])
        #expect(DirectMessageURLProtocol.requests[1].query == ["22", "23", "24"].map { CapturedQueryItem(name: "game_ids", value: $0) })
        let news = try await provider.profileGameAnnouncements(gameID: "21")
        #expect(news.messages.map(\.title) == ["Update", "Embed title", nil])
        #expect(news.messages[0].body == "New features")
        #expect(news.messages[1].body == "Embed body")
        #expect(news.messages[1].embedSource?.provider?.name == "Publisher")
        #expect(news.messages[1].media?.url?.absoluteString == "https://example.com/poster.png")
        #expect(news.messages[2].poll?.question == "Next update?")
        #expect(news.messages[2].poll?.answers.map(\.text) == ["New map"])
        #expect(news.channelID == ChannelID("41"))
        #expect(news.guildID == GuildID("10"))
        let request = try #require(DirectMessageURLProtocol.requests.last)
        #expect(request.path == "/api/v9/games/21/announcements")
        #expect(request.query == [CapturedQueryItem(name: "limit", value: "8")])
        #expect(DirectMessageURLProtocol.requests.allSatisfy { $0.method == "GET" && $0.hadAuthorization && $0.body == nil })
        _ = try await provider.profileGameAnnouncements(gameID: "21")
        _ = try await provider.similarProfileGames(to: "21")
        #expect(DirectMessageURLProtocol.requests.count == 3)
        await provider.receiveGatewayDispatchForTesting(name: "USER_UPDATE", data: .object([
            "id": .string("2"), "username": .string("maya"), "nsfw_allowed": .bool(true)
        ]))
        #expect(try await provider.similarProfileGames(to: "21").map(\.id) == ["22", "24"])
        #expect(DirectMessageURLProtocol.requests.count == 3)
        await provider.disconnect()
        #expect(await provider.profileSimilarGameIDs.isEmpty)
        #expect(await provider.profileGameAnnouncementCache.isEmpty)
    }

    @Test func `custom status saves the status subtree and leaves profile drafts independent`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        let retained = try #require(Data(base64Encoded: "CgsKCWludmlzaWJsZRoAKgcIxf7s0YU0"))
        let initial = DiscordSettingsProto.protoLengthDelimitedField(11, retained).base64EncodedString()
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": .object(["id": .string("2"), "username": .string("maya"), "premium_type": .number(2)]),
            "guilds": .array([]), "user_settings_proto": .string(initial)
        ]))
        let saved = try await provider.updateProfileCustomStatus(ProfileCustomStatus(text: "  Growing flowers  ", emojiName: "🌸"))
        #expect(saved?.text == "Growing flowers")
        #expect(saved?.emojiName == "🌸")
        #expect(saved?.expiresAt == nil)
        #expect(saved?.createdAt != nil)
        #expect(DirectMessageURLProtocol.requests.count == 1)
        let request = try #require(DirectMessageURLProtocol.requests.first)
        #expect(request.method == "PATCH")
        #expect(request.encodedPath == "/api/v9/users/@me/settings-proto/1")
        #expect(request.query.isEmpty)
        #expect(request.hadAuthorization)
        #expect(request.body?.keys.sorted() == ["settings"])
        let response = try await provider.updateProfileCustomStatus(nil)
        #expect(response == nil)
        #expect(DirectMessageURLProtocol.requests.last?.body?["settings"] as? String == initial)
        let events = await provider.eventStream()
        let external = ProfileCustomStatus(text: "Changed elsewhere", emojiName: "🌸")
        for status in [external, nil] {
            let proto = DiscordSettingsProto.updatingCustomStatus(status, in: retained)
            await provider.receiveGatewayDispatchForTesting(name: "USER_SETTINGS_PROTO_UPDATE", data: .object([
                "settings": .object(["type": .number(1), "proto": .string(proto.base64EncodedString())]), "partial": .bool(true)
            ]))
            #expect(await provider.profileStatusSettings.flatMap { DiscordSettingsProto.customStatus(in: $0) } == status)
        }
        await provider.disconnect()
        var received: [ProfileCustomStatus?] = []
        for await event in events {
            if case let .profileCustomStatusChanged(userID, status) = event {
                #expect(userID == UserID("2"))
                received.append(status)
            }
        }
        #expect(received == [external, nil])
        #expect(DirectMessageURLProtocol.requests.count == 2)
    }

    @Test func `widget image upload gates access before reservation and omits credentials from storage`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": .object(["id": .string("2"), "username": .string("maya"), "premium_type": .number(2)]),
            "guilds": .array([])
        ]))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await #expect(throws: ChatProviderError.self) {
            try await provider.uploadProfileWidgetImage(fileURL: file, filename: "cover.png", contentType: "image/png")
        }
        #expect(DirectMessageURLProtocol.requests.isEmpty)
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": .object(["id": .string("2"), "username": .string("maya"), "premium_type": .number(2)]),
            "guilds": .array([]),
            "apex_experiments": .object(["assignments": .object(["1": .object(["2": .object([
                "assignments": .array([.array([.number(2_369_760_879), .number(1), .number(2), .number(1)])])
            ])])])])
        ]))
        let image = try await provider.uploadProfileWidgetImage(fileURL: file, filename: "cover.png", contentType: "image/png")
        #expect(image.reference == .pendingUpload(filename: "reserved/cover.png"))
        let requests = DirectMessageURLProtocol.requests
        #expect(requests.map(\.method) == ["POST", "PUT"])
        #expect(requests.map(\.path) == ["/api/v9/users/@me/widgets/assets/upload", "/widget-image"])
        #expect(requests.map(\.hadAuthorization) == [true, false])
        #expect(requests.first?.body?["filename"] as? String == "cover.png")
        #expect(requests.first?.body?["file_size"] as? Int == 3)
        #expect(requests.last?.contentType == "image/png")
        #expect(requests.last?.query == [CapturedQueryItem(name: "signature", value: "fixture")])
        await provider.disconnect()
    }

    @Test(arguments: [0, 2]) func `widget save follows a failed profile group and acknowledges only the saved widgets`(premiumType: Int) async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": .object(["id": .string("2"), "username": .string("maya"), "global_name": .string("Maya"), "premium_type": .number(Double(premiumType))]),
            "guilds": .array([]),
            "apex_experiments": .object(["assignments": .object(["1": .object(["2": .object([
                "assignments": .array([.array([.number(2_369_760_879), .number(1), .number(2), .number(1)])])
            ])])])])
        ]))
        _ = try await provider.profileEditingSnapshot(in: .main)
        if premiumType == 0 {
            let personal = ProfileWidget(content: .personal(ProfilePersonalWidget(header: "Personal", sections: [.cover(ProfileWidgetCover(title: "Content"))])))
            await #expect(throws: ChatProviderError.self) {
                try await provider.saveProfileChanges(ProfileEditChanges(widgets: [personal]), in: .main) { _ in }
            }
            #expect(DirectMessageURLProtocol.requests.count == 1)
        }
        var changes = ProfileEditChanges(widgets: [ProfileWidget(content: .application(id: "7"))])
        changes.metadata.bio = .set("rejected-bio")
        let receipt = ProfileSaveReceipt(changes)
        await #expect(throws: ProfileValidationError.self) {
            try await provider.saveProfileChanges(changes, in: .main) { await receipt.accept($0) }
        }
        #expect(await receipt.stages == [.widgets])
        #expect(await receipt.changes.widgets == nil)
        #expect(await receipt.changes.metadata.bio == .set("rejected-bio"))
        #expect(await receipt.snapshots.last??.presentation.widgets?.first?.serverID == "700")
        #expect(DirectMessageURLProtocol.requests.map(\.path) == [
            "/api/v9/users/2/profile", "/api/v9/users/@me/profile", "/api/v9/users/@me/widgets"
        ])
        #expect(DirectMessageURLProtocol.requests.last?.method == "PUT")
        await provider.disconnect()
    }

    @Test func `profile save acknowledges successful identity before metadata failure and retries only remaining changes`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": user(id: "2", username: "maya", globalName: "Maya"), "guilds": .array([])
        ]))
        _ = try await provider.profileEditingSnapshot(in: .main)
        var changes = ProfileEditChanges()
        changes.identity.name = .set("Updated")
        changes.metadata.bio = .set("rejected-bio")
        let receipt = ProfileSaveReceipt(changes)
        await #expect(throws: ProfileValidationError.self) {
            try await provider.saveProfileChanges(changes, in: .main) { await receipt.accept($0) }
        }
        #expect(await receipt.stages == [.identity])
        var remaining = await receipt.changes
        #expect(!remaining.identity.hasChanges)
        #expect(remaining.metadata.bio == .set("rejected-bio"))
        remaining.metadata.bio = .set("Accepted bio")
        try await provider.saveProfileChanges(remaining, in: .main) { await receipt.accept($0) }
        #expect(await receipt.stages == [.identity, .metadata])
        #expect(await receipt.snapshots.last??.presentation.bio == "Accepted bio")
        #expect(DirectMessageURLProtocol.requests.map(\.path) == [
            "/api/v9/users/2/profile", "/api/v9/users/@me", "/api/v9/users/@me/profile", "/api/v9/users/@me/profile"
        ])
        #expect(DirectMessageURLProtocol.requests.suffix(3).allSatisfy { $0.method == "PATCH" })
        #expect(DirectMessageURLProtocol.requests.suffix(2).allSatisfy { $0.encodedPath == "/api/v9/users/%40me/profile" })
        await provider.disconnect()
    }

    @Test func `solid and pop defaults pass save validation and reconcile their distinct palettes`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": .object(["id": .string("2"), "username": .string("maya"), "premium_type": .number(2)]),
            "guilds": .array([])
        ]))
        _ = try await provider.profileEditingSnapshot(in: .main)
        var changes = ProfileEditChanges()
        for invalidStyle in [
            DisplayNameStyle(colors: [0x1000000]),
            DisplayNameStyle(colors: [0x123456, 0x654321]),
            DisplayNameStyle(effectID: ProfileNameEffect.gradient.rawValue),
            DisplayNameStyle(effectID: ProfileNameEffect.pop.rawValue),
        ] {
            changes.identity.displayNameStyle = .set(invalidStyle)
            await #expect(throws: ChatProviderError.self) {
                try await provider.saveProfileChanges(changes, in: .main) { _ in }
            }
        }
        #expect(DirectMessageURLProtocol.requests.count == 1)

        for style in [DisplayNameStyle(), DisplayNameStyle(effectID: 5, colors: [1_036_166])] {
            changes.identity.displayNameStyle = .set(style)
            let receipt = ProfileSaveReceipt(changes)
            try await provider.saveProfileChanges(changes, in: .main) { await receipt.accept($0) }
            let request = try #require(DirectMessageURLProtocol.requests.last)
            #expect(request.method == "PATCH" && request.path == "/api/v9/users/@me")
            #expect(request.body?["display_name_font_id"] as? Int == style.fontID)
            #expect(request.body?["display_name_effect_id"] as? Int == style.effectID)
            #expect(request.body?["display_name_colors"] as? [UInt32] == style.colors)
            #expect(await receipt.stages == [.identity])
            #expect(await receipt.snapshots.last??.presentation.user.displayNameStyle == style)
            #expect(await receipt.changes.hasChanges == false)
        }
        await provider.disconnect()
    }

    @Test func `server decoration reset accepts omitted inherited decoration and continues metadata save`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": .object(["id": .string("2"), "username": .string("maya"), "premium_type": .number(2)]),
            "guilds": .array([])
        ]))
        let scope = ProfileEditingScope.server(GuildID(rawValue: 10))
        _ = try await provider.profileEditingSnapshot(in: scope)
        var changes = ProfileEditChanges()
        changes.identity.decorationSKUID = .clear
        changes.identity.nameplateSKUID = .clear
        changes.metadata.collectibleSKUIDs = .clear
        let receipt = ProfileSaveReceipt(changes)
        try await provider.saveProfileChanges(changes, in: scope) { await receipt.accept($0) }
        #expect(await receipt.stages == [.identity, .metadata])
        #expect(await receipt.snapshots.first??.serverIdentity?.decorationSKUID == .missing)
        #expect(await receipt.snapshots.first??.serverIdentity?.nameplateSKUID == .null)
        #expect(await receipt.changes.hasChanges == false)
        #expect(DirectMessageURLProtocol.requests.map(\.path) == [
            "/api/v9/users/2/profile", "/api/v9/guilds/10/members/@me", "/api/v9/guilds/10/profile/@me"
        ])
        await provider.disconnect()
    }

    @Test func `successful but malformed profile response is acknowledged and requires a reload`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": user(id: "2", username: "maya", globalName: "Maya"), "guilds": .array([])
        ]))
        _ = try await provider.profileEditingSnapshot(in: .main)
        var changes = ProfileEditChanges()
        changes.identity.name = .set("malformed-response")
        changes.metadata.bio = .set("Must not be sent")
        let receipt = ProfileSaveReceipt(changes)
        await #expect(throws: ChatProviderError.self) {
            try await provider.saveProfileChanges(changes, in: .main) { await receipt.accept($0) }
        }
        #expect(await receipt.stages == [.identity])
        #expect(await receipt.snapshots == [nil])
        let remaining = await receipt.changes
        await #expect(throws: ChatProviderError.self) {
            try await provider.saveProfileChanges(remaining, in: .main) { await receipt.accept($0) }
        }
        #expect(DirectMessageURLProtocol.requests.count == 2)
        await provider.disconnect()
    }

    @Test func `server tag saves from either editor update every cached profile with one account request`() async throws {
        let scopes: [ProfileEditingScope] = [.main, .server(GuildID(rawValue: 10)), .server(GuildID(rawValue: 11))]
        for origin in scopes.prefix(2) {
            DirectMessageURLProtocol.reset()
            let provider = makeProvider()
            await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
                "user": user(id: "2", username: "maya", globalName: "Maya"), "guilds": .array([])
            ]))
            for scope in scopes { _ = try await provider.profileEditingSnapshot(in: scope) }
            for tag: GuildID? in [GuildID(rawValue: 99), nil] {
                let requestCount = DirectMessageURLProtocol.requests.count
                let receipt = ProfileSaveReceipt(ProfileEditChanges(serverTag: tag.map(ProfileChange.set) ?? .clear))
                try await provider.saveProfileChanges(await receipt.changes, in: origin) { await receipt.accept($0) }
                #expect(await receipt.stages == [.serverTag])
                #expect(await receipt.changes.hasChanges == false)
                for scope in scopes {
                    let cached = try #require(try await provider.cachedProfileEditingSnapshot(in: scope))
                    #expect(cached.presentation.user.primaryGuild?.guildID == tag)
                    #expect(cached.mainPresentation.user.primaryGuild?.guildID == tag)
                    #expect(cached.serverTag.value?.guildID.value == tag)
                    #expect(cached.serverTag.value?.isEnabled.value == (tag != nil))
                    #expect(cached.presentation.user.displayName == "Maya")
                    if scope.guildID != nil { #expect(cached.serverIdentity?.name == .null) }
                }
                #expect(DirectMessageURLProtocol.requests.count == requestCount + 1)
                let request = try #require(DirectMessageURLProtocol.requests.last)
                #expect(request.path == "/api/v9/users/@me/clan")
                #expect(request.method == "PUT")
                #expect(request.body?["identity_enabled"] as? Bool == (tag != nil))
                if let tag { #expect(request.body?["identity_guild_id"] as? String == tag.description) } else {
                    #expect(request.body?["identity_guild_id"] is NSNull)
                }
            }
            await provider.disconnect()
        }
    }

    @Test func `user and member updates invalidate profile snapshots without issuing requests`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        let account = user(id: "2", username: "maya", globalName: "Maya")
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": account, "guilds": .array([])
        ]))
        let scopes: [ProfileEditingScope] = [.main, .server(GuildID(rawValue: 10))]
        for event in ["USER_UPDATE", "GUILD_MEMBER_UPDATE"] {
            for scope in scopes { _ = try await provider.profileEditingSnapshot(in: scope) }
            let requestCount = DirectMessageURLProtocol.requests.count
            let revision = await provider.profilePresentationRevisions[UserID(rawValue: 2), default: 0]
            let body: JSONValue = event == "USER_UPDATE" ? account : .object([
                "guild_id": .string("10"), "user": account, "roles": .array([]),
                "joined_at": .string("2026-01-01T00:00:00Z")
            ])
            await provider.receiveGatewayDispatchForTesting(name: event, data: body)
            for scope in scopes { #expect(try await provider.cachedProfileEditingSnapshot(in: scope) == nil) }
            #expect(await provider.profilePresentationRevisions[UserID(rawValue: 2), default: 0] > revision)
            #expect(DirectMessageURLProtocol.requests.count == requestCount)
        }
        await provider.disconnect()
    }

    @Test func `profile editor loads the official modal query and READY widget eligibility`() async throws {
        for scope in [ProfileEditingScope.main, .server(GuildID(rawValue: 10))] {
            DirectMessageURLProtocol.reset()
            let provider = makeProvider()
            await provider.receiveGatewayDispatchForTesting(
                name: "READY",
                data: .object([
                    "user": .object([
                        "id": .string("2"), "username": .string("maya"),
                        "global_name": .string("Maya"), "premium_type": .number(2),
                    ]),
                    "guilds": .array([]),
                    "user_settings_proto": .string(Data([0x6A, 0x02, 0x10, 0x01]).base64EncodedString()),
                    "apex_experiments": .object([
                        "assignments": .object([
                            "1": .object([
                                "2": .object([
                                    "assignments": .array([
                                        .array([.number(2_369_760_879), .number(1), .number(2), .number(1)])
                                    ])
                                ])
                            ])
                        ])
                    ]),
                ])
            )
            let snapshot = try await provider.profileEditingSnapshot(in: scope)
            #expect(snapshot.scope == scope)
            #expect(snapshot.mainIdentity.avatarHash == .null)
            #expect(snapshot.widgetEligibility.canEditPersonalWidget)
            #expect(snapshot.widgetEligibility.showsDeveloperWidgets)
            await provider.applyProfileSettingsProto(Data([0x6A, 0x02, 0x08, 0x01]).base64EncodedString(), isPartial: true)
            #expect(await provider.profileDeveloperMode)
            #expect(snapshot.presentation.user.premiumType == 2)
            let cachedEditing = try await provider.cachedProfileEditingSnapshot(in: scope)
            #expect(cachedEditing?.identity == snapshot.identity)
            #expect(cachedEditing?.metadata == snapshot.metadata)
            let cachedMain = try #require(try await provider.cachedProfileEditingSnapshot(in: .main))
            #expect(cachedMain.scope == .main)
            #expect(cachedMain.identity == snapshot.mainIdentity)
            #expect(cachedMain.metadata == snapshot.mainMetadata)
            #expect(cachedMain.presentation.user == snapshot.mainPresentation.user)
            #expect(cachedMain.presentation.displayName == snapshot.mainPresentation.displayName)
            #expect(cachedMain.presentation.bio == snapshot.mainPresentation.bio)
            #expect(cachedMain.presentation.pronouns == snapshot.mainPresentation.pronouns)
            #expect(cachedMain.presentation.themeHexes == snapshot.mainPresentation.themeHexes)
            let cachedPopover = try await provider.profile(for: snapshot.presentation.id, in: scope.guildID)
            #expect(cachedPopover.id == snapshot.presentation.id)
            #expect(DirectMessageURLProtocol.requests.count == 1)
            let request = try #require(DirectMessageURLProtocol.requests.first)
            var expectedQuery = [
                CapturedQueryItem(name: "type", value: "modal"),
                CapturedQueryItem(name: "with_mutual_guilds", value: "true"),
                CapturedQueryItem(name: "with_mutual_friends", value: "false"),
                CapturedQueryItem(name: "with_mutual_friends_count", value: "true"),
            ]
            if scope.guildID != nil {
                expectedQuery.append(CapturedQueryItem(name: "guild_id", value: "10"))
                #expect(snapshot.serverIdentity?.name == .null)
                #expect(snapshot.serverMetadata?.pronouns == .value(""))
            }
            #expect(request.method == "GET")
            #expect(request.path == "/api/v9/users/2/profile")
            #expect(request.query == expectedQuery)
            #expect(request.hadAuthorization)
            #expect(request.body == nil)
            if scope == .main {
                let suggestions = try await provider.suggestedProfileWidgetGames()
                #expect(suggestions.gameIDs == ["21", "22"])
                #expect(suggestions.wantedGameIDs == ["31"])
                #expect(!suggestions.fallbackGameIDs.isEmpty)
                let suggestionRequest = try #require(DirectMessageURLProtocol.requests.last)
                #expect(suggestionRequest.method == "GET")
                #expect(suggestionRequest.path == "/api/v9/users/@me/widgets/suggested-games")
                #expect(suggestionRequest.query.isEmpty)
                #expect(suggestionRequest.body == nil)
                #expect(suggestionRequest.hadAuthorization)
            } else {
                // Opening the main editor from a server preload must establish
                // a saveable main baseline, including the original widget list.
                var changes = ProfileEditChanges(widgets: [ProfileWidget(content: .application(id: "7"))])
                changes.metadata.bio = .set("Accepted bio")
                let receipt = ProfileSaveReceipt(changes)
                try await provider.saveProfileChanges(changes, in: .main) { await receipt.accept($0) }
                #expect(await receipt.stages == [.metadata, .widgets])
                #expect(await receipt.changes.hasChanges == false)
                #expect(DirectMessageURLProtocol.requests.map(\.method) == ["GET", "PATCH", "PUT"])
                let saved = try #require(try await provider.cachedProfileEditingSnapshot(in: .main))
                #expect(saved.metadata.bio == .value("Accepted bio"))
                #expect(saved.presentation.widgets?.first?.serverID == "700")
                #expect(saved.serverIdentity == nil)
                #expect(saved.serverMetadata == nil)
                #expect(try await provider.cachedProfileEditingSnapshot(in: scope)?.serverMetadata == snapshot.serverMetadata)
            }
            await provider.disconnect()
        }
    }

    @Test func `widget connection reads preserve repeated query keys and reconcile grants without another request`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": user(id: "2", username: "maya", globalName: "Maya"), "guilds": .array([])
        ]))
        let connections = try await provider.profileWidgetConnections(applicationIDs: ["21", "22", "23", "21"])
        #expect(connections == ["21": .linked(sharesProfileData: true), "22": .linked(sharesProfileData: false), "23": .unlinked])
        let request = try #require(DirectMessageURLProtocol.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/v9/oauth2/tokens")
        #expect(request.query == ["21", "22", "23"].map { CapturedQueryItem(name: "application_ids", value: $0) })
        #expect(request.hadAuthorization && request.body == nil)
        _ = try await provider.profileWidgetConnections(applicationIDs: ["23", "21"])
        #expect(DirectMessageURLProtocol.requests.count == 1)
        await provider.receiveGatewayDispatchForTesting(name: "OAUTH2_TOKEN_CREATE", data: .object([
            "id": .string("new-grant"), "application": .object(["id": .string("22")]),
            "scopes": .array([.string("sdk.social_layer_presence")])
        ]))
        #expect(try await provider.profileWidgetConnections(applicationIDs: ["22"]) == ["22": .linked(sharesProfileData: true)])
        await provider.receiveGatewayDispatchForTesting(name: "OAUTH2_TOKEN_DELETE", data: .object([
            "id": .string("old-grant"), "application_id": .string("22")
        ]))
        #expect(try await provider.profileWidgetConnections(applicationIDs: ["22"]) == ["22": .linked(sharesProfileData: true)])
        await provider.receiveGatewayDispatchForTesting(name: "OAUTH2_TOKEN_DELETE", data: .object([
            "id": .string("new-grant"), "application_id": .string("22")
        ]))
        #expect(try await provider.profileWidgetConnections(applicationIDs: ["22"]) == ["22": .unlinked])
        #expect(DirectMessageURLProtocol.requests.count == 1)
        await provider.disconnect()
    }

}

extension DirectMessageProviderContractTests {
    @Test func `DM history stays a read and extends the forwarding user index`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()

        _ = try await provider.messages(
            in: ChannelID(rawValue: 41),
            before: MessageID(rawValue: 900),
            limit: 50
        )

        #expect(await provider.currentKnownUsers().map(\.id) == [
            UserID(rawValue: 77), UserID(rawValue: 78),
        ])

        let request = try #require(DirectMessageURLProtocol.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/v9/channels/41/messages")
        #expect(request.query == [
            CapturedQueryItem(name: "before", value: "900"),
            CapturedQueryItem(name: "limit", value: "50"),
        ])
        #expect(request.hadAuthorization)
    }

    @Test func `DM profile matches Paicord mutual profile query`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()

        let profile = try await provider.profile(
            for: UserID(rawValue: 2),
            in: nil
        )

        #expect(profile.user.id == UserID(rawValue: 2))
        let request = try #require(DirectMessageURLProtocol.requests.first)
        #expect(request.method == "GET")
        #expect(request.path == "/api/v9/users/2/profile")
        #expect(request.query == [
            CapturedQueryItem(name: "with_mutual_guilds", value: "true"),
            CapturedQueryItem(name: "with_mutual_friends", value: "true"),
            CapturedQueryItem(
                name: "with_mutual_friends_count",
                value: "true"
            ),
        ])
        #expect(request.hadAuthorization)
    }

    @Test func `profile effects use only the current collectibles product route`() async throws {
        DirectMessageURLProtocol.reset()
        DirectMessageURLProtocol.profileHasEffect = true
        let provider = makeProvider()

        async let firstProfile = provider.profile(
            for: UserID(rawValue: 2),
            in: nil
        )
        async let secondProfile = provider.profile(
            for: UserID(rawValue: 2),
            in: nil
        )
        let (profile, duplicateProfile) = try await (firstProfile, secondProfile)

        #expect(profile.effect?.id == "900")
        #expect(profile.effect?.title == "Aurora")
        #expect(profile.effect?.thumbnailURL?.absoluteString == "https://cdn.discordapp.com/assets/content/aurora-preview")
        #expect(duplicateProfile == profile)
        #expect(DirectMessageURLProtocol.requests.map(\.path) == [
            "/api/v9/users/2/profile",
            "/api/v9/collectibles-products/900",
        ])
        #expect(DirectMessageURLProtocol.requests[1].query == [
            CapturedQueryItem(
                name: "locale",
                value: Locale.preferredLanguages.first ?? "en-US"
            )
        ])
    }

    @Test func `private channel gateway events reconcile recipients and deletion`() async throws {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_CREATE",
            data: .object([
                "id": .string("41"),
                "type": .number(3),
                "name": .string("Design crew"),
                "owner_id": .string("1"),
                "recipients": .array([
                    .object([
                        "id": .string("2"),
                        "username": .string("maya"),
                        "global_name": .string("Maya"),
                    ])
                ]),
            ])
        )
        #expect(
            await provider.cachedChannelForTesting(
                channelID: ChannelID(rawValue: 41)
            )?.ownerID == UserID(rawValue: 1)
        )

        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_RECIPIENT_ADD",
            data: .object([
                "channel_id": .string("41"),
                "user": .object([
                    "id": .string("3"),
                    "username": .string("theo"),
                    "global_name": .string("Theo"),
                ]),
            ])
        )
        #expect(
            await provider.cachedChannelForTesting(
                channelID: ChannelID(rawValue: 41)
            )?.recipients.map(\.id) == [
                UserID(rawValue: 3), UserID(rawValue: 2),
            ]
        )

        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_UPDATE",
            data: .object([
                "id": .string("41"),
                "type": .number(3),
                "name": .string("Renamed remotely"),
            ])
        )
        let remotelyRenamed = try #require(
            await provider.cachedChannelForTesting(
                channelID: ChannelID(rawValue: 41)
            )
        )
        #expect(remotelyRenamed.name == "Renamed remotely")
        #expect(remotelyRenamed.recipients.map(\.id) == [
            UserID(rawValue: 3), UserID(rawValue: 2),
        ])
        #expect(remotelyRenamed.ownerID == UserID(rawValue: 1))

        await provider.receiveGatewayDispatchForTesting(
            name: "CHANNEL_DELETE",
            data: .object(["id": .string("41")])
        )
        #expect(
            await provider.cachedChannelForTesting(
                channelID: ChannelID(rawValue: 41)
            ) == nil
        )
        await provider.disconnect()
    }

    @Test func `private channel order matches Paicord Ready and message reconciliation`() async {
        let provider = makeProvider()
        await seedPrivateChannelOrderReady(on: provider)
        #expect(
            await provider.cachedPrivateChannelsForTesting().map(\.id) == [
                ChannelID(rawValue: 43),
                ChannelID(rawValue: 41),
                ChannelID(rawValue: 42),
            ]
        )
        #expect(
            Dictionary(
                uniqueKeysWithValues: await provider.cachedPrivateChannelsForTesting()
                    .map { ($0.id, $0.position) }
            ) == [
                ChannelID(rawValue: 41): 0,
                ChannelID(rawValue: 42): 1,
                ChannelID(rawValue: 43): 2,
            ]
        )
        #expect(
            await provider.cachedPrivateChannelsForTesting().allSatisfy {
                $0.name == "Maya"
                    && $0.recipients.map(\.id) == [UserID(rawValue: 2)]
            }
        )

        // A new message-less group DM leads by its own snowflake; reopened
        // DMs land by last message, not by their (newer) channel IDs.
        let created: [(id: String, lastMessageID: String?)] = [("800", nil), ("801", "600"), ("802", "10")]
        for channel in created {
            await provider.receiveGatewayDispatchForTesting(name: "CHANNEL_CREATE", data: privateChannel(id: channel.id, lastMessageID: channel.lastMessageID))
        }
        let afterCreate = await provider.cachedPrivateChannelsForTesting()
        #expect(afterCreate.map(\.id.rawValue) == [800, 43, 801, 41, 42, 802])
        #expect(afterCreate.filter { $0.id.rawValue >= 800 }.map(\.position) == [3, 4, 5])

        await provider.receiveGatewayDispatchForTesting(
            name: "READY_SUPPLEMENTAL",
            data: .object([
                "guilds": .array([]),
                "users": .array([
                    user(id: "3", username: "theo", globalName: "Theo")
                ]),
                "lazy_private_channels": .array([
                    privateChannel(
                        id: "45",
                        lastMessageID: "900",
                        recipientID: "3"
                    )
                ]),
            ])
        )
        let afterSupplemental = await provider.cachedPrivateChannelsForTesting()
        #expect(afterSupplemental.map(\.id.rawValue) == [45, 800, 43, 801, 41, 42, 802])
        #expect(
            afterSupplemental.first?.recipients.map(\.id)
                == [UserID(rawValue: 3)]
        )
        #expect(afterSupplemental.first?.position == 6)

        await provider.receiveGatewayDispatchForTesting(
            name: "MESSAGE_CREATE",
            data: .object([
                "id": .string("1000"),
                "channel_id": .string("42"),
                "author": .object([
                    "id": .string("2"),
                    "username": .string("maya"),
                    "global_name": .string("Maya"),
                    "avatar": .null,
                ]),
                "content": .string("most recent"),
                "timestamp": .string("2026-07-29T08:00:00.000Z"),
                "attachments": .array([]),
                "reactions": .array([]),
            ])
        )
        let reordered = await provider.cachedPrivateChannelsForTesting()
        #expect(reordered.map(\.id.rawValue) == [42, 45, 800, 43, 801, 41, 802])
        #expect(reordered.first?.lastMessageID == MessageID(rawValue: 1000))
        await provider.disconnect()
    }

    @Test func `ready supplemental does not admit standalone hydration users`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        let events = await provider.eventStream()
        let published = Task { () -> [User]? in
            for await event in events {
                if case let .knownUsersChanged(users) = event { return users }
            }
            return nil
        }

        await provider.receiveGatewayDispatchForTesting(
            name: "READY_SUPPLEMENTAL",
            data: .object([
                "guilds": .array([]),
                "users": .array([
                    .object([
                        "id": .string("3"),
                        "username": .string("legacy-bot"),
                        "discriminator": .string("8860"),
                        "global_name": .string("Global Name"),
                    ]),
                    .object([
                        "id": .string("2"),
                        "username": .string("later-user"),
                        "global_name": .string("Later User"),
                    ])
                ]),
            ])
        )

        let users = try #require(await published.value)
        #expect(users.isEmpty)
        #expect(await provider.currentMessageSearchUsers().isEmpty)
        #expect(DirectMessageURLProtocol.requests.isEmpty)
        await provider.disconnect()
    }

    @Test func `ready supplemental admits only lazy private channel recipients in payload order`() async {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "READY_SUPPLEMENTAL",
            data: .object([
                "guilds": .array([]),
                "users": .array([
                    user(id: "9", username: "hydration", globalName: "Hydration"),
                    user(id: "3", username: "third", globalName: "Third"),
                    user(id: "2", username: "second", globalName: "Second"),
                ]),
                "lazy_private_channels": .array([
                    .object([
                        "id": .string("41"),
                        "type": .number(3),
                        "recipients": .array([
                            user(id: "3", username: "third", globalName: "Third"),
                            user(id: "2", username: "second", globalName: "Second"),
                        ]),
                    ])
                ]),
            ])
        )

        #expect(await provider.currentKnownUsers().map(\.id) == [
            UserID(rawValue: 3), UserID(rawValue: 2),
        ])
        #expect(await provider.currentMessageSearchUsers().map(\.id) == [
            UserID(rawValue: 3), UserID(rawValue: 2),
        ])
        await provider.disconnect()
    }

    @Test func `message updates an existing forwarding user without a REST lookup`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "READY_SUPPLEMENTAL",
            data: .object([
                "guilds": .array([]),
                "users": .array([
                    user(id: "2", username: "before", globalName: "Before")
                ]),
            ])
        )
        let events = await provider.eventStream()
        let published = Task { () -> [User]? in
            for await event in events {
                if case let .knownUsersChanged(users) = event { return users }
            }
            return nil
        }

        await provider.receiveGatewayDispatchForTesting(
            name: "MESSAGE_CREATE",
            data: .object([
                "id": .string("1000"),
                "channel_id": .string("42"),
                "author": user(id: "2", username: "after", globalName: "After"),
                "content": .string("updated identity"),
                "timestamp": .string("2026-08-10T08:00:00.000Z"),
                "attachments": .array([]),
                "reactions": .array([]),
            ])
        )

        let users = try #require(await published.value)
        let updated = try #require(users.first { $0.id == UserID(rawValue: 2) })
        #expect(updated.username == "after")
        #expect(updated.displayName == "After")
        #expect(DirectMessageURLProtocol.requests.isEmpty)
        await provider.disconnect()
    }

    @Test func `message learned forwarding people survive a provider relaunch`() async throws {
        DirectMessageURLProtocol.reset()
        let cacheDirectory = FileManager.default.temporaryDirectory.appending(
            path: "forward-search-people-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        await seedForwardSearchPeopleCache(at: cacheDirectory)

        let second = makeProvider(usesForwardSearchPeopleDiskCache: true)
        await second.setForwardSearchPeopleCacheDirectoryForTesting(cacheDirectory)
        await second.beginStartupSearchCacheLoad()
        await second.receiveGatewayDispatchForTesting(
            name: "READY",
            data: .object([
                "guilds": .array([]),
                "user": user(id: "1", username: "owner", globalName: "Owner"),
                "users": .array([
                    user(id: "3", username: "ready", globalName: "Ready User")
                ]),
            ])
        )

        #expect(await second.currentKnownUsers().map(\.id) == [
            UserID(rawValue: 1),
            UserID(rawValue: 3),
        ])
        #expect(await second.currentQuickSwitcherUsers().map(\.id) == [
            UserID(rawValue: 1), UserID(rawValue: 3),
        ])
        let reloadedMemberships = await second.currentQuickSwitcherGuildMemberUserIDs()
        #expect(reloadedMemberships[GuildID(rawValue: 7)] == nil)
        #expect(
            await second.currentQuickSwitcherGuildMemberAliases()[GuildID(rawValue: 7)]
                == nil
        )
        #expect(
            await second.currentUserSearchAliasesByUserID()[UserID(rawValue: 2)]
                == ["Current nickname"]
        )

        await seedLiveForwardSearchUsers(on: second)

        #expect(await second.currentKnownUsers().map(\.id) == [
            UserID(rawValue: 1),
            UserID(rawValue: 3),
            UserID(rawValue: 2),
            UserID(rawValue: 4),
        ])
        #expect(await second.currentQuickSwitcherUsers().map(\.id) == [
            UserID(rawValue: 1), UserID(rawValue: 3),
            UserID(rawValue: 2), UserID(rawValue: 4),
        ])
        let reloadedAliases = await second.currentUserSearchAliasesByUserID()
        #expect(reloadedAliases[UserID(rawValue: 2)] == [
            "Ready nickname", "Current nickname",
        ])
        #expect(
            await second.currentUserSearchAliasesByUserID()[UserID(rawValue: 4)]
                == nil
        )
        let liveMessageMemberships = await second.currentQuickSwitcherGuildMemberUserIDs()
        #expect(liveMessageMemberships[GuildID(rawValue: 6)] == [
            UserID(rawValue: 2), UserID(rawValue: 4),
        ])
        #expect(
            await second.currentQuickSwitcherGuildMemberAliases()[GuildID(rawValue: 8)]
                == [UserID(rawValue: 2): "Ready nickname"]
        )
        #expect(DirectMessageURLProtocol.requests.isEmpty)
        await second.disconnect()
    }

    @Test func `quick switcher channel store order survives Ready reconciliation`() async throws {
        let cacheDirectory = FileManager.default.temporaryDirectory.appending(
            path: "quick-switcher-channel-store-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let first = makeProvider(usesForwardSearchPeopleDiskCache: true)
        await first.setForwardSearchPeopleCacheDirectoryForTesting(cacheDirectory)
        await first.reconcileQuickSwitcherChannelStoreOrder(with: [
            ChannelID(rawValue: 3), ChannelID(rawValue: 1), ChannelID(rawValue: 2),
        ])
        await first.persistQuickSwitcherChannelStoreCache()

        let second = makeProvider(usesForwardSearchPeopleDiskCache: true)
        await second.setForwardSearchPeopleCacheDirectoryForTesting(cacheDirectory)
        await second.loadQuickSwitcherChannelStoreCache()
        await second.reconcileQuickSwitcherChannelStoreOrder(with: [
            ChannelID(rawValue: 2), ChannelID(rawValue: 3),
            ChannelID(rawValue: 4), ChannelID(rawValue: 1),
        ])

        #expect(await second.cachedForwardChannelStoreOrder == [
            ChannelID(rawValue: 3), ChannelID(rawValue: 1),
            ChannelID(rawValue: 2), ChannelID(rawValue: 4),
        ])
        await first.disconnect()
        await second.disconnect()
    }

    @Test func `ready supplemental resolves recipients referenced by Ready private channels`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "READY",
            data: .object([
                "guilds": .array([]),
                "user": user(id: "1", username: "owner", globalName: "Owner"),
                "users": .array([]),
                "private_channels": .array([
                    .object([
                        "id": .string("41"),
                        "type": .number(3),
                        "name": .string(""),
                        "owner_id": .string("1"),
                        "recipient_ids": .array([.string("2")]),
                    ])
                ]),
            ])
        )
        #expect(await provider.cachedPrivateChannelsForTesting().first?.recipients.isEmpty == true)

        await provider.receiveGatewayDispatchForTesting(
            name: "READY_SUPPLEMENTAL",
            data: .object([
                "guilds": .array([]),
                "users": .array([
                    user(id: "2", username: "later-user", globalName: "Later User")
                ]),
            ])
        )

        let channel = try #require(await provider.cachedPrivateChannelsForTesting().first)
        #expect(channel.recipients.map(\.id) == [UserID(rawValue: 2)])
        #expect(channel.name == "Later User")
        #expect(await provider.currentMessageSearchUsers().map(\.id) == [
            UserID(rawValue: 1), UserID(rawValue: 2),
        ])
        #expect(DirectMessageURLProtocol.requests.isEmpty)
        await provider.disconnect()
    }

    @Test func `private recipient ordering matches Discords JavaScript snowflake sorter`() {
        let input = [
            "1000000000000000123",
            "1100000000000000456",
            "1200000000000000789",
            "1300000000000000111",
            "1400000000000000222",
        ]

        #expect(
            DiscordPrivateRecipientOrdering.sortedIDs(
                input,
                channelID: "1500000000000000123",
                channelType: 3
            ) == [
                "1300000000000000111",
                "1000000000000000123",
                "1200000000000000789",
                "1400000000000000222",
                "1100000000000000456",
            ]
        )
    }

    @Test func `ready excludes blocked and ignored users from forwarding search`() async throws {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "READY",
            data: .object([
                "guilds": .array([]),
                "user": user(id: "1", username: "owner", globalName: "Owner"),
                "relationships": .array([
                    .object([
                        "id": .string("7"),
                        "type": .number(2),
                        "user": user(id: "7", username: "blocked", globalName: "Blocked"),
                    ]),
                    .object([
                        "id": .string("8"),
                        "type": .number(3),
                        "user_ignored": .bool(true),
                        "user": user(id: "8", username: "ignored", globalName: "Ignored"),
                    ]),
                    .object([
                        "id": .string("9"),
                        "type": .number(1),
                        "user": user(id: "9", username: "friend", globalName: "Friend"),
                    ]),
                ]),
            ])
        )

        let users = await provider.currentKnownUsers()
        #expect(users.contains { $0.id == UserID(rawValue: 9) })
        #expect(!users.contains { $0.id == UserID(rawValue: 7) })
        #expect(!users.contains { $0.id == UserID(rawValue: 8) })
        let quickSwitcherUsers = await provider.currentQuickSwitcherUsers()
        #expect(quickSwitcherUsers.contains { $0.id == UserID(rawValue: 7) })
        #expect(quickSwitcherUsers.contains { $0.id == UserID(rawValue: 8) })
        #expect(quickSwitcherUsers.contains { $0.id == UserID(rawValue: 9) })
        await provider.disconnect()
    }

    @Test func `guild create members extend account wide forwarding users without REST`() async {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        let events = await provider.eventStream()
        let publishedAliases = Task { () -> [UserID: [String]]? in
            for await event in events {
                if case let .userSearchAliasesChanged(aliases) = event {
                    return aliases
                }
            }
            return nil
        }

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE",
            data: .object([
                "id": .string("1"),
                "name": .string("Guild"),
                "members": .array([
                    .object([
                        "user": user(
                            id: "7",
                            username: "member-user",
                            globalName: "Member User"
                        ),
                        "nick": .string("Member nickname"),
                        "roles": .array([]),
                    ])
                ]),
            ])
        )

        let users = await provider.currentKnownUsers()
        #expect(users.contains { $0.id == UserID(rawValue: 7) })
        let aliases = await publishedAliases.value
        #expect(aliases?[UserID(rawValue: 7)] == ["Member nickname"])
        #expect(DirectMessageURLProtocol.requests.isEmpty)
        await provider.disconnect()
    }

    @Test func `guild member chunks extend forwarding users without a REST lookup`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        let events = await provider.eventStream()
        let published = Task { () -> [User]? in
            for await event in events {
                if case let .knownUsersChanged(users) = event { return users }
            }
            return nil
        }

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBERS_CHUNK",
            data: .object([
                "guild_id": .string("1"),
                "chunk_index": .number(0),
                "chunk_count": .number(1),
                "members": .array([
                    .object([
                        "user": user(
                            id: "8",
                            username: "chunk-user",
                            globalName: "Chunk User"
                        ),
                        "nick": .string("Chunk nickname"),
                        "roles": .array([]),
                    ])
                ]),
            ])
        )

        let users = try #require(await published.value)
        #expect(users.contains { $0.id == UserID(rawValue: 8) })
        #expect(DirectMessageURLProtocol.requests.isEmpty)
        await provider.disconnect()
    }

    @Test func `member list updates do not extend forwarding user search`() async {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE",
            data: .object([
                "id": .string("1"),
                "name": .string("Guild"),
            ])
        )

        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_MEMBER_LIST_UPDATE",
            data: .object([
                "guild_id": .string("1"),
                "id": .string("everyone"),
                "ops": .array([
                    .object([
                        "op": .string("SYNC"),
                        "range": .array([.number(0), .number(0)]),
                        "items": .array([
                            .object([
                                "member": .object([
                                    "user": user(
                                        id: "10",
                                        username: "list-user",
                                        globalName: "List User"
                                    ),
                                    "nick": .string("List nickname"),
                                    "roles": .array([]),
                                ])
                            ])
                        ]),
                    ])
                ]),
            ])
        )

        #expect(!(await provider.currentKnownUsers()).contains {
            $0.id == UserID(rawValue: 10)
        })
        #expect(
            await provider.currentUserSearchAliasesByUserID()[UserID(rawValue: 10)]
                == ["List nickname"]
        )
        #expect(DirectMessageURLProtocol.requests.isEmpty)
        await provider.disconnect()
    }

    @Test func `empty group DM uses its owner display name like Discord`() async throws {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "READY",
            data: .object([
                "guilds": .array([]),
                "user": user(id: "1", username: "owner", globalName: "Owner Display"),
                "users": .array([]),
                "private_channels": .array([
                    .object([
                        "id": .string("41"),
                        "type": .number(3),
                        "name": .string(""),
                        "owner_id": .string("1"),
                        "recipient_ids": .array([]),
                        "last_message_id": .string("500"),
                    ])
                ]),
            ])
        )

        let channel = try #require(
            await provider.cachedPrivateChannelsForTesting().first
        )
        #expect(channel.kind == .groupDirectMessage)
        #expect(channel.name == "Owner Display's Group")
        await provider.disconnect()
    }

    @Test func `official Discord system recipient marker survives Ready hydration`() async {
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "READY",
            data: .object([
                "guilds": .array([]),
                "users": .array([
                    user(
                        id: "2",
                        username: "discord",
                        globalName: "Discord",
                        system: true
                    )
                ]),
                "private_channels": .array([
                    privateChannel(id: "41", lastMessageID: "500")
                ]),
            ])
        )

        #expect(
            await provider.cachedPrivateChannelsForTesting()
                .first?.recipients.first?.isSystem == true
        )
        await provider.disconnect()
    }

    @Test func `DM presence, platform, and custom status follow prioritized Ready and guildless updates without REST`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()
        await provider.receiveGatewayDispatchForTesting(
            name: "READY",
            data: .object([
                "guilds": .array([]),
                "users": .array([
                    user(id: "2", username: "maya", globalName: "Maya")
                ]),
                "private_channels": .array([
                    privateChannel(id: "41", lastMessageID: "500")
                ]),
            ])
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "READY_SUPPLEMENTAL",
            data: .object([
                "guilds": .array([]),
                "merged_presences": .object([
                    "guilds": .array([]),
                    "friends": .array([
                        .object([
                            "user_id": .string("2"),
                            "status": .string("idle"),
                            "client_status": .object(["mobile": .string("idle")]),
                            "activities": .array([
                                .object([
                                    "type": .number(4),
                                    "state": .string("Shipping tiny details"),
                                ])
                            ]),
                        ])
                    ]),
                ]),
            ])
        )

        var member = try #require(await provider.members(in: nil).first)
        #expect(member.user.displayName == "Maya")
        #expect(member.status == .idle)
        #expect(member.showsMobileIndicator)
        #expect(member.customStatus == "Shipping tiny details")

        await provider.receiveGatewayDispatchForTesting(
            name: "PRESENCE_UPDATE",
            data: .object([
                "user": .object(["id": .string("2")]),
                "status": .string("online"),
                "client_status": .object(["mobile": .string("online")]),
                "activities": .array([]),
            ])
        )
        member = try #require(await provider.members(in: nil).first)
        #expect(member.status == .online)
        #expect(member.showsMobileIndicator)
        #expect(member.customStatus == nil)

        await provider.receiveGatewayDispatchForTesting(
            name: "PRESENCE_UPDATE",
            data: .object([
                "user": .object(["id": .string("2")]),
                "status": .string("online"),
                "client_status": .object([
                    "mobile": .string("online"),
                    "desktop": .string("idle"),
                ]),
            ])
        )
        member = try #require(await provider.members(in: nil).first)
        #expect(!member.showsMobileIndicator)

        try await verifyMobilePresenceTransitions(provider: provider)
        #expect(DirectMessageURLProtocol.requests.isEmpty)
        await provider.disconnect()
    }

    @Test func `private call gateway events preserve rings participants and deletion`() async throws {
        let provider = makeProvider()
        let events = await provider.eventStream()
        let created = Task { () -> PrivateCall? in
            for await event in events {
                if case let .privateCallChanged(call) = event { return call }
            }
            return nil
        }

        await provider.receiveGatewayDispatchForTesting(
            name: "CALL_CREATE",
            data: .object([
                "channel_id": .string("41"),
                "message_id": .string("501"),
                "region": .string("rotterdam"),
                "ongoing_rings": .object([
                    "2": .string("1")
                ]),
                "voice_states": .array([
                    .object([
                        "user_id": .string("1"),
                        "channel_id": .string("41"),
                        "guild_id": .null,
                        "session_id": .string("private-session"),
                        "self_mute": .bool(false),
                        "self_deaf": .bool(false),
                    ])
                ]),
            ])
        )
        let call = try #require(await created.value)
        #expect(call.channelID == ChannelID(rawValue: 41))
        #expect(call.messageID == MessageID(rawValue: 501))
        #expect(call.region == "rotterdam")
        #expect(
            call.ongoingRings == [
                PrivateCallRing(
                    recipientID: UserID(rawValue: 2),
                    senderID: UserID(rawValue: 1)
                )
            ]
        )
        #expect(call.voiceStates?.first?.guildID == nil)
        #expect(call.voiceStates?.first?.channelID == ChannelID(rawValue: 41))

        let deleted = Task { () -> (ChannelID, Bool)? in
            for await event in events {
                if case let .privateCallDeleted(channelID, unavailable) = event {
                    return (channelID, unavailable)
                }
            }
            return nil
        }
        await provider.receiveGatewayDispatchForTesting(
            name: "CALL_DELETE",
            data: .object([
                "channel_id": .string("41"),
                "unavailable": .bool(true),
            ])
        )
        let deletion = try #require(await deleted.value)
        #expect(deletion.0 == ChannelID(rawValue: 41))
        #expect(deletion.1)
        await provider.disconnect()
    }

    @Test func `guildless voice move evicts the participant from the previous call`() async throws {
        try await assertGuildlessVoiceMoveReconciliation(
            provider: makeProvider()
        )
    }

    @Test func `private call REST paths use exact bounded bodies`() async throws {
        DirectMessageURLProtocol.reset()
        let provider = makeProvider()

        #expect(
            try await provider.privateCallIsRingable(
                channelID: ChannelID(rawValue: 41)
            )
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "CALL_CREATE",
            data: .object([
                "channel_id": .string("41"),
                "message_id": .string("501"),
                "ongoing_rings": .object([:]),
            ])
        )
        try await provider.ringPrivateCall(
            channelID: ChannelID(rawValue: 41),
            recipients: nil
        )
        try await provider.stopRingingPrivateCall(
            channelID: ChannelID(rawValue: 41),
            recipients: [UserID(rawValue: 1)]
        )

        #expect(DirectMessageURLProtocol.requests.map(\.method) == [
            "GET", "POST", "POST",
        ])
        #expect(DirectMessageURLProtocol.requests.map(\.path) == [
            "/api/v9/channels/41/call",
            "/api/v9/channels/41/call/ring",
            "/api/v9/channels/41/call/stop-ringing",
        ])
        #expect(
            DirectMessageURLProtocol.requests[1].body?["recipients"] is NSNull
        )
        #expect(
            DirectMessageURLProtocol.requests[2].body?["recipients"] as? [String]
                == ["1"]
        )

        DirectMessageURLProtocol.ringStatus = 429
        await #expect(throws: ChatProviderError.self) {
            try await provider.ringPrivateCall(
                channelID: ChannelID(rawValue: 41),
                recipients: nil
            )
        }
        #expect(
            DirectMessageURLProtocol.requests.count {
                $0.path == "/api/v9/channels/41/call/ring"
            } == 2
        )
        await provider.disconnect()
    }

    @Test func `private call connect uses current gateway opcode`() throws {
        let payload = DiscordGatewayPayloadFactory.privateCallConnect(
            channelID: ChannelID(rawValue: 41)
        )
        #expect(payload["op"] as? Int == 13)
        let body = try #require(payload["d"] as? [String: Any])
        #expect(body["channel_id"] as? String == "41")
    }

    @Test func `private call subscriptions reset after Gateway resume`() async {
        let provider = makeProvider()
        let channelID = ChannelID(rawValue: 41)
        await provider.seedPrivateCallSubscriptionForTesting(channelID: channelID)
        #expect(await provider.hasPrivateCallSubscriptionForTesting(channelID: channelID))

        await provider.receiveGatewayDispatchForTesting(
            name: "RESUMED",
            data: .object([:])
        )

        #expect(!(await provider.hasPrivateCallSubscriptionForTesting(channelID: channelID)))
        await provider.disconnect()
    }

    private func seedPrivateChannelOrderReady(on provider: DiscordRESTProvider) async {
        await provider.receiveGatewayDispatchForTesting(
            name: "READY",
            data: .object([
                "guilds": .array([]),
                "users": .array([
                    user(id: "2", username: "maya", globalName: "Maya")
                ]),
                "private_channels": .array([
                    privateChannel(id: "41", lastMessageID: "500"),
                    privateChannel(id: "42", lastMessageID: nil),
                    privateChannel(id: "43", lastMessageID: "700"),
                ]),
            ])
        )
    }

    private func seedForwardSearchPeopleCache(at cacheDirectory: URL) async {
        let provider = makeProvider(usesForwardSearchPeopleDiskCache: true)
        await provider.setForwardSearchPeopleCacheDirectoryForTesting(cacheDirectory)
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE",
            data: .object([
                "id": .string("7"),
                "name": .string("Cached guild"),
                "members": .array([
                    .object([
                        "user": user(id: "2", username: "cached", globalName: "Cached User"),
                        "nick": .string("Current nickname"),
                        "roles": .array([]),
                    ]),
                    .object([
                        "user": user(id: "5", username: "live-only", globalName: "Live Only"),
                        "nick": .string("Live nickname"),
                        "roles": .array([]),
                    ])
                ]),
            ])
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "MESSAGE_CREATE",
            data: .object([
                "id": .string("1000"),
                "channel_id": .string("42"),
                "guild_id": .string("7"),
                "author": user(id: "2", username: "cached", globalName: "Cached User"),
                "member": .object([
                    "nick": .string("Historical nickname"),
                    "roles": .array([]),
                ]),
                "content": .string("cache me"),
                "timestamp": .string("2026-08-10T08:00:00.000Z"),
                "attachments": .array([]),
                "reactions": .array([]),
            ])
        )
        await provider.disconnect()
    }

    private func seedLiveForwardSearchUsers(on provider: DiscordRESTProvider) async {
        await provider.receiveGatewayDispatchForTesting(
            name: "GUILD_CREATE",
            data: .object([
                "id": .string("8"),
                "name": .string("Ready guild"),
                "members": .array([
                    .object([
                        "user": user(id: "2", username: "cached", globalName: "Cached User"),
                        "nick": .string("Ready nickname"),
                        "roles": .array([]),
                    ])
                ]),
            ])
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "MESSAGE_CREATE",
            data: .object([
                "id": .string("1001"),
                "channel_id": .string("43"),
                "guild_id": .string("6"),
                "author": user(id: "4", username: "later", globalName: "Later User"),
                "member": .object([
                    "nick": .string("Later nickname"),
                    "roles": .array([]),
                ]),
                "mentions": .array([
                    user(id: "2", username: "cached", globalName: "Cached User")
                ]),
                "content": .string("learn after Ready"),
                "timestamp": .string("2026-08-10T08:01:00.000Z"),
                "attachments": .array([]),
                "reactions": .array([]),
            ])
        )
        await provider.receiveGatewayDispatchForTesting(
            name: "MESSAGE_CREATE",
            data: .object([
                "id": .string("1002"),
                "channel_id": .string("43"),
                "guild_id": .string("6"),
                "author": user(id: "2", username: "cached", globalName: "Cached User"),
                "member": .object([
                    "nick": .string("Later guild nickname"),
                    "roles": .array([]),
                ]),
                "content": .string("learn a later guild alias"),
                "timestamp": .string("2026-08-10T08:02:00.000Z"),
                "attachments": .array([]),
                "reactions": .array([]),
            ])
        )
    }

    private func privateChannel(
        id: String,
        lastMessageID: String?,
        recipientID: String = "2"
    ) -> JSONValue {
        var values: [String: JSONValue] = [
            "id": .string(id),
            "type": .number(1),
            "recipient_ids": .array([.string(recipientID)]),
        ]
        values["last_message_id"] = lastMessageID.map { .string($0) } ?? .null
        return .object(values)
    }

    private func user(
        id: String,
        username: String,
        globalName: String,
        system: Bool = false
    ) -> JSONValue {
        .object([
            "id": .string(id),
            "username": .string(username),
            "global_name": .string(globalName),
            "avatar": .null,
            "system": .bool(system),
        ])
    }

    private func makeProvider(
        usesForwardSearchPeopleDiskCache: Bool? = nil
    ) -> DiscordRESTProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DirectMessageURLProtocol.self]
        return DiscordRESTProvider(
            credentials: DirectMessageCredentialStore(),
            handle: CredentialHandle(accountID: "dm-contract"),
            session: URLSession(configuration: configuration),
            usesForwardSearchPeopleDiskCache: usesForwardSearchPeopleDiskCache
        )
    }
}

private func assertGuildlessVoiceMoveReconciliation(
    provider: DiscordRESTProvider
) async throws {
    await provider.receiveGatewayDispatchForTesting(
        name: "CALL_CREATE",
        data: privateCallPayload(
            channelID: "41",
            messageID: "501",
            voiceState: .object([
                "user_id": .string("9"),
                "channel_id": .string("41"),
                "guild_id": .null,
                "session_id": .string("private-session-a")
            ])
        )
    )
    await provider.receiveGatewayDispatchForTesting(
        name: "CALL_CREATE",
        data: privateCallPayload(
            channelID: "42",
            messageID: "502",
            voiceState: nil
        )
    )

    let events = await provider.eventStream()
    let changedCalls = Task {
        await nextPrivateCallChanges(count: 2, from: events)
    }

    await provider.receiveGatewayDispatchForTesting(
        name: "VOICE_STATE_UPDATE",
        data: .object([
            "user_id": .string("9"),
            "channel_id": .string("42"),
            "guild_id": .null,
            "session_id": .string("private-session-b"),
            "self_mute": .bool(false),
            "self_deaf": .bool(false)
        ])
    )

    let calls = await changedCalls.value
    #expect(calls.map(\.channelID) == [
        ChannelID(rawValue: 41),
        ChannelID(rawValue: 42)
    ])
    #expect(calls[0].voiceStates?.isEmpty == true)
    #expect(calls[1].voiceStates?.map(\.userID) == [UserID(rawValue: 9)])
    #expect(calls[1].voiceStates?.first?.sessionID == "private-session-b")
    await provider.disconnect()
}

private func nextPrivateCallChanges(
    count: Int,
    from events: AsyncStream<ClientEvent>
) async -> [PrivateCall] {
    var calls: [PrivateCall] = []
    for await event in events {
        guard case let .privateCallChanged(call) = event else {
            continue
        }
        calls.append(call)
        if calls.count == count {
            return calls
        }
    }
    return calls
}

private func privateCallPayload(
    channelID: String,
    messageID: String,
    voiceState: JSONValue?
) -> JSONValue {
    .object([
        "channel_id": .string(channelID),
        "message_id": .string(messageID),
        "ongoing_rings": .object([:]),
        "voice_states": .array(voiceState.map { [$0] } ?? [])
    ])
}

actor DirectMessageCredentialStore: CredentialStore {
    func store(
        _ credential: Data,
        accountID: String
    ) async throws -> CredentialHandle {
        CredentialHandle(accountID: accountID)
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        Data("dm-contract-session".utf8)
    }

    func remove(_ handle: CredentialHandle) async throws {}

    func handles() async throws -> [CredentialHandle] {
        [CredentialHandle(accountID: "dm-contract")]
    }
}

private actor ProfileSaveReceipt {
    var changes: ProfileEditChanges
    var stages: [ProfileSaveStage] = []
    var snapshots: [ProfileEditingSnapshot?] = []

    init(_ changes: ProfileEditChanges) { self.changes = changes }

    func accept(_ confirmation: ProfileSaveConfirmation) {
        changes.acknowledge(confirmation.stage)
        stages.append(confirmation.stage)
        snapshots.append(confirmation.snapshot)
    }
}

struct CapturedQueryItem: Equatable, Sendable {
    var name: String
    var value: String?
}

struct CapturedDirectMessageRequest: @unchecked Sendable {
    var method: String
    var path: String
    var encodedPath: String
    var query: [CapturedQueryItem]
    var hadAuthorization: Bool
    var contentType: String?
    var body: [String: Any]?
    var receivedAt = ContinuousClock.now
}

final class DirectMessageURLProtocol:
    URLProtocol,
    @unchecked Sendable
{
    nonisolated(unsafe) static var requests:
        [CapturedDirectMessageRequest] = []
    nonisolated(unsafe) static var ringStatus = 204
    nonisolated(unsafe) static var profileHasEffect = false
    /// Replies consumed in order by settings-proto/1 requests; when empty, a
    /// PATCH echoes its settings.
    nonisolated(unsafe) static var settingsReplies: [SettingsProtocolReply] = []

    static func reset() {
        requests = []
        ringStatus = 204
        profileHasEffect = false
        settingsReplies = []
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        let requestBody = Self.requestBody(request).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let query = URLComponents(
            url: request.url!,
            resolvingAgainstBaseURL: false
        )?.queryItems?.map {
            CapturedQueryItem(name: $0.name, value: $0.value)
        } ?? []
        Self.requests.append(
            CapturedDirectMessageRequest(
                method: request.httpMethod ?? "",
                path: request.url?.path ?? "",
                encodedPath: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "",
                query: query,
                hadAuthorization:
                    request.value(
                        forHTTPHeaderField: "Authorization"
                    ) != nil,
                contentType: request.value(forHTTPHeaderField: "Content-Type"),
                body: requestBody
            )
        )

        var body: String
        do {
            body = try Self.responseBody(path: request.url?.path, query: query, requestBody: requestBody)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        var status: Int
        var responseGate: StatusRecoveryResponseGate?
        if request.url?.path == "/api/v9/users/@me/settings-proto/1", !Self.settingsReplies.isEmpty {
            let reply = Self.settingsReplies.removeFirst()
            status = reply.status
            body = reply.body
            responseGate = reply.gate
        } else if requestBody?["bio"] as? String == "rejected-bio" {
            status = 400
        } else if request.url?.path == "/api/v9/games/autocomplete", query.first?.value == "unavailable" {
            status = 503
        } else {
            status = request.url?.path == "/api/v9/channels/41/call/ring" ? Self.ringStatus : 200
        }
        if let gate = responseGate {
            let responseStatus = status, responseBody = body
            gate.capture { [self] in completeResponse(status: responseStatus, body: responseBody) }
            return
        }
        completeResponse(status: status, body: body)
    }

    private static func responseBody(
        path: String?,
        query: [CapturedQueryItem],
        requestBody: [String: Any]?
    ) throws -> String {
        switch path {
        case "/api/v9/oauth2/tokens":
            return #"[{"id":"grant21","application":{"id":"21"},"scopes":["application_identities.write"]},{"id":"old-grant","application":{"id":"22"},"scopes":["identify"]}]"#
        case "/api/v9/users/@me/settings-proto/1":
            return String(data: try JSONSerialization.data(withJSONObject: ["settings": requestBody?["settings"] as? String ?? ""]), encoding: .utf8)!
        case "/api/v9/users/@me/widgets/assets/upload":
            return #"{"upload_url":"https://storage.example/widget-image?signature=fixture","upload_filename":"reserved/cover.png"}"#
        case "/api/v9/users/@me/widgets/suggested-games":
            return #"{"suggested_games":["21","22"],"suggested_wishlist_games":["31"]}"#
        case "/widget-image":
            return ""
        case "/api/v9/users/@me":
            if requestBody?["display_name_colors"] != nil {
                return requestBody?["display_name_effect_id"] as? Int == 5
                    ? #"{"id":"2","username":"maya","premium_type":2,"display_name_styles":{"font_id":11,"effect_id":5,"colors":[1036166]}}"#
                    : #"{"id":"2","username":"maya","premium_type":2,"display_name_styles":{"font_id":11,"effect_id":1,"colors":[]}}"#
            }
            return requestBody?["global_name"] as? String == "malformed-response"
                ? "{}" : #"{"id":"2","username":"maya","global_name":"Updated","avatar":null}"#
        case "/api/v9/users/@me/profile":
            return requestBody?["bio"] as? String == "rejected-bio"
                ? #"{"code":50035,"message":"Invalid Form Body","errors":{"bio":{"_errors":[{"code":"BASE_TYPE_MAX_LENGTH","message":"About Me is too long."}]}}}"#
                : #"{"bio":"Accepted bio","pronouns":"","banner":null,"theme_colors":null,"collectibles":[]}"#
        case "/api/v9/guilds/10/members/@me":
            return #"{"user":{"id":"2","username":"maya"},"roles":[],"nick":null,"avatar":null,"collectibles":{"nameplate":null}}"#
        case "/api/v9/guilds/10/profile/@me":
            return #"{"bio":"","pronouns":"","banner":null,"theme_colors":null,"collectibles":[]}"#
        case "/api/v9/users/@me/widgets":
            return #"{"widgets":[{"id":"700","updated_at":"2026-09-05T12:00:00.000000+00:00","data":{"type":"application","application_id":"7"}}]}"#
        case "/api/v9/channels/41/messages":
            return #"""
            [{
              "id":"800","channel_id":"41",
              "author":{"id":"77","username":"history-author","global_name":"History Author"},
              "content":"history","timestamp":"2026-07-29T08:00:00.000Z",
              "mentions":[{"id":"78","username":"history-mention","global_name":"History Mention"}],
              "attachments":[],"reactions":[]
            }]
            """#
        case "/api/v9/collectibles-products/900":
            return #"""
            {"sku_id":"900","name":"Aurora","summary":"Profile effect","type":1,"premium_type":0,
             "items":[{"type":1,"sku_id":"900","title":"Aurora",
             "thumbnailPreviewSrc":"https://cdn.discordapp.com/assets/content/aurora-preview","effects":[] }]}
            """#
        case "/api/v9/channels/41/call":
            return #"{"ringable":true}"#
        default:
            return try profileResponseBody(path: path, query: query, requestBody: requestBody)
                ?? gameResponseBody(path: path, query: query)
        }
    }

    private static func profileResponseBody(
        path: String?, query: [CapturedQueryItem], requestBody: [String: Any]?
    ) throws -> String? {
        switch path {
        case "/api/v9/users/@me/clan":
            return try serverTagResponse(requestBody)
        case "/api/v9/users/2/profile":
            return profileHasEffect
                ? #"""
                {
                  "user":{"id":"2","username":"maya","global_name":"Maya","avatar":null},
                  "user_profile":{"profile_effect":{"sku_id":"900"}},
                  "mutual_guilds":[],"mutual_friends":[],"mutual_friends_count":0
                }
                """#
                : query.contains(where: { $0.name == "guild_id" })
                    ? #"""
                    {"user":{"id":"2","username":"maya","global_name":"Maya","avatar":null},"premium_type":2,
                     "guild_member":{"nick":null,"avatar":null},"guild_member_profile":{"bio":"","pronouns":"","theme_colors":null},"widgets":[],
                     "mutual_guilds":[],"mutual_friends":[],"mutual_friends_count":0}
                    """#
                    : #"{"user":{"id":"2","username":"maya","global_name":"Maya","avatar":null},"premium_type":2,"widgets":[],"mutual_guilds":[],"mutual_friends":[],"mutual_friends_count":0}"#
        default: return nil
        }
    }

    private static func serverTagResponse(_ requestBody: [String: Any]?) throws -> String {
        let enabled = requestBody?["identity_enabled"] as? Bool == true
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "2", "username": "maya", "global_name": "Maya", "avatar": NSNull(),
            "primary_guild": ["identity_guild_id": requestBody?["identity_guild_id"] ?? NSNull(),
                              "identity_enabled": enabled, "tag": enabled ? "TEST" as Any : NSNull()]
        ])
        return String(data: data, encoding: .utf8)!
    }

    private static func gameResponseBody(path: String?, query: [CapturedQueryItem]) -> String {
        switch path {
        case "/api/v9/content-inventory/users/@me/similar-games/21":
            return #"{"similar_games":["21","22","23","24","700136079562375258"]}"#
        case "/api/v9/games":
            return #"[{"id":"22","name":"Available","game_flags":0},{"id":"23","name":"Hidden","game_flags":1},{"id":"24","name":"Adult","content_classification":{"discord_classifications":8}}]"#
        case "/api/v9/games/21/announcements":
            return ##"""
            {"messages":[
              {"id":"800","channel_id":"41","author":{"id":"77","username":"publisher"},"content":"# Update\nNew features","timestamp":"2026-09-05T12:00:00Z"},
              {"id":"801","channel_id":"41","author":{"id":"77","username":"publisher"},
               "content":"https://example.com/news","timestamp":"2026-09-05T12:00:00Z",
               "embeds":[{"title":"Embed title","description":"Embed body","provider":{"name":"Publisher"},"video":{"url":"https://example.com/video.mp4"},
               "thumbnail":{"url":"https://example.com/poster.png"}}]},
              {"id":"802","channel_id":"41","author":{"id":"77","username":"publisher"},"content":"","timestamp":"2026-09-05T12:00:00Z",
               "poll":{"question":{"text":"Next update?"},"answers":[{"answer_id":1,"poll_media":{"text":"New map"}}],"expiry":"2026-09-06T12:00:00Z"}}
            ],"channel_id":"41","guild_id":"10"}
            """##
        case "/api/v9/games/autocomplete":
            return query.first?.value == "unavailable" ? #"{"message":"Unavailable"}"# : #"[{"id":"21","name":"Test Game"}]"#
        default:
            return "{}"
        }
    }

    override func stopLoading() {}

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
