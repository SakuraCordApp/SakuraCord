import AppKit
import MessageRendering
import SakuraCordModels
import SwiftUI

enum MessageRowLayoutMetrics {
    nonisolated static let avatarDiameter: CGFloat = 38
    nonisolated static let compactContentHeight: CGFloat = 18
    nonisolated static let authorLineHeight: CGFloat = 16
    nonisolated static let authorContentSpacing: CGFloat = 4
    nonisolated static let commandAuthorContentSpacing: CGFloat = 2
    nonisolated static let firstMessageContentOffset: CGFloat = 12
    nonisolated static let visibleHighlightInset: CGFloat = 3
    nonisolated static let replyPreviewIntrinsicTopInset: CGFloat = 3
    nonisolated static let editFooterIntrinsicBottomInset: CGFloat = 3
    nonisolated static let commandInvocationHeight: CGFloat = 20
    nonisolated static let commandInvocationContentInset: CGFloat = 3

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
        followsTimelineSeparator: Bool = false,
        highlightTopInset: CGFloat
    ) -> CGFloat {
        // Date and unread separators already provide the complete visual gap
        // between adjacent messages. Applying the ordinary author-group
        // separation after either one makes the lower half visibly larger
        // than the upper half.
        guard startsGroup, !followsTimelineSeparator else { return 0 }
        return firstMessageContentOffset - highlightTopInset
    }

    nonisolated static func authorToContentSpacing(
        isCommandResponse: Bool
    ) -> CGFloat {
        isCommandResponse
            ? commandAuthorContentSpacing
            : authorContentSpacing
    }

    nonisolated static func geometry(
        contentHeight: CGFloat,
        startsGroup: Bool,
        hasReplyPreview: Bool = false,
        isEditing: Bool = false,
        followsTimelineSeparator: Bool = false
    ) -> MessageRowLayoutGeometry {
        let insets = highlightInsets(hasReplyPreview: hasReplyPreview, isEditing: isEditing)
        let externalSeparation = separation(
            startsGroup: startsGroup,
            followsTimelineSeparator: followsTimelineSeparator,
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

nonisolated enum MessageRowPersistentHighlight: Equatable {
    case none
    case ephemeral
    case mention

    static func resolve(
        message: Message,
        currentUserID: UserID?,
        currentUserRoleIDs: Set<RoleID> = []
    ) -> Self {
        if message.flags.contains(.ephemeral) {
            return .ephemeral
        }
        guard let currentUserID,
              message.author.id != currentUserID
        else {
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

struct NativeTimelineEditingMessageContent: View {
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
        VStack(alignment: .leading, spacing: 4) {
            InlineMessageEditor(
                model: model,
                text: $editText,
                save: {
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
                )
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
                Label(
                    "Failed",
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption2)
                .foregroundStyle(.red)
            }
        }
        .accessibilityValue(
            MessageOutboxPresentation.accessibilityStatus(
                for: message.outboxState
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

struct MessageActionCapsule: View {
    let model: AppModel
    let message: Message
    let canEdit: Bool
    @Binding var isReactionPickerPresented: Bool
    @Binding var isDeleteConfirmationPresented: Bool
    let retry: (() -> Void)?
    let edit: () -> Void
    let reply: (() -> Void)?
    let react: (String) -> Void
    let copy: () -> Void
    let copyLink: () -> Void
    let openThread: (() -> Void)?
    let delete: () -> Void

    var body: some View {
        if isDeleteConfirmationPresented {
            deleteConfirmation
        } else {
            actions
        }
    }

    private var actions: some View {
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
                    systemImage: "trash",
                    help: "Delete message",
                    role: .destructive
                ) {
                    isDeleteConfirmationPresented = true
                }
            }
        }
    }

    private var deleteConfirmation: some View {
        HoverActionPill {
            Text("Delete message?")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 4)
            HoverActionButton(
                systemImage: "xmark",
                help: "Cancel deletion"
            ) {
                isDeleteConfirmationPresented = false
            }
            HoverActionButton(
                systemImage: "trash.fill",
                help: "Delete message",
                role: .destructive
            ) {
                isDeleteConfirmationPresented = false
                delete()
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
            ConcentricRectangle(cornerRadius: presentation.cornerRadius, style: .continuous)
                .fill(backgroundColor)
                .overlay {
                    ConcentricRectangle(cornerRadius: presentation.cornerRadius, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                        .padding(0.5)
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
                        ConcentricRectangle(cornerRadius: presentation.cornerRadius, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
        }
        .frame(width: presentation.width, height: presentation.height)
        .contentShape(
            ConcentricRectangle(cornerRadius: presentation.cornerRadius, style: .continuous)
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

struct InlineMessageEditorComposerActions {
    let onSubmit: () -> Void
    let onEscape: () -> Void
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
                onTextChange: { text = $0 },
                onSubmit: composerActions.onSubmit,
                onEscape: composerActions.onEscape,
                onAutocompleteCommand: handleAutocomplete,
                capturesUnfocusedTyping: true,
                selection: $selection,
                isFocused: $isFocused
            )
                .padding(9)
                .background(
                    Color.primary.opacity(0.065),
                    in: ConcentricRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    ConcentricRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                        .padding(0.5)
                }
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
                ConcentricRectangle(cornerRadius: 5, style: .continuous)
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
            .background(.quaternary, in: ConcentricRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct MessageProfilePopoverContent: View {
    let model: AppModel
    let userID: UserID

    var body: some View {
        Group {
            if let presentation = model.contextualProfilePresentation,
               presentation.member.id == userID
            {
                ProfilePresentationContent(presentation: presentation)
            } else {
                Color.clear.frame(width: 330, height: 250)
            }
        }
        .onDisappear {
            model.dismissContextualProfile(for: userID)
        }
    }
}
