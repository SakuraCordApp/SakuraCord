import AppKit
import SakuraCordModels
import SwiftUI

nonisolated enum ChannelMuteDuration: CaseIterable, Equatable, Sendable {
    case fifteenMinutes
    case oneHour
    case threeHours
    case eightHours
    case twentyFourHours
    case indefinitely

    var title: String {
        switch self {
        case .fifteenMinutes: "For 15 Minutes"
        case .oneHour: "For 1 Hour"
        case .threeHours: "For 3 Hours"
        case .eightHours: "For 8 Hours"
        case .twentyFourHours: "For 24 Hours"
        case .indefinitely: "Until I Turn It Back On"
        }
    }

    func endDate(from now: Date = .now) -> Date? {
        let interval: TimeInterval
        switch self {
        case .fifteenMinutes: interval = 15 * 60
        case .oneHour: interval = 60 * 60
        case .threeHours: interval = 3 * 60 * 60
        case .eightHours: interval = 8 * 60 * 60
        case .twentyFourHours: interval = 24 * 60 * 60
        case .indefinitely: return nil
        }
        return now.addingTimeInterval(interval)
    }
}

nonisolated enum ChannelContextMenuSubtitle {
    static func muteRemaining(
        until endTime: Date?,
        now: Date = .now
    ) -> String? {
        guard let endTime else { return nil }
        let remaining = endTime.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        if remaining < 60 {
            return "Less than a minute remaining"
        }
        if remaining < 60 * 60 {
            let minutes = Int(ceil(remaining / 60))
            return "\(minutes) \(minutes == 1 ? "minute" : "minutes") remaining"
        }
        let hours = Int(ceil(remaining / (60 * 60)))
        return "\(hours) \(hours == 1 ? "hour" : "hours") remaining"
    }

    static func notificationSelection(
        configured: MessageNotificationLevel,
        inherited: MessageNotificationLevel
    ) -> String {
        (configured == .inherit ? inherited : configured).menuTitle
    }
}

/// The mute and notification items that channel, category, server and thread
/// menus share.
@MainActor
enum NotificationMenuItems {
    /// Unmute, with the time a timed mute has left.
    static func unmuteEntry(
        _ title: String, until endTime: Date?, isEnabled: Bool, content: ActionMenuEntry.Content
    ) -> ActionMenuEntry {
        ActionMenuEntry(
            id: "mute", title: title, systemImage: "bell.fill",
            subtitle: ChannelContextMenuSubtitle.muteRemaining(until: endTime),
            isEnabled: isEnabled, content: content
        )
    }

    /// Mute, with a submenu of durations.
    static func muteEntry(
        _ title: String, isEnabled: Bool, content: (ChannelMuteDuration) -> ActionMenuEntry.Content
    ) -> ActionMenuEntry {
        ActionMenuEntry(
            id: "mute", title: title, systemImage: "bell.slash.fill", isEnabled: isEnabled,
            content: .submenu(ChannelMuteDuration.allCases.map { duration in
                ActionMenuEntry(id: "mute-\(duration.title)", title: duration.title, content: content(duration))
            })
        )
    }

    /// Notification Settings, with the effective level beside its submenu.
    static func settingsEntry(selection: String, isEnabled: Bool, levels: [ActionMenuEntry]) -> ActionMenuEntry {
        ActionMenuEntry(
            id: "notifications", title: "Notification Settings", systemImage: "bell.badge.fill",
            subtitle: selection, isEnabled: isEnabled, content: .submenu(levels)
        )
    }

    /// One level in the Notification Settings submenu, checked when selected.
    static func levelEntry(
        _ level: MessageNotificationLevel,
        title: String,
        subtitle: String?,
        selected: MessageNotificationLevel,
        content: ActionMenuEntry.Content
    ) -> ActionMenuEntry {
        ActionMenuEntry(
            id: "notifications-\(level.rawValue)", title: title, subtitle: subtitle,
            isChecked: selected == level, content: content
        )
    }
}

nonisolated enum ChannelNotificationInheritanceSource: Equatable, Sendable {
    case category
    case server
    case directMessages

    var menuTitle: String {
        switch self {
        case .category: "Use Category Default"
        case .server: "Use Server Default"
        case .directMessages: "Use Direct Message Default"
        }
    }
}

nonisolated enum ChannelContextMenuSubject: Equatable, Sendable {
    case channel
    case category

    var muteTitle: String {
        self == .category ? "Mute Category" : "Mute Channel"
    }

    var unmuteTitle: String {
        self == .category ? "Unmute Category" : "Unmute Channel"
    }

    var copyIDTitle: String {
        self == .category ? "Copy Category ID" : "Copy Channel ID"
    }

    var includesCopyLink: Bool { self == .channel }
}

enum ChannelPinMenuAction {
    case unavailable
    case available(isPinned: Bool, isServerChannel: Bool = false, toggle: () -> Void)

    var title: String? {
        guard case let .available(isPinned, isServerChannel, _) = self else { return nil }
        if isServerChannel { return isPinned ? "Unpin Channel" : "Pin Channel to Top" }
        return isPinned ? "Unpin" : "Pin"
    }
}

/// SwiftUI context menus can discard item images in the macOS 27 adaptation.
/// This bridge uses the same AppKit symbol configuration as message menus.
/// Page destinations share the channel row's native hover and selection tracking.
struct ChannelRowHoverBridge: NSViewRepresentable {
    let isSelected: Bool
    /// Resolved when the menu opens.
    var menu: (() -> NSMenu?)?
    func makeNSView(context: Context) -> ChannelContextMenuHitView {
        let view = ChannelContextMenuHitView()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: ChannelContextMenuHitView, context: Context) {
        view.isSelected = isSelected
        view.menuProvider = menu
    }
    static func dismantleNSView(_ view: ChannelContextMenuHitView, coordinator: ()) {
        view.uninstallFromNativeRow()
    }
}

/// Edit Group and Leave Group, which Discord offers together on every group DM.
struct GroupDirectMessageMenuActions {
    let edit: () -> Void
    let leave: () -> Void
}

struct ChannelContextMenuBridge: NSViewRepresentable {
    var subject: ChannelContextMenuSubject = .channel
    let isSelected: Bool
    let isUnread: Bool
    let isMutationPending: Bool
    var allowsMutations = true
    let directOverride: ChannelNotificationOverride?
    let inheritedLevel: MessageNotificationLevel
    let inheritanceSource: ChannelNotificationInheritanceSource
    let markRead: () -> Void
    let mute: (ChannelMuteDuration) -> Void
    let unmute: () -> Void
    let setNotificationLevel: (MessageNotificationLevel) -> Void
    let copyChannelID: () -> Void
    let copyLink: () -> Void
    var pinAction: ChannelPinMenuAction = .unavailable
    /// Recipient actions for a direct message, such as a friend nickname.
    /// Resolved when the menu opens so rows don't observe relationship state.
    var userMenu: () -> NSMenu? = { nil }
    /// Edit Group and Leave Group for a group DM.
    var groupActions: GroupDirectMessageMenuActions?
    /// Close DM for a 1:1 DM.
    var closeDirectMessage: (() -> Void)?
    /// Favorites server actions, resolved when the menu opens.
    var favoriteItems: () -> [NSMenuItem] = { [] }

    func makeNSView(context: Context) -> ChannelContextMenuHitView {
        let view = ChannelContextMenuHitView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: ChannelContextMenuHitView, context: Context) {
        nsView.menuProvider = { makeMenu() }
        nsView.isSelected = isSelected
    }

    static func dismantleNSView(_ nsView: ChannelContextMenuHitView, coordinator: ()) {
        nsView.uninstallFromNativeRow()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let canMutate = allowsMutations && !isMutationPending

        menu.addItem(
            ContextMenuItemSupport.item("Mark as Read", systemImage: "envelope.open.fill", isEnabled: isUnread && allowsMutations) {
                self.markRead()
            }
        )
        menu.addItem(.separator())

        let favorites = favoriteItems()
        if !favorites.isEmpty {
            favorites.forEach(menu.addItem)
            menu.addItem(.separator())
        }

        if let pinTitle = pinAction.title {
            menu.addItem(
                ContextMenuItemSupport.item(pinTitle, systemImage: "pin.fill", isEnabled: canMutate) {
                    if case let .available(_, _, toggle) = self.pinAction {
                        toggle()
                    }
                }
            )
            menu.addItem(.separator())
        }

        if groupActions != nil {
            menu.addItem(ContextMenuItemSupport.item("Edit Group", systemImage: "pencil", isEnabled: allowsMutations) { self.groupActions?.edit() })
            menu.addItem(.separator())
        }

        let personItems = detachedUserMenuItems()
        let copyIdentifier = "user-\(UserMenuAction.Group.copy.rawValue)"
        let destructiveIdentifier = "user-\(UserMenuAction.Group.destructive.rawValue)"
        let userItems = personItems.filter {
            !$0.isSeparatorItem && $0.identifier?.rawValue != copyIdentifier && $0.identifier?.rawValue != destructiveIdentifier
        }
        if !userItems.isEmpty {
            userItems.forEach(menu.addItem)
            menu.addItem(.separator())
        }

        let muteEntry = if directOverride?.isActivelyMuted() == true {
            NotificationMenuItems.unmuteEntry(
                subject.unmuteTitle,
                until: directOverride?.muteConfiguration?.endTime,
                isEnabled: canMutate,
                content: .action { self.unmute() }
            )
        } else {
            NotificationMenuItems.muteEntry(subject.muteTitle, isEnabled: canMutate) { duration in
                .action { self.mute(duration) }
            }
        }
        menu.addItem(ActionMenuRenderer.item(muteEntry))

        menu.addItem(
            ActionMenuRenderer.item(NotificationMenuItems.settingsEntry(
                selection: ChannelContextMenuSubtitle.notificationSelection(
                    configured: directOverride?.messageNotifications ?? .inherit,
                    inherited: inheritedLevel
                ),
                isEnabled: canMutate,
                levels: notificationLevelEntries()
            ))
        )

        menu.addItem(.separator())
        personItems.filter { $0.identifier?.rawValue == copyIdentifier }.forEach(menu.addItem)
        menu.addItem(ContextMenuItemSupport.item(subject.copyIDTitle, systemImage: "number.square.fill") { self.copyChannelID() })
        if subject.includesCopyLink {
            menu.addItem(ContextMenuItemSupport.item("Copy Link", systemImage: "link") { self.copyLink() })
        }
        let destructiveItems = personItems.filter { $0.identifier?.rawValue == destructiveIdentifier }
        UserContextMenu.append(conversationLeavingItems(around: destructiveItems), to: menu)
        return menu
    }

    /// Close DM leads a 1:1 DM's last group, above the person's destructive
    /// actions; Leave Group follows them for a group DM.
    private func conversationLeavingItems(around destructiveItems: [NSMenuItem]) -> [NSMenuItem] {
        var items = destructiveItems
        if closeDirectMessage != nil {
            items.insert(
                ContextMenuItemSupport.item("Close DM", systemImage: "xmark", isEnabled: allowsMutations) { self.closeDirectMessage?() },
                at: 0
            )
        }
        if groupActions != nil {
            items.append(
                ContextMenuItemSupport.item(
                    "Leave Group", systemImage: "rectangle.portrait.and.arrow.right",
                    isEnabled: allowsMutations, isDestructive: true
                ) { self.groupActions?.leave() }
            )
        }
        return items
    }

    private func detachedUserMenuItems() -> [NSMenuItem] {
        let menu = userMenu()
        let items = menu?.items ?? []
        menu?.removeAllItems()
        return items
    }

    private func notificationLevelEntries() -> [ActionMenuEntry] {
        let selected = directOverride?.messageNotifications ?? .inherit
        let levels: [MessageNotificationLevel] = [
            .inherit, .allMessages, .onlyMentions, .nothing,
        ]
        return levels.map { level in
            NotificationMenuItems.levelEntry(
                level,
                title: level == .inherit ? inheritanceSource.menuTitle : level.menuTitle,
                subtitle: level == .inherit ? inheritedLevel.menuTitle : nil,
                selected: selected,
                content: .action { self.setNotificationLevel(level) }
            )
        }
    }
}

extension ChannelContextMenuBridge {
    /// The menu for a channel or DM row, with its notification, read and copy
    /// actions bound to the model.
    init(
        channel: Channel,
        model: AppModel,
        isSelected: Bool,
        isUnread: Bool,
        allowsMutations: Bool = true,
        pinAction: ChannelPinMenuAction = .unavailable,
        userMenu: @escaping () -> NSMenu? = { nil },
        groupActions: GroupDirectMessageMenuActions? = nil,
        closeDirectMessage: (() -> Void)? = nil,
        favoriteItems: @escaping () -> [NSMenuItem] = { [] }
    ) {
        self.init(
            isSelected: isSelected,
            isUnread: isUnread,
            isMutationPending: model.isChannelNotificationMutationPending(channel.id),
            allowsMutations: allowsMutations,
            directOverride: model.channelNotificationOverride(for: channel),
            inheritedLevel: model.inheritedChannelNotificationLevel(for: channel),
            inheritanceSource: channel.guildID == nil ? .directMessages : channel.categoryID == nil ? .server : .category,
            markRead: { model.markConversationRead(channelID: channel.id) },
            mute: { model.setChannelMute(true, until: $0.endDate(), for: channel) },
            unmute: { model.setChannelMute(false, until: nil, for: channel) },
            setNotificationLevel: { model.setChannelNotificationLevel($0, for: channel) },
            copyChannelID: { Pasteboard.copy(channel.id.description) },
            copyLink: { Pasteboard.copy(DiscordLink.channel(guildID: channel.guildID, channelID: channel.id)) },
            pinAction: pinAction,
            userMenu: userMenu,
            groupActions: groupActions,
            closeDirectMessage: closeDirectMessage,
            favoriteItems: favoriteItems
        )
    }
}

extension MessageNotificationLevel {
    nonisolated var menuTitle: String {
        switch self {
        case .allMessages: "All Messages"
        case .onlyMentions: "Only @mentions"
        case .nothing: "Nothing"
        case .inherit: "Default"
        }
    }
}
