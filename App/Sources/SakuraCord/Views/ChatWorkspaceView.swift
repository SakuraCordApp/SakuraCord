import SakuraCordModels
import SwiftUI

/// Equatable on its inputs: a binding never compares equal, so each update of
/// the window's root view updated the workspace again, and with it every
/// column, mid-motion. What the workspace reads from the model still updates
/// it.
struct ChatWorkspaceView: View, Equatable {
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        MainActor.assumeIsolated {
            lhs.model === rhs.model
                && lhs.presentsForumComposer == rhs.presentsForumComposer
                && lhs.toolbarSearchFieldMetrics == rhs.toolbarSearchFieldMetrics
        }
    }

    let model: AppModel
    @Binding var presentsForumComposer: Bool
    let toolbarSearchFieldMetrics: ToolbarSearchFieldMetrics
    /// The trailing column's frame, reported by `WorkspaceColumnsHost`.
    @State private var supplementaryPaneFrame = CGRect.zero

    @ViewBuilder var body: some View {
        let presentation = model.workspacePresentation
        Group {
            switch presentation.primary {
            case .guildPage(let page):
                if let guildID = model.selectedGuildID {
                    guildWorkspace(page, guildID: guildID, presentation: presentation)
                }
            case .friends:
                FriendsView(model: model)
                    .id("friends-\(model.currentUser?.id.description ?? "")")
            case .channel, .fullWidthThread:
                conversation(presentation)
            }
        }
        .windowModal(
            item: Binding(
                get: { model.interactionModalForm },
                set: {
                    if $0 == nil {
                        model.dismissInteractionModal()
                    }
                }
            ),
            cornerRadius: InterfaceScale.metric(32),
            cornerStyle: .circular
        ) { form in
            InteractionModalView(model: model, form: form)
                .windowModalDismissDisabled(form.isSubmitting)
        }
    }

    private func guildWorkspace(
        _ page: GuildWorkspacePage,
        guildID: GuildID,
        presentation: WorkspacePresentation
    ) -> some View {
        workspaceColumns(presentation) {
            Group {
                switch page {
                case .channelsAndRoles: GuildCustomizationView(model: model, guildID: guildID)
                    .id("customization-\(guildID)-\(model.currentUser?.id.description ?? "")")
                case .guide: GuildGuideView(model: model, guildID: guildID)
                    .id("guide-\(guildID)-\(model.currentUser?.id.description ?? "")")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func conversation(_ presentation: WorkspacePresentation) -> some View {
        let widening = WorkspaceMotionPhase.shared.widening
        let channelContent: WorkspacePresentation.ChannelContent? =
            if case .channel(let content) = presentation.primary { content } else { widening?.channel }
        return workspaceColumns(presentation) {
            if let channelContent {
                ChatWorkspacePrimaryContent(
                    model: model,
                    content: channelContent,
                    presentsForumComposer: $presentsForumComposer
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .workspaceMotionProbe("primary")
            }
        }
        .onChange(of: model.selectedChannelID) { _, channelID in
            guard let channelID else {
                AppPerformanceSignposts.cancelConversationNavigation()
                return
            }
            AppPerformanceSignposts.ensureConversationNavigation(
                to: channelID
            )
        }
    }

    /// The primary content, a side chat (in the pane or at full width) and
    /// the inspector, moved by `WorkspaceLayoutMotion`.
    @ViewBuilder
    private func workspaceColumns(
        _ presentation: WorkspacePresentation,
        @ViewBuilder primary: () -> some View
    ) -> some View {
        let motion = WorkspaceMotionPhase.shared
        // A thread keeps one view, and its timeline, between the pane and
        // full width.
        let fullWidthThread = presentation.primary == .fullWidthThread
            ? model.sideConversations.thread.map { WorkspaceTrailingColumn(.sideConversation($0)) }
            : nil
        let trailing = WorkspaceTrailingColumn(presentation)
        // The column host keeps departing columns itself while they leave, so
        // a motion updates no view after the change that starts it.
        let columns = [fullWidthThread, trailing].compactMap(\.self)
        WorkspaceColumnsHost(
            conversation: AnyView(primary()),
            columns: columns.map { column in
                let isSideConversation = if case .sideConversation = column.content { true } else { false }
                return WorkspaceColumnsHost.Column(
                    id: column.id,
                    isSideConversation: isSideConversation,
                    isFullWidth: column.id == fullWidthThread?.id,
                    content: AnyView(columnContent(column))
                )
            },
            widening: fullWidthThread == nil || motion.widening == nil
                ? nil : motion.wideningHasArrived ? .arriving : .starting,
            supplementaryPaneFrameChanged: { supplementaryPaneFrame = $0 }
        )
        // Spans the window's top edge so the columns scroll under the
        // toolbar; each column's hosting view insets its own content from it.
        .ignoresSafeArea(.container, edges: .top)
        .preference(key: SupplementaryPaneFramePreferenceKey.self, value: supplementaryPaneFrame)
    }

    /// A trailing column as `WorkspaceColumnsHost` hosts it.
    @ViewBuilder
    private func columnContent(_ column: WorkspaceTrailingColumn) -> some View {
        switch column.content {
        case .sideConversation(let conversation):
            SideConversationView(model: model, conversation: conversation)
                .workspaceMotionProbe("pane")
                .reportsSupplementaryPaneFrame(isEnabled: !conversation.isFullWidth)
        case .inspector(let pane):
            ChatWorkspaceSupplementaryContent(
                model: model,
                pane: pane,
                toolbarSearchFieldMetrics: toolbarSearchFieldMetrics
            )
            .workspaceMotionProbe(column.id)
        }
    }
}

private struct ChatWorkspacePrimaryContent: View {
    let model: AppModel
    let content: WorkspacePresentation.ChannelContent
    @Binding var presentsForumComposer: Bool

    var body: some View {
        switch content {
        case .chat:
            if let channel = model.selectedChannel,
               channel.kind == .directMessage || channel.kind == .groupDirectMessage,
               model.privateCall(in: channel.id) != nil
                    || model.activeVoiceChannel?.id == channel.id
            {
                DirectMessageCallWorkspace(model: model, channel: channel)
                    .background {
                        nonTimelineFrameReporter(channel.id)
                    }
            } else {
                ChatDetailView(model: model)
            }
        case .forum:
            ForumChannelView(model: model, presentsComposer: $presentsForumComposer)
                .background {
                    if let channelID = model.selectedChannelID {
                        nonTimelineFrameReporter(channelID)
                    }
                }
        case .voice:
            VoiceChannelView(model: model)
                .background {
                    if let channelID = model.selectedChannelID {
                        nonTimelineFrameReporter(channelID)
                    }
                }
        }
    }

    private func nonTimelineFrameReporter(
        _ channelID: ChannelID
    ) -> some View {
        DisplayCompleteFrameReporter(
            presentationID: channelID.rawValue
        ) {
            guard model.selectedChannelID == channelID else { return }
            AppPerformanceSignposts.reportNonTimelineWorkspaceFrame()
            AppPerformanceSignposts.reportConversationFirstFrame(
                channelID: channelID
            )
        }
        .frame(width: 1, height: 1)
    }
}

private struct ChatWorkspaceSupplementaryContent: View {
    let model: AppModel
    let pane: SupplementaryPane
    let toolbarSearchFieldMetrics: ToolbarSearchFieldMetrics

    var body: some View {
        switch pane {
        case .sideConversation(let conversation):
            SideConversationView(model: model, conversation: conversation)
        case .memberInspector:
            HStack(spacing: 0) {
                if model.selectedChannel?.kind != .directMessage {
                    Divider()
                        .ignoresSafeArea(.container, edges: .top)
                }
                memberInspector
            }
        case .messageSearch:
            HStack(spacing: 0) {
                Divider()
                    .ignoresSafeArea(.container, edges: .top)
                if toolbarSearchFieldMetrics.isValid {
                    MessageSearchPanelView(model: model)
                        .id(ObjectIdentifier(model.messageSearch))
                        .frame(width: ChatChromeMetrics.memberListWidth)
                        .frame(maxHeight: .infinity)
                        .reportsSupplementaryPaneFrame()
                }
            }
        }
    }

    @ViewBuilder private var memberInspector: some View {
        let userContext = UserMenuContext(guildID: model.selectedGuildID, channelID: model.selectedChannelID)
        if model.isThreadFullWidth, let thread = model.openThread,
           model.openThreadParentChannel?.kind != .announcement {
            ThreadMemberInspectorView(model: model, thread: thread)
                .frame(width: ChatChromeMetrics.memberListWidth)
                .frame(maxHeight: .infinity)
        } else if let channel = model.selectedChannel,
           channel.kind == .directMessage,
           let recipient = channel.recipients.first
        {
            DirectMessageProfileInspector(
                model: model,
                recipient: recipient
            )
        } else {
            MemberInspectorView(
                sections: model.directMessageInspectorSections,
                customEmojiURLsByID: model.customEmojiURLsByID,
                profilePresentation:
                    model.liveProfilePresentation(for: .inspector),
                isProfilePresented: model.isInspectorProfilePresented,
                selectMember: model.selectMember,
                dismissProfile: model.dismissInspectorProfile,
                viewportIdentity: model.selectedChannelID,
                presentation: NativeMemberListPresentation(
                    roleColorDisplay: model.accessibilitySettings.roleColorDisplay
                ),
                openProfile: model.expandProfile,
                sendProfileMessage: model.sendProfileMessage,
                userMenu: { UserContextMenu.make(for: $0.user, context: userContext, model: model) },
                userAccessibilityActions: { UserContextMenu.accessibilityActions(for: $0.user, context: userContext, model: model) },
                updateViewport: model.updateMemberListViewport
            )
            .frame(width: ChatChromeMetrics.memberListWidth)
            .frame(maxHeight: .infinity)
        }
    }
}

private struct DirectMessageProfileInspector: View {
    let model: AppModel
    let recipient: User

    var body: some View {
        Group {
            if let presentation = model.liveProfilePresentation(for: .inspector),
               presentation.member.id == recipient.id
            {
                ProfilePresentationContent(
                    presentation: presentation,
                    layout: .inspector,
                    openProfile: model.expandProfile,
                    userMenu: { UserContextMenu.make(for: presentation.member.user, context: .init(guildID: presentation.guildID), model: model) }
                )
            } else {
                ProgressView("Loading profile…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: ChatChromeMetrics.memberListWidth)
        .frame(maxHeight: .infinity)
        .clipShape(
            ConcentricRectangle(
                corners: .concentric(
                    minimum: .fixed(
                        ChatChromeMetrics.composerMinimumCornerRadius
                    )
                ),
                isUniform: true
            )
        )
        .task(id: [recipient.id, model.inspectorProfilePresentation?.member.id]) {
            if model.inspectorProfilePresentation?.member.id != recipient.id {
                model.showInspectorProfile(for: recipient)
            }
        }
    }
}
