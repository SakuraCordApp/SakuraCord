import DiscordProtocol
import Foundation
import SakuraCordModels

/// A network-free provider used only while the normal app is signed out.
/// It intentionally contains no fixtures, so normal launches cannot fall
/// through to the offline testing experience.
actor SignedOutChatProvider: ChatProvider {
    func bootstrap() async throws -> BootstrapSnapshot {
        throw ChatProviderError.unauthenticated
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        throw ChatProviderError.unauthenticated
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        throw ChatProviderError.unauthenticated
    }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.unauthenticated
    }

    func currentStatus() async -> PresenceStatus {
        .offline
    }

    func updateStatus(_ status: PresenceStatus) async throws {
        throw ChatProviderError.unauthenticated
    }

    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws -> MessagePage {
        throw ChatProviderError.unauthenticated
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.unauthenticated
    }

    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message {
        throw ChatProviderError.unauthenticated
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {
        throw ChatProviderError.unauthenticated
    }

    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {
        throw ChatProviderError.unauthenticated
    }

    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { $0.finish() }
    }

    func disconnect() async {}
}
