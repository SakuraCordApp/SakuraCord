import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    func rebuildMemberSections() {
        memberSections = AppPerformanceSignposts.measureSync(
            "MemberSectionBuild"
        ) {
            MemberSection.make(
                from: members,
                groups: memberListGroups,
                roles: guildRoles
            )
        }
    }

    func updateMemberListViewport(_ visibleRange: ClosedRange<Int>) {
        guard !isThreadFullWidth || openThreadParentChannel?.kind == .announcement else { return }
        guard let guildID = selectedGuildID,
              let channelID = selectedChannelID
        else { return }
        lastMemberListVisibleRange = visibleRange
        let session = accountSession()
        let request = MemberListViewportRequest(
            guildID: guildID,
            channelID: channelID,
            visibleRange: visibleRange
        )
        memberListViewportRequest = request
        Task { [weak self] in
            guard let self,
                  isCurrentAccountSession(session),
                  memberListViewportRequest == request,
                  selectedGuildID == request.guildID,
                  selectedChannelID == request.channelID
            else { return }
            await sendMemberListViewport(request, account: session, purpose: "subscription")
        }
    }

    func replayMemberListViewportIfNeeded(
        for guildID: GuildID,
        account session: AppModelAccountSession
    ) async {
        guard let channelID = selectedChannelID,
              isCurrentAccountSession(session)
        else { return }
        // An empty cold member list has no native row from which the canvas can
        // derive a viewport. Seed the first Gateway block after members(in:)
        // arms the subscription; subsequent reports replace this with the real
        // visible range.
        let visibleRange = lastMemberListVisibleRange ?? 0 ... 0
        let request = MemberListViewportRequest(
            guildID: guildID,
            channelID: channelID,
            visibleRange: visibleRange
        )
        memberListViewportRequest = request
        await sendMemberListViewport(request, account: session, purpose: "replay")
    }

    /// Sends `request`, recording a failure while its account is current.
    private func sendMemberListViewport(
        _ request: MemberListViewportRequest,
        account session: AppModelAccountSession,
        purpose: StaticString
    ) async {
        do {
            try await session.provider.updateMemberListViewport(
                in: request.guildID,
                channelID: request.channelID,
                visibleRange: request.visibleRange
            )
        } catch {
            guard isCurrentAccountSession(session) else { return }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            AppModel.memberListLogger.debug(
                "Member-list viewport \(purpose.description, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func mergedMemberStore(with updates: [Member]) -> [UserID: Member] {
        guard let guildID = selectedGuildID else {
            return Dictionary(
                updates.map { ($0.id, $0) },
                uniquingKeysWith: { _, newer in newer }
            )
        }
        let merged = MemberStoreMerge.merging(
            existing: membersByGuildID[guildID] ?? [:],
            updates: updates
        )
        membersByGuildID[guildID] = merged
        return merged
    }

    func applyGuildRoles(_ roles: [GuildRole], to guildID: GuildID) {
        // Every guild has at least @everyone. An empty result is incomplete
        // state, so retain the last Gateway/REST catalog like Paicord's
        // per-guild role store instead of blanking every message author.
        guard !roles.isEmpty else { return }
        guard guildRolesByGuildID[guildID] != roles else { return }
        guildRolesByGuildID[guildID] = roles
        for key in profileCache.keys where key.guildID == guildID {
            profileCache[key]?.refreshRoles(from: roles)
        }
        for destination in [ProfilePresentationDestination.inspector, .contextual, .expanded] {
            guard var presentation = profilePresentation(for: destination), presentation.guildID == guildID else { continue }
            presentation.profile?.refreshRoles(from: roles)
            setProfilePresentation(presentation, for: destination)
        }
        discardUnreachableKeptComposerDrafts()
        guard selectedGuildID == guildID else { return }
        guildRoles = roles
        refreshUnreadPresentation(
            appliesAccessImmediately: true,
            accessAffectedGuildIDs: [guildID]
        )
    }

    var directMessageInspectorSections: [MemberSection] {
        guard let channel = selectedChannel, channel.guildID == nil else {
            return memberSections
        }
        return MemberSection.make(
            from: DirectMessageMemberResolver.members(
                for: channel,
                knownMembers: members,
                currentUser: currentUser,
                currentStatus: currentStatus
            )
        )
    }

    func restoreMemberPresentation(for guildID: GuildID?) {
        let restoredGroups = guildID.flatMap { memberListGroupsByGuildID[$0] } ?? []
        let restoredRoles = guildID.flatMap { guildRolesByGuildID[$0] } ?? []
        let restoredMembersByID = (guildID.flatMap { membersByGuildID[$0] } ?? [:]).mapValues(memberWithCurrentStatus)
        let restoredMembers = membersWithCurrentStatus(guildID.flatMap { memberListsByGuildID[$0] } ?? [])
        let presentationChanged =
            memberListGroups != restoredGroups
            || guildRoles != restoredRoles
            || members != restoredMembers

        defersMemberPresentationRebuild = true
        memberListGroups = restoredGroups
        guildRoles = restoredRoles
        membersByID = restoredMembersByID
        members = restoredMembers
        defersMemberPresentationRebuild = false

        guard presentationChanged else { return }
        rebuildMemberSections()
        AppPerformanceSignposts.signposter.emitEvent(
            "TimelineInvalidationGuildPresentationRestore"
        )
        invalidateTimelinePresentation()
    }

    func beginMemberLoad(for guildID: GuildID?) {
        memberLoadTask?.cancel()
        memberLoadGeneration &+= 1
        let requestGeneration = memberLoadGeneration
        let session = accountSession()
        let requestProvider = session.provider
        memberLoadTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            defer {
                if isCurrentAccountSession(session),
                   memberLoadGeneration == requestGeneration
                {
                    memberLoadTask = nil
                }
            }
            do {
                let timeoutRevision = guildID.map { onboarding.timeoutRevisions[$0, default: 0] }
                var value = try await AppPerformanceSignposts.measure(
                    "MemberListInitialRequest"
                ) {
                    try await requestProvider.members(in: guildID)
                }
                guard !Task.isCancelled,
                      isCurrentAccountSession(session),
                      memberLoadGeneration == requestGeneration,
                      selectedGuildID == guildID
                else { return }
                if let guildID,
                   onboarding.timeoutRevisions[guildID, default: 0] != timeoutRevision,
                   let index = value.firstIndex(where: { $0.id == currentUser?.id }) {
                    // A live membership update can overtake this snapshot.
                    // Preserve its timeout in both the self and list stores.
                    value[index].communicationDisabledUntil = onboarding.members[guildID]?.communicationDisabledUntil
                }
                let processedMembers = membersWithCurrentStatus(value)
                AppPerformanceSignposts.measureSync(
                    "MemberListInitialPublication"
                ) {
                    if let guildID {
                        memberListsByGuildID[guildID] = processedMembers
                        if let loadedMember = processedMembers.first(where: { $0.id == currentUser?.id }) {
                            // Initial list hydration supplies timeout evidence;
                            // keep the existing onboarding/role state authoritative.
                            var member = onboarding.members[guildID] ?? loadedMember
                            member.communicationDisabledUntil = loadedMember.communicationDisabledUntil
                            receiveOnboardingMember(member, guildID: guildID)
                        }
                    }
                    members = processedMembers
                    // Keep the pre-subscription GuildMemberStore snapshot for
                    // composer search. Full member-list subscriptions feed the
                    // inspector, but Discord does not use their visual list order
                    // as autocomplete's candidate store.
                    mentionAutocompleteMembers = processedMembers
                }
                if let guildID {
                    await replayMemberListViewportIfNeeded(
                        for: guildID,
                        account: session
                    )
                }
                if let guildID {
                    let roles = try? await AppPerformanceSignposts.measure(
                        "MemberListRoleRequest"
                    ) {
                        try await requestProvider.roles(in: guildID)
                    }
                    if let roles,
                       !Task.isCancelled,
                       isCurrentAccountSession(session),
                       memberLoadGeneration == requestGeneration,
                       selectedGuildID == guildID
                    {
                        applyGuildRoles(roles, to: guildID)
                    }
                } else {
                    guildRoles = []
                }
            } catch {
                guard !Task.isCancelled,
                      isCurrentAccountSession(session),
                      memberLoadGeneration == requestGeneration,
                      selectedGuildID == guildID
                else { return }
                members =
                    snapshot.map {
                        [Member(user: $0.currentUser, roleName: "You", status: currentStatus)]
                    }
                    ?? []
                if guildID == nil {
                    guildRoles = []
                }
            }
        }
    }
}
