import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    public func profileWidgetConnections(applicationIDs: [String]) async throws -> [String: ProfileWidgetConnection] {
        guard let userID = currentUser?.id else { throw ChatProviderError.unauthenticated }
        var seen = Set<String>()
        let ids = applicationIDs.filter { seen.insert($0).inserted }
        guard ids.allSatisfy({ UInt64($0) != nil }) else {
            throw ChatProviderError.invalidRequest("Invalid widget application identifier.")
        }
        let generation = profileEditingGeneration
        let revision = profileWidgetConnectionRevision
        let missing = ids.filter { profileWidgetConnectionStates[$0] == nil && profileWidgetConnectionTasks[$0] == nil }
        if !missing.isEmpty {
            let task = Task { try await self.loadProfileWidgetConnections(ids: missing, userID: userID, generation: generation, revision: revision) }
            for id in missing { profileWidgetConnectionTasks[id] = task }
        }
        for id in ids {
            if let task = profileWidgetConnectionTasks[id] { _ = try await task.value }
        }
        try validateProfileWidgetSession(userID: userID, generation: generation)
        guard revision == profileWidgetConnectionRevision else { throw CancellationError() }
        return profileWidgetConnectionStates.filter { seen.contains($0.key) }
    }

    private func loadProfileWidgetConnections(ids: [String], userID: UserID, generation: UInt64, revision: UUID) async throws -> [String: ProfileWidgetConnection] {
        defer {
            if generation == profileEditingGeneration, revision == profileWidgetConnectionRevision {
                for id in ids { profileWidgetConnectionTasks[id] = nil }
            }
        }
        let tokens: [ProfileWidgetAuthorizationDTO] = try await request(
            "/oauth2/tokens", query: ids.map { URLQueryItem(name: "application_ids", value: $0) }
        )
        try validateProfileWidgetSession(userID: userID, generation: generation)
        guard revision == profileWidgetConnectionRevision else { throw CancellationError() }
        var result = Dictionary(uniqueKeysWithValues: ids.map { ($0, ProfileWidgetConnection.unlinked) })
        for id in ids { profileWidgetAuthorizationTokenIDs[id] = nil }
        for token in tokens where result[token.application.id] != nil {
            result[token.application.id] = token.connection
            profileWidgetAuthorizationTokenIDs[token.application.id] = token.id
        }
        profileWidgetConnectionStates.merge(result) { _, new in new }
        return result
    }

    func invalidateProfileWidgetConnections() {
        profileWidgetConnectionRevision = UUID()
        profileWidgetConnectionStates = [:]
        profileWidgetAuthorizationTokenIDs = [:]
        profileWidgetConnectionTasks.cancelAll()
    }

    func handleProfileWidgetAuthorizationEvent(name: String, body: JSONValue) {
        if name == "OAUTH2_TOKEN_CREATE" {
            guard let token = try? JSONValueDecoder().decode(ProfileWidgetAuthorizationDTO.self, from: body) else { return }
            profileWidgetConnectionStates[token.application.id] = token.connection
            profileWidgetAuthorizationTokenIDs[token.application.id] = token.id
        } else {
            guard let deletion = try? JSONValueDecoder().decode(ProfileWidgetAuthorizationDeletionDTO.self, from: body),
                  profileWidgetAuthorizationTokenIDs[deletion.applicationID] == deletion.id else { return }
            profileWidgetConnectionStates[deletion.applicationID] = .unlinked
            profileWidgetAuthorizationTokenIDs[deletion.applicationID] = nil
        }
        // A response started before this event cannot overwrite the newer grant.
        profileWidgetConnectionRevision = UUID()
        profileWidgetConnectionTasks.cancelAll()
        if let userID = currentUser?.id { continuation?.yield(.profileWidgetConnectionsChanged(userID: userID, connections: profileWidgetConnectionStates)) }
    }
}

private struct ProfileWidgetAuthorizationDTO: Decodable {
    struct Application: Decodable { let id: String }
    let id: String
    let application: Application
    let scopes: [String]

    var connection: ProfileWidgetConnection {
        // Official widget module520082 accepts any of these profile-data scopes.
        let accepted: Set<String> = ["application_identities.write", "managed_platform.application_identities.write",
                                     "sdk.social_layer", "sdk.social_layer_presence"]
        return .linked(sharesProfileData: !accepted.isDisjoint(with: scopes))
    }
}

private struct ProfileWidgetAuthorizationDeletionDTO: Decodable {
    let id: String
    let applicationID: String
    enum CodingKeys: String, CodingKey { case id; case applicationID = "application_id" }
}
