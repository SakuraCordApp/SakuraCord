import MessageRendering
import SakuraCordModels
import SwiftUI
import UniformTypeIdentifiers

/// `@time` and `@game` open a picker that replaces their query in the draft.
private enum ComposerMentionPicker {
    case time(range: NSRange, seconds: Int64)
    case game(range: NSRange)
}

struct ComposerView: View {
    typealias Conversation = MessageComposerDestination

    let model: AppModel
    @Environment(\.composerDropInteraction) private var composerDropInteraction
    @Environment(\.appearsActive) private var appearsActive
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
    @Environment(\.columnPresentation) private var columnPresentation
    @Environment(\.isLeavingWorkspace) private var isLeaving
    /// The send button's mode before the composer's pane began to leave.
    /// Closing a thread clears its draft and recording and allows no voice
    /// messages, and the button changed as the pane slid away.
    @State private var showedSendSlotMode = ComposerSendSlot.Mode.send
    @State private var focusedColumnPresentation = 0
    @State private var isComposing = false
    @State private var draftSelection: NSRange?
    @State private var selectionBeforeEmojiPicker: NSRange?
    @State private var isSubmitting = false
    @State private var gifPickerDismissedAt: TimeInterval = -.infinity
    @State private var stickerPickerInitialQuery = ""
    @State private var stickerPickerDismissedAt: TimeInterval = -.infinity
    @State private var emojiPickerDismissedAt: TimeInterval = -.infinity
    @State private var autocompleteIndex = 0
    @State private var autocompleteKeyboardSelectionRevision = 0
    @State private var isAutocompleteDismissed = false
    @State private var commandAwaitingClear: ApplicationCommand?
    @State private var timestampClock = RelativeTimestampDisplayClock()
    @State private var mentionPicker: ComposerMentionPicker?
    @State private var sendTransitionAnchor = ComposerSendTransitionAnchor()
    @State private var holdsPlaceholderForSendTransition = false
    /// A send clears the composer under the message leaving it, so the
    /// composer collapses at once rather than animating.
    @State private var isClearingForSend = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                        .transition(Self.headerTransition)
                        Divider()
                            .transition(.opacity)
                    }
                    if !hasActiveCommand, !attachments.isEmpty {
                        ComposerAttachmentTray(
                            attachments: attachments,
                            checkingIDs: model.composer.checkingAttachmentIDs,
                            sendTransitionAnchor: sendTransitionAnchor,
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
                        .transition(Self.headerTransition)
                        Divider()
                            .padding(.horizontal, InterfaceScale.metric(11))
                            .transition(.opacity)
                    }
                }
                // The composer grows upward, so the header rises out of the
                // field rather than dropping in from above.
                .clipped()
            },
            leading: {
                Group {
                    if hasActiveCommand, let commandDraft = commandComposer.draft {
                        ApplicationCommandComposerBadge(command: commandDraft.command, cancel: cancelCommand)
                    } else if !isCreatingThread {
                        composerLeadingButton(appearance: appearance)
                        .escapeDismissiblePopover(isPresented: $showComposerActions, arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: InterfaceScale.metric(4)) {
                                if canAddAttachments {
                                    Button {
                                        showComposerActions = false
                                        showFileImporter = true
                                    } label: {
                                        Label("Upload a File", systemImage: "doc.badge.plus")
                                            .frame(maxWidth: .infinity, alignment: .leading).padding(InterfaceScale.metric(8))
                                    }
                                    Button {
                                        showComposerActions = false
                                        showPhotosPicker = true
                                    } label: {
                                        Label("Select from Photos", systemImage: "photo.on.rectangle")
                                            .frame(maxWidth: .infinity, alignment: .leading).padding(InterfaceScale.metric(8))
                                    }
                                }
                                if canCreateThread {
                                    Button {
                                        showComposerActions = false
                                        model.beginThreadCreation()
                                    } label: {
                                        Label {
                                            Text("Create Thread")
                                        } icon: {
                                            SakuraCordSystemSymbol.swiftUIImage(named: SakuraCordSystemSymbol.thread)
                                        }
                                            .frame(maxWidth: .infinity, alignment: .leading).padding(InterfaceScale.metric(8))
                                    }
                                }
                                if canCreatePoll {
                                    Button {
                                        showComposerActions = false
                                        showPollCreator = true
                                    } label: {
                                        Label("Create a Poll", systemImage: "chart.bar.xaxis")
                                            .frame(maxWidth: .infinity, alignment: .leading).padding(InterfaceScale.metric(8))
                                    }
                                }
                                ComposerTranslateDraftRow(model: model, destination: conversation) {
                                    showComposerActions = false
                                }
                            }
                            .labelStyle(ComposerActionLabelStyle())
                            .buttonStyle(PopoverRowButtonStyle()).padding(InterfaceScale.metric(6)).frame(width: InterfaceScale.metric(200))
                        }
                    }
                }
            },
            input: {
                Group {
                    if hasActiveCommand, let commandDraft = commandComposer.draft {
                        ApplicationCommandEditorView(
                            composer: commandComposer,
                            draft: commandDraft,
                            caretRequestRevision: commandComposer.caretRequestRevision,
                            fieldIssue: commandComposer.fieldIssue,
                            roles: model.guildRoles,
                            generalInputSettings: model.generalInputSettings,
                            capturesUnfocusedTyping: capturesUnfocusedTyping,
                            onKeyboardCommand: handleAutocomplete,
                            onSubmit: submitComposer,
                            onCancel: leaveCommand(restoring:),
                            canReceiveAttachment: {
                                commandComposer.pastedAttachmentOption != nil
                            },
                            receiveAttachment: { attachments in
                                Task { await model.receiveCommandAttachment(attachments, in: conversation) }
                            },
                            // Ignore focus callbacks from the editor being replaced.
                            isFocused: Binding(
                                get: { hasActiveCommand && isFocused },
                                set: { if hasActiveCommand { isFocused = $0 } }
                            )
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
                                onSubmit: submitComposer,
                                onEscape: handleEscapeCommand,
                                onEditLatestMessage: editLatestMessage,
                                onNavigateReplySelection: { direction in
                                    model.navigateReplySelection(
                                        in: conversation,
                                        direction: direction
                                    )
                                },
                                onAutocompleteCommand: handleAutocomplete,
                                onDropTargetChanged: { targeted, instant in
                                    composerDropInteraction?.update(
                                        isTargeted: targeted,
                                        destination: conversation,
                                        isInstant: instant
                                    )
                                },
                                onReceiveAttachments: { attachments, isInstant in
                                    Task {
                                        await model.receiveComposerAttachments(
                                            attachments,
                                            to: conversation,
                                            sendingImmediately: isInstant
                                        )
                                    }
                                    return true
                                },
                                canReceiveAttachments: { model.isComposerDropEligible(conversation) },
                                onCompositionStateChange: {
                                    isComposing = $0
                                    if $0, model.draftTranslation(for: conversation)?.phase == .translating {
                                        model.dismissDraftTranslation(in: conversation)
                                    }
                                },
                                capturesUnfocusedTyping: capturesUnfocusedTyping,
                                verticalContentInset: appearance == .defaultStyle
                                    ? ChatChromeMetrics.composerTextVerticalInset
                                    : 0,
                                sendTransitionAnchor: sendTransitionAnchor,
                                selection: $draftSelection,
                                // The hidden editor takes no typing while a voice message is shown.
                                isFocused: Binding(
                                    get: { !hasActiveCommand && !isVoiceMessageActive && isFocused },
                                    set: { if !hasActiveCommand, !isVoiceMessageActive { isFocused = $0 } }
                                )
                            )
                            .frame(minHeight: ChatChromeMetrics.composerControlHeight)
                            .opacity(isVoiceMessageActive ? 0 : 1)
                            .allowsHitTesting(!isVoiceMessageActive)
                            .accessibilityHidden(isVoiceMessageActive)
                            if draft.isEmpty, !isComposing, !isVoiceMessageActive {
                                Text(composerPlaceholder)
                                    .foregroundStyle(.tertiary)
                                    .font(.interfaceSystem(size: 15))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                                    // Typing swaps it for text at once; the composer's animations don't fade it.
                                    .transition(.identity)
                                    // Sent text leaves from this spot; let it go first.
                                    .opacity(holdsPlaceholderForSendTransition ? 0 : 1)
                                    .animation(.easeIn(duration: 0.15), value: holdsPlaceholderForSendTransition)
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
                            if isVoiceMessageActive { voiceMessageField }
                        }
                    }
                }
                .frame(minHeight: ChatChromeMetrics.composerControlHeight)
                .layoutPriority(1)
            },
            accessories: {
                HStack(spacing: 1) {
                    if !isVoiceMessageActive {
                        ForEach(model.appearanceSettings.composerIcons.order) { icon in
                            switch icon {
                            case .gif:
                                if model.supportedCapabilities.contains(.gifs), !isCreatingThread {
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
                                if model.supportedCapabilities.contains(.stickers), !isCreatingThread {
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
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    } else if voiceMessage.phase.recording != nil { voiceMessageDiscardButton(appearance: appearance) }
                }
                .frame(height: ChatChromeMetrics.composerControlHeight)
                .disabled(hasActiveCommand)
            },
            send: { composerSendSlot(appearance: appearance) },
            overlay: { composerOverlay }
        )
        VStack(spacing: 0) {
            if let activeConversationID {
                ComposerSlowmodeIndicator(model: model, channelID: activeConversationID)
            }
            chrome
                .animation(.smooth(duration: 0.42, extraBounce: 0.08), value: voiceMessagePhaseKey)
                .animation(.smooth(duration: 0.3), value: showsVoiceMessageButton)
                .onChange(of: isLeaving ? nil : liveSendSlotMode, initial: true, holdSendSlotMode)
                .animation(animatesChromeResize ? ComposerResizeMotion.animation : nil, value: chromeKey)
                // Another conversation's composer appears in place, as the
                // timeline does.
                .transaction(value: activeConversationID) { $0.disablesAnimations = true }
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
        .windowModal(isPresented: $showPollCreator, cornerRadius: InterfaceScale.metric(32), cornerStyle: .circular) {
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
                if hasActiveCommand {
                    await model.receiveCommandAttachment(.external(urls), in: conversation)
                } else {
                    await model.addComposerAttachments(urls, to: conversation)
                }
            }
        }
        .composerShortcutCommands(
            conversation: conversation,
            focus: { selection in
                if let selection { draftSelection = selection }
                isFocused = true
            },
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
        .background { commandMentionHandling }
        .onChange(of: draftHasRelativeTimestamp, initial: true) { _, counts in
            counts ? timestampClock.start() : timestampClock.stop()
        }
        .onChange(of: model.builtInExpressionPickerRequest) { _, request in
            guard let request,
                  request.channelID == activeConversationID else { return }
            model.builtInExpressionPickerRequest = nil
            showEmojiPicker = false
            switch request.kind {
            case .gif:
                showStickerPicker = false
                if !request.query.isEmpty { model.searchGIFs(request.query) }
                showGIFPicker = true
            case .sticker:
                showGIFPicker = false
                stickerPickerInitialQuery = request.query
                showStickerPicker = true
            }
        }
        .onChange(of: draft) { _, value in
            mentionPicker = nil
            if completeClosedEmojiName(in: value) {
                return
            }
            isAutocompleteDismissed = false
            autocompleteIndex = 0
            updateSlashPicker(for: value)
            updateMentionMemberSearch()
        }
        .onChange(of: chromeKey) { previous, current in
            guard animatesChromeResize,
                  previous.conversationID == current.conversationID
            else { return }
            model.composer.noteAnimatedResize(of: conversation)
        }
        .onChange(of: draftSelection) { _, _ in
            isAutocompleteDismissed = false
            autocompleteIndex = 0
            updateMentionMemberSearch()
        }
        .onChange(of: commandComposer.draft) { previous, current in
            guard let current else {
                model.cancelApplicationCommandAutocompleteTask(in: conversation)
                model.cancelApplicationCommandMemberSearch(in: conversation)
                return
            }
            if previous?.focus != current.focus {
                model.cancelApplicationCommandMemberSearch(in: conversation)
            }
            model.refreshApplicationCommandAutocomplete(in: conversation)
            updateCommandMemberSearch(current)
        }
        .onDisappear(perform: composerDidDisappear)
        .onChange(of: voiceMessage.errorMessage) { _, message in
            guard let message else { return }
            model.errorMessage = message
            voiceMessage.clearError()
        }
        .task(id: composerPresentationID) {
            if !voiceMessage.restoreAfterGuildTimeout(in: activeConversationID) {
                voiceMessage.discard(playback: model.voiceMessagePlayback)
            }
            sendTransitionAnchor.channelID = activeConversationID
            model.timelineSendTransitionStore.registerComposer(sendTransitionAnchor)
            draftSelection = nil
            mentionPicker = nil
            selectionBeforeEmojiPicker = nil
            showFileImporter = false
            showGIFPicker = false
            showStickerPicker = false
            showEmojiPicker = false
            let isClosedVoiceChat = model.selectedChannel?.kind == .voice
                && !model.isVoiceChatOpen
            guard conversation == .thread || !isClosedVoiceChat else { return }
            await clearFocusOfReusedPane()
            isFocused = true
            if supportsCommands {
                model.ensureApplicationCommandsLoaded(in: conversation)
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
        return "\(conversation):\(conversationID):\(model.isVoiceChatOpen):\(columnPresentation)"
    }

    private var commandPanelCornerRadius: CGFloat {
        model.appearanceSettings.composerBarAppearance == .legacy
            ? ChatChromeMetrics.composerMinimumCornerRadius : ChatChromeMetrics.composerCornerRadius
    }

    @ViewBuilder
    private var composerMenus: some View {
        if supportsCommands, commandComposer.isPickerPresented,
           // Like Discord, nothing shows for a query that matches no command.
           !commandComposer.pickerSections.isEmpty
               || commandComposer.isLoading || commandComposer.loadError != nil
        {
            ApplicationCommandPickerView(
                composer: commandComposer,
                choose: activateCommand,
                dismiss: commandComposer.dismissPicker,
                cornerRadius: commandPanelCornerRadius
            )
        } else if hasActiveCommand, let draft = commandComposer.draft {
            VStack(spacing: InterfaceScale.metric(6)) {
                if let content = visibleCommandSuggestionContent {
                    ApplicationCommandSuggestionPanel(
                        content: content,
                        selectedIndex: commandComposer.suggestionIndex ?? content.defaultIndex,
                        select: acceptCommandSuggestion,
                        highlight: { commandComposer.suggestionIndex = $0 },
                        cornerRadius: commandPanelCornerRadius,
                        keyboardSelectionRevision: autocompleteKeyboardSelectionRevision
                    )
                }
                ApplicationCommandHelpStrip(draft: draft, issue: commandComposer.fieldIssue, cancel: cancelCommand)
                    .commandPanelSurface(cornerRadius: commandPanelCornerRadius)
            }
        } else if let mentionPicker {
            mentionPickerMenu(mentionPicker)
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
                    select: { acceptMentionAutocomplete($0, context: context) },
                    cornerRadius: commandPanelCornerRadius,
                    keyboardSelectionRevision: autocompleteKeyboardSelectionRevision
                )
            }
        } else if let context = autocompleteContext {
            let suggestions = emojiSuggestions(query: context.query)
            if !suggestions.isEmpty {
                EmojiAutocompleteList(
                    suggestions: suggestions,
                    selectedIndex: autocompleteIndex,
                    highlight: { autocompleteIndex = $0 },
                    select: { acceptAutocomplete($0, context: context) },
                    cornerRadius: commandPanelCornerRadius,
                    keyboardSelectionRevision: autocompleteKeyboardSelectionRevision
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
        StickerPickerView(model: model, destination: conversation, initialQuery: stickerPickerInitialQuery) {
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
        guard !isCreatingThread else { return }

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
        guard !isCreatingThread else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - stickerPickerDismissedAt > 0.25 else { return }
        stickerPickerInitialQuery = ""
        showEmojiPicker = false
        showGIFPicker = false
        selectionBeforeEmojiPicker = nil
        showStickerPicker = true
    }

    private func send() {
        guard !isSubmitting, allowsSubmission() else { return }
        if isCreatingThread, !model.validateThreadCreation() { return }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty,
              !hasCheckingAttachments
        else { return }
        isSubmitting = true
        draftSelection = nil
        selectionBeforeEmojiPicker = nil
        let staged = attachments
        let conversationID = activeConversationID
        let keepsCreationDraft = isCreatingThread
        if !keepsCreationDraft, let conversationID {
            registerSendTransition(channelID: conversationID, attachments: staged)
        }
        model.beginUsingOwnedPromisedFiles(staged.map(\.url))
        if !keepsCreationDraft {
            isClearingForSend = true
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                // The files go on to the outbox, keeping their early uploads.
                model.setComposerAttachments([], for: conversation)
            }
            Task { @MainActor in
                // The draft and reply clear once the message is enqueued.
                try? await Task.sleep(for: .milliseconds(250))
                isClearingForSend = false
            }
        }
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
            if !result.consumedComposer, let conversationID {
                // Nothing will arrive to take the held message over.
                model.timelineSendTransitionStore.discard(conversationID)
            }
            if !keepsCreationDraft, !result.consumedComposer {
                model.returnUnsentComposerAttachments(staged, to: conversation, from: conversationID)
            }
            isSubmitting = false
            isFocused = true
        }
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
                recentMessages: activeMessages.filter { !model.isMessageSuppressed($0) },
                localMembers: model.mentionAutocompleteMembers.filter { !model.isUserIgnored($0.id) },
                remoteMembers: model.mentionMemberResults.filter { !model.isUserIgnored($0.id) },
                roles: model.guildRoles,
                isGuildChannel: model.selectedChannel?.guildID != nil,
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

    private var commandSuggestionContent: ApplicationCommandSuggestionContent? {
        guard let draft = commandComposer.draft else { return nil }
        return ApplicationCommandSuggestionFactory.content(
            draft: draft,
            autocomplete: commandComposer.autocompleteStatus,
            members: commandSuggestionMembers.map(model.cosmeticPolicy.member),
            roles: model.guildRoles,
            channels: model.visibleChannels
        )
    }

    private var visibleCommandSuggestionContent: ApplicationCommandSuggestionContent? {
        guard isInputActive, !commandComposer.areSuggestionsDismissed,
              let content = commandSuggestionContent, !content.isEmpty
        else { return nil }
        return content
    }

    private var commandSuggestionMembers: [Member] {
        var seen = Set<UserID>()
        return (commandComposer.memberResults + model.members).filter { seen.insert($0.id).inserted }
    }

    private func updateCommandMemberSearch(_ draft: ApplicationCommandDraft) {
        guard let field = draft.focusedField, field.resolved == nil,
              field.option.type == .user || field.option.type == .mentionable
        else { return }
        let text = field.text.trimmingCharacters(in: .whitespaces)
        model.requestApplicationCommandMemberSearch(
            query: text.hasPrefix("@") ? String(text.dropFirst()) : text, in: conversation
        )
    }

    private var composerCanSubmit: Bool {
        if hasActiveCommand {
            return true
        }
        return !isSubmitting
            && !hasCheckingAttachments
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
        draftSelection = selection
        autocompleteIndex = 0
        isAutocompleteDismissed = true
        return true
    }

    private func updateSlashPicker(for text: String) {
        guard supportsCommands, !hasActiveCommand else { return }
        guard model.supportsCapability(.slashCommands),
              let context = SlashCommandQuery(text: text, selection: draftSelection)
        else {
            if commandComposer.isPickerPresented {
                commandComposer.dismissPicker()
            }
            return
        }
        let shouldLoad = !commandComposer.hasLoadedCatalogs
            && !commandComposer.isLoading
        // Typing a command's full name and a space selects it, as in Discord.
        if context.query.hasSuffix(" "),
           let command = commandComposer.exactCommand(named: context.query)
        {
            activateCommand(command)
            return
        }
        if !commandComposer.isPickerPresented {
            commandComposer.presentPicker(query: context.query)
        } else {
            commandComposer.updatePickerQuery(context.query)
        }
        if shouldLoad {
            model.loadApplicationCommands(in: conversation)
        }
    }

    private func activateCommand(_ command: ApplicationCommand) {
        if let kind = SakuraCordBuiltInCommands.issueReportKind(for: command) {
            commandComposer.dismissPicker()
            updateDraft("")
            draftSelection = nil
            model.presentIssueReport(kind)
            return
        }
        commandComposer.activate(command)
        cancelReply()
        updateDraft("")
        model.clearComposerAttachments(for: conversation)
        draftSelection = nil
        isFocused = true
        model.refreshApplicationCommandAutocomplete(in: conversation)
    }

    private func cancelCommand() {
        leaveCommand(restoring: "")
    }

    /// Leaves the structured command, continuing with ordinary text. Removing
    /// the command with Backspace restores its name so the picker reopens.
    private func leaveCommand(restoring text: String) {
        commandComposer.cancelActiveCommand()
        model.cancelApplicationCommandAutocompleteTask(in: conversation)
        model.cancelApplicationCommandMemberSearch(in: conversation)
        updateDraft(text)
        draftSelection = NSRange(location: text.utf16.count, length: 0)
        isFocused = true
        updateSlashPicker(for: text)
    }

    private func submitComposer() {
        if isVoiceMessageActive {
            if sendSlotMode == .sendVoice { sendVoiceMessage() }
            return
        }
        if !hasActiveCommand, model.canPresentIssueReport,
           let command = SakuraCordBuiltInCommands.commands.first(where: {
               draft.trimmingCharacters(in: .whitespacesAndNewlines) == "/\($0.name)"
           }), let kind = SakuraCordBuiltInCommands.issueReportKind(for: command)
        {
            commandComposer.dismissPicker()
            updateDraft("")
            draftSelection = nil
            model.presentIssueReport(kind)
            return
        }
        guard allowsSubmission() else { return }
        if hasActiveCommand {
            model.executeApplicationCommand(in: conversation)
        } else {
            send()
        }
    }

    private func acceptCommandSuggestion(_ suggestion: ApplicationCommandSuggestion) {
        let composer = commandComposer
        switch suggestion.action {
        case let .value(value, display):
            composer.resolveFocusedField(value, display: display)
        case .chooseAttachment:
            showFileImporter = true
        case let .addOption(option):
            composer.addOption(option)
        }
        composer.resetSuggestions()
        isFocused = true
    }

    private func handleAutocomplete(_ command: ComposerAutocompleteCommand) -> Bool {
        if hasActiveCommand {
            return handleActiveCommandAutocomplete(command)
        }
        if supportsCommands, commandComposer.isPickerPresented {
            return handleCommandPickerAutocomplete(command)
        }
        if let mentionPicker {
            return handleMentionPickerCommand(command, picker: mentionPicker)
        }
        if let context = mentionAutocompleteContext, !mentionAutocompleteSuggestions.isEmpty {
            return handleMentionAutocomplete(command, context: context)
        }
        guard let context = autocompleteContext, !autocompleteSuggestions.isEmpty else { return false }
        return handleColonAutocomplete(command, context: context)
    }

    /// Keys while a command is active: the panel takes navigation and
    /// acceptance when it lists something, otherwise keys move between fields.
    private func handleActiveCommandAutocomplete(_ command: ComposerAutocompleteCommand) -> Bool {
        let composer = commandComposer
        let content = visibleCommandSuggestionContent
        let suggestions = content?.suggestions ?? []
        let index = composer.suggestionIndex ?? content?.defaultIndex
        let selected = index.flatMap { suggestions.indices.contains($0) ? suggestions[$0] : nil }
        if command == .previous || command == .next { autocompleteKeyboardSelectionRevision &+= 1 }
        switch command {
        case .previous:
            guard !suggestions.isEmpty else { return false }
            composer.suggestionIndex = ((index ?? 0) - 1 + suggestions.count) % suggestions.count
        case .next:
            guard !suggestions.isEmpty else { return false }
            composer.suggestionIndex = index.map { ($0 + 1) % suggestions.count } ?? 0
        case .accept:
            guard let selected else { return false }
            acceptCommandSuggestion(selected)
        case .advance:
            if let selected {
                acceptCommandSuggestion(selected)
            } else if !suggestions.isEmpty {
                composer.suggestionIndex = 0
                autocompleteKeyboardSelectionRevision &+= 1
            } else {
                composer.advanceField()
            }
        case .previousField:
            composer.moveFocus(by: -1)
        case .nextField:
            composer.moveFocus(by: 1)
        case .dismiss:
            // Discord's Escape only closes the list; the command stays.
            composer.areSuggestionsDismissed = true
        case .removeField:
            guard let field = composer.draft?.focusedField else { return false }
            composer.removeField(field.id)
        }
        return true
    }

    private func handleCommandPickerAutocomplete(_ command: ComposerAutocompleteCommand) -> Bool {
        switch command {
        case .previous: commandComposer.movePickerSelection(by: -1)
        case .next: commandComposer.movePickerSelection(by: 1)
        case .accept, .advance:
            guard let selected = commandComposer.selectedPickerCommand else { return true }
            activateCommand(selected)
        case .dismiss: commandComposer.dismissPicker()
        case .previousField, .nextField, .removeField: return true
        }
        return true
    }

    private func handleMentionAutocomplete(
        _ command: ComposerAutocompleteCommand,
        context: MentionAutocompleteContext
    ) -> Bool {
        if command == .previous || command == .next { autocompleteKeyboardSelectionRevision &+= 1 }
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
        if command == .previous || command == .next { autocompleteKeyboardSelectionRevision &+= 1 }
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
        draftSelection = result
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

    private var capturesUnfocusedTyping: Bool {
        conversation == model.activeComposerDestination
            && model.threadCreation?.isSubmitting != true
            && !showEmojiPicker && !showGIFPicker && !showStickerPicker && !isPickingGame
            && !isVoiceMessageActive
    }

    private var commandComposer: ApplicationCommandComposerModel {
        model.commandComposer(for: conversation)
    }

    private var supportsCommands: Bool {
        model.commandContext(for: conversation) != nil
    }

    private var hasActiveCommand: Bool {
        supportsCommands && commandComposer.activeCommand != nil
    }

    private var canAddAttachments: Bool {
        model.isComposerDropEligible(conversation)
            && attachments.count < SendMessageDraft.maximumAttachmentCount
    }

    private var canCreatePoll: Bool {
        activeConversationID.map { model.canCreatePoll(in: $0) } ?? false
    }

    private var canCreateThread: Bool {
        conversation == .channel && model.canCreateThreadInSelectedChannel
    }

    private var hasComposerActions: Bool {
        canAddAttachments || canCreatePoll || canCreateThread || model.translation.settings.isEnabled
    }

    /// The thread pane composes a thread's first message before Discord has
    /// created the thread, so it has no conversation ID, slowmode, or
    /// destination for immediate GIF or sticker sends yet.
    private var isCreatingThread: Bool {
        conversation == .thread && model.threadCreation != nil
    }

    private func allowsSubmission() -> Bool {
        guard let activeConversationID else { return isCreatingThread }
        return model.allowSlowmodeSubmission(in: activeConversationID)
    }

    private var composerPlaceholder: String {
        ComposerPlaceholderPolicy.text(
            channelName: channelName,
            channelKind: model.selectedChannel?.kind,
            destination: conversation,
            startsThread: isCreatingThread
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

private extension ComposerView {
    @ViewBuilder
    private var composerOverlay: some View {
        if isInputActive {
            composerMenus
        }
    }

    /// Composer menus belong to the active editor or game search field. They
    /// hide when the window becomes inactive.
    private var isInputActive: Bool {
        appearsActive && (isFocused || isPickingGame)
    }

    private var composerMentionPresentations: [String: MentionPresentation] {
        _ = model.timelinePresentationRevision
        let values = MessageMentionResolver(model: model).presentations(in: draft)
        guard draftHasRelativeTimestamp else { return values }
        return TimestampMentionPresentation.refreshed(values, source: draft, at: timestampClock.date)
    }

    /// A relative time in the draft counts on, as it will once sent.
    private var draftHasRelativeTimestamp: Bool {
        draft.contains(":R>")
    }

    private var isPickingGame: Bool {
        if case .game = mentionPicker { true } else { false }
    }

    private func acceptMentionAutocomplete(
        _ suggestion: MentionAutocompleteSuggestion,
        context: MentionAutocompleteContext
    ) {
        autocompleteIndex = 0
        isAutocompleteDismissed = true
        switch suggestion.action {
        case .chooseTimeFormat:
            mentionPicker = .time(range: context.range, seconds: Int64(Date.now.timeIntervalSince1970))
        case .chooseGame:
            mentionPicker = .game(range: context.range)
            isFocused = false
        case .insert:
            if let member = suggestion.member { model.rememberMentionMember(member) }
            draftSelection = insertInDraft(suggestion.value + " ", replacing: context.range)
        }
    }

    @ViewBuilder
    private func mentionPickerMenu(_ picker: ComposerMentionPicker) -> some View {
        switch picker {
        case let .time(range, seconds):
            ComposerTimeFormatPicker(
                seconds: seconds,
                selectedIndex: autocompleteIndex,
                select: { insertMentionPickerResult(DiscordTimestampToken(seconds: seconds, style: $0).rawToken, range: range) },
                highlight: { autocompleteIndex = $0 }
            )
        case let .game(range):
            ComposerGameMentionPicker(
                model: model,
                select: { game in
                    model.rememberGameMention(game)
                    insertMentionPickerResult("<@$\(game.id)>", range: range)
                },
                dismiss: dismissMentionPicker
            )
        }
    }

    private func handleMentionPickerCommand(_ command: ComposerAutocompleteCommand, picker: ComposerMentionPicker) -> Bool {
        guard case let .time(range, seconds) = picker else {
            // The game picker's search field handles its own keys.
            if case .dismiss = command { dismissMentionPicker() }
            return true
        }
        let styles = ComposerTimeFormatPicker.styles
        switch command {
        case .previous:
            autocompleteIndex = (autocompleteIndex - 1 + styles.count) % styles.count
        case .next:
            autocompleteIndex = (autocompleteIndex + 1) % styles.count
        case .accept, .advance:
            let token = DiscordTimestampToken(seconds: seconds, style: styles[autocompleteIndex])
            insertMentionPickerResult(token.rawToken, range: range)
        case .dismiss:
            dismissMentionPicker()
        case .previousField, .nextField, .removeField:
            return false
        }
        return true
    }

    private func dismissMentionPicker() {
        mentionPicker = nil
        isAutocompleteDismissed = true
        isFocused = true
    }

    /// Starts a clicked command mention once this conversation's commands
    /// have loaded, asking first before it replaces a written message, as
    /// Discord does. One that is not offered here stays typed.
    private var commandMentionHandling: some View {
        Color.clear
            .onChange(of: commandComposer.mentionedCommand, startMentionedCommand)
            .onChange(of: commandComposer.isLoading, startMentionedCommand)
            .alert("Clear message?", item: $commandAwaitingClear) { command in
                Button("Clear", role: .destructive) {
                    if isVoiceMessageActive { voiceMessage.discard(playback: model.voiceMessagePlayback) }
                    activateCommand(command)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Looks like you’ve already written something. Do you want to clear it and use a command?", bundle: #bundle)
            }
    }

    private func startMentionedCommand() {
        guard let mention = commandComposer.mentionedCommand, !commandComposer.isLoading else { return }
        commandComposer.mentionedCommand = nil
        isFocused = true
        guard let command = commandComposer.command(mentioned: mention) else {
            if draft.isEmpty { updateDraft("/\(mention.name)") }
            return
        }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, attachments.isEmpty,
           !hasActiveCommand, !isVoiceMessageActive {
            activateCommand(command)
        } else {
            commandAwaitingClear = command
        }
    }

    private func insertMentionPickerResult(_ token: String, range: NSRange) {
        mentionPicker = nil
        draftSelection = insertInDraft(token + " ", replacing: range)
        autocompleteIndex = 0
        isAutocompleteDismissed = true
        isFocused = true
    }
}

extension ComposerView {
    private func composerDidDisappear() {
        timestampClock.stop()
        if let channelID = sendTransitionAnchor.channelID,
           channelID == activeConversationID,
           model.guildTimeoutUntil(in: channelID) != nil {
            voiceMessage.preserveForGuildTimeout(in: channelID, playback: model.voiceMessagePlayback)
        } else {
            voiceMessage.discard(playback: model.voiceMessagePlayback)
        }
        composerDropInteraction?.clear(destination: conversation)
        if let channelID = sendTransitionAnchor.channelID {
            model.timelineSendTransitionStore.discard(channelID)
        }
    }

    /// One button morphs between attaching, discarding a recording, and
    /// previewing it.
    func composerLeadingButton(appearance: ComposerBarAppearance) -> some View {
        ComposerActionButton(
            icon: Image(systemName: leadingSymbol),
            help: leadingHelp,
            iconSize: 19,
            iconWeight: .regular,
            showsHoverBackground: appearance == .legacy,
            appearance: appearance,
            action: performLeadingAction
        )
        .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer)))
        .disabled(hasActiveCommand || (!hasComposerActions && !isVoiceMessageActive) || !voiceMessage.canPreview)
        .opacity((hasComposerActions || isVoiceMessageActive) && voiceMessage.canPreview ? 1 : 0.4)
        .animation(.smooth(duration: 0.2), value: voiceMessage.canPreview)
    }

    /// Sits where the composer icons were, tinted like the delete action.
    func voiceMessageDiscardButton(appearance: ComposerBarAppearance) -> some View {
        ComposerActionButton(
            icon: Image(systemName: "trash"),
            help: "Delete voice message",
            iconSize: 19,
            size: appearance.accessoryButtonSize,
            appearance: appearance,
            role: .destructive,
            action: discardVoiceMessage
        )
        .fixedSize()
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    var voiceMessageField: some View {
        ComposerVoiceMessageField(
            state: voiceMessage,
            playback: model.voiceMessagePlayback
        )
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)),
                removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .leading))
            )
        )
    }

    func composerSendSlot(appearance: ComposerBarAppearance) -> some View {
        let deadline = activeConversationID.flatMap { channelID in
            let configuration = model.slowmodeConfiguration(in: channelID)
            return model.composer.slowmode.deadline(
                in: channelID, interval: configuration.interval, immune: configuration.immune
            )
        }
        return TimelineView(ComposerSlowmodeTimelineSchedule(deadline: deadline)) { context in
            let coolingDown = deadline.map { $0 > context.date } ?? false
            ComposerSendSlot(
                mode: sendSlotMode,
                appearance: appearance,
                isSlowmodeBlocked: coolingDown,
                send: sendSlotMode == .sendVoice ? sendVoiceMessage : submitComposer,
                startRecording: startVoiceMessage,
                stopRecording: { voiceMessage.stop() }
            )
            .disabled(sendSlotIsDisabled(coolingDown: coolingDown))
        }
    }

    private var voiceMessage: VoiceMessageComposerState {
        model.voiceMessageComposer(for: conversation)
    }

    private var isVoiceMessageActive: Bool {
        voiceMessage.phase.isActive
    }

    /// Changes only between phases, not with every recording level.
    private var voiceMessagePhaseKey: Int {
        switch voiceMessage.phase {
        case .idle: 0
        case .starting: 1
        case .recording: 2
        case .finishing: 3
        case .recorded: 4
        }
    }

    /// Keeps the mode current while the pane is in place, including when it
    /// returns before leaving finished. A leaving composer also gives up the
    /// keyboard: typing would land in the closed thread's draft.
    private func holdSendSlotMode(_: ComposerSendSlot.Mode?, _ mode: ComposerSendSlot.Mode?) {
        if let mode { showedSendSlotMode = mode } else { isFocused = false }
    }

    /// With nothing to send, the send button records a voice message instead.
    private var showsVoiceMessageButton: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attachments.isEmpty && !hasActiveCommand && !isCreatingThread
            && model.canSendVoiceMessages(in: conversation)
    }

    private var sendSlotMode: ComposerSendSlot.Mode {
        isLeaving ? showedSendSlotMode : liveSendSlotMode
    }

    private var liveSendSlotMode: ComposerSendSlot.Mode {
        switch voiceMessage.phase {
        case .idle: showsVoiceMessageButton ? .voice : .send
        case .starting, .recording, .finishing: .stop
        case .recorded: .sendVoice
        }
    }

    private func sendSlotIsDisabled(coolingDown: Bool) -> Bool {
        switch sendSlotMode {
        case .send: !composerCanSubmit && !coolingDown
        case .voice: false
        case .stop: voiceMessage.phase == .finishing
        case .sendVoice: isSubmitting || coolingDown
        }
    }

    private var leadingSymbol: String {
        switch voiceMessage.phase {
        case .idle: "plus"
        case .starting, .recording, .finishing: "trash"
        case .recorded:
            model.voiceMessagePlayback.phase(of: voiceMessage.playbackID) == .playing ? "pause.fill" : "play.fill"
        }
    }

    private var leadingHelp: String {
        switch voiceMessage.phase {
        case .idle: "Add attachments"
        case .starting, .recording, .finishing: "Delete voice message"
        case .recorded where !voiceMessage.canPreview:
            "Waiting for your headset to switch back from its microphone"
        case .recorded:
            model.voiceMessagePlayback.phase(of: voiceMessage.playbackID) == .playing ? "Pause" : "Play voice message"
        }
    }

    private func performLeadingAction() {
        switch voiceMessage.phase {
        case .idle:
            showComposerActions.toggle()
        case .starting, .recording, .finishing:
            discardVoiceMessage()
        case let .recorded(recording):
            model.voiceMessagePlayback.toggle(
                voiceMessage.playbackID,
                source: .local(recording.fileURL),
                duration: recording.duration
            )
        }
    }

    private func startVoiceMessage() {
        showComposerActions = false
        showEmojiPicker = false
        showGIFPicker = false
        showStickerPicker = false
        voiceMessage.start(inputDeviceID: model.voiceMessageInputDeviceID)
    }

    private func discardVoiceMessage() {
        voiceMessage.discard(playback: model.voiceMessagePlayback)
        isFocused = true
    }

    private func sendVoiceMessage() {
        guard !isSubmitting, allowsSubmission() else { return }
        isSubmitting = true
        Task {
            _ = await model.submitVoiceMessage(from: conversation)
            isSubmitting = false
            isFocused = true
        }
    }
}

private extension ComposerView {
    var draft: String {
        switch conversation {
        case .channel: model.draft
        case .thread: model.threadDraft
        }
    }

    func updateDraft(_ value: String) {
        switch conversation {
        case .channel:
            model.updateDraft(value)
        case .thread:
            model.updateThreadDraft(value)
        }
    }

    var activeReply: Message? {
        switch conversation {
        case .channel: model.replyingTo
        case .thread: model.threadReplyingTo
        }
    }

    var activeReplyMentionsAuthor: Bool {
        switch conversation {
        case .channel: model.replyMentionsAuthor
        case .thread: model.threadReplyMentionsAuthor
        }
    }

    var attachments: [ForumPostAttachment] {
        model.composerAttachments(for: conversation)
    }

    var hasCheckingAttachments: Bool {
        let checking = model.composer.checkingAttachmentIDs
        return !checking.isEmpty && attachments.contains { checking.contains($0.id) }
    }

    static var headerTransition: AnyTransition {
        AnyTransition(.blurReplace).combined(with: .offset(y: InterfaceScale.metric(14)))
    }

    var chromeKey: ComposerChromeKey {
        ComposerChromeKey(
            conversationID: activeConversationID,
            attachmentIDs: hasActiveCommand ? [] : attachments.map(\.id),
            replyID: hasActiveCommand ? nil : activeReply?.id,
            hasActiveCommand: hasActiveCommand,
            hasTranslationHeader: model.draftTranslation(for: conversation) != nil
        )
    }

    var animatesChromeResize: Bool {
        !reduceMotion && !model.accessibilitySettings.disablesAllAnimations && !isClearingForSend
    }

    /// The timeline animates a sent message out of the field, as a bubble or
    /// as plain text; it consumes this when the optimistic row arrives.
    func registerSendTransition(
        channelID: ChannelID,
        attachments: [ForumPostAttachment]
    ) {
        // A send from older history first loads the newest messages, so
        // the field stays editable and nothing arrives to take it over yet.
        guard model.animatesMessageSending,
              conversation == .thread ? !model.isThreadWindowAwayFromNewest : !model.hasMoreLaterMessages,
              let source = sendTransitionAnchor.source(
                  channelID: channelID,
                  content: draft.trimmingCharacters(in: .whitespacesAndNewlines),
                  attachments: attachments
              )
        else { return }
        model.timelineSendTransitionStore.register(source)
        holdsPlaceholderForSendTransition = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            holdsPlaceholderForSendTransition = false
        }
    }
}

private struct ComposerActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            configuration.icon.frame(width: InterfaceScale.metric(20), alignment: .center)
            configuration.title
        }
    }
}

private extension ComposerView {
    /// A pane reused from the pool left the window still marked focused, so
    /// focusing it again would change nothing.
    func clearFocusOfReusedPane() async {
        guard columnPresentation != focusedColumnPresentation else { return }
        focusedColumnPresentation = columnPresentation
        isFocused = false
        await Task.yield()
    }
}
