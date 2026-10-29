import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    /// Friends is the Direct Messages home: chosen explicitly, or shown
    /// when no conversation is selected there.
    var isFriendsPresented: Bool {
        selectedGuildID == nil && onboardingEntryGuildID == nil && (friends.isPresented || selectedChannelID == nil)
    }

    var friendsSection: FriendsSection {
        friends.selectedSection ?? friends.initialSection
    }

    /// Discord's visible sections; the chosen one stays while it empties.
    var visibleFriendsSections: [FriendsSection] {
        let visible = friends.availableSections
        let section = friendsSection
        return FriendsSection.allCases.filter { visible.contains($0) || $0 == section }
    }

    var incomingFriendRequestCount: Int {
        friends.incomingCount
    }

    var isFriendsSearchActive: Bool {
        isFriendsPresented && friendsSection != .addFriend
    }

    var friendsSearchText: String {
        get { friends.searchTextBySection[friendsSection] ?? "" }
        set { friends.searchTextBySection[friendsSection] = newValue }
    }

    var friendsProjection: FriendsProjection {
        friends.projection(for: friendsSection, query: friendsSearchText)
    }

    func openFriends() {
        lastDirectMessageSelection = .friends
        cancelConversationNavigation()
        guard selectedGuildID == nil else {
            friends.isPresented = true
            selectGuild(nil)
            return
        }
        suspendSelectedConversationPresentation()
        closeThread()
        friends.isPresented = true
        selectedChannelID = nil
        loadRelationshipsIfNeeded(for: friendsSection)
    }

    func selectFriendsSection(_ section: FriendsSection) {
        guard friendsSection != section else {
            if section == .addFriend { friends.addFriendFocusRequest &+= 1 }
            return
        }
        // Leaving a list for Add Friend discards the list's searches, as
        // unmounting Discord's list does.
        if section == .addFriend {
            friends.searchTextBySection = [:]
            friends.addFriendFocusRequest &+= 1
        } else if friends.selectedSection == .addFriend {
            friends.resetAddFriendForm()
        }
        friends.isSearchFocused = false
        friends.selectedSection = section
        loadRelationshipsIfNeeded(for: section)
    }

    /// The full read starts from the first list other than Online or Add
    /// Friend; READY already supplies those.
    func loadRelationshipsIfNeeded(for section: FriendsSection) {
        guard section == .all || section == .pending, friends.loadedSections.insert(section).inserted else { return }
        let session = accountSession()
        startAccountChildTask(account: session) { model, session in
            do {
                try await session.provider.loadRelationships()
            } catch {
                guard model.isCurrentAccountSession(session) else { return }
                model.friends.loadedSections.remove(section)
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            }
        }
    }

    /// A new Gateway connection makes the full read eligible again; the
    /// provider still reads at most once per connection.
    func friendsConnectionChanged() {
        friends.loadedSections = []
        if isFriendsPresented { loadRelationshipsIfNeeded(for: friendsSection) }
    }

    func applyRelationships(_ relationships: [Relationship]) {
        guard var value = snapshot else { return }
        friends.replaceRelationships(relationships)
        ignoredUsers.replaceRelationships(relationships)
        let previousBlocked = value.blockedOrIgnoredUserIDs
        let previousIgnored = value.relationships.ignoredUserIDs
        value.relationships = relationships
        value.blockedOrIgnoredUserIDs = relationships.blockedOrIgnoredUserIDs
        value.friendUserIDs = relationships.friendUserIDs
        value.relationshipNicknamesByUserID = relationships.nicknamesByUserID
        snapshot = value
        if previousBlocked != value.blockedOrIgnoredUserIDs { reconcileInboxEligibility() }
        if previousIgnored != relationships.ignoredUserIDs || previousBlocked != value.blockedOrIgnoredUserIDs {
            ignoredUsers.revealedMessageIDs = []
            ignoredUsers.collapsingMessageIDs = []
            ignoredUsers.revealedProfileRequests = []
            timelinePresentationRevision &+= 1
            typingState.clearAll()
            reconcilePrivateCallSounds()
            reconcileIgnoredVoiceParticipants()
        }
        forwardSearchSourceRevision &+= 1
        let ids = Set(relationships.map(\.id))
        friends.pendingUserIDs.formIntersection(ids)
    }

    func applyRelationshipPresences(_ presences: [UserID: UserPresence], isComplete: Bool) {
        friends.updatePresences(presences, isComplete: isComplete)
    }

    // MARK: - Add Friend

    func sendFriendRequest() {
        guard !friends.isSendingRequest else { return }
        guard case let .valid(tag, username, discriminator) = FriendsListPolicy.parseUsername(friends.addFriendText) else {
            friends.addFriendSuccess = nil
            friends.addFriendError = FriendsListPolicy.usernameFailureMessage
            return
        }
        friends.isSendingRequest = true
        friends.addFriendError = nil
        friends.addFriendSuccess = nil
        let note = friends.addFriendNote
        let session = accountSession()
        startAccountChildTask(account: session) { model, session in
            defer { if model.isCurrentAccountSession(session) { model.friends.isSendingRequest = false } }
            do {
                try await session.provider.sendFriendRequest(username: username, discriminator: discriminator, note: note)
                guard model.isCurrentAccountSession(session) else { return }
                model.friends.addFriendText = ""
                model.friends.addFriendNote = ""
                model.friends.addFriendSuccess = tag
                model.friends.addFriendFocusRequest &+= 1
            } catch RelationshipActionError.strangerConfirmationRequired {
                guard model.isCurrentAccountSession(session) else { return }
                model.friends.addFriendError = FriendsListPolicy.usernameFailureMessage
            } catch {
                guard model.isCurrentAccountSession(session), !(error is CancellationError) else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                model.friends.addFriendError = error.localizedDescription
                model.friends.requestFailure = error.localizedDescription
            }
        }
    }

    /// Profiles, DMs and user menus send by user ID, not by typing a tag.
    func sendFriendRequest(to user: User, location: IgnoreActionLocation) {
        performRelationshipAction(on: user.id, failure: \.requestFailure) { _, session in
            do {
                try await session.provider.sendFriendRequest(to: user, location: location)
            } catch RelationshipActionError.strangerConfirmationRequired {
                // Code 80013 on a send is silent, as in the official client.
            }
        }
    }

    // MARK: - Managing relationships

    func acceptFriendRequest(from user: User, confirmingStranger: Bool = false) {
        performRelationshipAction(on: user.id) { model, session in
            do {
                try await session.provider.acceptFriendRequest(from: user.id, confirmingStranger: confirmingStranger)
            } catch RelationshipActionError.strangerConfirmationRequired {
                guard model.isCurrentAccountSession(session) else { return }
                model.friends.confirmation = .acceptStranger(user)
            }
        }
    }

    func removeRelationship(with userID: UserID, as removal: RelationshipRemoval) {
        performRelationshipAction(on: userID) { _, session in
            try await session.provider.removeRelationship(with: userID, as: removal)
        }
    }

    func setUserIgnored(_ user: User, ignored: Bool, location: IgnoreActionLocation = .contextMenu) {
        guard user.id != currentUser?.id, !user.isWebhookIdentity, !user.isSystem,
              relationships.first(where: { $0.id == user.id })?.type != .blocked,
              isUserIgnored(user.id) != ignored else { return }
        setUserIgnored(user.id, ignored: ignored, location: location)
    }

    func setUserIgnored(_ userID: UserID, ignored: Bool, location: IgnoreActionLocation) {
        guard userID != currentUser?.id,
              relationships.first(where: { $0.id == userID })?.type != .blocked,
              isUserIgnored(userID) != ignored else { return }
        performRelationshipAction(on: userID) { _, session in
            try await session.provider.setUserIgnored(userID, ignored: ignored, location: location)
        }
    }

    func blockUser(_ user: User) {
        performRelationshipAction(on: user.id) { _, session in
            try await session.provider.blockUser(user.id)
        }
    }

    func confirmFriendsAction(_ confirmation: FriendsConfirmation) {
        friends.confirmation = nil
        switch confirmation {
        case .removeFriend(let user):
            guard isFriend(user.id) else { return }
            removeRelationship(with: user.id, as: .removeFriend)
        case .ignore(let user, let location):
            setUserIgnored(user, ignored: true, location: location)
        case .block(let user):
            guard relationships.first(where: { $0.id == user.id })?.type != .blocked else { return }
            blockUser(user)
        case .acceptStranger(let user):
            guard relationships.first(where: { $0.id == user.id })?.type == .incomingRequest else { return }
            acceptFriendRequest(from: user, confirmingStranger: true)
        }
    }

    func showFriendProfile(_ row: FriendRow) {
        var member = Member(user: row.user, roleName: "", status: row.presence.status)
        member.customStatus = row.presence.customStatus
        presentProfile(for: member, in: nil, destination: .expanded)
    }

    /// Opens the existing conversation, or creates it through the provider.
    func openDirectMessage(with user: User) {
        if let channel = snapshot?.channels.first(where: {
            $0.kind == .directMessage && $0.recipients.first?.id == user.id
        }) {
            navigate(to: channel.id)
            return
        }
        startConversationNavigation { model, session in
            do {
                let channel = try await session.provider.ensurePrivateChannel(for: user.id)
                guard !Task.isCancelled, model.isCurrentAccountSession(session) else { return }
                if model.snapshot?.channels.contains(where: { $0.id == channel.id }) == false {
                    model.snapshot?.channels.append(channel)
                    model.forwardSearchSourceRevision &+= 1
                }
                if model.selectedGuildID != nil { await model.activateGuild(nil, account: session) }
                guard !Task.isCancelled, model.isCurrentAccountSession(session) else { return }
                model.recordForwardDestinationVisit(channel.id)
                model.closeThread()
                model.selectedChannelID = channel.id
            } catch {
                guard !Task.isCancelled, model.isCurrentAccountSession(session), !(error is CancellationError) else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                model.errorMessage = error.localizedDescription
            }
        }
    }

    /// One user-initiated mutation per user at a time. Gateway events, which
    /// can arrive before the response, update the list; responses never do.
    private func performRelationshipAction(
        on userID: UserID, failure: ReferenceWritableKeyPath<FriendsState, String?> = \.actionError,
        _ operation: @escaping @MainActor (AppModel, AppModelAccountSession) async throws -> Void
    ) {
        guard friends.pendingUserIDs.insert(userID).inserted else { return }
        friends[keyPath: failure] = nil
        let session = accountSession()
        startAccountChildTask(account: session) { model, session in
            defer { if model.isCurrentAccountSession(session) { model.friends.pendingUserIDs.remove(userID) } }
            do {
                try await operation(model, session)
            } catch {
                guard model.isCurrentAccountSession(session), !(error is CancellationError) else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                model.friends[keyPath: failure] = error.localizedDescription
            }
        }
    }
}
