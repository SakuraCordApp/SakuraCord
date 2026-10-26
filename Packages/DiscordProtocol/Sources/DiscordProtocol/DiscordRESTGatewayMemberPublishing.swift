import SakuraCordModels

extension DiscordRESTProvider {
    func publishCurrentMemberTimeoutChange(previousMembers: [UserID: Member], guildID: GuildID) {
        guard let userID = currentUser?.id,
              previousMembers[userID]?.communicationDisabledUntil
                != cachedMemberIndex(guildID: guildID)[userID]?.communicationDisabledUntil
        else { return }
        publishMembers(
            guildID: guildID,
            members: cachedMembers[guildID] ?? [],
            groups: selectedMemberListGroups(guildID: guildID)
        )
    }

    func publishMemberChange(_ member: Member, guildID: GuildID) {
        memberPresentationRevisions[ProfileCacheKey(userID: member.id, guildID: guildID), default: 0] &+= 1
        let previous = cachedMembers[guildID]?.first { $0.id == member.id }
        cachedMembers[guildID] = DiscordMemberStoreOrdering.merging(
            existing: cachedMembers[guildID] ?? [], updates: [member]
        )
        if member.id == currentUser?.id,
           previous?.roleIDs != member.roleIDs || previous?.isPending != member.isPending {
            continuation?.yield(
                .currentUserRolesChanged(guildID: guildID, roleIDs: member.roleIDs)
            )
            if var guild = cachedGuilds[guildID] {
                guild.currentUserPermissions = nil
                cachedGuilds[guildID] = guild
                continuation?.yield(.guildChanged(guild))
            }
        }
        let members = cachedMembers[guildID] ?? []
        if previous != members.first(where: { $0.id == member.id }) {
            publishMembers(
                guildID: guildID,
                members: members,
                groups: selectedMemberListGroups(guildID: guildID)
            )
        }
    }

    func removeMember(userID: UserID, guildID: GuildID) {
        memberPresentationRevisions[ProfileCacheKey(userID: userID, guildID: guildID), default: 0] &+= 1
        cachedMembers[guildID]?.removeAll { $0.id == userID }
        let memberListIDs = cachedMemberListItems[guildID].map { Array($0.keys) } ?? []
        for memberListID in memberListIDs {
            cachedMemberListItems[guildID]?[memberListID]?.removeAll {
                $0?.member?.user.id == userID.description
            }
        }
        if userID == currentUser?.id {
            clearCurrentUserPermissionSnapshot(guildID)
        }
        let members = cachedMembers[guildID] ?? []
        publishMembers(
            guildID: guildID,
            members: members,
            groups: selectedMemberListGroups(guildID: guildID)
        )
        if userID == currentUser?.id {
            continuation?.yield(.currentUserRolesChanged(guildID: guildID, roleIDs: []))
        }
    }
}
