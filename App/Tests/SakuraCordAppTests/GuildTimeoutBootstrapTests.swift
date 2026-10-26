import DiscordProtocol
import Foundation
import Observation
@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func `membership timeout changes received before bootstrap publication survive its older snapshot`(removingTimeout: Bool) async throws {
    let provider = GatedBootstrapRaceProvider(timeoutRemoval: removingTimeout)
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    let start = Task { await model.start() }
    await provider.waitForStaleRead()
    try await provider.publishTimeoutChange()
    // The status marker follows the membership event in the same stream, so
    // observing it proves the event was consumed before the snapshot returns.
    for await status in Observations({ model.currentStatus }) where status == .dnd { break }
    #expect(model.currentUser == nil)
    await provider.releaseBootstrap()
    await cancellableValue(of: start)
    await model.memberLoadTask?.value

    let channel = try #require(model.selectedChannel)
    #expect((model.guildTimeoutUntil(in: channel.id) == nil) == removingTimeout)
    #expect(model.selectedConversationAccess.canSend == removingTimeout)
    model.onboarding.reset()
    await provider.disconnect()
}
