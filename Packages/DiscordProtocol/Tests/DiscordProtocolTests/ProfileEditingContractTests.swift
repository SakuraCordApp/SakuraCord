@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

@Test func `game metadata preserves media reviews role ownership and profile availability`() throws {
    let dto = try JSONDecoder().decode(ProfileGameDTO.self, from: Data(#"""
    {"id":"21","name":"Test Game","game_flags":1,"description":"Game description","genres":[16,28],"platforms":[7],
     "companies":[{"name":"Studio","roles":[1,2]}],"first_release_date":"2025-01-01T00:00:00+00:00",
     "media":{"cover":{"type":"hash","value":"aabb"},"icon":{"type":"hash","value":"ccdd"}},
     "websites":[{"category":1,"url":"https://example.com"}],"third_party_skus":[{"distributor":"steam","id":null},{"distributor":"steam","id":"123"}],
     "linked_applications":[{"id":"22","type":1},{"id":"23","type":2}],"steam_release_status":4,
     "reviews":{"steam":{"rating":93,"rating_count":2500,"localized_rating":95,"localized_rating_count":300},
                "opencritic":{"tier":3,"top_critic_rating":68.7}},"opencritic_url":"https://opencritic.com/game/123/test"}
    """#.utf8))
    let game = dto.domain
    let details = try #require(game.metadata)
    #expect(game.coverURL?.absoluteString == "https://cdn.discordapp.com/app-icons/21/aabb.webp?size=256&keep_aspect_ratio=true")
    #expect(details.description == "Game description")
    #expect(details.genres == [16, 28] && details.platforms == [7])
    #expect(details.publishers == ["Studio"] && details.developers == ["Studio"])
    #expect(details.releaseDate == Date(timeIntervalSince1970: 1_735_689_600))
    #expect(details.steamURL?.absoluteString == "https://store.steampowered.com/app/123")
    #expect(details.officialApplicationID == "23")
    #expect(details.isRetiredFromSteam && !details.isProfileAvailable)
    #expect(details.steamReviews?.localizedCount == 300)
    #expect(details.criticReviews?.rating == 68.7)
}

@Test func `widget replacement drops blank drafts and omits cleared images while preserving game nulls`() throws {
    let originals = try JSONDecoder().decode([ProfileWidgetDTO].self, from: Data(#"""
    [{"id":"10","data":{"type":"personal","header":"About","sections":[
      {"type":"cover","title":"Hello","subtitle":"","image":null},
      {"type":"fields","fields":[{"title":" ","description":"\n","image":null}]}]}},
     {"id":"11","data":{"type":"current_games","games":[{"game_id":"12","comment":null,"tags":null}]}}]
    """#.utf8))
    let userID = UserID(rawValue: 2)
    var widgets = try originals.map { try $0.domain(userID: userID) }
    var equivalentGames = widgets[1]
    equivalentGames.content = .games(.rotation, [ProfileWidgetGame(id: "12", tags: [])])
    #expect(widgets[1].hasSameEditableContent(as: equivalentGames))
    equivalentGames.content = .games(.rotation, [ProfileWidgetGame(id: "12", tags: ["casual"])])
    #expect(!widgets[1].hasSameEditableContent(as: equivalentGames))
    widgets.append(ProfileWidget(content: .games(.favorite, [])))
    widgets.append(ProfileWidget(content: .personal(ProfilePersonalWidget(header: "Blank", sections: [.cover(ProfileWidgetCover(title: " "))]))))
    let request = try ProfileEditingRequest.widgets(widgets, originals: originals, userID: userID)
    #expect(request.body == ["widgets": .array([
        .object(["id": .string("10"), "data": .object([
            "type": .string("personal"), "header": .string("About"), "sections": .array([
                .object(["type": .string("cover"), "title": .string("Hello"), "subtitle": .string("")])
            ])
        ])]),
        .object(["id": .string("11"), "data": .object([
            "type": .string("current_games"), "games": .array([
                .object(["game_id": .string("12"), "comment": .null, "tags": .null])
            ])
        ])])
    ])])
}

@Test func `application widgets resolve typed identity precedence fallback and duration units`() throws {
    let response = try JSONDecoder().decode(ProfileWidgetIdentitiesDTO.self, from: Data(#"""
    {"identities":[{"application_id":"7","profile":{"username":"initial","data":{
      "primary":{"username":"primary","progress":0.1,"playtime_hours":1.5},
      "dynamic":[{"type":1,"name":"username","value":"latest"},{"type":2,"name":"progress","value":0.69},
                 {"type":3,"name":"invalid_image","value":{"proxy_url":"https://media.example/image","width":0,"height":100}}]
    }}}]}
    """#.utf8))
    let values = try #require(response.identities.first?.domain.data)
    #expect(values["username"] == .text("latest"))
    #expect(values["progress"] == .number(0.69))
    #expect(values["invalid_image"] == nil)
    let fallback = ProfileWidgetConfiguredField(presentation: "text", source: .literal(.text("Unavailable")))
    let mismatched = ProfileWidgetConfiguredField(presentation: "text", source: .data(key: "progress", fallback: fallback))
    #expect(mismatched.resolve(data: values) == .text("Unavailable"))
    let duration = ProfileWidgetConfiguredField(presentation: "duration", source: .data(key: "playtime_hours", fallback: nil))
    #expect(duration.resolve(data: values) == .number(5_400_000))
    let config = try JSONDecoder().decode(ProfileApplicationWidgetDTO.self, from: Data(#"""
    {"config_id":"8","application_id":"7","display_name":"Progress","status":"published",
     "surfaces":{"widget_top":{"layout":"widget_top_hero","components":{"hero_image":{"fields":{
       "image":{"value_type":"application_asset","presentation_type":"image","value":"hero"}}}}}},
     "resolved_assets":[{"key":"hero","asset_id":"9","metadata":{"width":516,"height":432,"is_animated":true}}]}
    """#.utf8)).domain()
    let image = config.surfaces["widget_top"]?.components["hero_image"]?["image"]?.resolve(data: values)
    #expect(image == .image(url: URL(string: "https://cdn.discordapp.com/app-assets/7/9.webp?size=600&animated=true")!, width: 516, height: 432))
}

@Test func `global profile updates preserve explicit matching server nickname and server cosmetics`() throws {
    let dto = try JSONDecoder().decode(GuildMemberDTO.self, from: Data(#"""
    {"user":{"id":"2","username":"maya","global_name":"Maya"},"nick":"Maya","roles":[],
     "display_name_styles":{"font_id":3,"effect_id":1,"colors":[123]},
     "collectibles":{"nameplate":{"sku_id":"100","label":"Flowers","palette":"forest"}}}
    """#.utf8))
    var member = try dto.domain(currentUserID: nil, currentStatus: .offline, guildID: GuildID(rawValue: 10))
    var updated = try dto.user.domain()
    updated.displayName = "New main name"
    updated.displayNameStyle = DisplayNameStyle(fontID: 6, effectID: 1, colors: [456])
    member.applyGlobalProfileUser(updated)
    #expect(member.user.displayName == "Maya")
    #expect(member.globalDisplayName == "New main name")
    #expect(member.user.displayNameStyle?.fontID == 3)
    #expect(member.user.nameplate?.palette == "forest")
}

@Test func `custom status activities preserve emoji without status text`() throws {
    let activities = try JSONDecoder().decode([GuildActivityDTO].self, from: Data(#"""
    [
      {"type":4,"name":"Custom Status","state":"","emoji":{"name":"🤔"}},
      {"type":4,"name":"Custom Status","emoji":{"id":"123456789","name":"thinking","animated":true}},
      {"type":4,"name":"Custom Status","state":"Working","emoji":{"name":"🌸"}},
      {"type":4,"name":"Custom Status"}
    ]
    """#.utf8))
    #expect(activities.map(\.displayText) == ["🤔", "<a:thinking:123456789>", "🌸 Working", nil])
}

@Test func `draft projection restores inheritance without changing raw server values`() throws {
    let user = User(id: UserID(rawValue: 2), username: "maya", displayName: "Main name")
    let avatar = URL(string: "https://cdn.example/main.png")!
    let main = UserProfile(user: user, avatarURL: avatar, themeHexes: [0x123456, 0xABCDEF], bio: "Main bio")
    var scoped = main
    scoped.displayName = "Server name"
    scoped.bio = "Server bio"
    scoped.themeHexes = [1, 2]
    let snapshot = ProfileEditingSnapshot(
        scope: .server(GuildID(rawValue: 10)), mainIdentity: ProfileIdentityFields(), mainMetadata: ProfileMetadataFields(),
        serverIdentity: ProfileIdentityFields(name: .value("Server name")),
        serverMetadata: ProfileMetadataFields(bio: .value("Server bio")),
        presentation: scoped, mainPresentation: main,
        widgetEligibility: ProfileWidgetEligibility(hasFullNitro: true, hasPersonalWidgetAccess: false)
    )
    var changes = ProfileEditChanges()
    changes.identity.name = .clear
    changes.identity.avatar = .clear
    changes.metadata.bio = .set("")
    changes.metadata.themeColors = .clear
    let result = ProfileDraftProjection.resolve(snapshot: snapshot, changes: changes, inventory: nil)
    #expect(result.displayName == "Main name")
    #expect(result.avatarURL == avatar)
    #expect(result.bio == "Main bio")
    #expect(result.themeHexes == [0x123456, 0xABCDEF])
    var partialTheme = changes
    partialTheme.metadata.themeColors = .set(ProfileThemeColors(primary: nil, accent: 0xFF0000))
    #expect(ProfileDraftProjection.resolve(snapshot: snapshot, changes: partialTheme, inventory: nil).themeHexes == [0x123456, 0xABCDEF])
    let metadata = try JSONDecoder().decode(ProfileMetadataDTO.self, from: Data(#"{"theme_colors":[null,16711680]}"#.utf8))
    #expect(metadata.themeColors == [nil, 0xFF0000])
    #expect(metadata.renderedThemeColors == [])
    #expect(snapshot.serverIdentity?.name == .value("Server name"))
    #expect(snapshot.serverMetadata?.bio == .value("Server bio"))
}

@Test func `collectible variants retain independent ownership and expired purchases fail closed`() throws {
    let product = try JSONDecoder().decode(ProfileCollectibleProductDTO.self, from: Data(#"""
    {"sku_id":"100","name":"Flowers","summary":"Nameplate","type":2000,"premium_type":0,"items":[],
     "variants":[
       {"sku_id":"100","name":"Base","summary":"Nameplate","type":2,"premium_type":0,"variant_label":"Base",
        "items":[{"type":2,"sku_id":"100","label":"Flowers","palette":"forest"}]},
       {"sku_id":"101","name":"Blue","summary":"Nameplate","type":2,"premium_type":0,"base_variant_sku_id":"100",
        "items":[{"type":2,"sku_id":"101","label":"Blue flowers","palette":"cobalt"}]}
     ]}
    """#.utf8)).domain
    var purchase = try #require(product.variants.first)
    var inventory = ProfileCollectibleInventory(
        categories: [ProfileCollectibleCategory(id: "90", name: "Garden", summary: "", bannerURL: nil, products: [product])],
        purchases: [purchase]
    )
    #expect(inventory.owns(itemID: "100"))
    #expect(!inventory.owns(itemID: "101"))
    #expect(inventory.item(id: "101")?.kind == .nameplate)
    #expect(inventory.items(of: .nameplate).map(\.id) == ["100", "101"])
    #expect(!inventory.canUse(itemID: "101", hasFullNitro: true))
    // A catalogue's premium marker does not classify an owned purchase. The
    // official picker uses purchase_type == PREMIUM_PURCHASE (7).
    purchase.premiumType = 2
    purchase.purchaseType = 1
    inventory.purchases = [purchase]
    #expect(inventory.canUse(itemID: "100", hasFullNitro: false))
    purchase.premiumType = 0
    purchase.purchaseType = 7
    inventory.purchases = [purchase]
    #expect(inventory.requiresNitro(itemID: "100"))
    #expect(!inventory.canUse(itemID: "100", hasFullNitro: false))
    #expect(inventory.canUse(itemID: "100", hasFullNitro: true))
    purchase.expiresAt = .distantPast
    inventory.purchases = [purchase]
    #expect(!inventory.owns(itemID: "100"))

    let expired = try JSONDecoder().decode(ProfileCollectibleProductDTO.self, from: Data(#"""
    {"sku_id":"102","name":"Temporary","summary":"Nameplate","type":2,"premium_type":0,
     "expires_at":"unrecognized date","items":[{"type":2,"sku_id":"102","label":"Temporary"}]}
    """#.utf8)).domain
    inventory.purchases = [expired]
    #expect(!inventory.owns(itemID: "102"))
}

@Test func `identity changes preserve scope specific nameplate and style clearing contracts`() throws {
    #expect(ProfileEditingRequest.identity(ProfileIdentityChanges(), in: .main) == nil)
    var changes = ProfileIdentityChanges()
    changes.name = .set("")
    changes.nameplateSKUID = .clear
    changes.displayNameStyle = .clear
    let main = try #require(ProfileEditingRequest.identity(changes, in: .main))
    let server = try #require(ProfileEditingRequest.identity(changes, in: .server(GuildID(rawValue: 10))))
    #expect(main.path == "/users/@me")
    #expect(server.path == "/guilds/10/members/@me")
    #expect(main.method == "PATCH")
    #expect(server.method == "PATCH")
    #expect(main.body == [
        "global_name": .string(""), "nameplate_sku_id": .null,
        "display_name_font_id": .null, "display_name_effect_id": .null, "display_name_colors": .null,
    ])
    #expect(server.body == [
        "nick": .string(""), "collectibles": .object(["nameplate": .null]),
        "display_name_font_id": .null, "display_name_effect_id": .null, "display_name_colors": .null,
    ])
}

@Test func `server tag metadata survives nested gateway state and explicit removal`() throws {
    let decoder = JSONDecoder()
    let readyGuild = try decoder.decode(GatewayReadyGuildsDTO.GuildReference.self, from: Data(#"""
    {"id":"90","properties":{"name":"Garden","features":["GUILD_TAGS"],
      "profile":{"tag":"LEAF","badge":"badge-hash"}}}
    """#.utf8))
    let guild = try #require(readyGuild.domain(currentUserID: nil))
    #expect(guild.profileTag?.guildID == GuildID(rawValue: 90))
    #expect(guild.profileTag?.tag == "LEAF")
    #expect(guild.profileTag?.badgeURL?.absoluteString == "https://cdn.discordapp.com/clan-badges/90/badge-hash.png?size=16")
    let rename = try decoder.decode(GatewayGuildPatchDTO.self, from: Data(#"{"id":"90","name":"New Garden"}"#.utf8))
    let renamed = try #require(rename.applying(to: guild, currentUserID: nil))
    #expect(renamed.profileTag == guild.profileTag)
    #expect(renamed.features == ["GUILD_TAGS"])
    let removal = try decoder.decode(GatewayGuildPatchDTO.self, from: Data(#"{"id":"90","properties":{"profile":null,"features":[]}}"#.utf8))
    let removed = try #require(removal.applying(to: renamed, currentUserID: nil))
    #expect(removed.profileTag == nil)
    #expect(removed.features.isEmpty)
}

@Test func `custom status matches the captured protobuf and preserves independent status settings`() throws {
    // R177: controlled research text; no account identifiers or credentials.
    let encoded = "WlAKCwoJaW52aXNpYmxlEjYKIlRlc3RpbmcgcHJvZmlsZSBjdXN0b21pemF0aW9uIPCfjLghYwyBdKABAAApY7Bab6ABAAAaACoHCMX+7NGFNA=="
    let patch = try #require(Data(base64Encoded: encoded))
    let settings = try #require(DiscordSettingsProto.statusSettings(in: patch))
    let status = try #require(DiscordSettingsProto.customStatus(in: settings))
    #expect(status.text == "Testing profile customization 🌸")
    #expect(status.emojiID == nil)
    #expect(status.emojiName == nil)
    #expect(status.expiresAt == Date(timeIntervalSince1970: 1_788_661_009.507))
    #expect(status.createdAt == Date(timeIntervalSince1970: 1_788_574_609.507))
    #expect(DiscordSettingsProto.updatingCustomStatus(status, in: settings) == patch)
    let clearedPatch = DiscordSettingsProto.updatingCustomStatus(nil, in: settings)
    let cleared = try #require(DiscordSettingsProto.statusSettings(in: clearedPatch))
    #expect(DiscordSettingsProto.customStatus(in: cleared) == nil)
    // The three retained siblings are presence, show_current_game and
    // status_created_at_ms. Clearing must not turn Invisible into Online.
    #expect(cleared.base64EncodedString() == "CgsKCWludmlzaWJsZRoAKgcIxf7s0YU0")
    var emojiStatus = status
    emojiStatus.text = ""
    emojiStatus.emojiID = "123456789012345678"
    emojiStatus.emojiName = "flower"
    emojiStatus.expiresAt = nil
    let emojiPatch = DiscordSettingsProto.updatingCustomStatus(emojiStatus, in: cleared)
    let emojiSettings = try #require(DiscordSettingsProto.statusSettings(in: emojiPatch))
    #expect(DiscordSettingsProto.customStatus(in: emojiSettings) == emojiStatus)
}

@Test func `profile resets encode ordered unset colors and empty collectible selection`() throws {
    #expect(ProfileEditingRequest.metadata(ProfileMetadataChanges(), in: .main) == nil)
    var changes = ProfileMetadataChanges()
    changes.banner = .clear
    changes.themeColors = .clear
    changes.collectibleSKUIDs = .clear
    let main = try #require(ProfileEditingRequest.metadata(changes, in: .main))
    let server = try #require(ProfileEditingRequest.metadata(changes, in: .server(GuildID(rawValue: 10))))
    #expect(main.path == "/users/%40me/profile")
    #expect(server.path == "/guilds/10/profile/%40me")
    #expect(main.body == [
        "banner": .null, "theme_colors": .array([.null, .null]), "collectibles_sku_ids": .array([]),
    ])
    #expect(server.body == main.body)
    #expect(ProfileEditingRequest.serverTag(nil).body == [
        "identity_guild_id": .null, "identity_enabled": .bool(false),
    ])
}

@Test func `unchanged archived avatar uses its id while cropped media uploads bytes and original digest`() throws {
    let entries = try JSONDecoder().decode(ProfileAvatarHistoryDTO.self, from: Data(#"""
    {"avatars":[{"id":"100","storage_hash":"a_saved","description":"Animated avatar"},
                {"id":"101","storage_hash":"saved","description":"Static avatar"}]}
    """#.utf8)).domain(for: UserID(rawValue: 2))
    let entry = try #require(entries.first)
    #expect(entry.imageURL.absoluteString == "https://cdn.discordapp.com/avatars/2/archived/100/a_saved.webp?size=128&animated=true")
    #expect(entry.cropImageURL.absoluteString == "https://cdn.discordapp.com/avatars/2/archived/100/a_saved.webp?size=2048&animated=true")
    #expect(entries.last?.cropImageURL.absoluteString == "https://cdn.discordapp.com/avatars/2/archived/101/saved.webp?size=2048")
    var changes = ProfileIdentityChanges()
    changes.avatar = .set(.history(entry))
    let history = try #require(ProfileEditingRequest.identity(changes, in: .main))
    #expect(history.body == ["avatar_id": .string("100")])
    #expect(history.headers.isEmpty)

    changes.avatar = .set(.upload(ProfileImageUpload(
        data: Data([1, 2, 3]), mediaType: "image/png", description: "Edited avatar",
        originalMD5: "0123456789abcdef0123456789abcdef"
    )))
    let cropped = try #require(ProfileEditingRequest.identity(changes, in: .server(GuildID(rawValue: 10))))
    #expect(cropped.body == [
        "avatar": .string("data:image/png;base64,AQID"), "avatar_description": .string("Edited avatar"),
    ])
    #expect(cropped.headers == [
        "X-Discord-Original-MD5": "user_guild_profile_avatar=\"0123456789abcdef0123456789abcdef\""
    ])
}

@Test func `editor retains omitted null empty and inherited profile values`() throws {
    let identity = try JSONDecoder().decode(
        ProfileEditingIdentityDTO.self,
        from: Data(#"{"nick":null,"avatar":null,"collectibles":{"nameplate":null}}"#.utf8)
    ).fields
    let metadata = try JSONDecoder().decode(
        ProfileEditingMetadataDTO.self,
        from: Data(#"{"bio":"","pronouns":"","banner":null,"theme_colors":[null,null],"collectibles":[]}"#.utf8)
    ).fields

    #expect(identity.name == .null)
    #expect(identity.avatarHash == .null)
    #expect(identity.nameplateSKUID == .null)
    #expect(identity.decorationSKUID == .missing)
    #expect(identity.displayNameStyle == .missing)
    #expect(metadata.bio == .value(""))
    #expect(metadata.pronouns == .value(""))
    #expect(metadata.bannerHash == .null)
    #expect(metadata.accentColor == .missing)
    #expect(metadata.themeColors == .value(ProfileThemeColors(primary: nil, accent: nil)))
    #expect(metadata.collectibles == .value([]))
    #expect(ProfileChange<String>.unchanged.applying(to: identity.avatarHash) == .null)
    #expect(ProfileChange<String>.unchanged.applying(to: identity.decorationSKUID) == .missing)
}

@Test func `editor preserves ordered integer colors and rejects malformed editable values`() throws {
    let metadata = try JSONDecoder().decode(
        ProfileEditingMetadataDTO.self,
        from: Data(#"{"theme_colors":[1193046,6636321]}"#.utf8)
    )
    #expect(metadata.fields.themeColors == .value(ProfileThemeColors(primary: 0x123456, accent: 0x654321)))

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(
            ProfileEditingMetadataDTO.self, from: Data(#"{"theme_colors":[1193046]}"#.utf8)
        )
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(
            ProfileEditingIdentityDTO.self, from: Data(#"{"display_name_styles":{"colors":"unknown"}}"#.utf8)
        )
    }
}

@Test func `server tag decoding keeps disabled distinct from system unset`() throws {
    let disabled = try JSONDecoder().decode(
        ProfileEditingIdentityDTO.self,
        from: Data(#"{"primary_guild":{"identity_guild_id":null,"identity_enabled":false}}"#.utf8)
    )
    let unset = try JSONDecoder().decode(
        ProfileEditingIdentityDTO.self,
        from: Data(#"{"primary_guild":{"identity_guild_id":null,"identity_enabled":null}}"#.utf8)
    )
    #expect(disabled.serverTag.value?.isEnabled == .value(false))
    #expect(unset.serverTag.value?.isEnabled == .null)
}

@Test func `personal widget editing requires matching rollout and full Nitro`() throws {
    func rollout(userID: String, _ assignment: String) throws -> DiscordExperiments {
        let apex = try JSONDecoder().decode(JSONValue.self, from: Data(
            #"{"assignments":{"1":{"\#(userID)":{"assignments":[\#(assignment)]}}}}"#.utf8
        ))
        return DiscordExperiments(user: nil, guild: nil, apex: apex, userID: userID)
    }
    var user = User(id: UserID(rawValue: 42), username: "member", displayName: "Member", premiumType: 2)
    let enabled = try rollout(userID: "42", "[2369760879,1,2,1,null,null]")
    #expect(enabled.widgetEligibility(for: user).canEditPersonalWidget)
    #expect(!enabled.widgetEligibility(for: user).showsPersonalWidgetCreateEntrypoint)

    for premiumType in [0, 1, 3] {
        user.premiumType = premiumType
        #expect(!enabled.widgetEligibility(for: user).canEditPersonalWidget)
    }
    user.premiumType = 2
    // An eligibility-only assignment, an unknown variant, and another user's unit.
    for experiments in try [
        rollout(userID: "42", "[2369760879,2,8,1,null,null]"),
        rollout(userID: "42", "[2369760879,9,2,1,null,null]"),
        DiscordExperiments(user: nil, guild: nil, apex: JSONDecoder().decode(
            JSONValue.self, from: Data(#"{"assignments":{"1":{"43":{"assignments":[[2369760879,1,2,1]]}}}}"#.utf8)
        ), userID: "42"),
    ] {
        #expect(!experiments.widgetEligibility(for: user).canEditPersonalWidget)
    }
}

@Test func `user profile maps server joined date from guild member payload`() throws {
    let payload = Data("""
    {
      "user": {"id": "42", "username": "alice", "discriminator": "0"},
      "guild_member": {
        "joined_at": "2026-07-21T15:30:00.000000+00:00",
        "nick": "AliceInServer"
      }
    }
    """.utf8)
    let dto = try JSONDecoder().decode(UserProfileDTO.self, from: payload)
    let domain = try dto.domain(guildID: GuildID(rawValue: 100), guilds: [:], guildRoles: [], effectConfig: nil)
    #expect(domain.guildJoinedAt == DiscordDate.parse("2026-07-21T15:30:00.000000+00:00"))
    #expect(domain.displayName == "AliceInServer")
}
