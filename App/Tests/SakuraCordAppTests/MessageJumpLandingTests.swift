@testable import SakuraCord
import SakuraCordModels
import Testing

/// Guards Jump to Surrounding on an AutoMod alert: the caught message never
/// posted, so the jump lands on the last sent message before the alert, never
/// on a local send that is still pending or failed in that conversation.
@MainActor
struct MessageJumpLandingTests {
    private let author = User(id: UserID(rawValue: 1), username: "member", displayName: "Member")

    private func message(_ id: UInt64, _ state: OutboxState = .confirmed) -> Message {
        Message(id: MessageID(rawValue: id), channelID: ChannelID(rawValue: 9), author: author,
                content: "\(id)", outboxState: state)
    }

    @Test func `a nearest jump skips local sends before and after the target`() {
        let messages = [message(10, .failed), message(20), message(30, .sending)]
        #expect(AppModel.landingID(for: MessageID(rawValue: 40), in: messages, nearest: true) == MessageID(rawValue: 20))
        #expect(AppModel.landingID(for: MessageID(rawValue: 15), in: [message(20, .failed), message(30)], nearest: true)
            == MessageID(rawValue: 30))
    }

    @Test func `an exact jump still requires its message`() {
        #expect(AppModel.landingID(for: MessageID(rawValue: 40), in: [message(20)], nearest: false) == nil)
    }
}
