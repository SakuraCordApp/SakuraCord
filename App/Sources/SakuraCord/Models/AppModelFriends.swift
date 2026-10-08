import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    /// Friends is the Direct Messages home: chosen explicitly, or shown
    /// when no conversation is selected there.
    var isFriendsPresented: Bool {
        selectedGuildID == nil && onboardingEntryGuildID == nil && (friends.isPresented || selectedChannelID == nil)
    }

    var relationships: [Relationship] {
        snapshot?.relationships ?? []
    }

    var friendsSection: FriendsSection {
        friends.selectedSection ?? FriendsListPolicy.initialSection(relationships)
    }

    /// Discord's visible sections; the chosen one stays while it empties.
    var visibleFriendsSections: [FriendsSection] {
        let visible = FriendsListPolicy.visibleSections(relationships, presences: friends.presences)
        let section = friendsSection
        return FriendsSection.allCases.filter { visible.contains($0) || $0 == section }
    }

    var incomingFriendRequestCount: Int {
        FriendsListPolicy.incomingRequestCount(relationships)
    }

    var isFriendsSearchActive: Bool {
        isFriendsPresented && friendsSection != .addFriend
    }

    var friendsSearchText: String {
        get { friends.searchTextBySection[friendsSection] ?? "" }
        set { friends.searchTextBySection[friendsSection] = newValue }
    }

    func friendsListGroups() -> [FriendsListGroup] {
        FriendsListPolicy.groups(
            for: friendsSection,
            rows: FriendsListPolicy.rows(relationships, presences: friends.presences),
            query: friendsSearchText
        )
    }

    func openFriends() {
        cancelConversationNavigation()
        guard selectedGuildID == nil else {
            friends.isPresented = true
            selectGuild(nil)
            return
        }
        suspendSelectedConversationPresentation()
        closeThread()
        dismissMessageSearch()
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
        value.relationships = relationships
        value.friendUserIDs = relationships.friendUserIDs
        value.relationshipNicknamesByUserID = relationships.nicknamesByUserID
        snapshot = value
        forwardSearchSourceRevision &+= 1
        let ids = Set(relationships.map(\.id))
        friends.pendingUserIDs.formIntersection(ids)
    }

    func applyRelationshipPresences(_ presences: [UserID: UserPresence], isComplete: Bool) {
        if isComplete {
            friends.presences = presences
        } else {
            friends.presences.merge(presences) { _, newer in newer }
        }
    }

    // MARK: - Add Friend

    func sendFriendRequest() {
        guard !friends.isSendingRequest else { return }
        guard case let .valid(username, discriminator) = FriendsListPolicy.parseUsername(friends.addFriendText) else {
            friends.addFriendSuccess = nil
            friends.addFriendError = "Hm, didn’t work. Double check that the username is correct."
            return
        }
        let tag = discriminator.map { "\(username)#\(String(format: "%04d", $0))" } ?? username
        friends.isSendingRequest = true
        friends.addFriendError = nil
        friends.addFriendSuccess = nil
        let session = accountSession()
        startAccountChildTask(account: session) { model, session in
            defer { if model.isCurrentAccountSession(session) { model.friends.isSendingRequest = false } }
            do {
                try await session.provider.sendFriendRequest(
                    username: username, discriminator: discriminator,
                    captchaHandler: model.friendsCaptchaHandler(account: session)
                )
                guard model.isCurrentAccountSession(session) else { return }
                model.friends.addFriendText = ""
                model.friends.addFriendSuccess = tag
                model.friends.addFriendFocusRequest &+= 1
            } catch {
                guard model.isCurrentAccountSession(session), !(error is CancellationError) else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                model.friends.addFriendError = error.localizedDescription
            }
        }
    }

    // MARK: - Managing relationships

    func acceptFriendRequest(from user: User, confirmingStranger: Bool = false) {
        performRelationshipAction(on: user.id) { model, session in
            do {
                try await session.provider.acceptFriendRequest(
                    from: user.id, confirmingStranger: confirmingStranger,
                    captchaHandler: model.friendsCaptchaHandler(account: session)
                )
            } catch RelationshipActionError.strangerConfirmationRequired {
                guard model.isCurrentAccountSession(session) else { return }
                model.friends.confirmation = .acceptStranger(user)
            }
        }
    }

    func removeRelationship(with user: User, as removal: RelationshipRemoval) {
        performRelationshipAction(on: user.id) { _, session in
            try await session.provider.removeRelationship(with: user.id, as: removal)
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
        case .removeFriend(let user): removeRelationship(with: user, as: .removeFriend)
        case .block(let user): blockUser(user)
        case .acceptStranger(let user): acceptFriendRequest(from: user, confirmingStranger: true)
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
        let session = accountSession()
        startAccountChildTask(account: session) { model, session in
            do {
                let channel = try await session.provider.ensurePrivateChannel(for: user.id)
                guard model.isCurrentAccountSession(session) else { return }
                if model.snapshot?.channels.contains(where: { $0.id == channel.id }) == false {
                    model.snapshot?.channels.append(channel)
                    model.forwardSearchSourceRevision &+= 1
                }
                model.navigate(to: channel.id)
            } catch {
                guard model.isCurrentAccountSession(session) else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                model.errorMessage = error.localizedDescription
            }
        }
    }

    /// One user-initiated mutation per user at a time. Gateway events, which
    /// can arrive before the response, update the list; responses never do.
    private func performRelationshipAction(
        on userID: UserID,
        _ operation: @escaping @MainActor (AppModel, AppModelAccountSession) async throws -> Void
    ) {
        guard friends.pendingUserIDs.insert(userID).inserted else { return }
        friends.actionError = nil
        let session = accountSession()
        startAccountChildTask(account: session) { model, session in
            defer { if model.isCurrentAccountSession(session) { model.friends.pendingUserIDs.remove(userID) } }
            do {
                try await operation(model, session)
            } catch {
                guard model.isCurrentAccountSession(session), !(error is CancellationError) else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                model.friends.actionError = error.localizedDescription
            }
        }
    }

    /// A handler bound to this account session; a solution never outlives it.
    private func friendsCaptchaHandler(account: AppModelAccountSession) -> DiscordCaptchaHandler {
        { [weak self] challenge in
            guard let self else { throw CancellationError() }
            return try await self.solveFriendsCaptcha(challenge, account: account)
        }
    }

    private func solveFriendsCaptcha(_ challenge: DiscordCaptchaChallenge, account: AppModelAccountSession) async throws -> String {
        guard isCurrentAccountSession(account) else { throw CancellationError() }
        return try await friends.captcha.solution(for: challenge)
    }
}
