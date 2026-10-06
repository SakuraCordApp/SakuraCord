import MessageRendering
import SakuraCordModels
import SwiftUI
import UniformTypeIdentifiers

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

    var body: some View {
        @Bindable var model = model
        let appearance = model.appearanceSettings.composerBarAppearance
        let accessoryButtonSize = appearance.accessoryButtonSize
        let chrome = ComposerChromeLayout(
            appearance: appearance,
            focus: { isFocused = true },
            header: {
                VStack(alignment: .leading, spacing: 0) {
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
                    if hasActiveCommand, let commandDraft = commandComposer.draft {
                        ApplicationCommandComposerBadge(command: commandDraft.command, cancel: cancelCommand)
                    } else if !isCreatingThread {
                        ComposerAttachmentButton(appearance: appearance) {
                            showComposerActions.toggle()
                        }
                        .disabled(hasActiveCommand || !hasComposerActions)
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
                            }
                            .labelStyle(ComposerActionLabelStyle())
                            .buttonStyle(PopoverRowButtonStyle()).padding(6).frame(width: 200)
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
                                onCompositionStateChange: { isComposing = $0 },
                                capturesUnfocusedTyping: capturesUnfocusedTyping,
                                verticalContentInset: appearance == .defaultStyle
                                    ? ChatChromeMetrics.composerTextVerticalInset
                                    : 0,
                                selection: $draftSelection,
                                isFocused: Binding(
                                    get: { !hasActiveCommand && isFocused },
                                    set: { if !hasActiveCommand { isFocused = $0 } }
                                )
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
                    Group {
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
                    }
                }
                .frame(height: ChatChromeMetrics.composerControlHeight)
                .disabled(hasActiveCommand)
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
        .windowModal(isPresented: $showPollCreator, cornerRadius: 32, cornerStyle: .circular) {
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
        return "\(conversation):\(conversationID):\(model.isVoiceChatOpen)"
    }

    private var commandPanelCornerRadius: CGFloat {
        model.appearanceSettings.composerBarAppearance == .legacy
            ? ChatChromeMetrics.composerMinimumCornerRadius : ChatChromeMetrics.composerCornerRadius
    }

    /// Composer menus belong to the active input, like Discord's: they hide
    /// when the editor loses focus or the window becomes inactive, and return
    /// unchanged with focus.
    private var isInputActive: Bool {
        isFocused && appearsActive
    }

    @ViewBuilder
    private var composerOverlay: some View {
        if isInputActive {
            composerMenus
        }
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
            VStack(spacing: 6) {
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
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
        else { return }
        isSubmitting = true
        draftSelection = nil
        selectionBeforeEmojiPicker = nil
        let staged = attachments
        let conversationID = activeConversationID
        let keepsCreationDraft = isCreatingThread
        model.beginUsingOwnedPromisedFiles(staged.map(\.url))
        if !keepsCreationDraft {
            model.clearComposerAttachments(for: conversation)
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
            if !keepsCreationDraft, !result.consumedComposer, activeConversationID == conversationID {
                model.restoreComposerAttachments(staged, to: conversation)
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

    private var capturesUnfocusedTyping: Bool {
        conversation == (model.hasThreadPane ? .thread : .channel)
            && model.threadCreation?.isSubmitting != true
            && !showEmojiPicker && !showGIFPicker && !showStickerPicker
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
        canAddAttachments || canCreatePoll || canCreateThread
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

private struct ComposerActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.frame(width: 20, alignment: .center)
            configuration.title
        }
    }
}
