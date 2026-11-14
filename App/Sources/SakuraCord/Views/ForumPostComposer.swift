import SakuraCordModels
import SwiftUI
import UniformTypeIdentifiers

/// Presents the forum post composer as a window modal over the selected forum.
struct ForumPostComposerPresentationModifier: ViewModifier {
    let model: AppModel
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.windowModal(item: Binding(
            get: { isPresented ? model.selectedChannel.flatMap { $0.kind == .forum ? $0 : nil } : nil },
            set: { if $0 == nil { isPresented = false } }
        ), cornerRadius: InterfaceScale.metric(32), cornerStyle: .circular) { channel in
            ForumPostComposer(model: model, channel: channel)
        }
    }
}

/// Why a post can't be sent yet, said once its Post is pressed.
private enum ForumPostProblem: Equatable {
    case missingTitle, titleTooLong, missingContent, contentTooLong, missingTag, checkingFiles

    /// The part of the composer the problem is in, which shakes.
    var field: ForumPostField? {
        switch self {
        case .missingTitle, .titleTooLong: .title
        case .missingContent, .contentTooLong: .content
        case .missingTag: .tags
        case .checkingFiles: nil
        }
    }

    var message: LocalizedStringResource {
        switch self {
        case .missingTitle: "Give your post a title."
        case .titleTooLong: "Titles can be up to 100 characters."
        case .missingContent: "Write something or attach a file."
        case .contentTooLong: "Your post is too long."
        case .missingTag: "This forum needs a tag on every post."
        case .checkingFiles: "Your files are still being checked."
        }
    }
}

/// Rows sit inside the 32-point panel as the poll creator's do; the footer's
/// 12-point inset keeps its capsules concentric with the panel.
struct ForumPostComposer: View {
    static let titleLimit = 100
    static let tagLimit = 5

    let model: AppModel
    let channel: Channel
    @Environment(\.windowModalContext) private var modal
    /// One entry per access started, so the same file attached twice stays
    /// open until both are removed.
    @State private var securityScopedAttachmentURLs: [URL] = []
    @State private var isSubmitting = false
    @State private var submitTask: Task<Void, Never>?
    @State private var problem: ForumPostProblem?
    @State private var shakes: [ForumPostField: Int] = [:]
    @State private var showsFileImporter = false
    @State private var showsGuidelines = false
    @State private var showsEmojiPicker = false
    @State private var emojiPickerDismissedAt: Date?
    @State private var contentSelection: NSRange?
    @State private var selectionBeforeEmojiPicker: NSRange?
    @State private var isContentFocused = false
    @State private var isDropTargeted = false
    @State private var sendTransitionAnchor = ComposerSendTransitionAnchor()
    @State private var isTitleFocused = false

    /// Forum posts keep the standard limit, which the provider enforces for
    /// every account.
    private static let limitPremiumType: Int? = nil

    init(model: AppModel, channel: Channel) {
        self.model = model
        self.channel = channel
    }

    var body: some View {
        VStack(spacing: 0) {
            titleField
            Divider()
            bodyField
            if !attachments.isEmpty {
                VStack(spacing: 0) {
                    Divider().padding(.horizontal, InterfaceScale.metric(18))
                    attachmentTray
                }
                .transition(ComposerResizeMotion.headerTransition)
            }
            if !channel.availableTags.isEmpty {
                Divider().padding(.horizontal, InterfaceScale.metric(18))
                tagRow
            }
            status
            Divider()
            footer
        }
        .clipped()
        .animation(motion(ComposerResizeMotion.animation), value: attachments.map(\.id))
        .animation(motion(.snappy(duration: 0.2)), value: statusKey)
        .overlay { dropHighlight }
        .windowModalSize(width: 680, height: 600)
        .dropDestination(for: URL.self) { urls, _ in
            guard model.canAttachFilesToForumPosts else { return false }
            addAttachments(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 && model.canAttachFilesToForumPosts }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { addAttachments(urls) }
        }
        .windowModalDismissDisabled(isSubmitting)
        .task {
            // Files kept with the draft are opened again, as when attached.
            openSecurityScopes(attachments.map(\.url))
            await Task.yield()
            if draft.title.isEmpty { isTitleFocused = true } else { isContentFocused = true }
            let pending = attachments.filter { draft.checkingAttachmentIDs.contains($0.id) }
            if !pending.isEmpty { await checkAttachments(pending) }
        }
        .onChange(of: draft) { problem = nil }
        .onAppear { modal?.escapeAction = handleEscape }
        .onDisappear(perform: releaseAttachments)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New post in \(channel.name)")
    }

    // MARK: Fields

    private var titleField: some View {
        HStack(alignment: .firstTextBaseline, spacing: InterfaceScale.metric(11)) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.interfaceSystem(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .help(channel.name)
                .accessibilityHidden(true)
            ForumPostTitleField(
                text: draftBinding(\.title),
                isFocused: $isTitleFocused,
                canReceiveAttachments: { model.canAttachFilesToForumPosts },
                receiveAttachments: receiveAttachments,
                submit: { isContentFocused = true }
            )
            if draft.title.count > Self.titleLimit - 20 {
                Text("\(draft.title.count)/\(Self.titleLimit)")
                    .font(.interface(.caption)).monospacedDigit()
                    .foregroundStyle(draft.title.count > Self.titleLimit ? .red : .secondary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, InterfaceScale.metric(18)).padding(.vertical, InterfaceScale.metric(17))
        .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(58), alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { isTitleFocused = true }
        .modifier(ForumPostRejectionShake(trigger: shakes[.title, default: 0]))
    }

    private var bodyField: some View {
        // The text scrolls within the space left to it rather than growing
        // past the panel.
        GeometryReader { proxy in
            ForumPostBodyEditor(
                model: model,
                text: draftBinding(\.content),
                selection: $contentSelection,
                isFocused: $isContentFocused,
                maximumHeight: proxy.size.height,
                submit: submit,
                receiveAttachments: receiveAttachments,
                dropTargetChanged: { isDropTargeted = $0 && model.canAttachFilesToForumPosts }
            )
        }
        .padding(.horizontal, InterfaceScale.metric(18))
        .padding(.vertical, InterfaceScale.metric(14))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            if ChatCharacterLimitPolicy.shouldShowCounter(characterCount: draft.content.count, premiumType: Self.limitPremiumType) {
                ComposerCharacterCounter(characterCount: draft.content.count, premiumType: Self.limitPremiumType)
                    .padding(InterfaceScale.metric(10))
                    .transition(.opacity)
            }
        }
        .modifier(ForumPostRejectionShake(trigger: shakes[.content, default: 0]))
    }

    private var attachmentTray: some View {
        ComposerAttachmentTray(
            attachments: attachments,
            checkingIDs: draft.checkingAttachmentIDs,
            uploads: model.attachmentUploads,
            sendTransitionAnchor: sendTransitionAnchor,
            mediaViewerSourceID: {
                model.mediaViewerPresentation?.uncoveredSourceItemID(showing: model.mediaViewerSelectedItemID)
            },
            scrolled: {
                guard let link = model.mediaViewerPresentation?.transitionLink else { return }
                sendTransitionAnchor.followMediaViewerSources(in: link)
            },
            open: openAttachment,
            toggleSpoiler: { id in updateAttachment(id) { $0.isSpoiler.toggle() } },
            update: { attachment in updateAttachment(attachment.id) { $0 = attachment } },
            remove: { removeAttachments([$0]) }
        )
        .padding(.horizontal, InterfaceScale.metric(8))
    }

    private var tagRow: some View {
        HStack(spacing: InterfaceScale.metric(10)) {
            Image(systemName: "tag")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: InterfaceScale.metric(7)) {
                    HStack(spacing: InterfaceScale.metric(7)) {
                        ForEach(channel.availableTags) { tag in
                            ForumTagButton(
                                tag: tag,
                                customEmojiURL: tag.emojiID.flatMap { model.customEmojiURLsByID[$0] },
                                isSelected: draft.tagIDs.contains(tag.id)
                            ) { toggleTag(tag) }
                            .disabled(!draft.tagIDs.contains(tag.id) && !canAdd(tag))
                        }
                    }
                    .padding(.vertical, InterfaceScale.metric(2))
                }
            }
            .scrollIndicators(.hidden)
            if channel.requiresForumTag {
                Text("Required")
                    .font(.interface(.caption).weight(.semibold))
                    .foregroundStyle(problem == .missingTag ? .red : .secondary)
            }
        }
        .padding(.horizontal, InterfaceScale.metric(18))
        .padding(.vertical, InterfaceScale.metric(10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tags")
        .modifier(ForumPostRejectionShake(trigger: shakes[.tags, default: 0]))
    }

    // MARK: Status and footer

    private var statusKey: String? {
        if let problem { return "\(problem)" }
        return model.forumActionError ?? model.forumCreateProgress.map { "\($0)" }
    }

    @ViewBuilder private var status: some View {
        if let progress = model.forumCreateProgress {
            UploadProgressView(progress: progress)
                .padding(.horizontal, InterfaceScale.metric(18))
                .padding(.bottom, InterfaceScale.metric(10))
                .transition(.opacity)
        } else if let message = problem.map({ String(localized: $0.message) }) ?? model.forumActionError {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.interface(.callout))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, InterfaceScale.metric(18))
                .padding(.bottom, InterfaceScale.metric(10))
                .transition(.opacity)
        }
    }

    private var footer: some View {
        HStack(spacing: InterfaceScale.metric(4)) {
            ComposerActionButton(icon: Image(systemName: "plus"), help: "Add attachments", iconSize: 19, iconWeight: .regular) {
                showsFileImporter = true
            }
            .disabled(!model.canAttachFilesToForumPosts || attachments.count >= SendMessageDraft.maximumAttachmentCount)
            ComposerActionButton(icon: SakuraCordSystemSymbol.emojiFaceGrinningImage, help: "Choose emoji", iconSize: 19, action: toggleEmojiPicker)
                .background { emojiPicker }
            if let topic = channel.topic, !topic.isEmpty {
                ComposerActionButton(icon: Image(systemName: "checklist"), help: "Posting guidelines", iconSize: 18) { showsGuidelines.toggle() }
                    .escapeDismissiblePopover(isPresented: $showsGuidelines, arrowEdge: .top) { guidelines(topic) }
            }
            Spacer(minLength: InterfaceScale.metric(16))
            ModalGlassButton(symbol: "xmark", label: "Cancel") { modal?() }
                .disabled(isSubmitting)
            ModalGlassButton(symbol: "paperplane", label: "Post", primary: true, isLoading: isSubmitting, action: submit)
                .disabled(isSubmitting || draft.isEmpty || model.guildTimeoutUntil(in: channel.id) != nil)
                .keyboardShortcut(.return, modifiers: .command)
                .modifier(ForumPostRejectionShake(trigger: shakes[.post, default: 0]))
                .padding(.leading, InterfaceScale.metric(4))
        }
        .padding(InterfaceScale.metric(12))
    }

    private var emojiPicker: some View {
        StableReactionPickerPresenter(
            isPresented: $showsEmojiPicker,
            preferredEdge: .maxY,
            accessibilityIdentifier: "forum-post-emoji-picker"
        ) {
            EmojiPickerView(
                model: model,
                allowsPersistentSelection: true,
                dismiss: { showsEmojiPicker = false },
                select: insertEmoji
            )
        }
        .onChange(of: showsEmojiPicker) { _, isShown in
            if !isShown { emojiPickerDismissedAt = .now }
        }
    }

    private func guidelines(_ topic: String) -> some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(10)) {
            Text("Posting Guidelines").font(.interface(.headline))
            ScrollView {
                CustomEmojiRichText(
                    model: model,
                    content: topic,
                    emojiSize: InterfaceScale.metric(20),
                    baseFontSize: InterfaceScale.fontSize(14),
                    isSelectable: true,
                    foregroundColor: .labelColor,
                    mentionPresentation: { MessageMentionResolver(model: model, message: nil).presentation($0) }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: InterfaceScale.metric(320))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(InterfaceScale.metric(16))
        .frame(width: InterfaceScale.metric(380))
    }

    @ViewBuilder private var dropHighlight: some View {
        if isDropTargeted {
            ConcentricRectangle(cornerRadius: InterfaceScale.metric(24))
                .stroke(SakuraCordAccentColor.color, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .background(SakuraCordAccentColor.color.opacity(0.08), in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(24)))
                .overlay {
                    Label("Drop to attach", systemImage: "paperclip")
                        .font(.interface(.headline))
                        .padding(.horizontal, InterfaceScale.metric(16))
                        .frame(height: InterfaceScale.metric(40))
                        .glassEffect(.regular, in: Capsule())
                }
                .padding(InterfaceScale.metric(8))
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func motion(_ animation: Animation) -> Animation? {
        ComposerResizeMotion.isReduced ? nil : animation
    }
}

// MARK: Actions

private extension ForumPostComposer {
    var currentProblem: ForumPostProblem? {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return .missingTitle }
        if title.count > Self.titleLimit { return .titleTooLong }
        if draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, attachments.isEmpty { return .missingContent }
        if !ChatCharacterLimitPolicy.isWithinLimit(characterCount: draft.content.count, premiumType: Self.limitPremiumType) {
            return .contentTooLong
        }
        if channel.requiresForumTag, appliedTagIDs.isEmpty { return .missingTag }
        if !draft.checkingAttachmentIDs.isEmpty { return .checkingFiles }
        return nil
    }

    /// The draft's tags that the forum still offers. One deleted since the
    /// draft was saved can't be seen or removed, so it neither counts toward
    /// the limit nor is sent.
    var appliedTagIDs: [ForumTagID] {
        channel.availableTags.map(\.id).filter(draft.tagIDs.contains)
    }

    func submit() {
        guard !isSubmitting, model.guildTimeoutUntil(in: channel.id) == nil else { return }
        if let currentProblem {
            problem = currentProblem
            shakes[.post, default: 0] += 1
            if let field = currentProblem.field { shakes[field, default: 0] += 1 }
            switch currentProblem.field {
            case .title: isTitleFocused = true
            case .content: isContentFocused = true
            default: break
            }
            return
        }
        isSubmitting = true
        // Pasted files stay while the post reads them, even if removed meanwhile.
        let sentURLs = attachments.map(\.url)
        model.beginUsingOwnedPromisedFiles(sentURLs)
        submitTask = Task {
            defer { model.endUsingOwnedPromisedFiles(sentURLs) }
            let didCreate = await model.createForumPost(
                CreateForumPostDraft(
                    channelID: channel.id,
                    title: draft.title,
                    content: draft.content,
                    attachments: attachments,
                    appliedTagIDs: appliedTagIDs,
                    autoArchiveDuration: channel.defaultAutoArchiveDuration ?? 4_320
                )
            )
            // Cleared even if the composer closed meanwhile.
            if didCreate { draft = ForumPostComposerDraft() }
            guard !Task.isCancelled else { return }
            isSubmitting = false
            submitTask = nil
            if didCreate { modal?(allowsDisabled: true) }
        }
    }

    /// Adding is gated; a selected tag can always be removed, even one made
    /// moderator-only since the draft was saved.
    func canAdd(_ tag: ForumTag) -> Bool {
        (!tag.isModerated || model.canManageForumPosts) && appliedTagIDs.count < Self.tagLimit
    }

    func toggleTag(_ tag: ForumTag) {
        if draft.tagIDs.contains(tag.id) {
            draft.tagIDs.remove(tag.id)
        } else if canAdd(tag) {
            draft.tagIDs = Set(appliedTagIDs + [tag.id])
        }
    }

    func toggleEmojiPicker() {
        // The click that dismissed the picker shouldn't reopen it.
        if let emojiPickerDismissedAt, Date.now.timeIntervalSince(emojiPickerDismissedAt) < 0.25 { return }
        selectionBeforeEmojiPicker = contentSelection
        showsEmojiPicker.toggle()
    }

    func insertEmoji(_ activation: EmojiPickerActivation) {
        let insertedText: String
        switch activation.selection {
        case let .native(value):
            insertedText = value
        case let .custom(emoji):
            ComposerEmojiImageStore.shared.register(emoji)
            insertedText = model.composerText(for: emoji)
        }
        let edit = ComposerDraftEditing.insert(insertedText, into: draft.content, replacing: selectionBeforeEmojiPicker ?? contentSelection)
        draft.content = edit.text
        contentSelection = edit.selection
        selectionBeforeEmojiPicker = edit.selection
        isContentFocused = true
        if !activation.keepsPickerPresented { showsEmojiPicker = false }
    }

    // MARK: Attachments

    /// The draft lives in the model, so a file check that ends after the
    /// composer closed or reopened still updates what it shows.
    var draft: ForumPostComposerDraft {
        get { model.forumPostDrafts[channel.id] ?? ForumPostComposerDraft() }
        // Only a blank draft is dropped; one holding just spaces stays, so
        // typing a space first doesn't undo itself.
        nonmutating set { model.forumPostDrafts[channel.id] = newValue == ForumPostComposerDraft() ? nil : newValue }
    }

    func draftBinding<Value>(_ keyPath: WritableKeyPath<ForumPostComposerDraft, Value>) -> Binding<Value> {
        Binding { draft[keyPath: keyPath] } set: { draft[keyPath: keyPath] = $0 }
    }

    var attachments: [ForumPostAttachment] { draft.attachments }

    /// Pasted data is held by the model, which deletes it once no draft or
    /// post uses it.
    func receiveAttachments(_ incoming: ComposerIncomingAttachments) {
        switch incoming {
        case let .external(urls): addAttachments(urls)
        case let .owned(batch): addAttachments(model.adoptPromisedFileBatch(batch))
        }
    }

    /// Files show at once and are checked behind their tiles, as in the
    /// message composer; any over Discord's size limit leave again.
    func addAttachments(_ urls: [URL]) {
        let urls = model.uploadableFileURLs(urls)
        guard !urls.isEmpty, model.attachmentBatchFits(urls.count, besides: attachments.count) else {
            model.pruneOwnedPromisedAttachmentFiles()
            return
        }
        openSecurityScopes(urls)
        let staged = urls.map {
            ForumPostAttachment(url: $0).applyingFilenamePrivacy(model.privacySafetySettings.anonymisesFileNames)
        }
        draft.attachments.append(contentsOf: staged)
        draft.checkingAttachmentIDs.formUnion(staged.map(\.id))
        Task { await checkAttachments(staged) }
    }

    /// Removes any of `staged` over Discord's size limit. The check gives up
    /// if the selected conversation changes or the composer closes first;
    /// the files then stay pending and are checked when it next appears.
    func checkAttachments(_ staged: [ForumPostAttachment]) async {
        guard let allowedURLs = await model.checkedAttachmentURLsWithinDiscordLimit(staged.map(\.url)).map(Set.init) else { return }
        draft.checkingAttachmentIDs.subtract(staged.map(\.id))
        removeAttachments(Set(staged.filter { !allowedURLs.contains($0.url) }.map(\.id)))
    }

    func updateAttachment(_ id: UUID, _ change: (inout ForumPostAttachment) -> Void) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        change(&draft.attachments[index])
    }

    func removeAttachments(_ ids: Set<UUID>) {
        var updated = draft
        let removed = updated.attachments.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        updated.attachments.removeAll { ids.contains($0.id) }
        updated.checkingAttachmentIDs.subtract(ids)
        draft = updated
        for url in removed.map(\.url) {
            if let scoped = securityScopedAttachmentURLs.firstIndex(of: url) {
                securityScopedAttachmentURLs.remove(at: scoped).stopAccessingSecurityScopedResource()
            }
        }
        // Pasted files no draft holds any more are deleted.
        model.pruneOwnedPromisedAttachmentFiles()
    }

    func openSecurityScopes(_ urls: [URL]) {
        for url in urls where url.startAccessingSecurityScopedResource() {
            securityScopedAttachmentURLs.append(url)
        }
    }

    func openAttachment(_ id: UUID) {
        model.openComposerAttachment(id, in: attachments, from: sendTransitionAnchor)
    }

    /// As in the message composer, Escape first drops the staged files, then
    /// closes the composer.
    func handleEscape() {
        if attachments.isEmpty || isSubmitting {
            modal?()
        } else {
            removeAttachments(Set(attachments.map(\.id)))
        }
    }

    func releaseAttachments() {
        submitTask?.cancel()
        submitTask = nil
        for url in securityScopedAttachmentURLs { url.stopAccessingSecurityScopedResource() }
        securityScopedAttachmentURLs.removeAll()
    }
}

private enum ForumPostField { case title, content, tags, post }

/// Nudges a field side to side when Post is pressed while it's the reason
/// the post can't be sent, as the composer does for slowmode.
private struct ForumPostRejectionShake: ViewModifier {
    let trigger: Int

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: CGFloat.zero, trigger: ComposerResizeMotion.isReduced ? 0 : trigger) { content, offset in
            content.offset(x: offset)
        } keyframes: { _ in
            LinearKeyframe(-5, duration: 0.04)
            LinearKeyframe(5, duration: 0.06)
            LinearKeyframe(-3, duration: 0.06)
            LinearKeyframe(3, duration: 0.06)
            LinearKeyframe(0, duration: 0.04)
        }
    }
}
