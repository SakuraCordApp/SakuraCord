import DiscordProtocol
import Foundation
import SakuraCordModels

/// A nickname action offered by a user context menu.
struct NicknameMenuAction {
    let title: String
    let systemImage: String
    let perform: () -> Void
}

extension AppModel {
    /// The private nickname the current account gave this friend.
    func friendNickname(for userID: UserID) -> String? {
        relationshipNicknamesByUserID[userID]
    }

    func isFriend(_ userID: UserID) -> Bool {
        friendUserIDs.contains(userID)
    }

    /// Discord's Change Nickname eligibility for another member: Manage
    /// Nicknames over a member whose highest role is below yours.
    func canChangeNickname(of userID: UserID, in guildID: GuildID) -> Bool {
        guard let currentUserID = currentUser?.id, userID != currentUserID,
              let basis = conversationPermissionBasis(for: guildID),
              let member = profileMember(userID, in: guildID), member.joinedAt != nil
        else { return false }
        let context = NicknamePermissionPolicy.Context(
            ownerID: basis.guild.ownerID,
            isOwner: basis.guild.isOwnedByCurrentUser == true,
            permissions: basis.resolvedBasePermissions,
            roleIDs: currentUserRoleIDsByGuild[guildID] ?? Set(profileMember(currentUserID, in: guildID)?.roleIDs ?? []),
            roles: guildRolesByGuildID[guildID] ?? (guildID == selectedGuildID ? guildRoles : []),
            guildID: guildID,
            currentMember: onboardingMember(in: guildID)
        )
        return NicknamePermissionPolicy.canChangeNickname(
            of: userID, roleIDs: Set(member.roleIDs.isEmpty ? member.roles.map(\.id) : member.roleIDs), in: context
        )
    }

    /// Discord's user-menu nickname items for a server (`guildID`) or private
    /// context: the friend nickname, then your per-server profile or another
    /// member's Change Nickname.
    func nicknameMenuActions(for user: User, in guildID: GuildID?) -> [NicknameMenuAction] {
        guard let currentUserID = currentUser?.id, !user.isWebhookIdentity, !user.isSystem else { return [] }
        var actions: [NicknameMenuAction] = []
        if isFriend(user.id) {
            let title = friendNickname(for: user.id) == nil ? "Add Friend Nickname" : "Change Friend Nickname"
            actions.append(NicknameMenuAction(title: title, systemImage: "person.text.rectangle.fill") { [weak self] in
                self?.presentFriendNicknameEditor(for: user, in: guildID)
            })
        }
        if let guildID {
            // Discord's menu subscribes to the target member and excludes
            // missing members, guests and lurkers before canManageUser.
            guard let member = profileMember(user.id, in: guildID) else {
                resolveNicknameMenuMember(user.id, in: guildID)
                return actions
            }
            guard member.joinedAt != nil else { return actions }
        }
        if let guildID, user.id == currentUserID {
            actions.append(NicknameMenuAction(title: "Edit Per-server Profile", systemImage: "person.crop.circle") { [weak self] in
                self?.editServerProfile(in: guildID)
            })
        } else if let guildID, canChangeNickname(of: user.id, in: guildID) {
            actions.append(NicknameMenuAction(title: "Change Nickname", systemImage: "pencil") { [weak self] in
                self?.presentNicknameEditor(for: user, in: guildID)
            })
        }
        return actions
    }

    /// Hydrates a context-menu target through the existing Gateway member path.
    /// A later menu request can then use the same authoritative member store.
    @discardableResult
    func resolveNicknameMenuMember(_ userID: UserID, in guildID: GuildID) -> Task<Void, Never> {
        let key = "\(guildID)-\(userID)"
        let store = nicknameEditor
        if let task = store.memberLoads[key] { return task }
        let task = startAccountChildTask(account: accountSession()) { model, session in
            defer {
                if !Task.isCancelled, model.isCurrentAccountSession(session) { store.memberLoads[key] = nil }
            }
            do {
                let resolved = try await session.provider.resolveMembers(in: guildID, userIDs: [userID])
                guard model.isCurrentAccountSession(session), !Task.isCancelled,
                      model.profileMember(userID, in: guildID) == nil,
                      let member = resolved.first(where: { $0.id == userID }) else { return }
                let merged = MemberStoreMerge.merging(existing: model.membersByGuildID[guildID] ?? [:], updates: [member])
                model.membersByGuildID[guildID] = merged
                if model.selectedGuildID == guildID {
                    let previous = model.membersByID
                    model.membersByID = merged
                    model.publishTimelineMemberPresentationChanges(from: previous, to: merged)
                }
            } catch {
                if !(error is CancellationError), model.isCurrentAccountSession(session) {
                    DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                }
            }
        }
        store.memberLoads[key] = task
        return task
    }

    /// Opens Profiles settings on this server's profile, where your own
    /// server nickname is edited.
    func editServerProfile(in guildID: GuildID) {
        SettingsNavigationRouter.shared.open(page: .profiles, profileScope: .server(guildID))
        nicknameEditor.settingsRequest &+= 1
    }

    func presentNicknameEditor(for user: User, in guildID: GuildID) {
        guard canChangeNickname(of: user.id, in: guildID) else { return }
        let member = profileMember(user.id, in: guildID)
        nicknameEditor.presentation = NicknameEditorStore.Presentation(
            target: .server(guildID),
            user: member?.user ?? user,
            currentNickname: member?.guildNickname.flatMap { $0.isEmpty ? nil : $0 },
            fallbackName: globalName(of: user, member: member)
        )
    }

    func presentFriendNicknameEditor(for user: User, in guildID: GuildID? = nil) {
        guard isFriend(user.id) else { return }
        nicknameEditor.presentation = NicknameEditorStore.Presentation(
            target: .friend,
            user: user,
            currentNickname: friendNickname(for: user.id),
            fallbackName: globalName(of: user, member: profileMember(user.id, in: guildID))
        )
    }

    /// Discord's placeholder: the global display name, never a nickname.
    private func globalName(of user: User, member: Member?) -> String {
        member?.globalDisplayName
            ?? snapshot?.knownUsers.first { $0.id == user.id }?.displayName
            ?? user.displayName
    }

    /// Saves the open dialog once with the text as typed. An unchanged server
    /// nickname closes without a request; Discord's Gateway events publish the
    /// confirmed name, and failures keep the draft for another try.
    func saveNickname(_ presentation: NicknameEditorStore.Presentation) {
        let store = nicknameEditor
        guard store.presentation == presentation, !store.isSaving else { return }
        let value = store.draft
        // Compare with the live nickname: another session may have changed it
        // while the dialog was open.
        if case let .server(guildID) = presentation.target,
           let member = profileMember(presentation.user.id, in: guildID),
           value == (member.guildNickname ?? "") {
            store.presentation = nil
            return
        }
        let revision = store.revision
        store.isSaving = true
        store.error = nil
        startAccountChildTask(account: accountSession()) { model, session in
            do {
                switch presentation.target {
                case let .server(guildID):
                    _ = try await session.provider.setMemberNickname(value, for: presentation.user.id, in: guildID)
                case .friend:
                    _ = try await session.provider.setFriendNickname(value, for: presentation.user.id)
                }
                guard model.isCurrentAccountSession(session), store.revision == revision else { return }
                // Clearing the presentation closes the dialog; its dismissal
                // guard still reflects the save until the next view update.
                store.isSaving = false
                store.presentation = nil
            } catch {
                guard model.isCurrentAccountSession(session), store.revision == revision else { return }
                if !(error is CancellationError) {
                    DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                }
                store.isSaving = false
                store.error = error is CancellationError
                    ? "The nickname change was interrupted. Check the current name before trying again."
                    : error.localizedDescription
            }
        }
    }
}

nonisolated enum NicknamePermissionPolicy {
    /// The current account's standing in one guild.
    struct Context {
        let ownerID: UserID?
        let isOwner: Bool
        let permissions: UInt64?
        let roleIDs: Set<RoleID>
        let roles: [GuildRole]
        var guildID: GuildID?
        var currentMember: Member?
    }

    /// Discord's `canManageUser(MANAGE_NICKNAMES)`: never the owner; the owner
    /// manages everyone else; others, administrators included, need a highest
    /// role above the target's. Missing role records are ignored, as in Discord.
    static func canChangeNickname(
        of targetUserID: UserID, roleIDs targetRoleIDs: Set<RoleID>, in context: Context, now: Date = .now
    ) -> Bool {
        guard targetUserID != context.ownerID else { return false }
        if context.isOwner { return true }
        let permissions = context.permissions ?? 0
        let isAdministrator = permissions & DiscordPermissionBits.administrator != 0
        guard isAdministrator || permissions & DiscordPermissionBits.manageNicknames != 0 else { return false }
        let member = context.currentMember
        let flags = member?.flags ?? 0
        // Discord restricts pending members and guests even with Administrator.
        guard member?.isPending != true, flags & 16 == 0 else { return false }
        // AutoMod quarantine and timeout masks apply only to non-administrators.
        if !isAdministrator {
            guard flags & (128 | 256 | 1024) == 0,
                  member?.communicationDisabledUntil.map({ $0 > now }) != true else { return false }
        }
        return isRole(
            highestRole(context.roleIDs, in: context),
            higherThan: highestRole(targetRoleIDs, in: context),
            guildID: context.guildID
        )
    }

    private static func highestRole(_ roleIDs: Set<RoleID>, in context: Context) -> GuildRole? {
        context.roles.filter { roleIDs.contains($0.id) }.max {
            isRole($1, higherThan: $0, guildID: context.guildID)
        }
    }

    /// Discord places @everyone last, then orders by position and older role ID.
    private static func isRole(_ lhs: GuildRole?, higherThan rhs: GuildRole?, guildID: GuildID?) -> Bool {
        guard let lhs else { return false }
        guard let rhs else { return true }
        if lhs.id.rawValue == guildID?.rawValue { return false }
        if rhs.id.rawValue == guildID?.rawValue { return true }
        if lhs.position != rhs.position { return lhs.position > rhs.position }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}
