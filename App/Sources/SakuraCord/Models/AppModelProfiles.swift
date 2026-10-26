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
    }

    func consumeProfileChanged(userID: UserID, scope: ProfileEditingScope, value: UserProfile?) {
        if userID == snapshot?.currentUser.id { preparedProfileEditingSnapshot = nil }
        let key = ProfileCacheKey(userID: userID, guildID: scope.guildID)
        profileCache[key] = value
        for destination in [ProfilePresentationDestination.inspector, .contextual, .expanded] {
            guard var presentation = profilePresentation(for: destination), presentation.member.id == userID,
                  presentation.guildID == scope.guildID else { continue }
            switch destination {
            case .inspector: inspectorProfileTask?.cancel()
            case .contextual: contextualProfileTask?.cancel()
            case .expanded: expandedProfileTask?.cancel()
            }
            if let value {
                presentation.profile = value
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
            // The provider publishes `.currentUserStatusChanged`; applying the
            // pick here as well could overwrite a newer remote or saved value.
            try await session.provider.updateStatus(status)
        } catch {
            guard isCurrentAccountSession(session) else { return }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            errorMessage = error.localizedDescription
        }
    }

    func applyCurrentStatus(_ status: PresenceStatus) {
        currentStatusRevision &+= 1
        currentStatus = status
        members = membersWithCurrentStatus(members)
    }

    /// `currentStatus` is the current user's only status source; cached member
    /// lists can hold an older one, so they pass through here when shown again.
    func membersWithCurrentStatus(_ members: [Member]) -> [Member] {
        members.map(memberWithCurrentStatus)
    }

    func memberWithCurrentStatus(_ member: Member) -> Member {
        guard member.id == currentUser?.id, member.status != currentStatus else { return member }
        var member = member
        member.status = currentStatus
        return member
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
        presentProfile(for: member, in: selectedGuildID, destination: .inspector)
    }

    @discardableResult
    func showProfile(for user: User, sourceMessage: Message? = nil) -> UUID {
        let guildID = sourceMessage.map { messagePresentationGuildID(for: $0) } ?? selectedGuildID
        if let sourceMessage, sourceMessage.author.id == user.id,
           DiscordBuiltInCommands.isClydeMessage(sourceMessage)
            || (sourceMessage.webhookID != nil && user.isWebhookIdentity) {
            let isClyde = DiscordBuiltInCommands.isClydeMessage(sourceMessage)
            contextualProfileTask?.cancel()
            let requestID = UUID()
            contextualProfilePresentation = ProfilePresentationState(
                requestID: requestID, guildID: guildID,
                member: Member(user: sourceMessage.author, roleName: "", status: .offline),
                isCurrentUser: false, profile: UserProfile(user: sourceMessage.author),
                isLoading: false, errorMessage: nil, isWebhook: !isClyde, isClyde: isClyde,
                sourceMessageID: sourceMessage.id
            )
            return requestID
        }
        let member = profileMember(user.id, in: guildID)
            ?? Member(user: user, roleName: "Member", status: .offline)
        return presentProfile(for: member, in: guildID, destination: .contextual)
    }

    func showSystemMessageProfile(
        userID: UserID,
        sourceMessage: Message? = nil
    ) {
        if let user = systemMessageUser(
            userID: userID,
            sourceMessage: sourceMessage
        ) {
            _ = showProfile(for: user, sourceMessage: sourceMessage)
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
        presentProfile(for: member, in: selectedGuildID, destination: .inspector)
    }

    func authorPresentation(for message: Message) -> MessageAuthorPresentation {
        let guildID = messagePresentationGuildID(for: message)
        let member = guildID.flatMap { membersByGuildID[$0]?[message.author.id] }
            ?? (guildID == selectedGuildID ? membersByID[message.author.id] : nil)
        let roles = guildID.flatMap { guildRolesByGuildID[$0] }
            ?? (guildID == selectedGuildID ? guildRoles : [])
        let presentation = MessageAuthorPresentation.resolve(message: message, member: member, roles: roles)
        var user = privateConversationUser(presentation.user, in: guildID)
        user.avatarDecorationURL = user.avatarDecorationURL ?? message.author.avatarDecorationURL
        return MessageAuthorPresentation(user: cosmeticPolicy.user(user), roleColorHex: presentation.roleColorHex)
    }

    func authorPresentation(
        for replyPreview: MessageReplyPreview, in message: Message? = nil
    ) -> MessageAuthorPresentation {
        let guildID = message.map { messagePresentationGuildID(for: $0) } ?? selectedGuildID
        let member = guildID.flatMap { membersByGuildID[$0]?[replyPreview.author.id] }
            ?? (guildID == selectedGuildID ? membersByID[replyPreview.author.id] : nil)
        let roles = guildID.flatMap { guildRolesByGuildID[$0] } ?? (guildID == selectedGuildID ? guildRoles : [])
        let presentation = MessageAuthorPresentation.resolve(
            replyPreview: replyPreview,
            member: member,
            roles: roles
        )
        return MessageAuthorPresentation(
            user: cosmeticPolicy.user(privateConversationUser(presentation.user, in: guildID)),
            roleColorHex: presentation.roleColorHex
        )
    }

    /// Discord names people by their friend nickname in DMs and group DMs only.
    func privateConversationUser(_ user: User, in guildID: GuildID?) -> User {
        guard guildID == nil, !user.isWebhookIdentity, let nickname = friendNickname(for: user.id) else { return user }
        var user = user
        user.displayName = nickname
        return user
    }

    func messagePresentationGuildID(for message: Message) -> GuildID? {
        if let guildID = message.guildID { return guildID }
        if let channel = messagePresentationChannel(message.channelID) {
            return channel.guildID
        }
        let thread = (openThread?.id == message.channelID ? openThread : nil)
            ?? inbox.threads[message.channelID]
            ?? threads.first { $0.id == message.channelID }
            ?? activeJoinedThreads.first { $0.id == message.channelID }
        return thread?.guildID ?? thread?.parentID.flatMap { messagePresentationChannel($0)?.guildID }
    }

    @discardableResult
    func presentProfile(
        for member: Member,
        in guildID: GuildID?,
        destination: ProfilePresentationDestination
    ) -> UUID {
        let requestID = UUID()
        let cacheKey = ProfileCacheKey(
            userID: member.id,
            guildID: guildID
        )
        let cachedProfile = profileCache[cacheKey]
        let presentation = ProfilePresentationState(
            requestID: requestID,
            guildID: guildID,
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
                      profilePresentation(
                          for: destination
                      )?.requestID == requestID
                else {
                    return
                }
                profileCache[cacheKey] = loaded
                var value = profilePresentation(for: destination)
                value?.profile = loaded
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
        guard !presentation.isLocalIdentity else { return }
        presentProfile(for: presentation.member, in: presentation.guildID, destination: .expanded)
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

    func profileMember(_ userID: UserID, in guildID: GuildID?) -> Member? {
        guildID.flatMap { membersByGuildID[$0]?[userID] }
            ?? (guildID == selectedGuildID ? membersByID[userID] : nil)
    }

    /// Resolves presence from the member store so presented profiles stay live.
    func liveProfilePresentation(
        for destination: ProfilePresentationDestination
    ) -> ProfilePresentationState? {
        guard var presentation = profilePresentation(for: destination) else { return nil }
        guard !presentation.isLocalIdentity else { return presentation }
        presentation.member = profileMember(presentation.member.id, in: presentation.guildID) ?? presentation.member
        if presentation.member.id == currentUser?.id {
            // Member stores do not track our own presence; the account does.
            presentation.member.status = currentStatus
        }
        if presentation.member.id == profileCustomStatusUserID {
            // Account settings are authoritative for our own status, including clears.
            presentation.member.customStatus = profileCustomStatus?.displayText
        }
        if presentation.guildID == nil, let nickname = friendNickname(for: presentation.member.id) {
            // Profiles opened from a DM or group DM use the friend nickname.
            presentation.member.user.displayName = nickname
            presentation.profile?.displayName = nickname
        }
        return presentation
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
