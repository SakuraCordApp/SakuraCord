import SakuraCordModels
import SwiftUI

// The workspace's toolbar actions, as the column-owned toolbar
// (`WorkspaceTitlebar`) shows them.

struct InboxToolbarButton: View {
    let model: AppModel
    /// Off for a copy of the button that is out of view, so the panel opens
    /// from the visible one only.
    var presentsPanel = true

    var body: some View {
        Button {
            if model.inbox.isPresented { model.dismissInbox() } else { model.presentInbox() }
        } label: {
            Label {
                Text("Inbox")
            } icon: {
                ToggleSymbol(off: "tray", on: "tray.fill", isOn: model.inbox.isPresented)
            }
            .symbolVariant(.none)
                .animation(model.animates(.overlays) ? .smooth(duration: 0.24) : nil, value: model.inbox.isPresented)
        }
        .help("Inbox")
        .background { ToolbarPanelPresenter(model: model, panel: .inbox, isEnabled: presentsPanel) }
    }
}

struct PinnedMessagesToolbarButton: View {
    let model: AppModel
    let channelID: ChannelID
    var presentsPanel = true

    var body: some View {
        let isPresented = model.pinnedMessages.isPresented && model.pinnedMessages.channelID == channelID
        Button {
            if isPresented {
                model.dismissPinnedMessages()
            } else {
                model.presentPinnedMessages(channelID: channelID)
            }
        } label: {
            Label {
                Text("Pinned Messages")
            } icon: {
                ToggleSymbol(off: "pin", on: "pin.fill", isOn: isPresented)
            }
            .symbolVariant(.none)
                .animation(model.animates(.overlays) ? .smooth(duration: 0.24) : nil, value: isPresented)
        }
        .help("Pinned Messages")
        .background { ToolbarPanelPresenter(model: model, panel: .pinnedMessages(channelID), isEnabled: presentsPanel) }
    }
}

struct ThreadsToolbarButton: View {
    let model: AppModel
    var presentsPanel = true

    var body: some View {
        Button(action: model.toggleThreadBrowser) {
            Label {
                Text("Threads")
            } icon: {
                SakuraCordSystemSymbol.swiftUIImage(named: SakuraCordSystemSymbol.thread)
            }
        }
        .help("Threads")
        .background { ToolbarPanelPresenter(model: model, panel: .threadBrowser, isEnabled: presentsPanel) }
    }
}

/// A toolbar panel, opening from the view it backs.
private struct ToolbarPanelPresenter: View {
    enum Panel: Equatable {
        case inbox
        case pinnedMessages(ChannelID)
        case threadBrowser
    }

    let model: AppModel
    let panel: Panel
    let isEnabled: Bool

    var body: some View {
        StableAnchoredPopoverPresenter(
            isPresented: isEnabled && isPresented,
            configuration: .toolbarPanel,
            onDismiss: dismiss,
            onWillDismiss: dismiss
        ) { content }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isPresented: Bool {
        switch panel {
        case .inbox: model.inbox.isPresented
        case .pinnedMessages(let channelID): model.pinnedMessages.isPresented && model.pinnedMessages.channelID == channelID
        case .threadBrowser: model.threadBrowser.isPresented
        }
    }

    private func dismiss() {
        switch panel {
        case .inbox: model.dismissInbox()
        case .pinnedMessages: model.dismissPinnedMessages()
        case .threadBrowser: model.dismissThreadBrowser()
        }
    }

    @ViewBuilder private var content: some View {
        switch panel {
        case .inbox: InboxPopoverView(model: model)
        case .pinnedMessages: PinnedMessagesPopoverView(model: model)
        case .threadBrowser: ThreadBrowserPopoverView(model: model)
        }
    }
}

/// Inbox, Pinned Messages and Threads in one menu, for a conversation too
/// narrow for their buttons. Their panels open from this button.
struct ConversationOverflowToolbarMenu: View {
    let model: AppModel
    /// The channel whose pins the menu offers, if it has any.
    let pinsChannelID: ChannelID?
    let offersThreads: Bool
    var presentsPanels = true
    @State private var presenter = ActionMenuPresenter()

    var body: some View {
        Button {
            presenter.show(menu)
        } label: {
            Label("More", systemImage: "chevron.right.2")
        }
        .help("More")
        .background {
            ActionMenuAnchor(presenter: presenter)
            ToolbarPanelPresenter(model: model, panel: .inbox, isEnabled: presentsPanels)
            if let pinsChannelID {
                ToolbarPanelPresenter(model: model, panel: .pinnedMessages(pinsChannelID), isEnabled: presentsPanels)
            }
            if offersThreads {
                ToolbarPanelPresenter(model: model, panel: .threadBrowser, isEnabled: presentsPanels)
            }
        }
    }

    private var menu: [[ActionMenuEntry]] {
        var entries = [
            ActionMenuEntry(id: "inbox", title: "Inbox", systemImage: "tray", content: .action(model.presentInbox)),
        ]
        if let pinsChannelID {
            entries.append(ActionMenuEntry(
                id: "pins", title: "Pinned Messages", systemImage: "pin",
                content: .action { [model] in model.presentPinnedMessages(channelID: pinsChannelID) }
            ))
        }
        if offersThreads {
            entries.append(ActionMenuEntry(
                id: "threads", title: "Threads", systemImage: SakuraCordSystemSymbol.thread,
                content: .action(model.toggleThreadBrowser)
            ))
        }
        return [entries]
    }
}

struct MemberInspectorToolbarButton: View {
    let model: AppModel

    var body: some View {
        let isDirectMessage = model.selectedChannel?.kind == .directMessage
        let isShown = model.workspacePresentation.supplementaryPane == .memberInspector
        Button {
            model.toggleMemberInspector()
        } label: {
            Label {
                Text(model.selectedChannel?.kind.isDirectMessage == true ? "People" : "Members")
            } icon: {
                ToggleSymbol(
                    off: isDirectMessage ? "person" : "person.2",
                    on: isDirectMessage ? "person.fill" : "person.2.fill",
                    isOn: isShown
                )
            }
            .symbolVariant(.none)
            .animation(model.animates(.sidebar) ? .smooth(duration: 0.24) : nil, value: isShown)
        }
    }
}

/// A toggle's symbol, as wide in either state: the toolbar measures its
/// items' widths, so a filled symbol half a point narrower than its outline
/// moved every item beside it.
private struct ToggleSymbol: View {
    let off: String
    let on: String
    let isOn: Bool

    var body: some View {
        // Both symbols stay, and the state fades one into the other: a
        // changing symbol is redrawn on every frame of its transition, and
        // in the workspace's titlebar each redraw waited for the frame
        // before it to reach the screen, while the member list moved.
        ZStack {
            Image(systemName: off).opacity(isOn ? 0 : 1)
            Image(systemName: on).opacity(isOn ? 1 : 0)
        }
    }
}

/// A side chat's actions: Add to Channel List, Follow, its menu and Close.
struct SideConversationToolbarActions: View {
    let model: AppModel
    let conversation: SideConversation

    var body: some View {
        let capabilities = conversation.capabilities
        // One group, as the toolbar draws adjacent items: on one capsule.
        HStack(spacing: 0) {
            if SideConversationAddToChannelListButton.isOffered(model: model, capabilities: capabilities),
               let channel = model.customizationPreviewChannel, let guildID = channel.guildID
            {
                SideConversationAddToChannelListButton(model: model, channel: channel, guildID: guildID)
            }
            if case .thread(let thread, _) = conversation {
                if ForumPostFollowToolbarButton.isOffered(model: model, thread: thread) {
                    ForumPostFollowToolbarButton(model: model, thread: thread, surface: .forumPostHeader)
                }
                ThreadActionsToolbarMenu(model: model, thread: thread, surface: .sidePane)
            }
            SideConversationCloseButton(model: model, capabilities: capabilities)
        }
        .titlebarButtons(grouped: true)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

/// Adds the channel a side chat previews to the server's channel list.
struct SideConversationAddToChannelListButton: View {
    let model: AppModel
    let channel: Channel
    let guildID: GuildID

    /// Offered while the previewed channel isn't in the channel list yet.
    static func isOffered(model: AppModel, capabilities: SideConversationCapabilities) -> Bool {
        capabilities.canAddToChannelList
            && model.customizationPreviewChannel.map { !model.isChannelSelected($0) } == true
    }

    var body: some View {
        Button("Add to Channel List", systemImage: "plus") {
            model.setChannelSelected(true, channelID: channel.id, guildID: guildID)
        }
        .labelStyle(.iconOnly)
        .help("Add to Channel List")
    }
}

/// Closes the side chat; Escape closes it over a server guide.
struct SideConversationCloseButton: View {
    let model: AppModel
    let capabilities: SideConversationCapabilities

    var body: some View {
        Button {
            model.closeSideConversation()
        } label: {
            Label("Close conversation", systemImage: "xmark")
                .labelStyle(.iconOnly)
        }
        .help(capabilities.closeHelp)
        .keyboardShortcut(model.guildWorkspacePage == .guide ? .cancelAction : nil)
    }
}

/// A side chat's title in the column-owned toolbar: it fills the pane up to
/// the pane's actions.
struct SideConversationTitlebarTitle: View {
    let label: SideConversationLabel

    var body: some View {
        ConversationToolbarLabel(
            title: label.title,
            systemImage: label.systemImage,
            subtitle: nil,
            textSize: InterfaceTypographyMetrics.interfaceTextSize
        )
        .padding(.horizontal, 8)
        .frame(minHeight: 36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: Capsule())
    }
}

extension View {
    /// Buttons as the window toolbar draws them: icons on their own glass,
    /// or on their group's.
    func titlebarButtons(grouped: Bool = false) -> some View {
        labelStyle(.iconOnly)
            .buttonStyle(TitlebarGlassButtonStyle(hasOwnGlass: !grouped))
            .toggleStyle(.button)
    }
}

/// The window toolbar's button: a glass circle with the item's icon, or a
/// glass capsule around a title, which keeps its own type and ink.
struct TitlebarGlassButtonStyle: ButtonStyle {
    var hasOwnGlass = true
    var isTitle = false

    func makeBody(configuration: Configuration) -> some View {
        TitlebarGlassButton(configuration: configuration, hasOwnGlass: hasOwnGlass, isTitle: isTitle)
    }
}

private struct TitlebarGlassButton: View {
    let configuration: ButtonStyle.Configuration
    let hasOwnGlass: Bool
    let isTitle: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        label
            .frame(minHeight: 36)
            // The whole capsule takes the pointer, not just what it draws.
            .contentShape(Capsule())
            .glassEffect(hasOwnGlass ? .regular.interactive() : .identity, in: Capsule())
            // The toolbar tints the item under the pointer, icon and all; in
            // a group, a smaller capsule inset within the group's glass.
            .overlay {
                Capsule()
                    .fill(.primary.opacity(
                        isHovered && isEnabled
                            ? TitlebarButtonMetrics.hoverOpacity(grouped: !hasOwnGlass, colorScheme) : 0
                    ))
                    .padding(hasOwnGlass ? EdgeInsets() : TitlebarButtonMetrics.groupedHoverInset)
                    .allowsHitTesting(false)
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var label: some View {
        if isTitle {
            configuration.label
        } else {
            let ink: Color = colorScheme == .dark ? .white : .black
            configuration.label
                .font(.system(size: TitlebarButtonMetrics.iconSize))
                .imageScale(.medium)
                // The toolbar draws its icons in a plain translucent ink: as
                // `.primary` over glass they took on its vibrancy and drew
                // lighter in light mode. Disabled icons keep the dimmed primary.
                .foregroundStyle(
                    isEnabled
                        ? AnyShapeStyle(ink.opacity(TitlebarButtonMetrics.iconOpacity))
                        : AnyShapeStyle(.primary.opacity(TitlebarButtonMetrics.iconOpacity))
                )
                // As wide as the toolbar's own: its icon's width, inset, at
                // least a circle.
                .padding(.horizontal, 5.75)
                .frame(minWidth: 36)
        }
    }
}

/// Measured against the window toolbar's own items.
enum TitlebarButtonMetrics {
    static let iconSize: CGFloat = 17
    static let iconOpacity = 0.877

    static let groupedHoverInset = EdgeInsets(top: 4, leading: 2.75, bottom: 4, trailing: 2.75)

    /// A grouped item's is stronger: the group's glass mutes what its
    /// buttons draw.
    static func hoverOpacity(grouped: Bool, _ colorScheme: ColorScheme) -> Double {
        switch (grouped, colorScheme == .dark) {
        case (false, true): 0.055
        case (false, false): 0.07
        case (true, true): 0.2
        case (true, false): 0.24
        }
    }
}
