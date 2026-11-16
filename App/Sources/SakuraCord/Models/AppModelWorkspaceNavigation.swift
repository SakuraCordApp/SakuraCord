import DiscordProtocol
import Foundation
import SakuraCordModels

@MainActor
extension AppModel {
    func presentQuickSwitcher() {
        guard sessionState == .workspace else { return }
        if workspaceNavigationOverlay == .quickSwitcher {
            dismissWorkspaceNavigationOverlay()
            return
        }
        AppPerformanceSignposts.beginQuickSwitcherOpen()
        workspaceNavigationOverlay = .quickSwitcher
    }

    /// Neither server onboarding, a server page nor Friends takes the
    /// conversation's place.
    var showsConversationWorkspace: Bool {
        onboardingEntryGuildID == nil && guildWorkspacePage == nil && !isFriendsPresented
    }

    func dismissWorkspaceNavigationOverlay() {
        if workspaceNavigationOverlay == .quickSwitcher {
            AppPerformanceSignposts.beginQuickSwitcherClose()
        }
        workspaceNavigationOverlay = nil
    }

    func activateQuickSwitcherDestination(_ destination: ConversationDestination) {
        switch destination.kind {
        case .channel(let channel):
            workspaceNavigationOverlay = nil
            navigate(to: channel.id)
        case .thread(let thread, _):
            workspaceNavigationOverlay = nil
            navigate(to: thread.guildID, linkedChannelID: thread.id)
        case .user(let user, let directMessage):
            if let directMessage {
                workspaceNavigationOverlay = nil
                navigate(to: directMessage.id)
                return
            }
            workspaceNavigationOverlay = nil
            openDirectMessage(with: user)
        }
    }

    func navigateToSearchResult(_ message: Message) {
        messageSearch.selectedMessageID = message.id
        guard let result = messageSearch.page?.results.first(where: {
            $0.hit.id == message.id
        }) else { return }
        navigateToMessageSearchResult(result, messageID: message.id)
    }

    func navigateToInboxResult(_ message: Message, messageID: MessageID? = nil) {
        if message.guildID != nil, knownRootChannel(message.channelID) == nil,
           inbox.threads[message.channelID] == nil,
           readState.entries[message.channelID]?.parentID == nil
        {
            resolveInboxThreadThenNavigate(message, messageID: messageID)
            return
        }
        if let guildID = message.guildID, inboxRequiresAgeAgreement(channelID: message.channelID, guildID: guildID) {
            requestInboxAgeAgreement(guildID: guildID) { [weak self] in self?.navigateToInboxResult(message, messageID: messageID) }
            return
        }
        let isThread = inbox.threads[message.channelID] != nil || snapshot?.threads.contains { $0.id == message.channelID } == true
            || snapshot?.activeJoinedThreads.contains { $0.id == message.channelID } == true
        dismissInbox()
        navigateToMessageResult(source: message, messageID: messageID ?? message.id, initialMessages: isThread ? [message] : nil, isKnownThread: isThread)
    }

    /// The age gate and thread presentation need the thread's parent. Resolve
    /// it through the provider now rather than waiting for the background
    /// inbox metadata lookup, and report a failed lookup.
    private func resolveInboxThreadThenNavigate(_ message: Message, messageID: MessageID?) {
        let channelID = message.channelID
        // The same destination the resolved navigation uses, so a repeated
        // selection joins the pending lookup instead of restarting it.
        let target = ConversationNavigationTarget.message(
            channelID, messageID ?? message.id, fullWidthThread: false
        )
        if isNavigating(to: target) { return }
        startConversationNavigation(target: target) { model, session in
            let post: ForumPost
            do {
                post = try await session.provider.forumPost(threadID: channelID)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, model.isCurrentAccountSession(session) else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                model.errorMessage = Self.threadResolutionErrorMessage(error)
                return
            }
            guard !Task.isCancelled, model.isCurrentAccountSession(session) else { return }
            model.inbox.threads[channelID] = post.thread
            // Hand off to the resolved navigation, which shares this target.
            model.conversationNavigationTarget = nil
            model.navigateToInboxResult(message, messageID: messageID)
        }
    }

    func openInboxGroup(_ channelID: ChannelID) {
        guard let group = inbox.groups.first(where: { $0.id == channelID }) else { return }
        if group.isEvents {
            inbox.selectedEvent = group.events.first ?? inbox.scheduledEvents.events.first { $0.guildID == group.guildID }
            return
        }
        if inboxRequiresAgeAgreement(channelID: channelID, guildID: group.guildID), let guildID = group.guildID {
            requestInboxAgeAgreement(guildID: guildID) { [weak self] in self?.openInboxGroup(channelID) }
            return
        }
        if !group.isForum, let message = group.messages.first {
            navigateToInboxResult(message)
        } else {
            dismissInbox()
            navigate(to: group.guildID, linkedChannelID: channelID)
        }
    }

    func navigateToPinnedResult(_ message: Message) {
        navigateToMessageResult(
            source: message,
            messageID: message.id,
            initialMessages: message.channelID == openThread?.id ? [message] : nil,
            isKnownThread: message.channelID == openThread?.id
        )
    }

    func navigateToPinnedReply(_ messageID: MessageID) {
        guard let source = pinnedMessages.items.first(where: {
            $0.message.replyTo == messageID
        })?.message else { return }
        let isKnownThread = source.channelID == openThread?.id
        navigateToMessageResult(
            source: source,
            messageID: messageID,
            initialMessages: isKnownThread ? [source] : nil,
            isKnownThread: isKnownThread
        )
    }

    func navigateToSearchReply(_ messageID: MessageID) {
        guard let result = messageSearch.page?.results.first(where: {
            $0.hit.replyTo == messageID
        })
        else { return }
        navigateToMessageSearchResult(result, messageID: messageID)
    }

    private func navigateToMessageSearchResult(
        _ result: MessageSearchResult,
        messageID: MessageID
    ) {
        let isGuildThreadResult = messageSearch.submittedQuery?.scope.guildID != nil
            && messageSearch.page?.channels.contains(where: {
                $0.id == result.hit.channelID
            }) == true
        navigateToMessageResult(
            source: result.hit,
            messageID: messageID,
            initialMessages: result.messages,
            isKnownThread: isGuildThreadResult,
            fullWidthThread: true
        )
    }

    private func navigateToMessageResult(
        source: Message,
        messageID: MessageID,
        initialMessages: [Message]?,
        isKnownThread: Bool,
        fullWidthThread: Bool = false
    ) {
        let guildID = source.guildID
            ?? snapshot?.channels.first(where: { $0.id == source.channelID })?.guildID
        if isKnownThread {
            navigate(
                to: guildID,
                linkedChannelID: source.channelID,
                messageID: messageID,
                initialMessages: initialMessages ?? [source],
                fullWidthThread: fullWidthThread
            )
        } else {
            navigate(
                to: guildID,
                channelID: source.channelID,
                messageID: messageID
            )
        }
    }
}
