import Foundation
import SakuraCordModels

public extension DiscordRESTProvider {
    func guildGuideProfile(in guildID: GuildID) async throws -> GuildGuideProfile {
        let value: GuildGuideProfile = try await request("/guilds/\(guildID)/profile")
        guard value.id == guildID else { throw ChatProviderError.invalidRequest("Discord returned a different server’s profile.") }
        return value
    }

    func guildGuide(in guildID: GuildID) async throws -> GuildGuide {
        let value: GuildGuide = try await request("/guilds/\(guildID)/new-member-welcome")
        guard value.guildID == guildID else { throw ChatProviderError.invalidRequest("Discord returned a different server’s guide.") }
        return value
    }

    func guildGuideProgress(in guildID: GuildID) async throws -> GuildGuideProgress {
        guard let userID = currentUser?.id else { throw ChatProviderError.unauthenticated }
        let (data, response) = try await perform("/guilds/\(guildID)/new-member-actions", method: "GET", query: [], body: nil)
        guard (200 ..< 300).contains(response.statusCode) else {
            if response.statusCode == 401 {
                authorizationValue = nil
                throw apiDiagnostics.coalescing(ChatProviderError.unauthenticated, with: response)
            }
            throw apiDiagnostics.coalescing(ChatProviderError.transport(
                status: response.statusCode, requestID: response.value(forHTTPHeaderField: "x-request-id")
            ), with: response)
        }
        if response.statusCode == 204, data.isEmpty { return GuildGuideProgress(guildID: guildID, userID: userID) }
        let value = try JSONDecoder().decode(GuildGuideProgress.self, from: data)
        try validateGuideProgress(value, guildID: guildID)
        return value
    }

    func completeGuildGuideAction(in guildID: GuildID, channelID: ChannelID) async throws -> GuildGuideProgress {
        let value: GuildGuideProgress = try await request("/guilds/\(guildID)/new-member-action/\(channelID)", method: "POST")
        try validateGuideProgress(value, guildID: guildID)
        guard value.isCompleted(channelID) else {
            throw ChatProviderError.invalidRequest("Discord has not confirmed this task. Refresh the Server Guide to check again.")
        }
        return value
    }

    private func validateGuideProgress(_ value: GuildGuideProgress, guildID: GuildID) throws {
        guard value.guildID == guildID, value.userID == currentUser?.id else {
            throw ChatProviderError.invalidRequest("Discord returned task progress for a different membership.")
        }
    }
}
