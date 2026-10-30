import AppKit
import Combine
import SakuraCordModels
import SwiftUI

struct RootView: View {
    let model: AppModel
    @State private var toolbarSearchFieldMetrics = ToolbarSearchFieldMetrics.zero
    @State private var automaticSearchFocusGuard = AutomaticSearchFocusGuard()

    /// Toolbar search focus is the reader's unless a switch armed the guard
    /// and no input of theirs preceded it; their focus disarms the guard.
    private func acceptsToolbarSearchFocus() -> Bool {
        guard automaticSearchFocusGuard.isArmed else { return true }
        if automaticSearchFocusGuard.focusFollowsReaderInput {
            automaticSearchFocusGuard.disarm()
            return true
        }
        automaticSearchFocusGuard.releaseToolbarSearchFieldFocus()
        return false
    }
    var body: some View {
        @Bindable var model = model
        @Bindable var search = model.messageSearch
        Group {
            switch model.sessionState {
            case .workspace:
                ChatRootView(
                    model: model,
                    toolbarSearchFieldMetrics: toolbarSearchFieldMetrics
                )
                .modifier(FriendsActionPresentation(model: model))
                .windowModal(
                    item: Binding(
                        get: { model.issueReports.presentation },
                        set: { if $0 == nil { model.issueReports.dismiss() } }
                    ),
                    cornerRadius: InterfaceScale.metric(32),
                    cornerStyle: .circular
                ) { _ in
                    IssueReportView(model: model)
                }
            case .signedOut:
                if model.launchMode == .normal || model.includesOfflineSignIn {
                    if model.savedAccounts.isEmpty {
                        DiscordLoginView(
                            showsCancel: false,
                            networkingEnabled: !model.isDiscordNetworkingDisabled,
                            offlineSignIn: model.includesOfflineSignIn,
                            playsWelcome: model.hasPendingLaunchWelcome,
                            showsOnboarding: showsInitialOnboarding,
                            onEntranceStarted: { model.hasPendingLaunchWelcome = false },
                            onOnboardingCompleted: {
                                if model.launchMode == .normal {
                                    SakuraCordOnboardingStore.complete()
                                }
                            },
                            onConnected: { credential in
                                if model.includesOfflineSignIn {
                                    return await model.completeOfflineSignIn()
                                }
                                return await model.connectPendingAuthenticatedAccount(
                                    credential,
                                    preservesInteractivePresentation: true
                                )
                                    ? nil
                                    : (model.errorMessage ?? "Discord account bootstrap failed for an unknown reason.")
                            }
                        )
                        .interfaceScaleRoot()
                    } else {
                        AccountSwitcherView(model: model, showsCancel: false)
                            .interfaceScaleRoot()
                    }
                } else {
                    SakuraCordSessionLoadingView(
                        state: model.sessionState,
                        isOfflineTesting: model.isOfflineTesting
                    )
                }
            case .restoring:
                // Credentials have not resolved yet; the destination may be
                // sign-in, so do not expose chat skeletons or toolbar chrome.
                SakuraCordSignInBackdrop()
                    .ignoresSafeArea()
                    .frame(
                        minWidth: InterfaceScale.windowLength(860, axis: .horizontal),
                        minHeight: InterfaceScale.windowLength(600, axis: .vertical)
                    )
                    .toolbar(removing: .title)
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            case .connecting:
                SakuraCordSessionLoadingView(
                    state: model.sessionState,
                    isOfflineTesting: model.isOfflineTesting,
                    isAccountSwitch: model.isSwitchingAccounts
                )
            }
        }
        .modifier(HumanCaptchaPresentation(store: model.captcha))
        .modifier(MessageSearchExperienceModifier(
            model: model,
            search: search,
            isEnabled: showsMessageSearchToolbar,
            prompt: messageSearchPrompt,
            toolbarMetrics: toolbarSearchFieldMetrics
        ))
        .background {
            ZStack {
                MessageSearchToolbarBridge(
                    model: model,
                    isVisible: showsMessageSearchToolbar || model.showsLocalToolbarSearch
                        || model.keepsMessageSearchFieldInPlace,
                    metrics: $toolbarSearchFieldMetrics
                )
                ToolbarSearchFieldLoadingStyler(isActive: showsSessionLoadingChrome)
            }
            .frame(width: 0, height: 0)
        }
        .onChange(of: model.isSwitchingAccounts) { _, isSwitching in
            if isSwitching {
                search.isFilterModalPresented = false
                model.dismissMessageSearch()
                automaticSearchFocusGuard.arm()
            }
        }
        // Focus the reader did not give the toolbar search field after a switch
        // is released, closing the suggestions it would open.
        .onChange(of: search.isInputFocused) { _, isFocused in
            if isFocused, !acceptsToolbarSearchFocus() { search.isInputFocused = false }
        }
        .onChange(of: model.friends.isSearchFocused) { _, isFocused in
            if isFocused, !acceptsToolbarSearchFocus() { model.friends.isSearchFocused = false }
        }
        .onChange(of: model.onboarding.isChannelSearchFocused) { _, isFocused in
            if isFocused, !acceptsToolbarSearchFocus() { model.onboarding.isChannelSearchFocused = false }
        }
        // System-message actions such as Edit Group are drawn in the accent
        // color, which depends on the whole committed theme.
        .onChange(of: SakuraCordThemeStore.shared.committedTheme) { _, _ in
            model.invalidateTimelinePresentation()
        }
        .onChange(of: model.sessionState) { _, state in
            if model.launchMode == .normal,
               state == .workspace || !model.savedAccounts.isEmpty {
                SakuraCordOnboardingStore.complete()
            }
        }
        .onChange(of: model.showInspector) { _, isVisible in
            if !isVisible, model.selectedChannel?.kind != .directMessage {
                model.dismissInspectorProfile()
            }
            GeneralWindowRestorationStore.shared.recordMemberListVisibility(
                isVisible
            )
        }
        .onChange(of: model.selectedChannelID) { _, _ in
            guard let activeAccountID = model.activeAccountID,
                  let selectedChannel = model.selectedChannel
            else { return }
            SettingsConversationRestorationStore.shared.record(
                accountID: activeAccountID,
                guildID: selectedChannel.guildID?.description,
                channelID: selectedChannel.id.description
            )
        }
        .environment(\.profileCosmeticPolicy, model.cosmeticPolicy)
        .environment(\.serverTagCardModel, model)
        .environment(\.roleColorDisplay, model.accessibilitySettings.roleColorDisplay)
        .modifier(SakuraCordWindowBackground(opacity: model.appearanceSettings.windowOpacity))
    }

    private var showsInitialOnboarding: Bool {
        model.hasPendingLaunchWelcome
            && (model.includesOfflineSignIn
                || (model.launchMode == .normal && SakuraCordOnboardingStore.needsThemeSetup))
    }

    private var showsMessageSearchToolbar: Bool {
        switch model.sessionState {
        case .restoring:
            false
        case .connecting:
            true
        case .workspace:
            model.showsWorkspaceMessageSearch
        case .signedOut:
            model.launchMode != .normal && !model.includesOfflineSignIn
        }
    }

    private var messageSearchPrompt: Text {
        Text(showsSessionLoadingChrome ? "" : model.isFriendsSearchActive ? "Search"
            : (model.isBrowsingGuildChannels ? "Search Channels" : model.messageSearchPromptTitle))
    }

    private var showsSessionLoadingChrome: Bool {
        switch model.sessionState {
        case .restoring:
            false
        case .connecting:
            true
        case .workspace:
            model.isSwitchingAccounts
        case .signedOut:
            model.launchMode != .normal && !model.includesOfflineSignIn
        }
    }
}

private struct ChatRootView: View {
    @Environment(\.windowModalInputAllowed) private var modalInputAllowed
    let model: AppModel
    let toolbarSearchFieldMetrics: ToolbarSearchFieldMetrics
    @State private var showAccountSwitcher = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var supplementaryPaneFrame = CGRect.zero
    /// Measured width the pane's toolbar actions reserve after the title,
    /// keyed by action count. It does not depend on the title's width.
    @State private var sideConversationActionReserve: [Int: CGFloat] = [:]
    /// Advances when the detail column's leading edge moves the
    /// customization switch in or out of the toolbar.
    @State private var customizationPickerRevision = 0
    @State private var conversationTitleWidth: CGFloat = 0
    @State private var customizationModePickerWidth: CGFloat = 260
    /// Where the workspace and the detail column start in the window.
    @State private var columnEdges = ColumnEdges()
    @State private var sidebarWidth = ChatChromeMetrics.serverRailWidth + InterfaceScale.metric(230)
    @State private var presentsForumComposer = false
    @State private var isFileDropTargeted = false
    @State private var isInstantUpload = false
    @State private var hoveredFileDropDestination: MessageComposerDestination?
    @State private var fileDropWatchdogTask: Task<Void, Never>?
    @State private var composerDropInteraction = ComposerDropInteractionState()

    @ViewBuilder private var workspace: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            HStack(spacing: 0) {
                ServerRailContainer(model: model, sidebarWidth: sidebarWidth)
                .environment(\.reducesSidebarMotion, !model.animates(.sidebar))
                .zIndex(200)
                ChannelSidebarView(
                    voiceModel: model,
                    guild: selectedGuild,
                    channels: model.visibleChannels,
                    channelGroups: model.visibleChannelGroups,
                    unreadCategoryIDs: selectedGuild.map {
                        model.unreadCategoryIDsByGuild[$0.id] ?? []
                    } ?? [],
                    selection: $model.channelSidebarSelection,
                    currentUser: model.currentUser,
                    connectionState: model.connectionState,
                    currentStatus: model.currentStatus,
                    isAuthenticated: model.isAuthenticated,
                    isOfflineTesting: model.isOfflineTesting,
                    activeVoiceChannelID: model.activeVoiceChannel?.id,
                    connectAccount: {
                        if !model.isOfflineTesting {
                            showAccountSwitcher = true
                        }
                    },
                    updateStatus: { await model.updateStatus($0) }
                )
            }
            .background {
                NativeSidebarAnimation(snaps: !model.animates(.sidebar)).frame(width: 0, height: 0)
            }
            // Column content follows the interface size; the window toolbar
            // is system chrome and keeps its native item sizing.
            .interfaceScaleRoot()
            .opacity(model.isSwitchingAccounts ? 0 : 1)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                guard width.isFinite, width > ChatChromeMetrics.serverRailWidth else { return }
                sidebarWidth = width
            }
            .navigationSplitViewColumnWidth(
                min: ChatChromeMetrics.serverRailWidth + InterfaceScale.metric(190),
                ideal: ChatChromeMetrics.serverRailWidth + InterfaceScale.metric(230),
                max: ChatChromeMetrics.serverRailWidth + InterfaceScale.metric(310)
            )
        } detail: {
            Group {
                if model.isSwitchingAccounts {
                    Color.clear
                } else if let guildID = model.onboardingEntryGuildID {
                    GuildOnboardingView(model: model, guildID: guildID)
                        .id(guildID)
                } else {
                    ChatWorkspaceView(
                        model: model,
                        presentsForumComposer: $presentsForumComposer,
                        toolbarSearchFieldMetrics: toolbarSearchFieldMetrics
                    )
                    .equatable()
                }
            }
            .interfaceScaleRoot()
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .global).minX
            } action: { minX in
                let showedPicker = showsCustomizationModePicker
                columnEdges.detailMinX = minX
                if showsCustomizationModePicker != showedPicker { customizationPickerRevision &+= 1 }
            }
            .background {
                // Measures the conversation title outside the toolbar, whose
                // item may be narrower than the title while it lays out.
                if let title = conversationToolbarPresentation, model.guildWorkspacePage == .channelsAndRoles {
                    ConversationToolbarTitle(presentation: title)
                        .buttonStyle(.plain)
                        .fixedSize()
                        .hidden()
                        .accessibilityHidden(true)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.width
                        } action: { width in
                            conversationTitleWidth = width
                        }
                }
            }
            .navigationTitle("")
            .toolbar {
                detailToolbar
            }
            .background {
                if usesWorkspaceTitlebar {
                    WorkspaceTitlebar(
                        groups: workspaceTitlebarGroups,
                        showsSearch: model.showsWorkspaceMessageSearch || model.showsLocalToolbarSearch
                    )
                        .frame(width: 0, height: 0)
                }
            }
        }
        .toolbar {
            if model.onboardingEntryGuildID != nil {
                ToolbarItem(placement: .navigation) {
                    ConversationToolbarTitle(presentation: .init(title: "Server Onboarding", systemImage: "sparkles"))
                        .buttonStyle(.plain)
                }
            } else {
                conversationToolbar
            }
        }
        .environment(\.composerDropInteraction, composerDropInteraction)
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                SakuraCordTextInputAccentBridge()
                .frame(width: 0, height: 0)

                if columnVisibility != .detailOnly {
                    if model.isSwitchingAccounts {
                        SkeletonShimmerTimeline {
                            SkeletonShape(cornerRadius: InterfaceScale.metric(4))
                                .frame(width: InterfaceScale.metric(132), height: InterfaceScale.metric(14))
                        }
                        .offset(
                            x: ChatChromeMetrics.sidebarTitleLeadingOffset,
                            y: ChatChromeMetrics.sidebarTitleTopOffset(height: InterfaceScale.metric(14))
                        )
                    } else {
                        Text(sidebarDisplayName)
                            .font(.interfaceSystem(
                                size: InterfaceTypographyMetrics.interfaceTextSize + 2,
                                weight: .semibold
                            ))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: InterfaceScale.metric(150), height: InterfaceScale.metric(28), alignment: .leading)
                            .offset(
                                x: ChatChromeMetrics.sidebarTitleLeadingOffset,
                                y: ChatChromeMetrics.sidebarTitleTopOffset(height: InterfaceScale.metric(28))
                            )
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .background {
            IncomingPrivateCallWindowOverlay(model: model).frame(width: 0, height: 0)
        }
        .overlay {
            if model.isSwitchingAccounts {
                SakuraCordSessionLoadingView(
                    state: .connecting,
                    isOfflineTesting: false,
                    isAccountSwitch: true,
                    isEmbeddedInWorkspace: true,
                    embeddedSidebarWidth: sidebarWidth
                )
                .zIndex(1_000)
            }
        }
        .background {
            ZStack {
                WindowActivityReader { isActive in
                    model.reportMainWindowActive(isActive)
                }
                WindowChromeDimmingBridge(isDimmed: showsFileDropEffect)
            }
            .frame(width: 0, height: 0)
        }
        .background {
            MediaViewerWindowOverlay(
                presentation: model.mediaViewerPresentation,
                dismiss: { model.mediaViewerPresentation = nil },
                selectionChanged: { model.mediaViewerSelectedItemID = $0 }
            )
            .frame(width: 0, height: 0)
        }
        .modifier(ExpandedProfilePresentationModifier(model: model))
        .modifier(NicknameEditorPresentationModifier(model: model))
        .modifier(EditGroupPresentationModifier(model: model))
        .modifier(LeaveGroupPresentationModifier(model: model))
        .modifier(ThreadActionPresentationModifier(model: model))
        .modifier(ProfileGamePresentationModifier(model: model))
        .background {
            CommunicationWindowOverlays(model: model)
                .frame(width: 0, height: 0)
        }
        .background {
            WindowModalOverlay(
                presentation: model.workspaceNavigationOverlay,
                preloadedPresentation: .quickSwitcher,
                behavior: { presentation in
                    presentation == .quickSwitcher ? .instantKeyboardOwned : .standard
                },
                dismiss: model.dismissWorkspaceNavigationOverlay,
                content: { presentation, animationState in
                WorkspaceNavigationOverlayView(
                    model: model,
                    presentation: presentation,
                    animationState: animationState
                )
            })
            .frame(width: 0, height: 0)
        }
        .background {
            DisplayCompleteFrameReporter(
                presentationID: model.selectedChannelID?.rawValue
            ) {
                guard model.selectedChannelID == nil else { return }
                AppPerformanceSignposts.reportNonTimelineWorkspaceFrame()
            }
            .frame(width: 1, height: 1)
        }
        .background {
            if presentsForumComposer,
               let channel = model.selectedChannel,
               channel.kind == .forum
            {
                ForumPostComposerOverlay(
                    model: model,
                    channel: channel,
                    isPresented: $presentsForumComposer
                )
                .frame(width: 0, height: 0)
            }
        }
        .overlay {
            if showsFileDropEffect {
                ComposerFileDropOverlay(
                    model: model,
                    workspaceMinX: columnEdges.workspaceMinX,
                    supplementaryPaneFrame: supplementaryPaneFrame,
                    hoveredDestination: effectiveFileDropDestination,
                    isInstantUpload: effectiveInstantUpload
                )
                .interfaceScaleRoot()
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.22), value: showsFileDropEffect)
    }

    var body: some View {
        @Bindable var model = model
        workspace
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .global).minX
        } action: { minX in
            columnEdges.workspaceMinX = minX
        }
        .overlay { fileDropBridge }
        .onChange(of: showsFileDropEffect) { _, isShown in
            // Driven by the combined state, not per-target callbacks: during a
            // handoff the next target lights up before the previous one exits.
            if isShown {
                if fileDropWatchdogTask == nil { startFileDropWatchdog() }
            } else {
                fileDropWatchdogTask?.cancel()
                fileDropWatchdogTask = nil
            }
        }
        .onPreferenceChange(SupplementaryPaneFramePreferenceKey.self) { frame in
            supplementaryPaneFrame = frame
        }
        .onChange(of: hasOpenSupplementaryConversation) { _, isOpen in
            if !isOpen {
                supplementaryPaneFrame = .zero
            }
        }
        .onChange(of: showsInboxToolbarItem) { _, isShown in
            if !isShown { model.dismissInbox() }
        }
        .onChange(of: model.openThread?.id) { _, threadID in
            if threadID != nil {
                model.dismissPinnedMessages()
            }
        }
        .onChange(of: model.selectedChannelID) { _, channelID in
            presentsForumComposer = false
            model.mediaViewerPresentation = nil
            if model.selectedChannel?.kind == .voice {
                model.dismissPinnedMessages()
            }
            AppPerformanceSignposts.expectStartupConversation(channelID)
        }
        .onAppear {
            AppPerformanceSignposts.expectStartupConversation(
                model.selectedChannelID
            )
        }
        .onDisappear {
            fileDropWatchdogTask?.cancel()
            fileDropWatchdogTask = nil
            model.mediaViewerPresentation = nil
        }
        .sheet(isPresented: $showAccountSwitcher) {
            AccountSwitcherView(
                model: model,
                showsCancel: true,
                accountActivated: { showAccountSwitcher = false }
            )
            .interfaceScaleRoot()
        }
        .background {
            AttachmentPromptPresenter(model: model)
        }
        .overlay {
            if model.externalAttachmentUploadPresentation != nil || model.attachmentCompactionPresentation != nil {
                let upload = model.externalAttachmentUploadPresentation
                let compaction = model.attachmentCompactionPresentation
                ZStack {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                    VStack(spacing: InterfaceScale.metric(14)) {
                        ProgressView()
                            .controlSize(.large)
                        Text(upload.map { "Uploading to \($0.service.displayName)…" } ?? "Compressing file…")
                            .font(.interface(.headline))
                        Text(upload?.fileName ?? compaction?.fileURL.lastPathComponent ?? "")
                            .font(.interface(.callout))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("Cancel", role: .cancel) {
                            if compaction != nil { model.cancelAttachmentCompaction() } else { model.cancelExternalAttachmentUpload() }
                        }
                    }
                    .padding(InterfaceScale.metric(24))
                    .frame(minWidth: InterfaceScale.metric(280))
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: InterfaceScale.metric(16)))
                    .shadow(radius: InterfaceScale.metric(18))
                }
                .interfaceScaleRoot()
            }
        }
        .alert("Whoa there. Way too spicy!", isPresented: $model.isSendQueueFullAlertPresented) {
            Button("Enter the chill zone") {}
        } message: {
            Text("You’re sending messages too quickly!")
        }
        .alert("SakuraCord", isPresented: Binding(get: { model.errorMessage != nil }, set: {
            if !$0 {
                model.dismissError()
            }
        })) {
            Button("OK") { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .sakuracordToggleChannelSidebar
            )
        ) { _ in
            withAnimation(
                model.animates(.sidebar) ? .spring(ChatChromeMetrics.sidebarSpring) : nil
            ) {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sakuracordNotificationDeepLink)) { notification in
            guard let link = notification.object as? NotificationDeepLink else { return }
            Task { await model.navigate(from: link) }
        }
    }

    private func startFileDropWatchdog() {
        fileDropWatchdogTask?.cancel()
        fileDropWatchdogTask = Task { @MainActor in
            while !Task.isCancelled {
                // Native destinations send periodic updates even during a
                // stationary or button-free drag. Ordinary pointer movement
                // cannot keep a finished session alive.
                let idle = ContinuousClock.now - composerDropInteraction.lastDragActivity
                if idle > .seconds(1) {
                    resetFileDropState()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func resetFileDropState() {
        fileDropWatchdogTask?.cancel()
        fileDropWatchdogTask = nil
        isFileDropTargeted = false
        isInstantUpload = false
        hoveredFileDropDestination = nil
        composerDropInteraction.reset()
    }

    @ToolbarContentBuilder
    private var conversationToolbar: some ToolbarContent {
        if !usesWorkspaceTitlebar {
            nativeConversationToolbar
        }
    }

    @ToolbarContentBuilder
    private var nativeConversationToolbar: some ToolbarContent {
        ToolbarItem(id: "conversation-title", placement: .navigation) {
            if model.isSwitchingAccounts {
                SkeletonShimmerTimeline {
                    HStack(spacing: 8) {
                        SkeletonShape(cornerRadius: 4)
                            .frame(width: 16, height: 16)
                        SkeletonShape(cornerRadius: 4)
                            .frame(width: 112, height: 13)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                }
            } else if let title = conversationToolbarPresentation {
                ConversationToolbarTitle(presentation: title)
                    .buttonStyle(.plain)
                    // Remeasure changed text without replacing the toolbar item.
                    .id(title.title)
                    .transition(.identity)
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
            }
        }
        .visibilityPriority(.high)

        ToolbarSpacer(.fixed, placement: .navigation)

        if !model.isSwitchingAccounts {
            if model.isFriendsPresented {
                FriendsToolbarSections(model: model)
            }
        }
    }

    /// A conversation and the side chats beside it own their toolbar items
    /// (`WorkspaceTitlebar`), which move with their columns.
    private var usesWorkspaceTitlebar: Bool {
        guard !model.isSwitchingAccounts, model.onboardingEntryGuildID == nil,
              model.guildWorkspacePage == nil, !model.isFriendsPresented
        else { return false }
        return switch model.workspacePresentation.primary {
        case .channel, .fullWidthThread: true
        case .guildPage, .friends: false
        }
    }

    private var workspaceTitlebarGroups: [WorkspaceTitlebar.Group] {
        let presentation = model.workspacePresentation
        let motion = WorkspaceMotionPhase.shared
        var groups: [WorkspaceTitlebar.Group] = []
        // The conversation, beneath a full-width side chat too, so its items
        // are ready when the side chat leaves; covered, its panels open
        // from the side chat's copies of its buttons.
        let isCovered = presentation.primary == .fullWidthThread && motion.widening == nil
        if let title = channelToolbarPresentation {
            groups.append(.init(
                id: WorkspaceTitlebar.conversationID,
                title: AnyView(
                    ConversationToolbarTitle(presentation: title)
                        .buttonStyle(TitlebarGlassButtonStyle(isTitle: true))
                ),
                actions: AnyView(conversationTitlebarActions(presentsPanels: !isCovered))
            ))
        }
        let fullWidth = presentation.primary == .fullWidthThread ? model.sideConversations.thread : nil
        let current = [fullWidth, presentation.paneSideConversation].compactMap(\.self)
        // The toolbar keeps a leaving side chat's items itself while its
        // column slides away (`WorkspaceTitlebarView.apply`).
        for conversation in current {
            var fullWidthActions: AnyView?
            if case .thread(let thread, _) = conversation {
                // Hidden until the thread is full width; only then, past the
                // widening crossfade, do its buttons open panels.
                fullWidthActions = AnyView(fullWidthTitlebarActions(thread, presentsPanels: isCovered && conversation == fullWidth))
            }
            groups.append(.init(
                id: WorkspaceTrailingColumn(.sideConversation(conversation)).id,
                title: AnyView(
                    SideConversationTitlebarTitle(label: model.sideConversationLabel(conversation))
                        .workspaceMotionProbe("toolbarTitle")
                ),
                actions: AnyView(SideConversationToolbarActions(model: model, conversation: conversation)),
                fullWidthActions: fullWidthActions
            ))
        }
        return groups
    }

    /// The conversation's actions, which stay beside it whatever opens.
    private func conversationTitlebarActions(presentsPanels: Bool) -> some View {
        let pinsChannelID = model.selectedChannelSupportsPins ? model.selectedChannelID : nil
        let offersThreads = model.canBrowseThreadsInSelectedChannel
        // A narrow conversation keeps Members and gathers the rest into "»".
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: ChatChromeMetrics.toolbarItemEdgeInset) {
                conversationCallActions
                InboxToolbarButton(model: model, presentsPanel: presentsPanels)
                if let pinsChannelID {
                    PinnedMessagesToolbarButton(model: model, channelID: pinsChannelID, presentsPanel: presentsPanels)
                }
                if offersThreads {
                    ThreadsToolbarButton(model: model, presentsPanel: presentsPanels)
                }
                if selectedVoiceChannel == nil {
                    MemberInspectorToolbarButton(model: model)
                }
            }
            HStack(spacing: ChatChromeMetrics.toolbarItemEdgeInset) {
                conversationCallActions
                ConversationOverflowToolbarMenu(
                    model: model,
                    pinsChannelID: pinsChannelID,
                    offersThreads: offersThreads,
                    presentsPanels: presentsPanels
                )
                if selectedVoiceChannel == nil {
                    MemberInspectorToolbarButton(model: model)
                }
            }
        }
        .titlebarButtons()
    }

    /// A DM's or group DM's call buttons, or a voice channel's Open Chat.
    @ViewBuilder
    private var conversationCallActions: some View {
        if let channel = selectedPrivateChannel {
            privateCallButtons(channel)
        } else if let channel = selectedVoiceChannel, !model.isVoiceChatOpen {
            openVoiceChatButton(channel)
        }
    }

    @ViewBuilder
    private func privateCallButtons(_ channel: Channel) -> some View {
        Button {
            Task {
                if model.joinablePrivateCall(in: channel.id) != nil {
                    await model.joinPrivateCall(in: channel)
                } else {
                    await model.startPrivateCall(in: channel)
                }
            }
        } label: {
            Label(
                model.joinablePrivateCall(in: channel.id) == nil
                    ? "Start Voice Call" : "Join Voice Call",
                systemImage: "phone.fill"
            )
        }
        .disabled(
            model.activeVoiceChannel?.id == channel.id
                || model.isPrivateCallActionInFlight(in: channel.id)
        )
        .help(
            model.joinablePrivateCall(in: channel.id) == nil
                ? "Start Voice Call" : "Join Ongoing Call"
        )

        Button {
            Task {
                if model.joinablePrivateCall(in: channel.id) != nil {
                    await model.joinPrivateCall(in: channel, withVideo: true)
                } else {
                    await model.startPrivateCall(in: channel, withVideo: true)
                }
            }
        } label: {
            Label("Start Video Call", systemImage: "video.fill")
        }
        .disabled(
            model.activeVoiceChannel?.id == channel.id
                || model.isPrivateCallActionInFlight(in: channel.id)
        )
        .help(
            model.joinablePrivateCall(in: channel.id) == nil
                ? "Start Video Call" : "Join Ongoing Call with Video"
        )
    }

    private func openVoiceChatButton(_ channel: Channel) -> some View {
        Button { model.openVoiceChat(for: channel) } label: {
            Label("Open Chat", systemImage: "bubble.left.fill")
        }
        .help("Open voice channel chat")
    }

    /// A full-width thread's actions, which replace its pane actions as it
    /// widens.
    private func fullWidthTitlebarActions(_ thread: MessageThreadSummary, presentsPanels: Bool) -> some View {
        HStack(spacing: ChatChromeMetrics.toolbarItemEdgeInset) {
            if ForumPostFollowToolbarButton.isOffered(model: model, thread: thread) {
                ForumPostFollowToolbarButton(model: model, thread: thread, surface: .forumPostHeader)
            }
            InboxToolbarButton(model: model, presentsPanel: presentsPanels)
            PinnedMessagesToolbarButton(model: model, channelID: thread.id, presentsPanel: presentsPanels)
            MemberInspectorToolbarButton(model: model)
            ThreadActionsToolbarMenu(model: model, thread: thread, surface: .fullView)
        }
        .titlebarButtons()
    }

    private var showsThreadsToolbarItem: Bool {
        model.guildWorkspacePage == nil && model.onboardingEntryGuildID == nil
            && !model.isThreadFullWidth && model.canBrowseThreadsInSelectedChannel
    }

    @ToolbarContentBuilder
    private var threadsToolbarItem: some ToolbarContent {
        ToolbarItem(id: "threads") {
            Button(action: model.toggleThreadBrowser) {
                Label {
                    Text("Threads")
                } icon: {
                    SakuraCordSystemSymbol.swiftUIImage(named: SakuraCordSystemSymbol.thread)
                }
            }
            .help("Threads")
            .background {
                StableAnchoredPopoverPresenter(
                    isPresented: model.threadBrowser.isPresented,
                    configuration: .toolbarPanel,
                    onDismiss: model.dismissThreadBrowser,
                    onWillDismiss: model.dismissThreadBrowser
                ) { ThreadBrowserPopoverView(model: model) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .visibilityPriority(.high)
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        if usesWorkspaceTitlebar {
            ToolbarSpacer(.flexible)
            if model.showsWorkspaceMessageSearch || model.showsLocalToolbarSearch {
                ToolbarSpacer(.fixed)
            }
        } else {
            nativeDetailToolbar
        }
    }

    @ToolbarContentBuilder
    private var nativeDetailToolbar: some ToolbarContent {
        ToolbarSpacer(.flexible)

        if showsCustomizationModePicker {
            // In the toolbar's centre, as before side chats. It keeps its
            // label, which the overflow menu shows.
            ToolbarItem(id: "customization-mode", placement: .principal) {
                Picker("Channels & Roles", selection: Binding(
                    get: { model.isBrowsingGuildChannels },
                    set: { model.showGuildCustomizationChannels($0) }
                )) {
                    Text("Customize").tag(false)
                    Text("Browse Channels").tag(true)
                }
                .pickerStyle(.segmented)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    if width > 0 { customizationModePickerWidth = width }
                }
            }
            .visibilityPriority(.low)
        }

        if !model.isSwitchingAccounts {
            if let channel = selectedPrivateChannel {
                ToolbarItemGroup { privateCallButtons(channel) }
                    .visibilityPriority(.high)
            } else if model.guildWorkspacePage == nil, model.onboardingEntryGuildID == nil, let channel = selectedVoiceChannel, !model.isVoiceChatOpen {
                ToolbarItem { openVoiceChatButton(channel) }
                    .visibilityPriority(.high)
            }

            if model.isThreadFullWidth, let thread = model.openThread {
                if ForumPostFollowToolbarButton.isOffered(model: model, thread: thread) {
                    ToolbarItem {
                        ForumPostFollowToolbarButton(model: model, thread: thread, surface: .forumPostHeader)
                    }
                    ToolbarSpacer(.fixed)
                }
            }

            if showsInboxToolbarItem {
                if hasToolbarActionBeforeInbox {
                    ToolbarSpacer(.fixed)
                }

                ToolbarItem(id: "inbox") {
                    Button {
                        if model.inbox.isPresented { model.dismissInbox() } else { model.presentInbox() }
                    } label: {
                        Label("Inbox", systemImage: model.inbox.isPresented ? "tray.fill" : "tray")
                            .symbolVariant(.none)
                            .animation(.smooth(duration: 0.24), value: model.inbox.isPresented)
                    }
                    .help("Inbox")
                    .background {
                        StableAnchoredPopoverPresenter(
                            isPresented: model.inbox.isPresented,
                            configuration: .toolbarPanel,
                            onDismiss: model.dismissInbox,
                            onWillDismiss: model.dismissInbox
                        ) { InboxPopoverView(model: model) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .visibilityPriority(.high)
            }

            if let pinsChannelID = toolbarPinsChannelID {
                ToolbarSpacer(.fixed)

                ToolbarItem(id: "pinned-messages") {
                    Button {
                        if model.pinnedMessages.isPresented {
                            model.dismissPinnedMessages()
                        } else {
                            model.presentPinnedMessages(channelID: pinsChannelID)
                        }
                    } label: {
                        Label("Pinned Messages", systemImage: model.pinnedMessages.isPresented ? "pin.fill" : "pin")
                            .symbolVariant(.none)
                            .animation(.smooth(duration: 0.24), value: model.pinnedMessages.isPresented)
                    }
                    .help("Pinned Messages")
                    .background {
                        StableAnchoredPopoverPresenter(
                            isPresented: model.pinnedMessages.isPresented,
                            configuration: .toolbarPanel,
                            onDismiss: model.dismissPinnedMessages,
                            onWillDismiss: model.dismissPinnedMessages
                        ) {
                            PinnedMessagesPopoverView(model: model)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .visibilityPriority(.high)
            }

            if showsThreadsToolbarItem {
                ToolbarSpacer(.fixed)
                threadsToolbarItem
            }

            if let conversation = model.workspacePresentation.paneSideConversation {
                sideConversationToolbar(conversation)
            }
        }

        if showsMemberInspectorToolbarItem {
            if !model.isSwitchingAccounts {
                ToolbarSpacer(.fixed)
            }

            // A stable identity lets the toolbar keep the item when a side
            // chat closes instead of inserting a new one.
            ToolbarItem(id: "member-inspector") {
                ZStack {
                    Button {
                        model.toggleMemberInspector()
                    } label: {
                        inspectorToolbarLabel
                    }
                    .disabled(model.isSwitchingAccounts)
                    .opacity(model.isSwitchingAccounts ? 0 : 1)

                    if model.isSwitchingAccounts {
                        SkeletonShimmerTimeline {
                            SkeletonShape(cornerRadius: 6)
                                .frame(width: 20, height: 20)
                        }
                        .accessibilityHidden(true)
                    }
                }
            }
            .visibilityPriority(.high)

            fullWidthThreadActions

            ToolbarSpacer(.fixed)
                .contentMarginsRemoved(true)
        } else {
            fullWidthThreadActions
        }

        if model.showsWorkspaceMessageSearch || model.showsLocalToolbarSearch {
            // Search's own flexible space is hidden (see the search bridge);
            // keep the trailing actions their usual distance from the field.
            ToolbarSpacer(.fixed)
        }
    }

    private var sidebarDisplayName: String {
        guard let guild = selectedGuild else { return "Messages" }
        return guild.name.isEmpty ? "Unnamed Server" : guild.name
    }

    private var fileDropBridge: some View {
            ComposerFileDropBridge(
                isEnabled: canAcceptWindowDrops,
                targetChanged: { targeted, location, instant in
                    if targeted { composerDropInteraction.noteDragActivity() }
                    let destination = targeted ? composerDestination(at: location) : nil
                    isFileDropTargeted = destination != nil
                    isInstantUpload = destination != nil && instant
                    hoveredFileDropDestination = destination
                },
                receiveURLs: { urls, location, instant in
                    guard canAcceptWindowDrops,
                          let destination = composerDestination(at: location)
                    else { return false }
                    Task {
                        await model.receiveComposerAttachments(
                            .external(urls),
                            to: destination,
                            sendingImmediately: instant
                        )
                    }
                    return true
                },
                receiveFiles: { batch, location, instant in
                    guard let destination = composerDestination(at: location) else {
                        batch.discard()
                        return
                    }
                    Task {
                        await model.receiveComposerAttachments(
                            .owned(batch),
                            to: destination,
                            sendingImmediately: instant
                        )
                    }
                }
            )
    }

    private var canAcceptWindowDrops: Bool {
        modalInputAllowed
            && model.onboardingEntryGuildID == nil
            && model.guildWorkspacePage == nil
            && !presentsForumComposer
            && !showAccountSwitcher
            && model.interactionModalForm == nil
            && (model.isComposerDropEligible(.channel)
                || model.isComposerDropEligible(.thread))
    }

    private func composerDestination(at location: CGPoint) -> MessageComposerDestination? {
        let proposed = proposedComposerDestination(atX: location.x)
        return model.isComposerDropEligible(proposed) ? proposed : nil
    }

    private var showsFileDropEffect: Bool {
        canAcceptWindowDrops
            && (isFileDropTargeted || composerDropInteraction.isTargeted)
    }

    private var effectiveFileDropDestination: MessageComposerDestination? {
        composerDropInteraction.destination ?? hoveredFileDropDestination
    }

    private var effectiveInstantUpload: Bool {
        composerDropInteraction.isTargeted
            ? composerDropInteraction.isInstant
            : isInstantUpload
    }

    private func proposedComposerDestination(atX horizontalPosition: CGFloat) -> MessageComposerDestination {
        let presentation = model.workspacePresentation
        // A full-width thread is the only visible composer.
        if presentation.primary == .fullWidthThread { return .thread }
        if presentation.paneSideConversation?.isThread == true, supplementaryPaneFrame != .zero {
            let localThreadLeadingEdge = supplementaryPaneFrame.minX - (columnEdges.workspaceMinX ?? 0)
            return horizontalPosition >= localThreadLeadingEdge ? .thread : .channel
        }
        return .channel
    }

    private func channelToolbarSymbol(_ channel: Channel) -> String {
        ChannelIconPresentation.systemImage(
            for: channel,
            access: model.conversationAccess(for: channel),
            rulesChannelID: selectedGuild?.rulesChannelID
        )
    }

    private var isDirectMessageSelected: Bool {
        guard let channel = model.selectedChannel else { return false }
        return channel.kind == .directMessage || channel.kind == .groupDirectMessage
    }

    private var inspectorToolbarLabel: some View {
        Label(
            isDirectMessageSelected ? "People" : "Members",
            systemImage: model.selectedChannel?.kind == .directMessage
                ? (model.showInspector ? "person.fill" : "person")
                : (model.showInspector ? "person.2.fill" : "person.2")
        )
        .symbolVariant(.none)
        .animation(.smooth(duration: 0.24), value: model.showInspector)
    }

    private var selectedPrivateChannel: Channel? {
        guard let channel = model.selectedChannel,
              channel.kind == .directMessage || channel.kind == .groupDirectMessage,
              !channel.isOfficialSystemDirectMessage
        else { return nil }
        return channel
    }

    private func directMessageToolbarSubtitle(for channel: Channel) -> String? {
        switch channel.kind {
        case .directMessage:
            return channel.recipients.first.map { "@\($0.username)" }
        case .groupDirectMessage:
            let memberCount = model.directMessageInspectorSections.reduce(0) {
                $0 + $1.members.count
            }
            return "\(memberCount) members"
        default:
            return nil
        }
    }

    private func directMessageToolbarStatus(for channel: Channel) -> PresenceStatus? {
        guard channel.kind == .directMessage else { return nil }
        return directMessageRecipient(for: channel)?.status ?? .offline
    }

    private func directMessageRecipient(for channel: Channel) -> Member? {
        DirectMessageInboxPolicy.recipientMember(
            for: channel,
            membersByID: model.membersByID
        )
    }

    private func channelTopic(for channel: Channel) -> String? {
        guard let topic = channel.topic?.trimmingCharacters(in: .whitespacesAndNewlines),
              !topic.isEmpty
        else { return nil }
        return topic
    }

    /// The trailing column holds a side chat or message search.
    private var hasOpenSupplementaryConversation: Bool {
        switch model.workspacePresentation.supplementaryPane {
        case .sideConversation, .messageSearch: true
        case .memberInspector, nil: false
        }
    }

    private var selectedVoiceChannel: Channel? {
        guard model.selectedChannel?.kind == .voice else { return nil }
        return model.selectedChannel
    }

    private var showsMemberInspectorToolbarItem: Bool {
        model.isSwitchingAccounts
            || (model.guildWorkspacePage == nil && model.onboardingEntryGuildID == nil && !model.isFriendsPresented
                && model.workspacePresentation.paneSideConversation == nil && selectedVoiceChannel == nil)
    }

    /// A full-width thread's actions end the trailing button group, as a
    /// toolbar's overflow item does.
    @ToolbarContentBuilder
    private var fullWidthThreadActions: some ToolbarContent {
        if !model.isSwitchingAccounts, model.isThreadFullWidth, let thread = model.openThread {
            ToolbarSpacer(.fixed)
            ToolbarItem(id: "full-width-thread-actions") {
                ThreadActionsToolbarMenu(model: model, thread: thread, surface: .fullView)
            }
            .visibilityPriority(.high)
        }
    }

    private var hasToolbarActionBeforeInbox: Bool {
        selectedPrivateChannel != nil
            || (selectedVoiceChannel != nil && !model.isVoiceChatOpen)
    }

    private var toolbarPinsChannelID: ChannelID? {
        guard model.guildWorkspacePage == nil, model.onboardingEntryGuildID == nil,
              selectedVoiceChannel == nil, model.workspacePresentation.paneSideConversation == nil
        else { return nil }
        return model.activePinsChannelID
    }

    private var conversationToolbarPresentation: ConversationToolbarPresentation? {
        if let conversation = model.presentedSideConversation, conversation.isFullWidth {
            // One line with the thread symbol for threads and forum posts
            // alike, as before side chats were unified.
            let label = model.sideConversationLabel(conversation)
            return .init(title: label.title, systemImage: SakuraCordSystemSymbol.thread)
        }
        if let page = model.guildWorkspacePage {
            return .init(title: page == .guide ? "Server Guide" : model.customizationTitle(in: model.selectedGuildID),
                         systemImage: page == .guide ? "signpost.right" : "slider.horizontal.3")
        }
        if model.isFriendsPresented { return .init(title: "Friends", systemImage: "person.2.fill") }
        return channelToolbarPresentation
    }

    /// The selected channel's title, which the conversation's toolbar shows
    /// even while a full-width side chat covers it.
    private var channelToolbarPresentation: ConversationToolbarPresentation? {
        guard let channel = model.selectedChannel else { return nil }
        return .init(title: channel.name, systemImage: channelToolbarSymbol(channel),
                     subtitle: isDirectMessageSelected ? directMessageToolbarSubtitle(for: channel) : nil,
                     topic: isDirectMessageSelected ? nil : channelTopic(for: channel),
                     avatarChannel: isDirectMessageSelected ? channel : nil,
                     avatarStatus: isDirectMessageSelected ? directMessageToolbarStatus(for: channel) : nil,
                     avatarIsMobile: isDirectMessageSelected && directMessageRecipient(for: channel)?.showsMobileIndicator == true)
    }

    @ToolbarContentBuilder
    private func sideConversationToolbar(_ conversation: SideConversation) -> some ToolbarContent {
        let label = model.sideConversationLabel(conversation)
        let capabilities = conversation.capabilities
        let showsAddToChannelList = capabilities.canAddToChannelList
            && model.customizationPreviewChannel.map { !model.isChannelSelected($0) } == true
        let paneThread = conversation.isThread ? model.openThread : nil
        let showsFollow = paneThread.map { ForumPostFollowToolbarButton.isOffered(model: model, thread: $0) } ?? false
        let actionCount = 1 + (showsAddToChannelList ? 1 : 0) + (paneThread != nil ? 1 : 0) + (showsFollow ? 1 : 0)
        if showsInboxToolbarItem {
            // Keep the primary column's last action inset from the pane edge.
            ToolbarSpacer(.fixed)
            ToolbarSpacer(.fixed)
        }

        ToolbarItem(id: "side-conversation-title") {
            SideConversationToolbarTitle(label: label, width: sideConversationTitleWidth(actionCount: actionCount))
                .workspaceMotionProbe("toolbarTitle")
                // Remeasure changed text without replacing the toolbar item.
                .id(label.title)
                .transition(.identity)
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .global).maxX
                } action: { trailingEdge in
                    recordSideConversationActionReserve(titleTrailingEdge: trailingEdge, actionCount: actionCount)
                }
        }
        .sharedBackgroundVisibility(.hidden)
        .visibilityPriority(.high)

        // The same separation as other distinct toolbar groups.
        ToolbarSpacer(.fixed)

        if showsAddToChannelList, let channel = model.customizationPreviewChannel, let guildID = channel.guildID {
            ToolbarItem(id: "side-conversation-add") {
                Button("Add to Channel List", systemImage: "plus") {
                    model.setChannelSelected(true, channelID: channel.id, guildID: guildID)
                }
                .labelStyle(.iconOnly)
                .help("Add to Channel List")
            }
            .visibilityPriority(.high)
        }

        if let paneThread {
            if showsFollow {
                ToolbarItem(id: "side-conversation-follow") {
                    ForumPostFollowToolbarButton(model: model, thread: paneThread, surface: .forumPostHeader)
                }
            }
            ToolbarItem(id: "side-conversation-thread-actions") {
                ThreadActionsToolbarMenu(model: model, thread: paneThread, surface: .sidePane)
            }
        }

        ToolbarItem(id: "side-conversation-close") {
            Button {
                model.closeSideConversation()
            } label: {
                Label("Close conversation", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .help(capabilities.closeHelp)
            .keyboardShortcut(model.guildWorkspacePage == .guide ? .cancelAction : nil)
        }
        .visibilityPriority(.high)
    }

    /// The pane title spans from the pane's leading inset to its actions, so
    /// neither title length nor window width moves it. Its width depends only
    /// on the pane's width and the actions' measured reserve, which a resize
    /// or title change cannot invalidate.
    private func sideConversationTitleWidth(actionCount: Int) -> CGFloat? {
        guard supplementaryPaneFrame != .zero else { return nil }
        let reserve = sideConversationActionReserve[actionCount]
            ?? Self.defaultSideConversationActionReserve(actionCount)
        return max(0, supplementaryPaneFrame.width - ChatChromeMetrics.toolbarItemEdgeInset - reserve)
    }

    private func recordSideConversationActionReserve(titleTrailingEdge: CGFloat, actionCount: Int) {
        guard supplementaryPaneFrame != .zero, titleTrailingEdge.isFinite else { return }
        let reserve = supplementaryPaneFrame.maxX - titleTrailingEdge
        // An item in the overflow menu reports no meaningful frame. The
        // reserve does not depend on the title width, so this cannot loop.
        guard abs(reserve - Self.defaultSideConversationActionReserve(actionCount)) < 24,
              abs(reserve - (sideConversationActionReserve[actionCount] ?? -1)) > 0.1
        else { return }
        sideConversationActionReserve[actionCount] = reserve
    }

    private static func defaultSideConversationActionReserve(_ actionCount: Int) -> CGFloat {
        ChatChromeMetrics.toolbarItemEdgeInset
            + ChatChromeMetrics.toolbarTitleActionSpacing
            + CGFloat(actionCount) * ChatChromeMetrics.toolbarIconButtonWidth
    }

    /// Customize and Browse Channels switch the Channels & Roles page. Beside
    /// a channel preview the primary column may be too narrow for the switch;
    /// it leaves the toolbar then, rather than pushing the preview's title
    /// and actions out of the pane.
    private var showsCustomizationModePicker: Bool {
        guard !model.isSwitchingAccounts, model.guildWorkspacePage == .channelsAndRoles,
              model.featuresSettings.channelManagement,
              let guildID = model.selectedGuildID, model.hasCustomizationQuestions(in: guildID)
        else { return false }
        guard model.workspacePresentation.paneSideConversation != nil, supplementaryPaneFrame != .zero else {
            return true
        }
        let inset = ChatChromeMetrics.toolbarItemEdgeInset
        // The title, then the switch and its gap to the pane, each with the
        // toolbar's margins.
        let required = inset + conversationTitleWidth + inset * 2 + customizationModePickerWidth + inset * 3
        _ = customizationPickerRevision
        return supplementaryPaneFrame.minX - columnEdges.detailMinX >= required
    }

    /// Inbox belongs beside a conversation, not on a server's own pages or
    /// Friends.
    private var showsInboxToolbarItem: Bool {
        !model.isSwitchingAccounts && model.onboardingEntryGuildID == nil
            && model.guildWorkspacePage == nil && !model.isFriendsPresented
    }

    private var selectedGuild: Guild? {
        model.selectedGuild
    }
}

struct DisplayCompleteFrameReporter: NSViewRepresentable {
    let presentationID: UInt64?
    let report: @MainActor () -> Void

    func makeNSView(context: Context) -> DisplayCompleteFrameReportingView {
        DisplayCompleteFrameReportingView(
            presentationID: presentationID,
            report: report
        )
    }

    func updateNSView(
        _ nsView: DisplayCompleteFrameReportingView,
        context: Context
    ) {
        nsView.update(
            presentationID: presentationID,
            report: report
        )
    }
}

final class DisplayCompleteFrameReportingView: NSView {
    private var presentationID: UInt64?
    private var report: @MainActor () -> Void
    private var didReport = false

    init(
        presentationID: UInt64?,
        report: @escaping @MainActor () -> Void
    ) {
        self.presentationID = presentationID
        self.report = report
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard window != nil, !didReport else { return }
        didReport = true
        Task { @MainActor [report] in
            await Task.yield()
            report()
        }
    }

    func update(
        presentationID: UInt64?,
        report: @escaping @MainActor () -> Void
    ) {
        self.report = report
        guard self.presentationID != presentationID else { return }
        self.presentationID = presentationID
        didReport = false
        needsDisplay = true
    }
}

private struct MessageSearchExperienceModifier: ViewModifier {
    let model: AppModel
    let search: MessageSearchState
    let isEnabled: Bool
    let prompt: Text
    let toolbarMetrics: ToolbarSearchFieldMetrics

    func body(content: Content) -> some View {
        content
            .modifier(MessageSearchToolbarModifier(
                model: model,
                search: search,
                prompt: prompt
            ))
            .overlay(alignment: .topTrailing) {
                if isEnabled, search.isInputFocused, toolbarMetrics.isValid {
                    MessageSearchAutocompleteView(
                        model: model,
                        width: toolbarMetrics.fieldWidth
                    )
                    .padding(.trailing, toolbarMetrics.trailingInset)
                    .zIndex(100_000)
                }
            }
            .onChange(of: isEnabled) { wasVisible, isVisible in
                guard wasVisible, !isVisible else { return }
                search.isFilterModalPresented = false
                search.isInputFocused = false
            }
    }
}

private struct MessageSearchToolbarBridge: View {
    let model: AppModel
    let isVisible: Bool
    @Binding var metrics: ToolbarSearchFieldMetrics

    var body: some View {
        @Bindable var model = model
        @Bindable var search = model.messageSearch
        @Bindable var onboarding = model.onboarding
        @Bindable var friends = model.friends
        let friendsSearch = model.isFriendsSearchActive
        let local = friendsSearch || model.isBrowsingGuildChannels
        ToolbarSearchFieldGeometryReader(
            searchText: friendsSearch ? $model.friendsSearchText : local ? $onboarding.channelSearch : $model.messageSearchInputText,
            searchTokens: local ? .constant([]) : $search.tokens,
            isSearchFocused: friendsSearch ? $friends.isSearchFocused
                : local ? $onboarding.isChannelSearchFocused : $search.isInputFocused,
            isToolbarItemVisible: isVisible,
            preferredFieldWidth: ChatChromeMetrics.toolbarSearchMaximumFieldWidth,
            didUseBuiltInClear: {
                if friendsSearch {
                    model.friendsSearchText = ""
                } else if local {
                    onboarding.channelSearch = ""
                } else {
                    model.clearMessageSearchUsingBuiltInButton()
                }
            },
            didEndEditing: {
                if friendsSearch {
                    friends.isSearchFocused = false
                } else if local {
                    onboarding.isChannelSearchFocused = false
                } else {
                    model.messageSearchEditingDidEnd()
                }
            },
            pasteCanonicalSyntax: { value in
                if local { return .init(tokens: [], text: value) }
                return MessageSearchTokenParser.parse(
                    value,
                    users: model.messageSearchUsers,
                    channels: model.messageSearchChannels
                )
            },
            changed: { metrics = $0 }
        )
    }
}

private struct MessageSearchToolbarModifier: ViewModifier {
    let model: AppModel
    let search: MessageSearchState
    let prompt: Text

    func body(content: Content) -> some View {
        @Bindable var model = model
        @Bindable var search = search
        @Bindable var onboarding = model.onboarding
        @Bindable var friends = model.friends
        let friendsSearch = model.isFriendsSearchActive
        let local = friendsSearch || model.isBrowsingGuildChannels
        content
            .searchable(
                text: friendsSearch ? $model.friendsSearchText : local ? $onboarding.channelSearch : $model.messageSearchInputText,
                tokens: local ? .constant([]) : $search.tokens,
                isPresented: friendsSearch ? $friends.isSearchFocused
                    : local ? $onboarding.isChannelSearchFocused : $search.isInputFocused,
                placement: .toolbar,
                prompt: prompt
            ) { token in
                Text(token.title)
            }
            .onSubmit(of: .search) {
                if !local { model.submitMessageSearchInput() }
            }
    }
}

/// Where the workspace and the detail column start in the window. Their
/// leading edges move on every frame the sidebar shows or hides; held
/// unobserved, those frames update no view. Views read them where they
/// use them.
@MainActor
private final class ColumnEdges {
    var workspaceMinX: CGFloat?
    var detailMinX: CGFloat = 0
}

private struct ComposerFileDropOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: AppModel
    let workspaceMinX: CGFloat?
    let supplementaryPaneFrame: CGRect
    let hoveredDestination: MessageComposerDestination?
    let isInstantUpload: Bool

    var body: some View {
        GeometryReader { proxy in
            let presentation = model.workspacePresentation
            Group {
                if presentation.primary == .fullWidthThread, let thread = model.sideConversations.thread {
                    destinationZone(.thread, label: model.sideConversationLabel(thread))
                } else if let thread = presentation.paneSideConversation, thread.isThread,
                          supplementaryPaneFrame != .zero
                {
                    HStack(spacing: 0) {
                        destinationZone(.channel, label: channelLabel)
                            .frame(width: primaryWidth(in: proxy.size.width))

                        destinationZone(.thread, label: model.sideConversationLabel(thread))
                    }
                } else {
                    destinationZone(.channel, label: channelLabel)
                }
            }
            .animation(.smooth(duration: 0.22), value: hoveredDestination)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isInstantUpload
                ? "Drop files to upload instantly"
                : "Drop files anywhere to upload"
        )
    }

    private var channelLabel: SideConversationLabel {
        SideConversationLabel(title: model.selectedChannel?.name ?? "Channel", systemImage: "number")
    }

    @ViewBuilder
    private func destinationZone(
        _ destination: MessageComposerDestination,
        label: SideConversationLabel
    ) -> some View {
        if hoveredDestination == destination, model.isComposerDropEligible(destination) {
            ZStack {
                Color.black.opacity(0.6)
                    .transition(.opacity)

                GlassEffectContainer(spacing: InterfaceScale.metric(14)) {
                    VStack(spacing: InterfaceScale.metric(18)) {
                        Image(
                            systemName: isInstantUpload
                                ? "paperplane.fill" : "tray.and.arrow.down.fill"
                        )
                        .font(.interfaceSystem(size: 50, weight: .semibold))
                        .foregroundStyle(.primary)
                        .symbolEffect(.bounce, value: isInstantUpload)
                        .symbolEffectsRemoved(reduceMotion)

                        Text(isInstantUpload ? "Upload directly to" : "Upload to")
                            .font(.interface(.title2).weight(.bold))

                        Label {
                            Text(label.title)
                        } icon: {
                            SakuraCordSystemSymbol.swiftUIImage(named: label.systemImage)
                        }
                        .font(.interface(.headline).weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, InterfaceScale.metric(14))
                        .padding(.vertical, InterfaceScale.metric(7))
                        .glassEffect(.regular, in: Capsule())

                        VStack(spacing: InterfaceScale.metric(10)) {
                            Text(
                                isInstantUpload
                                    ? "Release to upload immediately."
                                    : "You can add a message before uploading."
                            )
                            .font(.interface(.callout))
                            .foregroundStyle(.secondary)

                            if !isInstantUpload {
                                HStack(spacing: InterfaceScale.metric(7)) {
                                    Text("⇧")
                                        .font(.interface(.caption).weight(.bold))
                                        .frame(width: InterfaceScale.metric(21), height: InterfaceScale.metric(19))
                                        .glassEffect(
                                            .regular,
                                            in: ConcentricRectangle(
                                                cornerRadius: InterfaceScale.metric(6),
                                                style: .continuous
                                            )
                                        )
                                    Text("Hold Shift to upload directly")
                                        .font(.interface(.caption).weight(.medium))
                                }
                                .foregroundStyle(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, InterfaceScale.metric(48))
                    .padding(.vertical, InterfaceScale.metric(38))
                    .frame(maxWidth: InterfaceScale.metric(460))
                    .glassEffect(
                        .regular,
                        in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(28), style: .continuous)
                    )
                    .padding(InterfaceScale.metric(24))
                    .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: isInstantUpload)
                }
                // The card lifts toward the pointer as files come over it.
                .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            }
            .transition(.opacity)
        } else {
            Color.clear
        }
    }

    private func primaryWidth(in totalWidth: CGFloat) -> CGFloat {
        guard let workspaceMinX else { return totalWidth / 2 }
        return max(0, min(totalWidth, supplementaryPaneFrame.minX - workspaceMinX))
    }
}

private struct ConversationToolbarPresentation {
    let title: String
    let systemImage: String
    var subtitle: String?
    var topic: String?
    var avatarChannel: Channel?
    var avatarStatus: PresenceStatus?
    var avatarIsMobile = false
}

struct ConversationToolbarLabel: View {
    let title: String
    let systemImage: String
    var subtitle: String?
    let textSize: CGFloat
    let avatarChannel: Channel?
    let avatarStatus: PresenceStatus?
    let avatarIsMobile: Bool

    init(
        title: String,
        systemImage: String,
        subtitle: String?,
        textSize: CGFloat,
        avatarChannel: Channel? = nil,
        avatarStatus: PresenceStatus? = nil,
        avatarIsMobile: Bool = false
    ) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.textSize = textSize
        self.avatarChannel = avatarChannel
        self.avatarStatus = avatarStatus
        self.avatarIsMobile = avatarIsMobile
    }

    var body: some View {
        HStack(spacing: 8) {
            if let avatarChannel {
                DirectMessageAvatar(
                    channel: avatarChannel,
                    size: 24,
                    status: avatarStatus,
                    isMobile: avatarIsMobile,
                    animates: true
                )
                .accessibilityHidden(true)
            } else {
                SakuraCordSystemSymbol.swiftUIImage(named: systemImage)
                    .font(systemImage == SakuraCordSystemSymbol.thread ? .system(size: textSize) : nil)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(
                        size: textSize,
                        weight: subtitle == nil ? .regular : .semibold
                    ))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: max(10, textSize - 2)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 6)
    }
}

/// Use the same control and native toolbar background for every destination.
/// Topic availability changes only its action and accessibility traits.
private struct ConversationToolbarTitle: View {
    let presentation: ConversationToolbarPresentation
    @State private var isTopicPresented = false

    var body: some View {
        Button {
            if presentation.topic != nil { isTopicPresented.toggle() }
        } label: {
            ConversationToolbarLabel(
                title: presentation.title,
                systemImage: presentation.systemImage,
                subtitle: presentation.subtitle,
                textSize: InterfaceTypographyMetrics.interfaceTextSize,
                avatarChannel: presentation.avatarChannel,
                avatarStatus: presentation.avatarStatus,
                avatarIsMobile: presentation.avatarIsMobile
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .allowsHitTesting(presentation.topic != nil)
        .accessibilityRemoveTraits(presentation.topic == nil ? .isButton : [])
        .accessibilityAddTraits(presentation.topic == nil ? .isStaticText : [])
        .escapeDismissiblePopover(
            isPresented: $isTopicPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            if let topic = presentation.topic { ChannelTopicPopover(topic: topic) }
        }
        .onChange(of: presentation.title) { isTopicPresented = false }
    }
}

private struct ChannelTopicPopover: View {
    let topic: String

    var body: some View {
        Text(topic)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .tint(SakuraCordAccentColor.color)
            .padding(InterfaceScale.metric(16))
            .frame(width: InterfaceScale.metric(320), alignment: .leading)
            .interfaceScaleRoot()
    }
}

/// Friends categories use the same principal placement as Channels & Roles.
private struct FriendsToolbarSections: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        ToolbarItem(id: "friends-categories", placement: .principal) {
            Picker("Friends", selection: Binding(
                get: { model.friendsSection },
                set: { model.selectFriendsSection($0) }
            )) {
                ForEach(model.visibleFriendsSections, id: \.self) { section in
                    Text(title(section)).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private func title(_ section: FriendsSection) -> String {
        switch section {
        case .online: "Online"
        case .all: "All"
        case .pending: model.incomingFriendRequestCount > 0 ? "Pending (\(model.incomingFriendRequestCount))" : "Pending"
        case .addFriend: "Add Friend"
        }
    }
}

private extension AppModel {
    /// The workspace shows message search in the window toolbar.
    var showsWorkspaceMessageSearch: Bool {
        onboardingEntryGuildID == nil && guildWorkspacePage == nil
            && (isSwitchingAccounts || canShowMessageSearch)
    }

    /// The toolbar field searches friends or browsable channels instead.
    var showsLocalToolbarSearch: Bool {
        isFriendsSearchActive || (isBrowsingGuildChannels && presentedSideConversation == nil)
    }
}
