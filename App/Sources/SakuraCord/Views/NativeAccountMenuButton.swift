import AppKit
import SakuraCordModels
import SwiftUI

struct NativeAccountMenuButton: NSViewRepresentable {
    let isAuthenticated: Bool
    let isCachedStartup: Bool
    let isOfflineTesting: Bool
    let currentStatus: PresenceStatus
    let savedAccounts: [SavedAccount]
    let activeAccountID: String?
    let manageAccounts: () -> Void
    let switchAccount: (String) async -> Bool
    let updateStatus: (PresenceStatus) async -> Void
    let openSettings: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(configuration)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: "",
            target: context.coordinator,
            action: #selector(Coordinator.showMenu(_:))
        )
        button.isBordered = false
        button.isTransparent = true
        button.imagePosition = .imageOnly
        button.focusRingType = .none
        button.setButtonType(.momentaryPushIn)
        button.setAccessibilityLabel("Account and Settings")
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.update(configuration)
    }

    private var configuration: Configuration {
        Configuration(
            isAuthenticated: isAuthenticated,
            isCachedStartup: isCachedStartup,
            isOfflineTesting: isOfflineTesting,
            currentStatus: currentStatus,
            savedAccounts: savedAccounts,
            activeAccountID: activeAccountID,
            manageAccounts: manageAccounts,
            switchAccount: switchAccount,
            updateStatus: updateStatus,
            openSettings: openSettings
        )
    }

    struct Configuration {
        let isAuthenticated: Bool
        let isCachedStartup: Bool
        let isOfflineTesting: Bool
        let currentStatus: PresenceStatus
        let savedAccounts: [SavedAccount]
        let activeAccountID: String?
        let manageAccounts: () -> Void
        let switchAccount: (String) async -> Bool
        let updateStatus: (PresenceStatus) async -> Void
        let openSettings: () -> Void
    }

    @MainActor
    final class Coordinator: NSObject {
        private var configuration: Configuration
        private var avatarImages: [String: NSImage] = [:]
        private var avatarTasks: [String: Task<Void, Never>] = [:]

        init(_ configuration: Configuration) {
            self.configuration = configuration
            super.init()
            preloadAvatars()
        }

        func update(_ configuration: Configuration) {
            self.configuration = configuration
            preloadAvatars()
        }

        @objc func showMenu(_ sender: NSButton) {
            let menu = makeMenu()
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: -4),
                in: sender
            )
        }

        private func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            if configuration.isOfflineTesting {
                menu.addItem(disabledItem("Discord networking is disabled"))
            } else if configuration.isCachedStartup {
                menu.addItem(
                    disabledItem("Cached data is read-only while Discord reconnects")
                )
            } else if configuration.isAuthenticated {
                menu.addItem(statusMenuItem())
                menu.addItem(accountMenuItem())
            } else {
                menu.addItem(
                    menuItem(
                        "Connect Discord Account…",
                        systemImage: "person.crop.circle.badge.plus",
                        action: #selector(manageAccountsFromMenu)
                    )
                )
            }
            menu.addItem(.separator())
            menu.addItem(
                menuItem(
                    "Settings…",
                    systemImage: "gearshape",
                    action: #selector(openSettingsFromMenu)
                )
            )
            return menu
        }

        private func statusMenuItem() -> NSMenuItem {
            let item = menuItem(
                "Set Status",
                systemImage: "circle.dotted",
                action: nil
            )
            let submenu = NSMenu(title: "Set Status")
            submenu.autoenablesItems = false
            for status in PresenceStatus.allCases where status != .offline {
                let statusItem = NSMenuItem(
                    title: statusTitle(status),
                    action: #selector(updateStatusFromMenu(_:)),
                    keyEquivalent: ""
                )
                statusItem.target = self
                statusItem.isEnabled = true
                statusItem.state = status == configuration.currentStatus ? .on : .off
                statusItem.representedObject = status.rawValue
                submenu.addItem(statusItem)
            }
            item.submenu = submenu
            return item
        }

        private func accountMenuItem() -> NSMenuItem {
            let item = menuItem(
                "Switch Account",
                systemImage: "person.crop.circle",
                action: nil
            )
            let submenu = NSMenu(title: "Switch Account")
            submenu.autoenablesItems = false
            for account in configuration.savedAccounts {
                let accountItem = NSMenuItem(
                    title: account.username ?? account.resolvedDisplayName,
                    action: #selector(switchAccountFromMenu(_:)),
                    keyEquivalent: ""
                )
                accountItem.target = self
                accountItem.isEnabled = true
                accountItem.state = account.accountID == configuration.activeAccountID
                    ? .on
                    : .off
                accountItem.representedObject = account.accountID
                let avatar = avatarImages[account.accountID]
                    ?? coloredSymbolImage(
                        "person.crop.circle.fill",
                        accessibilityDescription: account.resolvedDisplayName
                    )
                    ?? NSImage()
                ContextMenuItemSupport.configure(
                    accountItem,
                    image: accountMenuImage(avatar)
                )
                submenu.addItem(accountItem)
            }
            submenu.addItem(.separator())
            let manageItem = NSMenuItem(
                title: "Manage Accounts…",
                action: #selector(manageAccountsFromMenu),
                keyEquivalent: ""
            )
            manageItem.target = self
            manageItem.isEnabled = true
            let manageImage = NSImage(
                systemSymbolName: "person.crop.circle",
                accessibilityDescription: "Manage Accounts"
            )
            manageImage?.isTemplate = true
            manageItem.mixedStateImage = manageImage
            manageItem.state = .mixed
            submenu.addItem(manageItem)
            item.submenu = submenu
            return item
        }

        private func disabledItem(_ title: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }

        private func coloredSymbolImage(
            _ name: String,
            accessibilityDescription: String
        ) -> NSImage? {
            let baseConfiguration = NSImage.SymbolConfiguration(
                pointSize: 13,
                weight: .regular
            )
            let configuration = baseConfiguration.applying(
                NSImage.SymbolConfiguration(
                    paletteColors: [.labelColor]
                )
            )
            let image = NSImage(
                systemSymbolName: name,
                accessibilityDescription: accessibilityDescription
            )?.withSymbolConfiguration(configuration)
            image?.isTemplate = false
            return image
        }

        private func accountMenuImage(_ avatar: NSImage) -> NSImage {
            let image = NSImage(size: NSSize(width: 18, height: 18))
            image.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            avatar.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            image.unlockFocus()
            image.isTemplate = false
            return image
        }

        private func menuItem(
            _ title: String,
            systemImage: String,
            action: Selector?,
            isDestructive: Bool = false
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = action == nil ? nil : self
            item.isEnabled = true
            ContextMenuItemSupport.configure(
                item,
                title: title,
                systemImage: systemImage,
                isDestructive: isDestructive
            )
            return item
        }

        private func preloadAvatars() {
            let validIDs = Set(configuration.savedAccounts.map(\.accountID))
            avatarImages = avatarImages.filter { validIDs.contains($0.key) }
            let obsoleteTaskIDs = avatarTasks.keys.filter { !validIDs.contains($0) }
            for accountID in obsoleteTaskIDs {
                avatarTasks[accountID]?.cancel()
                avatarTasks[accountID] = nil
            }
            for account in configuration.savedAccounts {
                guard avatarImages[account.accountID] == nil,
                      avatarTasks[account.accountID] == nil,
                      let avatarURL = account.avatarURL
                else { continue }
                avatarTasks[account.accountID] = Task { [weak self] in
                    defer { self?.avatarTasks[account.accountID] = nil }
                    guard let image = await AccountMenuAvatarStore.shared.image(
                        for: avatarURL
                    ), !Task.isCancelled
                    else { return }
                    self?.avatarImages[account.accountID] = image
                }
            }
        }

        private func statusTitle(_ status: PresenceStatus) -> String {
            switch status {
            case .online: "Online"
            case .idle: "Idle"
            case .dnd: "Do Not Disturb"
            case .invisible: "Invisible"
            case .offline: "Offline"
            }
        }

        @objc private func switchAccountFromMenu(_ sender: NSMenuItem) {
            guard let accountID = sender.representedObject as? String,
                  accountID != configuration.activeAccountID
            else { return }
            Task { _ = await configuration.switchAccount(accountID) }
        }

        @objc private func updateStatusFromMenu(_ sender: NSMenuItem) {
            guard let rawValue = sender.representedObject as? String,
                  let status = PresenceStatus(rawValue: rawValue),
                  status != configuration.currentStatus
            else { return }
            Task { await configuration.updateStatus(status) }
        }

        @objc private func manageAccountsFromMenu() {
            configuration.manageAccounts()
        }

        @objc private func openSettingsFromMenu() {
            configuration.openSettings()
        }
    }
}

@MainActor
private final class AccountMenuAvatarStore {
    static let shared = AccountMenuAvatarStore()

    private let images = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    private init() {
        images.countLimit = 16
        images.totalCostLimit = 16 * 18 * 18 * 4
    }

    func image(for url: URL) async -> NSImage? {
        let key = url as NSURL
        if let image = images.object(forKey: key) { return image }
        if let task = inFlight[url] { return await task.value }

        let task = Task<NSImage?, Never> {
            guard let data = try? await SharedMediaDataLoader.shared.data(for: url),
                  !Task.isCancelled,
                  let source = NSImage(data: data)
            else { return nil }
            return Self.circularImage(source)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            images.setObject(image, forKey: key, cost: 18 * 18 * 4)
        }
        return image
    }

    private static func circularImage(_ source: NSImage) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).addClip()

        let sourceSize = source.size
        let scale = max(
            size.width / max(1, sourceSize.width),
            size.height / max(1, sourceSize.height)
        )
        let drawSize = NSSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        let drawRect = NSRect(
            x: (size.width - drawSize.width) / 2,
            y: (size.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        source.draw(
            in: drawRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
