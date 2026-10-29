import AppKit
import MessageRendering
import SakuraCordModels
import SwiftUI

enum MessageRowLayoutMetrics {
    nonisolated static var horizontalInset: CGFloat { InterfaceScale.metric(14) }
    nonisolated static var avatarDiameter: CGFloat { InterfaceScale.metric(38) }
    nonisolated static var avatarColumnGap: CGFloat { InterfaceScale.metric(12) }
    nonisolated static var compactContentHeight: CGFloat { InterfaceScale.metric(18) }
    nonisolated static var authorLineHeight: CGFloat { InterfaceScale.metric(16) }
    nonisolated static var authorContentSpacing: CGFloat { InterfaceScale.metric(2) }
    nonisolated static var commandAuthorContentSpacing: CGFloat { InterfaceScale.metric(0) }
    nonisolated static var messageGroupSeparation: CGFloat { InterfaceScale.metric(12) }
    // Message density is set in points and is independent of interface size.
    nonisolated static let visibleHighlightInset: CGFloat = 3
    nonisolated static let defaultMessageSpacing = visibleHighlightInset * 2
    nonisolated static var replyPreviewIntrinsicTopInset: CGFloat { InterfaceScale.metric(3) }
    nonisolated static var editFooterIntrinsicBottomInset: CGFloat { InterfaceScale.metric(3) }
    nonisolated static var commandInvocationHeight: CGFloat { InterfaceScale.metric(20) }
    nonisolated static var commandInvocationContentInset: CGFloat { InterfaceScale.metric(3) }

    /// The gap after the avatar column, which widens with the compact
    /// timestamp gutter so grouped content stays aligned.
    static func columnGap(timestampGutterWidth: CGFloat) -> CGFloat {
        avatarColumnGap + max(avatarDiameter, timestampGutterWidth) - avatarDiameter
    }

    nonisolated static func avatarColumnHeight(startsGroup: Bool) -> CGFloat {
        startsGroup ? avatarDiameter : compactContentHeight
    }

    nonisolated static func highlightInsets(
        hasReplyPreview: Bool,
        isEditing: Bool,
        messageSpacing: CGFloat = defaultMessageSpacing
    ) -> MessageRowHighlightInsets {
        let intrinsicTopInset = hasReplyPreview ? replyPreviewIntrinsicTopInset : 0
        let intrinsicBottomInset = isEditing ? editFooterIntrinsicBottomInset : 0
        let edgeSpacing = max(0, messageSpacing) / 2
        return MessageRowHighlightInsets(
            top: max(0, edgeSpacing - intrinsicTopInset),
            bottom: max(0, edgeSpacing - intrinsicBottomInset),
            intrinsicTop: intrinsicTopInset,
            intrinsicBottom: intrinsicBottomInset
        )
    }

    nonisolated static func separation(
        startsGroup: Bool,
        followsTimelineSeparator: Bool = false,
        highlightTopInset: CGFloat,
        messageSpacing: CGFloat = defaultMessageSpacing
    ) -> CGFloat {
        // Date and unread separators already provide the complete visual gap
        // between adjacent messages. Applying the ordinary author-group
        // separation after either one makes the lower half visibly larger
        // than the upper half.
        guard startsGroup, !followsTimelineSeparator else { return 0 }
        let adjustedSeparation = messageGroupSeparation
            + messageSpacing
            - defaultMessageSpacing
        return max(0, adjustedSeparation - highlightTopInset)
    }

    nonisolated static func authorToContentSpacing(isCommandResponse: Bool) -> CGFloat {
        isCommandResponse
            ? commandAuthorContentSpacing
            : authorContentSpacing
    }

    nonisolated static func geometry(
        contentHeight: CGFloat,
        startsGroup: Bool,
        hasReplyPreview: Bool = false,
        isEditing: Bool = false,
        followsTimelineSeparator: Bool = false,
        messageSpacing: CGFloat = defaultMessageSpacing
    ) -> MessageRowLayoutGeometry {
        let insets = highlightInsets(
            hasReplyPreview: hasReplyPreview,
            isEditing: isEditing,
            messageSpacing: messageSpacing
        )
        let externalSeparation = separation(
            startsGroup: startsGroup,
            followsTimelineSeparator: followsTimelineSeparator,
            highlightTopInset: insets.top,
            messageSpacing: messageSpacing
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

nonisolated enum MessageRowPersistentHighlight: Equatable {
    case none
    case failed
    case ephemeral
    case mention

    static func resolve(
        message: Message,
        currentUserID: UserID?,
        currentUserRoleIDs: Set<RoleID> = []
    ) -> Self {
        if message.outboxState == .failed {
            return .failed
        }
        if message.flags.contains(.ephemeral) {
            return .ephemeral
        }
        guard let currentUserID else {
            return .none
        }
        if message.mentionedUsers.contains(where: {
            $0.id == currentUserID
        }) {
            return .mention
        }
        if message.mentionsEveryone {
            return .mention
        }
        if !message.flags.contains(.failedToMentionRoles),
           !currentUserRoleIDs.isDisjoint(
                with: message.mentionedRoleIDs
           )
        {
            return .mention
        }
        return .none
    }
}

nonisolated enum MessageOutboxPresentation {
    enum InteractionMode: Equatable {
        case disabled
        case failed
        case confirmed

        var allowsHoverActions: Bool {
            self != .disabled
        }

        var allowsMessageContextMenu: Bool {
            self != .disabled
        }

        var allowsMediaContextMenu: Bool {
            self == .confirmed
        }
    }

    static func interactionMode(for message: Message) -> InteractionMode {
        message.flags.contains(.ephemeral) ? .disabled : interactionMode(for: message.outboxState)
    }

    static func interactionMode(for state: OutboxState) -> InteractionMode {
        switch state {
        case .queued, .uploading, .sending, .awaitingReconciliation:
            .disabled
        case .failed:
            .failed
        case .confirmed:
            .confirmed
        }
    }

    /// Pending-interaction status replaces dimming; it is already muted.
    static func textOpacity(for message: Message) -> Double {
        message.flags.contains(.loading) ? 1 : contentOpacity(for: message.outboxState)
    }

    /// Discord labels a pending interaction from its loading flag, not its
    /// body: a local command row reports its own progress, and an app's
    /// deferred response is the app "thinking".
    static func interactionLoadingStatus(for message: Message, authorName: String) -> String? {
        guard message.flags.contains(.loading) else { return nil }
        if message.outboxState != .confirmed, !message.content.isEmpty { return message.content }
        return "\(authorName) is thinking…"
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

    static let retryTitle = String(localized: "Retry")

    static func failureText(for message: Message) -> String {
        guard message.outboxState == .failed,
              case let .autoModeration(explanation) = message.sendFailure
        else { return "Failed" }
        let detail = explanation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return detail.isEmpty ? "This message was blocked by AutoMod." : detail
    }

    static func accessibilityStatus(for message: Message) -> String {
        guard message.outboxState == .failed,
              case let .autoModeration(explanation) = message.sendFailure
        else { return accessibilityStatus(for: message.outboxState) }
        let detail = explanation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return detail.isEmpty ? "Blocked by AutoMod" : "Blocked by AutoMod. \(detail)"
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

struct NativeTimelineEditingMessageContent: View {
    @State private var isDismissHovered = false

    let model: AppModel
    let message: Message
    let save: (String) -> Void
    let cancel: () -> Void
    let react: (String) -> Void
    @State private var editText: String
    @State private var isReactionPickerPresented = false

    init(
        model: AppModel,
        message: Message,
        save: @escaping (String) -> Void,
        cancel: @escaping () -> Void,
        react: @escaping (String) -> Void
    ) {
        self.model = model
        self.message = message
        self.save = save
        self.cancel = cancel
        self.react = react
        _editText = State(initialValue: message.content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(4)) {
            InlineMessageEditor(
                model: model,
                text: $editText,
                canEdit: model.guildTimeoutUntil(in: message.channelID, guildID: message.guildID) == nil,
                save: {
                    guard model.guildTimeoutUntil(in: message.channelID, guildID: message.guildID) == nil else { return }
                    guard let value = MessageEditInputPolicy.submission(
                        from: editText
                    ) else {
                        return
                    }
                    save(value)
                },
                cancel: cancel
            )
            let reactionItems = MessageReactionPresentation.items(
                from: message.reactions
            )
            if !reactionItems.isEmpty {
                MessageReactionStrip(
                    reactions: reactionItems,
                    customEmojiURLsByID: model.customEmojiURLsByID,
                    react: react,
                    loadReactors: { reaction in
                        await model.loadReactionReactors(
                            reaction,
                            on: message
                        )
                    },
                    addReactionControl: {
                        if model.canCreateReactions(on: message) {
                            ReactionActionMenu(
                                model: model,
                                guildID: message.guildID,
                                isPickerPresented:
                                    $isReactionPickerPresented,
                                presentation: .inline,
                                react: react
                            )
                            .id("reaction-picker-\(message.id)-inline")
                        }
                    }
                )
                .disabled(!model.canUpdateReactions(on: message))
            }
            if message.flags.contains(.ephemeral) {
                HStack(spacing: InterfaceScale.metric(4)) {
                    Image(systemName: "eye")
                        .accessibilityHidden(true)
                    Text("Only you can see this")
                    Text("•")
                    Button {
                        model.dismissEphemeralMessage(message)
                    } label: {
                        Text("Dismiss message").underline(isDismissHovered)
                    }
                    .onModalHover { isDismissHovered = $0 }
                    .buttonStyle(.plain)
                    .foregroundStyle(SakuraCordAccentColor.color)
                }
                .font(.interface(.caption))
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
            if message.outboxState == .failed {
                Label(
                    MessageOutboxPresentation.failureText(for: message),
                    systemImage: "exclamationmark.circle"
                )
                .accessibilityLabel(MessageOutboxPresentation.accessibilityStatus(for: message))
                .font(.interface(.caption2))
                .foregroundStyle(.red)
            }
        }
        .accessibilityValue(
            MessageOutboxPresentation.accessibilityStatus(
                for: message
            )
        )
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

enum MessageDeleteConfirmationPolicy {
    static func isBypassed(
        by modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        modifierFlags.contains(.shift)
    }
}

/// Holding Shift alone swaps the hover capsule's quick reactions for
/// message utilities, as in Discord.
enum MessageActionShiftPolicy {
    static func isActive(_ modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags.intersection([.shift, .command, .option, .control]) == .shift
    }
}

struct MessageActionCapsule: View {
    let model: AppModel
    let message: Message
    let canEdit: Bool
    let canDelete: Bool
    let canReact: Bool
    let showsQuickReactions: Bool
    let showsShiftActions: Bool
    @Binding var isReactionPickerPresented: Bool
    let retry: (() -> Void)?
    let edit: () -> Void
    let reply: (() -> Void)?
    let forward: (() -> Void)?
    let react: (String) -> Void
    let copy: () -> Void
    let copyLink: () -> Void
    let copyMessageID: () -> Void
    let markUnread: () -> Void
    let togglePin: (() -> Void)?
    let showMoreActions: () -> Void
    let delete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool { systemReduceMotion || !model.animates(.overlays) }

    var body: some View {
        if message.outboxState == .failed {
            HoverActionPill {
                if message.canRetrySending, let retry {
                    HoverActionButton(
                        systemImage: "arrow.clockwise",
                        help: "Retry send",
                        action: retry
                    )
                }
                HoverActionButton(
                    systemImage: "doc.on.doc",
                    help: "Copy text",
                    action: copy
                )
            }
        } else {
            // The leading section carries its own trailing spacing, so it
            // stays in place while empty without widening the pill.
            HoverActionPill(spacing: 0) {
                leadingActions
                HStack(spacing: HoverActionPillMetrics.spacing) {
                    if canReact {
                        ReactionActionMenu(
                            model: model,
                            guildID: message.guildID,
                            isPickerPresented: $isReactionPickerPresented,
                            react: react
                        )
                        .id("reaction-picker-\(message.id)-toolbar")
                    }
                    if let reply {
                        HoverActionButton(systemImage: "arrowshape.turn.up.left", help: "Reply", action: reply)
                    }
                    if canEdit {
                        HoverActionButton(systemImage: "pencil", help: "Edit message", action: edit)
                    }
                    if let forward {
                        HoverActionButton(
                            systemImage: "arrowshape.turn.up.right",
                            help: "Forward",
                            action: forward
                        )
                    }
                    trailingAction
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.3), value: showsShiftActions)
        }
    }

    /// Quick reactions slide up and out as the Shift utilities rise from
    /// below; releasing Shift plays the same motion in reverse.
    private var leadingActions: some View {
        ZStack(alignment: .trailing) {
            if showsShiftActions {
                HStack(spacing: HoverActionPillMetrics.spacing) {
                    HoverActionButton(systemImage: "number.square", help: "Copy Message ID", action: copyMessageID)
                    HoverActionButton(systemImage: "link", help: "Copy Link", action: copyLink)
                    HoverActionButton(systemImage: "envelope.badge", help: "Mark Unread", action: markUnread)
                    if let togglePin {
                        HoverActionButton(
                            systemImage: message.isPinned ? "pin.slash" : "pin",
                            help: message.isPinned ? "Unpin Message" : "Pin Message",
                            action: togglePin
                        )
                    }
                }
                .padding(.trailing, HoverActionPillMetrics.spacing)
                .transition(variantTransition(isShift: true))
            } else if showsQuickReactions {
                HStack(spacing: HoverActionPillMetrics.spacing) {
                    QuickReactionSection(model: model, message: message, react: react)
                }
                .padding(.trailing, HoverActionPillMetrics.spacing)
                .transition(variantTransition(isShift: false))
            }
        }
        .clipped()
    }

    /// Shift turns More into Delete. Shift is held when it is clicked, so
    /// deletion skips confirmation as it does from the context menu.
    private var trailingAction: some View {
        ZStack {
            if showsShiftActions, canDelete {
                HoverActionButton(systemImage: "trash", help: "Delete message", role: .destructive, action: delete)
                    .transition(variantTransition(isShift: true))
            } else {
                HoverActionButton(systemImage: "ellipsis", help: "More", action: showMoreActions)
                    .transition(variantTransition(isShift: false))
            }
        }
        .clipped()
    }

    private func variantTransition(isShift: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: isShift ? .bottom : .top).combined(with: .opacity)
    }
}

/// Its own view so that only this section tracks the model state it reads.
private struct QuickReactionSection: View {
    let model: AppModel
    let message: Message
    let react: (String) -> Void

    var body: some View {
        let quickReactions = model.quickReactions(for: message)
        if !quickReactions.isEmpty {
            ForEach(quickReactions) { reaction in
                QuickReactionButton(reaction: reaction, customEmojiURLsByID: model.customEmojiURLsByID) {
                    react(reaction.token)
                }
            }
            // One load per section; on ForEach it would run per emoji.
            HoverActionPillDivider()
                .task { await model.loadDiscordEmojiSettings() }
        }
    }
}

private struct QuickReactionButton: View {
    let reaction: QuickReaction
    let customEmojiURLsByID: CustomEmojiImageURLs
    let action: () -> Void

    var body: some View {
        let token = Reaction(emoji: reaction.token, count: 0)
        Button(action: action) {
            HoverActionControlLabel(diameter: HoverActionPillMetrics.controlDiameter) {
                MessageReactionEmoji(
                    reaction: token,
                    url: MessageReactionPresentation.emojiURL(for: token, customEmojiURLsByID: customEmojiURLsByID),
                    size: InterfaceScale.metric(18)
                )
            }
        }
        .buttonStyle(.plain)
        // Discord marks an applied quick reaction only in its tooltip and
        // label; clicking it removes that reaction.
        .help(":\(reaction.name):\n\(reaction.isApplied ? "Click to remove" : "Click to react")")
        .accessibilityLabel(
            reaction.isApplied ? "Click to remove \(reaction.name)" : "Click to react with \(reaction.name)"
        )
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
        let width = presentation.width
        let height = presentation.height
        let cornerRadius = presentation.cornerRadius
        ZStack {
            ConcentricRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(backgroundColor)
                .overlay {
                    ConcentricRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                        .padding(0.5)
                }

            Button {
                presentPicker()
            } label: {
                SakuraCordSystemSymbol.emojiFaceGrinningImage
                    .symbolVariant(.none)
                    .font(.system(
                        size: InterfaceScale.fontSize(
                            NSFont.preferredFont(forTextStyle: .callout).pointSize + 2
                        ),
                        weight: .medium
                    ))
                    .foregroundStyle(.primary)
                    .opacity(presentation == .inline ? 0.8 : 1)
                    .frame(width: width, height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: width, height: height)
        // Hover tracks the square frame, so clicks and the pointer cover it
        // too, as on the other hover action controls.
        .contentShape(Rectangle())
        .pointerStyle(.link)
        .onModalHover { isHovering = $0 }
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
                    allowsPersistentSelection: true,
                    dismiss: { isPickerPresented = false },
                    select: { activation in
                        switch activation.selection {
                        case let .native(value): react(value)
                        case let .custom(emoji): react(emoji.messageToken)
                        }
                        if !activation.keepsPickerPresented {
                            isPickerPresented = false
                        }
                    }
                )
            }
            .frame(
                width: width,
                height: height
            )
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

    var width: CGFloat {
        self == .toolbar
            ? HoverActionPillMetrics.controlDiameter
            : InterfaceScale.metric(30)
    }
    var height: CGFloat {
        self == .toolbar
            ? HoverActionPillMetrics.controlDiameter
            : MessageReactionMetrics.pillHeight
    }
    var cornerRadius: CGFloat {
        self == .toolbar
            ? HoverActionPillMetrics.controlDiameter / 2
            : InterfaceScale.metric(9)
    }
    var popoverEdge: NSRectEdge {
        StableReactionPickerAnchorPolicy.preferredEdge(isInline: self == .inline)
    }
    var pickerAccessibilityIdentifier: String {
        self == .inline ? "reaction-picker-inline" : "reaction-picker-toolbar"
    }
}

enum MessageReplySummary {
    nonisolated struct Prepared: Sendable {
        let source: String
        let text: String
        /// UTF-16 ranges of `text` inside spoilers. Reply bars never reveal
        /// them, so presentation conceals these ranges.
        let spoilerRanges: [NSRange]
    }

    private final class CachedValue {
        let prepared: Prepared

        init(_ prepared: Prepared) {
            self.prepared = prepared
        }
    }

    private static let values: NSCache<NSString, CachedValue> = {
        let cache = NSCache<NSString, CachedValue>()
        cache.countLimit = 2_000
        cache.totalCostLimit = 4 * 1_024 * 1_024
        return cache
    }()

    static let defaultMentionLabel: (RenderedMention) -> String = { mention in
        switch mention.kind {
        case .guildNavigation: GuildNavigationMention(rawValue: mention.id)?.title ?? mention.rawToken
        case .user: "@unknown-user"
        case .role: "@unknown-role"
        case .channel: "#unknown-channel"
        case .channelLink: "Channel link"
        case .message: "Message link"
        }
    }

    /// Plain single-line text, including spoiler contents.
    static func text(
        content: String,
        mentionLabel: (RenderedMention) -> String = defaultMentionLabel
    ) -> String {
        summary(content: content, mentionLabel: mentionLabel).text
    }

    /// Single-line text with its spoiler ranges.
    static func summary(
        content: String,
        mentionLabel: (RenderedMention) -> String = defaultMentionLabel
    ) -> Prepared {
        let source = resolvedSource(content: content, mentionLabel: mentionLabel)
        if let cached = values.object(forKey: source as NSString) {
            return cached.prepared
        }
        let prepared = prepare(source)
        install(prepared)
        return prepared
    }

    /// Text for accessibility, which reads each spoiler as "Spoiler".
    static func accessibilityText(
        content: String,
        mentionLabel: (RenderedMention) -> String = defaultMentionLabel
    ) -> String {
        let prepared = summary(content: content, mentionLabel: mentionLabel)
        let text = NSMutableString(string: prepared.text)
        for range in prepared.spoilerRanges.reversed() {
            text.replaceCharacters(in: range, with: "Spoiler")
        }
        return text as String
    }

    static func preparation(
        content: String,
        mentionLabel: (RenderedMention) -> String
    ) -> String? {
        let source = resolvedSource(content: content, mentionLabel: mentionLabel)
        return values.object(forKey: source as NSString) == nil ? source : nil
    }

    private static func resolvedSource(
        content: String,
        mentionLabel: (RenderedMention) -> String
    ) -> String {
        let document = MessageDocumentCache.shared.document(for: content)
        return document.segments.reduce(into: "") { output, segment in
            switch segment {
            case let .markdown(value):
                output += value
            case let .customEmoji(emoji):
                output += ":\(emoji.name):"
            case let .mention(mention):
                output += mentionLabel(mention)
            }
        }
    }

    /// Collapses the rendered text's whitespace to single spaces. A collapsed
    /// space is a spoiler only inside one spoiler, and adjacent spoilers stay
    /// separate ranges.
    nonisolated static func prepare(_ source: String) -> Prepared {
        var text = ""
        var spoilerRanges: [NSRange] = []
        var length = 0
        var pendingSpace = false
        var previousSpoilerID: Int?
        var rangeSpoilerID: Int?

        func append(_ value: String, spoilerID: Int?) {
            let valueLength = value.utf16.count
            if let spoilerID {
                if let last = spoilerRanges.last,
                   NSMaxRange(last) == length,
                   rangeSpoilerID == spoilerID
                {
                    spoilerRanges[spoilerRanges.count - 1].length += valueLength
                } else {
                    spoilerRanges.append(NSRange(location: length, length: valueLength))
                    rangeSpoilerID = spoilerID
                }
            }
            text += value
            length += valueLength
        }

        for run in DiscordMarkdown.plainTextRuns(source) {
            for character in run.text {
                if character.isWhitespace {
                    pendingSpace = !text.isEmpty
                    continue
                }
                if pendingSpace {
                    append(
                        " ",
                        spoilerID: previousSpoilerID == run.spoilerID ? run.spoilerID : nil
                    )
                    pendingSpace = false
                }
                append(String(character), spoilerID: run.spoilerID)
                previousSpoilerID = run.spoilerID
            }
        }
        guard !text.isEmpty else {
            return Prepared(source: source, text: "Attachment", spoilerRanges: [])
        }
        return Prepared(source: source, text: text, spoilerRanges: spoilerRanges)
    }

    static func install(_ prepared: Prepared) {
        values.setObject(
            CachedValue(prepared),
            forKey: prepared.source as NSString,
            cost: prepared.source.utf8.count + prepared.text.utf8.count
        )
    }
}

enum MessageEditLayoutMetrics {
    nonisolated static var editorFooterSpacing: CGFloat { InterfaceScale.metric(2) }
    nonisolated static var footerVerticalPadding: CGFloat { InterfaceScale.metric(0) }
    nonisolated static var footerHorizontalPadding: CGFloat { InterfaceScale.metric(0) }
    nonisolated static var actionHeight: CGFloat { InterfaceScale.metric(22) }
    nonisolated static var actionHorizontalPadding: CGFloat { InterfaceScale.metric(5) }
    nonisolated static var keycapHorizontalPadding: CGFloat { InterfaceScale.metric(5) }
    nonisolated static var keycapVerticalPadding: CGFloat { InterfaceScale.metric(1) }

    nonisolated static var footerIntrinsicHeight: CGFloat {
        actionHeight + (footerVerticalPadding * 2)
    }

    nonisolated static var verticalContributionBelowEditor: CGFloat {
        editorFooterSpacing + footerIntrinsicHeight
    }
}

struct InlineMessageEditorComposerActions {
    let onSubmit: () -> Void
    let onEscape: () -> Void
}

private struct InlineMessageEditor: View {
    let model: AppModel
    @Binding var text: String
    let canEdit: Bool
    let save: () -> Void
    let cancel: () -> Void
    @State private var selection: NSRange?
    @State private var isFocused = true
    @State private var autocompleteIndex = 0
    @State private var isAutocompleteDismissed = false

    private var composerActions: InlineMessageEditorComposerActions {
        InlineMessageEditorComposerActions(
            onSubmit: save,
            onEscape: cancel
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MessageEditLayoutMetrics.editorFooterSpacing) {
            if let context, !suggestions.isEmpty {
                EmojiAutocompleteList(
                    suggestions: suggestions,
                    selectedIndex: autocompleteIndex,
                    highlight: { autocompleteIndex = $0 },
                    select: { accept($0, context: context) }
                )
            }
            ComposerTextView(
                text: text,
                placeholder: "Edit message",
                sendWithReturn: MessageEditInputPolicy.sendsWithReturn,
                generalInputSettings: model.generalInputSettings,
                onTextChange: { text = $0 },
                onSubmit: composerActions.onSubmit,
                onEscape: composerActions.onEscape,
                onAutocompleteCommand: handleAutocomplete,
                capturesUnfocusedTyping: true,
                selection: $selection,
                isFocused: $isFocused
            )
                .disabled(!canEdit)
                .padding(InterfaceScale.metric(9))
                .background(
                    Color.primary.opacity(0.065),
                    in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(8), style: .continuous)
                )
                .overlay {
                    ConcentricRectangle(cornerRadius: InterfaceScale.metric(8), style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                        .padding(0.5)
                }
                .accessibilityLabel("Message text")
                .accessibilityHint("Press Return to save, Shift-Return for a new line, or Escape to cancel.")
                .onExitCommand(perform: cancel)
            InlineMessageEditFooter(
                canSave: canEdit && MessageEditInputPolicy.submission(from: text) != nil,
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
        !canEdit || isAutocompleteDismissed ? nil : ColonAutocompleteContext(text: text, selection: selection)
    }

    private var suggestions: [ColonAutocompleteSuggestion] {
        guard let context else { return [] }
        return ColonAutocompleteSuggestionFactory.suggestions(
            query: context.query,
            customEmojis: model.composerCustomEmojis,
            customValue: model.composerText(for:),
            customSource: { model.serverRailGuildsByID[$0.guildID]?.name },
            discordFavoriteKeys: Set(model.discordFavoriteEmojiKeys),
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
        isAutocompleteDismissed = true
    }
}

private struct InlineMessageEditFooter: View {
    let canSave: Bool
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: InterfaceScale.metric(12)) {
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
            HStack(spacing: InterfaceScale.metric(4)) {
                Text(title)
                    .font(.interface(.caption).weight(.semibold))
                InlineEditKeycap(key: key, isActive: isHovering && isEnabled)
            }
            .foregroundStyle(isHovering && isEnabled ? .primary : .secondary)
            .padding(.horizontal, MessageEditLayoutMetrics.actionHorizontalPadding)
            .frame(height: MessageEditLayoutMetrics.actionHeight)
            .background {
                ConcentricRectangle(cornerRadius: InterfaceScale.metric(5), style: .continuous)
                    .fill(Color.primary.opacity(isHovering && isEnabled ? 0.09 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onModalHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct InlineEditKeycap: View {
    let key: LocalizedStringKey
    let isActive: Bool

    var body: some View {
        Text(key)
            .font(.interface(.caption2).monospaced().weight(.semibold))
            .foregroundStyle(isActive ? .primary : .secondary)
            .padding(.horizontal, MessageEditLayoutMetrics.keycapHorizontalPadding)
            .padding(.vertical, MessageEditLayoutMetrics.keycapVerticalPadding)
            .background(.quaternary, in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(4), style: .continuous))
            .accessibilityHidden(true)
    }
}

struct MessageProfilePopoverContent: View {
    let model: AppModel
    let userID: UserID
    let requestID: UUID

    var body: some View {
        Group {
            if let presentation = model.liveProfilePresentation(for: .contextual),
               presentation.member.id == userID,
               presentation.requestID == requestID
            {
                ProfilePresentationContent(presentation: presentation, openProfile: model.expandProfile, userMenu: {
                    UserContextMenu.make(for: presentation.member.user, context: .init(guildID: presentation.guildID), model: model)
                }, sendMessage: model.sendProfileMessage)
                    .environment(\.profileCosmeticPolicy, model.cosmeticPolicy)
                    .environment(\.serverTagCardModel, model)
            } else {
                Color.clear.frame(width: InterfaceScale.metric(330), height: InterfaceScale.metric(250))
            }
        }
        .onDisappear {
            model.dismissContextualProfile(requestID: requestID)
        }
    }
}
