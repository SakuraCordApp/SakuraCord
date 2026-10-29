import Foundation
import DiscordProtocol
import SakuraCordModels

extension AppModel {
    func loadThreadMembers(_ thread: MessageThreadSummary) async throws {
        guard openThread?.id == thread.id, openThreadAccess.isReadable, !thread.isArchived else { return }
        let account = accountSession()
        do {
            var request = thread
            request.guildID = thread.guildID ?? openThreadParentChannel?.guildID
            let members = try await account.provider.threadMembers(in: request)
            guard !Task.isCancelled, isCurrentAccountSession(account),
                  openThread?.id == thread.id, openThreadAccess.isReadable else { return }
            if let members { threadMembersByID[thread.id] = members }
        } catch {
            guard isCurrentAccountSession(account) else { throw CancellationError() }
            throw error
        }
    }

    /// Eligibility shared by menu construction and action execution. Thread permissions
    /// inherit from the actual parent, independently of the selected conversation.
    func threadActionPolicy(_ thread: MessageThreadSummary) -> ThreadActionPolicy {
        let thread = sidebarThread(thread.id) ?? thread
        guard let parent = thread.parentID.flatMap({ messagePresentationChannelsByID[$0] }),
              conversationAccess(for: parent).isReadable,
              let permissions = effectiveMessagePermissions(in: parent),
              let currentUserID = currentUser?.id else { return .init() }
        return ThreadActionPolicy(
            thread: thread, currentUserID: currentUserID,
            parentPermissions: permissions, parentKind: parent.kind
        )
    }

    func setThreadMute(_ thread: MessageThreadSummary, isMuted: Bool, until: Date?) {
        guard threadActionPolicy(thread).canChangeNotifications else { return }
        setForumPostMute(isMuted, until: until, for: ForumPost(thread: thread), reportErrorInAlert: true)
    }

    func setThreadNotificationLevel(_ thread: MessageThreadSummary, level: MessageNotificationLevel) {
        guard threadActionPolicy(thread).canChangeNotifications else { return }
        setForumPostNotificationLevel(level, for: ForumPost(thread: thread), reportErrorInAlert: true)
    }

    /// Join (Follow) or Leave (Unfollow). An open thread stays open; the
    /// provider updates the sidebar and catalogue when Discord confirms.
    func setThreadMembership(_ thread: MessageThreadSummary, isJoined: Bool, surface: ThreadActionSurface) {
        guard threadActionPolicy(thread).canChangeMembership else { return }
        startAccountChildTask(account: accountSession()) { model, account in
            guard model.threadActionPolicy(thread).canChangeMembership else { return }
            await model.changeThreadMembership(thread, isJoined: isJoined, location: surface.membershipLocation, account: account)
        }
    }

    /// Failures use the application alert.
    private func changeThreadMembership(
        _ thread: MessageThreadSummary, isJoined: Bool, location: ThreadMembershipLocation, account: AppModelAccountSession
    ) async {
        do {
            try await account.provider.setThreadMembership(threadID: thread.id, isJoined: isJoined, location: location)
        } catch ChatProviderError.threadMemberLimitReached {
            guard isCurrentAccountSession(account) else { return }
            let noun = isForumThread(thread) ? "post" : "thread"
            errorMessage = "Cannot join \(noun). This \(noun) has reached its member limit."
        } catch {
            guard isCurrentAccountSession(account) else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Discord's Mark Unread (E10) first reopens an archived thread, stopping
    /// if that fails, then joins an unjoined one, continuing if that fails.
    func prepareThreadForMarkUnread(_ thread: MessageThreadSummary, account: AppModelAccountSession) async -> Bool {
        if thread.isArchived {
            let post = forumCataloguePosts.first { $0.id == thread.id } ?? ForumPost(thread: thread)
            do {
                let updated = try await account.provider.updateForumPost(post, mutation: .archived(false))
                guard isCurrentAccountSession(account) else { return false }
                reconcileMutatedThread(updated)
            } catch {
                if isCurrentAccountSession(account) { errorMessage = error.localizedDescription }
                return false
            }
        }
        if thread.notificationSettings == nil {
            await changeThreadMembership(thread, isJoined: true, location: .markUnread, account: account)
        }
        return true
    }

    /// Close/Reopen, Lock/Unlock and Pin/Unpin from any thread surface.
    /// Failures use the application alert.
    func updateThread(_ thread: MessageThreadSummary, mutation: ForumPostMutation) {
        let thread = currentThreadSummary(thread)
        let policy = threadActionPolicy(thread)
        switch mutation {
        case .archived(let archived):
            guard archived ? policy.canClose : policy.canReopen else { return }
        case .locked: guard policy.canManage else { return }
        case .pinned: guard policy.canManage, isForumThread(thread) else { return }
        case .name: guard policy.canRename else { return }
        case .tags: return
        }
        let post = forumCataloguePosts.first { $0.id == thread.id } ?? ForumPost(thread: thread)
        startAccountChildTask(account: accountSession()) { model, account in
            do {
                let updated = try await account.provider.updateForumPost(post, mutation: mutation)
                guard model.isCurrentAccountSession(account) else { return }
                model.reconcileMutatedThread(updated)
            } catch {
                guard model.isCurrentAccountSession(account) else { return }
                model.errorMessage = error.localizedDescription
            }
        }
    }

    func deleteSidebarThread(_ thread: MessageThreadSummary) {
        guard threadActionPolicy(thread).canDelete else { return }
        startAccountChildTask(account: accountSession()) { model, account in
            guard model.threadActionPolicy(thread).canDelete else { return }
            do {
                try await account.provider.deleteForumPost(ForumPost(thread: thread))
                guard model.isCurrentAccountSession(account) else { return }
                model.consumeThreadDeleted(channelID: thread.id)
                // A catalogue update published while the post was still open
                // may have kept its card; the deletion is confirmed now.
                model.removeForumPost(thread.id)
            } catch {
                guard model.isCurrentAccountSession(account) else { return }
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

extension AppModel {
    /// The freshest known summary of a thread, for actions started from an
    /// older row or card.
    func currentThreadSummary(_ thread: MessageThreadSummary) -> MessageThreadSummary {
        if openThread?.id == thread.id, let openThread { return openThread }
        if let post = forumCataloguePosts.first(where: { $0.id == thread.id }) { return post.thread }
        return sidebarThread(thread.id) ?? thread
    }

    func isForumThread(_ thread: MessageThreadSummary) -> Bool {
        thread.parentID.flatMap { messagePresentationChannelsByID[$0] }?.kind == .forum
    }

    // MARK: - Rename

    /// Opens Edit Thread / Edit Post when the policy allows renaming.
    func presentThreadRename(_ thread: MessageThreadSummary) {
        let thread = currentThreadSummary(thread)
        guard threadActionPolicy(thread).canRename else { return }
        threadActions.renaming = ThreadActionStore.ThreadPresentation(
            thread: thread, isForumPost: isForumThread(thread)
        )
    }

    /// Saves the open dialog once. An unchanged name closes without a request;
    /// an archived thread is unarchived first by the provider. Failures keep
    /// the draft with Discord's reason.
    func saveThreadRename() {
        let store = threadActions
        guard let presentation = store.renaming, !store.isSaving else { return }
        guard ThreadNamePolicy.validatedName(store.draftName) != nil else {
            store.error = "Enter a name between 1 and \(ThreadNamePolicy.maximumLength) characters."
            return
        }
        guard let name = store.nameToSave else {
            store.renaming = nil
            return
        }
        let thread = currentThreadSummary(presentation.thread)
        guard threadActionPolicy(thread).canRename else {
            store.error = "You no longer have permission to rename this \(presentation.isForumPost ? "post" : "thread")."
            return
        }
        let post = forumCataloguePosts.first { $0.id == thread.id } ?? ForumPost(thread: thread)
        let revision = store.revision
        store.isSaving = true
        store.error = nil
        startAccountChildTask(account: accountSession()) { model, session in
            do {
                let updated = try await session.provider.updateForumPost(post, mutation: .name(name))
                guard model.isCurrentAccountSession(session), store.revision == revision else { return }
                model.reconcileMutatedThread(updated)
                store.isSaving = false
                store.renaming = nil
            } catch {
                guard model.isCurrentAccountSession(session), store.revision == revision else { return }
                store.isSaving = false
                store.error = error is CancellationError
                    ? "The rename was interrupted. Check the name before trying again."
                    : error.localizedDescription
            }
        }
    }

    /// Applies a thread returned by a mutation to the open thread and the
    /// selected forum; the provider's publication updates the other projections.
    func reconcileMutatedThread(_ updated: ForumPost) {
        if openThread?.id == updated.id { openThread = updated.thread }
        if selectedChannelID == updated.thread.parentID, selectedChannel?.kind == .forum {
            mergeForumCatalogue([updated])
            applyForumPresentation()
        }
    }

    // MARK: - Delete

    func requestThreadDeletion(_ thread: MessageThreadSummary) {
        let thread = currentThreadSummary(thread)
        guard threadActionPolicy(thread).canDelete else { return }
        threadActions.deletion = ThreadActionStore.ThreadPresentation(
            thread: thread, isForumPost: isForumThread(thread)
        )
    }

    func confirmThreadDeletion(_ confirmation: ThreadActionStore.ThreadPresentation) {
        threadActions.deletion = nil
        deleteSidebarThread(confirmation.thread)
    }
}
