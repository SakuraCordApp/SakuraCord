import DiscordProtocol
import SakuraCordModels

/// A test provider that implements only what its test probes and answers the
/// rest of the core requirements inertly.
protocol ChatProviderStub: ChatProvider {}

extension ChatProviderStub {
    func channels(in guildID: GuildID?) async throws -> [Channel] { [] }
    func members(in guildID: GuildID?) async throws -> [Member] { [] }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus { .online }
    func updateStatus(_ status: PresenceStatus) async throws {}

    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws -> MessagePage {
        MessagePage(messages: [], hasMoreBefore: false)
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(_ message: Message, content: String) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {}
    func eventStream() async -> AsyncStream<ClientEvent> { AsyncStream { $0.finish() } }
    func disconnect() async {}
}
