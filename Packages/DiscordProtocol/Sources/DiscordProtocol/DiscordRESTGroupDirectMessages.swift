import Foundation
import SakuraCordModels

public extension DiscordRESTProvider {
    /// Edit Group from the group DM menu: one `PATCH /channels/{channel}` with
    /// only the changed `name` and `icon`, never replayed. A cleared name is
    /// `""` and a removed icon `null`, as Discord's modal sends them. A
    /// rejected value stays in the dialog, and `CHANNEL_UPDATE` reconciles
    /// other sessions.
    func editGroupDirectMessage(_ channelID: ChannelID, changes: GroupDirectMessageChanges) async throws -> Channel {
        guard let user = currentUser else { throw ChatProviderError.unauthenticated }
        guard let existing = privateChannel(id: channelID), existing.kind == .groupDirectMessage else {
            throw ChatProviderError.invalidRequest("This group is no longer available.")
        }
        var body: [String: JSONValue] = [:]
        switch changes.name {
        case .unchanged: break
        case .clear: body["name"] = .string("")
        case let .set(name):
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.utf16.count <= GroupDirectMessageChanges.maximumNameLength else {
                throw ChatProviderError.invalidRequest("Group names must be 100 characters or fewer.")
            }
            body["name"] = .string(name)
        }
        body["icon"] = changes.icon.jsonValue(\.dataURI)
        guard !body.isEmpty else { return existing }
        let generation = profileEditingGeneration
        let revision = privateChannelRevisions[channelID, default: 0]
        let path = "/channels/\(channelID)"
        let (data, response) = try await perform(
            path, method: "PATCH", query: [], body: body,
            headers: ["X-Context-Properties": DiscordClientMetadata.groupDirectMessageMenuContextHeader]
        )
        if response.statusCode == 400, let error = Self.profileValidationError(data: data, method: "PATCH", path: path) {
            throw apiDiagnostics.coalescing(error, with: response)
        }
        let dto: ChannelDTO = try decodedResponse(data, response, method: "PATCH", path: path) { status, _ in
            status == 403 ? ChatProviderError.invalidRequest("You can no longer edit this group.") : nil
        }
        guard currentUser?.id == user.id else { throw CancellationError() }
        guard dto.id == channelID.description, dto.type == 3 else {
            throw ChatProviderError.invalidRequest("Discord saved the group, but its response could not be loaded.")
        }
        let saved = try privateChannel(from: dto)
        // Gateway may already have applied this edit, or a newer one. Only
        // publish the response while no group event or session reset followed.
        if profileEditingGeneration == generation, privateChannelRevisions[channelID, default: 0] == revision,
           let current = privateChannel(id: channelID)
        {
            var channel = saved
            // The edit response omits account-scoped warning state and may
            // omit the latest pin; changing a name or icon must preserve them.
            channel.blockedUserWarningDismissed = dto.blockedUserWarningDismissed ?? current.blockedUserWarningDismissed
            channel.lastPinTimestamp = channel.lastPinTimestamp ?? current.lastPinTimestamp
            // Message events update activity independently of the group's revision.
            channel.lastMessageID = [saved.lastMessageID, current.lastMessageID].compactMap(\.self).max()
            upsertPrivateChannel(channel)
        }
        return saved
    }

    /// Leave Group: one `DELETE /channels/{channel}?silent=…`, never replayed,
    /// as Discord's confirmation sends it. A successful leave removes the group
    /// locally unless a Gateway event or session reset changed it meanwhile;
    /// the matching `CHANNEL_DELETE` then finds nothing left to remove.
    func leaveGroupDirectMessage(_ channelID: ChannelID, silently: Bool) async throws {
        try await deletePrivateChannel(
            channelID, kind: .groupDirectMessage,
            query: [URLQueryItem(name: "silent", value: silently ? "true" : "false")]
        )
    }

    /// Close DM: the same bodyless `DELETE /channels/{channel}` without `silent`,
    /// which hides a 1:1 DM without deleting its messages.
    func closeDirectMessage(_ channelID: ChannelID) async throws {
        try await deletePrivateChannel(channelID, kind: .directMessage, query: [])
    }

    private func deletePrivateChannel(_ channelID: ChannelID, kind: ChannelKindValue, query: [URLQueryItem]) async throws {
        if try await requestPrivateChannelChange(
            channelID, path: "/channels/\(channelID)", method: "DELETE", query: query, where: { $0.kind == kind }
        ) {
            removePrivateChannel(channelID)
        }
    }

    /// Sends one request about a cached DM or group. True when its result
    /// still applies: no Gateway event or session reset changed the
    /// conversation while the request was in flight.
    internal func requestPrivateChannelChange(
        _ channelID: ChannelID,
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: [String: JSONValue]? = nil,
        where isEligible: (Channel) -> Bool
    ) async throws -> Bool {
        guard let user = currentUser else { throw ChatProviderError.unauthenticated }
        guard let channel = privateChannel(id: channelID), isEligible(channel) else {
            throw ChatProviderError.invalidRequest("This conversation is no longer available.")
        }
        let generation = profileEditingGeneration
        let revision = privateChannelRevisions[channelID, default: 0]
        try await requestEmpty(path, method: method, query: query, body: body)
        return currentUser?.id == user.id && profileEditingGeneration == generation
            && privateChannelRevisions[channelID, default: 0] == revision
    }
}
