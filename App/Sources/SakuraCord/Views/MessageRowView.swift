import AppKit
import MessageRendering
import SakuraCordModels
import SwiftUI

enum MessageRowLayoutMetrics {
    nonisolated static let avatarDiameter: CGFloat = 38
    nonisolated static let compactContentHeight: CGFloat = 18
    nonisolated static let firstMessageContentOffset: CGFloat = 12
    nonisolated static let visibleHighlightInset: CGFloat = 3
    nonisolated static let replyPreviewIntrinsicTopInset: CGFloat = 3
    nonisolated static let editFooterIntrinsicBottomInset: CGFloat = 3

    nonisolated static func avatarColumnHeight(startsGroup: Bool) -> CGFloat {
        startsGroup ? avatarDiameter : compactContentHeight
    }

    nonisolated static func highlightInsets(
        hasReplyPreview: Bool,
        isEditing: Bool
    ) -> MessageRowHighlightInsets {
        let intrinsicTopInset = hasReplyPreview ? replyPreviewIntrinsicTopInset : 0
        let intrinsicBottomInset = isEditing ? editFooterIntrinsicBottomInset : 0
        return MessageRowHighlightInsets(
            top: max(0, visibleHighlightInset - intrinsicTopInset),
            bottom: max(0, visibleHighlightInset - intrinsicBottomInset),
            intrinsicTop: intrinsicTopInset,
            intrinsicBottom: intrinsicBottomInset
        )
    }

    nonisolated static func separation(
        startsGroup: Bool,
        highlightTopInset: CGFloat
    ) -> CGFloat {
        guard startsGroup else { return 0 }
        return firstMessageContentOffset - highlightTopInset
    }

    nonisolated static func geometry(
        contentHeight: CGFloat,
        startsGroup: Bool,
        hasReplyPreview: Bool = false,
        isEditing: Bool = false
    ) -> MessageRowLayoutGeometry {
        let insets = highlightInsets(hasReplyPreview: hasReplyPreview, isEditing: isEditing)
        let externalSeparation = separation(
            startsGroup: startsGroup,
            highlightTopInset: insets.top
        )
        let highlightMinY = externalSeparation
        let contentMinY = highlightMinY + insets.top
        let contentMaxY = contentMinY + contentHeight
        let highlightMaxY = contentMaxY + insets.bottom
        return MessageRowLayoutGeometry(
            externalTopSeparation: externalSeparation,
            highlightMinY: highlightMinY,
            highlightMaxY: highlightMaxY,
            contentMinY: contentMinY,
            contentMaxY: contentMaxY,
            visibleContentMinY: contentMinY + insets.intrinsicTop,
            visibleContentMaxY: contentMaxY - insets.intrinsicBottom,
            rowHeight: highlightMaxY
        )
    }
}

struct MessageRowHighlightInsets: Equatable {
    let top: CGFloat
    let bottom: CGFloat
    let intrinsicTop: CGFloat
    let intrinsicBottom: CGFloat
}

struct MessageRowLayoutGeometry: Equatable {
    let externalTopSeparation: CGFloat
    let highlightMinY: CGFloat
    let highlightMaxY: CGFloat
    let contentMinY: CGFloat
    let contentMaxY: CGFloat
    let visibleContentMinY: CGFloat
    let visibleContentMaxY: CGFloat
    let rowHeight: CGFloat

    nonisolated var highlightTopInset: CGFloat { contentMinY - highlightMinY }
    nonisolated var highlightBottomInset: CGFloat { highlightMaxY - contentMaxY }
    nonisolated var visibleHighlightTopInset: CGFloat { visibleContentMinY - highlightMinY }
    nonisolated var visibleHighlightBottomInset: CGFloat { highlightMaxY - visibleContentMaxY }
    nonisolated var contentHeight: CGFloat { contentMaxY - contentMinY }
}

nonisolated enum MessageOutboxPresentation {
    static func textOpacity(for state: OutboxState) -> Double {
        contentOpacity(for: state)
    }

    static func mediaOpacity(for state: OutboxState) -> Double {
        contentOpacity(for: state)
    }

    private static func contentOpacity(for state: OutboxState) -> Double {
        switch state {
        case .queued, .uploading, .sending, .awaitingReconciliation:
            0.55
        case .confirmed, .failed:
            1
        }
    }

    static func accessibilityStatus(for state: OutboxState) -> String {
        switch state {
        case .queued, .uploading, .sending:
            "Sending"
        case .awaitingReconciliation:
            "Waiting for confirmation"
        case .confirmed:
            "Sent"
        case .failed:
            "Failed"
        }
    }
}

struct MessageRowView: View, Equatable {
    let model: AppModel
    let message: Message
    let authorPresentation: MessageAuthorPresentation
    let startsGroup: Bool
    let replyPreview: MessageReplyPreview?
    let isReplyAvailable: Bool
    let canEdit: Bool
    let saveEdit: (String) -> Void
    let reply: (() -> Void)?
    let markUnread: () -> Void
    let openReply: (MessageID) -> Void
    let delete: () -> Void
    let react: (String) -> Void
    @State private var isEditing = false
    @State private var isHovering = false
    @State private var isActionReactionPickerPresented = false
    @State private var isInlineReactionPickerPresented = false
    @State private var editText = ""
    @State private var isDeleteConfirmationPresented = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model
            && lhs.message == rhs.message
            && lhs.authorPresentation == rhs.authorPresentation
            && lhs.startsGroup == rhs.startsGroup
            && lhs.replyPreview == rhs.replyPreview
            && lhs.isReplyAvailable == rhs.isReplyAvailable
            && lhs.canEdit == rhs.canEdit
    }

    var body: some View {
        let highlightInsets = MessageRowLayoutMetrics.highlightInsets(
            hasReplyPreview: replyPreview != nil,
            isEditing: isEditing
        )
        VStack(alignment: .leading, spacing: 0) {
            if let replyPreview {
                MessageReplyContext(
                    model: model,
                    preview: replyPreview,
                    isAvailable: isReplyAvailable,
                    open: { openReply(replyPreview.messageID) }
                )
            }
            if message.type == .chatInputCommand {
                ApplicationCommandInvocationLine(model: model, message: message)
            }
            if message.type.hasGeneratedContent {
                MessageContent(
                    model: model,
                    message: message,
                    isEditing: $isEditing,
                    editText: $editText,
                    save: commitEdit,
                    cancel: cancelEdit,
                    react: react,
                    isReactionPickerPresented: $isInlineReactionPickerPresented
                )
                .padding(.leading, 36)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    MessageAvatarColumn(
                        model: model,
                        startsGroup: startsGroup,
                        author: authorPresentation.user,
                        timestamp: message.timestamp
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        if startsGroup {
                            MessageAuthorLine(
                                model: model,
                                message: message,
                                author: authorPresentation.user,
                                roleColorHex: authorPresentation.roleColorHex
                            )
                        }
                        MessageContent(
                            model: model,
                            message: message,
                            isEditing: $isEditing,
                            editText: $editText,
                            save: commitEdit,
                            cancel: cancelEdit,
                            react: react,
                            isReactionPickerPresented: $isInlineReactionPickerPresented
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, highlightInsets.top)
        .padding(.bottom, highlightInsets.bottom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? Color.primary.opacity(0.055) : .clear)
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            if MessageActionVisibilityPolicy.isVisible(
                isRowHovered: isHovering,
                isReactionPickerPresented: isActionReactionPickerPresented
                    || isInlineReactionPickerPresented,
                isEditing: isEditing
            ) {
                MessageActionCapsule(
                    model: model,
                    message: message,
                    canEdit: canEdit,
                    isReactionPickerPresented: $isActionReactionPickerPresented,
                    retry: message.outboxState == .failed
                        ? { Task { await model.retrySending(message) } }
                        : nil,
                    edit: beginEditing,
                    reply: reply,
                    react: react,
                    copy: copyText,
                    copyLink: copyMessageLink,
                    openThread: message.thread.map { thread in { model.open(thread) } },
                    delete: { isDeleteConfirmationPresented = true }
                )
                .padding(.trailing, 14)
                .offset(y: -13)
            }
        }
        .onHover { isHovering = $0 }
        .zIndex(
            isHovering || isActionReactionPickerPresented || isInlineReactionPickerPresented
                ? 10 : 0
        )
        .overlay {
            MessageContextMenuBridge(
                canEdit: canEdit,
                canRetry: message.outboxState == .failed,
                retry: { Task { await model.retrySending(message) } },
                edit: beginEditing,
                reply: reply,
                markUnread: markUnread,
                react: react,
                copy: copyText,
                delete: { isDeleteConfirmationPresented = true }
            )
        }
        .padding(
            .top,
            MessageRowLayoutMetrics.separation(
                startsGroup: startsGroup,
                highlightTopInset: highlightInsets.top
            )
        )
        .confirmationDialog("Delete this message?", isPresented: $isDeleteConfirmationPresented) {
            Button("Delete Message", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }

    private func beginEditing() {
        editText = message.content
        isEditing = true
    }

    private func commitEdit() {
        guard let value = MessageEditInputPolicy.submission(from: editText) else { return }
        isEditing = false
        saveEdit(value)
    }

    private func cancelEdit() {
        isEditing = false
        editText = message.content
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
    }

    private func copyMessageLink() {
        let guild = (message.guildID ?? model.selectedGuildID)?.description ?? "@me"
        let value = "https://discord.com/channels/\(guild)/\(message.channelID)/\(message.id)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

enum MessageActionVisibilityPolicy {
    nonisolated static func isVisible(
        isRowHovered: Bool,
        isReactionPickerPresented: Bool,
        isEditing: Bool
    ) -> Bool {
        !isEditing && (isRowHovered || isReactionPickerPresented)
    }
}

private struct MessageContextMenuBridge: NSViewRepresentable {
    let canEdit: Bool
    let canRetry: Bool
    let retry: () -> Void
    let edit: () -> Void
    let reply: (() -> Void)?
    let markUnread: () -> Void
    let react: (String) -> Void
    let copy: () -> Void
    let delete: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            canEdit: canEdit,
            canRetry: canRetry,
            retry: retry,
            edit: edit,
            reply: reply,
            markUnread: markUnread,
            react: react,
            copy: copy,
            delete: delete
        )
    }

    func makeNSView(context: Context) -> MessageContextMenuHitView {
        let view = MessageContextMenuHitView()
        view.menuProvider = { [weak coordinator = context.coordinator] in
            coordinator?.makeMenu()
        }
        return view
    }

    func updateNSView(_ nsView: MessageContextMenuHitView, context: Context) {
        context.coordinator.update(
            canEdit: canEdit,
            canRetry: canRetry,
            retry: retry,
            edit: edit,
            reply: reply,
            markUnread: markUnread,
            react: react,
            copy: copy,
            delete: delete
        )
        nsView.menuProvider = { [weak coordinator = context.coordinator] in
            coordinator?.makeMenu()
        }
    }

    final class Coordinator: NSObject {
        private var canEdit: Bool
        private var canRetry: Bool
        private var retry: () -> Void
        private var edit: () -> Void
        private var reply: (() -> Void)?
        private var markUnread: () -> Void
        private var react: (String) -> Void
        private var copy: () -> Void
        private var delete: () -> Void

        init(
            canEdit: Bool,
            canRetry: Bool,
            retry: @escaping () -> Void,
            edit: @escaping () -> Void,
            reply: (() -> Void)?,
            markUnread: @escaping () -> Void,
            react: @escaping (String) -> Void,
            copy: @escaping () -> Void,
            delete: @escaping () -> Void
        ) {
            self.canEdit = canEdit
            self.canRetry = canRetry
            self.retry = retry
            self.edit = edit
            self.reply = reply
            self.markUnread = markUnread
            self.react = react
            self.copy = copy
            self.delete = delete
        }

        func update(
            canEdit: Bool,
            canRetry: Bool,
            retry: @escaping () -> Void,
            edit: @escaping () -> Void,
            reply: (() -> Void)?,
            markUnread: @escaping () -> Void,
            react: @escaping (String) -> Void,
            copy: @escaping () -> Void,
            delete: @escaping () -> Void
        ) {
            self.canEdit = canEdit
            self.canRetry = canRetry
            self.retry = retry
            self.edit = edit
            self.reply = reply
            self.markUnread = markUnread
            self.react = react
            self.copy = copy
            self.delete = delete
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            if canRetry {
                menu.addItem(
                    menuItem(
                        "Retry Sending",
                        systemImage: "arrow.clockwise",
                        action: #selector(retrySending)
                    )
                )
                menu.addItem(.separator())
            }
            menu.addItem(
                menuItem(
                    "Add Reaction", systemImage: "face.smiling.inverse", action: #selector(addReaction)
                )
            )
            if reply != nil {
                menu.addItem(
                    menuItem(
                        "Reply", systemImage: "arrowshape.turn.up.left", action: #selector(replyToMessage)
                    )
                )
            }
            menu.addItem(
                menuItem(
                    "Mark Unread",
                    systemImage: "envelope.badge",
                    action: #selector(markMessageUnread)
                )
            )
            if canEdit {
                menu.addItem(
                    menuItem("Edit Message", systemImage: "pencil", action: #selector(editMessage))
                )
            }
            menu.addItem(menuItem("Copy Text", systemImage: "doc.on.doc", action: #selector(copyMessage)))
            if canEdit {
                menu.addItem(.separator())
                menu.addItem(
                    menuItem(
                        "Delete Message",
                        systemImage: "trash",
                        action: #selector(deleteMessage),
                        isDestructive: true
                    )
                )
            }
            return menu
        }

        private func menuItem(
            _ title: String,
            systemImage: String,
            action: Selector,
            isDestructive: Bool = false
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = true

            let baseConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            let configuration =
                isDestructive
                ? baseConfiguration.applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
                : baseConfiguration
            if let image = NSImage(systemSymbolName: systemImage, accessibilityDescription: title)?
                .withSymbolConfiguration(configuration)
            {
                image.isTemplate = !isDestructive
                item.image = image
            }
            if #available(macOS 27.0, *) {
                item.preferredImageVisibility = .visible
            }

            if isDestructive {
                item.attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [.foregroundColor: NSColor.systemRed]
                )
            }
            return item
        }

        @objc private func addReaction() {
            react("👍")
        }

        @objc private func retrySending() {
            retry()
        }

        @objc private func replyToMessage() {
            reply?()
        }

        @objc private func markMessageUnread() {
            markUnread()
        }

        @objc private func editMessage() {
            edit()
        }

        @objc private func copyMessage() {
            copy()
        }

        @objc private func deleteMessage() {
            delete()
        }
    }
}

private final class MessageContextMenuHitView: NSView {
    var menuProvider: (() -> NSMenu?)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = window?.currentEvent else { return nil }
        if event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        {
            return self
        }
        return nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }
}

private struct MessageActionCapsule: View {
    let model: AppModel
    let message: Message
    let canEdit: Bool
    @Binding var isReactionPickerPresented: Bool
    let retry: (() -> Void)?
    let edit: () -> Void
    let reply: (() -> Void)?
    let react: (String) -> Void
    let copy: () -> Void
    let copyLink: () -> Void
    let openThread: (() -> Void)?
    let delete: () -> Void

    var body: some View {
        HoverActionPill {
            if let retry {
                HoverActionButton(
                        systemImage: "arrow.clockwise",
                        help: "Retry sending",
                        action: retry
                )
            }
            ReactionActionMenu(
                model: model,
                guildID: message.guildID,
                isPickerPresented: $isReactionPickerPresented,
                react: react
            )
            .id("reaction-picker-\(message.id)-toolbar")
            if let reply {
                HoverActionButton(systemImage: "arrowshape.turn.up.left", help: "Reply", action: reply)
            }
            if canEdit {
                HoverActionButton(systemImage: "pencil", help: "Edit message", action: edit)
            }
            HoverActionButton(systemImage: "doc.on.doc", help: "Copy text", action: copy)
            HoverActionButton(systemImage: "link", help: "Copy message link", action: copyLink)
            if let openThread {
                HoverActionButton(
                    systemImage: "bubble.left.and.bubble.right", help: "Open thread", action: openThread
                )
            }
            if canEdit {
                HoverActionButton(
                    systemImage: "trash", help: "Delete message", role: .destructive, action: delete
                )
            }
        }
    }
}

private struct ReactionActionMenu: View {
    let model: AppModel
    let guildID: GuildID?
    @Binding var isPickerPresented: Bool
    var presentation: ReactionActionMenuPresentation = .toolbar
    let react: (String) -> Void
    @State private var isHovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: presentation.cornerRadius, style: .continuous)
                .fill(backgroundColor)
                .overlay {
                    RoundedRectangle(cornerRadius: presentation.cornerRadius, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                }

            Button {
                presentPicker()
            } label: {
                Image(systemName: "face.smiling.inverse")
                    .symbolVariant(.none)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(width: presentation.width, height: presentation.height)
                    .contentShape(
                        RoundedRectangle(cornerRadius: presentation.cornerRadius, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
        }
        .frame(width: presentation.width, height: presentation.height)
        .contentShape(
            RoundedRectangle(cornerRadius: presentation.cornerRadius, style: .continuous)
        )
        .onHover { isHovering = $0 }
        .help("Add reaction")
        .background {
            StableReactionPickerPresenter(
                isPresented: $isPickerPresented,
                preferredEdge: presentation.popoverEdge,
                accessibilityIdentifier: presentation.pickerAccessibilityIdentifier
            ) {
                EmojiPickerView(
                    model: model,
                    useCase: .reaction(guildID: guildID ?? model.selectedGuildID),
                    allowsPersistentSelection: true
                ) { activation in
                    switch activation.selection {
                    case let .native(value): react(value)
                    case let .custom(emoji): react(emoji.messageToken)
                    }
                    if !activation.keepsPickerPresented {
                        isPickerPresented = false
                    }
                }
            }
            .frame(width: presentation.width, height: presentation.height)
        }
    }

    private var backgroundColor: Color {
        if isHovering { return Color.primary.opacity(0.14) }
        return presentation == .inline ? Color.primary.opacity(0.09) : .clear
    }

    private var borderColor: Color {
        presentation == .inline && isHovering ? Color.primary.opacity(0.28) : .clear
    }

    private func presentPicker() {
        guard !isPickerPresented else {
            isPickerPresented = false
            return
        }
        Task { @MainActor in
            await Task.yield()
            isPickerPresented = true
        }
    }
}

enum ReactionActionMenuPresentation {
    case toolbar
    case inline

    var width: CGFloat { self == .toolbar ? 28 : 30 }
    var height: CGFloat { self == .toolbar ? 28 : MessageReactionMetrics.pillHeight }
    var cornerRadius: CGFloat { self == .toolbar ? 14 : 9 }
    var popoverEdge: NSRectEdge {
        StableReactionPickerAnchorPolicy.preferredEdge(isInline: self == .inline)
    }
    var pickerAccessibilityIdentifier: String {
        self == .inline ? "reaction-picker-inline" : "reaction-picker-toolbar"
    }
}

private struct MessageReplyContext: View {
    let model: AppModel
    let preview: MessageReplyPreview
    let isAvailable: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            MessageReferenceContext {
                MessageProfileAvatar(model: model, user: preview.author, size: 14)
                    .allowsHitTesting(false)
                Text(preview.author.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(isAvailable ? summary : "Original unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
            }
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isAvailable
                ? "Replying to \(preview.author.displayName): \(summary)" : "Original reply unavailable"
        )
        .help(isAvailable ? "Jump to original message" : "Original message unavailable")
    }

    private var summary: String {
        MessageReplySummary.text(
            content: preview.content,
            mentionLabel: MessageMentionResolver(model: model).label
        )
    }
}

private struct MessageReferenceContext<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 5) {
            MessageReplyConnector()
                .stroke(.tertiary, style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
                .frame(width: 30, height: 20)
                .accessibilityHidden(true)
            content
        }
        .contentShape(Rectangle())
        .padding(.trailing, 48)
        .frame(height: 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MessageReplyConnector: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let stemX = min(19, rect.maxX)
        let horizontalY = rect.minY + rect.height * 0.46
        var path = Path()
        path.move(to: CGPoint(x: stemX, y: rect.maxY))
        path.addLine(to: CGPoint(x: stemX, y: horizontalY + 4))
        path.addQuadCurve(
            to: CGPoint(x: stemX + 4, y: horizontalY),
            control: CGPoint(x: stemX, y: horizontalY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: horizontalY))
        return path
    }
}

@MainActor
enum MessageReplySummary {
    private static let values: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 2_000
        cache.totalCostLimit = 4 * 1_024 * 1_024
        return cache
    }()

    static func text(
        content: String,
        mentionLabel: (RenderedMention) -> String = { mention in
            switch mention.kind {
            case .user: "@unknown-user"
            case .role: "@unknown-role"
            case .channel: "#unknown-channel"
            case .channelLink: "Channel link"
            case .message: "Message link"
            }
        }
    ) -> String {
        let document = MessageDocumentCache.shared.document(for: content)
        let markdownSource = document.segments.reduce(into: "") { output, segment in
            switch segment {
            case let .markdown(value):
                output += value
            case let .customEmoji(emoji):
                output += ":\(emoji.name):"
            case let .mention(mention):
                output += mentionLabel(mention)
            }
        }
        let key = markdownSource as NSString
        if let cached = values.object(forKey: key) {
            return cached as String
        }
        let plainText = String(DiscordMarkdown.attributed(markdownSource).characters)
        let collapsed = plainText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let result = collapsed.isEmpty ? "Attachment" : collapsed
        values.setObject(
            result as NSString,
            forKey: key,
            cost: markdownSource.utf8.count + result.utf8.count
        )
        return result
    }
}

private struct MessageAvatarColumn: View {
    let model: AppModel
    let startsGroup: Bool
    let author: User
    let timestamp: Date
    @State private var isHovering = false

    var body: some View {
        ZStack {
            if startsGroup {
                MessageProfileAvatar(
                    model: model,
                    user: author,
                    size: MessageRowLayoutMetrics.avatarDiameter
                )
            } else if isHovering {
                Text(timestamp, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(
            width: MessageRowLayoutMetrics.avatarDiameter,
            height: MessageRowLayoutMetrics.avatarColumnHeight(startsGroup: startsGroup)
        )
        .onHover { isHovering = $0 }
    }
}

private struct MessageContent: View {
    let model: AppModel
    let message: Message
    @Binding var isEditing: Bool
    @Binding var editText: String
    let save: () -> Void
    let cancel: () -> Void
    let react: (String) -> Void
    @Binding var isReactionPickerPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isEditing {
                InlineMessageEditor(
                    model: model,
                    text: $editText,
                    save: save,
                    cancel: cancel
                )
            } else if !message.content.isEmpty || message.type.hasGeneratedContent {
                RichMessageContentView(model: model, message: message)
            } else if !message.attachments.isEmpty || !message.embeds.isEmpty
                || !message.components.isEmpty || !message.stickers.isEmpty || message.thread != nil
            {
                RichMessageContentView(model: model, message: message)
            }
            let reactionItems = MessageReactionPresentation.items(from: message.reactions)
            if !reactionItems.isEmpty {
                MessageReactionStrip(
                    reactions: reactionItems,
                    customEmojiURLsByID: model.customEmojiURLsByID,
                    react: react,
                    loadReactors: { reaction in
                        await model.loadReactionReactors(reaction, on: message)
                    }
                ) {
                    ReactionActionMenu(
                        model: model,
                        guildID: message.guildID,
                        isPickerPresented: $isReactionPickerPresented,
                        presentation: .inline,
                        react: react
                    )
                    .id("reaction-picker-\(message.id)-inline")
                }
            }
            if message.flags.contains(.ephemeral) {
                HStack(spacing: 4) {
                    Image(systemName: "eye")
                        .accessibilityHidden(true)
                    Text("Only you can see this")
                    Text("•")
                    Button("Dismiss message") {
                        model.dismissEphemeralMessage(message)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
            if message.outboxState == .failed {
                Label("Failed", systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .accessibilityValue(
            MessageOutboxPresentation.accessibilityStatus(for: message.outboxState)
        )
    }

}

enum MessageEditLayoutMetrics {
    nonisolated static let editorFooterSpacing: CGFloat = 2
    nonisolated static let footerVerticalPadding: CGFloat = 0
    nonisolated static let footerHorizontalPadding: CGFloat = 0
    nonisolated static let actionHeight: CGFloat = 22
    nonisolated static let actionHorizontalPadding: CGFloat = 5
    nonisolated static let keycapHorizontalPadding: CGFloat = 5
    nonisolated static let keycapVerticalPadding: CGFloat = 1

    nonisolated static var footerIntrinsicHeight: CGFloat {
        actionHeight + (footerVerticalPadding * 2)
    }

    nonisolated static var verticalContributionBelowEditor: CGFloat {
        editorFooterSpacing + footerIntrinsicHeight
    }
}

private struct InlineMessageEditor: View {
    let model: AppModel
    @Binding var text: String
    let save: () -> Void
    let cancel: () -> Void
    @State private var selection: NSRange?
    @State private var isFocused = true
    @State private var autocompleteIndex = 0
    @State private var isAutocompleteDismissed = false

    var body: some View {
        VStack(alignment: .leading, spacing: MessageEditLayoutMetrics.editorFooterSpacing) {
            if let context, !suggestions.isEmpty {
                EmojiAutocompleteList(
                    suggestions: suggestions,
                    selectedIndex: autocompleteIndex,
                    highlight: { autocompleteIndex = $0 }
                ) {
                    accept($0, context: context)
                }
            }
            ComposerTextView(
                text: text,
                placeholder: "Edit message",
                sendWithReturn: MessageEditInputPolicy.sendsWithReturn,
                onTextChange: { text = $0 },
                onSubmit: save,
                onAutocompleteCommand: handleAutocomplete,
                selection: $selection,
                isFocused: $isFocused
            )
                .padding(9)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel("Message text")
                .accessibilityHint("Press Return to save, Shift-Return for a new line, or Escape to cancel.")
                .onExitCommand(perform: cancel)
            InlineMessageEditFooter(
                canSave: MessageEditInputPolicy.submission(from: text) != nil,
                save: save,
                cancel: cancel
            )
        }
        .onChange(of: text) { _, _ in
            isAutocompleteDismissed = false
            autocompleteIndex = 0
        }
        .onChange(of: selection) { _, _ in
            isAutocompleteDismissed = false
            autocompleteIndex = 0
        }
    }

    private var context: ColonAutocompleteContext? {
        isAutocompleteDismissed ? nil : ColonAutocompleteContext(text: text, selection: selection)
    }

    private var suggestions: [ColonAutocompleteSuggestion] {
        guard let context else { return [] }
        return ColonAutocompleteSuggestionFactory.suggestions(
            query: context.query,
            customEmojis: model.orderedCustomEmojis,
            customValue: model.composerText(for:),
            customSource: { model.serverRailGuildsByID[$0.guildID]?.name },
            favoriteKeys: model.favoriteEmojiKeys,
            discordFavoriteKeys: Set(model.discordFavoriteEmojiKeys),
            usageCounts: model.emojiUsageCounts,
            discordUsageScores: model.discordEmojiUsageScores,
            discordSettingsAreLoaded: model.hasLoadedDiscordEmojiSettings
        )
    }

    private func handleAutocomplete(_ command: ComposerAutocompleteCommand) -> Bool {
        guard let context, !suggestions.isEmpty else { return false }
        switch command {
        case .previous:
            autocompleteIndex = (autocompleteIndex - 1 + suggestions.count) % suggestions.count
        case .next: autocompleteIndex = (autocompleteIndex + 1) % suggestions.count
        case .accept, .advance:
            accept(suggestions[min(autocompleteIndex, suggestions.count - 1)], context: context)
        case .dismiss: isAutocompleteDismissed = true
        case .previousField, .nextField, .removeField: return false
        }
        return true
    }

    private func accept(_ suggestion: ColonAutocompleteSuggestion, context: ColonAutocompleteContext) {
        let value = text as NSString
        text = value.replacingCharacters(in: context.range, with: suggestion.value)
        selection = NSRange(
            location: context.range.location + suggestion.value.utf16.count, length: 0
        )
        model.recordEmojiUse(suggestion.usageKey)
        isAutocompleteDismissed = true
    }
}

private struct InlineMessageEditFooter: View {
    let canSave: Bool
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            InlineEditTextButton(title: "Cancel", key: "esc", action: cancel)
                .keyboardShortcut(.cancelAction)
                .accessibilityHint("Discards your changes. Keyboard shortcut: Escape.")
            InlineEditTextButton(title: "Save", key: "↵", action: save)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint(
                    canSave
                        ? "Saves your edited message. Keyboard shortcut: Return."
                        : "Enter message text before saving."
                )
                .disabled(!canSave)
        }
        .frame(height: MessageEditLayoutMetrics.footerIntrinsicHeight)
        .padding(.vertical, MessageEditLayoutMetrics.footerVerticalPadding)
        .padding(.horizontal, MessageEditLayoutMetrics.footerHorizontalPadding)
    }
}

private struct InlineEditTextButton: View {
    let title: LocalizedStringKey
    let key: LocalizedStringKey
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                InlineEditKeycap(key: key, isActive: isHovering && isEnabled)
            }
            .foregroundStyle(isHovering && isEnabled ? .primary : .secondary)
            .padding(.horizontal, MessageEditLayoutMetrics.actionHorizontalPadding)
            .frame(height: MessageEditLayoutMetrics.actionHeight)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(isHovering && isEnabled ? 0.09 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct InlineEditKeycap: View {
    let key: LocalizedStringKey
    let isActive: Bool

    var body: some View {
        Text(key)
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(isActive ? .primary : .secondary)
            .padding(.horizontal, MessageEditLayoutMetrics.keycapHorizontalPadding)
            .padding(.vertical, MessageEditLayoutMetrics.keycapVerticalPadding)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct MessageAuthorLine: View {
    let model: AppModel
    let message: Message
    let author: User
    let roleColorHex: UInt32?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            MessageProfileName(model: model, user: author, font: .headline)
                .foregroundStyle(nameColor)
            if author.isBot {
                Text("APP").font(.caption2.bold()).padding(.horizontal, 4).background(
                    Color.accentColor, in: RoundedRectangle(cornerRadius: 3)
                )
            }
            Text(message.timestamp, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(
                .secondary
            )
            if message.editedTimestamp != nil {
                Text("(edited)").font(.caption2).foregroundStyle(.tertiary)
            }
            if message.flags.contains(.loading) {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private var nameColor: Color {
        if author.isBot { return .accentColor }
        return roleColorHex.map(Color.init(hex:)) ?? .primary
    }
}

private struct ApplicationCommandInvocationLine: View {
    let model: AppModel
    let message: Message

    var body: some View {
        MessageReferenceContext {
            if let user = message.interactionMetadata?.user {
                MessageProfileAvatar(model: model, user: user, size: 14)
                    .allowsHitTesting(false)
                MessageProfileName(model: model, user: user, font: .caption2.weight(.semibold))
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Someone").font(.caption2.weight(.semibold))
            }
            Text("used")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 3) {
                Image(systemName: "xmark.triangle.circle.square.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
                Text(message.interactionMetadata?.displayName ?? "command")
            }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Color.accentColor.opacity(0.16),
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(message.interactionMetadata?.user?.displayName ?? "Someone") used "
                + "/\(message.interactionMetadata?.displayName ?? "command")"
        )
    }
}

private struct MessageProfileAvatar: View {
    let model: AppModel
    let user: User
    let size: CGFloat
    @State private var isPresented = false

    var body: some View {
        Button {
            open()
        } label: {
            AvatarView(name: user.displayName, url: user.avatarURL, size: size)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented) {
            MessageProfilePopoverContent(model: model, userID: user.id)
        }
        .help("View \(user.displayName)'s profile")
    }

    private func open() {
        model.showProfile(for: user)
        isPresented = true
    }
}

private struct MessageProfileName: View {
    let model: AppModel
    let user: User
    let font: Font
    @State private var isPresented = false

    var body: some View {
        Button {
            model.showProfile(for: user)
            isPresented = true
        } label: {
            Text(user.displayName).font(font)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented) {
            MessageProfilePopoverContent(model: model, userID: user.id)
        }
        .help("View \(user.displayName)'s profile")
    }
}

struct MessageProfilePopoverContent: View {
    let model: AppModel
    let userID: UserID

    var body: some View {
        ZStack {
            if let member = model.selectedMember, member.id == userID {
                MemberProfilePopover(
                    member: member,
                    profile: model.selectedProfile,
                    isLoading: model.isLoadingProfile,
                    errorMessage: model.profileErrorMessage
                )
            } else {
                ProgressView().padding(40)
            }
        }
        .onDisappear {
            if !model.isInspectorProfilePresented, model.selectedMember?.id == userID {
                model.dismissProfile()
            }
        }
    }
}
