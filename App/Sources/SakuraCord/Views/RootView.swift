import AppKit
import Combine
import SakuraCordModels
import SwiftUI

struct RootView: View {
    let model: AppModel
    @Environment(\.colorSchemeContrast) private var systemColorSchemeContrast
    @State private var toolbarSearchFieldMetrics = ToolbarSearchFieldMetrics.zero

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
            case .signedOut:
                if model.launchMode == .normal {
                    if model.savedAccounts.isEmpty {
                        DiscordLoginView(
                            showsCancel: false,
                            networkingEnabled: !model.isDiscordNetworkingDisabled
                        ) { credential in
                            await model.connectPendingAuthenticatedAccount(
                                credential,
                                preservesInteractivePresentation: true
                            )
                                ? nil
                                : (model.errorMessage ?? "Discord account bootstrap failed for an unknown reason.")
                        }
                    } else {
                        AccountSwitcherView(model: model, showsCancel: false)
                    }
                } else {
                    SakuraCordSessionLoadingView(
                        state: model.sessionState,
                        isOfflineTesting: model.isOfflineTesting
                    )
                }
            case .restoring, .connecting:
                SakuraCordSessionLoadingView(
                    state: model.sessionState,
                    isOfflineTesting: model.isOfflineTesting,
                    isAccountSwitch: model.isSwitchingAccounts
                )
            }
        }
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
                    isVisible: showsMessageSearchToolbar,
                    metrics: $toolbarSearchFieldMetrics
                )
                ToolbarSearchFieldLoadingStyler(isActive: showsSessionLoadingChrome)
            }
            .frame(width: 0, height: 0)
        }
        .onChange(of: model.isSwitchingAccounts) { _, isSwitching in
            if isSwitching {
                search.isFilterSheetPresented = false
                model.dismissMessageSearch()
            }
        }
        .onChange(of: model.showInspector) { _, isVisible in
            if model.interfaceSettings.showsMemberList != isVisible {
                model.interfaceSettings.showsMemberList = isVisible
            }
            guard SettingsPreferenceStore.shared.value(
                for: .rememberMemberListVisibility
            ) == .bool(true) else { return }
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
        .contrast(
            model.accessibilitySettings.increasesContrast
                && systemColorSchemeContrast == .standard
                ? 1.12
                : 1
        )
        .background {
            SakuraCordThemeBackground()
                .ignoresSafeArea()
        }
    }

    private var showsMessageSearchToolbar: Bool {
        switch model.sessionState {
        case .restoring, .connecting:
            true
        case .workspace:
            model.isSwitchingAccounts
                || MessageSearchSurfacePolicy.showsToolbar(
                    channelKind: model.selectedChannel?.kind,
                    hasOpenThread: model.openThread != nil
                )
        case .signedOut:
            model.launchMode != .normal
        }
    }

    private var messageSearchPrompt: Text {
        Text(showsSessionLoadingChrome ? "" : model.messageSearchPromptTitle)
    }

    private var showsSessionLoadingChrome: Bool {
        switch model.sessionState {
        case .restoring, .connecting:
            true
        case .workspace:
            model.isSwitchingAccounts
        case .signedOut:
            model.launchMode != .normal
        }
    }
}

private struct ChatRootView: View {
    let model: AppModel
    let toolbarSearchFieldMetrics: ToolbarSearchFieldMetrics
    @State private var showAccountSwitcher = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var supplementaryPaneFrame = CGRect.zero
    @State private var supplementaryToolbarSpacerWidth: CGFloat = 0
    @State private var workspaceFrame = CGRect.zero
    @State private var sidebarWidth = ChatChromeMetrics.serverRailWidth + 230
    @State private var presentsForumComposer = false
    @State private var isFileDropTargeted = false
    @State private var isInstantUpload = false
    @State private var hoveredFileDropDestination: MessageComposerDestination?
    @State private var modifierPollingTask: Task<Void, Never>?
    @State private var composerDropInteraction = ComposerDropInteractionState()

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            HStack(spacing: 0) {
                ServerRailContainer(model: model)
                .zIndex(200)
                ChannelSidebarView(
                    voiceModel: model,
                    guild: selectedGuild,
                    channels: model.visibleChannels,
                    channelGroups: model.visibleChannelGroups,
                    unreadCategoryIDs: selectedGuild.map {
                        model.unreadCategoryIDsByGuild[$0.id] ?? []
                    } ?? [],
                    selection: $model.selectedChannelID,
                    currentUser: model.snapshot?.currentUser,
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
            .opacity(model.isSwitchingAccounts ? 0 : 1)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                guard width.isFinite, width > ChatChromeMetrics.serverRailWidth else { return }
                sidebarWidth = width
            }
            .navigationSplitViewColumnWidth(
                min: ChatChromeMetrics.serverRailWidth + 190,
                ideal: ChatChromeMetrics.serverRailWidth + 230,
                max: ChatChromeMetrics.serverRailWidth + 310
            )
        } detail: {
            Group {
                if model.isSwitchingAccounts {
                    Color.clear
                } else {
                    ChatWorkspaceView(
                        model: model,
                        presentsForumComposer: $presentsForumComposer,
                        toolbarSearchFieldMetrics: toolbarSearchFieldMetrics
                    )
                }
            }
            .navigationTitle("")
            .toolbar {
                detailToolbar
            }
        }
        .toolbar {
            conversationToolbar
        }
        .environment(\.composerDropInteraction, composerDropInteraction)
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                SakuraCordTextInputAccentBridge()
                .frame(width: 0, height: 0)

                if columnVisibility != .detailOnly {
                    if model.isSwitchingAccounts {
                        SkeletonShimmerTimeline {
                            SkeletonShape(cornerRadius: 4)
                                .frame(width: 132, height: 14)
                        }
                        .offset(
                            x: ChatChromeMetrics.sidebarTitleLeadingOffset,
                            y: ChatChromeMetrics.sidebarTitleTopOffset + 7
                        )
                    } else {
                        Text(sidebarDisplayName)
                            .font(.system(
                                size: InterfaceTypographyMetrics.interfaceTextSize + 2,
                                weight: .semibold
                            ))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: 150, height: 28, alignment: .leading)
                            .offset(
                                x: ChatChromeMetrics.sidebarTitleLeadingOffset,
                                y: ChatChromeMetrics.sidebarTitleTopOffset
                            )
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .overlay {
            if !model.incomingPrivateCalls.isEmpty {
                IncomingPrivateCallOverlay(model: model)
                    .zIndex(500)
            }
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
                dismiss: { model.mediaViewerPresentation = nil }
            )
            .frame(width: 0, height: 0)
        }
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
        .overlay {
            if presentsForumComposer,
               let channel = model.selectedChannel,
               channel.kind == .forum
            {
                ForumPostComposerOverlay(
                    model: model,
                    channel: channel,
                    isPresented: $presentsForumComposer
                )
            }
        }
        .overlay {
            if showsFileDropEffect {
                ComposerFileDropOverlay(
                    model: model,
                    workspaceFrame: workspaceFrame,
                    supplementaryPaneFrame: supplementaryPaneFrame,
                    hoveredDestination: effectiveFileDropDestination,
                    isInstantUpload: effectiveInstantUpload
                )
                .allowsHitTesting(false)
            }
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            workspaceFrame = frame
        }
        .dropDestination(
            for: URL.self,
            action: { urls, location in
                guard canAcceptWindowDrops,
                      let destination = composerDestination(at: location)
                else { return false }
                hoveredFileDropDestination = destination
                if NSEvent.modifierFlags.contains(.shift) {
                    sendDroppedAttachmentsImmediately(urls, to: destination)
                    return !urls.isEmpty
                }
                return model.addComposerAttachments(urls, to: destination)
            },
            isTargeted: { targeted in
                isFileDropTargeted = targeted
                isInstantUpload = targeted && NSEvent.modifierFlags.contains(.shift)
                hoveredFileDropDestination =
                    targeted ? composerDestinationForCurrentPointer() : nil
                updateModifierPolling(isTargeted: targeted)
            }
        )
        .overlay {
            ComposerPromisedFileDropBridge(
                isEnabled: canAcceptWindowDrops,
                targetChanged: { targeted, location, instant in
                    let destination = targeted ? composerDestination(at: location) : nil
                    isFileDropTargeted = destination != nil
                    isInstantUpload = destination != nil && instant
                    hoveredFileDropDestination = destination
                },
                receiveFiles: { batch, location, instant in
                    guard let destination = composerDestination(at: location) else {
                        batch.discard()
                        return
                    }
                    if instant {
                        sendDroppedPromisedAttachmentsImmediately(
                            batch,
                            to: destination
                        )
                    } else {
                        model.addPromisedComposerAttachments(
                            batch,
                            to: destination
                        )
                    }
                }
            )
        }
        .onPreferenceChange(ThreadPaneFramePreferenceKey.self) { frame in
            supplementaryPaneFrame = frame
        }
        .onChange(of: hasOpenSupplementaryConversation) { _, isOpen in
            if !isOpen {
                supplementaryPaneFrame = .zero
                supplementaryToolbarSpacerWidth = 0
            }
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
            modifierPollingTask?.cancel()
            modifierPollingTask = nil
            model.mediaViewerPresentation = nil
        }
        .sheet(isPresented: $showAccountSwitcher) {
            AccountSwitcherView(
                model: model,
                showsCancel: true,
                accountActivated: { showAccountSwitcher = false }
            )
        }
        .alert(
            "File Too Large",
            isPresented: oversizedAttachmentPromptIsPresented,
            presenting: model.oversizedAttachmentPrompt
        ) { prompt in
            if prompt.availableServices.contains(.catbox) {
                Button("Upload to Catbox (Permanent)") {
                    model.uploadOversizedAttachment(prompt, using: .catbox)
                }
            }
            if prompt.availableServices.contains(.litterbox) {
                Button("Upload to Litterbox (24 Hours)") {
                    model.uploadOversizedAttachment(prompt, using: .litterbox)
                }
            }
            Button("Cancel", role: .cancel) {
                model.dismissOversizedAttachmentPrompt(id: prompt.id)
            }
        } message: { prompt in
            Text(model.oversizedAttachmentMessage(prompt))
        }
        .overlay {
            if let upload = model.externalAttachmentUploadPresentation {
                ZStack {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Uploading to \(upload.service.displayName)…")
                            .font(.headline)
                        Text(upload.fileName)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("Cancel", role: .cancel) {
                            model.cancelExternalAttachmentUpload()
                        }
                    }
                    .padding(24)
                    .frame(minWidth: 280)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .shadow(radius: 18)
                }
            }
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
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
        .onReceive(NotificationCenter.default.publisher(for: .sakuracordNotificationDeepLink)) { notification in
            guard let link = notification.object as? NotificationDeepLink else { return }
            Task { await model.navigate(from: link) }
        }
    }

    private func updateModifierPolling(isTargeted: Bool) {
        modifierPollingTask?.cancel()
        modifierPollingTask = nil
        guard isTargeted else { return }
        modifierPollingTask = Task { @MainActor in
            while !Task.isCancelled {
                isInstantUpload = NSEvent.modifierFlags.contains(.shift)
                hoveredFileDropDestination = composerDestinationForCurrentPointer()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private var oversizedAttachmentPromptIsPresented: Binding<Bool> {
        let presentedID = model.oversizedAttachmentPrompt?.id
        return Binding(
            get: { model.oversizedAttachmentPrompt != nil },
            set: { isPresented in
                if !isPresented {
                    model.dismissOversizedAttachmentPrompt(id: presentedID)
                }
            }
        )
    }

    @ToolbarContentBuilder
    private var conversationToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
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
            } else if let channel = model.selectedChannel {
                if isDirectMessageSelected {
                    ConversationToolbarLabel(
                        title: channel.name,
                        systemImage: channelToolbarSymbol(channel),
                        subtitle: directMessageToolbarSubtitle(for: channel),
                        textSize: InterfaceTypographyMetrics.interfaceTextSize
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                } else if let topic = channelTopic(for: channel) {
                    ChannelTopicToolbarButton(
                        title: channel.name,
                        systemImage: channelToolbarSymbol(channel),
                        topic: topic,
                        textSize: InterfaceTypographyMetrics.interfaceTextSize
                    )
                } else {
                    ConversationToolbarLabel(
                        title: channel.name,
                        systemImage: channelToolbarSymbol(channel),
                        subtitle: nil,
                        textSize: InterfaceTypographyMetrics.interfaceTextSize
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                }
            }
        }
        .visibilityPriority(.high)

        if !model.isSwitchingAccounts {
            if let presentation = supplementaryToolbarPresentation {
                ToolbarItem {
                    ConversationToolbarLabel(
                        title: presentation.title,
                        systemImage: presentation.systemImage,
                        subtitle: nil,
                        textSize: InterfaceTypographyMetrics.interfaceTextSize
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { frame in
                        alignSupplementaryToolbarTitle(frame)
                    }
                }
                .visibilityPriority(.high)

                ToolbarSpacer(.fixed)

                ToolbarItem {
                    Color.clear
                        .frame(width: supplementaryToolbarSpacerWidth, height: 1)
                        .accessibilityHidden(true)
                }
                .contentMarginsRemoved()
                .sharedBackgroundVisibility(.hidden)

                ToolbarSpacer(.fixed)

                ToolbarItem(placement: .primaryAction) {
                    Button(action: closeSupplementaryConversation) {
                        Label("Close conversation", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .help(supplementaryCloseHelp)
                }
                .visibilityPriority(.high)
            }
        }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarSpacer(.flexible)

        if !model.isSwitchingAccounts {
            if let channel = selectedPrivateChannel {
                ToolbarItemGroup {
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
                .visibilityPriority(.high)
            } else if let channel = selectedVoiceChannel, !model.isVoiceChatOpen {
                ToolbarItem {
                    Button { model.openVoiceChat(for: channel) } label: {
                        Label("Open Chat", systemImage: "bubble.left.fill")
                    }
                    .help("Open voice channel chat")
                }
                .visibilityPriority(.high)
            }

            if let pinsChannelID = toolbarPinsChannelID {
                if hasToolbarActionBeforePins {
                    ToolbarSpacer(.fixed)
                }

                ToolbarItem {
                    Button {
                        if model.pinnedMessages.isPresented {
                            model.dismissPinnedMessages()
                        } else {
                            model.presentPinnedMessages(channelID: pinsChannelID)
                        }
                    } label: {
                        Label("Pinned Messages", systemImage: "pin.fill")
                    }
                    .help("Pinned Messages")
                    .popover(
                        isPresented: Binding(
                            get: { model.pinnedMessages.isPresented },
                            set: { presented in
                                if !presented { model.dismissPinnedMessages() }
                            }
                        ),
                        arrowEdge: .bottom
                    ) {
                        PinnedMessagesPopoverView(model: model)
                    }
                }
                .visibilityPriority(.high)
            }
        }

        if model.isSwitchingAccounts
            || (!hasOpenSupplementaryToolbarConversation && selectedVoiceChannel == nil)
        {
            if !model.isSwitchingAccounts, hasToolbarActionBeforeInspector {
                ToolbarSpacer(.fixed)
            }

            ToolbarItem {
                ZStack {
                    Button { model.showInspector.toggle() } label: {
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

            ToolbarSpacer(.fixed)
                .contentMarginsRemoved(true)
        }
    }

    private var sidebarDisplayName: String {
        guard let guild = selectedGuild else { return "Messages" }
        return guild.name.isEmpty ? "Unnamed Server" : guild.name
    }

    private var canAcceptWindowDrops: Bool {
        !presentsForumComposer
            && !showAccountSwitcher
            && model.presentedInteractionModal == nil
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
        if model.openThread != nil, supplementaryPaneFrame != .zero {
            let localThreadLeadingEdge = supplementaryPaneFrame.minX - workspaceFrame.minX
            return horizontalPosition >= localThreadLeadingEdge ? .thread : .channel
        }
        return .channel
    }

    private func composerDestinationForCurrentPointer() -> MessageComposerDestination? {
        guard let window =
            NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })
        else { return nil }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let proposed = proposedComposerDestination(atX: windowPoint.x - workspaceFrame.minX)
        return model.isComposerDropEligible(proposed) ? proposed : nil
    }

    private func sendDroppedAttachmentsImmediately(
        _ urls: [URL],
        to destination: MessageComposerDestination
    ) {
        let acceptedURLs = model.attachmentURLsWithinDiscordLimit(
            urls,
            offeringExternalUploadFor: destination
        )
        guard !acceptedURLs.isEmpty else { return }
        Task {
            let scopedURLs = acceptedURLs.filter { $0.startAccessingSecurityScopedResource() }
            defer {
                for url in scopedURLs {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            await model.sendAttachmentsImmediately(
                acceptedURLs.map { ForumPostAttachment(url: $0) },
                to: destination
            )
        }
    }

    private func sendDroppedPromisedAttachmentsImmediately(
        _ batch: ComposerPromisedFileBatch,
        to destination: MessageComposerDestination
    ) {
        let acceptedURLs = model.preparePromisedAttachmentsForImmediateSend(
            batch,
            to: destination
        )
        guard !acceptedURLs.isEmpty else { return }
        Task {
            defer { model.endUsingOwnedPromisedFiles(acceptedURLs) }
            await model.sendAttachmentsImmediately(
                acceptedURLs.map { ForumPostAttachment(url: $0) },
                to: destination
            )
        }
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
            systemImage: model.showInspector
                ? "person.2.fill"
                : "person.2"
        )
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

    private func channelTopic(for channel: Channel) -> String? {
        guard let topic = channel.topic?.trimmingCharacters(in: .whitespacesAndNewlines),
              !topic.isEmpty
        else { return nil }
        return topic
    }

    private var hasOpenSupplementaryConversation: Bool {
        hasOpenSupplementaryToolbarConversation
            || model.messageSearch.isPresented
    }

    private var hasOpenSupplementaryToolbarConversation: Bool {
        model.openThread != nil
            || model.isVoiceChatOpen
    }

    private var selectedVoiceChannel: Channel? {
        guard model.selectedChannel?.kind == .voice else { return nil }
        return model.selectedChannel
    }

    private var hasToolbarActionBeforePins: Bool {
        selectedPrivateChannel != nil
            || (selectedVoiceChannel != nil && !model.isVoiceChatOpen)
    }

    private var hasToolbarActionBeforeInspector: Bool {
        selectedPrivateChannel != nil
            || toolbarPinsChannelID != nil
    }

    private var toolbarPinsChannelID: ChannelID? {
        guard selectedVoiceChannel == nil, model.openThread == nil else { return nil }
        return model.activePinsChannelID
    }

    private var supplementaryToolbarPresentation: SupplementaryToolbarPresentation? {
        if let thread = model.openThread {
            return SupplementaryToolbarPresentation(
                title: thread.name,
                systemImage: "bubble.left.and.bubble.right"
            )
        }
        guard model.isVoiceChatOpen, let channel = model.selectedChannel else { return nil }
        return SupplementaryToolbarPresentation(
            title: channel.name,
            systemImage: "bubble.left.fill"
        )
    }

    private var supplementaryCloseHelp: String {
        model.openThread == nil ? "Close voice channel chat" : "Close thread"
    }

    private func alignSupplementaryToolbarTitle(_ titleFrame: CGRect) {
        guard supplementaryPaneFrame != .zero,
              titleFrame != .zero,
              titleFrame.minX.isFinite
        else { return }

        let targetLeadingEdge = supplementaryPaneFrame.minX
            + ChatChromeMetrics.toolbarPaneEdgeInset
        let correction = titleFrame.minX - targetLeadingEdge
        guard abs(correction) > 0.5 else { return }
        supplementaryToolbarSpacerWidth = max(
            0,
            supplementaryToolbarSpacerWidth + correction
        )
    }

    private func closeSupplementaryConversation() {
        if model.openThread != nil {
            model.closeThread()
        } else {
            model.closeVoiceChat()
        }
    }

    private var selectedGuild: Guild? {
        guard let guildID = model.selectedGuildID else { return nil }
        return model.snapshot?.guilds.first(where: { $0.id == guildID })
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
                search.isFilterSheetPresented = false
                model.dismissMessageSearch()
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
        ToolbarSearchFieldGeometryReader(
            searchText: $model.messageSearchInputText,
            searchTokens: $search.tokens,
            isSearchFocused: $search.isInputFocused,
            isToolbarItemVisible: isVisible,
            didUseBuiltInClear: model.clearMessageSearchUsingBuiltInButton,
            didEndEditing: model.messageSearchEditingDidEnd,
            pasteCanonicalSyntax: { value in
                MessageSearchTokenParser.parse(
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
        content
            .searchable(
                text: $model.messageSearchInputText,
                tokens: $search.tokens,
                isPresented: $search.isInputFocused,
                placement: .toolbar,
                prompt: prompt
            ) { token in
                Text(token.title)
            }
            .onSubmit(of: .search) {
                model.submitMessageSearchInput()
            }
    }
}

private struct ComposerFileDropOverlay: View {
    let model: AppModel
    let workspaceFrame: CGRect
    let supplementaryPaneFrame: CGRect
    let hoveredDestination: MessageComposerDestination?
    let isInstantUpload: Bool

    var body: some View {
        GeometryReader { proxy in
            Group {
                if model.openThread != nil, supplementaryPaneFrame != .zero {
                    HStack(spacing: 0) {
                        destinationZone(
                            .channel,
                            title: model.selectedChannel?.name ?? "Channel"
                        )
                        .frame(width: primaryWidth(in: proxy.size.width))

                        destinationZone(
                            .thread,
                            title: model.openThread?.name ?? "Thread"
                        )
                    }
                } else {
                    destinationZone(
                        .channel,
                        title: model.selectedChannel?.name ?? "Channel"
                    )
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isInstantUpload
                ? "Drop files to upload instantly"
                : "Drop files anywhere to upload"
        )
    }

    @ViewBuilder
    private func destinationZone(
        _ destination: MessageComposerDestination,
        title: String
    ) -> some View {
        if hoveredDestination == destination, model.isComposerDropEligible(destination) {
            ZStack {
                Color.black.opacity(0.6)

                GlassEffectContainer(spacing: 14) {
                    VStack(spacing: 18) {
                        Image(
                            systemName: isInstantUpload
                                ? "paperplane.fill" : "tray.and.arrow.down.fill"
                        )
                        .font(.system(size: 50, weight: .semibold))
                        .foregroundStyle(.primary)
                        .symbolEffect(.bounce, value: isInstantUpload)

                        Text(isInstantUpload ? "Upload directly to" : "Upload to")
                            .font(.title2.weight(.bold))

                        Label(
                            title,
                            systemImage: destination == .thread
                                ? "bubble.left.and.bubble.right.fill" : "number"
                        )
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .glassEffect(.regular, in: Capsule())

                        VStack(spacing: 10) {
                            Text(
                                isInstantUpload
                                    ? "Release to upload immediately."
                                    : "You can add a message before uploading."
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)

                            if !isInstantUpload {
                                HStack(spacing: 7) {
                                    Text("⇧")
                                        .font(.caption.weight(.bold))
                                        .frame(width: 21, height: 19)
                                        .glassEffect(
                                            .regular,
                                            in: ConcentricRectangle(
                                                cornerRadius: 6,
                                                style: .continuous
                                            )
                                        )
                                    Text("Hold Shift to upload directly")
                                        .font(.caption.weight(.medium))
                                }
                                .foregroundStyle(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 48)
                    .padding(.vertical, 38)
                    .frame(maxWidth: 460)
                    .glassEffect(
                        .regular,
                        in: ConcentricRectangle(cornerRadius: 28, style: .continuous)
                    )
                    .padding(24)
                }
            }
        } else {
            Color.clear
        }
    }

    private func primaryWidth(in totalWidth: CGFloat) -> CGFloat {
        guard workspaceFrame != .zero else { return totalWidth / 2 }
        return max(0, min(totalWidth, supplementaryPaneFrame.minX - workspaceFrame.minX))
    }
}

private struct SupplementaryToolbarPresentation {
    let title: String
    let systemImage: String
}

private struct ConversationToolbarLabel: View {
    let title: String
    let systemImage: String
    var subtitle: String?
    let textSize: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
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

private struct ChannelTopicToolbarButton: View {
    let title: String
    let systemImage: String
    let topic: String
    let textSize: CGFloat
    @State private var isTopicPresented = false

    var body: some View {
        Button {
            isTopicPresented.toggle()
        } label: {
            ConversationToolbarLabel(
                title: title,
                systemImage: systemImage,
                subtitle: nil,
                textSize: textSize
            )
        }
        .popover(
            isPresented: $isTopicPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            ChannelTopicPopover(topic: topic)
        }
        .help("Show channel topic")
        .accessibilityLabel("Show channel topic")
        .accessibilityValue(title)
    }
}

private struct ChannelTopicPopover: View {
    let topic: String

    var body: some View {
        Text(topic)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .tint(SakuraCordAccentColor.color)
            .padding(16)
            .frame(width: 320, alignment: .leading)
    }
}
