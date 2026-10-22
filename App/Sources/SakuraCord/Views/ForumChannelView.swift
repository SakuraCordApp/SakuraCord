import AppKit
import DiscordProtocol
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
                // Posts scroll beneath the header and the window toolbar, as
                // conversation timelines do. The header's controls need the
                // opaque edge to stay legible over moving cards.
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
                        Divider()
                    }
                    .animation(.snappy(duration: 0.25), value: model.forumActionError)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                    // The board scrolls beneath the header and toolbar; this
                    // opaque backdrop keeps both legible over moving cards.
                    .background(.background.opacity(0.94), ignoresSafeAreaEdges: .top)
                }
                .scrollEdgeEffectStyle(.hard, for: .top)
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

/// The forum's search, New Post and filter controls. Search matches the
/// app's inline search headers (Threads browser, pickers); tags wrap rather
/// than scroll, so none are cut off.
private struct ForumBrowseHeader: View {
    let model: AppModel
    let channel: Channel
    @Binding var searchText: String
    @Binding var presentsComposer: Bool
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PickerSearchHeader(text: $searchText, focus: { isSearchFocused = true }, input: {
                    TextField("Search posts", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.interfaceSystem(size: ChatChromeMetrics.pickerSearchHeaderFontSize))
                        .tint(SakuraCordAccentColor.color)
                        .focused($isSearchFocused)
                        .onExitCommand { searchText = "" }
                        .accessibilityIdentifier("forum-search")
                })
                .onChange(of: searchText) { _, value in model.updateForumSearch(value) }
                HoverActionButton(systemImage: "square.and.pencil", help: "New Post") {
                    isSearchFocused = false
                    presentsComposer = true
                }
                .disabled(!model.canCreateForumPosts)
                .pointerStyle(model.canCreateForumPosts ? .link : nil)
                .padding(.trailing, InterfaceScale.metric(9))
            }
            Divider()
            ForumFilterBar(model: model, channel: channel)
                .padding(.horizontal, InterfaceScale.metric(14))
                .padding(.vertical, InterfaceScale.metric(10))
        }
    }
}

private struct ForumFilterBar: View {
    let model: AppModel
    let channel: Channel
    @State private var isExpanded = false
    @State private var width: CGFloat = 0

    private static let collapsedRows = 2

    var body: some View {
        let tags = channel.availableTags
        let fit = ForumTagChipMetrics.visibleCount(
            tags: tags,
            leadingWidth: ForumTagChipMetrics.sortChipWidth,
            width: width,
            rows: Self.collapsedRows
        )
        let collapses = fit < tags.count
        let shown = isExpanded || !collapses ? tags[...] : tags.prefix(fit)
        ForumTagFlowLayout(spacing: ForumTagChipMetrics.spacing) {
            ForumSortMenu(model: model)
            ForEach(shown) { tag in
                ForumTagButton(
                    tag: tag,
                    customEmojiURL: tag.emojiID.flatMap { model.customEmojiURLsByID[$0] },
                    isSelected: model.forumSelectedTagIDs.contains(tag.id)
                ) {
                    model.toggleForumFilterTag(tag.id)
                }
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            if collapses {
                ForumTagOverflowButton(
                    hiddenCount: isExpanded ? 0 : tags.count - fit,
                    selectedHiddenCount: isExpanded ? 0 : tags.dropFirst(fit).count(where: { model.forumSelectedTagIDs.contains($0.id) })
                ) {
                    isExpanded.toggle()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .animation(.snappy(duration: 0.28), value: isExpanded)
        .onChange(of: channel.id) { isExpanded = false }
    }
}

/// Chip sizes known before layout, so the collapsed filter bar can decide
/// how many tags fit in its rows without measuring views.
enum ForumTagChipMetrics {
    static var height: CGFloat { InterfaceScale.metric(30) }
    static var spacing: CGFloat { InterfaceScale.metric(8) }
    static var horizontalPadding: CGFloat { InterfaceScale.metric(11) }
    static var emojiSize: CGFloat { InterfaceScale.metric(16) }
    private static var cachedFont = (scale: InterfaceScale.factor, font: makeFont())

    /// Rebuilt only when the interface size changes; chip widths are measured
    /// with it for every tag on each filter bar pass.
    static var font: NSFont {
        if cachedFont.scale != InterfaceScale.factor {
            cachedFont = (InterfaceScale.factor, makeFont())
        }
        return cachedFont.font
    }

    private static func makeFont() -> NSFont {
        .interfaceSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .semibold)
    }

    static var sortChipWidth: CGFloat {
        horizontalPadding * 2 + textWidth("Sort & view") + InterfaceScale.metric(44)
    }

    static func chipWidth(of tag: ForumTag) -> CGFloat {
        let emoji = tag.emojiID != nil || tag.emojiName?.isEmpty == false ? emojiSize + InterfaceScale.metric(5) : 0
        return ceil(horizontalPadding * 2 + emoji + textWidth(tag.name))
    }

    static func overflowWidth(hiddenCount: Int) -> CGFloat {
        ceil(horizontalPadding * 2 + textWidth("+\(hiddenCount) more") + InterfaceScale.metric(18))
    }

    /// Memoized by text and font, so repeated passes over the same tags are lookups.
    static func textWidth(_ text: String) -> CGFloat {
        NativeTimelineRowLayout.measuredTextWidth(text, font: font)
    }

    /// How many leading tags fit within `rows` wrapped rows after the sort
    /// chip, keeping room on the last row for the "+N more" chip.
    static func visibleCount(tags: [ForumTag], leadingWidth: CGFloat, width: CGFloat, rows: Int) -> Int {
        guard width > 0 else { return tags.count }
        var row = 1
        var cursorX = leadingWidth
        var fitted = 0
        for (index, tag) in tags.enumerated() {
            let chip = chipWidth(of: tag)
            let remaining = tags.count - index - 1
            let reserve = remaining > 0 && row == rows ? spacing + overflowWidth(hiddenCount: remaining) : 0
            if cursorX + spacing + chip + reserve <= width {
                cursorX += spacing + chip
                fitted += 1
            } else if row < rows {
                row += 1
                // The last row also has to hold the overflow chip.
                let lastRowReserve = remaining > 0 && row == rows ? spacing + overflowWidth(hiddenCount: remaining) : 0
                guard chip + lastRowReserve <= width else { return fitted }
                cursorX = chip
                fitted += 1
            } else {
                return fitted
            }
        }
        return fitted
    }
}

/// Wraps chips onto as many rows as they need, left to right.
private struct ForumTagFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.last.map { $0.originY + $0.height } ?? 0
        let usedWidth = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? usedWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        for row in arrange(subviews: subviews, width: bounds.width) {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.originX, y: bounds.minY + row.originY + (row.height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size)
                )
            }
        }
    }

    private struct Placement {
        let index: Int
        let originX: CGFloat
        let size: CGSize
    }

    private struct Row {
        var originY: CGFloat
        var height: CGFloat = 0
        var width: CGFloat = 0
        var items: [Placement] = []
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row(originY: 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let originX = row.items.isEmpty ? 0 : row.width + spacing
            if !row.items.isEmpty, originX + size.width > width {
                rows.append(row)
                row = Row(originY: row.originY + row.height + spacing)
                row.items.append(Placement(index: index, originX: 0, size: size))
                row.width = size.width
            } else {
                row.items.append(Placement(index: index, originX: originX, size: size))
                row.width = originX + size.width
            }
            row.height = max(row.height, size.height)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

/// A filter chip: quiet at rest, lifted on hover, accent-filled when on.
private struct ForumChipBackground: View {
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        Capsule()
            .fill(
                isSelected
                    ? AnyShapeStyle(SakuraCordAccentColor.color.opacity(isHovered ? 0.3 : 0.22))
                    : AnyShapeStyle(Color.primary.opacity(isHovered ? 0.1 : 0.06))
            )
            .overlay {
                Capsule().strokeBorder(
                    isSelected ? SakuraCordAccentColor.color.opacity(0.55) : Color.primary.opacity(isHovered ? 0.16 : 0.09),
                    lineWidth: 1
                )
            }
    }
}

private struct ForumSortMenu: View {
    let model: AppModel
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: InterfaceScale.metric(5)) {
            Image(systemName: "arrow.up.arrow.down")
            Text("Sort & view")
            Image(systemName: "chevron.down")
                .font(.interface(.caption2).weight(.bold))
        }
        .font(.interface(.callout).weight(.semibold))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, ForumTagChipMetrics.horizontalPadding)
        .frame(height: ForumTagChipMetrics.height)
        .background(ForumChipBackground(isSelected: false, isHovered: isHovered))
        .contentShape(Capsule())
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
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private struct ForumTagButton: View {
    let tag: ForumTag
    let customEmojiURL: URL?
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
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
            .background(ForumChipBackground(isSelected: isSelected, isHovered: isHovered && isEnabled))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.snappy(duration: 0.2), value: isSelected)
        .pointerStyle(isEnabled ? .link : nil)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(tag.isModerated ? "Only moderators can apply this tag" : "")
    }
}

private struct ForumTagOverflowButton: View {
    let hiddenCount: Int
    let selectedHiddenCount: Int
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: InterfaceScale.metric(4)) {
                Text(hiddenCount > 0 ? "+\(hiddenCount) more" : "Show less")
                Image(systemName: hiddenCount > 0 ? "chevron.down" : "chevron.up")
                    .font(.interface(.caption2).weight(.bold))
            }
            .font(.interface(.callout).weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, ForumTagChipMetrics.horizontalPadding)
            .frame(height: ForumTagChipMetrics.height)
            .background(ForumChipBackground(isSelected: selectedHiddenCount > 0, isHovered: isHovered))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerStyle(.link)
        .help(hiddenCount > 0 ? "Show all tags" : "Show fewer tags")
        .accessibilityLabel(hiddenCount > 0 ? "Show \(hiddenCount) more tags" : "Show fewer tags")
        .accessibilityValue(selectedHiddenCount > 0 ? "\(selectedHiddenCount) selected" : "")
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

nonisolated enum ForumPostMessageCountPresentation {
    static func count(threadMessageCount: Int) -> Int {
        max(0, threadMessageCount)
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

struct ForumPostComposerOverlay: View {
    let model: AppModel
    let channel: Channel
    @Binding var isPresented: Bool

    var body: some View {
        WindowModalOverlay(presentation: isPresented ? channel : nil, dismiss: { isPresented = false }, content: { channel, context in
            GeometryReader { geometry in
                ZStack {
                    WindowModalBackdrop(opacity: 0.48)
                    GlassEffectContainer(spacing: 0) {
                        ForumPostComposer(model: model, channel: channel, isPresented: Binding(
                            get: { isPresented },
                            set: { if !$0 { context(allowsDisabled: true) } }
                        ))
                        .environment(\.windowModalContext, context)
                        .frame(width: min(760, max(0, geometry.size.width - 48)), height: min(560, max(0, geometry.size.height - 48)))
                        .padding(InterfaceScale.metric(24))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        })
    }
}

private struct ForumPostComposer: View {
    let model: AppModel
    let channel: Channel
    @Binding var isPresented: Bool
    @State private var title = ""
    @State private var content = ""
    @State private var attachments: [ForumPostAttachment] = []
    @State private var securityScopedAttachmentURLs: Set<URL> = []
    @State private var ownedAttachmentBatches: [ComposerPromisedFileBatch] = []
    @State private var selectedTags: Set<ForumTagID> = []
    @State private var showsFileImporter = false
    @State private var showsGuidelines = false
    @State private var isSubmitting = false
    @State private var submitTask: Task<Void, Never>?
    @State private var showsEmojiPicker = false
    @State private var contentSelection: NSRange?
    @State private var selectionBeforeEmojiPicker: NSRange?
    @State private var isContentFocused = false
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            composerEditor
            if let progress = model.forumCreateProgress {
                UploadProgressView(progress: progress)
                    .padding(.horizontal, InterfaceScale.metric(18))
                    .padding(.bottom, InterfaceScale.metric(10))
            }
            Divider()
            composerFooter
        }
        .background(
            Color(nsColor: .windowBackgroundColor),
            in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(20), style: .continuous)
        )
        .overlay {
            ConcentricRectangle(cornerRadius: InterfaceScale.metric(20), style: .continuous)
                .stroke(.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: InterfaceScale.metric(24), y: 10)
        .frame(
            idealWidth: InterfaceScale.metric(760),
            maxWidth: InterfaceScale.metric(920),
            minHeight: InterfaceScale.metric(420),
            idealHeight: InterfaceScale.metric(560),
            maxHeight: InterfaceScale.metric(760)
        )
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                addAttachments(urls)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            addAttachments(urls)
            return !urls.isEmpty
        }
        .sheet(isPresented: $showsGuidelines) {
            VStack(alignment: .leading, spacing: InterfaceScale.metric(16)) {
                Text("Posting Guidelines").font(.interface(.title).bold())
                ScrollView {
                    Text(channel.topic ?? "")
                        .textSelection(.enabled)
                        .tint(SakuraCordAccentColor.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button("Done") { showsGuidelines = false }.keyboardShortcut(.defaultAction)
                }
            }.padding(InterfaceScale.metric(24)).frame(minWidth: InterfaceScale.metric(480), minHeight: InterfaceScale.metric(300))
        }
        .task {
            await Task.yield()
            isTitleFocused = true
        }
        .windowModalDismissDisabled(isSubmitting)
        .onExitCommand {
            if !isSubmitting {
                isPresented = false
            }
        }
        .onDisappear {
            submitTask?.cancel()
            submitTask = nil
            for url in securityScopedAttachmentURLs {
                url.stopAccessingSecurityScopedResource()
            }
            securityScopedAttachmentURLs.removeAll()
            for batch in ownedAttachmentBatches {
                batch.discard()
            }
            ownedAttachmentBatches.removeAll()
        }
    }

    private var composerEditor: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(14)) {
            HStack(alignment: .top, spacing: InterfaceScale.metric(14)) {
                Button("Cancel", systemImage: "xmark") { isPresented = false }
                    .labelStyle(.iconOnly)
                    .font(.interfaceSystem(size: 18, weight: .medium))
                    .frame(width: InterfaceScale.metric(38), height: InterfaceScale.metric(38))
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                    .help("Cancel")

                VStack(alignment: .leading, spacing: InterfaceScale.metric(4)) {
                    TextField("Title", text: $title)
                        .tint(SakuraCordAccentColor.color)
                        .font(.interface(.title2).weight(.bold))
                        .textFieldStyle(.plain)
                        .focused($isTitleFocused)
                        .accessibilityLabel("Title")

                    ForumPostTextEditor(
                        model: model,
                        text: $content,
                        selection: $contentSelection,
                        isFocused: $isContentFocused,
                        placeholder: "Enter a message…",
                        receiveAttachments: receiveAttachments
                    )
                    .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(210), maxHeight: .infinity)
                }

                ForumComposerAttachmentControl(
                    attachments: $attachments,
                    addAttachments: { showsFileImporter = true }
                )
            }

            HStack(spacing: InterfaceScale.metric(10)) {
                Image(systemName: "tag")
                    .symbolVariant(.none)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Post tags")
                ScrollView(.horizontal) {
                    GlassEffectContainer(spacing: InterfaceScale.metric(7)) {
                        HStack(spacing: InterfaceScale.metric(7)) {
                            ForEach(channel.availableTags) { tag in
                                ForumTagButton(
                                    tag: tag,
                                    customEmojiURL: tag.emojiID.flatMap {
                                        model.customEmojiURLsByID[$0]
                                    },
                                    isSelected: selectedTags.contains(tag.id)
                                ) {
                                    toggleTag(tag)
                                }
                                .disabled(tag.isModerated && !model.canManageForumPosts)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(InterfaceScale.metric(18))
    }

    private var composerFooter: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            Button {
                selectionBeforeEmojiPicker = contentSelection
                showsEmojiPicker.toggle()
            } label: {
                SakuraCordSystemSymbol.emojiFaceGrinningImage
                    .environment(\.symbolVariants, .none)
                    .symbolRenderingMode(.monochrome)
                    .font(.interfaceSystem(size: 18, weight: .regular))
                    .frame(width: InterfaceScale.metric(28), height: InterfaceScale.metric(28))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose emoji")
            .accessibilityLabel("Emoji")
            .background {
                StableReactionPickerPresenter(
                    isPresented: $showsEmojiPicker,
                    preferredEdge: .maxY,
                    accessibilityIdentifier: "forum-post-emoji-picker"
                ) {
                    EmojiPickerView(
                        model: model,
                        allowsPersistentSelection: true,
                        dismiss: { showsEmojiPicker = false },
                        select: { activation in
                            insertEmoji(activation)
                        }
                    )
                }
                .frame(width: InterfaceScale.metric(28), height: InterfaceScale.metric(28))
            }

            Spacer()

            if let error = model.forumActionError {
                Text(error)
                    .font(.interface(.caption))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .accessibilityLabel("Post failed: \(error)")
            }
            if channel.requiresForumTag, selectedTags.isEmpty {
                Text("A tag is required")
                    .font(.interface(.caption).weight(.medium))
                    .foregroundStyle(.red)
                    .accessibilityLabel("A tag is required before posting")
            }
            if let topic = channel.topic, !topic.isEmpty {
                Button("Guidelines…", systemImage: "checklist") { showsGuidelines = true }
                    .buttonStyle(.bordered)
                    .help("View posting guidelines")
            }
            Button("Post", systemImage: "paperplane") { submit() }
                .buttonStyle(.borderedProminent)
                .tint(SakuraCordAccentColor.color)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isSubmitting || model.guildTimeoutUntil(in: channel.id) != nil)
        }
        .controlSize(.large)
        .padding(.horizontal, InterfaceScale.metric(18))
        .padding(.vertical, InterfaceScale.metric(14))
    }

    private func addAttachments(_ urls: [URL]) {
        Task { await addCheckedAttachments(urls) }
    }

    /// Adds pasted files; pasted data stays in app-owned storage until the
    /// composer closes, since these attachments are not held by the model.
    private func receiveAttachments(_ incoming: ComposerIncomingAttachments) {
        switch incoming {
        case let .external(urls):
            addAttachments(urls)
        case let .owned(batch):
            ownedAttachmentBatches.append(batch)
            Task {
                await addCheckedAttachments(batch.urls)
                let attachedURLs = Set(attachments.map(\.url))
                guard !batch.urls.contains(where: attachedURLs.contains) else { return }
                batch.discard()
                ownedAttachmentBatches.removeAll { $0.directory == batch.directory }
            }
        }
    }

    private func addCheckedAttachments(_ urls: [URL]) async {
        let existingURLs = Set(attachments.map(\.url))
        let urls = model.uploadableFileURLs(urls.filter { !existingURLs.contains($0) })
        guard model.attachmentBatchFits(urls.count, besides: attachments.count) else { return }
        let allowedURLs = await model.attachmentURLsWithinDiscordLimit(urls)
        let currentURLs = Set(attachments.map(\.url))
        let addedURLs = allowedURLs.filter { !currentURLs.contains($0) }
        guard model.attachmentBatchFits(addedURLs.count, besides: attachments.count) else { return }
        for url in addedURLs
            where !securityScopedAttachmentURLs.contains(url)
            && url.startAccessingSecurityScopedResource()
        {
            securityScopedAttachmentURLs.insert(url)
        }
        attachments.append(
            contentsOf: addedURLs.map { ForumPostAttachment(url: $0).applyingFilenamePrivacy(model.privacySafetySettings.anonymisesFileNames) }
        )
    }

    private func toggleTag(_ tag: ForumTag) {
        guard !tag.isModerated || model.canManageForumPosts else { return }
        if selectedTags.contains(tag.id) {
            selectedTags.remove(tag.id)
        } else if selectedTags.count < 5 {
            selectedTags.insert(tag.id)
        }
    }

    private func insertEmoji(_ activation: EmojiPickerActivation) {
        let insertedText: String
        switch activation.selection {
        case .native(let value):
            insertedText = value
        case .custom(let emoji):
            ComposerEmojiImageStore.shared.register(emoji)
            insertedText = model.composerText(for: emoji)
        }
        let edit = ComposerDraftEditing.insert(
            insertedText,
            into: content,
            replacing: selectionBeforeEmojiPicker ?? contentSelection
        )
        content = edit.text
        contentSelection = edit.selection
        selectionBeforeEmojiPicker = edit.selection
        isContentFocused = true
        if !activation.keepsPickerPresented {
            showsEmojiPicker = false
        }
    }

    private var isValid: Bool {
        let titleCount = title.trimmingCharacters(in: .whitespacesAndNewlines).count
        return (1 ... 100).contains(titleCount)
            && content.count <= 2_000
            && (!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty)
            && (!channel.requiresForumTag || !selectedTags.isEmpty)
            && selectedTags.count <= 5 && attachments.count <= 10
    }

    private func submit() {
        guard isValid else { return }
        isSubmitting = true
        submitTask = Task {
            let didCreate = await model.createForumPost(
                CreateForumPostDraft(
                    channelID: channel.id,
                    title: title,
                    content: content,
                    attachments: attachments,
                    appliedTagIDs: Array(selectedTags),
                    autoArchiveDuration: channel.defaultAutoArchiveDuration ?? 4_320
                )
            )
            guard !Task.isCancelled else { return }
            isSubmitting = false
            if didCreate {
                submitTask = nil
                isPresented = false
            }
        }
    }
}
