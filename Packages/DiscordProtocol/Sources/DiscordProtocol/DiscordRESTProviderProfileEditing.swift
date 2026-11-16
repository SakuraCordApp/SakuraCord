import Foundation
import SakuraCordModels

public extension DiscordRESTProvider {
    func cachedProfileEditingSnapshot(in scope: ProfileEditingScope) async throws -> ProfileEditingSnapshot? {
        guard let user = currentUser else { throw ChatProviderError.unauthenticated }
        // A server profile response includes the main profile's editable fields.
        // Reuse the account-bar preload even when it was fetched in a server.
        let cachedScope: ProfileEditingScope
        if profileEditingResponses[scope] != nil {
            cachedScope = scope
        } else if scope == .main, let entry = profileEditingResponses.first(where: {
            $0.value.profile.user.id == user.id.description
                && cachedProfiles[ProfileCacheKey(userID: user.id, guildID: $0.key.guildID)] != nil
        }) {
            cachedScope = entry.key
        } else { return nil }
        guard var response = profileEditingResponses[cachedScope], response.profile.user.id == user.id.description else { return nil }
        if scope.guildID != nil, response.serverIdentity == nil || response.serverMetadata == nil { return nil }
        let key = ProfileCacheKey(userID: user.id, guildID: cachedScope.guildID)
        guard var presentation = cachedProfiles[key] else { return nil }
        presentation.widgetResources = cachedProfileWidgetResources(for: user.id)
        if cachedScope != scope {
            presentation = try makeProfileEditingSnapshot(response, in: cachedScope, presentation: presentation).mainPresentation
            response.profile.guildMember = nil
            response.profile.guildMemberProfile = nil
            response.profile.guildBadges = nil
            response.serverIdentity = nil
            response.serverMetadata = nil
        }
        let snapshot = try makeProfileEditingSnapshot(response, in: scope, presentation: presentation)
        if cachedScope != scope {
            // The editor and saver must share the same scoped baseline. A server
            // preload contains main fields, but was previously never registered
            // under .main, leaving a usable editor that could not save.
            let key = ProfileCacheKey(userID: user.id, guildID: scope.guildID)
            profileEditingResponses[scope] = response
            profileResponses[key] = response.profile
            cachedProfiles[key] = presentation
        }
        return snapshot
    }

    func profileEditingSnapshot(in scope: ProfileEditingScope) async throws -> ProfileEditingSnapshot {
        guard let user = currentUser else { throw ChatProviderError.unauthenticated }
        let generation = profileEditingGeneration
        let revision = profilePresentationRevisions[user.id, default: 0]
        var query = [
            URLQueryItem(name: "type", value: "modal"),
            URLQueryItem(name: "with_mutual_guilds", value: "true"),
            URLQueryItem(name: "with_mutual_friends", value: "false"),
            URLQueryItem(name: "with_mutual_friends_count", value: "true"),
        ]
        if let guildID = scope.guildID {
            query.append(URLQueryItem(name: "guild_id", value: guildID.description))
        }
        let response: ProfileEditingResponseDTO = try await request("/users/\(user.id)/profile", query: query)
        guard response.profile.user.id == user.id.description else {
            throw ChatProviderError.invalidRequest("Discord returned a different account's profile.")
        }
        if scope.guildID != nil, response.serverIdentity == nil || response.serverMetadata == nil {
            throw ChatProviderError.invalidRequest("This server profile is unavailable.")
        }
        try Task.checkCancellation()
        guard currentUser?.id == user.id, profileEditingGeneration == generation,
              profilePresentationRevisions[user.id, default: 0] == revision, !requestSafetyCircuitIsOpen else {
            throw CancellationError()
        }
        let presentation = try await resolveProfile(response.profile, in: scope.guildID)
        let snapshot = try makeProfileEditingSnapshot(response, in: scope, presentation: presentation)
        try Task.checkCancellation()
        guard currentUser?.id == user.id, profileEditingGeneration == generation,
              profilePresentationRevisions[user.id, default: 0] == revision, !requestSafetyCircuitIsOpen else {
            throw CancellationError()
        }
        profileEditingResponses[scope] = response
        profileResponses[ProfileCacheKey(userID: user.id, guildID: scope.guildID)] = response.profile
        cachedProfiles[ProfileCacheKey(userID: user.id, guildID: scope.guildID)] = presentation
        return snapshot
    }

    internal func makeProfileEditingSnapshot(
        _ response: ProfileEditingResponseDTO, in scope: ProfileEditingScope, presentation: UserProfile
    ) throws -> ProfileEditingSnapshot {
        guard let user = currentUser, response.profile.user.id == user.id.description else {
            throw CancellationError()
        }
        var presentation = presentation
        if let profileStatusSettings {
            presentation.customStatus = DiscordSettingsProto.customStatus(in: profileStatusSettings)?.displayText
        }
        var eligibility = experiments.widgetEligibility(for: user)
        eligibility.showsDeveloperWidgets = profileDeveloperMode
        var mainDTO = response.profile
        mainDTO.guildMember = nil
        mainDTO.guildMemberProfile = nil
        mainDTO.guildBadges = nil
        let mainEffectID = mainDTO.userProfile?.profileEffect?.resolvedID
        var mainPresentation = try mainDTO.domain(
            guildID: nil, guilds: cachedGuilds, guildRoles: [],
            effectConfig: mainEffectID.flatMap { profileEffects?[$0] },
            frame: resolvedProfileFrame(skuID: mainDTO.frameSKUID)
        )
        mainPresentation.widgetResources = presentation.widgetResources
        mainPresentation.customStatus = presentation.customStatus
        return ProfileEditingSnapshot(
            scope: scope,
            mainIdentity: response.identity.fields,
            mainMetadata: response.metadata?.fields ?? ProfileMetadataFields(),
            serverIdentity: response.serverIdentity?.fields,
            serverMetadata: response.serverMetadata?.fields,
            serverTag: response.identity.serverTag,
            serverTagGuilds: gatewayGuildIDs.compactMap { id in
                guard let guild = cachedGuilds[id], guild.features.contains(GuildFeature.guildTags), guild.profileTag?.tag != nil,
                      let member = cachedMembers[id]?.first(where: { $0.id == user.id }),
                      member.joinedAt != nil, member.isPending != true else { return nil }
                return guild
            },
            customStatus: profileStatusSettings.flatMap(DiscordSettingsProto.customStatus(in:)),
            presentation: presentation,
            mainPresentation: mainPresentation,
            widgetEligibility: eligibility
        )
    }
}
