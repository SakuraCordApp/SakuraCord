import Foundation
import SakuraCordModels

public extension DiscordRESTProvider {
    /// Accept DM on the Message Requests page: one
    /// `PUT /channels/{channel}/recipients/@me` with consent status ACCEPTED,
    /// as Discord's web client sends it. The DM then joins the conversation
    /// list; consent holds whatever else a Gateway event changed meanwhile.
    func acceptMessageRequest(_ channelID: ChannelID) async throws {
        guard try await requestMessageRequestChange(channelID, method: "PUT", body: ["consent_status": .number(2)]) != nil,
              var channel = privateChannel(id: channelID)
        else { return }
        channel.isMessageRequest = false
        channel.isSpam = false
        upsertPrivateChannel(channel)
    }

    /// Ignore: the bodyless `DELETE /channels/{channel}/recipients/@me`, which
    /// removes the request without telling its sender.
    func ignoreMessageRequest(_ channelID: ChannelID) async throws {
        if let revision = try await requestMessageRequestChange(channelID, method: "DELETE", body: nil),
           privateChannelRevisions[channelID, default: 0] == revision {
            removePrivateChannel(channelID)
        }
    }

    private func requestMessageRequestChange(
        _ channelID: ChannelID, method: String, body: [String: JSONValue]?
    ) async throws -> UInt64? {
        try await requestPrivateChannelChange(
            channelID, path: "/channels/\(channelID)/recipients/@me", method: method, body: body,
            where: { $0.messageRequest != nil }
        )
    }
}
