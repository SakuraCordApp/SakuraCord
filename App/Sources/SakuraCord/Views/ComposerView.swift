import MessageRendering
import SakuraCordModels
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct ComposerDraftEdit: Equatable {
    let text: String
    let selection: NSRange
}

nonisolated enum ComposerDraftEditing {
    static func insert(_ insertedText: String, into source: String, replacing selection: NSRange?)
        -> ComposerDraftEdit
    {
        let resolved = resolvedRange(selection, in: source)
        var value = source
        let range = Range(resolved, in: value) ?? (value.endIndex ..< value.endIndex)
        value.replaceSubrange(range, with: insertedText)
        return ComposerDraftEdit(
            text: value,
            selection: NSRange(location: resolved.location + insertedText.utf16.count, length: 0)
        )
    }

    static func insertCustomEmoji(_ token: String, into source: String, replacing selection: NSRange?)
        -> ComposerDraftEdit
    {
        insert(token, into: source, replacing: selection)
    }

    private static func resolvedRange(_ selection: NSRange?, in source: String) -> NSRange {
        let end = NSRange(location: source.utf16.count, length: 0)
        guard let selection,
              selection.location != NSNotFound,
              selection.location >= 0,
              selection.length >= 0,
              selection.location <= source.utf16.count,
              selection.length <= source.utf16.count - selection.location,
              Range(selection, in: source) != nil
        else { return end }
        return selection
    }
}

struct ComposerView: View {
    enum Conversation: Equatable {
        case channel
        case thread
    }

    let model: AppModel
    let channelName: String
    var conversation: Conversation = .channel
    @State private var attachments: [URL] = []
    @State private var showFileImporter = false
    @State private var showEmojiPicker = false
    @State private var isFocused = false
    @State private var draftSelection: NSRange?
    @State private var selectionBeforeEmojiPicker: NSRange?
    @State private var isSubmitting = false
    @State private var emojiPickerDismissedAt: TimeInterval = -.infinity
    @State private var autocompleteIndex = 0
    @State private var isAutocompleteDismissed = false
    @State private var commandSuggestionIndex = 0
    @State private var isCommandSuggestionsDismissed = false
    @AppStorage("sendWithReturn") private var sendWithReturn = true

    var body: some View {
        @Bindable var model = model
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 7) {
                if !hasActiveCommand,
                   isSubmitting, let progress = activeSendProgress
                {
                    UploadProgressView(progress: progress)
                }
                if !hasActiveCommand, !attachments.isEmpty {
                    ComposerAttachmentStrip(attachments: $attachments)
                }
                VStack(alignment: .leading, spacing: 0) {
                    if !hasActiveCommand, let reply = activeReply {
                        HStack(spacing: 7) {
                            Image(systemName: "arrowshape.turn.up.left")
                                .foregroundStyle(.secondary)
                            Text("Replying to")
                                .foregroundStyle(.secondary)
                            Text(reply.author.displayName)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Button {
                                cancelReply()
                            } label: {
                                Image(systemName: "xmark")
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.plain)
                            .help("Cancel reply")
                        }
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                    }
                    HStack(alignment: .bottom, spacing: 9) {
                        if !hasActiveCommand {
                            ComposerActionButton(
                                systemImage: "plus",
                                help: "Add attachments",
                                iconSize: 19,
                                iconWeight: .regular
                            ) {
                                showFileImporter = true
                            }
                        }
                        if hasActiveCommand {
                            ApplicationCommandInlineInput(
                                composer: model.commandComposer,
                                roles: model.guildRoles,
                                sendWithReturn: sendWithReturn,
                                onTextChange: { option, text in
                                    updateCommandField(text, for: option)
                                },
                                onSubmit: submitComposer,
                                onKeyboardCommand: handleAutocomplete,
                                cancel: cancelCommand,
                                isFocused: $isFocused
                            )
                            .frame(minHeight: 36, alignment: .center)
                            .layoutPriority(1)
                        } else {
                            ZStack(alignment: .leading) {
                                ComposerTextView(
                                    text: draft,
                                    placeholder: "Message #\(channelName)",
                                    sendWithReturn: sendWithReturn,
                                    mentionPresentations: composerMentionPresentations,
                                    onTextChange: updateDraft,
                                    onSubmit: send,
                                    onAutocompleteCommand: handleAutocomplete,
                                    capturesUnfocusedTyping: true,
                                    selection: $draftSelection,
                                    isFocused: $isFocused
                                )

                                if draft.isEmpty {
                                    Text("Message #\(channelName)")
                                        .foregroundStyle(.tertiary)
                                        .font(.system(size: 15))
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(minHeight: 36, alignment: .center)
                            .layoutPriority(1)
                        }
                        HStack(spacing: 1) {
                            if !hasActiveCommand {
                                ComposerActionButton(
                                    systemImage: "face.smiling.inverse",
                                    help: "Choose emoji",
                                    iconSize: 19,
                                    iconWeight: .medium
                                ) {
                                    toggleEmojiPicker()
                                }
                                .fixedSize()
                                .background {
                                    StableReactionPickerPresenter(
                                        isPresented: $showEmojiPicker,
                                        preferredEdge: .maxY,
                                        accessibilityIdentifier: "composer-emoji-picker"
                                    ) {
                                        composerEmojiPicker
                                    }
                                    .frame(width: 36, height: 36)
                                }
                            }
                            Capsule()
                                .fill(.primary.opacity(0.16))
                                .frame(width: 1, height: 16)
                                .frame(width: 9, height: 36)
                                .accessibilityHidden(true)
                            ComposerSendButton(action: submitComposer)
                                .disabled(!composerCanSubmit)
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .frame(minHeight: ChatChromeMetrics.controlHeight)
                }
                .background {
                    ComposerFocusSurface { isFocused = true }
                }
                .glassEffect(
                    .regular.interactive(),
                    in: RoundedRectangle(
                        cornerRadius: ChatChromeMetrics.controlCornerRadius, style: .continuous
                    )
                )
                .overlay(alignment: .top) {
                    composerOverlay
                        .alignmentGuide(.top) { dimensions in
                            dimensions[.bottom] + 7
                        }
                        .zIndex(10)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12).padding(.bottom, 12)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: !hasActiveCommand
        ) { result in
            guard case let .success(urls) = result else { return }
            if hasActiveCommand,
               let option = model.commandComposer.focusedOption, option.type == .attachment,
               let url = urls.first
            {
                model.commandComposer.setValue(
                    .attachment(url), displayText: url.lastPathComponent, for: option
                )
                focusNextCommandField()
            } else if !hasActiveCommand {
                attachments.append(contentsOf: urls)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            if hasActiveCommand,
               let option = model.commandComposer.focusedOption, option.type == .attachment,
               let url = urls.first
            {
                model.commandComposer.setValue(
                    .attachment(url), displayText: url.lastPathComponent, for: option
                )
                focusNextCommandField()
                return true
            }
            guard !hasActiveCommand else { return false }
            attachments.append(contentsOf: urls)
            return !urls.isEmpty
        }
        .onReceive(NotificationCenter.default.publisher(for: .sakuracordFocusComposer)) { _ in
            isFocused = true
        }
        .onChange(of: showEmojiPicker) { wasPresented, isPresented in
            if wasPresented, !isPresented {
                emojiPickerDismissedAt = ProcessInfo.processInfo.systemUptime
            }
        }
        .onChange(of: draft) { _, value in
            if completeClosedEmojiName(in: value) {
                return
            }
            isAutocompleteDismissed = false
            autocompleteIndex = 0
            updateSlashPicker(for: value)
            updateMentionMemberSearch()
        }
        .onChange(of: draftSelection) { _, _ in
            isAutocompleteDismissed = false
            autocompleteIndex = 0
            updateMentionMemberSearch()
        }
        .onChange(of: model.commandComposer.focusedOptionID) { _, _ in
            model.cancelApplicationCommandAutocompleteTask()
            model.cancelApplicationCommandMemberSearch()
            commandSuggestionIndex = 0
            isCommandSuggestionsDismissed = false
            isFocused = hasActiveCommand
        }
        .task(id: composerPresentationID) {
            attachments.removeAll()
            draftSelection = nil
            selectionBeforeEmojiPicker = nil
            showFileImporter = false
            showEmojiPicker = false
            let isClosedVoiceChat = model.selectedChannel?.kind == .voice
                && !model.isVoiceChatOpen
            guard conversation == .thread || !isClosedVoiceChat else { return }
            isFocused = true
            if conversation == .channel, model.selectedChannel?.kind != .voice {
                updateSlashPicker(for: draft)
            }
        }
        .task(id: autocompleteSettingsAreRequested) {
            guard autocompleteSettingsAreRequested else { return }
            await model.loadDiscordEmojiSettings()
        }
        .task(id: emojiAutocompleteCatalogIsRequested) {
            guard emojiAutocompleteCatalogIsRequested else { return }
            for guild in model.snapshot?.guilds ?? [] {
                guard !Task.isCancelled else { return }
                await model.loadEmojis(for: guild.id)
            }
        }
    }

    private var composerPresentationID: String {
        let conversationID = activeConversationID?.rawValue.description ?? "none"
        return "\(conversation):\(conversationID):\(model.isVoiceChatOpen)"
    }

    @ViewBuilder
    private var composerOverlay: some View {
        if conversation == .channel, model.commandComposer.isPickerPresented {
            ApplicationCommandPickerView(
                composer: model.commandComposer,
                choose: activateCommand,
                dismiss: model.commandComposer.dismissPicker
            )
        } else if hasActiveCommand {
            let suggestions = commandSuggestions
            if (model.commandComposer.focusedOption == nil || isFocused),
               !isCommandSuggestionsDismissed,
               (!suggestions.isEmpty
                || model.commandComposer.isAutocompleteLoading
                || model.commandComposer.autocompleteError != nil)
            {
                ApplicationCommandSuggestionPanel(
                    heading: commandSuggestionHeading,
                    suggestions: suggestions,
                    selectedIndex: commandSuggestionIndex,
                    isLoading: model.commandComposer.isAutocompleteLoading,
                    error: model.commandComposer.autocompleteError,
                    select: acceptCommandSuggestion,
                    highlight: { commandSuggestionIndex = $0 }
                )
            }
        } else if let context = mentionAutocompleteContext {
            let suggestions = mentionAutocompleteSuggestions(for: context)
            if !suggestions.isEmpty {
                MentionAutocompleteList(
                    heading: context.kind == .member
                        ? MentionAutocompleteSuggestionFactory.memberHeading(query: context.query)
                        : "TEXT CHANNELS",
                    suggestions: suggestions,
                    selectedIndex: autocompleteIndex,
                    highlight: { autocompleteIndex = $0 }
                ) { acceptMentionAutocomplete($0, context: context) }
            }
        } else if let context = autocompleteContext {
            let suggestions = emojiSuggestions(query: context.query)
            if !suggestions.isEmpty {
                EmojiAutocompleteList(
                    suggestions: suggestions,
                    selectedIndex: autocompleteIndex,
                    highlight: { autocompleteIndex = $0 }
                ) { acceptAutocomplete($0, context: context) }
            }
        }
    }

    private var composerEmojiPicker: some View {
        EmojiPickerView(
            model: model,
            allowsPersistentSelection: true
        ) { activation in
            let replacementSelection =
                selectionBeforeEmojiPicker
                ?? NSRange(location: draft.utf16.count, length: 0)
            let restoredSelection: NSRange
            switch activation.selection {
            case let .native(value):
                restoredSelection = insertInDraft(value, replacing: replacementSelection)
            case let .custom(emoji):
                ComposerEmojiImageStore.shared.register(emoji)
                let value = model.composerText(for: emoji)
                restoredSelection = applyDraftEdit(
                    ComposerDraftEditing.insertCustomEmoji(
                        value,
                        into: draft,
                        replacing: replacementSelection
                    )
                )
            }
            if activation.keepsPickerPresented {
                selectionBeforeEmojiPicker = restoredSelection
                draftSelection = restoredSelection
                return
            }
            showEmojiPicker = false
            selectionBeforeEmojiPicker = nil
            Task { @MainActor in
                await Task.yield()
                isFocused = true
                await Task.yield()
                draftSelection = restoredSelection
            }
        }
        .onExitCommand { showEmojiPicker = false }
    }

    private func toggleEmojiPicker() {
        if showEmojiPicker {
            showEmojiPicker = false
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - emojiPickerDismissedAt > 0.25 else { return }

        selectionBeforeEmojiPicker =
            draftSelection
            ?? NSRange(location: draft.utf16.count, length: 0)
        showEmojiPicker = true
    }

    private func send() {
        guard !isSubmitting,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
        else { return }
        isSubmitting = true
        draftSelection = nil
        selectionBeforeEmojiPicker = nil
        let staged = attachments
        let conversationID = activeConversationID
        attachments.removeAll()
        Task {
            let scopedURLs = staged.filter { $0.startAccessingSecurityScopedResource() }
            defer {
                for url in scopedURLs {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let didSend = switch conversation {
            case .channel:
                await model.send(attachments: staged)
            case .thread:
                await model.sendThreadMessage(attachments: staged)
            }
            if !didSend, activeConversationID == conversationID {
                let currentAttachments = Set(attachments)
                attachments = staged.filter { !currentAttachments.contains($0) } + attachments
            }
            isSubmitting = false
            isFocused = true
        }
    }

    private var autocompleteContext: ColonAutocompleteContext? {
        guard !isAutocompleteDismissed else { return nil }
        return ColonAutocompleteContext(text: draft, selection: draftSelection)
    }

    private var mentionAutocompleteContext: MentionAutocompleteContext? {
        guard !isAutocompleteDismissed else { return nil }
        return MentionAutocompleteContext(text: draft, selection: draftSelection)
    }

    private var mentionAutocompleteSuggestions: [MentionAutocompleteSuggestion] {
        guard let context = mentionAutocompleteContext else { return [] }
        return mentionAutocompleteSuggestions(for: context)
    }

    private func mentionAutocompleteSuggestions(
        for context: MentionAutocompleteContext
    ) -> [MentionAutocompleteSuggestion] {
        switch context.kind {
        case .member:
            return MentionAutocompleteSuggestionFactory.memberSuggestions(
                query: context.query,
                recentMessages: activeMessages,
                localMembers: model.mentionAutocompleteMembers,
                remoteMembers: model.mentionMemberResults,
                roles: model.guildRoles,
                canMentionNonMentionableRoles:
                    MentionAutocompleteSuggestionFactory.canMentionNonMentionableRoles(
                        in: model.selectedChannel,
                        guild: model.selectedGuildID.flatMap { model.serverRailGuildsByID[$0] },
                        currentUserID: model.snapshot?.currentUser.id,
                        currentMember: (model.snapshot?.currentUser.id).flatMap {
                            model.membersByID[$0]
                        },
                        roles: model.guildRoles
                    )
            )
        case .channel:
            return MentionAutocompleteSuggestionFactory.channelSuggestions(
                query: context.query,
                channels: model.visibleChannels,
                guilds: model.serverRailGuildsByID,
                guildAndChannelUsageScores: model.discordGuildAndChannelUsageScores,
                currentUserID: model.snapshot?.currentUser.id,
                currentMember: (model.snapshot?.currentUser.id).flatMap { model.membersByID[$0] },
                roles: model.guildRoles
            )
        }
    }

    private var composerMentionPresentations: [String: MentionPresentation] {
        let resolver = MessageMentionResolver(model: model)
        return MessageDocumentCache.shared.document(for: draft).segments.reduce(into: [:]) {
            values, segment in
            if case let .mention(mention) = segment {
                values[mention.rawToken] = resolver.presentation(mention)
            }
        }
    }

    private func updateMentionMemberSearch() {
        guard let context = mentionAutocompleteContext, context.kind == .member else {
            model.requestMentionMemberSearch(query: "")
            return
        }
        model.requestMentionMemberSearch(query: context.query)
    }

    private var emojiAutocompleteCatalogIsRequested: Bool {
        autocompleteContext != nil
    }

    private var autocompleteSettingsAreRequested: Bool {
        autocompleteContext != nil || mentionAutocompleteContext?.kind == .channel
    }

    private var activeSendProgress: MessageSendProgress? {
        for message in activeMessages.reversed() where message.channelID == activeConversationID {
            if let nonce = message.nonce, let progress = model.sendProgressByNonce[nonce] {
                return progress
            }
        }
        return nil
    }

    private var commandFieldText: String {
        guard let option = model.commandComposer.focusedOption else { return "" }
        return commandLookupQuery(
            model.commandComposer.draftText(for: option),
            option: option
        )
    }

    private var commandSuggestions: [ApplicationCommandSuggestion] {
        ApplicationCommandSuggestionFactory.suggestions(
            option: model.commandComposer.focusedOption,
            query: commandFieldText,
            members: commandSuggestionMembers,
            roles: model.guildRoles,
            channels: model.visibleChannels,
            autocompleteChoices: model.commandComposer.autocompleteChoices,
            availableOptions: model.commandComposer.availableOptionalOptions
        )
    }

    private var commandSuggestionHeading: String {
        ApplicationCommandSuggestionFactory.heading(
            option: model.commandComposer.focusedOption,
            hasAutocompleteChoices: !model.commandComposer.autocompleteChoices.isEmpty
        )
    }

    private var commandSuggestionMembers: [Member] {
        var seen = Set<UserID>()
        return (model.commandMemberResults + model.members).filter { seen.insert($0.id).inserted }
    }

    private var visibleCommandSuggestions: [ApplicationCommandSuggestion] {
        isCommandSuggestionsDismissed ? [] : commandSuggestions
    }

    private var composerCanSubmit: Bool {
        if hasActiveCommand {
            return model.commandComposer.canSubmit
                && model.commandComposer.executionProgress == nil
        }
        return !isSubmitting
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty)
    }

    private var autocompleteSuggestions: [ColonAutocompleteSuggestion] {
        guard let context = autocompleteContext else { return [] }
        return emojiSuggestions(query: context.query)
    }

    private func emojiSuggestions(query: String) -> [ColonAutocompleteSuggestion] {
        ColonAutocompleteSuggestionFactory.suggestions(
            query: query,
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

    private func completeClosedEmojiName(in text: String) -> Bool {
        guard let context = ClosedColonAutocompleteContext(text: text, selection: draftSelection),
              let suggestion = emojiSuggestions(query: context.query).first(where: {
                  $0.matchesCompletionName(context.query)
              })
        else { return false }

        if let emoji = suggestion.customEmoji {
            ComposerEmojiImageStore.shared.register(emoji)
        }
        let selection = applyDraftEdit(
            ComposerDraftEditing.insert(
                suggestion.value,
                into: text,
                replacing: context.range
            )
        )
        model.recordEmojiUse(suggestion.usageKey)
        draftSelection = selection
        autocompleteIndex = 0
        isAutocompleteDismissed = true
        return true
    }

    private func updateSlashPicker(for text: String) {
        guard conversation == .channel, !hasActiveCommand else { return }
        guard model.supportsCapability(.slashCommands),
              let context = SlashCommandQuery(text: text, selection: draftSelection)
        else {
            if model.commandComposer.isPickerPresented {
                model.commandComposer.dismissPicker()
            }
            return
        }
        let shouldLoad = model.commandComposer.commands.isEmpty
            && !model.commandComposer.isLoading
        if !model.commandComposer.isPickerPresented {
            model.commandComposer.presentPicker(query: context.query)
        } else {
            model.commandComposer.updatePickerQuery(context.query)
        }
        if shouldLoad {
            model.loadApplicationCommands()
        }
    }

    private func activateCommand(_ command: ApplicationCommand) {
        model.commandComposer.activate(command)
        model.cancelReply()
        model.updateDraft("")
        attachments.removeAll()
        draftSelection = nil
        commandSuggestionIndex = 0
        isCommandSuggestionsDismissed = false
        isFocused = true
    }

    private func cancelCommand() {
        model.commandComposer.cancelActiveCommand()
        commandSuggestionIndex = 0
        isCommandSuggestionsDismissed = false
        isFocused = true
    }

    private func submitComposer() {
        if hasActiveCommand {
            guard model.commandComposer.canSubmit else { return }
            model.executeApplicationCommand()
        } else {
            send()
        }
    }

    private func updateCommandField(
        _ text: String,
        for option: ApplicationCommandOption
    ) {
        model.commandComposer.updateDraftText(text, for: option)
        commandSuggestionIndex = 0
        isCommandSuggestionsDismissed = false
        if option.usesAutocomplete {
            model.requestApplicationCommandAutocomplete(for: option, query: text)
        } else if option.type == .user || option.type == .mentionable {
            model.requestApplicationCommandMemberSearch(
                query: commandLookupQuery(text, option: option)
            )
        }
    }

    private func commandLookupQuery(
        _ text: String,
        option: ApplicationCommandOption
    ) -> String {
        guard option.type == .user
            || option.type == .role
            || option.type == .channel
            || option.type == .mentionable
        else { return text }
        return text.hasPrefix("@") || text.hasPrefix("#")
            ? String(text.dropFirst())
            : text
    }

    private func acceptCommandSuggestion(_ suggestion: ApplicationCommandSuggestion) {
        switch suggestion.action {
        case let .value(value, displayText):
            guard let option = model.commandComposer.focusedOption else { return }
            model.commandComposer.setValue(value, displayText: displayText, for: option)
            focusNextCommandField()
        case .chooseAttachment:
            showFileImporter = true
        case let .addOption(option):
            model.commandComposer.addOptionalOption(option)
            isFocused = true
        }
        commandSuggestionIndex = 0
        isCommandSuggestionsDismissed = false
    }

    private func focusNextCommandField() {
        model.commandComposer.moveOptionFocus(by: 1)
        isFocused = true
    }

    private func handleAutocomplete(_ command: ComposerAutocompleteCommand) -> Bool {
        if hasActiveCommand {
            switch command {
            case .previous:
                guard !visibleCommandSuggestions.isEmpty else { return false }
                commandSuggestionIndex = (
                    commandSuggestionIndex - 1 + visibleCommandSuggestions.count
                ) % visibleCommandSuggestions.count
            case .next:
                guard !visibleCommandSuggestions.isEmpty else { return false }
                commandSuggestionIndex =
                    (commandSuggestionIndex + 1) % visibleCommandSuggestions.count
            case .accept:
                if visibleCommandSuggestions.indices.contains(commandSuggestionIndex) {
                    acceptCommandSuggestion(visibleCommandSuggestions[commandSuggestionIndex])
                } else {
                    submitComposer()
                }
            case .dismiss:
                if !visibleCommandSuggestions.isEmpty
                    || model.commandComposer.isAutocompleteLoading
                    || model.commandComposer.autocompleteError != nil
                {
                    isCommandSuggestionsDismissed = true
                } else {
                    cancelCommand()
                }
            case .previousField:
                model.commandComposer.moveOptionFocus(by: -1)
            case .nextField:
                focusNextCommandField()
            case .advance:
                if visibleCommandSuggestions.indices.contains(commandSuggestionIndex) {
                    acceptCommandSuggestion(visibleCommandSuggestions[commandSuggestionIndex])
                } else if model.commandComposer.focusedOption == nil {
                    return true
                } else {
                    focusNextCommandField()
                }
            case .removeField:
                guard let option = model.commandComposer.focusedOption,
                      !option.isRequired
                else { return false }
                model.commandComposer.removeOptionalOption(option)
            }
            return true
        }
        if conversation == .channel, model.commandComposer.isPickerPresented {
            switch command {
            case .previous: model.commandComposer.movePickerSelection(by: -1)
            case .next: model.commandComposer.movePickerSelection(by: 1)
            case .accept, .advance:
                guard let id = model.commandComposer.selectedCommandID,
                      let selected = model.commandComposer.commands.first(where: { $0.id == id })
                else { return true }
                activateCommand(selected)
            case .dismiss: model.commandComposer.dismissPicker()
            case .previousField, .nextField, .removeField: return true
            }
            return true
        }
        if let context = mentionAutocompleteContext, !mentionAutocompleteSuggestions.isEmpty {
            switch command {
            case .previous:
                autocompleteIndex = (autocompleteIndex - 1 + mentionAutocompleteSuggestions.count)
                    % mentionAutocompleteSuggestions.count
            case .next:
                autocompleteIndex = (autocompleteIndex + 1) % mentionAutocompleteSuggestions.count
            case .accept, .advance:
                acceptMentionAutocomplete(
                    mentionAutocompleteSuggestions[min(autocompleteIndex, mentionAutocompleteSuggestions.count - 1)],
                    context: context
                )
            case .dismiss:
                isAutocompleteDismissed = true
            case .previousField, .nextField, .removeField:
                return false
            }
            return true
        }
        guard let context = autocompleteContext, !autocompleteSuggestions.isEmpty else { return false }
        switch command {
        case .previous:
            autocompleteIndex =
                (autocompleteIndex - 1 + autocompleteSuggestions.count) % autocompleteSuggestions.count
        case .next: autocompleteIndex = (autocompleteIndex + 1) % autocompleteSuggestions.count
        case .accept, .advance:
            acceptAutocomplete(
                autocompleteSuggestions[min(autocompleteIndex, autocompleteSuggestions.count - 1)],
                context: context
            )
        case .dismiss: isAutocompleteDismissed = true
        case .previousField, .nextField, .removeField: return false
        }
        return true
    }

    private func acceptAutocomplete(
        _ suggestion: ColonAutocompleteSuggestion, context: ColonAutocompleteContext
    ) {
        if let emoji = suggestion.customEmoji {
            ComposerEmojiImageStore.shared.register(emoji)
        }
        let result = insertInDraft(suggestion.value, replacing: context.range)
        model.recordEmojiUse(suggestion.usageKey)
        draftSelection = result
        autocompleteIndex = 0
        isAutocompleteDismissed = true
    }

    private func acceptMentionAutocomplete(
        _ suggestion: MentionAutocompleteSuggestion,
        context: MentionAutocompleteContext
    ) {
        if let member = suggestion.member { model.rememberMentionMember(member) }
        draftSelection = insertInDraft(suggestion.value + " ", replacing: context.range)
        autocompleteIndex = 0
        isAutocompleteDismissed = true
    }

    @discardableResult
    private func insertInDraft(
        _ insertedText: String,
        replacing selection: NSRange?
    ) -> NSRange {
        applyDraftEdit(ComposerDraftEditing.insert(insertedText, into: draft, replacing: selection))
    }

    private func applyDraftEdit(_ edit: ComposerDraftEdit) -> NSRange {
        updateDraft(edit.text)
        return edit.selection
    }

    private var hasActiveCommand: Bool {
        conversation == .channel && model.commandComposer.activeCommand != nil
    }

    private var activeConversationID: ChannelID? {
        switch conversation {
        case .channel: model.selectedChannelID
        case .thread: model.openThread?.id
        }
    }

    private var activeMessages: [Message] {
        switch conversation {
        case .channel: model.messages
        case .thread: model.threadMessages
        }
    }

    private var activeReply: Message? {
        conversation == .channel ? model.replyingTo : nil
    }

    private var draft: String {
        switch conversation {
        case .channel: model.draft
        case .thread: model.threadDraft
        }
    }

    private func updateDraft(_ value: String) {
        switch conversation {
        case .channel:
            model.updateDraft(value)
        case .thread:
            model.threadDraft = value
        }
    }

    private func cancelReply() {
        guard conversation == .channel else { return }
        model.cancelReply()
    }
}

struct ComposerAttachmentStrip: View {
    @Binding var attachments: [URL]

    var body: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(attachments, id: \.self) { url in
                    HStack(spacing: 7) {
                        Image(systemName: "doc")
                        Text(url.lastPathComponent).lineLimit(1)
                        Button {
                            attachments.removeAll { $0 == url }
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    .glassEffect(
                        .regular,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                }
            }
        }
        .frame(height: 42)
    }
}

struct SlashCommandQuery {
    let query: String

    init?(text: String, selection: NSRange?) {
        guard text.hasPrefix("/"), !text.contains(where: \.isNewline) else { return nil }
        if let selection {
            guard selection.length == 0, selection.location == text.utf16.count else { return nil }
        }
        query = String(text.dropFirst())
    }
}

struct ColonAutocompleteContext {
    private static let expression = try! NSRegularExpression(
        pattern: #"(?:^|\s)(:[A-Za-z0-9_+\-]*)$"#
    )

    let query: String
    let range: NSRange

    init?(text: String, selection: NSRange?) {
        let cursor = selection?.location ?? text.utf16.count
        guard selection?.length ?? 0 == 0, cursor <= text.utf16.count else { return nil }
        let prefix = (text as NSString).substring(to: cursor)
        guard
            let match = Self.expression.firstMatch(
                in: prefix, range: NSRange(location: 0, length: (prefix as NSString).length)
            ),
            match.range(at: 1).location != NSNotFound
        else { return nil }
        range = match.range(at: 1)
        query = String((prefix as NSString).substring(with: range).dropFirst())
        guard query.count >= 2 else { return nil }
    }
}

struct MentionAutocompleteContext {
    private static let expression = try! NSRegularExpression(
        pattern: #"(?:^|\s)([@#]([^\s@#]*))$"#
    )

    enum Kind: Equatable { case member, channel }

    let kind: Kind
    let query: String
    let range: NSRange

    init?(text: String, selection: NSRange?) {
        let cursor = selection?.location ?? text.utf16.count
        guard selection?.length ?? 0 == 0, cursor <= text.utf16.count else { return nil }
        let prefix = (text as NSString).substring(to: cursor)
        guard let match = Self.expression.firstMatch(
            in: prefix,
            range: NSRange(location: 0, length: (prefix as NSString).length)
        ), match.range(at: 1).location != NSNotFound,
           match.range(at: 2).location != NSNotFound
        else { return nil }
        range = match.range(at: 1)
        let token = (prefix as NSString).substring(with: range)
        kind = token.first == "@" ? .member : .channel
        query = (prefix as NSString).substring(with: match.range(at: 2))
    }
}

struct MentionAutocompleteSuggestion: Identifiable {
    let id: String
    let title: String
    let detail: String
    let value: String
    let target: MentionTarget
    var avatarURL: URL?
    var colorHex: UInt32?
    var member: Member?
}

enum MentionAutocompleteSuggestionFactory {
    private static let resultLimit = 10

    private enum MemberMatchRank: Int {
        case none = 0
        case fuzzy = 1
        case strong = 2
    }

    private struct RankedMember {
        let storeIndex: Int
        let rank: MemberMatchRank
        let member: Member
    }

    private struct RankedChannel {
        let channel: Channel
        let score: Double
        let sidebarPosition: Int
    }

    private struct MemberSearchSignature: Equatable {
        let username: String
        let displayName: String
        let globalDisplayName: String?
    }

    private struct MemberSearchCacheEntry {
        let signature: MemberSearchSignature
        let candidates: [String]
    }

    private static var memberSearchCache: [UserID: MemberSearchCacheEntry] = [:]
    private static let memberSearchCacheLimit = 50_000

    static func memberHeading(query: String) -> String {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "MEMBERS" : "MEMBERS MATCHING @\(normalized.uppercased())"
    }

    static func memberSuggestions(
        query: String,
        recentMessages: [Message],
        localMembers: [Member],
        remoteMembers: [Member],
        roles: [GuildRole],
        canMentionNonMentionableRoles: Bool = false
    ) -> [MentionAutocompleteSuggestion] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = normalized(trimmedQuery)
        // A completed opcode-8 query is the official client's narrowed result
        // set. Keep its order and do not re-introduce fuzzy local members that
        // Discord omitted. Before it arrives, the local GuildMemberStore still
        // makes the menu responsive immediately.
        let memberStore = normalizedQuery.isEmpty || remoteMembers.isEmpty
            ? mergingMemberStore(localMembers, updates: remoteMembers)
            : remoteMembers

        let orderedMembers: [Member]
        if normalizedQuery.isEmpty {
            let resolvedByID = Dictionary(
                memberStore.map { ($0.id, $0) },
                uniquingKeysWith: { _, rhs in rhs }
            )
            var seen = Set<UserID>()
            let recent = recentMessages.reversed().compactMap { message -> Member? in
                guard seen.insert(message.author.id).inserted else { return nil }
                return resolvedByID[message.author.id]
                    ?? Member(user: message.author, roleName: "Member", status: .offline)
            }
            // Discord prefers recent channel authors for a bare @. When the
            // channel has no messages cached, its guild-member store order is
            // the fallback.
            orderedMembers = recent.isEmpty ? memberStore : recent
        } else {
            var bestMatches: [RankedMember] = []
            bestMatches.reserveCapacity(resultLimit)
            for (index, member) in memberStore.enumerated() {
                let rank = memberMatchRank(member, normalizedQuery: normalizedQuery)
                guard rank != .none else { continue }
                let candidate = RankedMember(storeIndex: index, rank: rank, member: member)
                let insertionIndex = bestMatches.firstIndex {
                    isPreferred(candidate, over: $0)
                }
                if let insertionIndex {
                    bestMatches.insert(candidate, at: insertionIndex)
                    if bestMatches.count > resultLimit {
                        bestMatches.removeLast()
                    }
                } else if bestMatches.count < resultLimit {
                    bestMatches.append(candidate)
                }
            }
            orderedMembers = bestMatches.map(\.member)
        }

        var values = orderedMembers.prefix(resultLimit).map { member in
            let topColor = MessageAuthorPresentation.topRoleColor(in: member.roles)
            return MentionAutocompleteSuggestion(
                id: "user:\(member.id)",
                title: member.user.displayName,
                detail: "@\(member.user.username)",
                value: "<@\(member.id)>",
                target: .user(member.id),
                avatarURL: member.guildAvatarURL ?? member.user.avatarURL,
                colorHex: topColor,
                member: member
            )
        }

        let matchingRoles = roles.compactMap { role -> (GuildRole, Int)? in
            role.name.caseInsensitiveCompare("@everyone") != .orderedSame
                && (role.isMentionable || canMentionNonMentionableRoles)
                ? (role, roleMatchRank(name: role.name, query: trimmedQuery))
                : nil
        }.filter { _, rank in
            normalizedQuery.isEmpty || rank > 0
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            let comparison = lhs.0.name.localizedCompare(rhs.0.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.0.id < rhs.0.id
        }
        let remaining = max(0, resultLimit - values.count)
        values.append(contentsOf: matchingRoles.prefix(remaining).map { role, _ in
            MentionAutocompleteSuggestion(
                id: "role:\(role.id)",
                title: "@\(role.name)",
                detail: "",
                value: "<@&\(role.id)>",
                target: .role(role.id),
                colorHex: role.colorHex
            )
        })
        return values
    }

    static func channelSuggestions(
        query: String,
        channels: [Channel],
        guilds: [GuildID: Guild],
        guildAndChannelUsageScores: [String: Int] = [:],
        currentUserID: UserID? = nil,
        currentMember: Member? = nil,
        roles: [GuildRole] = []
    ) -> [MentionAutocompleteSuggestion] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = normalized(trimmedQuery)
        let queryTerms = normalizedQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        var bestMatches: [RankedChannel] = []
        bestMatches.reserveCapacity(25)
        for channel in channels {
            let isTextChannel = switch channel.kind {
            case .text, .announcement, .forum: true
            case .voice, .directMessage, .groupDirectMessage, .unknown: false
            }
            // The supplied channel list is the same already-discovered store
            // used by the sidebar. Re-evaluating permissions here can hide a
            // channel that Discord supplied when the current-member snapshot
            // is still partial (and makes the picker disagree with the
            // sidebar). The comparison client's autocomplete searches that
            // channel store directly, including entries exposed by its active
            // channel-store patches.
            guard isTextChannel else { continue }
            var score = channelMatchScore(
                channel: channel,
                guild: channel.guildID.flatMap { guilds[$0] },
                query: normalizedQuery,
                terms: queryTerms
            )
            if guildAndChannelUsageScores[channel.id.description, default: 0] > 0 {
                // Preserve the current client's observable precedence behavior:
                // its missing parentheses make any positive frecency value a
                // full three-point boost before the 10/7 cap is applied.
                score = min(score + 3, score >= 7 ? 10 : 7)
            }
            guard normalizedQuery.isEmpty || score > 0 else { continue }
            let candidate = RankedChannel(
                channel: channel,
                score: score,
                sidebarPosition: channel.categoryPosition * 100_000 + channel.position
            )
            let insertionIndex = bestMatches.firstIndex { isPreferred(candidate, over: $0) }
            if let insertionIndex {
                bestMatches.insert(candidate, at: insertionIndex)
                if bestMatches.count > 25 { bestMatches.removeLast() }
            } else if bestMatches.count < 25 {
                bestMatches.append(candidate)
            }
        }
        return bestMatches.map { match in
            let channel = match.channel
            return MentionAutocompleteSuggestion(
                id: "channel:\(channel.id)",
                title: channel.name,
                detail: channel.category
                    ?? channel.guildID.flatMap { guilds[$0]?.name }
                    ?? "Channel",
                value: "<#\(channel.id)>",
                target: .channel(channel.id)
            )
        }
    }

    private static func mergingMemberStore(_ members: [Member], updates: [Member]) -> [Member] {
        guard !updates.isEmpty else { return members }
        var result = members
        var positions = Dictionary(uniqueKeysWithValues: members.enumerated().map { ($0.element.id, $0.offset) })
        for update in updates {
            if let index = positions[update.id] {
                result[index] = update
            } else {
                positions[update.id] = result.count
                result.append(update)
            }
        }
        return result
    }

    private static func isPreferred(_ lhs: RankedMember, over rhs: RankedMember) -> Bool {
        if lhs.rank != rhs.rank { return lhs.rank.rawValue > rhs.rank.rawValue }
        // Discord's user comparator is stable for equal scores, so
        // GuildMemberStore insertion order is the exact tie-break.
        return lhs.storeIndex < rhs.storeIndex
    }

    private static func isPreferred(_ lhs: RankedChannel, over rhs: RankedChannel) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.sidebarPosition != rhs.sidebarPosition {
            return lhs.sidebarPosition < rhs.sidebarPosition
        }
        return lhs.channel.id < rhs.channel.id
    }

    private static func memberMatchRank(
        _ member: Member,
        normalizedQuery: String
    ) -> MemberMatchRank {
        guard !normalizedQuery.isEmpty else { return .strong }
        if member.id.description == normalizedQuery { return .strong }
        var hasFuzzyMatch = false
        for candidate in normalizedCandidates(for: member) {
            if candidate.hasPrefix(normalizedQuery) { return .strong }
            if isOrderedSubsequence(normalizedQuery, of: candidate) {
                hasFuzzyMatch = true
            }
        }
        return hasFuzzyMatch ? .fuzzy : .none
    }

    private static func normalizedCandidates(for member: Member) -> [String] {
        let signature = MemberSearchSignature(
            username: member.user.username,
            displayName: member.user.displayName,
            globalDisplayName: member.globalDisplayName
        )
        if let cached = memberSearchCache[member.id], cached.signature == signature {
            return cached.candidates
        }

        var candidates: [String] = []
        candidates.reserveCapacity(6)
        for value in [signature.username, signature.displayName] + [signature.globalDisplayName].compactMap({ $0 }) {
            let lowered = value.lowercased()
            candidates.append(lowered)
            guard !lowered.utf8.allSatisfy({ $0 < 0x80 }) else { continue }
            let folded = normalized(value)
            if folded != lowered {
                candidates.append(folded)
            }
        }
        if memberSearchCache.count >= memberSearchCacheLimit,
           memberSearchCache[member.id] == nil
        {
            memberSearchCache.removeAll(keepingCapacity: true)
        }
        memberSearchCache[member.id] = MemberSearchCacheEntry(
            signature: signature,
            candidates: candidates
        )
        return candidates
    }

    /// Match-sorter's ranking ladder used by Discord for role autocomplete.
    private static func roleMatchRank(name: String, query: String) -> Int {
        guard !query.isEmpty else { return 1 }
        if name == query { return 7 }
        let name = normalized(name)
        let query = normalized(query)
        if name == query { return 6 }
        if name.hasPrefix(query) { return 5 }
        if name.contains(" \(query)") { return 4 }
        if name.contains(query) { return 3 }
        if query.count > 1, acronym(for: name).contains(query) { return 2 }
        return isOrderedSubsequence(query, of: name) ? 1 : 0
    }

    private static func acronym(for value: String) -> String {
        value.split(whereSeparator: { $0 == " " || $0 == "-" })
            .compactMap(\.first)
            .map(String.init)
            .joined()
    }

    private static func channelMatchScore(
        channel: Channel,
        guild: Guild?,
        query: String,
        terms: [String]
    ) -> Double {
        guard !query.isEmpty else { return 7 }
        let name = normalized(channel.name)
        var score: Double
        if name == query {
            score = 10
        } else if name.hasPrefix(query) {
            score = 7
        } else if name.contains(query) {
            score = 5
        } else if !terms.isEmpty, terms.allSatisfy({ name.contains($0) }) {
            score = 3
        } else if isOrderedSubsequence(query, of: name) {
            score = 1
        } else {
            score = 0
        }

        // Discord lets remaining terms match category or guild context, at
        // half weight, while keeping a contextual result below a direct prefix.
        if terms.count > 1 {
            let context = normalized([channel.category, guild?.name].compactMap { $0 }.joined(separator: " "))
            let unmatched = terms.filter { !name.contains($0) }
            if !unmatched.isEmpty, unmatched.allSatisfy({ context.contains($0) }) {
                score = min(score, 6) + 0.5 * Double(unmatched.count)
            }
        }
        return score
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func isOrderedSubsequence(_ needle: String, of haystack: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var remaining = needle[...]
        for character in haystack where !remaining.isEmpty {
            if character == remaining.first { remaining.removeFirst() }
        }
        return remaining.isEmpty
    }

    private static func canView(
        _ channel: Channel,
        guild: Guild?,
        currentUserID: UserID?,
        currentMember: Member?,
        roles: [GuildRole]
    ) -> Bool {
        let viewChannel: UInt64 = 1 << 10
        guard let permissions = resolvedPermissions(
            in: channel,
            guild: guild,
            currentUserID: currentUserID,
            currentMember: currentMember,
            roles: roles
        ) else { return true }
        return permissions & viewChannel != 0
    }

    static func canMentionNonMentionableRoles(
        in channel: Channel?,
        guild: Guild? = nil,
        currentUserID: UserID?,
        currentMember: Member?,
        roles: [GuildRole]
    ) -> Bool {
        guard let channel,
              let permissions = resolvedPermissions(
                  in: channel,
                  guild: guild,
                  currentUserID: currentUserID,
                  currentMember: currentMember,
                  roles: roles
              )
        else { return false }
        let mentionEveryone: UInt64 = 1 << 17
        return permissions & mentionEveryone != 0
    }

    private static func resolvedPermissions(
        in channel: Channel,
        guild: Guild?,
        currentUserID: UserID?,
        currentMember: Member?,
        roles: [GuildRole]
    ) -> UInt64? {
        if guild?.isOwnedByCurrentUser == true { return .max }
        guard let guildID = channel.guildID,
              let currentUserID
        else { return nil }

        let memberRoleIDs: Set<String>
        if let currentMember, currentMember.id == currentUserID {
            memberRoleIDs = Set(currentMember.roles.map { $0.id.description })
        } else {
            memberRoleIDs = []
        }

        var permissions: UInt64
        if let knownPermissions = guild?.currentUserPermissions {
            // The guild list already supplies the current user's aggregate base
            // permissions, even while the member subscription is still warming.
            permissions = knownPermissions
        } else {
            guard let everyone = roles.first(where: {
                $0.id.description == guildID.description
            }), let everyonePermissions = everyone.permissions,
                currentMember?.id == currentUserID
            else { return nil }
            permissions = everyonePermissions
            for role in roles where memberRoleIDs.contains(role.id.description) {
                permissions |= role.permissions ?? 0
            }
        }
        let administrator: UInt64 = 1 << 3
        if permissions & administrator != 0 { return .max }

        let overwrites = channel.permissionOverwrites ?? []
        if let overwrite = overwrites.first(where: {
            $0.type == 0 && $0.id == guildID.description
        }) {
            permissions &= ~overwrite.deny
            permissions |= overwrite.allow
        }

        var roleAllow: UInt64 = 0
        var roleDeny: UInt64 = 0
        for overwrite in overwrites
        where overwrite.type == 0 && memberRoleIDs.contains(overwrite.id) {
            roleAllow |= overwrite.allow
            roleDeny |= overwrite.deny
        }
        permissions &= ~roleDeny
        permissions |= roleAllow

        if let overwrite = overwrites.first(where: {
            $0.type == 1 && $0.id == currentUserID.description
        }) {
            permissions &= ~overwrite.deny
            permissions |= overwrite.allow
        }
        return permissions
    }
}

struct ClosedColonAutocompleteContext {
    private static let expression = try! NSRegularExpression(
        pattern: #"(?:^|\s)(:([A-Za-z0-9_+\-]{2,}):)$"#
    )

    let query: String
    let range: NSRange

    init?(text: String, selection: NSRange?) {
        let cursor = selection?.location ?? text.utf16.count
        guard selection?.length ?? 0 == 0, cursor <= text.utf16.count else { return nil }
        let prefix = (text as NSString).substring(to: cursor)
        guard let match = Self.expression.firstMatch(
            in: prefix,
            range: NSRange(location: 0, length: (prefix as NSString).length)
        ),
            match.range(at: 1).location != NSNotFound,
            match.range(at: 2).location != NSNotFound
        else { return nil }
        range = match.range(at: 1)
        query = (prefix as NSString).substring(with: match.range(at: 2))
    }
}

struct ColonAutocompleteSuggestion: Identifiable {
    let id: String
    let title: String
    let detail: String
    let rankingName: String
    let value: String
    let imageURL: URL?
    let source: String?
    let usageKey: String
    let discordUsageKeys: [String]
    let completionNames: [String]
    let customEmoji: DiscordEmoji?
    let stableOrder: Int

    func matchesCompletionName(_ name: String) -> Bool {
        completionNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

private enum DiscordEmojiAutocompleteRanking {
    static func boundaryExpression(query: String) -> NSRegularExpression {
        let escapedQuery = NSRegularExpression.escapedPattern(for: query.lowercased())
        return try! NSRegularExpression(pattern: "(^|_|[A-Z])\(escapedQuery)s?([A-Z]|_|$)")
    }

    /// Mirrors the public client's base name score. Favorites are composed ahead
    /// of the ordinary search results by the composer rather than changing this
    /// score in the current experiment assignment.
    static func relevance(
        name: String,
        query: String,
        boundaryExpression: NSRegularExpression
    ) -> Double {
        let originalName = name
        let name = name.lowercased()
        let query = query.lowercased()
        var score = 1.0
        if name == query { score += 4 }
        if name.hasPrefix(query) { score += 1 }
        if beginsAtWordOrCapitalBoundary(
            name: originalName,
            expression: boundaryExpression
        ) {
            score += 2
        }
        return score
    }

    private static func beginsAtWordOrCapitalBoundary(
        name: String,
        expression: NSRegularExpression
    ) -> Bool {
        func matches(_ value: String) -> Bool {
            expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex ..< value.endIndex, in: value)
            ) != nil
        }
        return matches(name) || matches(name.lowercased())
    }

    static func searchNormalized(_ value: String) -> String {
        EmojiSearchMatcher.autocompleteNormalized(value)
    }

}

enum ColonAutocompleteSuggestionFactory {
    private struct RankedSuggestion {
        let suggestion: ColonAutocompleteSuggestion
        let isFavorite: Bool
        let score: Double
    }

    static func suggestions(
        query: String,
        customEmojis: [DiscordEmoji],
        customValue: (DiscordEmoji) -> String,
        customSource: (DiscordEmoji) -> String? = { _ in nil },
        favoriteKeys: Set<String> = [],
        discordFavoriteKeys: Set<String> = [],
        usageCounts: [String: Int] = [:],
        discordUsageScores: [String: Int] = [:],
        discordSettingsAreLoaded: Bool? = nil
    ) -> [ColonAutocompleteSuggestion] {
        let normalizedQuery = DiscordEmojiAutocompleteRanking.searchNormalized(query)
        var values = NativeEmojiAutocompleteCatalog.search(query).map { result in
            ColonAutocompleteSuggestion(
                id: result.id,
                title: result.name,
                detail: ":\(result.shortcode):",
                // Discord searches aliases but scores and alphabetizes the
                // entry's primary name. This keeps alias-only matches such as
                // :100: after the primary `sc…` prefix block.
                rankingName: result.rankingName,
                value: result.value,
                imageURL: nil,
                source: nil,
                usageKey: "unicode:\(result.value)",
                discordUsageKeys: [result.rankingName],
                completionNames: result.completionNames,
                customEmoji: nil,
                stableOrder: result.catalogIndex
            )
        }
        let availableCustomEmojis = customEmojis.filter(\.isAvailable)
        let normalizedCustomEmojis = availableCustomEmojis.map { emoji in
            (emoji, DiscordEmojiAutocompleteRanking.searchNormalized(emoji.name))
        }
        var duplicateCounts: [String: Int] = [:]
        duplicateCounts.reserveCapacity(normalizedCustomEmojis.count)
        for (_, normalizedName) in normalizedCustomEmojis {
            duplicateCounts[normalizedName, default: 0] += 1
        }
        var duplicateOrdinals: [String: Int] = [:]
        values.append(contentsOf: normalizedCustomEmojis.enumerated().compactMap {
            index, element in
            let (emoji, normalizedName) = element
            let ordinal = duplicateOrdinals[normalizedName, default: 0]
            duplicateOrdinals[normalizedName] = ordinal + 1
            let displayName = duplicateCounts[normalizedName, default: 0] > 1 && ordinal > 0
                ? "\(emoji.name)~\(ordinal)"
                : emoji.name
            guard normalizedName.contains(normalizedQuery) else { return nil }
            return ColonAutocompleteSuggestion(
                id: "custom:\(emoji.id)",
                title: displayName,
                detail: ":\(displayName):",
                rankingName: displayName,
                value: customValue(emoji),
                imageURL: emoji.imageURL,
                source: customSource(emoji),
                usageKey: "custom:\(emoji.name):\(emoji.id)",
                discordUsageKeys: [emoji.id],
                completionNames: ordinal > 0 ? [displayName, emoji.name] : [emoji.name],
                customEmoji: emoji,
                stableOrder: 100_000 + index
            )
        })

        let usesDiscordSettings = discordSettingsAreLoaded
            ?? !discordUsageScores.isEmpty
        let boundaryExpression = DiscordEmojiAutocompleteRanking.boundaryExpression(query: query)
        let ranked = values.map { suggestion in
            let isFavorite = usesDiscordSettings
                ? suggestion.discordUsageKeys.contains(where: discordFavoriteKeys.contains)
                : favoriteKeys.contains(suggestion.usageKey)
            let frecency = usesDiscordSettings
                ? suggestion.discordUsageKeys.compactMap { discordUsageScores[$0] }.max()
                : nil
            var score = DiscordEmojiAutocompleteRanking.relevance(
                name: suggestion.rankingName,
                query: query,
                boundaryExpression: boundaryExpression
            )
            if let frecency { score *= Double(frecency) / 100 }
            return RankedSuggestion(
                suggestion: suggestion,
                isFavorite: isFavorite,
                score: score
            )
        }
        return ranked.sorted { lhs, rhs in
            // The visible composer hoists matching favorites before the base
            // EmojiStore result. Preserve the account's stored favorite order
            // implicitly through the stable result catalogue when both match.
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.suggestion.rankingName != rhs.suggestion.rankingName {
                return lhs.suggestion.rankingName < rhs.suggestion.rankingName
            }
            if lhs.suggestion.stableOrder != rhs.suggestion.stableOrder {
                return lhs.suggestion.stableOrder < rhs.suggestion.stableOrder
            }
            return lhs.suggestion.id < rhs.suggestion.id
        }.map(\.suggestion)
    }
}

struct EmojiAutocompleteList: View {
    let suggestions: [ColonAutocompleteSuggestion]
    let selectedIndex: Int
    let highlight: (Int) -> Void
    let select: (ColonAutocompleteSuggestion) -> Void

    var body: some View {
        ComposerAutocompletePanel(heading: "EMOJIS", count: suggestions.count) {
            LazyVStack(spacing: 2) {
                    ForEach(suggestions.enumerated(), id: \.element.id) { index, suggestion in
                        EmojiAutocompleteRow(
                            suggestion: suggestion,
                            isSelected: index == selectedIndex,
                            select: { select(suggestion) },
                            highlight: { highlight(index) }
                        )
                    }
            }
        }
    }
}

private struct ComposerAutocompletePanel<Content: View>: View {
    let heading: String
    let count: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(heading)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 5)
            ScrollView {
                content()
                    .padding(.horizontal, 5)
                    .padding(.bottom, 5)
            }
            .frame(height: min(340, CGFloat(max(1, count)) * 42))
        }
        .frame(maxWidth: .infinity)
        .glassEffect(
            .regular.interactive(),
            in: RoundedRectangle(
                cornerRadius: ChatChromeMetrics.controlCornerRadius,
                style: .continuous
            )
        )
    }
}

struct MentionAutocompleteList: View {
    let heading: String
    let suggestions: [MentionAutocompleteSuggestion]
    let selectedIndex: Int
    let highlight: (Int) -> Void
    let select: (MentionAutocompleteSuggestion) -> Void

    var body: some View {
        ComposerAutocompletePanel(heading: heading, count: suggestions.count) {
            LazyVStack(spacing: 2) {
                ForEach(suggestions.enumerated(), id: \.element.id) { index, suggestion in
                    if index > 0,
                       case .role = suggestion.target,
                       case .user = suggestions[index - 1].target
                    {
                        Divider()
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                    }
                    MentionAutocompleteRow(
                        suggestion: suggestion,
                        isSelected: index == selectedIndex,
                        select: { select(suggestion) },
                        highlight: { highlight(index) }
                    )
                }
            }
        }
    }
}

private struct MentionAutocompleteRow: View {
    let suggestion: MentionAutocompleteSuggestion
    let isSelected: Bool
    let select: () -> Void
    let highlight: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 9) {
                leadingVisual
                if suggestion.detail.isEmpty {
                    Text(suggestion.title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            Text(suggestion.title)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 8)
                            Text(suggestion.detail)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        Text(suggestion.title)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 40)
            .background(
                isSelected ? Color.primary.opacity(0.10) : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlight() } }
    }

    @ViewBuilder
    private var leadingVisual: some View {
        switch suggestion.target {
        case .user:
            AvatarView(name: suggestion.title, url: suggestion.avatarURL, size: 28)
        case .role:
            Circle()
                .fill(Color(hex: suggestion.colorHex ?? 0x5865F2))
                .frame(width: 16, height: 16)
                .frame(width: 28, height: 28)
        case .channel:
            Image(systemName: "number")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        case .message:
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
    }
}

private struct EmojiAutocompleteRow: View {
    let suggestion: ColonAutocompleteSuggestion
    let isSelected: Bool
    let select: () -> Void
    let highlight: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 9) {
                if let url = suggestion.imageURL {
                    AnimatedRemoteImage(url: url)
                        .frame(width: 28, height: 28)
                } else {
                    Text(suggestion.value)
                        .font(.title3)
                        .frame(width: 28, height: 28)
                }
                Text(suggestion.detail)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 10)
                if let source = suggestion.source {
                    Text(source)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .background {
            RoundedRectangle(
                cornerRadius: ChatChromeMetrics.controlCornerRadius,
                style: .continuous
            )
            .fill(isSelected ? Color.primary.opacity(0.13) : .clear)
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: ChatChromeMetrics.controlCornerRadius,
                style: .continuous
            )
        )
        .onHover { hovering in
            guard hovering else { return }
            highlight()
        }
    }
}

private struct UploadProgressView: View {
    let progress: MessageSendProgress
    var body: some View {
        HStack(spacing: 8) {
            switch progress {
            case .preparing:
                ProgressView()
                Text("Preparing attachments…")
            case let .reserving(files):
                ProgressView()
                Text("Reserving \(files) file\(files == 1 ? "" : "s")…")
            case let .uploading(fileName, completed, total):
                ProgressView(value: total > 0 ? Double(completed) / Double(total) : 0).frame(width: 90)
                Text("Uploading \(fileName)…").lineLimit(1)
            case .submitting:
                ProgressView()
                Text("Sending message…")
            case .awaitingReconciliation:
                Image(systemName: "clock")
                Text("Waiting for confirmation — do not resend")
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Sent")
            }
        }
        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
    }
}

struct ComposerActionButton: View {
    let systemImage: String
    let help: String
    var iconSize: CGFloat = 18
    var iconWeight: Font.Weight = .medium
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .symbolVariant(.none)
                .font(.system(size: iconSize, weight: iconWeight))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .contentShape(buttonShape)
        }
        .buttonStyle(.plain)
        .background(hoverColor, in: buttonShape)
        .contentShape(buttonShape)
        .onHover { isHovering = $0 }
        .help(help)
    }

    private var buttonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
    }

    private var hoverColor: Color {
        isHovering && isEnabled ? .primary.opacity(0.14) : .clear
    }
}

struct ComposerSendButton: View {
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "paperplane.circle.fill")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(isEnabled ? Color.white : Color.gray.opacity(0.62))
                .frame(width: 36, height: 36)
                .contentShape(buttonShape)
        }
        .buttonStyle(.plain)
        .background(hoverColor, in: buttonShape)
        .contentShape(buttonShape)
        .onHover { isHovering = $0 }
        .help("Send message")
    }

    private var buttonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
    }

    private var hoverColor: Color {
        isHovering && isEnabled ? .primary.opacity(0.14) : .clear
    }
}
