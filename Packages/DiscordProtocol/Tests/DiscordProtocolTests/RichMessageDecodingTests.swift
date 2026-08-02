@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

@Test func `discord timestamps parse fractional and whole seconds`() throws {
    let fractional = try #require(
        DiscordDate.parse("2026-08-01T03:04:05.123456+00:00")
    )
    let whole = try #require(
        DiscordDate.parse("2026-08-01T03:04:05+00:00")
    )

    #expect(abs(fractional.timeIntervalSince(whole) - 0.123456) < 0.000_001)
}

@Test func `enhanced role primary color takes precedence over legacy color`() throws {
    let data = Data(
        #"""
        {
          "id":"10","name":"Orange","position":2,"hoist":true,"color":16777215,
          "colors":{"primary_color":16753920,"secondary_color":null,"tertiary_color":null}
        }
        """#.utf8
    )
    let role = try JSONDecoder().decode(GuildRoleDTO.self, from: data).domain

    #expect(role?.colorHex == 0xFFA500)
}

@Test func `role color falls back to legacy field when enhanced color is absent`() throws {
    let data = Data(
        #"{"id":"10","name":"Orange","position":2,"hoist":true,"color":16753920}"#.utf8
    )
    let role = try JSONDecoder().decode(GuildRoleDTO.self, from: data).domain

    #expect(role?.colorHex == 0xFFA500)
}

@Test func `partial message member merge does not erase known role ids`() {
    let existing = MessageGuildMember(
        nickname: "Guild Name",
        roleIDs: [RoleID(rawValue: 10)],
        avatarURL: URL(string: "https://cdn.discordapp.com/avatar.webp")
    )
    let merged = MessageGuildMember.merging(
        incoming: MessageGuildMember(),
        existing: existing
    )

    #expect(merged == existing)
    #expect(MessageGuildMember.merging(incoming: nil, existing: existing) == existing)
}

@Test func `channel decoder retains hidden channel timestamps`() throws {
    let lastMessageID = ClientNonce.make(
        now: Date(timeIntervalSince1970: 1_784_158_980.123)
    )
    let data = Data(
        #"{"id":"200","guild_id":"300","name":"private","type":0,"last_message_id":"\#(lastMessageID)","last_pin_timestamp":"2026-07-10T11:16:00.000Z"}"#.utf8
    )
    let dto = try JSONDecoder().decode(ChannelDTO.self, from: data)
    let channel = try dto.domain(guildID: nil)

    #expect(channel.lastMessageID?.description == lastMessageID)
    #expect(
        abs((channel.lastMessageID?.createdAt.timeIntervalSince1970 ?? 0) - 1_784_158_980.123)
            < 0.001
    )
    let timestampFormatter = ISO8601DateFormatter()
    timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    #expect(
        channel.lastPinTimestamp
            == timestampFormatter.date(from: "2026-07-10T11:16:00.000Z")
    )
}

@Test func `rich message fixture decodes every content family and skips malformed siblings`() throws {
    let data = Data(
        #"""
        {
          "id":"100","channel_id":"200","guild_id":"300","application_id":"400","type":0,"flags":32768,
          "author":{"id":"1","username":"fixture","global_name":"Fixture"},
          "member":{"nick":"Guild Fixture","roles":["10","11"],"avatar":"guild-avatar"},
          "content":"legacy content is suppressed",
          "mentions":[{"id":"2","username":"mentioned","global_name":"Mentioned User","member":{"nick":"Server Nick","avatar":null,"roles":[]}}],
          "timestamp":"2026-07-17T10:00:00.000Z",
          "attachments":[
            {"id":"1","filename":"photo.png","title":"Photo","description":"A blue square",
             "url":"https://cdn.example/photo.png","proxy_url":"https://proxy.example/photo.png",
             "content_type":"image/png","width":800,"height":600,"size":12,
             "placeholder":"abc","placeholder_version":1},
            {"id":false}
          ],
          "embeds":[
            {"title":"Preview","description":"**Rich** description","url":"https://example.com",
             "color":5793266,"fields":[{"name":"One","value":"Value","inline":true}],
             "image":{"url":"attachment://photo.png","width":800,"height":600}},
            false
          ],
          "components":[
            {"type":17,"id":1,"accent_color":5793266,"components":[
              {"type":10,"id":2,"content":"Component text"},
              {"type":2,"id":3,"style":5,"label":"Open","emoji":{"id":"216154654256398347","name":"mmLol","animated":false},"url":"https://example.com"},
              {"type":9,"id":5,"components":[{"type":10,"id":6,"content":"With thumbnail"}],
               "accessory":{"type":11,"id":7,"media":{"url":"attachment://photo.png"},
               "description":"Preview art","spoiler":true}},
              {"type":13,"id":8,"file":{"url":"attachment://photo.png"},"spoiler":true},
              {"type":12,"id":9,"items":[{"media":{"url":"https://cdn.example/banner.png",
               "proxy_url":"https://proxy.example/banner.png","width":1200,"height":200,
               "content_type":"image/png","placeholder":"thumbhash","placeholder_version":1,"flags":1},
               "description":"Wide banner"}]},
              {"type":999,"id":4}
            ]},
            false
          ],
          "sticker_items":[{"id":"500","name":"Wave","format_type":1}],
          "thread":{"id":"600","guild_id":"300","parent_id":"200","name":"Discussion","message_count":4,"member_count":2,"thread_metadata":{"archived":false,"locked":false}}
        }
        """#.utf8
    )

    let message = try RichMessageFixtureDecoder.decodeMessage(from: data)
    #expect(message.flags.contains(.isComponentsV2))
    #expect(message.author.displayName == "Guild Fixture")
    #expect(message.guildMember?.nickname == "Guild Fixture")
    #expect(message.guildMember?.roleIDs == [RoleID(rawValue: 10), RoleID(rawValue: 11)])
    #expect(message.author.avatarURL?.absoluteString.contains("/guilds/300/users/1/avatars/guild-avatar.webp") == true)
    #expect(message.applicationID == ApplicationID(rawValue: 400))
    #expect(message.attachments.count == 1)
    #expect(message.attachments[0].title == "Photo")
    #expect(message.embeds.count == 1)
    #expect(message.embeds[0].fields.count == 1)
    #expect(message.components.count == 1)
    guard case let .container(_, _, _, children) = message.components[0],
          case let .button(_, _, _, emoji, _, _, _, _) = children[1]
    else {
        Issue.record("Expected decoded component button")
        return
    }
    #expect(emoji?.id == "216154654256398347")
    #expect(emoji?.name == "mmLol")
    guard case let .section(_, _, accessory) = children[2],
          case let .thumbnail(_, thumbnail)? = accessory,
          case let .file(_, file) = children[3]
    else {
        Issue.record("Expected decoded thumbnail and file components")
        return
    }
    #expect(thumbnail.attachmentName == "photo.png")
    #expect(thumbnail.description == "Preview art")
    #expect(thumbnail.isSpoiler)
    #expect(file.attachmentName == "photo.png")
    #expect(file.isSpoiler)
    guard case let .mediaGallery(_, galleryItems) = children[4],
          let galleryMedia = galleryItems.first?.media
    else {
        Issue.record("Expected decoded media gallery metadata")
        return
    }
    #expect(galleryMedia.url?.absoluteString == "https://cdn.example/banner.png")
    #expect(galleryMedia.proxyURL?.absoluteString == "https://proxy.example/banner.png")
    #expect(galleryMedia.width == 1200)
    #expect(galleryMedia.height == 200)
    #expect(galleryMedia.contentType == "image/png")
    #expect(galleryMedia.placeholder == "thumbhash")
    #expect(galleryMedia.placeholderVersion == 1)
    #expect(galleryMedia.flags == 1)
    #expect(message.stickers.first?.name == "Wave")
    #expect(message.thread?.id == ChannelID(rawValue: 600))
    #expect(message.mentionedUsers.first?.displayName == "Server Nick")
}

@Test func `welcome messages and standard lottie stickers retain renderable metadata`() throws {
    let data = Data(
        #"""
        {"id":"101","channel_id":"200","type":7,
        "author":{"id":"1","username":"new-user","global_name":"New User"},
        "content":"","sticker_items":[{"id":"749054660769218631","name":"Wave","format_type":3}]}
        """#.utf8
    )
    let message = try RichMessageFixtureDecoder.decodeMessage(from: data)
    #expect(message.type == .userJoin)
    #expect(message.type.hasGeneratedContent)
    #expect(message.stickers.first?.format == .lottie)
    #expect(message.stickers.first?.mediaURL?.absoluteString.hasSuffix(".json") == true)
}

@Test func `reply preview retains referenced guild member roles`() throws {
    let data = Data(
        #"""
        {
          "id":"101","channel_id":"200","guild_id":"300","type":0,
          "author":{"id":"1","username":"replying","global_name":"Replying User"},
          "content":"Reply","timestamp":"2026-07-17T10:00:00.000Z",
          "message_reference":{"message_id":"100"},
          "referenced_message":{
            "id":"100",
            "author":{"id":"2","username":"original","global_name":"Original User"},
            "member":{"nick":"Guild Original","roles":["10","11"],"avatar":null},
            "content":"Original"
          }
        }
        """#.utf8
    )

    let message = try RichMessageFixtureDecoder.decodeMessage(from: data)
    #expect(message.replyPreview?.author.displayName == "Guild Original")
    #expect(
        message.replyPreview?.guildMember?.roleIDs
            == [RoleID(rawValue: 10), RoleID(rawValue: 11)]
    )
}

@Test func `partial update changes present rich fields and preserves absent fields`() throws {
    let author = User(id: UserID(rawValue: 1), username: "fixture", displayName: "Fixture")
    let original = Message(
        id: MessageID(rawValue: 100), channelID: ChannelID(rawValue: 200), author: author,
        content: "before",
        embeds: [MessageEmbed(title: "Keep until explicitly replaced")],
        stickers: [MessageSticker(id: "1", name: "Keep")]
    )
    let update = Data(
        #"{"id":"100","channel_id":"200","content":"after","components":[{"type":10,"content":"new"}]}"#
            .utf8
    )
    let merged = try RichMessageFixtureDecoder.mergeUpdate(from: update, into: original)

    #expect(merged.content == "after")
    #expect(merged.embeds == original.embeds)
    #expect(merged.stickers == original.stickers)
    #expect(merged.components.count == 1)
}

@Test func `deferred command update clears loading and preserves attribution`() throws {
    let author = User(id: UserID(rawValue: 101), username: "app", displayName: "App", isBot: true)
    let invocationUser = User(
        id: UserID(rawValue: 1), username: "tester", displayName: "Tester"
    )
    let original = Message(
        id: MessageID(rawValue: 100),
        channelID: ChannelID(rawValue: 200),
        author: author,
        content: "Working…",
        type: .chatInputCommand,
        flags: .loading,
        interactionMetadata: MessageInteractionMetadata(
            id: "800", name: "verify", user: invocationUser, applicationID: "400"
        )
    )
    let update = Data(
        #"{"id":"100","channel_id":"200","content":"Complete","flags":0,"edited_timestamp":"2026-07-19T18:00:00.000Z"}"#.utf8
    )
    let merged = try RichMessageFixtureDecoder.mergeUpdate(from: update, into: original)

    #expect(merged.content == "Complete")
    #expect(!merged.flags.contains(.loading))
    #expect(merged.editedTimestamp != nil)
    #expect(merged.interactionMetadata == original.interactionMetadata)
}

@Test func `chat input response decodes command attribution and application identity`() throws {
    let data = Data(
        #"""
        {
          "id":"700",
          "channel_id":"200",
          "guild_id":"300",
          "type":20,
          "flags":64,
          "author":{"id":"101","username":"verified","global_name":"Verified","bot":true},
          "content":"Verification complete",
          "nonce":"600",
          "application_id":"100",
          "application":{"id":"100","name":"Verified","description":"Verification tools","icon":"abc"},
          "interaction":{"id":"800","type":2,"name":"verifyforme","user":{"id":"1","username":"tester","global_name":"Tester"}},
          "interaction_metadata":{"id":"800","type":2,"application_id":"100","original_response_message_id":"700"}
        }
        """#.utf8
    )

    let message = try RichMessageFixtureDecoder.decodeMessage(from: data)
    #expect(message.type == .chatInputCommand)
    #expect(message.flags.contains(.ephemeral))
    #expect(message.nonce == "600")
    #expect(message.applicationID == ApplicationID("100"))
    #expect(message.application?.name == "Verified")
    #expect(message.application?.iconURL?.absoluteString.contains("/app-icons/100/abc.webp") == true)
    #expect(message.interactionMetadata?.id == "800")
    #expect(message.interactionMetadata?.displayName == "verifyforme")
    #expect(message.interactionMetadata?.user?.displayName == "Tester")
    #expect(message.interactionMetadata?.originalResponseMessageID == MessageID("700"))
}
