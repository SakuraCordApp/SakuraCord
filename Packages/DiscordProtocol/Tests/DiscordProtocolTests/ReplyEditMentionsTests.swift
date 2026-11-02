import SakuraCordModels
import Testing
@testable import DiscordProtocol

struct ReplyEditMentionsTests {
    private let author = User(id: UserID(rawValue: 1), username: "me", displayName: "Me")
    private let other = User(id: UserID(rawValue: 2), username: "other", displayName: "Other")

    private func reply(to target: User?, content: String = "reply", mentioned: [User] = []) -> Message {
        Message(
            id: MessageID(rawValue: 10),
            channelID: ChannelID(rawValue: 20),
            author: author,
            content: content,
            replyTo: MessageID(rawValue: 9),
            replyPreview: target.map {
                MessageReplyPreview(messageID: MessageID(rawValue: 9), author: $0, content: "original")
            },
            mentionedUsers: mentioned
        )
    }

    @Test func `editing a reply sent without a ping keeps the ping off`() {
        #expect(reply(to: author).editAllowedMentionsPayload != nil)
        #expect(reply(to: other, mentioned: [other]).editAllowedMentionsPayload == nil)
        #expect(reply(to: nil).editAllowedMentionsPayload != nil)
        #expect(reply(to: author, content: "hi <@1>", mentioned: [author]).editAllowedMentionsPayload != nil)
        #expect(reply(to: other, content: "hi <@!2>", mentioned: [other]).editAllowedMentionsPayload != nil)
    }
}
