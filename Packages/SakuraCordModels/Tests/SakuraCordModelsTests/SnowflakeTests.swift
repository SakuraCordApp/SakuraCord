import Foundation
@testable import SakuraCordModels
import Testing

@Test func `snowflakes round trip as strings`() throws {
    let id = ChannelID(rawValue: 123_456_789_012_345_678)
    let data = try JSONEncoder().encode(id)
    #expect(String(decoding: data, as: UTF8.self) == "\"123456789012345678\"")
    #expect(try JSONDecoder().decode(ChannelID.self, from: data) == id)
}

@Test func `snowflake exposes its embedded creation time`() throws {
    let date = Date(timeIntervalSince1970: 1_784_158_980.123)
    let id = try #require(MessageID(ClientNonce.make(now: date)))
    #expect(abs(id.createdAt.timeIntervalSince(date)) < 0.001)
}

@Test func `legacy cached users and members decode with cosmetic defaults`() throws {
    let userJSON = Data(
        #"{"id":"1","username":"legacy","displayName":"Legacy","avatarURL":null,"isBot":false}"#.utf8
    )
    let user = try JSONDecoder().decode(User.self, from: userJSON)
    #expect(user.publicFlags == 0)
    #expect(user.nameplate == nil)
    #expect(user.displayNameStyle == nil)

    let memberJSON = Data(
        #"{"user":{"id":"1","username":"legacy","displayName":"Legacy","avatarURL":null,"isBot":false},"roleName":"Member","status":"online"}"#
            .utf8
    )
    let member = try JSONDecoder().decode(Member.self, from: memberJSON)
    #expect(member.status == .online)
    #expect(member.roles.isEmpty)
    #expect(member.activityText == nil)
}

@Test func `legacy cached messages decode with rich content defaults`() throws {
    let data = Data(
        #"{"id":"100","channelID":"200","author":{"id":"1","username":"legacy","displayName":"Legacy","avatarURL":null,"isBot":false},"content":"hello","timestamp":0,"attachments":[],"reactions":[],"outboxState":"confirmed"}"#
            .utf8
    )
    let message = try JSONDecoder().decode(Message.self, from: data)

    #expect(message.type == .default)
    #expect(message.flags.isEmpty)
    #expect(message.embeds.isEmpty)
    #expect(message.components.isEmpty)
    #expect(message.stickers.isEmpty)
    #expect(message.thread == nil)
    #expect(message.mentionedUsers.isEmpty)
}

@Test func `custom emoji preserves exact discord token`() {
    let animated = EmojiReference(rawToken: "<a:party_blob:123456>")
    #expect(animated.id == "123456")
    #expect(animated.name == "party_blob")
    #expect(animated.isAnimated)
    #expect(animated.rawToken == "<a:party_blob:123456>")

    let unicode = EmojiReference(rawToken: "👋🏽")
    #expect(unicode.id == nil)
    #expect(unicode.rawToken == "👋🏽")
}

@Test func `attachment flags use Discord media bit positions`() {
    let flags = AttachmentFlags(rawValue: (1 << 0) | (1 << 3) | (1 << 5))
    #expect(flags.contains(.clip))
    #expect(flags.contains(.spoiler))
    #expect(flags.contains(.animated))
    #expect(!flags.contains(.thumbnail))
}

@Suite(.serialized)
struct ClientNonceTests {
    @Test func `uses discord epoch and decodes to creation time`() throws {
        let date = Date(timeIntervalSince1970: 1_784_158_980.123)
        let nonce = try #require(UInt64(ClientNonce.make(now: date)))
        let decodedMilliseconds = (nonce >> 22) + ClientNonce.discordEpochMilliseconds

        #expect(decodedMilliseconds == 1_784_158_980_123)
        #expect(nonce & 0x3FFFFF <= 0x0FFF)
    }

    @Test func `uses A sequence within the same millisecond`() throws {
        let date = Date(timeIntervalSince1970: 1_784_158_981.123)
        let first = try #require(UInt64(ClientNonce.make(now: date)))
        let second = try #require(UInt64(ClientNonce.make(now: date)))

        #expect(second == first + 1)
        #expect((first >> 22) == (second >> 22))
    }

    @Test func `does not underflow before discord epoch`() {
        let date = Date(timeIntervalSince1970: 1000)
        #expect(ClientNonce.make(now: date) == "0")
    }
}
