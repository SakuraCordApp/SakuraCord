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

nonisolated enum ChannelContextMenuValue {
    static func link(guildID: GuildID?, channelID: ChannelID) -> String {
        "https://discord.com/channels/\(guildID?.description ?? "@me")/\(channelID)"
    }

    @MainActor
    static func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
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

/// SwiftUI context menus can discard item images in the macOS 27 adaptation.
/// This bridge uses the same AppKit symbol configuration as message menus.
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

    func makeCoordinator() -> Coordinator {
        Coordinator(from: self)
    }

    func makeNSView(context: Context) -> ChannelContextMenuHitView {
        let view = ChannelContextMenuHitView()
        view.menuProvider = { [weak coordinator = context.coordinator] in
            coordinator?.makeMenu()
        }
        view.isSelected = isSelected
        return view
    }

    func updateNSView(_ nsView: ChannelContextMenuHitView, context: Context) {
        context.coordinator.update(from: self)
        nsView.menuProvider = { [weak coordinator = context.coordinator] in
            coordinator?.makeMenu()
        }
        nsView.isSelected = isSelected
    }

    static func dismantleNSView(
        _ nsView: ChannelContextMenuHitView,
        coordinator: Coordinator
    ) {
        nsView.uninstallFromNativeRow()
    }

    @MainActor
    final class Coordinator: NSObject {
        private var isUnread: Bool
        private var subject: ChannelContextMenuSubject
        private var isMutationPending: Bool
        private var allowsMutations: Bool
        private var directOverride: ChannelNotificationOverride?
        private var inheritedLevel: MessageNotificationLevel
        private var inheritanceSource: ChannelNotificationInheritanceSource
        private var markRead: () -> Void
        private var mute: (ChannelMuteDuration) -> Void
        private var unmute: () -> Void
        private var setNotificationLevel: (MessageNotificationLevel) -> Void
        private var copyChannelID: () -> Void
        private var copyLink: () -> Void

        init(from bridge: ChannelContextMenuBridge) {
            subject = bridge.subject
            isUnread = bridge.isUnread
            isMutationPending = bridge.isMutationPending
            allowsMutations = bridge.allowsMutations
            directOverride = bridge.directOverride
            inheritedLevel = bridge.inheritedLevel
            inheritanceSource = bridge.inheritanceSource
            markRead = bridge.markRead
            mute = bridge.mute
            unmute = bridge.unmute
            setNotificationLevel = bridge.setNotificationLevel
            copyChannelID = bridge.copyChannelID
            copyLink = bridge.copyLink
        }

        func update(from bridge: ChannelContextMenuBridge) {
            subject = bridge.subject
            isUnread = bridge.isUnread
            isMutationPending = bridge.isMutationPending
            allowsMutations = bridge.allowsMutations
            directOverride = bridge.directOverride
            inheritedLevel = bridge.inheritedLevel
            inheritanceSource = bridge.inheritanceSource
            markRead = bridge.markRead
            mute = bridge.mute
            unmute = bridge.unmute
            setNotificationLevel = bridge.setNotificationLevel
            copyChannelID = bridge.copyChannelID
            copyLink = bridge.copyLink
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false

            menu.addItem(
                menuItem(
                    "Mark as Read",
                    systemImage: "envelope.open.fill",
                    action: #selector(markReadFromMenu),
                    isEnabled: isUnread && allowsMutations
                )
            )
            menu.addItem(.separator())

            if isDirectlyMuted {
                let unmuteItem = menuItem(
                    subject.unmuteTitle,
                    systemImage: "bell.fill",
                    action: #selector(unmuteFromMenu),
                    isEnabled: allowsMutations && !isMutationPending
                )
                if let subtitle = ChannelContextMenuSubtitle.muteRemaining(
                    until: directOverride?.muteConfiguration?.endTime
                ) {
                    unmuteItem.subtitle = subtitle
                }
                menu.addItem(unmuteItem)
            } else {
                let muteItem = menuItem(
                    subject.muteTitle,
                    systemImage: "bell.slash.fill",
                    action: nil,
                    isEnabled: allowsMutations && !isMutationPending
                )
                let muteMenu = NSMenu(title: subject.muteTitle)
                muteMenu.autoenablesItems = false
                for (index, duration) in ChannelMuteDuration.allCases.enumerated() {
                    let item = menuItem(
                        duration.title,
                        action: #selector(muteFromMenu(_:)),
                        isEnabled: allowsMutations && !isMutationPending
                    )
                    item.representedObject = NSNumber(value: index)
                    muteMenu.addItem(item)
                }
                muteItem.submenu = muteMenu
                menu.addItem(muteItem)
            }

            let notificationItem = menuItem(
                "Notification Settings",
                systemImage: "bell.badge.fill",
                action: nil,
                isEnabled: allowsMutations && !isMutationPending
            )
            notificationItem.subtitle =
                ChannelContextMenuSubtitle.notificationSelection(
                    configured:
                        directOverride?.messageNotifications ?? .inherit,
                    inherited: inheritedLevel
                )
            notificationItem.submenu = notificationMenu()
            menu.addItem(notificationItem)

            menu.addItem(.separator())
            menu.addItem(
                menuItem(
                    subject.copyIDTitle,
                    systemImage: "number.square.fill",
                    action: #selector(copyChannelIDFromMenu)
                )
            )
            if subject.includesCopyLink {
                menu.addItem(
                    menuItem(
                        "Copy Link",
                        systemImage: "link",
                        action: #selector(copyLinkFromMenu)
                    )
                )
            }
            return menu
        }

        private var isDirectlyMuted: Bool {
            directOverride?.isMuted == true
                && (directOverride?.muteConfiguration?.isActive() ?? true)
        }

        private func notificationMenu() -> NSMenu {
            let menu = NSMenu(title: "Notification Settings")
            menu.autoenablesItems = false
            let selected = directOverride?.messageNotifications ?? .inherit
            let levels: [MessageNotificationLevel] = [
                .inherit, .allMessages, .onlyMentions, .nothing,
            ]
            for level in levels {
                let title =
                    if level == .inherit {
                        inheritanceSource.menuTitle
                    } else {
                        level.menuTitle
                    }
                let item = menuItem(
                    title,
                    action: #selector(setNotificationFromMenu(_:)),
                    isEnabled: allowsMutations && !isMutationPending
                )
                item.state = selected == level ? .on : .off
                item.representedObject = NSNumber(value: level.rawValue)
                if level == .inherit {
                    item.subtitle = inheritedLevel.menuTitle
                }
                menu.addItem(item)
            }
            return menu
        }

        private func menuItem(
            _ title: String,
            systemImage: String? = nil,
            action: Selector?,
            isEnabled: Bool = true
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = action == nil ? nil : self
            item.isEnabled = isEnabled
            if let systemImage {
                ContextMenuItemSupport.configure(
                    item,
                    title: title,
                    systemImage: systemImage
                )
            }
            return item
        }

        @objc private func markReadFromMenu() {
            markRead()
        }

        @objc private func muteFromMenu(_ sender: NSMenuItem) {
            guard let index = (sender.representedObject as? NSNumber)?.intValue,
                  ChannelMuteDuration.allCases.indices.contains(index)
            else { return }
            mute(ChannelMuteDuration.allCases[index])
        }

        @objc private func unmuteFromMenu() {
            unmute()
        }

        @objc private func setNotificationFromMenu(_ sender: NSMenuItem) {
            guard let rawValue = (sender.representedObject as? NSNumber)?.intValue,
                  let level = MessageNotificationLevel(rawValue: rawValue)
            else { return }
            setNotificationLevel(level)
        }

        @objc private func copyChannelIDFromMenu() {
            copyChannelID()
        }

        @objc private func copyLinkFromMenu() {
            copyLink()
        }
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

final class ChannelContextMenuHitView: NSView {
    var menuProvider: (() -> NSMenu?)?
    var isSelected = false {
        didSet {
            updateNativeHoverPresentation()
        }
    }

    private weak var nativeRowView: NSTableRowView?
    private let nativeHoverView = ChannelNativeHoverRowView()
    private let interactionView = ChannelNativeRowInteractionView()
    private var isHovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        interactionView.menuProvider = { [weak self] in
            self?.menuProvider?()
        }
        interactionView.hoverChanged = { [weak self] hovering in
            guard let self else { return }
            isHovering = hovering
            updateNativeHoverPresentation()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleNativeRowInstallation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            uninstallFromNativeRow()
        } else {
            scheduleNativeRowInstallation()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func uninstallFromNativeRow() {
        interactionView.resetHoverTracking()
        interactionView.removeFromSuperview()
        nativeHoverView.removeFromSuperview()
        nativeRowView = nil
        isHovering = false
    }

    private func scheduleNativeRowInstallation() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.installIntoNativeRowIfNeeded()
        }
    }

    private func installIntoNativeRowIfNeeded() {
        guard window != nil,
              let rowView = enclosingNativeRowView()
        else { return }
        guard nativeRowView !== rowView else {
            synchronizeNativeRowFrames()
            return
        }

        uninstallFromNativeRow()
        nativeRowView = rowView
        nativeHoverView.alphaValue = 0.18
        synchronizeNativeHoverGeometry()
        interactionView.frame = rowView.bounds
        interactionView.autoresizingMask = [.width, .height]
        rowView.addSubview(
            nativeHoverView,
            positioned: .below,
            relativeTo: nil
        )
        rowView.addSubview(
            interactionView,
            positioned: .above,
            relativeTo: nil
        )
        interactionView.refreshHoverTracking()
        updateNativeHoverPresentation()
    }

    private func enclosingNativeRowView() -> NSTableRowView? {
        var candidate = superview
        while let view = candidate {
            if let rowView = view as? NSTableRowView {
                return rowView
            }
            candidate = view.superview
        }
        return nil
    }

    private func synchronizeNativeRowFrames() {
        guard let nativeRowView else { return }
        synchronizeNativeHoverGeometry()
        interactionView.frame = nativeRowView.bounds
    }

    private func updateNativeHoverPresentation() {
        nativeHoverView.showsHover = isHovering && !isSelected
        guard nativeHoverView.showsHover else { return }
        synchronizeNativeHoverGeometry()
    }

    private func synchronizeNativeHoverGeometry() {
        guard let nativeRowView else { return }

        let template: ChannelNativeHoverTemplate
        if let tableView = enclosingNativeTableView(near: nativeRowView) {
            if let selectionView = nativeSelectionView(in: tableView) {
                template = ChannelNativeHoverTemplate(
                    selectionView: selectionView,
                    fallbackRowBounds: nativeRowView.bounds
                )
                ChannelNativeHoverTemplateStore.shared.set(
                    template,
                    for: tableView
                )
            } else {
                template =
                    ChannelNativeHoverTemplateStore.shared.template(for: tableView)
                    ?? .fallback
            }
        } else {
            template = .fallback
        }

        template.apply(to: nativeHoverView, in: nativeRowView.bounds)
    }

    private func enclosingNativeTableView(
        near rowView: NSTableRowView
    ) -> NSTableView? {
        var candidate = rowView.superview
        while let view = candidate {
            if let tableView = view as? NSTableView {
                return tableView
            }
            candidate = view.superview
        }
        return nil
    }

    private func nativeSelectionView(
        in tableView: NSTableView
    ) -> NSVisualEffectView? {
        for row in tableView.rows(in: tableView.visibleRect).integerRange {
            guard let visibleRow = tableView.rowView(
                atRow: row,
                makeIfNecessary: false
            ) else { continue }
            if let selectionView = visibleRow.subviews
                .compactMap({ $0 as? NSVisualEffectView })
                .first(where: {
                    !($0 is ChannelNativeHoverRowView)
                        && $0.material == .selection
                })
            {
                return selectionView
            }
        }
        return nil
    }
}

@MainActor
struct ChannelNativeHoverTemplate {
    static let fallback = ChannelNativeHoverTemplate(
        leadingInset: 5,
        trailingInset: 5,
        verticalInset: 2,
        height: nil,
        material: .selection,
        blendingMode: .withinWindow,
        state: .followsWindowActiveState,
        cornerRadius: 6,
        cornerCurve: .continuous,
        maskedCorners: [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                        .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    )

    let leadingInset: CGFloat
    let trailingInset: CGFloat
    let verticalInset: CGFloat
    let height: CGFloat?
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let state: NSVisualEffectView.State
    let cornerRadius: CGFloat
    let cornerCurve: CALayerCornerCurve
    let maskedCorners: CACornerMask

    init(
        selectionView: NSVisualEffectView,
        fallbackRowBounds: NSRect
    ) {
        let selectionRow = selectionView.superview?.bounds ?? fallbackRowBounds
        leadingInset = selectionView.frame.minX - selectionRow.minX
        trailingInset = selectionRow.maxX - selectionView.frame.maxX
        verticalInset = selectionView.frame.minY - selectionRow.minY
        height = selectionView.frame.height
        material = selectionView.material
        blendingMode = selectionView.blendingMode
        state = selectionView.state
        cornerRadius = selectionView.layer?.cornerRadius ?? 0
        cornerCurve = selectionView.layer?.cornerCurve ?? .circular
        maskedCorners = selectionView.layer?.maskedCorners ?? []
    }

    init(
        leadingInset: CGFloat,
        trailingInset: CGFloat,
        verticalInset: CGFloat,
        height: CGFloat?,
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode,
        state: NSVisualEffectView.State,
        cornerRadius: CGFloat,
        cornerCurve: CALayerCornerCurve,
        maskedCorners: CACornerMask
    ) {
        self.leadingInset = leadingInset
        self.trailingInset = trailingInset
        self.verticalInset = verticalInset
        self.height = height
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
        self.cornerRadius = cornerRadius
        self.cornerCurve = cornerCurve
        self.maskedCorners = maskedCorners
    }

    func frame(in rowBounds: NSRect) -> NSRect {
        NSRect(
            x: rowBounds.minX + leadingInset,
            y: rowBounds.minY + verticalInset,
            width: max(0, rowBounds.width - leadingInset - trailingInset),
            height: height ?? max(0, rowBounds.height - 2 * verticalInset)
        )
    }

    func apply(
        to hoverView: NSVisualEffectView,
        in rowBounds: NSRect
    ) {
        hoverView.frame = frame(in: rowBounds)
        hoverView.material = material
        hoverView.blendingMode = blendingMode
        hoverView.state = state
        hoverView.layer?.cornerRadius = cornerRadius
        hoverView.layer?.cornerCurve = cornerCurve
        hoverView.layer?.maskedCorners = maskedCorners
    }
}

@MainActor
final class ChannelNativeHoverTemplateStore {
    static let shared = ChannelNativeHoverTemplateStore()

    private final class Box: NSObject {
        let template: ChannelNativeHoverTemplate

        init(_ template: ChannelNativeHoverTemplate) {
            self.template = template
        }
    }

    private let templates = NSMapTable<NSTableView, Box>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )

    func template(for tableView: NSTableView) -> ChannelNativeHoverTemplate? {
        templates.object(forKey: tableView)?.template
    }

    func set(
        _ template: ChannelNativeHoverTemplate,
        for tableView: NSTableView
    ) {
        templates.setObject(Box(template), forKey: tableView)
    }
}

private final class ChannelNativeHoverRowView: NSVisualEffectView {
    var showsHover = false {
        didSet {
            guard showsHover != oldValue else { return }
            isHidden = !showsHover
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    nonisolated override func accessibilityIsIgnored() -> Bool {
        true
    }
}

private extension NSRange {
    var integerRange: Range<Int> {
        location ..< NSMaxRange(self)
    }
}

final class ChannelNativeRowInteractionView: NSView {
    var menuProvider: (() -> NSMenu?)?
    var hoverChanged: ((Bool) -> Void)?
    var pointerLocationInWindowProvider: (() -> NSPoint?)?
    private var rowTrackingArea: NSTrackingArea?
    private weak var observedClipView: NSClipView?
    private var reportedHover = false

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        refreshHoverTracking()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshHoverTracking()
    }

    override func updateTrackingAreas() {
        if let rowTrackingArea {
            removeTrackingArea(rowTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .activeInKeyWindow,
                .inVisibleRect,
                .mouseEnteredAndExited,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        rowTrackingArea = area
        super.updateTrackingAreas()
        synchronizeHoverWithCurrentPointer()
    }

    override func mouseEntered(with event: NSEvent) {
        synchronizeHover(atWindowPoint: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        setReportedHover(false)
    }

    func refreshHoverTracking() {
        updateClipViewObservation()
        synchronizeHoverWithCurrentPointer()
    }

    func resetHoverTracking() {
        stopObservingClipView()
        setReportedHover(false)
    }

    func synchronizeHover(atWindowPoint point: NSPoint?) {
        guard let point, window != nil else {
            setReportedHover(false)
            return
        }
        let localPoint = convert(point, from: nil)
        setReportedHover(
            bounds.contains(localPoint)
                && !visibleRect.isEmpty
                && visibleRect.contains(localPoint)
        )
    }

    private func synchronizeHoverWithCurrentPointer() {
        let point =
            pointerLocationInWindowProvider?()
            ?? window?.mouseLocationOutsideOfEventStream
        synchronizeHover(atWindowPoint: point)
    }

    private func setReportedHover(_ hovering: Bool) {
        guard reportedHover != hovering else { return }
        reportedHover = hovering
        hoverChanged?(hovering)
    }

    private func updateClipViewObservation() {
        let clipView = window == nil ? nil : enclosingScrollView?.contentView
        guard observedClipView !== clipView else { return }
        stopObservingClipView()
        guard let clipView else { return }
        observedClipView = clipView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView,
        )
    }

    private func stopObservingClipView() {
        if let observedClipView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: observedClipView
            )
        }
        observedClipView = nil
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        synchronizeHoverWithCurrentPointer()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point),
              let event = window?.currentEvent,
              event.type == .rightMouseDown
                || (
                    event.type == .leftMouseDown
                        && event.modifierFlags.contains(.control)
                )
        else { return nil }
        return self
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    nonisolated override func accessibilityIsIgnored() -> Bool {
        true
    }
}
