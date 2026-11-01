import SakuraCordModels
import Testing
@testable import DiscordProtocol

struct ReplyEditMentionsTests {
    private let author = User(id: UserID(rawValue: 1), username: "me", displayName: "Me")
    private let other = User(id: UserID(rawValue: 2), username: "other", displayName: "Other")

    private func reply(to target: User, pinged: Bool) -> Message {
        Message(
            id: MessageID(rawValue: 10),
            channelID: ChannelID(rawValue: 20),
            author: author,
            content: "reply",
            replyTo: MessageID(rawValue: 9),
            replyPreview: MessageReplyPreview(messageID: MessageID(rawValue: 9), author: target, content: "original"),
            mentionedUsers: pinged ? [target] : []
        )
    }

    @Test func `editing a reply sent without a ping keeps the ping off`() {
        #expect(reply(to: author, pinged: false).editAllowedMentionsPayload != nil)
        #expect(reply(to: other, pinged: true).editAllowedMentionsPayload == nil)
    }
}
