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

    func canManageSidebarThread(_ thread: MessageThreadSummary) -> Bool {
        threadActionPolicy(thread).canManage
    }

    func canArchiveSidebarThread(_ thread: MessageThreadSummary) -> Bool {
        let permissions = threadActionPolicy(thread)
        return thread.isArchived ? permissions.canReopen : permissions.canClose
    }

    func setSidebarThreadMute(_ thread: MessageThreadSummary, isMuted: Bool, until: Date?) {
        guard threadActionPolicy(thread).canChangeNotifications else { return }
        setForumPostMute(isMuted, until: until, for: ForumPost(thread: thread), reportErrorInAlert: true)
    }

    func setSidebarThreadNotificationLevel(_ thread: MessageThreadSummary, level: MessageNotificationLevel) {
        guard threadActionPolicy(thread).canChangeNotifications else { return }
        setForumPostNotificationLevel(level, for: ForumPost(thread: thread), reportErrorInAlert: true)
    }

    func setSidebarThreadMembership(_ thread: MessageThreadSummary, isJoined: Bool) {
        guard threadActionPolicy(thread).canChangeMembership else { return }
        startAccountChildTask(account: accountSession()) { model, account in
            guard model.threadActionPolicy(thread).canChangeMembership else { return }
            do {
                try await account.provider.setThreadMembership(
                    threadID: thread.id, isJoined: isJoined, location: .contextMenu
                )
            } catch {
                guard model.isCurrentAccountSession(account) else { return }
                model.errorMessage = error.localizedDescription
            }
        }
    }

    func updateSidebarThread(_ thread: MessageThreadSummary, mutation: ForumPostMutation) {
        switch mutation {
        case .archived(let archived):
            let permissions = threadActionPolicy(thread)
            guard archived ? permissions.canClose : permissions.canReopen else { return }
        case .locked: guard canManageSidebarThread(thread) else { return }
        case .pinned:
            guard canManageSidebarThread(thread),
                  thread.parentID.flatMap({ messagePresentationChannelsByID[$0] })?.kind == .forum else { return }
        case .name: guard threadActionPolicy(thread).canRename else { return }
        case .tags: return
        }
        startAccountChildTask(account: accountSession()) { model, account in
            do {
                let updated = try await account.provider.updateForumPost(ForumPost(thread: thread), mutation: mutation)
                guard model.isCurrentAccountSession(account) else { return }
                if model.openThread?.id == thread.id { model.openThread = updated.thread }
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
            } catch {
                guard model.isCurrentAccountSession(account) else { return }
                model.errorMessage = error.localizedDescription
            }
        }
    }
}
