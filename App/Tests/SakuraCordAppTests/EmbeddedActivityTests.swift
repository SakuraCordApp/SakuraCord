import DiscordProtocol
import SakuraCordModels
import Testing
@testable import SakuraCord

/// `/wordle` and other Activity commands start an instance outside voice. The
/// client used to treat that instance as abandoned and leave it for the user.
@MainActor
struct EmbeddedActivityTests {
    @Test
    func `an Activity this client's slash command started is hosted, not left`() async throws {
        let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
        await model.start()
        let user = try #require(model.currentUser)
        let channel = try #require(model.snapshot?.channels.first { $0.kind == .text })
        let wordle = ApplicationCommandApplication(id: "1211781489931452447", name: "Wordle")
        model.embeddedActivities.recordInteraction("1568432599532044288", application: wordle)

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

    /// A leave that failed while others kept playing must not make Discord
    /// drop the person again once they rejoin that game.
    @Test
    func `rejoining an Activity whose leave failed hosts it instead of leaving it again`() async throws {
        let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
        await model.start()
        let user = try #require(model.currentUser)
        let channel = try #require(model.snapshot?.channels.first { $0.kind == .text })
        let store = model.embeddedActivities
        let application = EmbeddedActivityApplication(id: try #require(ApplicationID("1211781489931452447")), name: "Wordle")
        let other = try #require(UserID("100000000000000002"))
        let location = EmbeddedActivityLocation.of(channel)
        let instance = EmbeddedActivityInstance(
            applicationID: application.id, instanceID: "1568432601910218892",
            compositeInstanceID: "i-1568432601910218892-\(location.id)", location: location,
            participants: [.init(userID: user.id, sessionID: "session"), .init(userID: other, sessionID: "other")]
        )
        store.upsert(instance)
        store.gatewaySessionID = "session"
        store.departingInstances[instance.compositeInstanceID] = true

        await model.startActivity(application, in: channel)
        #expect(store.departingInstances[instance.compositeInstanceID] == nil)
        await model.consume(.embeddedActivityChanged(instance))
        #expect(store.session?.instance?.compositeInstanceID == instance.compositeInstanceID)
        #expect(store.pendingLeaves.isEmpty)
    }
}
