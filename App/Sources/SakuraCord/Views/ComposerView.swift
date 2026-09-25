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
    @State private var showPhotosPicker = false
    @State private var showComposerActions = false
    @State private var showPollCreator = false
    @State private var showGIFPicker = false
    @State private var showStickerPicker = false
    @State private var showEmojiPicker = false
    @State private var isFocused = false
    @State private var isComposing = false
    @State private var draftSelection: NSRange?
    @State private var selectionBeforeEmojiPicker: NSRange?
    @State private var isSubmitting = false
    @State private var gifPickerDismissedAt: TimeInterval = -.infinity
    @State private var stickerPickerDismissedAt: TimeInterval = -.infinity
    @State private var emojiPickerDismissedAt: TimeInterval = -.infinity
    @State private var autocompleteIndex = 0
    @State private var isAutocompleteDismissed = false
    @State private var commandSuggestionIndex = 0
    @State private var isCommandSuggestionsDismissed = false

    var body: some View {
        @Bindable var model = model
        let appearance = model.appearanceSettings.composerBarAppearance
        let accessoryButtonSize = appearance.accessoryButtonSize
        let chrome = ComposerChromeLayout(
            appearance: appearance,
            focus: { isFocused = true },
            header: {
                VStack(alignment: .leading, spacing: 0) {
                    ComposerTranslationHeader(model: model, destination: conversation)
                    if !hasActiveCommand, let reply = activeReply {
                        let author = model.authorPresentation(for: reply)
                        ComposerReplyHeader(
                            authorFontID: author.user.displayNameStyle?.fontID,
                            authorName: author.user.displayName,
                            avatarURL: author.user.avatarURL,
                            roleColorHex: author.roleColorHex,
                            mentionsAuthor: activeReplyMentionsAuthor,
                            canMentionAuthor: author.user.id != model.currentUser?.id,
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
                        ComposerAttachmentButton(appearance: appearance) {
                            showComposerActions.toggle()
                        }
                        .disabled(!hasComposerActions)
                        .opacity(hasComposerActions ? 1 : 0.4)
                        .escapeDismissiblePopover(isPresented: $showComposerActions, arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                if canAddAttachments {
                                    Button {
                                        showComposerActions = false
                                        showFileImporter = true
                                    } label: {
                                        Label("Upload a File", systemImage: "doc.badge.plus")
                                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    }
                                    Button {
                                        showComposerActions = false
                                        showPhotosPicker = true
                                    } label: {
                                        Label("Select from Photos", systemImage: "photo.on.rectangle")
                                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    }
                                }
                                if canCreatePoll {
                                    Button {
                                        showComposerActions = false
                                        showPollCreator = true
                                    } label: {
                                        Label("Create a Poll", systemImage: "chart.bar.xaxis")
                                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    }
                                }
                                ComposerTranslateDraftRow(model: model, destination: conversation) {
                                    showComposerActions = false
                                }
                            }
                            .buttonStyle(PopoverRowButtonStyle()).padding(6).frame(width: 200)
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
                            generalInputSettings: model.generalInputSettings,
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
                                conversationID: activeConversationID,
                                translationEditID: model.translation.draftEditIDs[conversation],
                                placeholder: composerPlaceholder,
                                sendWithReturn: model.generalInputSettings.sendsWithReturn,
                                generalInputSettings: model.generalInputSettings,
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
                                onCompositionStateChange: {
                                    isComposing = $0
                                    if $0 { model.dismissDraftTranslation(in: conversation) }
                                },
                                capturesUnfocusedTyping:
                                    !showEmojiPicker
                                        && !showGIFPicker
                                        && !showStickerPicker,
                                verticalContentInset: appearance == .defaultStyle
                                    ? ChatChromeMetrics.composerTextVerticalInset
                                    : 0,
                                selection: $draftSelection,
                                isFocused: $isFocused
                            )
                            .frame(minHeight: ChatChromeMetrics.composerControlHeight)
                            if draft.isEmpty, !isComposing {
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
                                premiumType: model.currentUser?.premiumType
                            ) {
                                ComposerCharacterCounter(
                                    characterCount: draft.count,
                                    premiumType: model.currentUser?.premiumType
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
                        ForEach(model.appearanceSettings.composerIcons.order) { icon in
                            switch icon {
                            case .gif:
                                if model.supportedCapabilities.contains(.gifs) {
                                    ComposerIconView(icon: .gif, appearance: appearance) {
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
                            case .sticker:
                                if model.supportedCapabilities.contains(.stickers) {
                                    ComposerIconView(icon: .sticker, appearance: appearance) {
                                        toggleStickerPicker()
                                    }
                                    .fixedSize()
                                    .background {
                                        StableReactionPickerPresenter(
                                            isPresented: $showStickerPicker,
                                            preferredEdge: .maxY,
                                            accessibilityIdentifier: "composer-sticker-picker"
                                        ) {
                                            composerStickerPicker
                                        }
                                        .frame(width: accessoryButtonSize, height: accessoryButtonSize)
                                    }
                                }
                            case .emoji:
                                ComposerIconView(icon: .emoji, appearance: appearance) {
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
                    }
                }
                .frame(height: ChatChromeMetrics.composerControlHeight)
            },
            send: {
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let coolingDown = activeConversationID.map {
                        model.slowmodeRemaining(in: $0, now: context.date) > 0
                    } ?? false
                    ComposerSendButton(
                        action: submitComposer,
                        appearance: appearance,
                        isSlowmodeBlocked: coolingDown
                    )
                    .disabled(!composerCanSubmit && !coolingDown)
                }
            },
            overlay: { composerOverlay }
        )
        VStack(spacing: 0) {
            if let activeConversationID {
                ComposerSlowmodeIndicator(model: model, channelID: activeConversationID)
            }
            chrome
                .padding(.horizontal, ChatChromeMetrics.composerWindowInset)
                .padding(.bottom, ChatChromeMetrics.composerWindowInset)
                .keyframeAnimator(
                    initialValue: CGFloat.zero,
                    trigger: activeConversationID.map {
                        model.composer.slowmode.rejectedAttempts[$0, default: 0]
                    } ?? 0
                ) { content, offset in
                    content.offset(x: offset)
                } keyframes: { _ in
                    LinearKeyframe(-5, duration: 0.04)
                    LinearKeyframe(5, duration: 0.06)
                    LinearKeyframe(-3, duration: 0.06)
                    LinearKeyframe(3, duration: 0.06)
                    LinearKeyframe(0, duration: 0.04)
                }
        }
        .windowModal(isPresented: $showPollCreator, title: "Create a Poll") {
            if let channelID = activeConversationID {
                PollCreationView(model: model, channelID: channelID)
            }
        }
        .modifier(ComposerPhotosPicker(
            model: model,
            destination: conversation,
            isPresented: $showPhotosPicker
        ))
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: !hasActiveCommand
        ) { result in
            guard case let .success(urls) = result else { return }
            Task {
                if hasActiveCommand,
                   let option = model.commandComposer.focusedOption, option.type == .attachment,
                   let url = urls.first, !(await model.attachmentURLsWithinDiscordLimit([url])).isEmpty
                {
                    model.commandComposer.setValue(
                        .attachment(url), displayText: url.lastPathComponent, for: option
                    )
                    focusNextCommandField()
                } else if !hasActiveCommand {
                    await model.addComposerAttachments(urls, to: conversation)
                }
            }
        }
        .composerShortcutCommands(
            conversation: conversation,
            focus: { isFocused = true },
            chooseAttachment: { if canAddAttachments { showFileImporter = true } },
            togglePicker: { action in
                guard !hasActiveCommand else { return }
                switch action {
                case .toggleEmojiPicker: toggleEmojiPicker()
                case .toggleGIFPicker: toggleGIFPicker()
                case .toggleStickerPicker: toggleStickerPicker()
                default: break
                }
            }
        )
        .onChange(of: hasComposerActions) { _, available in
            if !available { showComposerActions = false }
        }
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
        .onChange(of: showStickerPicker) { wasPresented, isPresented in
            if wasPresented, !isPresented {
                stickerPickerDismissedAt = ProcessInfo.processInfo.systemUptime
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
            showStickerPicker = false
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
            allowsPersistentSelection: true,
            dismiss: dismissEmojiPicker,
            select: { activation in
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
                restoreComposerFocus(selection: restoredSelection)
            }
        )
    }

    private var composerGIFPicker: some View {
        GIFPickerView(model: model, destination: conversation) {
            showGIFPicker = false
            Task { @MainActor in
                await Task.yield()
                isFocused = true
            }
        }
    }

    private var composerStickerPicker: some View {
        StickerPickerView(model: model, destination: conversation) {
            showStickerPicker = false
            Task { @MainActor in
                await Task.yield()
                isFocused = true
            }
        }
    }

    private func handleEscapeCommand() {
        guard !model.consumeEscapeForMediaViewer() else { return }
        guard !model.consumeEscapeForPinnedMessages() else { return }
        guard !model.consumeEscapeForUnfocusedMessageSearch() else { return }
        if model.consumeEscapeForReply(in: conversation) {
            return
        } else if showGIFPicker {
            showGIFPicker = false
        } else if showStickerPicker {
            showStickerPicker = false
        } else if showEmojiPicker {
            dismissEmojiPicker()
        } else if !attachments.isEmpty {
            _ = model.consumeEscapeForComposerAttachments(in: conversation)
            return
        } else if model.consumeEscapeForSupplementaryConversation() {
            return
        } else if let conversationID = activeConversationID {
            model.completeConversationReadingAndAdvance(
                channelID: conversationID
            )
        }
    }

    private func dismissEmojiPicker() {
        guard showEmojiPicker else { return }
        let restoredSelection = selectionBeforeEmojiPicker
        showEmojiPicker = false
        selectionBeforeEmojiPicker = nil
        restoreComposerFocus(selection: restoredSelection)
    }

    private func restoreComposerFocus(selection: NSRange?) {
        Task { @MainActor in
            await Task.yield()
            isFocused = true
            await Task.yield()
            draftSelection = selection
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
        showStickerPicker = false
    }

    private func toggleGIFPicker() {
        if showGIFPicker {
            showGIFPicker = false
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - gifPickerDismissedAt > 0.25 else { return }
        showEmojiPicker = false
        showStickerPicker = false
        selectionBeforeEmojiPicker = nil
        showGIFPicker = true
    }

    private func toggleStickerPicker() {
        if showStickerPicker {
            showStickerPicker = false
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - stickerPickerDismissedAt > 0.25 else { return }
        showEmojiPicker = false
        showGIFPicker = false
        selectionBeforeEmojiPicker = nil
        showStickerPicker = true
    }

    private func send() {
        guard let activeConversationID, model.allowSlowmodeSubmission(in: activeConversationID) else { return }
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
            Task { await model.addComposerAttachments(urls, to: conversation) }
            return true
        }
        Task {
            let acceptedURLs = await model.attachmentURLsWithinDiscordLimit(urls, offeringExternalUploadFor: conversation)
            guard !acceptedURLs.isEmpty else { return }
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
        guard let currentUser = model.currentUser,
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
                    currentUserID: model.currentUser?.id,
                    currentMember: (model.currentUser?.id).flatMap {
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
                currentUserID: model.currentUser?.id,
                currentMember: (model.currentUser?.id).flatMap { model.membersByID[$0] },
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
            members: commandSuggestionMembers.map(model.cosmeticPolicy.member),
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
                premiumType: model.currentUser?.premiumType
            )
    }

    private var autocompleteSuggestions: [ColonAutocompleteSuggestion] {
        guard let context = autocompleteContext else { return [] }
        return emojiSuggestions(query: context.query)
    }

    private func emojiSuggestions(query: String) -> [ColonAutocompleteSuggestion] {
        ColonAutocompleteSuggestionFactory.suggestions(
            query: query,
            customEmojis: model.composerCustomEmojis,
            customValue: model.composerText(for:),
            customSource: { model.serverRailGuildsByID[$0.guildID]?.name },
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
        model.commandComposer.cancelActiveCommand()
        commandSuggestionIndex = 0
        isCommandSuggestionsDismissed = false
        isFocused = true
    }

    private func submitComposer() {
        guard let activeConversationID, model.allowSlowmodeSubmission(in: activeConversationID) else { return }
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
                // Submission goes through the text view's configured Return policy.
                return false
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

    private var canAddAttachments: Bool {
        model.isComposerDropEligible(conversation)
            && attachments.count < SendMessageDraft.maximumAttachmentCount
    }

    private var canCreatePoll: Bool {
        activeConversationID.map { model.canCreatePoll(in: $0) } ?? false
    }

    private var hasComposerActions: Bool {
        canAddAttachments || canCreatePoll || model.translation.settings.isEnabled
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
