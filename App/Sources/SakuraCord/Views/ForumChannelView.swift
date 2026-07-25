import AppKit
import SakuraCordModels
import SwiftUI
import UniformTypeIdentifiers

struct ForumChannelView: View {
    let model: AppModel
    @Binding var presentsComposer: Bool
    @State private var searchText = ""

    var body: some View {
        if let channel = model.selectedChannel {
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
                }
                Divider()
                forumContent(channel: channel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onChange(of: channel.id) {
                searchText = model.forumSearchText
            }
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
        } else if model.isLoadingForumPosts, model.forumPosts.isEmpty {
            ForumLoadingView()
        } else if !model.hasLoadedForumPosts {
            Color.clear
        } else if let error = model.forumPostError, model.forumPosts.isEmpty {
            ContentUnavailableView(
                "Forum could not be loaded", systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
            .overlay(alignment: .bottom) {
                Button("Try Again") { model.reloadForumPosts() }.padding(24)
            }
        } else if model.forumPosts.isEmpty, model.isSearchingForumPosts {
            ForumSearchingState()
        } else if model.forumPosts.isEmpty {
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
            ForumPostCollection(model: model, channel: channel)
        }
    }
}

private struct ForumPostCollection: View {
    let model: AppModel
    let channel: Channel

    var body: some View {
        ScrollView {
            if model.forumLayout == .gallery {
                galleryContent
            } else {
                listContent
            }
        }
    }

    private var listContent: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForumListPostSection(
                model: model,
                channel: channel,
                posts: model.forumRecentPosts,
                lastDisplayedPostID: lastDisplayedPostID
            )
            olderPostsHeader
            ForumListPostSection(
                model: model,
                channel: channel,
                posts: model.forumOlderPosts,
                lastDisplayedPostID: lastDisplayedPostID
            )
            paginationStatus
        }
        .padding(14)
    }

    private var galleryContent: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForumGalleryPostSection(
                model: model,
                channel: channel,
                posts: model.forumRecentPosts,
                lastDisplayedPostID: lastDisplayedPostID
            )
            olderPostsHeader
            ForumGalleryPostSection(
                model: model,
                channel: channel,
                posts: model.forumOlderPosts,
                lastDisplayedPostID: lastDisplayedPostID
            )
            paginationStatus
        }
        .padding(14)
    }

    @ViewBuilder
    private var olderPostsHeader: some View {
        if !model.forumOlderPosts.isEmpty {
            Text("Older Posts")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
                .padding(.top, model.forumRecentPosts.isEmpty ? 0 : 12)
        }
    }

    @ViewBuilder
    private var paginationStatus: some View {
        ForumPaginationStatusView(
            isLoading: model.isLoadingMoreForumPosts,
            errorMessage: model.forumPaginationError
        ) {
            Task { await model.loadMoreForumPosts() }
        }
    }

    private var lastDisplayedPostID: ChannelID? {
        model.forumOlderPosts.last?.id ?? model.forumRecentPosts.last?.id
    }

}

private struct ForumPaginationStatusView: View {
    let isLoading: Bool
    let errorMessage: String?
    let retry: () -> Void

    @ViewBuilder
    var body: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding()
        } else if let errorMessage {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Couldn’t load more posts")
                        .font(.callout.weight(.semibold))
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button("Try Again", action: retry)
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
        }
    }
}

private struct ForumListPostSection: View {
    let model: AppModel
    let channel: Channel
    let posts: ArraySlice<ForumPost>
    let lastDisplayedPostID: ChannelID?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(posts) { post in
                ForumListPostCard(model: model, channel: channel, post: post)
                    .onAppear {
                        guard post.id == lastDisplayedPostID, model.hasMoreForumPosts else { return }
                        Task { await model.loadMoreForumPosts() }
                    }
            }
        }
    }
}

private struct ForumGalleryPostSection: View {
    let model: AppModel
    let channel: Channel
    let posts: ArraySlice<ForumPost>
    let lastDisplayedPostID: ChannelID?

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 320), spacing: 12)],
            spacing: 12
        ) {
            ForEach(posts) { post in
                ForumGalleryPostCard(model: model, channel: channel, post: post)
                    .onAppear {
                        guard post.id == lastDisplayedPostID, model.hasMoreForumPosts else { return }
                        Task { await model.loadMoreForumPosts() }
                    }
            }
        }
    }
}

private struct ForumBrowseHeader: View {
    let model: AppModel
    let channel: Channel
    @Binding var searchText: String
    @Binding var presentsComposer: Bool
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search posts", text: $searchText)
                            .textFieldStyle(.plain)
                            .focused($isSearchFocused)
                            .onChange(of: searchText) { _, value in model.updateForumSearch(value) }
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .contentShape(Rectangle())
                    .glassEffect(
                        .regular.interactive(),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .simultaneousGesture(TapGesture().onEnded { isSearchFocused = true })

                    Button {
                        isSearchFocused = false
                        presentsComposer = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 48, height: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        .regular.interactive(),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .disabled(!model.canCreateForumPosts)
                    .help("New Post")
                    .accessibilityLabel("New Post")
                }
            }

            HStack(spacing: 10) {
                ForumSortMenu(model: model)
                Divider().frame(height: 24)
                ScrollView(.horizontal) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(channel.availableTags) { tag in
                                ForumTagButton(
                                    tag: tag,
                                    customEmojiURL: tag.emojiID.flatMap {
                                        model.customEmojiURLsByID[$0]
                                    },
                                    isSelected: model.forumSelectedTagIDs.contains(tag.id)
                                ) {
                                    if model.forumSelectedTagIDs.contains(tag.id) {
                                        model.forumSelectedTagIDs.remove(tag.id)
                                    } else {
                                        model.forumSelectedTagIDs.insert(tag.id)
                                    }
                                    model.reloadForumPosts()
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(14)
    }
}

private struct ForumSortMenu: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.up.arrow.down")
            Text("Sort & view")
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
        }
        .font(.callout.weight(.semibold))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .contentShape(Capsule())
        .glassEffect(.regular.interactive(), in: Capsule())
        .overlay {
            NativeForumSortMenuButton(
                sortOrder: model.forumSortOrder,
                layout: model.forumLayout,
                tagMatch: model.forumTagMatch,
                selectSortOrder: selectSort,
                selectLayout: { model.forumLayout = $0 },
                selectTagMatch: selectTagMatch,
                reset: resetToDefault
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func selectSort(_ value: ForumSortOrder) {
        guard model.forumSortOrder != value else { return }
        model.forumSortOrder = value
        model.reloadForumPosts()
    }

    private func selectTagMatch(_ value: ForumTagMatch) {
        guard model.forumTagMatch != value else { return }
        model.forumTagMatch = value
        model.reloadForumPosts()
    }

    private func resetToDefault() {
        model.forumSortOrder = model.selectedChannel?.defaultSortOrder ?? .latestActivity
        let layout = model.selectedChannel?.defaultForumLayout ?? .list
        model.forumLayout = layout == .defaultLayout ? .list : layout
        model.forumTagMatch = model.selectedChannel?.defaultTagMatch ?? .matchSome
        model.forumSelectedTagIDs = []
        model.reloadForumPosts()
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

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: "",
            target: context.coordinator,
            action: #selector(Coordinator.showMenu(_:))
        )
        button.isBordered = false
        button.isTransparent = true
        button.focusRingType = .none
        button.setButtonType(.momentaryPushIn)
        button.setAccessibilityLabel("Sort and view options")
        button.setAccessibilityHelp("Opens forum sorting and layout options")
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
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

private struct ForumTagButton: View {
    let tag: ForumTag
    let customEmojiURL: URL?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                ForumTagEmoji(tag: tag, customEmojiURL: customEmojiURL, size: 16)
                Text(tag.name)
            }
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            isSelected
                ? .regular.tint(Color.accentColor.opacity(0.28)).interactive()
                : .regular.interactive(),
            in: Capsule()
        )
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
                maximumPixelDimension: max(1, Int(((size + 4) * 2).rounded(.up)))
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

private enum ForumPostCardMetrics {
    static let cornerRadius: CGFloat = 14
    static let listAttachmentSize: CGFloat = 92
    static let galleryCardHeight: CGFloat = 390
    static let galleryHeroHeight: CGFloat = 238
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

private struct ForumTimestampLabel: View {
    let date: Date
    let exactPrefix: String
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(ForumTimestampPresentation.roundedRelativeText(for: date, relativeTo: context.date))
                .contentShape(Rectangle())
        }
        .onTapGesture(perform: open)
        .onHover { isHovering = $0 }
        .nativeHoverPopover(isPresented: $isHovering) {
            Text("\(exactPrefix) \(date.formatted(date: .complete, time: .shortened))")
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .accessibilityHidden(true)
        }
        .accessibilityLabel(
            "\(exactPrefix) \(date.formatted(date: .complete, time: .shortened))"
        )
    }
}

private struct ForumListPostCard: View {
    let model: AppModel
    let channel: Channel
    let post: ForumPost

    var body: some View {
        ForumPostCardChrome(model: model, channel: channel, post: post) {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 10) {
                    ForumPostStatusRow(model: model, channel: channel, post: post)
                        .padding(.trailing, attachmentTrailingInset)
                        .allowsHitTesting(false)

                    VStack(alignment: .leading, spacing: 7) {
                        Text(post.thread.name)
                            .font(
                                .title3.weight(
                                    model.isChannelUnread(post.id) ? .bold : .semibold
                                )
                            )
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        if let previewMessage, !previewMessage.content.isEmpty {
                            Text(.init(previewMessage.content))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.trailing, attachmentTrailingInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)

                    ForumPostListFooter(model: model, channel: channel, post: post)
                }

                if let attachment = post.firstMessage?.attachments.first {
                    ForumPostListAttachment(attachment: attachment)
                        .allowsHitTesting(false)
                }
            }
            .padding(14)
        }
    }

    private var previewMessage: Message? {
        post.mostRecentMessage ?? post.firstMessage
    }

    private var attachmentTrailingInset: CGFloat {
        post.firstMessage?.attachments.first == nil
            ? 0
            : ForumPostCardMetrics.listAttachmentSize + 14
    }
}

private struct ForumPostListAttachment: View {
    let attachment: Attachment

    var body: some View {
        ForumPostAttachmentPreview(
            attachment: attachment,
            maximumPixelDimension: Int(ForumPostCardMetrics.listAttachmentSize * 2)
        )
        .frame(
            width: ForumPostCardMetrics.listAttachmentSize,
            height: ForumPostCardMetrics.listAttachmentSize
        )
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(.separator.opacity(0.6), lineWidth: 1)
        }
    }
}

private struct ForumGalleryPostCard: View {
    let model: AppModel
    let channel: Channel
    let post: ForumPost

    var body: some View {
        ForumPostCardChrome(model: model, channel: channel, post: post) {
            VStack(alignment: .leading, spacing: 9) {
                ForumGalleryPostHeader(model: model, post: post)

                Text(post.thread.name)
                    .font(
                        .title3.weight(
                            model.isChannelUnread(post.id) ? .bold : .semibold
                        )
                    )
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                    .allowsHitTesting(false)

                ForumPostGalleryHero(model: model, channel: channel, post: post)
                    .allowsHitTesting(false)

                ForumPostGalleryFooter(model: model, channel: channel, post: post)
            }
            .padding(14)
            .frame(height: ForumPostCardMetrics.galleryCardHeight, alignment: .top)
        }
    }
}

private struct ForumGalleryPostHeader: View {
    let model: AppModel
    let post: ForumPost

    var body: some View {
        HStack(spacing: 7) {
            ForumTimestampLabel(
                date: post.createdAt,
                exactPrefix: "Posted",
                open: { model.open(post) }
            )
            Spacer(minLength: 6)
            if post.thread.isPinned {
                Image(systemName: "pin.fill").help("Pinned post")
            }
            if post.thread.isLocked {
                Image(systemName: "lock.fill").help("Locked post")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct ForumPostGalleryHero: View {
    let model: AppModel
    let channel: Channel
    let post: ForumPost

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.07))

            if let attachment = post.firstMessage?.attachments.first {
                ForumPostAttachmentPreview(attachment: attachment, maximumPixelDimension: 1_280)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let previewMessage, !previewMessage.content.isEmpty {
                Text(.init(previewMessage.content))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
            } else {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.72)],
                startPoint: .center,
                endPoint: .bottom
            )
            .frame(height: 72)

            ForumPostAppliedTags(
                model: model,
                channel: channel,
                post: post,
                maximumVisibleTags: 3
            )
            .padding(10)
        }
        .frame(height: ForumPostCardMetrics.galleryHeroHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator.opacity(0.65), lineWidth: 1)
        }
    }

    private var previewMessage: Message? {
        post.mostRecentMessage ?? post.firstMessage
    }
}

private struct ForumPostStatusRow: View {
    let model: AppModel
    let channel: Channel
    let post: ForumPost

    var body: some View {
        HStack(spacing: 7) {
            if model.isChannelUnread(post.id) {
                Circle().fill(Color.accentColor).frame(width: 8, height: 8)
            }
            if post.thread.isPinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.secondary)
                    .help("Pinned post")
            }
            if post.thread.isLocked {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help("Locked post")
            }
            ForumPostAppliedTags(model: model, channel: channel, post: post)
            Spacer(minLength: 6)
        }
    }
}

private struct ForumPostAppliedTags: View {
    let model: AppModel
    let channel: Channel
    let post: ForumPost
    var maximumVisibleTags = 5

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(appliedTags.prefix(maximumVisibleTags)) { tag in
                    HStack(spacing: 4) {
                        ForumTagEmoji(
                            tag: tag,
                            customEmojiURL: tag.emojiID.flatMap { model.customEmojiURLsByID[$0] },
                            size: 13
                        )
                        Text(tag.name).lineLimit(1)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .glassEffect(.regular, in: Capsule())
                }
                if appliedTags.count > maximumVisibleTags {
                    Text("+\(appliedTags.count - maximumVisibleTags)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .glassEffect(.regular, in: Capsule())
                }
            }
        }
    }

    private var appliedTags: [ForumTag] {
        channel.availableTags.filter { post.thread.appliedTagIDs.contains($0.id) }
    }
}

private struct ForumPostListFooter: View {
    let model: AppModel
    let channel: Channel
    let post: ForumPost

    var body: some View {
        HStack(spacing: 12) {
            ForumPostDefaultReactionPill(model: model, channel: channel, post: post)
            Label("\(post.replyCount)", systemImage: "bubble.left.fill")
                .allowsHitTesting(false)
            ForumTimestampLabel(
                date: post.lastActivityAt,
                exactPrefix: "Last activity",
                open: { model.open(post) }
            )
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct ForumPostGalleryFooter: View {
    let model: AppModel
    let channel: Channel
    let post: ForumPost

    var body: some View {
        HStack(spacing: 10) {
            Label("\(post.replyCount)", systemImage: "bubble.left.fill")
                .allowsHitTesting(false)
            Spacer()
            ForumPostDefaultReactionPill(model: model, channel: channel, post: post)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

private struct ForumPostDefaultReactionPill: View {
    let model: AppModel
    let channel: Channel
    let post: ForumPost

    var body: some View {
        if let reaction = displayedDefaultReaction {
            MessageReactionPill(
                reaction: reaction,
                emojiURL: MessageReactionPresentation.emojiURL(
                    for: reaction,
                    customEmojiURLsByID: model.customEmojiURLsByID
                ),
                react: toggleDefaultReaction,
                loadReactors: loadDefaultReactionReactors
            )
            .fixedSize()
        }
    }

    private var displayedDefaultReaction: Reaction? {
        guard let firstMessage = post.firstMessage, let token = defaultReactionToken else {
            return nil
        }
        let reference = EmojiReference(rawToken: token)
        return firstMessage.reactions.first { existing in
            let existingReference = existing.emojiReference
            if let id = reference.id { return existingReference.id == id }
            return existingReference.id == nil && existingReference.name == reference.name
        } ?? Reaction(emoji: token, count: 0)
    }

    private var defaultReactionToken: String? {
        guard let value = channel.defaultReaction else { return nil }
        if let id = value.emojiID {
            return EmojiReference(id: id, name: value.emojiName ?? "emoji").rawToken
        }
        return value.emojiName
    }

    private func toggleDefaultReaction() {
        guard let message = post.firstMessage, let reaction = displayedDefaultReaction else {
            return
        }
        Task { await model.toggleReaction(reaction.emoji, on: message) }
    }

    private func loadDefaultReactionReactors() async {
        guard let message = post.firstMessage, let reaction = displayedDefaultReaction else {
            return
        }
        await model.loadReactionReactors(reaction, on: message)
    }
}

private struct ForumPostCardChrome<Content: View>: View {
    let model: AppModel
    let channel: Channel
    let post: ForumPost
    let content: Content
    @State private var isDeleteConfirmationPresented = false

    init(
        model: AppModel,
        channel: Channel,
        post: ForumPost,
        @ViewBuilder content: () -> Content
    ) {
        self.model = model
        self.channel = channel
        self.post = post
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                Button {
                    model.open(post)
                } label: {
                    RoundedRectangle(
                        cornerRadius: ForumPostCardMetrics.cornerRadius,
                        style: .continuous
                    )
                    .fill(
                        model.openThread?.id == post.id
                            ? Color.primary.opacity(0.055)
                            : Color.clear
                    )
                    .contentShape(
                        RoundedRectangle(
                            cornerRadius: ForumPostCardMetrics.cornerRadius,
                            style: .continuous
                        )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(post.thread.name)
                .accessibilityHint("Opens this post as a thread")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                RoundedRectangle(
                    cornerRadius: ForumPostCardMetrics.cornerRadius,
                    style: .continuous
                )
                .stroke(
                    model.openThread?.id == post.id
                        ? Color.primary.opacity(0.24)
                        : Color(nsColor: .separatorColor),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            }
            .overlay {
                let canManage = model.canManageForumPosts
                let canArchive = model.canArchiveForumPost(post)
                let canEditTags = model.canEditForumPostTags(post)
                let canDelete = model.canDeleteForumPost(post)
                ForumPostContextMenuBridge(
                    tags: channel.availableTags,
                    appliedTagIDs: post.thread.appliedTagIDs,
                    customEmojiURLsByID: model.customEmojiURLsByID,
                    isArchived: post.thread.isArchived,
                    isLocked: post.thread.isLocked,
                    isPinned: post.thread.isPinned,
                    requiresTag: channel.requiresForumTag,
                    canManage: canManage,
                    canArchive: canArchive,
                    canEditTags: canEditTags,
                    canDelete: canDelete,
                    open: {
                        model.open(post)
                    },
                    copyLink: copyForumPostLink,
                    copyThreadID: {
                        copyToPasteboard(post.id.description)
                    },
                    toggleTag: toggleTag,
                    toggleArchive: {
                        Task {
                            await model.updateForumPost(
                                post, mutation: .archived(!post.thread.isArchived)
                            )
                        }
                    },
                    toggleLock: {
                        Task {
                            await model.updateForumPost(
                                post, mutation: .locked(!post.thread.isLocked)
                            )
                        }
                    },
                    togglePin: {
                        Task {
                            await model.updateForumPost(
                                post, mutation: .pinned(!post.thread.isPinned)
                            )
                        }
                    },
                    delete: {
                        isDeleteConfirmationPresented = true
                    }
                )
            }
            .contentShape(
                RoundedRectangle(
                    cornerRadius: ForumPostCardMetrics.cornerRadius,
                    style: .continuous
                )
            )
            .accessibilityElement(children: .contain)
            .confirmationDialog(
                "Delete this post?",
                isPresented: $isDeleteConfirmationPresented
            ) {
                Button("Delete Post", role: .destructive) {
                    Task { await model.deleteForumPost(post) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete the post and all of its replies.")
            }
    }

    private func copyForumPostLink() {
        copyToPasteboard(
            ForumPostContextValue.link(
                guildID: post.thread.guildID ?? channel.guildID ?? model.selectedGuildID,
                threadID: post.id
            )
        )
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func toggleTag(_ tagID: ForumTagID) {
        guard let tag = channel.availableTags.first(where: { $0.id == tagID }),
              model.canToggleForumTag(tag, on: post)
        else { return }
        var tags = Set(post.thread.appliedTagIDs)
        if tags.contains(tagID) {
            tags.remove(tagID)
        } else if tags.count < 5 {
            tags.insert(tagID)
        }
        Task { await model.updateForumPost(post, mutation: .tags(Array(tags))) }
    }
}

nonisolated enum ForumPostContextValue {
    static func link(guildID: GuildID?, threadID: ChannelID) -> String {
        let guild = guildID?.description ?? "@me"
        return "https://discord.com/channels/\(guild)/\(threadID)"
    }
}

struct ForumPostComposerOverlay: View {
    let model: AppModel
    let channel: Channel
    @Binding var isPresented: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.48)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())

                GlassEffectContainer(spacing: 0) {
                    ForumPostComposer(
                        model: model,
                        channel: channel,
                        isPresented: $isPresented
                    )
                    .frame(
                        width: min(760, max(0, geometry.size.width - 48)),
                        height: min(560, max(0, geometry.size.height - 48))
                    )
                    .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .zIndex(1_000)
        .accessibilityAddTraits(.isModal)
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
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
            }
            Divider()
            composerFooter
        }
        .background(
            Color(nsColor: .windowBackgroundColor),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
        .frame(
            idealWidth: 760,
            maxWidth: 920,
            minHeight: 420,
            idealHeight: 560,
            maxHeight: 760
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
            VStack(alignment: .leading, spacing: 16) {
                Text("Posting Guidelines").font(.title.bold())
                ScrollView {
                    Text(channel.topic ?? "").textSelection(.enabled).frame(
                        maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button("Done") { showsGuidelines = false }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(minWidth: 480, minHeight: 300)
        }
        .task {
            await Task.yield()
            isTitleFocused = true
        }
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
        }
    }

    private var composerEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Button("Cancel", systemImage: "xmark") { isPresented = false }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                    .help("Cancel")

                VStack(alignment: .leading, spacing: 4) {
                    TextField("Title", text: $title)
                        .font(.title2.weight(.bold))
                        .textFieldStyle(.plain)
                        .focused($isTitleFocused)
                        .accessibilityLabel("Title")

                    ForumPostTextEditor(
                        model: model,
                        text: $content,
                        selection: $contentSelection,
                        isFocused: $isContentFocused,
                        placeholder: "Enter a message…"
                    )
                    .frame(maxWidth: .infinity, minHeight: 210, maxHeight: .infinity)
                }

                ForumComposerAttachmentControl(
                    attachments: $attachments,
                    addAttachments: { showsFileImporter = true }
                )
            }

            HStack(spacing: 10) {
                Image(systemName: "tag")
                    .symbolVariant(.none)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Post tags")
                ScrollView(.horizontal) {
                    GlassEffectContainer(spacing: 7) {
                        HStack(spacing: 7) {
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
        .padding(18)
    }

    private var composerFooter: some View {
        HStack(spacing: 8) {
            Button {
                selectionBeforeEmojiPicker = contentSelection
                showsEmojiPicker.toggle()
            } label: {
                Image(systemName: "face.smiling.inverse")
                    .environment(\.symbolVariants, .none)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 18, weight: .regular))
                    .frame(width: 28, height: 28)
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
                    EmojiPickerView(model: model, allowsPersistentSelection: true) { activation in
                        insertEmoji(activation)
                    }
                    .onExitCommand { showsEmojiPicker = false }
                }
                .frame(width: 28, height: 28)
            }

            Spacer()

            if let error = model.forumActionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .accessibilityLabel("Post failed: \(error)")
            }
            if channel.requiresForumTag, selectedTags.isEmpty {
                Text("A tag is required")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .accessibilityLabel("A tag is required before posting")
            }
            if let topic = channel.topic, !topic.isEmpty {
                Button("Guidelines", systemImage: "checklist") { showsGuidelines = true }
                    .buttonStyle(.bordered)
                    .help("View posting guidelines")
            }
            Button("Post", systemImage: "paperplane") { submit() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isSubmitting)
        }
        .controlSize(.large)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func addAttachments(_ urls: [URL]) {
        let count = max(0, 10 - attachments.count)
        let existingURLs = Set(attachments.map(\.url))
        let uniqueURLs = urls.filter { !existingURLs.contains($0) }
        let addedURLs = Array(uniqueURLs.prefix(count))
        for url in addedURLs
            where !securityScopedAttachmentURLs.contains(url)
            && url.startAccessingSecurityScopedResource()
        {
            securityScopedAttachmentURLs.insert(url)
        }
        attachments.append(
            contentsOf: addedURLs.map { ForumPostAttachment(url: $0) }
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

private enum ForumAttachmentTrayCoordinateSpace {
    static let name = "forum-composer-attachment-tray"
}

private struct ForumAttachmentFramePreferenceKey: PreferenceKey {
    static var defaultValue: [URL: CGRect] = [:]

    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct ForumComposerAttachmentControl: View {
    @Binding var attachments: [ForumPostAttachment]
    let addAttachments: () -> Void
    @State private var editingTarget: ForumAttachmentEditorTarget?
    @State private var isExpanded = false
    @State private var scrollTarget: URL?
    @State private var hoveredAttachmentURL: URL?
    @State private var attachmentFrames: [URL: CGRect] = [:]
    @State private var attachmentThumbnails: [URL: NSImage] = [:]
    @State private var isHoveringAttachmentActions = false
    @State private var hoverDismissalTask: Task<Void, Never>?

    private let tileSize: CGFloat = 78
    private let traySpacing: CGFloat = 8
    private let trayInset: CGFloat = 8
    private let maximumExpandedWidth: CGFloat = 440
    private let hoverPillWidth: CGFloat = 68

    var body: some View {
        Color.clear
            .frame(width: tileSize, height: tileSize)
            .overlay(alignment: .topTrailing) {
                if attachments.isEmpty {
                    addAttachmentButton
                } else {
                    attachmentTray
                }
            }
            .overlay(alignment: .topTrailing) {
                if attachments.count > 1, !isExpanded {
                    attachmentCountBadge
                        .offset(x: 5, y: -5)
                        .allowsHitTesting(false)
                }
            }
            .zIndex(20)
            .sheet(item: $editingTarget) { target in
                if let attachment = attachments.first(where: { $0.url == target.id }) {
                    ForumAttachmentEditor(
                        attachment: attachment,
                        cancel: { editingTarget = nil },
                        save: { updated in
                            guard let index = attachments.firstIndex(where: { $0.url == target.id }) else {
                                editingTarget = nil
                                return
                            }
                            attachments[index] = updated
                            editingTarget = nil
                        }
                    )
                }
            }
            .onDisappear {
                hoverDismissalTask?.cancel()
            }
    }

    private var itemCount: Int {
        attachments.count
    }

    private var attachmentContentWidth: CGFloat {
        CGFloat(itemCount) * tileSize + CGFloat(max(0, itemCount - 1)) * traySpacing
    }

    private var pinnedAddButtonWidth: CGFloat {
        attachments.count < 10 ? tileSize + traySpacing : 0
    }

    private var expandedAttachmentViewportWidth: CGFloat {
        min(
            attachmentContentWidth,
            maximumExpandedWidth - (trayInset * 2) - pinnedAddButtonWidth
        )
    }

    private var expandedWidth: CGFloat {
        (trayInset * 2) + expandedAttachmentViewportWidth + pinnedAddButtonWidth
    }

    private var currentWidth: CGFloat {
        isExpanded ? expandedWidth : tileSize
    }

    private var currentHeight: CGFloat {
        isExpanded ? tileSize + (trayInset * 2) : tileSize
    }

    private var attachmentCountBadge: some View {
        Text("\(attachments.count)")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background {
                Circle().fill(Color.accentColor)
            }
            .overlay {
                Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)
            }
            .accessibilityLabel("\(attachments.count) attachments")
    }

    private var attachmentTray: some View {
        HStack(spacing: traySpacing) {
            attachmentScrollView

            if isExpanded, attachments.count < 10 {
                addAttachmentButton
                    .onHover { hovering in
                        if hovering {
                            clearHoveredAttachment()
                        }
                    }
            }
        }
        .padding(isExpanded ? trayInset : 0)
        .frame(width: currentWidth, height: currentHeight, alignment: .trailing)
        .background {
            if isExpanded {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.separator, lineWidth: 1)
                    }
            }
        }
        .coordinateSpace(name: ForumAttachmentTrayCoordinateSpace.name)
        .onPreferenceChange(ForumAttachmentFramePreferenceKey.self) {
            attachmentFrames = $0
        }
        .overlay(alignment: .topLeading) {
            hoveredAttachmentActions
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onHover { hovering in
            isExpanded = hovering
            if !hovering {
                clearHoveredAttachment()
                scrollTarget = attachments.first?.url
            }
        }
        .offset(
            x: isExpanded ? trayInset : 0,
            y: isExpanded ? -trayInset : 0
        )
    }

    private var attachmentScrollView: some View {
        ScrollView(.horizontal) {
            HStack(spacing: traySpacing) {
                ForEach(attachments, id: \.url) { attachment in
                    attachmentTile(attachment)
                        .id(attachment.url)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ForumAttachmentFramePreferenceKey.self,
                                    value: [
                                        attachment.url: proxy.frame(
                                            in: .named(ForumAttachmentTrayCoordinateSpace.name)
                                        )
                                    ]
                                )
                            }
                        }
                }
            }
        }
        .scrollPosition(id: $scrollTarget, anchor: .leading)
        .scrollIndicators(.hidden)
        .scrollDisabled(!isExpanded || attachmentContentWidth <= expandedAttachmentViewportWidth)
        .frame(
            width: isExpanded ? expandedAttachmentViewportWidth : tileSize,
            height: tileSize
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onChange(of: isExpanded) { _, expanded in
            if !expanded {
                scrollTarget = attachments.first?.url
            }
        }
    }

    @ViewBuilder
    private var hoveredAttachmentActions: some View {
        if isExpanded,
           let url = hoveredAttachmentURL,
           let attachment = attachments.first(where: { $0.url == url }),
           let frame = attachmentFrames[url]
        {
            attachmentActions(for: attachment)
                .frame(width: hoverPillWidth)
                .offset(
                    x: frame.maxX - hoverPillWidth + 8,
                    y: frame.minY - 8
                )
                .onHover { hovering in
                    isHoveringAttachmentActions = hovering
                    if hovering {
                        hoverDismissalTask?.cancel()
                    } else {
                        scheduleHoverDismissal(for: url)
                    }
                }
                .zIndex(10)
        }
    }

    private func attachmentActions(for attachment: ForumPostAttachment) -> some View {
        HoverActionPill(glass: .regular.interactive(), spacing: 1, padding: 3) {
            HoverActionButton(
                systemImage: attachment.isSpoiler ? "eye.slash" : "eye",
                help: attachment.isSpoiler ? "Remove spoiler" : "Mark as spoiler",
                isSelected: attachment.isSpoiler,
                diameter: 20,
                iconFont: .caption2.weight(.semibold),
                action: { toggleSpoiler(for: attachment.url) }
            )
            HoverActionButton(
                systemImage: "pencil",
                help: "Edit attachment",
                diameter: 20,
                iconFont: .caption2.weight(.semibold),
                action: { editingTarget = ForumAttachmentEditorTarget(id: attachment.url) }
            )
            HoverActionButton(
                systemImage: "trash",
                help: "Delete attachment",
                role: .destructive,
                diameter: 20,
                iconFont: .caption2.weight(.semibold),
                action: { deleteAttachment(attachment.url) }
            )
        }
    }

    private var addAttachmentButton: some View {
        Button(action: addAttachments) {
            Image(systemName: "photo.badge.plus")
                .symbolVariant(.none)
                .font(.system(size: 22, weight: .medium))
                .frame(width: tileSize, height: tileSize)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        }
        .help("Add attachments")
        .accessibilityLabel("Add Attachments")
    }

    private func attachmentTile(_ attachment: ForumPostAttachment) -> some View {
        ForumComposerAttachmentTile(
            attachment: attachment,
            thumbnail: attachmentThumbnails[attachment.url],
            size: tileSize,
            toggleSpoiler: { toggleSpoiler(for: attachment.url) },
            edit: { editingTarget = ForumAttachmentEditorTarget(id: attachment.url) },
            delete: { deleteAttachment(attachment.url) },
            thumbnailLoaded: { image in
                if attachmentThumbnails[attachment.url] == nil {
                    attachmentThumbnails[attachment.url] = image
                }
            },
            hoverChanged: { hovering in
                if hovering {
                    hoverDismissalTask?.cancel()
                    hoveredAttachmentURL = attachment.url
                } else {
                    scheduleHoverDismissal(for: attachment.url)
                }
            }
        )
    }

    private func toggleSpoiler(for url: URL) {
        guard let index = attachments.firstIndex(where: { $0.url == url }) else { return }
        attachments[index].isSpoiler.toggle()
    }

    private func deleteAttachment(_ url: URL) {
        clearHoveredAttachment()
        attachments.removeAll { $0.url == url }
        attachmentThumbnails.removeValue(forKey: url)
        scrollTarget = attachments.first?.url
        if attachments.isEmpty {
            isExpanded = false
        }
    }

    private func scheduleHoverDismissal(for url: URL) {
        hoverDismissalTask?.cancel()
        hoverDismissalTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(75))
            guard !Task.isCancelled,
                  !isHoveringAttachmentActions,
                  hoveredAttachmentURL == url
            else { return }
            hoveredAttachmentURL = nil
        }
    }

    private func clearHoveredAttachment() {
        hoverDismissalTask?.cancel()
        hoverDismissalTask = nil
        isHoveringAttachmentActions = false
        hoveredAttachmentURL = nil
    }
}

private struct ForumComposerAttachmentTile: View {
    let attachment: ForumPostAttachment
    let thumbnail: NSImage?
    var size: CGFloat = 108
    let toggleSpoiler: () -> Void
    let edit: () -> Void
    let delete: () -> Void
    let thumbnailLoaded: (NSImage) -> Void
    let hoverChanged: (Bool) -> Void

    var body: some View {
        ZStack {
            ForumLocalAttachmentThumbnail(
                url: attachment.url,
                cachedImage: thumbnail,
                onImageLoaded: thumbnailLoaded
            )
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }

            if attachment.isSpoiler {
                Rectangle()
                    .fill(.black.opacity(0.5))
                VStack(spacing: 4) {
                    Image(systemName: "eye.slash")
                    Text("SPOILER")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover(perform: hoverChanged)
        .help(attachment.filename)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachment.filename)
        .accessibilityAction(
            named: attachment.isSpoiler ? "Remove spoiler" : "Mark as spoiler",
            toggleSpoiler
        )
        .accessibilityAction(named: "Edit attachment", edit)
        .accessibilityAction(named: "Delete attachment", delete)
    }
}

private struct ForumAttachmentEditorTarget: Identifiable {
    let id: URL
}

private struct ForumAttachmentEditor: View {
    let attachment: ForumPostAttachment
    let cancel: () -> Void
    let save: (ForumPostAttachment) -> Void
    @State private var filename: String
    @State private var description: String
    @State private var isSpoiler: Bool

    init(
        attachment: ForumPostAttachment,
        cancel: @escaping () -> Void,
        save: @escaping (ForumPostAttachment) -> Void
    ) {
        self.attachment = attachment
        self.cancel = cancel
        self.save = save
        _filename = State(initialValue: attachment.filename)
        _description = State(initialValue: attachment.description)
        _isSpoiler = State(initialValue: attachment.isSpoiler)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Modify Attachment")
                    .font(.title2.bold())
                Spacer()
                Button("Close", systemImage: "xmark", action: cancel)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }

            HStack(alignment: .top, spacing: 24) {
                ForumLocalAttachmentThumbnail(url: attachment.url, maximumPixelDimension: 480)
                    .frame(width: 220, height: 220)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Filename").font(.headline)
                        TextField("Filename", text: $filename)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("Description (Alt Text)").font(.headline)
                            Spacer()
                            Text("\(description.count)/1024")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        TextEditor(text: $description)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(7)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(.separator, lineWidth: 1)
                            }
                            .frame(minHeight: 116)
                            .onChange(of: description) { _, value in
                                if value.count > 1_024 {
                                    description = String(value.prefix(1_024))
                                }
                            }
                    }

                    Toggle("Mark as spoiler", isOn: $isSpoiler)
                        .toggleStyle(.checkbox)
                }
                .frame(maxWidth: .infinity)
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var updated = attachment
                    updated.filename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.description = description
                    updated.isSpoiler = isSpoiler
                    save(updated)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(
            minWidth: 560,
            idealWidth: 680,
            maxWidth: 760,
            minHeight: 440,
            idealHeight: 520,
            maxHeight: 640
        )
    }
}

private struct ForumLocalAttachmentThumbnail: View {
    let url: URL
    var maximumPixelDimension = 256
    var cachedImage: NSImage?
    var onImageLoaded: ((NSImage) -> Void)?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.clear
            if let displayImage {
                Image(nsImage: displayImage)
                    .resizable()
                    .scaledToFill()
            } else if isImageFile {
                Color.clear
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .scaledToFit()
                    .padding(10)
            }
        }
        .clipped()
        .task(id: "\(url.absoluteString)#\(maximumPixelDimension)") {
            if let cachedImage {
                image = cachedImage
                return
            }
            image = nil
            guard isImageFile else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            guard let data = try? await SharedMediaDataLoader.shared.data(for: url),
                  !Task.isCancelled
            else { return }
            let decoded = await Task.detached(priority: .userInitiated) {
                try? DecodedAnimatedImage(
                    data: data,
                    maximumPixelDimension: maximumPixelDimension
                )
            }.value
            guard !Task.isCancelled else { return }
            let loadedImage: NSImage
            if let firstFrame = decoded?.frames.first {
                loadedImage = NSImage(cgImage: firstFrame, size: .zero)
            } else {
                guard let fallbackImage = NSImage(data: data) else { return }
                loadedImage = fallbackImage
            }
            image = loadedImage
            onImageLoaded?(loadedImage)
        }
    }

    private var displayImage: NSImage? {
        cachedImage ?? image
    }

    private var isImageFile: Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }
}

private struct ForumPostAttachmentPreview: View {
    let attachment: Attachment
    let maximumPixelDimension: Int

    var body: some View {
        if attachment.isSpoiler {
            VStack(spacing: 6) {
                Image(systemName: "eye.slash.fill")
                Text("SPOILER")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Spoiler attachment hidden")
        } else {
            switch attachment.mediaKind {
            case .image, .animatedImage:
                AnimatedRemoteImage(
                    url: attachment.proxyURL ?? attachment.url,
                    isLooping: false,
                    fallbackSystemImage: "photo",
                    maximumPixelDimension: maximumPixelDimension
                )
            case .video:
                ForumPostFilePreview(systemImage: "play.rectangle.fill", filename: attachment.filename)
            case .audio:
                ForumPostFilePreview(systemImage: "waveform", filename: attachment.filename)
            case .file:
                ForumPostFilePreview(systemImage: "doc.fill", filename: attachment.filename)
            }
        }
    }
}

private struct ForumPostFilePreview: View {
    let systemImage: String
    let filename: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.title2)
            Text(filename)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ForumActionErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .help("Dismiss error")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.red.opacity(0.08))
        .accessibilityElement(children: .contain)
    }
}

private struct ForumLoadingView: View {
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(0 ..< 5, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.quaternary)
                        .frame(height: 130)
                }
            }
            .padding(14)
        }
        .scrollDisabled(true)
        .redacted(reason: .placeholder)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct ForumEmptyState: View {
    let title: String
    let description: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct ForumSearchingState: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Searching posts…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
