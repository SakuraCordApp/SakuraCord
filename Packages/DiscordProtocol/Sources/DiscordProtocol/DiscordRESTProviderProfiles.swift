import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    public func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        let key = ProfileCacheKey(userID: userID, guildID: guildID)
        if let cached = cachedProfiles[key] {
            return cached
        }
        if let task = profileTasks[key] {
            return try await task.value
        }
        let task = Task { [self] in
            let profile = try await loadProfile(for: userID, in: guildID)
            try Task.checkCancellation()
            return profile
        }
        let generation = profilePresentationGeneration
        let revision = profilePresentationRevisions[userID, default: 0]
        profileTasks[key] = task
        do {
            let profile = try await task.value
            guard generation == profilePresentationGeneration,
                  revision == profilePresentationRevisions[userID, default: 0], !task.isCancelled
            else { throw CancellationError() }
            profileTasks[key] = nil
            cachedProfiles[key] = profile
            return profile
        } catch {
            if generation == profilePresentationGeneration,
               revision == profilePresentationRevisions[userID, default: 0]
            { profileTasks[key] = nil }
            throw error
        }
    }

    func loadProfile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        let generation = profilePresentationGeneration
        let revision = profilePresentationRevisions[userID, default: 0]
        var query = [
            URLQueryItem(name: "type", value: "popout"),
            URLQueryItem(name: "with_mutual_guilds", value: "true"),
            URLQueryItem(name: "with_mutual_friends", value: "true"),
            URLQueryItem(name: "with_mutual_friends_count", value: "true"),
        ]
        if let guildID {
            query.append(URLQueryItem(name: "guild_id", value: guildID.description))
        }
        let response: ProfileResponseDTO
        do {
            response = try await request("/users/\(userID)/profile", query: query)
        } catch ChatProviderError.transport(status: 404, requestID: _) {
            throw ChatProviderError.invalidRequest(
                "This profile is unavailable. You may no longer share a server or friendship with this user."
            )
        }

        let dto = response.profile
        let profile = try await resolveProfile(dto, in: guildID)
        try Task.checkCancellation()
        guard generation == profilePresentationGeneration,
              revision == profilePresentationRevisions[userID, default: 0] else { throw CancellationError() }
        profileResponses[ProfileCacheKey(userID: userID, guildID: guildID)] = dto
        if userID == currentUser?.id, let editable = response.editable {
            profileEditingResponses[guildID.map(ProfileEditingScope.server) ?? .main] = editable
        }
        return profile
    }

    func resolveProfile(_ dto: UserProfileDTO, in guildID: GuildID?) async throws -> UserProfile {
        let effectID =
            dto.guildMemberProfile?.profileEffect?.resolvedID
                ?? dto.userProfile?.profileEffect?.resolvedID
        if effectID != nil, profileEffects == nil { profileEffects = [:] }
        if let effectID, profileEffects?[effectID] == nil {
            _ = try? await loadProfileCollectibleProduct(id: effectID)
        }
        if let frameID = dto.frameSKUID, profileCollectibleProducts[frameID] == nil {
            _ = try? await loadProfileCollectibleProduct(id: frameID)
        }

        var profile = try dto.domain(
            guildID: guildID,
            guilds: cachedGuilds,
            guildRoles: guildID.flatMap { cachedGuildRoles[$0] } ?? [],
            effectConfig: effectID.flatMap { profileEffects?[$0] },
            frame: resolvedProfileFrame(skuID: dto.frameSKUID)
        )
        if let widgets = profile.widgets, !widgets.isEmpty {
            profile.widgetResources = try await resolveProfileWidgetResources(for: profile.id, widgets: widgets)
        }
        if profile.id == currentUser?.id, let profileStatusSettings {
            profile.customStatus = DiscordSettingsProto.customStatus(in: profileStatusSettings)?.displayText
        }
        gatewayLogger.debug(
            "Profile assets resolved; bio=\(profile.bio?.isEmpty == false), badges=\(profile.badges.count), effect=\(profile.effect != nil), animations=\(profile.effect?.animations.count ?? 0)"
        )
        return profile
    }

    func resolvedProfileFrame(skuID: String?) -> ProfileFrame? {
        guard let skuID, let product = profileCollectibleProducts[skuID],
              case let .frame(frame) = product.items?.first(where: { $0.domain?.id == skuID })?.domain?.artwork
        else { return nil }
        return frame
    }

}
