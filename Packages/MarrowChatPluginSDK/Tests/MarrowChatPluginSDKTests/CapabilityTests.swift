@testable import MarrowChatPluginSDK
import Testing

@Test func `mutating capabilities are sensitive`() {
    #expect(PluginCapability.sendMessages.isSensitive)
    #expect(!PluginCapability.addCommands.isSensitive)
}
