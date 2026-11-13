import AppKit
import DiscordProtocol
import MessageRendering
import SakuraCordModels
import SwiftUI
import UniformTypeIdentifiers

struct ForumChannelView: View {
    let model: AppModel
    @Binding var presentsComposer: Bool
    @State private var searchText = ""
    @State private var headerHeight: CGFloat = 0

    var body: some View {
        if let channel = model.selectedChannel {
            forumContent(channel: channel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Posts scroll beneath the header's glass controls and the
                // window toolbar, as conversation timelines do.
                .safeAreaBar(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        ForumBrowseHeader(
                            model: model,
                            channel: channel,
                            searchText: $searchText,
                            presentsComposer: $presentsComposer
                        )
                        if let error = model.forumActionError {
                            ForumActionErrorBanner(
                                message: error,
                                dismiss: model.dismissForumActionError
                            )
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(.snappy(duration: 0.25), value: model.forumActionError)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .onChange(of: channel.id) {
                    searchText = model.forumSearchText
                    reportPresentedForum(channel.id)
                }
                .onAppear { reportPresentedForum(channel.id) }
        } else {
            ContentUnavailableView("Choose a forum", systemImage: "rectangle.3.group.bubble")
        }
    }

    @ViewBuilder
    private func forumContent(channel: Channel) -> some View {
        if model.selectedConversationAccess == .hidden {
            ContentUnavailableView(
                "Forum unavailable", systemImage: "lock.fill",
                description: Text("You do not have permission to browse this forum.")
            )
        } else if model.hasLoadedForumPosts, let error = model.forumPostError, model.forumPosts.isEmpty {
            ContentUnavailableView(
                "Forum could not be loaded", systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
            .overlay(alignment: .bottom) {
                Button("Try Again") { model.reloadForumPosts() }.padding(InterfaceScale.metric(24))
            }
        } else if model.hasLoadedForumPosts, model.forumPosts.isEmpty,
                  !model.isSearchingForumPosts, !model.isLoadingForumPosts
        {
            let isFiltering =
                !model.forumSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !model.forumSelectedTagIDs.isEmpty
            ForumEmptyState(
                title: isFiltering ? "No matching posts" : "No posts yet",
                description: isFiltering
                    ? "Try another search or change the selected tags."
                    : "Start the conversation by creating the first post.",
                systemImage: isFiltering ? "magnifyingglass" : "bubble.left.and.text.bubble.right"
            )
        } else {
            NativeForumBoardView(
                model: model,
                channel: channel,
                snapshot: boardSnapshot(channel: channel),
                headerHeight: headerHeight
            )
                .ignoresSafeArea(.container, edges: .top)
        }
    }

    private func boardSnapshot(channel: Channel) -> ForumBoardSnapshot {
        ForumBoardSnapshot(
            query: ForumBoardSnapshot.Query(
                channelID: channel.id,
                searchText: model.forumSearchText.trimmingCharacters(in: .whitespacesAndNewlines),
                tagIDs: model.forumSelectedTagIDs,
                tagMatch: model.forumTagMatch,
                sortOrder: model.forumSortOrder
            ),
            mode: model.forumLayout == .gallery ? .gallery : .list,
            posts: model.forumPosts,
            recentCount: model.forumRecentPostCount,
            showsPlaceholders: !model.hasLoadedForumPosts
                || model.isLoadingForumPosts
                || model.isSearchingForumPosts,
            isLoadingMore: model.isLoadingMoreForumPosts,
            paginationError: model.forumPaginationError,
            hasMore: model.hasMoreForumPosts
        )
    }

    private func reportPresentedForum(_ channelID: ChannelID) {
        // SwiftUI's appearance callback runs before the current display
        // transaction. Deferring one main-actor turn makes the signpost a
        // closer proxy for the first presentable forum frame.
        Task { @MainActor in
            await Task.yield()
            guard model.selectedChannelID == channelID else { return }
            AppPerformanceSignposts.reportConversationFirstFrame(
                channelID: channelID
            )
        }
    }
}

/// The forum's search, filter tags, Sort & view and New Post in one row.
/// Tags scroll sideways rather than wrap, so the header keeps one height at
/// any width and does not reflow as a side chat opens or closes.
private struct ForumBrowseHeader: View {
    let model: AppModel
    let channel: Channel
    @Binding var searchText: String
    @Binding var presentsComposer: Bool

    var body: some View {
        HStack(spacing: InterfaceScale.metric(10)) {
            // A side chat can leave the forum narrow; search gives way down
            // to a minimum, then the tags scroll in what is left.
            ForumSearchField(text: $searchText)
                .frame(minWidth: InterfaceScale.metric(100), maxWidth: InterfaceScale.metric(220))
                .layoutPriority(1)
                .onChange(of: searchText) { _, value in model.updateForumSearch(value) }
            // Each forum's tags start scrolled to the first one.
            ForumTagStrip(model: model, channel: channel)
                .id(channel.id)
            ForumSortMenu(model: model)
            ForumNewPostButton(isEnabled: model.canCreateForumPosts) { presentsComposer = true }
        }
        .padding(.horizontal, InterfaceScale.metric(14))
        .frame(height: InterfaceScale.metric(50))
    }
}

/// The forum's tags on one line, faded at whichever edge has more to scroll to.
private struct ForumTagStrip: View {
    let model: AppModel
    let channel: Channel
    @State private var fades = Fades()

    private struct Fades: Equatable {
        var leading = false
        var trailing = false
    }

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: InterfaceScale.metric(4)) {
                HStack(spacing: InterfaceScale.metric(6)) {
                    ForEach(channel.availableTags) { tag in
                        ForumTagButton(
                            tag: tag,
                            customEmojiURL: tag.emojiID.flatMap { model.customEmojiURLsByID[$0] },
                            isSelected: model.forumSelectedTagIDs.contains(tag.id)
                        ) {
                            model.toggleForumFilterTag(tag.id)
                        }
                    }
                }
            }
            // Room for the glass edges, which the scroll view would clip.
            .padding(.vertical, InterfaceScale.metric(6))
            .padding(.horizontal, InterfaceScale.metric(2))
        }
        .scrollIndicators(.never)
        .onScrollGeometryChange(for: Fades.self) { geometry in
            Fades(
                leading: geometry.contentOffset.x > 1,
                trailing: geometry.contentOffset.x + geometry.containerSize.width < geometry.contentSize.width - 1
            )
        } action: { _, value in
            fades = value
        }
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: fades.leading ? InterfaceScale.metric(24) : 0)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: fades.trailing ? InterfaceScale.metric(32) : 0)
            }
            .animation(.easeOut(duration: 0.15), value: fades)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Chip sizes shared by the header's controls.
enum ForumTagChipMetrics {
    static var height: CGFloat { InterfaceScale.metric(30) }
    static var horizontalPadding: CGFloat { InterfaceScale.metric(11) }
    static var emojiSize: CGFloat { InterfaceScale.metric(16) }
}

/// New Post, the forum's primary action.
private struct ForumNewPostButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        let label = Label("New Post", systemImage: "square.and.pencil")
        Button(action: action) {
            // Drops its title where the header is too narrow for it.
            ViewThatFits(in: .horizontal) {
                label
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
                    .padding(.horizontal, InterfaceScale.metric(13))
                label
                    .labelStyle(.iconOnly)
                    .frame(width: ForumTagChipMetrics.height)
            }
            .font(.interface(.callout).weight(.semibold))
            .foregroundStyle(.white)
            .frame(height: ForumTagChipMetrics.height)
            .glassEffect(.forumChip(isOn: true), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .pointerStyle(isEnabled ? .link : nil)
    }
}

extension Glass {
    /// Regular glass for the forum's chips; accent-tinted when one is on.
    static func forumChip(isOn: Bool) -> Glass {
        isOn ? .regular.tint(SakuraCordAccentColor.color).interactive() : .regular.interactive()
    }
}

private struct ForumSortMenu: View {
    let model: AppModel
    @State private var isHovered = false

    var body: some View {
        Image(systemName: "line.3.horizontal.decrease")
            .font(.interface(.callout).weight(.semibold))
            .frame(width: ForumTagChipMetrics.height, height: ForumTagChipMetrics.height)
            .background { if isHovered { Circle().fill(Color.primary.opacity(0.1)) } }
            .glassEffect(.regular, in: Circle())
            .contentShape(Circle())
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .pointerStyle(.link)
            .overlay {
                NativeForumSortMenuButton(
                    sortOrder: model.forumSortOrder,
                    layout: model.forumLayout,
                    tagMatch: model.forumTagMatch,
                    selectSortOrder: model.setForumSortOrder,
                    selectLayout: model.setForumLayout,
                    selectTagMatch: model.setForumTagMatch,
                    reset: model.resetForumView,
                    onHover: { isHovered = $0 }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
    }

}

private struct NativeForumSortMenuButton: NSViewRepresentable {
    let sortOrder: ForumSortOrder
    let layout: ForumLayout
    let tagMatch: ForumTagMatch
    let selectSortOrder: (ForumSortOrder) -> Void
    let selectLayout: (ForumLayout) -> Void
    let selectTagMatch: (ForumTagMatch) -> Void
    let reset: () -> Void
    let onHover: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sortOrder: sortOrder,
            layout: layout,
            tagMatch: tagMatch,
            selectSortOrder: selectSortOrder,
            selectLayout: selectLayout,
            selectTagMatch: selectTagMatch,
            reset: reset
        )
    }

    func makeNSView(context: Context) -> ForumSortMenuNSButton {
        let button = ForumSortMenuNSButton(
            title: "",
            target: context.coordinator,
            action: #selector(Coordinator.showMenu(_:))
        )
        button.onHover = onHover
        button.isBordered = false
        button.isTransparent = true
        button.focusRingType = .none
        button.setButtonType(.momentaryPushIn)
        button.toolTip = "Sort & view"
        button.setAccessibilityLabel("Sort and view options")
        button.setAccessibilityHelp("Opens forum sorting and layout options")
        return button
    }

    func updateNSView(_ nsView: ForumSortMenuNSButton, context: Context) {
        nsView.onHover = onHover
        context.coordinator.update(
            sortOrder: sortOrder,
            layout: layout,
            tagMatch: tagMatch,
            selectSortOrder: selectSortOrder,
            selectLayout: selectLayout,
            selectTagMatch: selectTagMatch,
            reset: reset
        )
    }

    @MainActor
    final class Coordinator: NSObject {
        private var sortOrder: ForumSortOrder
        private var layout: ForumLayout
        private var tagMatch: ForumTagMatch
        private var selectSortOrder: (ForumSortOrder) -> Void
        private var selectLayout: (ForumLayout) -> Void
        private var selectTagMatch: (ForumTagMatch) -> Void
        private var reset: () -> Void

        init(
            sortOrder: ForumSortOrder,
            layout: ForumLayout,
            tagMatch: ForumTagMatch,
            selectSortOrder: @escaping (ForumSortOrder) -> Void,
            selectLayout: @escaping (ForumLayout) -> Void,
            selectTagMatch: @escaping (ForumTagMatch) -> Void,
            reset: @escaping () -> Void
        ) {
            self.sortOrder = sortOrder
            self.layout = layout
            self.tagMatch = tagMatch
            self.selectSortOrder = selectSortOrder
            self.selectLayout = selectLayout
            self.selectTagMatch = selectTagMatch
            self.reset = reset
        }

        func update(
            sortOrder: ForumSortOrder,
            layout: ForumLayout,
            tagMatch: ForumTagMatch,
            selectSortOrder: @escaping (ForumSortOrder) -> Void,
            selectLayout: @escaping (ForumLayout) -> Void,
            selectTagMatch: @escaping (ForumTagMatch) -> Void,
            reset: @escaping () -> Void
        ) {
            self.sortOrder = sortOrder
            self.layout = layout
            self.tagMatch = tagMatch
            self.selectSortOrder = selectSortOrder
            self.selectLayout = selectLayout
            self.selectTagMatch = selectTagMatch
            self.reset = reset
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
            menu.addItem(sectionHeader("Sort By"))
            menu.addItem(
                option(
                    "Recently active",
                    selected: sortOrder == .latestActivity,
                    action: #selector(selectSort(_:)),
                    representedValue: ForumSortOrder.latestActivity.rawValue
                )
            )
            menu.addItem(
                option(
                    "Date posted",
                    selected: sortOrder == .creationDate,
                    action: #selector(selectSort(_:)),
                    representedValue: ForumSortOrder.creationDate.rawValue
                )
            )
            menu.addItem(.separator())
            menu.addItem(sectionHeader("View As"))
            menu.addItem(
                option(
                    "List",
                    selected: layout == .list,
                    action: #selector(selectForumLayout(_:)),
                    representedValue: ForumLayout.list.rawValue
                )
            )
            menu.addItem(
                option(
                    "Gallery",
                    selected: layout == .gallery,
                    action: #selector(selectForumLayout(_:)),
                    representedValue: ForumLayout.gallery.rawValue
                )
            )
            menu.addItem(.separator())
            menu.addItem(sectionHeader("Tag Matching"))
            menu.addItem(
                option(
                    "Match Some",
                    selected: tagMatch == .matchSome,
                    action: #selector(selectTagMatching(_:)),
                    representedValue: ForumTagMatch.matchSome.rawValue
                )
            )
            menu.addItem(
                option(
                    "Match All",
                    selected: tagMatch == .matchAll,
                    action: #selector(selectTagMatching(_:)),
                    representedValue: ForumTagMatch.matchAll.rawValue
                )
            )
            menu.addItem(.separator())
            let resetItem = NSMenuItem(
                title: "Reset to default",
                action: #selector(resetOptions),
                keyEquivalent: ""
            )
            resetItem.target = self
            resetItem.isEnabled = true
            resetItem.mixedStateImage = symbolImage("arrow.counterclockwise")
            resetItem.state = .mixed
            menu.addItem(resetItem)
            return menu
        }

        private func sectionHeader(_ title: String) -> NSMenuItem {
            let item = NSMenuItem()
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 27))
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .labelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
                label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: 1),
            ])
            label.setAccessibilityLabel(title)
            item.view = container
            return item
        }

        private func option(
            _ title: String,
            selected: Bool,
            action: Selector,
            representedValue: Any
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            item.state = selected ? .on : .off
            item.representedObject = representedValue
            return item
        }

        private func symbolImage(_ name: String) -> NSImage? {
            let image = NSImage(
                systemSymbolName: name,
                accessibilityDescription: "Reset to default"
            )
            image?.isTemplate = true
            return image
        }

        @objc private func selectSort(_ sender: NSMenuItem) {
            guard let rawValue = (sender.representedObject as? NSNumber)?.intValue,
                  let value = ForumSortOrder(rawValue: rawValue)
            else { return }
            selectSortOrder(value)
        }

        @objc private func selectForumLayout(_ sender: NSMenuItem) {
            guard let rawValue = (sender.representedObject as? NSNumber)?.intValue,
                  let value = ForumLayout(rawValue: rawValue)
            else { return }
            selectLayout(value)
        }

        @objc private func selectTagMatching(_ sender: NSMenuItem) {
            guard let rawValue = sender.representedObject as? String,
                  let value = ForumTagMatch(rawValue: rawValue)
            else { return }
            selectTagMatch(value)
        }

        @objc private func resetOptions() {
            reset()
        }
    }
}

/// The sort menu's click target sits over the SwiftUI chip, so it reports
/// hover back to the chip and shows the pointing hand itself.
final class ForumSortMenuNSButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }

    override func resetCursorRects() {
        guard WindowModalCoordinator.allowsInput(for: self) else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

struct ForumTagButton: View {
    let tag: ForumTag
    let customEmojiURL: URL?
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: InterfaceScale.metric(5)) {
                ForumTagEmoji(tag: tag, customEmojiURL: customEmojiURL, size: ForumTagChipMetrics.emojiSize)
                Text(tag.name)
                    .lineLimit(1)
            }
            .font(.interface(.callout).weight(.semibold))
            .padding(.horizontal, ForumTagChipMetrics.horizontalPadding)
            .frame(height: ForumTagChipMetrics.height)
            .glassEffect(.forumChip(isOn: isSelected), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: isSelected)
        .pointerStyle(isEnabled ? .link : nil)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(tag.isModerated ? "Only moderators can apply this tag" : "")
    }
}

private struct ForumTagEmoji: View {
    let tag: ForumTag
    let customEmojiURL: URL?
    let size: CGFloat

    var body: some View {
        if tag.emojiID != nil, let url = resolvedCustomEmojiURL {
            AnimatedRemoteImage(
                url: url,
                fallbackSystemImage: "tag",
                maximumPixelDimension: max(1, Int(((size + 4) * 2).rounded(.up))),
            )
            .frame(width: size, height: size)
            .frame(width: size + 4, height: size + 4)
        } else if let emoji = tag.emojiName, !emoji.isEmpty {
            Text(emoji)
                .font(.system(size: size * 0.9))
                .fixedSize()
                .frame(width: size + 4, height: size + 4)
        }
    }

    private var resolvedCustomEmojiURL: URL? {
        if let customEmojiURL { return customEmojiURL }
        guard let id = tag.emojiID else { return nil }
        return EmojiReference(id: id, name: tag.emojiName ?? "emoji").imageURL(size: 64)
    }
}

nonisolated enum ForumTimestampPresentation {
    static func roundedRelativeText(for date: Date, relativeTo now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60:
            return "now"
        case ..<3_600:
            return "\(max(1, seconds / 60))m ago"
        case ..<86_400:
            return "\(seconds / 3_600)h ago"
        case ..<604_800:
            return "\(seconds / 86_400)d ago"
        case ..<2_629_800:
            return "\(seconds / 604_800)w ago"
        case ..<31_557_600:
            return "\(seconds / 2_629_800)mo ago"
        default:
            return "\(seconds / 31_557_600)y ago"
        }
    }
}

nonisolated enum ForumPostReactionPresentation {
    static func displayedReaction(
        reactions: [Reaction],
        defaultReaction: ForumDefaultReaction?
    ) -> Reaction? {
        var highestCountReaction: Reaction?
        for reaction in MessageReactionPresentation.items(from: reactions) {
            if highestCountReaction == nil
                || reaction.count > (highestCountReaction?.count ?? 0)
            {
                highestCountReaction = reaction
            }
        }
        if let highestCountReaction {
            return highestCountReaction
        }
        guard let token = defaultReactionToken(defaultReaction) else { return nil }
        return Reaction(emoji: token, count: 0)
    }

    static func defaultReactionToken(_ value: ForumDefaultReaction?) -> String? {
        guard let value else { return nil }
        if let id = value.emojiID {
            return EmojiReference(id: id, name: value.emojiName ?? "emoji").rawToken
        }
        return value.emojiName
    }
}
