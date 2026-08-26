import MessageRendering
import SakuraCordModels
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    typealias Conversation = MessageComposerDestination

    let model: AppModel
    @Environment(\.composerDropInteraction) private var composerDropInteraction
    let channelName: String
    var conversation: Conversation = .channel
    var onEditMessage: (MessageID) -> Void = { _ in }
    @State private var showFileImporter = false
    @State private var showGIFPicker = false
    @State private var showEmojiPicker = false
    @State private var isFocused = false
    @State private var draftSelection: NSRange?
    @State private var selectionBeforeEmojiPicker: NSRange?
    @State private var isSubmitting = false
    @State private var gifPickerDismissedAt: TimeInterval = -.infinity
    @State private var emojiPickerDismissedAt: TimeInterval = -.infinity
    @State private var autocompleteIndex = 0
    @State private var isAutocompleteDismissed = false
    @State private var commandSuggestionIndex = 0
    @State private var isCommandSuggestionsDismissed = false
    @State private var pendingDiscard: ComposerDiscardRequest?

    var body: some View {
        @Bindable var model = model
        let appearance = model.appearanceSettings.composerBarAppearance
        let accessoryButtonSize = appearance == .defaultStyle
            ? ChatChromeMetrics.composerAccessoryButtonSize
            : ChatChromeMetrics.composerControlHeight
        let chrome = ComposerChromeLayout(
            appearance: appearance,
            focus: { isFocused = true },
            header: {
                VStack(alignment: .leading, spacing: 0) {
                    if !hasActiveCommand, let reply = activeReply {
                        let author = model.authorPresentation(for: reply)
                        ComposerReplyHeader(
                            authorName: author.user.displayName,
                            avatarURL: author.user.avatarURL,
                            roleColorHex: author.roleColorHex,
                            mentionsAuthor: activeReplyMentionsAuthor,
                            canMentionAuthor: author.user.id != model.snapshot?.currentUser.id,
                            toggleMention: toggleReplyMention,
                            cancel: cancelReply
                        )
                        Divider()
                    }
                    if !hasActiveCommand, !attachments.isEmpty {
                        ComposerAttachmentTray(
                            attachments: attachments,
                            open: openComposerAttachment,
                            toggleSpoiler: {
                                model.toggleComposerAttachmentSpoiler($0, in: conversation)
                            },
                            update: {
                                model.updateComposerAttachment($0, in: conversation)
                            },
                            remove: {
                                model.removeComposerAttachment($0, from: conversation)
                            }
                        )
                        Divider()
                            .padding(.horizontal, 11)
                    }
                }
            },
            leading: {
                Group {
                    if !hasActiveCommand {
                        ComposerActionButton(
                            icon: Image(systemName: "plus"),
                            help: "Add attachments",
                            iconSize: 19,
                            iconWeight: .regular,
                            showsHoverBackground: appearance == .legacy,
                            appearance: appearance
                        ) {
                            showFileImporter = true
                        }
                    }
                }
            },
            input: {
                Group {
                    if hasActiveCommand {
                        ApplicationCommandInlineInput(
                            composer: model.commandComposer,
                            roles: model.guildRoles,
                            sendWithReturn: model.chatSettings.sendsWithReturn,
                            chatSettings: model.chatSettings,
                            onTextChange: { option, text in
                                updateCommandField(text, for: option)
                            },
                            onSubmit: submitComposer,
                            onKeyboardCommand: handleAutocomplete,
                            cancel: cancelCommand,
                            isFocused: $isFocused
                        )
                    } else {
                        ZStack(alignment: .bottomTrailing) {
                            ComposerTextView(
                                text: draft,
                                placeholder: composerPlaceholder,
                                sendWithReturn: model.chatSettings.sendsWithReturn,
                                chatSettings: model.chatSettings,
                                mentionPresentations: composerMentionPresentations,
                                onTextChange: updateDraft,
                                onSubmit: send,
                                onEscape: handleEscapeCommand,
                                onEditLatestMessage: editLatestMessage,
                                onNavigateReplySelection: { direction in
                                    model.navigateReplySelection(
                                        in: conversation,
                                        direction: direction
                                    )
                                },
                                onAutocompleteCommand: handleAutocomplete,
                                onPasteAttachments: addPastedAttachments,
                                onDropTargetChanged: { targeted, instant in
                                    composerDropInteraction?.update(
                                        isTargeted: targeted,
                                        destination: conversation,
                                        isInstant: instant
                                    )
                                },
                                onDropAttachments: handleDroppedAttachments,
                                capturesUnfocusedTyping:
                                    model.chatSettings.focusesComposerOnTyping,
                                verticalContentInset: appearance == .defaultStyle
                                    ? ChatChromeMetrics.composerTextVerticalInset
                                    : 0,
                                selection: $draftSelection,
                                isFocused: $isFocused
                            )
                            if draft.isEmpty {
                                Text(composerPlaceholder)
                                    .foregroundStyle(.tertiary)
                                    .font(.system(size: 15))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                                    .frame(
                                        maxWidth: .infinity,
                                        maxHeight: .infinity,
                                        alignment: .leading
                                    )
                            }
                            if ChatCharacterLimitPolicy.shouldShowCounter(
                                characterCount: draft.count,
                                premiumType: model.snapshot?.currentUser.premiumType
                            ) {
                                ComposerCharacterCounter(
                                    characterCount: draft.count,
                                    premiumType: model.snapshot?.currentUser.premiumType
                                )
                            }
                        }
                    }
                }
                .frame(minHeight: ChatChromeMetrics.composerControlHeight)
                .layoutPriority(1)
            },
            accessories: {
                HStack(spacing: 1) {
                    if !hasActiveCommand {
                        if model.supportedCapabilities.contains(.gifs) {
                            ComposerActionButton(
                                icon: Image("gif.square", bundle: .module),
                                help: "Choose GIF",
                                iconSize: 20,
                                iconWeight: .medium,
                                size: accessoryButtonSize,
                                appearance: appearance
                            ) {
                                toggleGIFPicker()
                            }
                            .fixedSize()
                            .background {
                                StableReactionPickerPresenter(
                                    isPresented: $showGIFPicker,
                                    preferredEdge: .maxY,
                                    accessibilityIdentifier: "composer-gif-picker"
                                ) {
                                    composerGIFPicker
                                }
                                .frame(width: accessoryButtonSize, height: accessoryButtonSize)
                            }
                        }
                        ComposerActionButton(
                            icon: SakuraCordSystemSymbol.emojiFaceGrinningImage,
                            help: "Choose emoji",
                            iconSize: 19,
                            iconWeight: .medium,
                            size: accessoryButtonSize,
                            appearance: appearance
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
                            .frame(width: accessoryButtonSize, height: accessoryButtonSize)
                        }
                    }
                }
                .frame(height: ChatChromeMetrics.composerControlHeight)
            },
            send: {
                ComposerSendButton(
                    action: submitComposer,
                    appearance: appearance
                )
                .disabled(!composerCanSubmit)
            },
            overlay: { composerOverlay }
        )
        chrome
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: !hasActiveCommand
        ) { result in
            guard case let .success(urls) = result else { return }
            if hasActiveCommand,
               let option = model.commandComposer.focusedOption, option.type == .attachment,
               let url = urls.first, !model.attachmentURLsWithinDiscordLimit([url]).isEmpty
            {
                model.commandComposer.setValue(
                    .attachment(url), displayText: url.lastPathComponent, for: option
                )
                focusNextCommandField()
            } else if !hasActiveCommand {
                model.addComposerAttachments(urls, to: conversation)
            }
        }
        .composerDiscardConfirmation(
            request: $pendingDiscard,
            discard: performPendingDiscard
        )
        .composerShortcutCommands(
            conversation: conversation,
            focus: { isFocused = true },
            editLatest: { if !hasActiveCommand { _ = editLatestMessage() } },
            chooseAttachment: { if !hasActiveCommand { showFileImporter = true } }
        )
        .onChange(of: showEmojiPicker) { wasPresented, isPresented in
            if wasPresented, !isPresented {
                emojiPickerDismissedAt = ProcessInfo.processInfo.systemUptime
            }
        }
        .onChange(of: showGIFPicker) { wasPresented, isPresented in
            if wasPresented, !isPresented {
                gifPickerDismissedAt = ProcessInfo.processInfo.systemUptime
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
        .onDisappear {
            composerDropInteraction?.clear(destination: conversation)
        }
        .task(id: composerPresentationID) {
            draftSelection = nil
            selectionBeforeEmojiPicker = nil
            showFileImporter = false
            showGIFPicker = false
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
            if model.commandComposer.focusedOption == nil || isFocused,
               !isCommandSuggestionsDismissed,
               !suggestions.isEmpty
                   || model.commandComposer.isAutocompleteLoading
                   || model.commandComposer.autocompleteError != nil
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
                    highlight: { autocompleteIndex = $0 },
                    select: { acceptMentionAutocomplete($0, context: context) }
                )
            }
        } else if let context = autocompleteContext {
            let suggestions = emojiSuggestions(query: context.query)
            if !suggestions.isEmpty {
                EmojiAutocompleteList(
                    suggestions: suggestions,
                    selectedIndex: autocompleteIndex,
                    highlight: { autocompleteIndex = $0 },
                    select: { acceptAutocomplete($0, context: context) }
                )
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
        .onExitCommand {
            handleEscapeCommand()
        }
    }

    private var composerGIFPicker: some View {
        GIFPickerView(model: model) {
            showGIFPicker = false
            Task { @MainActor in
                await Task.yield()
                isFocused = true
            }
        }
    }

    private func handleEscapeCommand() {
        guard !model.consumeEscapeForMediaViewer() else { return }
        guard !model.consumeEscapeForUnfocusedMessageSearch() else { return }
        if model.consumeEscapeForReply(in: conversation) {
            return
        } else if showGIFPicker {
            showGIFPicker = false
        } else if showEmojiPicker {
            showEmojiPicker = false
        } else if !attachments.isEmpty {
            if GeneralComposerDiscardPolicy.shouldConfirmUnsentContent(
                isEnabled: confirmsDiscardComposer,
                itemCount: attachments.count
            ) {
                pendingDiscard = .attachments
            } else {
                _ = model.consumeEscapeForComposerAttachments(in: conversation)
            }
            return
        } else if model.consumeEscapeForSupplementaryConversation() {
            return
        } else if let conversationID = activeConversationID {
            model.completeConversationReadingAndAdvance(
                channelID: conversationID
            )
        }
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
        showGIFPicker = false
    }

    private func toggleGIFPicker() {
        if showGIFPicker {
            showGIFPicker = false
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - gifPickerDismissedAt > 0.25 else { return }
        showEmojiPicker = false
        selectionBeforeEmojiPicker = nil
        showGIFPicker = true
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
        model.beginUsingOwnedPromisedFiles(staged.map(\.url))
        model.clearComposerAttachments(for: conversation)
        Task {
            defer {
                model.endUsingOwnedPromisedFiles(staged.map(\.url))
            }
            let scopedURLs = staged.map(\.url).filter {
                $0.startAccessingSecurityScopedResource()
            }
            defer {
                for url in scopedURLs {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let result = switch conversation {
            case .channel:
                await model.submitComposerMessage(attachments: staged)
            case .thread:
                await model.submitThreadComposerMessage(attachments: staged)
            }
            if !result.consumedComposer, activeConversationID == conversationID {
                model.restoreComposerAttachments(staged, to: conversation)
            }
            isSubmitting = false
            isFocused = true
        }
    }

    private func handleDroppedAttachments(
        _ urls: [URL],
        isInstant: Bool
    ) -> Bool {
        guard !urls.isEmpty else { return false }
        if !isInstant {
            return model.addComposerAttachments(urls, to: conversation)
        }
        let acceptedURLs = model.attachmentURLsWithinDiscordLimit(
            urls,
            offeringExternalUploadFor: conversation
        )
        guard !acceptedURLs.isEmpty else { return true }
        Task {
            let scopedURLs = acceptedURLs.filter {
                $0.startAccessingSecurityScopedResource()
            }
            defer {
                for url in scopedURLs {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            await model.sendAttachmentsImmediately(
                acceptedURLs.map { ForumPostAttachment(url: $0) },
                to: conversation
            )
        }
        return true
    }

    private func openComposerAttachment(_ id: UUID) {
        guard let currentUser = model.snapshot?.currentUser,
              let presentation = NativeTimelineMediaViewerPlan.composerAttachments(
                  attachments,
                  selectedAttachmentID: id,
                  author: currentUser
              )
        else { return }
        model.mediaViewerPresentation = presentation
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
        return MessageDocumentCache.shared.document(for: draft).segments.reduce(into: [:]) { values, segment in
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
            && draft.count <= ChatCharacterLimitPolicy.limit(
                premiumType: model.snapshot?.currentUser.premiumType
            )
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
        model.clearComposerAttachments(for: conversation)
        draftSelection = nil
        commandSuggestionIndex = 0
        isCommandSuggestionsDismissed = false
        isFocused = true
    }

    private func cancelCommand() {
        if GeneralComposerDiscardPolicy.shouldConfirmUnsentContent(
            isEnabled: confirmsDiscardComposer,
            itemCount: model.commandComposer.hasMeaningfulDraft ? 1 : 0
        ) {
            pendingDiscard = .command
            return
        }
        discardCommand()
    }

    private func discardCommand() {
        model.commandComposer.cancelActiveCommand()
        commandSuggestionIndex = 0
        isCommandSuggestionsDismissed = false
        isFocused = true
    }

    private var confirmsDiscardComposer: Bool {
        SettingsPreferenceStore.shared.value(for: .confirmDiscardComposer)
            != .bool(false)
    }

    private func performPendingDiscard() {
        let request = pendingDiscard
        pendingDiscard = nil
        switch request {
        case .attachments:
            _ = model.consumeEscapeForComposerAttachments(in: conversation)
        case .command:
            discardCommand()
        case nil:
            break
        }
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
            return handleActiveCommandAutocomplete(command)
        }
        if conversation == .channel, model.commandComposer.isPickerPresented {
            return handleCommandPickerAutocomplete(command)
        }
        if let context = mentionAutocompleteContext, !mentionAutocompleteSuggestions.isEmpty {
            return handleMentionAutocomplete(command, context: context)
        }
        guard let context = autocompleteContext, !autocompleteSuggestions.isEmpty else { return false }
        return handleColonAutocomplete(command, context: context)
    }

    private func handleActiveCommandAutocomplete(_ command: ComposerAutocompleteCommand) -> Bool {
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
            } else if model.commandComposer.focusedOption != nil {
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

    private func handleCommandPickerAutocomplete(_ command: ComposerAutocompleteCommand) -> Bool {
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

    private func handleMentionAutocomplete(
        _ command: ComposerAutocompleteCommand,
        context: MentionAutocompleteContext
    ) -> Bool {
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

    private func handleColonAutocomplete(
        _ command: ComposerAutocompleteCommand,
        context: ColonAutocompleteContext
    ) -> Bool {
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

    private var composerPlaceholder: String {
        ComposerPlaceholderPolicy.text(
            channelName: channelName,
            channelKind: model.selectedChannel?.kind,
            destination: conversation
        )
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
        switch conversation {
        case .channel: model.replyingTo
        case .thread: model.threadReplyingTo
        }
    }

    private var activeReplyMentionsAuthor: Bool {
        switch conversation {
        case .channel: model.replyMentionsAuthor
        case .thread: model.threadReplyMentionsAuthor
        }
    }

    private var attachments: [ForumPostAttachment] {
        model.composerAttachments(for: conversation)
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
            model.updateThreadDraft(value)
        }
    }

    private func cancelReply() {
        model.cancelReply(in: conversation)
    }

    private func toggleReplyMention() {
        model.setReplyMentionsAuthor(
            !activeReplyMentionsAuthor,
            in: conversation
        )
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
    private static let expression = RegularExpressionFactory.make(
        #"(?:^|\s)(:[A-Za-z0-9_+\-]*)$"#
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
    private static let expression = RegularExpressionFactory.make(
        #"(?:^|\s)([@#]([^\s@#]*))$"#
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
    var systemImage: String?
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
                target: .channel(channel.id),
                systemImage: ChannelIconPresentation.systemImage(
                    for: channel.kind,
                    isHidden: false
                )
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
    private static let expression = RegularExpressionFactory.make(
        #"(?:^|\s)(:([A-Za-z0-9_+\-]{2,}):)$"#
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
        return RegularExpressionFactory.make("(^|_|[A-Z])\(escapedQuery)s?([A-Z]|_|$)")
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
        values.append(contentsOf: normalizedCustomEmojis.enumerated().compactMap { index, element in
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

struct ComposerAutocompletePanel<Content: View>: View {
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
            in: ConcentricRectangle(
                corners: .concentric(
                    minimum: .fixed(
                        ChatChromeMetrics.composerMinimumCornerRadius
                    )
                ),
                isUniform: true
            )
        )
        .containerShape(
            .rect(
                cornerRadius: ChatChromeMetrics.composerMinimumCornerRadius,
                style: .continuous
            )
        )
    }
}
