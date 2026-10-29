import AppKit
import SakuraCordModels

/// The originating surface supplies its context; a menu never borrows an
/// unrelated selected server or composer.
struct UserMenuContext {
    var guildID: GuildID?
    var channelID: ChannelID?
    var isLocalIdentity = false
    var ignoreLocation: IgnoreActionLocation?
}

struct UserMenuAction: Identifiable {
    enum Group: Int, CaseIterable {
        case communication, personal, relationship, copy, destructive
    }

    let id: String
    let title: String
    let systemImage: String
    let group: Group
    var isEnabled = true
    let perform: () -> Void

    /// Reversing a relationship action shares its slot without its warning tint.
    var isDestructive: Bool {
        group == .destructive && !["ignore", "unignore", "unblock"].contains(id)
    }
}

extension AppModel {
    func userMenuActions(for user: User, context: UserMenuContext) -> [UserMenuAction] {
        let session = accountSession()
        let isSelf = user.id == currentUser?.id
        let isLocalIdentity = context.isLocalIdentity || user.isWebhookIdentity || user.isSystem
        let relationship = relationships.first { $0.id == user.id }
        let pending = friends.pendingUserIDs.contains(user.id)
        let location = context.ignoreLocation ?? (context.guildID != nil ? .guildChannel : .contextMenu)
        var actions: [UserMenuAction] = []
        func add(_ id: String, _ title: String, _ symbol: String, _ group: UserMenuAction.Group,
                 enabled: Bool = true, _ perform: @escaping (AppModel) -> Void) {
            actions.append(UserMenuAction(id: id, title: title, systemImage: symbol, group: group, isEnabled: enabled) { [weak self] in
                guard let self, self.isCurrentAccountSession(session) else { return }
                guard enabled else { return }
                if group == .personal || group == .relationship || group == .destructive {
                    guard !self.friends.pendingUserIDs.contains(user.id) else { return }
                }
                if group != .copy {
                    self.dismissExpandedProfile()
                    self.dismissContextualProfile()
                }
                perform(self)
            })
        }

        if !isLocalIdentity {
            add("profile", "Profile", "person.crop.circle", .communication) { model in
                let member = model.userMenuMember(user, context: context)
                model.presentProfile(for: member, in: context.guildID, destination: .expanded)
                model.dismissContextualProfile()
                model.dismissInspectorProfile()
            }
            if !isSelf {
                add("message", "Message", "bubble.left", .communication) { $0.openDirectMessage(with: user) }
            }
            if userMenuMentionDestination(in: context) != nil {
                add("mention", "Mention", "at", .communication) { $0.mentionUserFromMenu(user, context: context) }
            }
            if !isSelf, !user.isBot, relationship?.type != .blocked {
                add("call", "Start a Call", "phone", .communication) { $0.callUserFromMenu(user) }
            }
            for nickname in nicknameMenuActions(for: user, in: context.guildID) {
                add("nickname-\(nickname.title)", nickname.title, nickname.systemImage, .personal, enabled: !pending) { model in
                    model.nicknameMenuActions(for: user, in: context.guildID)
                        .first { $0.title == nickname.title }?.perform()
                }
            }
        }

        if !isSelf, !isLocalIdentity, !user.isBot {
            appendRelationshipMenuActions(for: user, relationship: relationship, pending: pending, location: location, add: add)
        }
        if !isSelf, !isLocalIdentity, relationship?.type != .blocked {
            if relationship?.isIgnored == true {
                add("unignore", "Unignore", "eye", .destructive, enabled: !pending) {
                    $0.setUserIgnored(user, ignored: false, location: location)
                }
            } else {
                add("ignore", "Ignore…", "eye.slash", .destructive, enabled: !pending) { model in
                    guard !model.isUserIgnored(user.id), model.relationships.first(where: { $0.id == user.id })?.type != .blocked else { return }
                    model.friends.confirmation = .ignore(user, location)
                }
            }
        }
        if !user.username.isEmpty {
            add("copy-username", "Copy Username", "doc.on.doc", .copy) { _ in ChannelContextMenuValue.copy(user.tag) }
        }
        add("copy-user-id", "Copy User ID", "number", .copy) { _ in ChannelContextMenuValue.copy(user.id.description) }
        return UserMenuAction.Group.allCases.flatMap { group in
            let grouped = actions.filter { $0.group == group }
            guard group == .destructive else { return grouped }
            let blockIDs: Set = ["block", "unblock"]
            return grouped.filter { !blockIDs.contains($0.id) } + grouped.filter { blockIDs.contains($0.id) }
        }
    }

    private func appendRelationshipMenuActions(
        for user: User, relationship: Relationship?, pending: Bool, location: IgnoreActionLocation,
        add: (String, String, String, UserMenuAction.Group, Bool, @escaping (AppModel) -> Void) -> Void
    ) {
        switch relationship?.type ?? .none {
        case .none, .implicit:
            guard !user.username.isEmpty else { break }
            add("add-friend", "Add Friend", "person.badge.plus", .relationship, !pending) { model in
                let type = model.relationships.first { $0.id == user.id }?.type ?? .none
                guard type == .none || type == .implicit else { return }
                model.sendFriendRequest(to: user, location: location)
            }
        case .incomingRequest:
            if relationship?.note != nil {
                add("view-request", "View Request", "text.bubble", .relationship, true) { model in
                    model.openFriends()
                    model.selectFriendsSection(.pending)
                    model.friends.revealRequest(user.id)
                }
            }
            add("accept", "Accept Friend Request", "checkmark", .relationship, !pending) { model in
                guard model.relationships.first(where: { $0.id == user.id })?.type == .incomingRequest else { return }
                model.acceptFriendRequest(from: user)
            }
            add("decline", "Decline Request", "xmark", .destructive, !pending) { model in
                guard model.relationships.first(where: { $0.id == user.id })?.type == .incomingRequest else { return }
                model.removeRelationship(with: user.id, as: .declineIncomingRequest)
            }
        case .outgoingRequest:
            add("cancel-request", "Cancel Request", "xmark", .destructive, !pending) { model in
                guard model.relationships.first(where: { $0.id == user.id })?.type == .outgoingRequest else { return }
                model.removeRelationship(with: user.id, as: .cancelOutgoingRequest)
            }
        case .friend:
            add("remove-friend", "Remove Friend…", "person.badge.minus", .destructive, !pending) { model in
                guard model.isFriend(user.id) else { return }
                model.friends.confirmation = .removeFriend(user)
            }
        case .blocked:
            break
        }
        if relationship?.type == .blocked {
            add("unblock", "Unblock", "hand.raised.slash", .destructive, !pending) { model in
                guard model.relationships.first(where: { $0.id == user.id })?.type == .blocked else { return }
                model.removeRelationship(with: user.id, as: .unblock)
            }
        } else {
            add("block", "Block…", "hand.raised", .destructive, !pending) { model in
                guard model.relationships.first(where: { $0.id == user.id })?.type != .blocked else { return }
                model.friends.confirmation = .block(user)
            }
        }
    }

    func userMenuMentionDestination(in context: UserMenuContext) -> MessageComposerDestination? {
        guard let channelID = context.channelID else { return nil }
        let destination = commandDestination(in: channelID)
        guard composerSendChannelID(in: destination) == channelID,
              commandContext(for: destination)?.channelID == channelID,
              commandComposer(for: destination).activeCommand == nil else { return nil }
        return destination
    }

    private func userMenuMember(_ user: User, context: UserMenuContext) -> Member {
        if let member = profileMember(user.id, in: context.guildID) { return member }
        var member = Member(user: user, roleName: "", status: .offline)
        if let row = friends.row(for: user.id) {
            member.status = row.presence.status
            member.customStatus = row.presence.customStatus
        }
        return member
    }

    private func mentionUserFromMenu(_ user: User, context: UserMenuContext) {
        guard let destination = userMenuMentionDestination(in: context) else { return }
        rememberMentionMember(userMenuMember(user, context: context))
        let current = destination == .thread ? threadDraft : draft
        let value = current + (current.isEmpty || current.last?.isWhitespace == true ? "" : " ") + "<@\(user.id)> "
        if destination == .thread { updateThreadDraft(value) } else { updateDraft(value) }
        NotificationCenter.default.post(name: .sakuracordFocusComposer, object: destination,
                                        userInfo: ["selection": NSRange(location: value.utf16.count, length: 0)])
    }

    private func callUserFromMenu(_ user: User) {
        guard user.id != currentUser?.id, !user.isBot,
              relationships.first(where: { $0.id == user.id })?.type != .blocked else { return }
        startAccountChildTask(account: accountSession()) { model, session in
            do {
                let channel = try await session.provider.ensurePrivateChannel(for: user.id)
                guard model.isCurrentAccountSession(session) else { return }
                await model.startPrivateCall(in: channel)
            } catch {
                guard model.isCurrentAccountSession(session), !(error is CancellationError) else { return }
                model.errorMessage = error.localizedDescription
            }
        }
    }
}
