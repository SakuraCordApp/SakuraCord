import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    /// The official client's /nick action is a single member mutation, with no
    /// profile-editor load and no automatic replay if the outcome is uncertain.
    public func setNickname(_ nickname: String, in guildID: GuildID) async throws -> String? {
        guard let user = currentUser else { throw ChatProviderError.unauthenticated }
        guard nickname.utf16.count <= 32 else {
            throw ChatProviderError.invalidRequest("Nicknames must be 32 characters or fewer.")
        }
        guard profileSaveID == nil else {
            throw ChatProviderError.invalidRequest("A profile save is already in progress.")
        }
        let saveID = UUID()
        let generation = profileEditingGeneration
        let memberKey = ProfileCacheKey(userID: user.id, guildID: guildID)
        let revision = memberPresentationRevisions[memberKey, default: 0]
        profileSaveID = saveID
        defer { if profileSaveID == saveID { profileSaveID = nil } }
        try Task.checkCancellation()
        let data = try await performProfileSaveRequest(ProfileEditingRequest(
            path: "/guilds/\(guildID)/members/%40me/nick", method: "PATCH",
            body: ["nick": .string(nickname)], headers: [:]
        ))
        guard currentUser?.id == user.id, profileEditingGeneration == generation,
              profileSaveID == saveID else { throw CancellationError() }
        profileEditingResponses[.server(guildID)] = nil
        guard case var .object(body)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              body["nick"] != nil,
              let dto = try? JSONDecoder().decode(GuildMemberDTO.self, from: data),
              dto.user.id == user.id.description else {
            throw ChatProviderError.invalidRequest("Discord saved the nickname, but its response could not be loaded. Check your server profile before trying again.")
        }
        // Gateway may have already applied this change, or a newer one. Only
        // reconcile if this member has not changed in the target guild.
        if memberPresentationRevisions[memberKey, default: 0] == revision {
            preserveCachedTimeout(in: &body, userID: user.id, guildID: guildID)
            body["guild_id"] = .string(guildID.description)
            await handleGuildMemberAddDispatch(name: "GUILD_MEMBER_UPDATE", body: .object(body))
        }
        return dto.nick
    }

    /// A moderator's Change Nickname action for another member. The current
    /// member keeps the `/nick` route above. One PATCH, never replayed.
    public func setMemberNickname(_ nickname: String, for userID: UserID, in guildID: GuildID) async throws -> String? {
        guard let user = currentUser else { throw ChatProviderError.unauthenticated }
        guard userID != user.id else { return try await setNickname(nickname, in: guildID) }
        guard nickname.utf16.count <= 32 else {
            throw ChatProviderError.invalidRequest("Nicknames must be 32 characters or fewer.")
        }
        let memberKey = ProfileCacheKey(userID: userID, guildID: guildID)
        let revision = memberPresentationRevisions[memberKey, default: 0]
        let generation = profileEditingGeneration
        let path = "/guilds/\(guildID)/members/\(userID)"
        let (data, response) = try await perform(path, method: "PATCH", query: [], body: ["nick": .string(nickname)])
        if response.statusCode == 400, let error = Self.profileValidationError(data: data, method: "PATCH", path: path) {
            throw apiDiagnostics.coalescing(error, with: response)
        }
        let saved: JSONValue = try decodedResponse(data, response, method: "PATCH", path: path) { status, _ in
            status == 403 ? ChatProviderError.invalidRequest("You don’t have permission to change this member’s nickname.") : nil
        }
        guard currentUser?.id == user.id else { throw CancellationError() }
        guard case var .object(body) = saved,
              let dto = try? JSONDecoder().decode(GuildMemberDTO.self, from: data),
              dto.user.id == userID.description else {
            throw ChatProviderError.invalidRequest("Discord saved the nickname, but its response could not be loaded.")
        }
        // READY resets revisions, so the generation also guards a reconnect.
        if profileEditingGeneration == generation, memberPresentationRevisions[memberKey, default: 0] == revision {
            preserveCachedTimeout(in: &body, userID: userID, guildID: guildID)
            body["guild_id"] = .string(guildID.description)
            await handleGuildMemberAddDispatch(name: "GUILD_MEMBER_UPDATE", body: .object(body))
        }
        return dto.nick.flatMap { $0.isEmpty ? nil : $0 }
    }

    public func saveProfileChanges(
        _ changes: ProfileEditChanges,
        in scope: ProfileEditingScope,
        didSave: @Sendable (ProfileSaveConfirmation) async -> Void
    ) async throws {
        guard changes.hasChanges else { return }
        guard let user = currentUser else { throw ChatProviderError.unauthenticated }
        guard profileSaveID == nil else {
            throw ChatProviderError.invalidRequest("A profile save is already in progress.")
        }
        guard var saved = profileEditingResponses[scope] else {
            throw ChatProviderError.invalidRequest("Reload this profile before saving changes.")
        }
        try validateProfileChanges(changes, in: scope, user: user)
        let saveID = UUID()
        let generation = profileEditingGeneration
        profileSaveID = saveID
        defer { if profileSaveID == saveID { profileSaveID = nil } }
        let groups = try profileSaveGroups(changes, in: scope, user: user, saved: saved)
        var failures: [any Error] = []
        var needsReload = false
        for group in groups where !group.isEmpty {
            let stages = group
            do {
                for (stage, request) in stages {
                    try Task.checkCancellation()
                    guard currentUser?.id == user.id, profileEditingGeneration == generation,
                          profileSaveID == saveID, !requestSafetyCircuitIsOpen
                    else { throw CancellationError() }
                    let data = try await performProfileSaveRequest(request)

                    // Once HTTP confirms a mutation, neither decoding nor a later request
                    // may cause the editor to send that stage again.
                    guard currentUser?.id == user.id, profileEditingGeneration == generation,
                          profileSaveID == saveID, !requestSafetyCircuitIsOpen
                    else {
                        await didSave(ProfileSaveConfirmation(stage: stage, snapshot: nil))
                        throw CancellationError()
                    }
                    let snapshot: ProfileEditingSnapshot
                    do {
                        if stage == .identity, scope == .main {
                            try await acceptProfileSaveCredential(from: data, accountID: user.id, generation: generation)
                        }
                        guard let reconciled = try profileSaveSnapshot(
                            data, request: request, stage: stage, scope: scope, saved: &saved,
                            accountID: user.id, needsReload: needsReload
                        ) else {
                            await didSave(ProfileSaveConfirmation(stage: stage, snapshot: nil))
                            continue
                        }
                        snapshot = reconciled
                    } catch {
                        needsReload = true
                        profileEditingResponses = [:]
                        invalidateSavedProfilePresentation(for: user.id)
                        continuation?.yield(.profileChanged(userID: user.id, scope: scope, profile: nil))
                        await didSave(ProfileSaveConfirmation(stage: stage, snapshot: nil))
                        throw ChatProviderError.invalidRequest("Discord saved this change, but its response could not be loaded. Reload the profile before continuing.")
                    }
                    await didSave(ProfileSaveConfirmation(stage: stage, snapshot: snapshot))
                }
            } catch {
                failures.append(error)
                needsReload = needsReload || error is URLError || error is CancellationError
                if Task.isCancelled || currentUser?.id != user.id || profileEditingGeneration != generation || requestSafetyCircuitIsOpen {
                    break
                }
            }
        }
        try throwProfileSaveFailures(failures, needsReload: needsReload)
    }

    private func profileSaveGroups(
        _ changes: ProfileEditChanges, in scope: ProfileEditingScope, user: User, saved: ProfileEditingResponseDTO
    ) throws -> [[(ProfileSaveStage, ProfileEditingRequest)]] {
        var stages: [(ProfileSaveStage, ProfileEditingRequest)] = []
        if let request = ProfileEditingRequest.identity(changes.identity, in: scope) { stages.append((.identity, request)) }
        if let request = ProfileEditingRequest.metadata(changes.metadata, in: scope) { stages.append((.metadata, request)) }
        switch changes.serverTag {
        case .unchanged: break
        case .clear: stages.append((.serverTag, .serverTag(nil)))
        case let .set(guildID): stages.append((.serverTag, .serverTag(guildID)))
        }

        var groups = [stages]
        if let widgets = changes.widgets {
            guard let originals = saved.profile.widgets else {
                throw ChatProviderError.invalidRequest("Reload your profile before editing its widgets.")
            }
            if profileApexAssignments?.widgetEligibility(for: user).canEditPersonalWidget != true {
                let originalWidgets = try originals.map { try $0.domain(userID: user.id) }
                for widget in widgets where !widget.isDiscardable {
                    if case .personal = widget.content,
                       !originalWidgets.contains(where: { $0.id == widget.id && $0.hasSameEditableContent(as: widget) }) {
                        throw ChatProviderError.invalidRequest("Personal widgets require Nitro and early access.")
                    }
                }
            }
            groups.append([(.widgets, try .widgets(widgets, originals: originals, userID: user.id))])
        }
        return groups
    }

    private func performProfileSaveRequest(_ request: ProfileEditingRequest) async throws -> Data {
        let (data, response) = try await perform(
            request.path, method: request.method, query: [], body: request.body, headers: request.headers
        )
        guard (200 ..< 300).contains(response.statusCode) else {
            if response.statusCode == 400,
               let error = Self.profileValidationError(data: data, method: request.method, path: request.path)
            { throw apiDiagnostics.coalescing(error, with: response) }
            if response.statusCode == 401 {
                authorizationValue = nil
                throw apiDiagnostics.coalescing(ChatProviderError.unauthenticated, with: response)
            }
            throw unexplainedFailure(data, response)
        }
        return data
    }

    private func profileSaveSnapshot(
        _ data: Data, request: ProfileEditingRequest, stage: ProfileSaveStage, scope: ProfileEditingScope,
        saved: inout ProfileEditingResponseDTO, accountID: UserID, needsReload: Bool
    ) throws -> ProfileEditingSnapshot? {
        try validateProfileSaveResponse(data, request: request)
        try reconcileProfileSave(data, stage: stage, scope: scope, saved: &saved)
        if needsReload { return nil }
        let effectID = saved.profile.guildMemberProfile?.profileEffect?.resolvedID
            ?? saved.profile.userProfile?.profileEffect?.resolvedID
        var presentation = try saved.profile.domain(
            guildID: scope.guildID, guilds: cachedGuilds,
            guildRoles: scope.guildID.flatMap { cachedGuildRoles[$0] } ?? [],
            effectConfig: effectID.flatMap { profileEffects?[$0] },
            frame: resolvedProfileFrame(skuID: saved.profile.frameSKUID)
        )
        presentation.widgetResources = cachedProfileWidgetResources(for: accountID)
        let snapshot = try makeProfileEditingSnapshot(saved, in: scope, presentation: presentation)
        try publishSavedProfilePresentations(saved, stage: stage, scope: scope)
        return snapshot
    }

    private func throwProfileSaveFailures(_ failures: [any Error], needsReload: Bool) throws {
        if failures.count == 1, let failure = failures.first { throw failure }
        if !failures.isEmpty {
            var fields: [String: [String]] = [:]
            for failure in failures {
                if let validation = failure as? ProfileValidationError {
                    fields.merge(validation.fields, uniquingKeysWith: +)
                }
            }
            throw ProfileSaveFailure(messages: failures.map(\.localizedDescription), fields: fields,
                                     requiresReload: needsReload)
        }
    }

    private func reconcileProfileSave(
        _ data: Data, stage: ProfileSaveStage, scope: ProfileEditingScope,
        saved: inout ProfileEditingResponseDTO
    ) throws {
        let decoder = JSONDecoder()
        if stage == .widgets {
            struct Response: Decodable { var widgets: [ProfileWidgetDTO] }
            let response = try decoder.decode(Response.self, from: data)
            guard response.widgets.allSatisfy({ $0.id.flatMap(UInt64.init) != nil }),
                  Set(response.widgets.compactMap(\.id)).count == response.widgets.count
            else { throw ChatProviderError.invalidRequest("Discord returned invalid saved widget identifiers.") }
            saved.profile.widgets = response.widgets
        } else if stage == .serverTag || (stage == .identity && scope == .main) {
            let dto = try decoder.decode(UserDTO.self, from: data)
            guard dto.id == saved.profile.user.id else {
                throw ChatProviderError.invalidRequest("Discord returned a different account's profile.")
            }
            saved.profile.user = dto
            saved.identity = try decoder.decode(ProfileEditingIdentityDTO.self, from: data)
            applyUserUpdate(dto: dto, user: try dto.domain())
        } else if stage == .identity {
            saved.profile.guildMember = try decoder.decode(ProfileGuildMemberDTO.self, from: data)
            saved.serverIdentity = try decoder.decode(ProfileEditingIdentityDTO.self, from: data)
            if let guildID = scope.guildID {
                var dto = try decoder.decode(GuildMemberDTO.self, from: data)
                if UserID(dto.user.id).flatMap({ cachedMemberIndex(guildID: guildID)[$0] }) != nil {
                    // Identity saves do not change timeout state. A delayed
                    // response must not replay it over confirmed membership.
                    dto.includesCommunicationDisabledUntil = false
                }
                let member = try dto.domain(
                    currentUserID: currentUser?.id, currentStatus: presenceStatus,
                    guildRoles: cachedGuildRoles[guildID] ?? [], guildID: guildID,
                    previousCommunicationDisabledUntil: UserID(dto.user.id).flatMap {
                        cachedMemberIndex(guildID: guildID)[$0]?.communicationDisabledUntil
                    }
                )
                guard member.id == currentUser?.id else {
                    throw ChatProviderError.invalidRequest("Discord returned a different server member.")
                }
                publishMemberChange(member, guildID: guildID)
            }
        } else {
            let dto = try decoder.decode(ProfileMetadataDTO.self, from: data)
            let fields = try decoder.decode(ProfileEditingMetadataDTO.self, from: data)
            if scope == .main {
                saved.profile.userProfile = dto
                saved.profile.user.banner = dto.banner
                saved.profile.user.bio = dto.bio
                saved.profile.user.accentColor = dto.accentColor
                saved.metadata = fields
            } else {
                saved.profile.guildMemberProfile = dto
                saved.profile.guildMember?.banner = dto.banner
                saved.profile.guildMember?.bio = dto.bio
                saved.serverMetadata = fields
            }
        }
    }

    private func preserveCachedTimeout(in body: inout [String: JSONValue], userID: UserID, guildID: GuildID) {
        guard cachedMemberIndex(guildID: guildID)[userID] != nil else { return }
        // Let sparse member reconciliation retain the canonical timeout,
        // including an explicit removal learned while this request waited.
        body["communication_disabled_until"] = nil
    }

    private func validateProfileSaveResponse(_ data: Data, request: ProfileEditingRequest) throws {
        guard case let .object(response) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw ChatProviderError.invalidRequest("Discord returned an invalid profile save response.")
        }
        for key in request.body.keys {
            // The server-member response omits a cleared decoration instead of
            // returning null. Preserve that inherited state in the decoded snapshot.
            if key == "avatar_decoration_sku_id", request.body[key] == .null,
               request.path.hasPrefix("/guilds/"), request.path.hasSuffix("/members/@me"),
               response["avatar_decoration_data"] == nil
            { continue }
            let returnedKey: String
            switch key {
            case "avatar_id", "avatar_description": returnedKey = "avatar"
            case "avatar_decoration_sku_id": returnedKey = "avatar_decoration_data"
            case "nameplate_sku_id", "collectibles_sku_ids": returnedKey = "collectibles"
            case "display_name_font_id", "display_name_effect_id", "display_name_colors": returnedKey = "display_name_styles"
            case "identity_guild_id", "identity_enabled": returnedKey = "primary_guild"
            default: returnedKey = key
            }
            guard response[returnedKey] != nil else {
                throw ChatProviderError.invalidRequest("Discord omitted a saved profile field.")
            }
        }
        if request.path == "/users/@me/widgets" {
            guard case let .array(expected) = request.body["widgets"],
                  case let .array(actual) = response["widgets"], expected.count == actual.count
            else { throw ChatProviderError.invalidRequest("Discord returned a different widget list.") }
            for (expected, actual) in zip(expected, actual) {
                guard case let .object(sent) = expected, case let .object(received) = actual,
                      sent["id"] == nil || sent["id"] == received["id"],
                      case let .object(sentData) = sent["data"], case let .object(receivedData) = received["data"],
                      sentData["type"] == receivedData["type"]
                else { throw ChatProviderError.invalidRequest("Discord changed a saved widget's identity or order.") }
            }
        }
    }

}
