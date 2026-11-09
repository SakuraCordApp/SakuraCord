import MessageRendering
import SakuraCordModels
import SwiftUI

/// A forum post's body: the message composer's text view with its emoji,
/// mention, channel and `@time` suggestions. Cmd-Return posts.
struct ForumPostBodyEditor: View {
    let model: AppModel
    @Binding var text: String
    @Binding var selection: NSRange?
    @Binding var isFocused: Bool
    let submit: () -> Void
    let receiveAttachments: (ComposerIncomingAttachments) -> Void
    @State private var autocompleteIndex = 0
    @State private var keyboardSelectionRevision = 0
    @State private var isAutocompleteDismissed = false
    @State private var timeQueryDate = Date.now
    @State private var timeQueryNeedsPick = false
    @State private var timestampClock = RelativeTimestampDisplayClock()
    @State private var emojiCache = ColonAutocompleteSuggestionCache()

    var body: some View {
        ComposerTextView(
            text: text,
            placeholder: "Write your post",
            sendWithReturn: false,
            generalInputSettings: model.generalInputSettings,
            mentionPresentations: mentionPresentations,
            onTextChange: { text = $0 },
            onSubmit: submit,
            onAutocompleteCommand: handleAutocomplete,
            onReceiveAttachments: { attachments, _ in
                receiveAttachments(attachments)
                return true
            },
            canReceiveAttachments: { model.canAttachFilesToForumPosts },
            maximumHeight: .greatestFiniteMagnitude,
            accessibilityHint: "Press Command-Return to post.",
            selection: $selection,
            isFocused: $isFocused
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            if text.isEmpty {
                Text("Write your post")
                    .font(.interfaceSystem(size: 15))
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        // Suggestions rise from the bottom of the field, clear of the line
        // being typed near its top.
        .overlay(alignment: .bottom) {
            if isFocused, let menu {
                suggestionList(menu)
                    .transition(.opacity.combined(with: .offset(y: InterfaceScale.metric(6))))
            }
        }
        .animation(ComposerResizeMotion.isReduced ? nil : ComposerResizeMotion.hover, value: menu?.kind)
        .onChange(of: text) { _, _ in
            isAutocompleteDismissed = false
            timeQueryNeedsPick = false
            autocompleteIndex = 0
        }
        .onChange(of: selection) { _, _ in
            isAutocompleteDismissed = false
            autocompleteIndex = 0
        }
        .onChange(of: mentionContext?.query) { _, _ in updateMemberSearch() }
        .onChange(of: timeContext?.query) { timeQueryDate = .now }
        // A relative time counts on while it is written, as in the composer.
        .onChange(of: text.contains(":R>"), initial: true) { _, counts in
            counts ? timestampClock.start() : timestampClock.stop()
        }
        .onDisappear {
            timestampClock.stop()
            model.requestMentionMemberSearch(query: "")
        }
    }

    private var mentionPresentations: [String: MentionPresentation] {
        let values = MessageMentionResolver(model: model).presentations(in: text)
        return text.contains(":R>") ? TimestampMentionPresentation.refreshed(values, source: text, at: timestampClock.date) : values
    }

    // MARK: Suggestions

    /// The open menu, worked out once per update: hovering a row while
    /// scrolling redraws this view, and ranking every emoji again then
    /// stutters the scroll.
    private var menu: ForumPostSuggestionMenu? {
        if let context = emojiContext, case let suggestions = emojiSuggestions(for: context), !suggestions.isEmpty {
            return .emoji(context, suggestions)
        }
        if let context = mentionContext, case let suggestions = mentionSuggestions(for: context), !suggestions.isEmpty {
            return .mention(context, suggestions)
        }
        if let context = timeContext, case let rows = timeRows(for: context), timeQueryNeedsPick || !rows.isEmpty {
            return .time(context, rows)
        }
        return nil
    }

    @ViewBuilder private func suggestionList(_ menu: ForumPostSuggestionMenu) -> some View {
        switch menu {
        case let .emoji(context, suggestions):
            EmojiAutocompleteList(
                suggestions: suggestions,
                selectedIndex: autocompleteIndex,
                highlight: { autocompleteIndex = $0 },
                select: { accept($0, context: context) }
            )
        case let .mention(context, suggestions):
            MentionAutocompleteList(
                heading: context.kind == .member
                    ? MentionAutocompleteSuggestionFactory.memberHeading(query: context.query)
                    : MentionAutocompleteSuggestionFactory.channelHeading(query: context.query),
                suggestions: suggestions,
                selectedIndex: autocompleteIndex,
                highlight: { autocompleteIndex = $0 },
                select: { accept($0, context: context) },
                keyboardSelectionRevision: keyboardSelectionRevision
            )
        case let .time(context, rows):
            ComposerTimeFormatPicker(
                query: context.query,
                rows: rows,
                needsPick: timeQueryNeedsPick,
                selectedIndex: autocompleteIndex,
                cornerRadius: ChatChromeMetrics.composerCornerRadius,
                keyboardSelectionRevision: keyboardSelectionRevision,
                select: { insert($0.token.rawToken + " ", replacing: context.range) },
                highlight: { autocompleteIndex = $0 }
            )
        }
    }

    private var emojiContext: ColonAutocompleteContext? {
        isAutocompleteDismissed ? nil : ColonAutocompleteContext(text: text, selection: selection)
    }

    private func emojiSuggestions(for context: ColonAutocompleteContext) -> [ColonAutocompleteSuggestion] {
        emojiCache.suggestions(query: context.query, model: model)
    }

    private var mentionContext: MentionAutocompleteContext? {
        isAutocompleteDismissed || emojiContext != nil ? nil : MentionAutocompleteContext(text: text, selection: selection)
    }

    /// The forum is the selected channel while its composer is open, so
    /// people, roles and channels resolve as they do in the message composer.
    private func mentionSuggestions(for context: MentionAutocompleteContext) -> [MentionAutocompleteSuggestion] {
        let currentMember = (model.currentUser?.id).flatMap { model.membersByID[$0] }
        switch context.kind {
        case .member:
            return MentionAutocompleteSuggestionFactory.memberSuggestions(
                query: context.query,
                recentMessages: [],
                localMembers: model.mentionAutocompleteMembers.filter { !model.isUserIgnored($0.id) },
                remoteMembers: model.mentionMemberResults.filter { !model.isUserIgnored($0.id) },
                roles: model.guildRoles,
                isGuildChannel: model.selectedChannel?.guildID != nil,
                canMentionNonMentionableRoles: MentionAutocompleteSuggestionFactory.canMentionNonMentionableRoles(
                    in: model.selectedChannel,
                    guild: model.selectedGuildID.flatMap { model.serverRailGuildsByID[$0] },
                    currentUserID: model.currentUser?.id,
                    currentMember: currentMember,
                    roles: model.guildRoles
                )
            )
        case .channel:
            return MentionAutocompleteSuggestionFactory.channelSuggestions(
                query: context.query,
                channels: model.visibleChannels.filter { !model.hiddenChannelIDs.contains($0.id) },
                threads: model.mentionAutocompleteThreads,
                guilds: model.serverRailGuildsByID,
                guildAndChannelUsageScores: model.discordGuildAndChannelUsageScores,
                currentUserID: model.currentUser?.id,
                currentMember: currentMember,
                roles: model.guildRoles
            )
        }
    }

    /// The `@time` menu replaces the mention menu once `@time ` is typed.
    private var timeContext: KeywordMentionContext? {
        isAutocompleteDismissed || emojiContext != nil || mentionContext != nil
            ? nil : KeywordMentionContext(.time, text: text, selection: selection)
    }

    private func timeRows(for context: KeywordMentionContext) -> [ComposerTimeFormatPicker.Row] {
        ComposerTimeFormatPicker.rows(DiscordNaturalLanguageTimeParser.suggestions(for: context.query, now: timeQueryDate))
    }

    private func updateMemberSearch() {
        guard let context = mentionContext, context.kind == .member else {
            model.requestMentionMemberSearch(query: "")
            return
        }
        model.requestMentionMemberSearch(query: context.query)
    }

    // MARK: Keys

    private func handleAutocomplete(_ command: ComposerAutocompleteCommand) -> Bool {
        if command == .previous || command == .next { keyboardSelectionRevision &+= 1 }
        switch menu {
        case let .emoji(context, suggestions):
            return route(command, count: suggestions.count) { accept(suggestions[$0], context: context) }
        case let .mention(context, suggestions):
            return route(command, count: suggestions.count) { accept(suggestions[$0], context: context) }
        case let .time(_, rows) where rows.isEmpty:
            // Nothing matches yet: Return asks for a time rather than a newline.
            switch command {
            case .accept, .advance: timeQueryNeedsPick = true
            case .dismiss: isAutocompleteDismissed = true
            default: return false
            }
            return true
        case let .time(context, rows):
            return route(command, count: rows.count) { insert(rows[$0].token.rawToken + " ", replacing: context.range) }
        case nil:
            return false
        }
    }

    /// Moves through, accepts or dismisses the open menu of `count` rows.
    private func route(_ command: ComposerAutocompleteCommand, count: Int, accept: (Int) -> Void) -> Bool {
        switch command {
        case .previous: autocompleteIndex = (autocompleteIndex - 1 + count) % count
        case .next: autocompleteIndex = (autocompleteIndex + 1) % count
        case .accept, .advance: accept(min(autocompleteIndex, count - 1))
        case .dismiss: isAutocompleteDismissed = true
        case .previousField, .nextField, .removeField: return false
        }
        return true
    }

    private func accept(_ suggestion: ColonAutocompleteSuggestion, context: ColonAutocompleteContext) {
        if let emoji = suggestion.customEmoji { ComposerEmojiImageStore.shared.register(emoji) }
        insert(suggestion.value, replacing: context.range)
    }

    private func accept(_ suggestion: MentionAutocompleteSuggestion, context: MentionAutocompleteContext) {
        if let member = suggestion.member { model.rememberMentionMember(member) }
        insert(suggestion.value + " ", replacing: context.range)
    }

    private func insert(_ value: String, replacing range: NSRange) {
        text = (text as NSString).replacingCharacters(in: range, with: value)
        selection = NSRange(location: range.location + value.utf16.count, length: 0)
        autocompleteIndex = 0
        isAutocompleteDismissed = true
    }
}

private enum ForumPostSuggestionMenu {
    case emoji(ColonAutocompleteContext, [ColonAutocompleteSuggestion])
    case mention(MentionAutocompleteContext, [MentionAutocompleteSuggestion])
    case time(KeywordMentionContext, [ComposerTimeFormatPicker.Row])

    enum Kind { case emoji, mention, time }

    var kind: Kind {
        switch self {
        case .emoji: .emoji
        case .mention: .mention
        case .time: .time
        }
    }
}
