@testable import SakuraCord
import DiscordProtocol
import SakuraCordModels
import Testing

@MainActor
@Test func profileMessagePreservesActiveConversationDraft() async throws {
    let provider = MockChatProvider()
    let snapshot = try await provider.bootstrap()
    let destination = try #require(snapshot.channels.first { $0.kind == .directMessage })
    let recipient = try #require(destination.recipients.first { $0.id != snapshot.currentUser.id })
    let source = try #require(snapshot.channels.first { $0.kind == .text })
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    model.snapshot = snapshot
    model.selectedChannelID = source.id
    await model.channelLoadTask?.value
    model.draft = "Keep this draft"
    model.threadDraft = "Keep the thread draft"

    #expect(await model.sendProfileMessage(to: recipient.id, content: "A private hello"))
    #expect(model.selectedChannelID == source.id)
    #expect(model.draft == "Keep this draft")
    #expect(model.threadDraft == "Keep the thread draft")
    let messages = try await provider.messages(in: destination.id, before: nil, limit: 100)
    #expect(messages.messages.contains { $0.content == "A private hello" })
    #expect(!model.messages.contains { $0.content == "A private hello" })
    #expect(!model.composer.outbox.draftsByNonce.values.contains { $0.content == "A private hello" })
    #expect(await model.sendProfileMessage(to: recipient.id, content: "  ") == false)
    #expect(await model.sendProfileMessage(to: snapshot.currentUser.id, content: "Self") == false)
}
