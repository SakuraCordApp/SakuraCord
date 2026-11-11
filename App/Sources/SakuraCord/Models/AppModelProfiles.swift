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
        guard let currentUserID = currentUser?.id ?? snapshot?.currentUser.id,
              member.id == currentUserID else { return member }
        var member = member
        member.status = currentStatus
        if currentUserActivity != nil {
            member.activityText = currentUserActivityDisplayText
            member.isListeningToMusic = isCurrentUserListeningToMusic
            member.richActivity = currentUserRichActivity
        } else {
            member.activityText = member.customStatus
            member.isListeningToMusic = false
            member.richActivity = nil
        }
        if member.id == profileCustomStatusUserID, let text = profileCustomStatus?.displayText {
            member.customStatus = text
            if currentUserActivity == nil {
                member.activityText = text
            }
        }
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
        let memberToPresent: Member
        if member.id == currentUser?.id || member.id == snapshot?.currentUser.id {
            memberToPresent = memberWithCurrentStatus(member)
        } else {
            memberToPresent = member
        }
        presentProfile(for: memberToPresent, in: selectedGuildID, destination: .inspector)
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
        var member: Member
        if let resolved = profileMember(user.id, in: guildID) {
            member = resolved
            applyPresenceIfBetter(to: &member, from: friends.presences[user.id])
        } else {
            var fallback = Member(user: user, roleName: "Member", status: .offline)
            if let presence = friends.presences[user.id] {
                fallback.status = presence.status
                fallback.customStatus = presence.customStatus
                fallback.activityText = presence.activityText
                fallback.isListeningToMusic = presence.isListeningToMusic
                fallback.isMobileOnly = presence.isMobileOnly
                fallback.richActivity = presence.richActivity
            }
            member = fallback
        }
        if member.id == currentUser?.id || member.id == snapshot?.currentUser.id {
            member = memberWithCurrentStatus(member)
        }
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
        var member: Member
        if let resolved = profileMember(user.id, in: selectedGuildID) ?? membersByID[user.id] {
            member = resolved
            applyPresenceIfBetter(to: &member, from: friends.presences[user.id])
        } else {
            var fallback = Member(
                user: user,
                roleName: "Direct Message",
                status: .offline
            )
            if let presence = friends.presences[user.id] {
                fallback.status = presence.status
                fallback.customStatus = presence.customStatus
                fallback.activityText = presence.activityText
                fallback.isListeningToMusic = presence.isListeningToMusic
                fallback.isMobileOnly = presence.isMobileOnly
                fallback.richActivity = presence.richActivity
            }
            member = fallback
        }
        if member.id == currentUser?.id || member.id == snapshot?.currentUser.id {
            member = memberWithCurrentStatus(member)
        }
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
        return MessageAuthorPresentation(
            user: cosmeticPolicy.user(user),
            roleColorHex: presentation.roleColorHex,
            roleSecondaryColorHex: presentation.roleSecondaryColorHex,
            roleTertiaryColorHex: presentation.roleTertiaryColorHex,
            topRoleWithIcon: presentation.topRoleWithIcon
        )
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
            roleColorHex: presentation.roleColorHex,
            roleSecondaryColorHex: presentation.roleSecondaryColorHex,
            roleTertiaryColorHex: presentation.roleTertiaryColorHex,
            topRoleWithIcon: presentation.topRoleWithIcon
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
        var member = member
        let isCurrent = member.id == snapshot?.currentUser.id || member.id == currentUser?.id
        if isCurrent {
            member = memberWithCurrentStatus(member)
        }
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
            isCurrentUser: isCurrent,
            profile: cachedProfile,
            isLoading: cachedProfile == nil,
            errorMessage: nil
        )
        setProfileTask(nil, for: destination)
        setProfilePresentation(presentation, for: destination)

        let session = accountSession()
        let memberID = member.id
        let isOffline = member.status == .offline
        if let cachedProfile {
            if !isCurrent, isOffline, let targetGuildID = guildID ?? cachedProfile.mutualGuilds.first?.id {
                refreshCachedProfilePresence(
                    memberID: memberID, targetGuildID: targetGuildID, guildID: guildID,
                    requestID: requestID, destination: destination, session: session
                )
            }
            return requestID
        }

        loadProfilePresentation(
            memberID: memberID, guildID: guildID, requestID: requestID,
            destination: destination, isCurrent: isCurrent, isOffline: isOffline, session: session
        )
        return requestID
    }

    private func setProfileTask(_ task: Task<Void, Never>?, for destination: ProfilePresentationDestination) {
        switch destination {
        case .inspector:
            inspectorProfileTask?.cancel()
            inspectorProfileTask = task
        case .contextual:
            contextualProfileTask?.cancel()
            contextualProfileTask = task
        case .expanded:
            expandedProfileTask?.cancel()
            expandedProfileTask = task
        }
    }

    private func applyResolvedProfileMember(
        _ resolvedMember: Member?,
        memberID: UserID,
        guildID: GuildID?,
        destination: ProfilePresentationDestination
    ) {
        guard var value = profilePresentation(for: destination) else { return }
        if let resolvedMember {
            if let guildID {
                membersByGuildID[guildID, default: [:]][resolvedMember.id] = resolvedMember
                if selectedGuildID == guildID {
                    membersByID[resolvedMember.id] = resolvedMember
                    if let index = members.firstIndex(where: { $0.id == resolvedMember.id }) {
                        members[index] = resolvedMember
                    }
                }
            }
            value.member = resolvedMember
        } else if let live = profileMember(memberID, in: guildID) {
            value.member = live
        }
        if let livePresence = friends.presences[memberID] {
            applyPresenceIfBetter(to: &value.member, from: livePresence)
        }
        setProfilePresentation(value, for: destination)
    }

    private func refreshCachedProfilePresence(
        memberID: UserID,
        targetGuildID: GuildID,
        guildID: GuildID?,
        requestID: UUID,
        destination: ProfilePresentationDestination,
        session: AppModelAccountSession
    ) {
        let task = Task { [weak self] in
            guard let self else { return }
            let resolved = try? await session.provider.requestMembersByID([memberID], guildID: targetGuildID, presences: true)
            guard !Task.isCancelled,
                  isCurrentAccountSession(session),
                  profilePresentation(for: destination)?.requestID == requestID
            else { return }
            applyResolvedProfileMember(
                resolved?.first(where: { $0.id == memberID }),
                memberID: memberID,
                guildID: targetGuildID,
                destination: destination
            )
        }
        setProfileTask(task, for: destination)
    }

    private func loadProfilePresentation(
        memberID: UserID,
        guildID: GuildID?,
        requestID: UUID,
        destination: ProfilePresentationDestination,
        isCurrent: Bool,
        isOffline: Bool,
        session: AppModelAccountSession
    ) {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                async let profileFetch = session.provider.profile(
                    for: memberID,
                    in: guildID
                )
                let resolvedMembers: [Member]?
                if let guildID, !isCurrent {
                    resolvedMembers = try? await session.provider.requestMembersByID([memberID], guildID: guildID, presences: true)
                } else {
                    resolvedMembers = nil
                }
                let loaded = try await profileFetch
                if guildID == nil, !isCurrent, isOffline, let mutualGuildID = loaded.mutualGuilds.first?.id {
                    _ = try? await session.provider.requestMembersByID([memberID], guildID: mutualGuildID, presences: true)
                }
                guard !Task.isCancelled,
                      isCurrentAccountSession(session),
                      profilePresentation(for: destination)?.requestID == requestID
                else { return }
                let cacheKey = ProfileCacheKey(userID: memberID, guildID: guildID)
                let profile = cacheLoadedProfile(loaded, for: cacheKey)
                var value = profilePresentation(for: destination)
                value?.profile = profile
                value?.isLoading = false
                value?.errorMessage = nil
                setProfilePresentation(value, for: destination)
                applyResolvedProfileMember(
                    resolvedMembers?.first(where: { $0.id == memberID }),
                    memberID: memberID,
                    guildID: guildID,
                    destination: destination
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      isCurrentAccountSession(session),
                      profilePresentation(for: destination)?.requestID == requestID
                else { return }
                var value = profilePresentation(for: destination)
                value?.isLoading = false
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                value?.errorMessage = error.localizedDescription
                setProfilePresentation(value, for: destination)
            }
        }
        setProfileTask(task, for: destination)
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

    /// Caches a profile from the provider with the roles current here, since a
    /// role change can arrive between the provider returning it and this.
    @discardableResult
    func cacheLoadedProfile(_ profile: UserProfile, for key: ProfileCacheKey) -> UserProfile {
        var profile = profile
        if let roles = key.guildID.flatMap({ guildRolesByGuildID[$0] }) { profile.refreshRoles(from: roles) }
        profileCache[key] = profile
        return profile
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

    private func applyPresenceIfBetter(to member: inout Member, from presence: UserPresence?) {
        guard let presence else { return }
        if member.status == .offline, presence.status.isVisibleOnline {
            member.status = presence.status
            member.isMobileOnly = presence.isMobileOnly
        }
        if let rich = presence.richActivity {
            member.richActivity = rich
        }
        if let text = presence.activityText {
            member.activityText = text
            member.isListeningToMusic = presence.isListeningToMusic
        }
        if let custom = presence.customStatus {
            member.customStatus = custom
        }
        if presence.isListeningToMusic {
            member.isListeningToMusic = true
        }
        if presence.isMobileOnly {
            member.isMobileOnly = true
        }
    }

    func profileMember(_ userID: UserID, in guildID: GuildID?) -> Member? {
        if let currentUserID = currentUser?.id ?? snapshot?.currentUser.id, userID == currentUserID {
            let base = guildID.flatMap { membersByGuildID[$0]?[userID] }
                ?? (guildID == selectedGuildID ? membersByID[userID] : nil)
                ?? membersByID[userID]
                ?? snapshot.map { Member(user: $0.currentUser, roleName: "", status: currentStatus) }
            return base.map(memberWithCurrentStatus)
        }
        if let guildID, let member = membersByGuildID[guildID]?[userID] {
            if member.status.isVisibleOnline {
                return member
            }
            for otherMembers in membersByGuildID.values {
                if let better = otherMembers[userID], better.status.isVisibleOnline {
                    var merged = member
                    merged.status = better.status
                    merged.customStatus = better.customStatus ?? member.customStatus
                    merged.activityText = better.activityText ?? member.activityText
                    merged.isListeningToMusic = better.isListeningToMusic || member.isListeningToMusic
                    merged.isMobileOnly = better.isMobileOnly || member.isMobileOnly
                    merged.richActivity = better.richActivity ?? member.richActivity
                    return merged
                }
            }
            return member
        }
        if let member = (guildID == selectedGuildID ? membersByID[userID] : nil) ?? membersByID[userID] {
            return member
        }
        if let directMember = members.first(where: { $0.id == userID }) {
            return directMember
        }
        for guildMembers in membersByGuildID.values {
            if let member = guildMembers[userID] {
                return member
            }
        }
        return nil
    }

    /// Resolves presence from the member store so presented profiles stay live.
    func liveProfilePresentation(
        for destination: ProfilePresentationDestination
    ) -> ProfilePresentationState? {
        guard var presentation = profilePresentation(for: destination) else { return nil }
        guard !presentation.isLocalIdentity else { return presentation }
        if let liveMember = profileMember(presentation.member.id, in: presentation.guildID) {
            presentation.member = liveMember
            applyPresenceIfBetter(to: &presentation.member, from: friends.presences[presentation.member.id])
        } else if let presence = friends.presences[presentation.member.id] {
            // Live relationship presence applies when no member cache holds this user.
            presentation.member.status = presence.status
            presentation.member.customStatus = presence.customStatus
            presentation.member.activityText = presence.activityText
            presentation.member.isListeningToMusic = presence.isListeningToMusic
            presentation.member.isMobileOnly = presence.isMobileOnly
            presentation.member.richActivity = presence.richActivity
        }
        if presentation.member.id == currentUser?.id || presentation.member.id == snapshot?.currentUser.id {
            // Member stores do not track our own presence; the account does.
            presentation.member = memberWithCurrentStatus(presentation.member)
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
                model.cacheLoadedProfile(profile, for: cacheKey)
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
