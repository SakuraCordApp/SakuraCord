import Foundation
import SakuraCordModels

/// Suggested Channels: the dismissal flag in UserContentSettings and the
/// affinity rankings the suggestions draw from. See docs/protocol/SETTINGS.md,
/// Favorites server.
extension DiscordRESTProvider {
    /// Discord refetches channel affinities after 12 hours and user
    /// affinities after 8.
    private static let channelAffinitiesLifetime: TimeInterval = 12 * 60 * 60
    private static let userAffinitiesLifetime: TimeInterval = 8 * 60 * 60

    func applyUserContentSettingsProto(_ encoded: String?, replacesAllSettings: Bool) {
        guard let encoded, let data = Data(base64Encoded: encoded) else { return }
        let message = DiscordUserContentProto.message(inSettings: data)
        guard message != nil || replacesAllSettings else { return }
        let stored = message ?? Data()
        let wasDismissed = userContentMessage.map { DiscordUserContentProto.isDismissed(DiscordUserContentProto.favoritesSuggestions, in: $0) }
        userContentMessage = stored
        let isDismissed = DiscordUserContentProto.isDismissed(DiscordUserContentProto.favoritesSuggestions, in: stored)
        if wasDismissed != isDismissed { continuation?.yield(.favoritesSuggestionsDismissed(isDismissed)) }
    }

    /// Like the official dismissible-content writes: the complete
    /// UserContentSettings with one bit changed, saved at once.
    public func setFavoritesSuggestionsDismissed(_ dismissed: Bool) async throws {
        guard let current = userContentMessage else {
            throw ChatProviderError.invalidRequest("Wait for your account settings to finish loading.")
        }
        let content = DiscordUserContentProto.favoritesSuggestions
        guard DiscordUserContentProto.isDismissed(content, in: current) != dismissed else { return }
        let message = DiscordUserContentProto.setting(content, dismissed: dismissed, in: current)
        continuation?.yield(.favoritesSuggestionsDismissed(dismissed))
        do {
            let response = try await patchUserSettings(
                ["settings": .string(
                    DiscordSettingsProto.protoLengthDelimitedField(DiscordUserContentProto.settingsField, message)
                        .base64EncodedString()
                )],
                retriesRateLimit: true
            )
            applyUserContentSettingsProto(response.settings, replacesAllSettings: true)
        } catch {
            if error is UserSettingsRejection { await reloadUserSettings() }
            continuation?.yield(.favoritesSuggestionsDismissed(!dismissed))
            throw error
        }
    }

    /// `GET /users/@me/affinities/v2/channels` and `…/users`, each kept for
    /// its lifetime and read only with personalization consent, as the
    /// official stores do. A failed read leaves that ranking empty.
    public func conversationAffinities() async -> ConversationAffinities {
        guard personalizationConsented else { return ConversationAffinities() }
        let now = Date.now
        if channelAffinities.map({ now.timeIntervalSince($0.fetchedAt) > Self.channelAffinitiesLifetime }) ?? true,
           let response: ChannelAffinitiesDTO = try? await request("/users/@me/affinities/v2/channels") {
            channelAffinities = (Self.ranked(response.channelAffinities.map { ($0.channelID, $0.score ?? 0) }), now)
        }
        if userAffinities.map({ now.timeIntervalSince($0.fetchedAt) > Self.userAffinitiesLifetime }) ?? true,
           let response: UserAffinitiesDTO = try? await request("/users/@me/affinities/v2/users") {
            userAffinities = (Self.ranked(response.userAffinities.map { ($0.otherUserID, $0.dmProbability ?? 0) }), now)
        }
        return ConversationAffinities(channelIDs: channelAffinities?.ids ?? [], userIDs: userAffinities?.ids ?? [])
    }

    /// Highest first; equal values keep Discord's order, as its stable sort does.
    private static func ranked<Kind>(_ values: [(String, Double)]) -> [Snowflake<Kind>] {
        values.enumerated()
            .compactMap { offset, value in Snowflake<Kind>(value.0).map { (id: $0, score: value.1, offset: offset) } }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            .map(\.id)
    }
}

private struct ChannelAffinitiesDTO: Decodable {
    struct Affinity: Decodable {
        var channelID: String
        var score: Double?
        enum CodingKeys: String, CodingKey {
            case channelID = "channel_id"
            case score
        }
    }

    var channelAffinities: [Affinity]
    enum CodingKeys: String, CodingKey { case channelAffinities = "channel_affinities" }
}

private struct UserAffinitiesDTO: Decodable {
    struct Affinity: Decodable {
        var otherUserID: String
        var dmProbability: Double?
        enum CodingKeys: String, CodingKey {
            case otherUserID = "other_user_id"
            case dmProbability = "dm_probability"
        }
    }

    var userAffinities: [Affinity]
    enum CodingKeys: String, CodingKey { case userAffinities = "user_affinities" }
}
