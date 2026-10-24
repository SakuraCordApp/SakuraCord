import Foundation
import SakuraCordModels

/// A side chat's title and symbol, shared by its pane toolbar, the full-width
/// toolbar and file-drop targets.
struct SideConversationLabel: Equatable {
    let title: String
    let systemImage: String
}

/// What takes an open side chat's place in the trailing column until it
/// closes (`AppModel.sideConversationCover`).
enum SideConversationCover {
    case memberList
    case messageSearch
}

/// Where the open thread's timeline is read, so moving it between the pane
/// and full width reopens it at the same place.
struct ThreadTimelinePosition {
    /// The latest reading position the timeline reported.
    var reading: MessageTimelineScrollRequest.Target?
    /// The position a recreated timeline opens at instead of its default.
    var restore: MessageTimelineScrollRequest.Target?
}

extension AppModel {
    // MARK: - Presentation

    /// The open context side chat, if it still belongs to the visible
    /// workspace. Leaving its page or channel hides it until it is replaced.
    var presentedSideConversationContext: SideConversation? {
        guard let context = sideConversations.context else { return nil }
        switch context {
        case .voiceChat(let channelID):
            guard guildWorkspacePage == nil, selectedChannelID == channelID,
                  selectedChannel?.kind == .voice else { return nil }
        case .channelPreview(let channelID, _):
            guard guildWorkspacePage == .channelsAndRoles, selectedChannelID == channelID,
                  let channel = messagePresentationChannelsByID[channelID], channel.guildID == selectedGuildID
            else { return nil }
        case .guideResource(let guildID, let channelID):
            guard guildWorkspacePage == .guide, selectedGuildID == guildID,
                  guideResource?.channelID == channelID else { return nil }
        case .thread, .threadCreation:
            return nil
        }
        return context
    }

    /// The side chat on top: an open thread, otherwise its context.
    var presentedSideConversation: SideConversation? {
        sideConversations.thread ?? presentedSideConversationContext
    }

    /// The side chat the workspace shows: Members or search results cover
    /// a pane, though not a full-width side chat.
    var visibleSideConversation: SideConversation? {
        sideConversationCover != nil && presentedSideConversation?.isFullWidth != true
            ? nil : presentedSideConversation
    }

    /// The thread the workspace shows, in its pane or at full width; not one
    /// that Members or search results cover.
    var visibleThread: MessageThreadSummary? {
        if case .thread(let thread, _)? = visibleSideConversation { return thread }
        return nil
    }

    var workspacePresentation: WorkspacePresentation {
        makeWorkspacePresentation(sideConversation: visibleSideConversation)
    }

    private func makeWorkspacePresentation(sideConversation: SideConversation?) -> WorkspacePresentation {
        WorkspacePresentation(
            guildPage: selectedGuildID == nil ? nil : guildWorkspacePage,
            isFriendsPresented: isFriendsPresented,
            channelKind: selectedChannel?.kind,
            sideConversation: sideConversation,
            showsMessageSearch: isMessageSearchVisible,
            showsInspector: showInspector
        )
    }

    /// The open thread or forum post. Assigning replaces its summary and keeps
    /// its layout; open and close threads through the entry points below,
    /// which own history and read-state lifetime.
    var openThread: MessageThreadSummary? {
        get {
            if case .thread(let thread, _)? = sideConversations.thread { return thread }
            return nil
        }
        set {
            if let newValue {
                let keepsLayout = openThread?.id == newValue.id
                sideConversations.thread = .thread(newValue, isFullWidth: keepsLayout && isThreadFullWidth)
            } else if openThread != nil {
                sideConversations.thread = nil
            }
        }
    }

    var isThreadFullWidth: Bool { sideConversations.thread?.isFullWidth == true }

    func sideConversationsDidChange() {
        if shortcutThreadIsFullWidth != isThreadFullWidth { shortcutThreadIsFullWidth = isThreadFullWidth }
    }

    /// A thread being composed. It becomes `openThread` once Discord creates it.
    var threadCreation: ThreadCreationDraft? {
        if case .threadCreation(let draft)? = sideConversations.thread { return draft }
        return nil
    }

    /// A thread or thread draft is open, in the pane or at full width.
    var hasThreadPane: Bool { sideConversations.thread != nil }

    var isVoiceChatOpen: Bool {
        if case .voiceChat? = presentedSideConversationContext { return true }
        return false
    }

    var presentedGuideResource: GuildResourceState? {
        guard case .guideResource? = presentedSideConversationContext else { return nil }
        return guideResource
    }

    func guideResource(for channelID: ChannelID) -> GuildResourceState? {
        guideResource?.channelID == channelID ? guideResource : nil
    }

    /// The composer that typing and file drops reach when no pane is targeted.
    var activeComposerDestination: MessageComposerDestination {
        visibleSideConversation?.capabilities.composerDestination ?? .channel
    }

    func sideConversationLabel(_ conversation: SideConversation) -> SideConversationLabel {
        switch conversation {
        case .thread(let thread, _):
            SideConversationLabel(
                title: thread.name,
                systemImage: openThreadParentChannel?.kind == .forum
                    ? "bubble.left.and.bubble.right.fill" : SakuraCordSystemSymbol.thread
            )
        case .threadCreation:
            SideConversationLabel(title: "New Thread", systemImage: SakuraCordSystemSymbol.thread)
        case .voiceChat:
            SideConversationLabel(title: selectedChannel?.name ?? "", systemImage: "bubble.left.fill")
        case .channelPreview(let channelID, _):
            if let channel = messagePresentationChannelsByID[channelID] {
                SideConversationLabel(
                    title: channel.name,
                    systemImage: ChannelIconPresentation.systemImage(
                        for: channel,
                        access: conversationAccess(for: channel),
                        rulesChannelID: selectedGuild?.rulesChannelID
                    )
                )
            } else {
                SideConversationLabel(title: "", systemImage: "number")
            }
        case .guideResource(let guildID, let channelID):
            SideConversationLabel(
                title: onboarding.guides[guildID]?.configuration?.resourceChannels
                    .first { $0.channelID == channelID }?.title ?? "Resource",
                systemImage: "doc.text"
            )
        }
    }

    // MARK: - Opening and closing

    /// Opens a side chat and closes what it replaces. A thread replaces only
    /// the open thread and keeps its context, unless it takes over the
    /// workspace at full width. Any other side chat replaces the context and
    /// the thread above it. Kind-specific entry points prepare the store.
    /// - Parameter preparing: State the side chat needs to be presented,
    ///   set in the same change so it moves in from its first frame.
    func openSideConversation(_ conversation: SideConversation, preparing: () -> Void = {}) {
        func open() {
            sideConversationCover = nil
            closeThread()
            if conversation.isThread {
                if conversation.isFullWidth { discardSideConversationContext() }
                sideConversations.thread = conversation
            } else {
                discardSideConversationContext()
                sideConversations.context = conversation
            }
            preparing()
        }
        // A thread opened straight into full width replaces the workspace,
        // as navigation does, and one side chat replaces another in the same
        // pane; a pane slides in beside its conversation.
        if conversation.isFullWidth || workspacePresentation.paneSideConversation != nil {
            open()
        } else {
            WorkspaceLayoutMotion.perform(in: self, open)
        }
    }

    /// Moves the open pane thread into the primary column.
    func presentOpenThreadFullWidth() {
        guard let thread = openThread else { return }
        threadTimelinePosition.restore = threadTimelinePosition.reading
        WorkspaceLayoutMotion.widen(in: self) {
            discardSideConversationContext()
            sideConversations.thread = .thread(thread, isFullWidth: true)
        }
        guard WorkspaceMotionPhase.shared.widening != nil else {
            suspendSelectedConversationPresentation()
            return
        }
        // The conversation stays beneath the widening thread until it is
        // covered. If the reader returns before then, it was never hidden.
        Task { [weak self] in
            await WorkspaceLayoutMotion.untilSettled()
            guard let self, isThreadFullWidth, openThread?.id == thread.id else { return }
            suspendSelectedConversationPresentation()
        }
    }

    /// The motion categories of opening, closing or widening a side chat. The
    /// member list or search results it takes the place of, or returns, move
    /// too, but only where this page shows one beside a conversation without
    /// the side chat.
    var sideChatMotionCategories: [AppMotionCategory] {
        let withoutSideChat = makeWorkspacePresentation(sideConversation: nil)
        return withoutSideChat.supplementaryPane == nil ? [.sideChats] : [.sideChats, .sidebar]
    }

    /// The motion categories of showing or hiding the member list or search
    /// results: a side chat they take the place of, or return, moves too.
    var inspectorMotionCategories: [AppMotionCategory] {
        workspacePresentation.paneSideConversation != nil || sideConversationCover != nil
            ? [.sidebar, .sideChats] : [.sidebar]
    }

    /// Shows or hides the member list beside the conversation.
    func toggleMemberInspector() {
        prepareInspectorProfileForPresentation()
        // Beside a side chat, which the toolbar keeps the toggle for, the
        // member list takes the side chat's place until it closes again.
        if workspacePresentation.paneSideConversation != nil {
            threadTimelinePosition.restore = threadTimelinePosition.reading
            WorkspaceLayoutMotion.perform(in: self, categories: inspectorMotionCategories) {
                sideConversationCover = .memberList
                showInspector = true
                // Search results the side chat hid would take precedence.
                messageSearch.isPresented = false
            }
            return
        }
        if sideConversationCover == .memberList, showInspector {
            revealCoveredSideConversation()
            return
        }
        WorkspaceLayoutMotion.perform(in: self, categories: inspectorMotionCategories) { showInspector.toggle() }
    }

    /// Shows the side chat Members or search results cover, as opening it
    /// again does.
    func revealCoveredSideConversation() {
        switch sideConversationCover {
        case .memberList:
            WorkspaceLayoutMotion.perform(in: self, categories: inspectorMotionCategories) {
                showInspector = false
                sideConversationCover = nil
            }
        case .messageSearch:
            dismissMessageSearch()
        case nil:
            break
        }
    }

    /// Closes the side chat on top, as Escape and the pane's close button do.
    @discardableResult
    func closeSideConversation() -> Bool {
        // A side chat the member list or search results cover stays until
        // they close.
        let presentation = workspacePresentation
        guard presentation.paneSideConversation != nil || presentation.primary == .fullWidthThread
            || guildWorkspacePage != nil
        else { return false }
        if sideConversations.thread != nil {
            // Leaving a full-width thread returns to its parent, as
            // navigation does; a pane slides away beside its conversation.
            if isThreadFullWidth { dismissOpenThread() } else { WorkspaceLayoutMotion.perform(in: self, dismissOpenThread) }
            return true
        }
        guard presentedSideConversationContext != nil else { return false }
        WorkspaceLayoutMotion.perform(in: self, closeSideConversations)
        return true
    }

    /// Closes every side chat: the thread and the context beneath it.
    func closeSideConversations() {
        closeThread()
        guard let context = sideConversations.context else { return }
        switch context {
        case .voiceChat(let channelID):
            cancelConversationRefresh(in: channelID)
            // Reopening restores this page, as returning to a channel does.
            if hasMoreLaterMessages {
                hasMoreCache[channelID] = nil
            } else {
                storeCachedMessages(messages, for: channelID)
                storeCachedMessageRows(messageRows, for: channelID)
            }
            channelLoadTask?.cancel()
            channelLoadTask = nil
            channelLoadGeneration &+= 1
            sideConversations.context = nil
            isLoadingMessages = false
            isLoadingEarlier = false
            messageLoadError = nil
        case .guideResource:
            discardSideConversationContext()
        case .channelPreview(_, let returnChannelID):
            if guildWorkspacePage == .channelsAndRoles {
                // Reuse the chat machinery without making a preview the main conversation.
                isRestoringPreviewSelection = true
                selectedChannelID = returnChannelID
                isRestoringPreviewSelection = false
            }
            sideConversations.context = nil
            if let selectedChannelID, !isConversationPresented(selectedChannelID) {
                suspendSelectedConversationPresentation()
            }
        case .thread, .threadCreation:
            sideConversations.context = nil
        }
    }

    /// Drops the context without restoring what it replaced, when navigation
    /// or another side chat supersedes it.
    func discardSideConversationContext() {
        if case .guideResource? = sideConversations.context { guideResource = nil }
        sideConversations.context = nil
        if sideConversations.thread == nil { sideConversationCover = nil }
    }

    /// Whether a selection change keeps the presented guild page without
    /// recording navigation: a channel preview borrows the selection, and
    /// clearing a selection that no preview borrowed leaves the page.
    var selectionChangeKeepsGuildPage: Bool {
        let previewChannelID: ChannelID? = if case .channelPreview(let channelID, _)? = sideConversations.context {
            channelID
        } else {
            nil
        }
        return isRestoringPreviewSelection || previewChannelID == selectedChannelID
    }

    /// A new selection closes its threads, and a voice channel opens its text
    /// chat by default. A preview or Guide resource stays while its page does.
    func synchronizeSideConversationsWithSelection(keepsGuildPage: Bool) {
        closeThread()
        switch sideConversations.context {
        case .channelPreview?, .guideResource?:
            if keepsGuildPage { return }
        case .voiceChat?, .thread?, .threadCreation?, nil:
            break
        }
        discardSideConversationContext()
        if selectedChannel?.kind == .voice, let selectedChannelID {
            sideConversations.context = .voiceChat(selectedChannelID)
        }
    }

    // MARK: - Escape

    @discardableResult
    func consumeEscapeForSupplementaryConversation() -> Bool {
        closeSideConversation()
    }

    /// Escape in a conversation timeline dismisses the innermost transient
    /// state, then the side chat, and otherwise finishes reading.
    func handleTimelineEscape(
        in destination: MessageComposerDestination,
        conversationID: ChannelID?
    ) {
        guard !consumeEscapeForMediaViewer() else { return }
        guard !consumeEscapeForPinnedMessages() else { return }
        guard !consumeEscapeForUnfocusedMessageSearch() else { return }
        guard !consumeEscapeForReply(in: destination) else { return }
        guard !consumeEscapeForComposerAttachments(in: destination) else { return }
        guard !consumeEscapeForSupplementaryConversation() else { return }
        if let conversationID {
            completeConversationReadingAndAdvance(channelID: conversationID)
        }
    }
}
