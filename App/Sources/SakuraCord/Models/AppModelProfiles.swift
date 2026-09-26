import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    func consumeProfileWidgetConnectionsChanged(userID: UserID, connections: [String: ProfileWidgetConnection]) {
        guard userID == snapshot?.currentUser.id else { return }
        preparedProfileEditingSnapshot?.presentation.widgetResources?.connections = connections
        preparedProfileEditingSnapshot?.mainPresentation.widgetResources?.connections = connections
        for key in profileCache.keys where key.userID == userID { profileCache[key]?.widgetResources?.connections = connections }
        for destination in [ProfilePresentationDestination.inspector, .contextual, .expanded] {
            guard var presentation = profilePresentation(for: destination), presentation.member.id == userID else { continue }
            presentation.profile?.widgetResources?.connections = connections
            setProfilePresentation(presentation, for: destination)
        }
        profileWidgetConnectionsRevision = UUID()
    }

    func consumeProfileCustomStatusChanged(userID: UserID, status: ProfileCustomStatus?) {
        guard snapshot?.currentUser.id == nil || snapshot?.currentUser.id == userID else { return }
        profileCustomStatusUserID = userID
        profileCustomStatus = status
        let text = status?.displayText
        if preparedProfileEditingSnapshot?.presentation.id == userID {
            preparedProfileEditingSnapshot?.customStatus = status
            preparedProfileEditingSnapshot?.presentation.customStatus = text
            preparedProfileEditingSnapshot?.mainPresentation.customStatus = text
        }
        for key in profileCache.keys where key.userID == userID { profileCache[key]?.customStatus = text }
        for guildID in membersByGuildID.keys { membersByGuildID[guildID]?[userID]?.customStatus = text }
        for guildID in memberListsByGuildID.keys {
            memberListsByGuildID[guildID] = memberListsByGuildID[guildID]?.map { member in
                var member = member
                if member.id == userID { member.customStatus = text }
                return member
            }
        }
        for index in members.indices where members[index].id == userID { members[index].customStatus = text }
        for index in mentionAutocompleteMembers.indices where mentionAutocompleteMembers[index].id == userID { mentionAutocompleteMembers[index].customStatus = text }
        for destination in [ProfilePresentationDestination.inspector, .contextual, .expanded] {
            guard var presentation = profilePresentation(for: destination), presentation.member.id == userID else { continue }
            presentation.member.customStatus = text
            presentation.profile?.customStatus = text
            setProfilePresentation(presentation, for: destination)
        }
    }

    func consumeProfileChanged(userID: UserID, scope: ProfileEditingScope, value: UserProfile?) {
        if userID == snapshot?.currentUser.id { preparedProfileEditingSnapshot = nil }
        let key = ProfileCacheKey(userID: userID, guildID: scope.guildID)
        profileCache[key] = value
        guard selectedGuildID == scope.guildID else { return }
        for destination in [ProfilePresentationDestination.inspector, .contextual, .expanded] {
            guard var presentation = profilePresentation(for: destination), presentation.member.id == userID else { continue }
            switch destination {
            case .inspector: inspectorProfileTask?.cancel()
            case .contextual: contextualProfileTask?.cancel()
            case .expanded: expandedProfileTask?.cancel()
            }
            if let value {
                presentation.member.user = value.user
                presentation.profile = profile(value, applyingPresenceFrom: presentation.member)
                presentation.errorMessage = nil
            } else {
                presentation.profile = nil
                presentation.errorMessage = "This profile changed. Reopen it to load the saved result."
            }
            presentation.isLoading = false
            setProfilePresentation(presentation, for: destination)
        }
    }

    func updateStatus(_ status: PresenceStatus) async {
        let session = accountSession()
        do {
            try await session.provider.updateStatus(status)
            guard isCurrentAccountSession(session) else { return }
            currentStatus = status
            members = members.map { member in
                guard member.user.id == snapshot?.currentUser.id else { return member }
                var updatedMember = member
                updatedMember.status = status
                return updatedMember
            }
        } catch {
            guard isCurrentAccountSession(session) else { return }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            errorMessage = error.localizedDescription
        }
    }

    func selectMember(_ member: Member) {
        if selectedMember?.id == member.id, isInspectorProfilePresented {
            dismissInspectorProfile()
            return
        }
        isInspectorProfilePresented = true
        if selectedMember?.id == member.id {
            return
        }
        presentProfile(for: member, destination: .inspector)
    }

    @discardableResult
    func showProfile(for user: User) -> UUID {
        let member =
            membersByID[user.id]
                ?? Member(user: user, roleName: "Member", status: .offline)
        return presentProfile(for: member, destination: .contextual)
    }

    func showSystemMessageProfile(
        userID: UserID,
        sourceMessage: Message? = nil
    ) {
        if let user = systemMessageUser(
            userID: userID,
            sourceMessage: sourceMessage
        ) {
            _ = showProfile(for: user)
        }
    }

    func navigateToSystemMessageTarget(
        guildID: GuildID?,
        channelID: ChannelID,
        messageID: MessageID
    ) {
        let isRootChannel = snapshot?.channels.contains { $0.id == channelID } == true
            || visibleChannels.contains { $0.id == channelID }
        if isRootChannel {
            navigate(to: guildID, channelID: channelID, messageID: messageID)
        } else {
            navigate(
                to: guildID,
                linkedChannelID: channelID,
                messageID: messageID
            )
        }
    }

    func prepareInspectorProfileForPresentation() {
        guard !showInspector,
              let channel = selectedChannel,
              channel.kind == .directMessage,
              let recipient = channel.recipients.first,
              inspectorProfilePresentation?.member.id != recipient.id
        else {
            return
        }
        showInspectorProfile(for: recipient)
    }

    func showInspectorProfile(for user: User) {
        isInspectorProfilePresented = true
        let member =
            membersByID[user.id]
                ?? Member(
                    user: user,
                    roleName: "Direct Message",
                    status: .offline
                )
        presentProfile(for: member, destination: .inspector)
    }

    func authorPresentation(for message: Message) -> MessageAuthorPresentation {
        let guildID = message.guildID ?? messagePresentationChannel(message.channelID)?.guildID
        let member = guildID.flatMap { membersByGuildID[$0]?[message.author.id] }
            ?? (guildID == selectedGuildID ? membersByID[message.author.id] : nil)
        let roles = guildID.flatMap { guildRolesByGuildID[$0] }
            ?? (guildID == selectedGuildID ? guildRoles : [])
        let presentation = MessageAuthorPresentation.resolve(message: message, member: member, roles: roles)
        var user = presentation.user
        user.avatarDecorationURL = user.avatarDecorationURL ?? message.author.avatarDecorationURL
        return MessageAuthorPresentation(user: cosmeticPolicy.user(user), roleColorHex: presentation.roleColorHex)
    }

    func authorPresentation(
        for replyPreview: MessageReplyPreview, in message: Message? = nil
    ) -> MessageAuthorPresentation {
        let guildID = message.map { $0.guildID ?? messagePresentationChannel($0.channelID)?.guildID } ?? selectedGuildID
        let member = guildID.flatMap { membersByGuildID[$0]?[replyPreview.author.id] }
            ?? (guildID == selectedGuildID ? membersByID[replyPreview.author.id] : nil)
        let roles = guildID.flatMap { guildRolesByGuildID[$0] } ?? (guildID == selectedGuildID ? guildRoles : [])
        let presentation = MessageAuthorPresentation.resolve(
            replyPreview: replyPreview,
            member: member,
            roles: roles
        )
        return MessageAuthorPresentation(user: cosmeticPolicy.user(presentation.user), roleColorHex: presentation.roleColorHex)
    }

    @discardableResult
    func presentProfile(
        for member: Member,
        destination: ProfilePresentationDestination
    ) -> UUID {
        var member = member
        if member.id == profileCustomStatusUserID { member.customStatus = profileCustomStatus?.displayText }
        let requestID = UUID()
        let guildID = selectedGuildID
        let cacheKey = ProfileCacheKey(
            userID: member.id,
            guildID: guildID
        )
        let cachedProfile = profileCache[cacheKey].map {
            profile($0, applyingPresenceFrom: member)
        }
        let presentation = ProfilePresentationState(
            requestID: requestID,
            member: member,
            isCurrentUser: member.id == snapshot?.currentUser.id,
            profile: cachedProfile,
            isLoading: cachedProfile == nil,
            errorMessage: nil
        )
        switch destination {
        case .inspector:
            inspectorProfileTask?.cancel()
            inspectorProfilePresentation = presentation
        case .contextual:
            contextualProfileTask?.cancel()
            contextualProfilePresentation = presentation
        case .expanded:
            expandedProfileTask?.cancel()
            expandedProfilePresentation = presentation
        }
        guard cachedProfile == nil else { return requestID }
        let session = accountSession()

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await session.provider.profile(
                    for: member.id,
                    in: guildID
                )
                guard !Task.isCancelled,
                      isCurrentAccountSession(session),
                      selectedGuildID == guildID,
                      profilePresentation(
                          for: destination
                      )?.requestID == requestID
                else {
                    return
                }
                profileCache[cacheKey] = loaded
                var value = profilePresentation(for: destination)
                value?.member = member
                value?.profile = profile(
                    loaded,
                    applyingPresenceFrom: member
                )
                value?.isLoading = false
                value?.errorMessage = nil
                setProfilePresentation(value, for: destination)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      isCurrentAccountSession(session),
                      profilePresentation(
                          for: destination
                      )?.requestID == requestID
                else { return }
                var value = profilePresentation(for: destination)
                value?.isLoading = false
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                value?.errorMessage = error.localizedDescription
                setProfilePresentation(value, for: destination)
            }
        }
        switch destination {
        case .inspector:
            inspectorProfileTask = task
        case .contextual:
            contextualProfileTask = task
        case .expanded:
            expandedProfileTask = task
        }
        return requestID
    }

    func expandProfile(_ presentation: ProfilePresentationState) {
        presentProfile(for: presentation.member, destination: .expanded)
        dismissContextualProfile()
        isInspectorProfilePresented = false
    }

    func dismissExpandedProfile() {
        expandedProfileTask?.cancel()
        expandedProfileTask = nil
        expandedProfilePresentation = nil
    }

    func dismissInspectorProfile() {
        inspectorProfileTask?.cancel()
        inspectorProfileTask = nil
        inspectorProfilePresentation = nil
        isInspectorProfilePresented = false
    }

    func dismissContextualProfile(for userID: UserID? = nil) {
        if let userID,
           contextualProfilePresentation?.member.id != userID
        {
            return
        }
        contextualProfileTask?.cancel()
        contextualProfileTask = nil
        contextualProfilePresentation = nil
    }

    func dismissContextualProfile(requestID: UUID) {
        guard contextualProfilePresentation?.requestID == requestID else {
            return
        }
        dismissContextualProfile()
    }

    func dismissAllProfiles(clearsCache: Bool = false) {
        dismissInspectorProfile()
        dismissContextualProfile()
        dismissExpandedProfile()
        if clearsCache {
            currentUserProfilePrefetch?.task.cancel()
            currentUserProfilePrefetch = nil
            profileCache.removeAll(keepingCapacity: false)
            preparedProfileEditingSnapshot = nil
        }
    }

    func profilePresentation(
        for destination: ProfilePresentationDestination
    ) -> ProfilePresentationState? {
        switch destination {
        case .inspector:
            inspectorProfilePresentation
        case .contextual:
            contextualProfilePresentation
        case .expanded:
            expandedProfilePresentation
        }
    }

    func setProfilePresentation(
        _ value: ProfilePresentationState?,
        for destination: ProfilePresentationDestination
    ) {
        switch destination {
        case .inspector:
            inspectorProfilePresentation = value
        case .contextual:
            contextualProfilePresentation = value
        case .expanded:
            expandedProfilePresentation = value
        }
    }

    func profile(
        _ value: UserProfile,
        applyingPresenceFrom member: Member
    ) -> UserProfile {
        var result = value
        result.status = member.status
        if member.id == profileCustomStatusUserID {
            // Account settings also represent an explicit clear. Lazy member lists
            // and the synthetic You member are not authoritative for our own status.
            result.customStatus = profileCustomStatus?.displayText
        } else if member.id != snapshot?.currentUser.id {
            result.customStatus = member.customStatus
        }
        return result
    }

    func beginCurrentUserProfilePrefetch(
        in guildID: GuildID?,
        account session: AppModelAccountSession?
    ) {
        guard let session, let user = snapshot?.currentUser else { return }
        let cacheKey = ProfileCacheKey(userID: user.id, guildID: guildID)
        guard profileCache[cacheKey] == nil,
              currentUserProfilePrefetch?.key != cacheKey
        else { return }

        currentUserProfilePrefetch?.task.cancel()
        let task = startAccountChildTask(account: session) { model, session in
            defer {
                if model.currentUserProfilePrefetch?.key == cacheKey {
                    model.currentUserProfilePrefetch = nil
                }
            }
            do {
                let profile = try await session.provider.profile(
                    for: user.id,
                    in: guildID
                )
                guard !Task.isCancelled,
                      model.isCurrentAccountSession(session)
                else { return }
                model.profileCache[cacheKey] = profile
                let invalidation = model.profileInvalidationRevision
                let baseline = try await session.provider.cachedProfileEditingSnapshot(in: .main)
                guard !Task.isCancelled, model.isCurrentAccountSession(session), model.profileInvalidationRevision == invalidation else { return }
                model.preparedProfileEditingSnapshot = baseline
                model.startAccountChildTask(account: session) { _, _ in
                    await ProfilePreviewPreparation.preload(baseline?.presentation ?? profile)
                }
            } catch {
                // Prefetching is speculative. The normal profile presentation
                // path remains responsible for surfacing load failures.
            }
        }
        currentUserProfilePrefetch = CurrentUserProfilePrefetch(
            key: cacheKey,
            task: task
        )
    }
}
