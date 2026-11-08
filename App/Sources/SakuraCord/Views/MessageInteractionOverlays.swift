import AppKit
import CoreText
import MessageRendering
import SakuraCordModels
import SwiftUI

enum MessageRowLayoutMetrics {
    nonisolated static var horizontalInset: CGFloat { InterfaceScale.metric(14) }
    nonisolated static var avatarDiameter: CGFloat { InterfaceScale.metric(38) }
    nonisolated static var avatarColumnGap: CGFloat { InterfaceScale.metric(12) }
    /// Forwarded content's indent past its 3-point bar.
    nonisolated static var forwardedContentInset: CGFloat { InterfaceScale.metric(11) }
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

/// The text of a message being edited inline, shared by its editor and
/// its Cancel and Save controls.
@Observable
final class NativeTimelineInlineEditDraft {
    var text: String
    /// Saved, and waiting for the timeline to show it.
    var isSaving = false
    /// Emoji suggestions open below the editor when there is no room above.
    var showsSuggestionsBelow = false

    init(text: String) {
        self.text = text
    }
}

/// Edits a message's text where the timeline draws it, in the same type,
/// without a field around it; the timeline keeps drawing the rest of the row.
struct NativeTimelineEditingMessageContent: View {
    let model: AppModel
    let message: Message
    @Bindable var draft: NativeTimelineInlineEditDraft
    /// An outgoing bubble's accent fill, which takes white text and caret.
    let isOnOutgoingBubble: Bool
    let save: (String) -> Void
    let cancel: () -> Void
    let editorHeightDidChange: (CGFloat) -> Void
    let draftDidChange: () -> Void

    var body: some View {
        InlineMessageEditor(
            model: model,
            message: message,
            text: $draft.text,
            canEdit: model.guildTimeoutUntil(in: message.channelID, guildID: message.guildID) == nil,
            save: {
                guard model.guildTimeoutUntil(in: message.channelID, guildID: message.guildID) == nil,
                      let value = MessageEditInputPolicy.submission(from: draft.text)
                else { return }
                save(value)
            },
            cancel: cancel,
            isOnOutgoingBubble: isOnOutgoingBubble,
            suggestionsBelow: draft.showsSuggestionsBelow,
            editorHeightDidChange: editorHeightDidChange
        )
        .disabled(draft.isSaving)
        .onChange(of: draft.text) { draftDidChange() }
    }
}

/// Cancel and Save for an inline edit, in the place of the row's hover actions.
struct NativeTimelineInlineEditControls: View {
    let draft: NativeTimelineInlineEditDraft
    let canEdit: () -> Bool
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        HoverActionPill {
            InlineEditTextButton(title: "Cancel", key: "esc", action: cancel)
                .keyboardShortcut(.cancelAction)
                .accessibilityHint("Discards your changes. Keyboard shortcut: Escape.")
            let canSave = canEdit() && MessageEditInputPolicy.submission(from: draft.text) != nil
            InlineEditTextButton(title: "Save", key: "↵", action: save)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint(
                    canSave
                        ? "Saves your edited message. Keyboard shortcut: Return."
                        : "Enter message text before saving."
                )
                .disabled(!canSave)
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Edit message")
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
        case .game, .broadcast, .command, .timestamp: MentionPresentation.fallback(for: mention).label
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
    /// The timeline's plain message text, so a draft is set in the font,
    /// colour and line height the row drew the message in.
    static func textStyle(isOnOutgoingBubble: Bool) -> ComposerTextStyle {
        let style = messageTextStyle
        guard isOnOutgoingBubble else { return style }
        // The timeline sets an outgoing bubble's text in white.
        var attributes = style.attributes
        attributes[.foregroundColor] = NSColor.white
        return ComposerTextStyle(font: style.font, attributes: attributes, usesMessageLineHeight: true)
    }

    /// The message text style at the current interface size, worked out once per size.
    private static var messageTextStyle: ComposerTextStyle {
        let fontSize = InterfaceScale.fontSize(InterfaceTypographyMetrics.messageTextSize)
        if let cached = messageTextCache, cached.fontSize == fontSize { return cached.style }
        let attributes = DiscordMarkdown.appKitAttributed(
            DiscordMarkdown.appKitPlan("x"), baseFontSize: fontSize, usesMessageLineHeight: true
        ).attributes(at: 0, effectiveRange: nil)
        guard let font = attributes[.font] as? NSFont else {
            preconditionFailure("The markdown renderer sets a font on message text.")
        }
        let style = ComposerTextStyle(font: font, attributes: attributes, usesMessageLineHeight: true)
        messageTextCache = (fontSize, style)
        return style
    }

    private static var messageTextCache: (fontSize: CGFloat, style: ComposerTextStyle)?

    nonisolated static var actionHorizontalPadding: CGFloat { InterfaceScale.metric(5) }
    nonisolated static var keycapHorizontalPadding: CGFloat { InterfaceScale.metric(5) }
    nonisolated static var keycapVerticalPadding: CGFloat { InterfaceScale.metric(1) }
}

struct InlineMessageEditorComposerActions {
    let onSubmit: () -> Void
    let onEscape: () -> Void
}

private struct InlineMessageEditor: View {
    let model: AppModel
    /// The message being edited, whose mentioned users resolve its mentions.
    let message: Message
    @Binding var text: String
    let canEdit: Bool
    let save: () -> Void
    let cancel: () -> Void
    let isOnOutgoingBubble: Bool
    let suggestionsBelow: Bool
    let editorHeightDidChange: (CGFloat) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: NSRange?
    @State private var isFocused = true
    @State private var autocompleteIndex = 0
    @State private var isAutocompleteDismissed = false
    @State private var activeTimeEntry: TimeMentionEntry?
    @State private var timeReferenceDate: Date?
    @State private var autocompleteKeyboardSelectionRevision = 0

    /// Game names and people resolve as they do in the message, and update
    /// as games load.
    private var mentionPresentations: [String: MentionPresentation] {
        _ = model.timelinePresentationRevision
        // The message as it is now: an update while editing can bring newer
        // details for the people it mentions.
        let current = model.retainedMessage(channelID: message.channelID, messageID: message.id) ?? message
        return MessageMentionResolver(model: model, message: current).presentations(in: text)
    }

    private var composerActions: InlineMessageEditorComposerActions {
        InlineMessageEditorComposerActions(
            onSubmit: {
                if activeTimeEntry != nil {
                    acceptActiveTimeEntry()
                }
                save()
            },
            onEscape: cancelEditing
        )
    }

    private func cancelEditing() {
        if let entry = activeTimeEntry {
            text = TimeMentionCoordinator.restoredDraftText(for: entry)
            activeTimeEntry = nil
        }
        cancel()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(4)) {
            if !suggestionsBelow { suggestionList }
            if let timeEntry = activeTimeEntry {
                TimeMentionInputView(
                    query: Binding(
                        get: { activeTimeEntry?.query ?? "" },
                        set: { value in
                            guard var entry = activeTimeEntry else { return }
                            entry.query = value
                            activeTimeEntry = entry
                            text = TimeMentionCoordinator.restoredDraftText(for: entry)
                            autocompleteIndex = 0
                            isAutocompleteDismissed = false
                        }
                    ),
                    prefix: timeEntry.prefix,
                    suffix: timeEntry.suffix,
                    mentionPresentations: mentionPresentations,
                    onAccept: acceptActiveTimeEntry,
                    onCancel: cancelTimeEntry,
                    onCommand: { command in
                        guard let context = timeMentionContext else { return false }
                        return handleTimeAutocomplete(command, context: context)
                    }
                )
            } else {
                ComposerTextView(
                    text: text,
                    placeholder: "Edit message",
                    sendWithReturn: MessageEditInputPolicy.sendsWithReturn,
                    generalInputSettings: model.generalInputSettings,
                    mentionPresentations: mentionPresentations,
                    onTextChange: updateText,
                    onSubmit: composerActions.onSubmit,
                    onEscape: composerActions.onEscape,
                    onAutocompleteCommand: handleAutocomplete,
                    capturesUnfocusedTyping: true,
                    maximumHeight: .greatestFiniteMagnitude,
                    insertionPointColor: isOnOutgoingBubble ? .white : nil,
                    textStyle: MessageEditLayoutMetrics.textStyle(isOnOutgoingBubble: isOnOutgoingBubble),
                    scrolls: false,
                    accessibilityHint: "Press Return to save, Shift-Return for a new line, or Escape to cancel.",
                    selection: $selection,
                    isFocused: $isFocused
                )
                    // The timeline sets an outgoing bubble's text in white.
                    .environment(\.colorScheme, isOnOutgoingBubble ? .dark : colorScheme)
                    .disabled(!canEdit)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height, action: editorHeightDidChange)
                    .onExitCommand(perform: cancelEditing)
            }
            if suggestionsBelow { suggestionList }
        }
        .onChange(of: selection) { _, _ in
            isAutocompleteDismissed = false
            autocompleteIndex = 0
        }
        .onChange(of: timeMentionContext?.query) { _, _ in
            timeReferenceDate = Date.now
        }
        .onChange(of: timeMentionContext != nil) { _, active in
            if active, timeReferenceDate == nil {
                timeReferenceDate = Date.now
            } else if !active {
                timeReferenceDate = nil
            }
        }
        .onDisappear {
            if let entry = activeTimeEntry {
                text = TimeMentionCoordinator.restoredDraftText(for: entry)
                activeTimeEntry = nil
            }
        }
    }

    @ViewBuilder
    private var suggestionList: some View {
        if let context = timeMentionContext {
            TimeFormatsAutocompleteList(
                heading: context.query.isEmpty ? "Time formats" : "Time formats for \(context.query.lowercased())",
                candidates: timeCandidates,
                selectedIndex: autocompleteIndex,
                highlight: { autocompleteIndex = $0 },
                select: { acceptTimeFormat($0, context: context) },
                keyboardSelectionRevision: autocompleteKeyboardSelectionRevision
            )
        } else if let context = mentionAutocompleteContext {
            let suggestions = mentionAutocompleteSuggestions(for: context)
            if !suggestions.isEmpty {
                MentionAutocompleteList(
                    heading: TimeMentionCoordinator.mentionHeading(for: context, suggestions: suggestions),
                    suggestions: suggestions,
                    selectedIndex: autocompleteIndex,
                    highlight: { autocompleteIndex = $0 },
                    select: { acceptMentionAutocomplete($0, context: context) },
                    keyboardSelectionRevision: autocompleteKeyboardSelectionRevision
                )
            }
        } else if let context = colonContext, !colonSuggestions.isEmpty {
            EmojiAutocompleteList(
                suggestions: colonSuggestions,
                selectedIndex: autocompleteIndex,
                highlight: { autocompleteIndex = $0 },
                select: { acceptColon($0, context: context) },
                keyboardSelectionRevision: autocompleteKeyboardSelectionRevision
            )
        }
    }

    private func updateText(_ value: String) {
        if activeTimeEntry == nil,
           let rawContext = TimeMentionContext(text: value, selection: selection) {
            let nsText = value as NSString
            let prefix = nsText.substring(to: rawContext.range.location)
            let suffix = nsText.substring(from: rawContext.range.location + rawContext.range.length)
            let entry = TimeMentionEntry(prefix: prefix, query: rawContext.rawQuery, suffix: suffix)
            activeTimeEntry = entry
            text = TimeMentionCoordinator.restoredDraftText(for: entry)
            autocompleteIndex = 0
            isAutocompleteDismissed = false
            return
        }
        text = value
        isAutocompleteDismissed = false
        autocompleteIndex = 0
    }

    private var timeMentionContext: TimeMentionContext? {
        TimeMentionCoordinator.context(
            entry: activeTimeEntry,
            text: text,
            selection: selection,
            isDismissed: isAutocompleteDismissed
        )
    }

    private var timeCandidates: [DiscordParsedTimeCandidate] {
        TimeMentionCoordinator.candidates(
            for: timeMentionContext,
            referenceDate: timeReferenceDate
        )
    }

    private var allTimeOptions: [DiscordParsedTimeCandidate.Option] {
        TimeMentionCoordinator.allOptions(for: timeCandidates)
    }

    private var mentionAutocompleteContext: MentionAutocompleteContext? {
        guard !isAutocompleteDismissed else { return nil }
        return MentionAutocompleteContext(text: text, selection: selection)
    }

    private func mentionAutocompleteSuggestions(
        for context: MentionAutocompleteContext
    ) -> [MentionAutocompleteSuggestion] {
        switch context.kind {
        case .member:
            return MentionAutocompleteSuggestionFactory.memberSuggestions(
                query: context.query,
                recentMessages: [],
                localMembers: model.mentionAutocompleteMembers.filter { !model.isUserIgnored($0.id) },
                remoteMembers: model.mentionMemberResults.filter { !model.isUserIgnored($0.id) },
                roles: model.guildRoles,
                canMentionNonMentionableRoles: false
            )
        case .channel:
            return MentionAutocompleteSuggestionFactory.channelSuggestions(
                query: context.query,
                channels: model.visibleChannels,
                guilds: model.serverRailGuildsByID,
                guildAndChannelUsageScores: model.discordGuildAndChannelUsageScores,
                currentUserID: model.currentUser?.id,
                currentMember: (model.currentUser?.id).flatMap { model.membersByID[$0] },
                roles: model.guildRoles
            )
        }
    }

    private var colonContext: ColonAutocompleteContext? {
        !canEdit || isAutocompleteDismissed ? nil : ColonAutocompleteContext(text: text, selection: selection)
    }

    private var colonSuggestions: [ColonAutocompleteSuggestion] {
        guard let colonContext else { return [] }
        return ColonAutocompleteSuggestionFactory.suggestions(
            query: colonContext.query,
            customEmojis: model.composerCustomEmojis,
            customValue: model.composerText(for:),
            customSource: { model.serverRailGuildsByID[$0.guildID]?.name },
            discordFavoriteKeys: Set(model.discordFavoriteEmojiKeys),
            discordUsageScores: model.discordEmojiUsageScores,
            discordSettingsAreLoaded: model.hasLoadedDiscordEmojiSettings
        )
    }

    private func handleAutocomplete(_ command: ComposerAutocompleteCommand) -> Bool {
        if let context = timeMentionContext {
            return handleTimeAutocomplete(command, context: context)
        }
        if let context = mentionAutocompleteContext {
            return handleMentionAutocomplete(command, context: context)
        }
        if let context = colonContext {
            return handleColonAutocomplete(command, context: context)
        }
        return false
    }

    private func handleTimeAutocomplete(
        _ command: ComposerAutocompleteCommand,
        context: TimeMentionContext
    ) -> Bool {
        TimeMentionCoordinator.handleAutocomplete(
            command,
            options: allTimeOptions,
            currentIndex: &autocompleteIndex,
            keyboardRevision: &autocompleteKeyboardSelectionRevision,
            onAccept: { acceptTimeFormat($0, context: context) },
            onDismiss: {
                if activeTimeEntry != nil {
                    cancelTimeEntry()
                } else {
                    isAutocompleteDismissed = true
                }
            }
        )
    }

    private func handleMentionAutocomplete(
        _ command: ComposerAutocompleteCommand,
        context: MentionAutocompleteContext
    ) -> Bool {
        let suggestions = mentionAutocompleteSuggestions(for: context)
        guard !suggestions.isEmpty else { return false }
        if command == .previous || command == .next { autocompleteKeyboardSelectionRevision &+= 1 }
        switch command {
        case .previous:
            autocompleteIndex = (autocompleteIndex - 1 + suggestions.count) % suggestions.count
            return true
        case .next:
            autocompleteIndex = (autocompleteIndex + 1) % suggestions.count
            return true
        case .accept, .advance:
            acceptMentionAutocomplete(
                suggestions[min(autocompleteIndex, suggestions.count - 1)],
                context: context
            )
            return true
        case .dismiss:
            isAutocompleteDismissed = true
            return true
        default:
            return false
        }
    }

    private func handleColonAutocomplete(
        _ command: ComposerAutocompleteCommand,
        context: ColonAutocompleteContext
    ) -> Bool {
        guard !colonSuggestions.isEmpty else { return false }
        if command == .previous || command == .next { autocompleteKeyboardSelectionRevision &+= 1 }
        switch command {
        case .previous:
            autocompleteIndex = (autocompleteIndex - 1 + colonSuggestions.count) % colonSuggestions.count
            return true
        case .next:
            autocompleteIndex = (autocompleteIndex + 1) % colonSuggestions.count
            return true
        case .accept, .advance:
            acceptColon(colonSuggestions[min(autocompleteIndex, colonSuggestions.count - 1)], context: context)
            return true
        case .dismiss:
            isAutocompleteDismissed = true
            return true
        default:
            return false
        }
    }

    private func acceptTimeFormat(
        _ option: DiscordParsedTimeCandidate.Option,
        context: TimeMentionContext? = nil
    ) {
        let result = TimeMentionCoordinator.accept(
            option: option,
            entry: activeTimeEntry,
            context: context,
            currentText: text
        )
        activeTimeEntry = nil
        autocompleteIndex = 0
        isAutocompleteDismissed = true
        text = result.text
        selection = result.selection
    }

    private func acceptActiveTimeEntry() {
        guard let entry = activeTimeEntry else { return }
        let option = allTimeOptions.indices.contains(autocompleteIndex)
            ? allTimeOptions[autocompleteIndex]
            : allTimeOptions.first
        let result = TimeMentionCoordinator.acceptActiveEntry(
            entry: entry,
            selectedOption: option
        )
        activeTimeEntry = nil
        autocompleteIndex = 0
        isAutocompleteDismissed = true
        text = result.text
        selection = result.selection
    }

    private func cancelTimeEntry() {
        guard let entry = activeTimeEntry else { return }
        let result = TimeMentionCoordinator.cancelActiveEntry(entry: entry)
        activeTimeEntry = nil
        autocompleteIndex = 0
        isAutocompleteDismissed = true
        text = result.text
        selection = result.selection
    }

    private func acceptMentionAutocomplete(
        _ suggestion: MentionAutocompleteSuggestion,
        context: MentionAutocompleteContext
    ) {
        if suggestion.id == "special:time" {
            let nsText = text as NSString
            let prefix = nsText.substring(to: context.range.location)
            let suffix = nsText.substring(from: context.range.location + context.range.length)
            let entry = TimeMentionEntry(prefix: prefix, query: "", suffix: suffix)
            activeTimeEntry = entry
            text = TimeMentionCoordinator.restoredDraftText(for: entry)
            autocompleteIndex = 0
            isAutocompleteDismissed = false
            return
        }
        let nsText = text as NSString
        let replacement = suggestion.value + " "
        text = nsText.replacingCharacters(in: context.range, with: replacement)
        selection = NSRange(
            location: context.range.location + replacement.utf16.count,
            length: 0
        )
        autocompleteIndex = 0
        isAutocompleteDismissed = true
    }

    private func acceptColon(_ suggestion: ColonAutocompleteSuggestion, context: ColonAutocompleteContext) {
        let value = text as NSString
        text = value.replacingCharacters(in: context.range, with: suggestion.value)
        selection = NSRange(
            location: context.range.location + suggestion.value.utf16.count, length: 0
        )
        isAutocompleteDismissed = true
    }
}

/// A text action drawn as the row's hover actions are.
private struct InlineEditTextButton: View {
    let title: LocalizedStringKey
    let key: LocalizedStringKey
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HoverActionControlLabel {
                HStack(spacing: InterfaceScale.metric(4)) {
                    Text(title)
                        .font(.interface(.caption).weight(.semibold))
                    Text(key)
                        .font(.interface(.caption2).monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, MessageEditLayoutMetrics.keycapHorizontalPadding)
                        .padding(.vertical, MessageEditLayoutMetrics.keycapVerticalPadding)
                        .background(.quaternary, in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(4), style: .continuous))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, MessageEditLayoutMetrics.actionHorizontalPadding)
            }
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
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
