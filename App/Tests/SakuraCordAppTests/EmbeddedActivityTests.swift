import DiscordProtocol
import SakuraCordModels
import Testing
@testable import SakuraCord

/// `/wordle` and other Activity commands start an instance outside voice. The
/// client used to treat that instance as abandoned and leave it for the user.
@MainActor
struct EmbeddedActivityTests {
    @Test(.timeLimit(.minutes(1)))
    func `an Activity this client's slash command started is hosted, not left`() async throws {
        let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
        await model.start()
        let user = try #require(model.currentUser)
        let channel = try #require(model.snapshot?.channels.first { $0.kind == .text })
        let wordle = ApplicationCommandApplication(id: "1211781489931452447", name: "Wordle")
        model.embeddedActivities.recordCommand("1568432599532044288", application: wordle)

        let location = EmbeddedActivityLocation.of(channel)
        await model.consume(.embeddedActivityChanged(EmbeddedActivityInstance(
            applicationID: try #require(ApplicationID(wordle.id)),
            instanceID: "1568432601910218892",
            compositeInstanceID: "i-1568432601910218892-\(location.id)",
            location: location,
            participants: [.init(userID: user.id, sessionID: "session", nonce: "1568432599532044288")]
        )))

        let session = try #require(model.embeddedActivities.session)
        #expect(session.channel.id == channel.id)
        #expect(session.instance?.instanceID == "1568432601910218892")
        #expect(model.embeddedActivities.pendingLeaves.isEmpty)
    }
}
