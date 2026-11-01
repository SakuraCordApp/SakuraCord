import Foundation
import SakuraCordModels

public extension DiscordRESTProvider {
    /// Accept DM on the Message Requests page: one
    /// `PUT /channels/{channel}/recipients/@me` with consent status ACCEPTED,
    /// as Discord's web client sends it. The DM then joins the conversation list.
    func acceptMessageRequest(_ channelID: ChannelID) async throws {
        guard try await requestMessageRequestChange(channelID, method: "PUT", body: ["consent_status": .number(2)]),
              var channel = privateChannel(id: channelID)
        else { return }
        channel.messageRequest = nil
        upsertPrivateChannel(channel)
    }

    /// Ignore: the bodyless `DELETE /channels/{channel}/recipients/@me`, which
    /// removes the request without telling its sender.
    func ignoreMessageRequest(_ channelID: ChannelID) async throws {
        if try await requestMessageRequestChange(channelID, method: "DELETE", body: nil) {
            removePrivateChannel(channelID)
        }
    }

    private func requestMessageRequestChange(
        _ channelID: ChannelID, method: String, body: [String: JSONValue]?
    ) async throws -> Bool {
        try await requestPrivateChannelChange(
            channelID, path: "/channels/\(channelID)/recipients/@me", method: method, body: body,
            where: { $0.messageRequest != nil }
        )
    }
}
