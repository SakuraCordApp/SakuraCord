import AppKit
import SakuraCordModels
import SwiftUI

struct RootView: View {
    let model: AppModel

    var body: some View {
        switch model.sessionState {
        case .workspace:
            ChatRootView(model: model)
        case .signedOut:
            if model.launchMode == .normal {
                DiscordLoginView(
                    showsCancel: false,
                    networkingEnabled: !model.isDiscordNetworkingDisabled
                ) { handle in
                    await model.connectAuthenticatedAccount(
                        handle,
                        preservesInteractivePresentation: true
                    )
                        ? nil
                        : (model.errorMessage ?? "Discord account bootstrap failed for an unknown reason.")
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
                isOfflineTesting: model.isOfflineTesting
            )
        }
    }
}

private struct ChatRootView: View {
    let model: AppModel
    @State private var showLogin = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var supplementaryPaneFrame = CGRect.zero

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            ServerRailView(
                guildsByID: model.serverRailGuildsByID,
                items: model.serverRailItems,
                selectedGuildID: model.selectedGuildID,
                selectHome: { model.selectGuild(nil) }, selectGuild: model.selectGuild
            )
            .zIndex(200)
            Divider()
            NavigationSplitView(columnVisibility: $columnVisibility) {
                ChannelSidebarView(
                    voiceModel: model,
                    guild: selectedGuild,
                    channels: model.visibleChannels,
                    selection: $model.selectedChannelID,
                    currentUser: model.snapshot?.currentUser,
                    connectionState: model.connectionState,
                    currentStatus: model.currentStatus,
                    isAuthenticated: model.isAuthenticated,
                    isOfflineTesting: model.isOfflineTesting,
                    activeVoiceChannelID: model.activeVoiceChannel?.id,
                    connectAccount: {
                        if !model.isOfflineTesting {
                            showLogin = true
                        }
                    },
                    logout: { await model.logout() },
                    updateStatus: { await model.updateStatus($0) }
                )
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 310)
            } detail: {
                ChatWorkspaceView(model: model)
                    .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
                    .toolbar(id: "sakuracord-main-v2") {
                        ToolbarItem(id: "channel") {
                            if let channel = model.selectedChannel {
                                Button { model.showQuickSwitcher = true } label: {
                                    ConversationToolbarLabel(
                                        title: channel.name,
                                        systemImage: channelToolbarSymbol(channel)
                                    )
                                }
                            }
                        }
                        .visibilityPriority(.high)
                        ToolbarSpacer(.flexible)
                        ToolbarItem(id: "thread") {
                            if let presentation = supplementaryToolbarPresentation {
                                HStack(spacing: 0) {
                                    Button { model.showQuickSwitcher = true } label: {
                                        ConversationToolbarLabel(
                                            title: presentation.title,
                                            systemImage: presentation.systemImage,
                                            subtitle: presentation.subtitle
                                        )
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(
                                    width: max(supplementaryPaneFrame.width - 64, 120),
                                    alignment: .leading
                                )
                            }
                        }
                        .visibilityPriority(.high)
                        ToolbarItem(id: "close-thread") {
                            if hasOpenSupplementaryConversation {
                                Button(action: closeSupplementaryConversation) {
                                    Label("Close conversation", systemImage: "xmark")
                                        .labelStyle(.iconOnly)
                                }
                                .help(model.openThread == nil ? "Close voice channel chat" : "Close thread")
                            }
                        }
                        .visibilityPriority(.high)
                        ToolbarSpacer(.fixed)
                        ToolbarItem(id: "voice-chat") {
                            if let channel = selectedVoiceChannel, !model.isVoiceChatOpen {
                                Button { model.openVoiceChat(for: channel) } label: {
                                    Label("Open Chat", systemImage: "bubble.left.fill")
                                }
                                .help("Open voice channel chat")
                            }
                        }
                        .visibilityPriority(.high)
                        ToolbarItem(id: "quick-switcher") {
                            if !hasOpenSupplementaryConversation, selectedVoiceChannel == nil {
                                Button { model.showQuickSwitcher = true } label: { Label("Quick Switcher", systemImage: "magnifyingglass") }
                            }
                        }
                        .visibilityPriority(.high)
                        ToolbarItem(id: "members") {
                            if !hasOpenSupplementaryConversation, selectedVoiceChannel == nil {
                                Button { model.showInspector.toggle() } label: { Label("Members", systemImage: "person.2") }
                            }
                        }
                        .visibilityPriority(.high)
                    }
            }
        }
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                TrafficLightGlassCapsule()
                    .frame(width: 80, height: 28)
                    .offset(x: 9, y: 12)
                    .accessibilityHidden(true)

                if columnVisibility != .detailOnly {
                    SidebarServerIdentity(guild: selectedGuild)
                        .frame(width: 150, height: 28, alignment: .leading)
                        .offset(x: ChatChromeMetrics.sidebarIdentityLeadingOffset, y: 12)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .onPreferenceChange(ThreadPaneFramePreferenceKey.self) { frame in
            supplementaryPaneFrame = frame
        }
        .onChange(of: hasOpenSupplementaryConversation) { _, isOpen in
            if !isOpen {
                supplementaryPaneFrame = .zero
            }
        }
        .sheet(isPresented: $showLogin) {
            DiscordLoginView(
                showsCancel: true,
                networkingEnabled: !model.isDiscordNetworkingDisabled
            ) { handle in
                await model.connectAuthenticatedAccount(
                    handle,
                    preservesInteractivePresentation: true
                )
                    ? nil
                    : (model.errorMessage ?? "Discord account bootstrap failed for an unknown reason.")
            }
        }
        .sheet(isPresented: $model.showQuickSwitcher) { QuickSwitcherView(model: model) }
        .alert("SakuraCord", isPresented: Binding(get: { model.errorMessage != nil }, set: {
            if !$0 {
                model.dismissError()
            }
        })) {
            Button("OK") { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .onReceive(NotificationCenter.default.publisher(for: .sakuracordQuickSwitcher)) { _ in model.showQuickSwitcher = true }
        .onReceive(NotificationCenter.default.publisher(for: .sakuracordToggleInspector)) { _ in model.showInspector.toggle() }
    }

    private func channelToolbarSymbol(_ channel: Channel) -> String {
        ChannelIconPresentation.systemImage(
            for: channel.kind,
            isHidden: model.conversationAccess(for: channel) == .hidden
        )
    }

    private var hasOpenSupplementaryConversation: Bool {
        model.openThread != nil || model.isVoiceChatOpen
    }

    private var selectedVoiceChannel: Channel? {
        guard model.selectedChannel?.kind == .voice else { return nil }
        return model.selectedChannel
    }

    private var supplementaryToolbarPresentation: SupplementaryToolbarPresentation? {
        if let thread = model.openThread {
            let replyCount = max(thread.messageCount, model.threadMessages.count)
            return SupplementaryToolbarPresentation(
                title: thread.name,
                systemImage: "bubble.left.and.bubble.right",
                subtitle: "\(replyCount) \(replyCount == 1 ? "reply" : "replies")"
            )
        }
        guard model.isVoiceChatOpen, let channel = model.selectedChannel else { return nil }
        return SupplementaryToolbarPresentation(
            title: channel.name,
            systemImage: "bubble.left.fill",
            subtitle: "Voice channel chat"
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

private struct SupplementaryToolbarPresentation {
    let title: String
    let systemImage: String
    let subtitle: String
}

private struct ConversationToolbarLabel: View {
    let title: String
    let systemImage: String
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(subtitle == nil ? .body : .headline)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 6)
    }
}
