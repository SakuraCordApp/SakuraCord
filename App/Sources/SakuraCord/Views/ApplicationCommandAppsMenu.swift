import AppKit
import Observation
import SakuraCordModels

/// Owns one open Apps submenu. Catalog changes, search and image tasks share
/// its lifetime; the timeline does not retain menu state after it closes.
@MainActor
final class ApplicationCommandAppsMenuPopulator: NSObject, NSMenuDelegate, NSSearchFieldDelegate {
    private weak var model: AppModel?
    private weak var menu: NSMenu?
    private let type: ApplicationCommandType
    private let targetID: String
    private let channelID: ChannelID
    private let account: AppModelAccountSession
    private let search = NSSearchField(frame: NSRect(x: 10, y: 7, width: 240, height: 24))
    private let searchItem = NSMenuItem()
    private var isOpen = false
    private var imageTasks: [Task<Void, Never>] = []
    private var editingMonitor: Any?

    init(model: AppModel, type: ApplicationCommandType, targetID: String, channelID: ChannelID) {
        self.model = model
        self.type = type
        self.targetID = targetID
        self.channelID = channelID
        account = model.accountSession()
        super.init()
        search.placeholderString = "Search commands"
        search.setAccessibilityLabel("Search commands")
        search.sendsSearchStringImmediately = true
        search.delegate = self
        // A menu redraws rows around a custom view without moving AppKit's
        // separately drawn focus ring, which could strand it over another row.
        // The caret already shows the field is active.
        search.focusRingType = .none
        search.autoresizingMask = .width
        let header = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 38))
        header.autoresizingMask = .width
        header.addSubview(search)
        searchItem.view = header
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        self.menu = menu
        populate(menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        if editingMonitor == nil {
            editingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleEditingShortcut(event) == true ? nil : event
            }
        }
        observeCatalog()
    }

    private func observeCatalog() {
        guard let model, model.isCurrentAccountSession(account) else { return }
        withObservationTracking {
            _ = model.commandComposer(for: model.commandDestination(in: channelID)).isLoading
            _ = model.commandComposer(for: model.commandDestination(in: channelID)).contextMenuCommands
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isOpen, let menu = self.menu else { return }
                self.populate(menu)
                self.observeCatalog()
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        imageTasks.forEach { $0.cancel() }
        imageTasks.removeAll()
        removeEditingMonitor()
    }

    isolated deinit {
        if let editingMonitor { NSEvent.removeMonitor(editingMonitor) }
    }

    private func removeEditingMonitor() {
        if let editingMonitor { NSEvent.removeMonitor(editingMonitor) }
        editingMonitor = nil
    }

    // Native menu key equivalents end tracking before dispatching the action.
    // Editing shortcuts must instead stay inside this menu's active field editor.
    private func handleEditingShortcut(_ event: NSEvent) -> Bool {
        guard isOpen, let editor = search.currentEditor(),
              editor.window?.firstResponder === editor,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command
        else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": editor.selectAll(nil)
        case "c": editor.copy(nil)
        case "x": editor.cut(nil)
        case "v": editor.paste(nil)
        default: return false
        }
        return true
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let menu else { return }
        populate(menu)
    }

    private func populate(_ menu: NSMenu) {
        guard let model, model.isCurrentAccountSession(account) else { return }
        imageTasks.forEach { $0.cancel() }
        imageTasks.removeAll()
        // Keep the search view and its field editor attached while filtering.
        for item in menu.items where item !== searchItem { menu.removeItem(item) }
        if searchItem.menu == nil { menu.addItem(searchItem) }
        menu.addItem(.separator())
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let results = model.commandComposer(for: model.commandDestination(in: channelID)).searchContextMenuCommands(of: type, query: query)
            for command in results { menu.addItem(commandItem(command, showsAvatar: true)) }
            if results.isEmpty { menu.addItem(statusItem("No matching commands")) }
            return
        }
        let sections = model.commandComposer(for: model.commandDestination(in: channelID)).contextMenuSections(of: type)
        guard !sections.applications.isEmpty else {
            menu.addItem(statusItem(model.commandComposer(for: model.commandDestination(in: channelID)).isLoading ? "Loading Apps…" : "No Apps"))
            return
        }
        if !sections.frequent.isEmpty {
            menu.addItem(.sectionHeader(title: "Frequently Used Commands"))
            for command in sections.frequent { menu.addItem(commandItem(command, showsAvatar: true)) }
            menu.addItem(.separator())
        }
        menu.addItem(.sectionHeader(title: "Apps"))
        for (application, commands) in sections.applications {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            commands.forEach { submenu.addItem(commandItem($0, showsAvatar: false)) }
            let item = NSMenuItem(title: application.bot?.username ?? application.name, action: nil, keyEquivalent: "")
            item.submenu = submenu
            configureIcon(item, application: application)
            menu.addItem(item)
        }
    }

    private func commandItem(_ command: ApplicationCommand, showsAvatar: Bool) -> NSMenuItem {
        let targetID = targetID, channelID = channelID
        let account = account
        let action = NativeTimelineMenuAction { [weak model] in
            guard let model, model.isCurrentAccountSession(account),
                  model.composerSendChannelID(in: model.commandDestination(in: channelID)) == channelID else { return }
            model.runContextMenuCommand(command, targetID: targetID, in: channelID)
        }
        let item = NSMenuItem(title: command.displayName, action: #selector(NativeTimelineMenuAction.performAction), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        item.toolTip = command.application.name
        if showsAvatar { configureIcon(item, application: command.application) }
        return item
    }

    private func statusItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func configureIcon(_ item: NSMenuItem, application: ApplicationCommandApplication) {
        guard let url = application.displayIconURL else { return }
        if let image = SharedDecodedImageLoader.shared.cachedImage(for: url, maximumPixelDimension: 64) {
            setIcon(image, on: item)
        } else {
            imageTasks.append(Task { @MainActor [weak self, weak item] in
                guard let image = await SharedDecodedImageLoader.shared.image(for: url, maximumPixelDimension: 64, priority: .visible),
                      !Task.isCancelled, let self, let item else { return }
                self.setIcon(image, on: item)
            })
        }
    }

    private func setIcon(_ image: CGImage, on item: NSMenuItem) {
        let source = NSImage(cgImage: image, size: .zero)
        let icon = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            source.draw(in: rect)
            return true
        }
        ContextMenuItemSupport.configure(item, image: icon)
    }
}
