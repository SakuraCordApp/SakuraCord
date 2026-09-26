import SakuraCordModels

extension AppModel {
    func consumeMembersChanged(
        guildID: GuildID,
        members value: [Member],
        groups: [GuildMemberListGroup],
        preparedPresentation: PreparedMemberListPresentation? = nil
    ) {
        AppPerformanceSignposts.measureSync("MemberListEventPublication") {
            value.forEach { receiveOnboardingMember($0, guildID: guildID) }
            let receivedMembers = value
            let value = value.map { member in
                var member = member
                if member.id == profileCustomStatusUserID { member.customStatus = profileCustomStatus?.displayText }
                return member
            }
            updateCurrentUserRoles(from: value, guildID: guildID)
            memberListsByGuildID[guildID] = value
            memberListGroupsByGuildID[guildID] = groups
            guard guildID == selectedGuildID else { return }

            let previousMembersByID = membersByID
            let nextSections: [MemberSection]
            if value == receivedMembers, let preparedPresentation,
               preparedPresentation.guildID == guildID,
               preparedPresentation.roles == guildRoles
            {
                nextSections = preparedPresentation.sections
            } else {
                nextSections = AppPerformanceSignposts.measureSync(
                    "MemberSectionBuild"
                ) {
                    MemberSection.make(
                        from: value,
                        groups: groups,
                        roles: guildRoles
                    )
                }
            }

            // These two observable assignments describe one member-list
            // snapshot. Publish their single derived section model after both
            // sources are current instead of building once from mismatched
            // inputs and immediately building it again.
            defersMemberPresentationRebuild = true
            memberListGroups = groups
            members = value
            defersMemberPresentationRebuild = false
            if memberSections != nextSections {
                memberSections = nextSections
            }
            publishTimelineMemberPresentationChanges(
                from: previousMembersByID,
                to: membersByID
            )
            refreshMentionAutocompleteMembers(from: value)
            refreshPresentedMembers(from: value)
        }
    }

    func updateCurrentUserRoles(from members: [Member], guildID: GuildID) {
        guard let currentUserID = snapshot?.currentUser.id,
              let currentMember = members.first(where: { $0.id == currentUserID })
        else { return }
        let roleIDs = Set(currentMember.roles.map(\.id))
        guard currentUserRoleIDsByGuild[guildID] != roleIDs else { return }
        currentUserRoleIDsByGuild[guildID] = roleIDs
        readState.updateCurrentUserRoles(roleIDs, guildID: guildID)
        guard selectedGuildID == guildID else { return }
        refreshUnreadPresentation(
            appliesAccessImmediately: true,
            accessAffectedGuildIDs: [guildID]
        )
    }

    func refreshMentionAutocompleteMembers(from members: [Member]) {
        if mentionAutocompleteMembers.isEmpty {
            // A guild activation can finish before Discord's lazy member list
            // has delivered its first store snapshot. Seed the dedicated
            // autocomplete store from that first Gateway update.
            mentionAutocompleteMembers = members
        } else {
            // Refresh known values without letting visual member-list sorting
            // reorder or expand the autocomplete store.
            let updatesByID = Dictionary(
                members.map { ($0.id, $0) },
                uniquingKeysWith: { _, newer in newer }
            )
            mentionAutocompleteMembers = mentionAutocompleteMembers.map {
                updatesByID[$0.id] ?? $0
            }
        }
    }

    func refreshPresentedMembers(from members: [Member]) {
        for destination in [ProfilePresentationDestination.inspector, .contextual, .expanded] {
            guard var presentation = profilePresentation(for: destination),
                  var updated = members.first(where: { $0.id == presentation.member.id }) else { continue }
            if updated.id == profileCustomStatusUserID { updated.customStatus = profileCustomStatus?.displayText }
            presentation.member = updated
            presentation.profile?.status = updated.status
            presentation.profile?.customStatus = updated.customStatus
            setProfilePresentation(presentation, for: destination)
        }
    }
}
