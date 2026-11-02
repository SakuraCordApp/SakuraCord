import DiscordProtocol
import AppKit
import Foundation
import MediaPipeline
@testable import SakuraCord
import SakuraCordModels
import SakuraCordPersistence
import Testing

@MainActor
@Test func `Return never sends while composing or when the setting asks for a newline`() {
    // Input-method composition must not submit a half-typed message.
    #expect(ComposerReturnAction.decide(
        sendWithReturn: true, shift: false, command: false, hasMarkedText: true
    ) == .inputMethod)
    #expect(ComposerReturnAction.decide(
        sendWithReturn: false, shift: false, command: true, hasMarkedText: true
    ) == .inputMethod)
    #expect(MessageEditInputPolicy.returnAction(
        shift: false, command: false, hasMarkedText: true
    ) == .inputMethod)
    // Plain Return with send-with-Return off, or Shift+Return, must not send.
    #expect(ComposerReturnAction.decide(
        sendWithReturn: false, shift: false, command: false, hasMarkedText: false
    ) == .newline)
    #expect(ComposerReturnAction.decide(
        sendWithReturn: true, shift: true, command: false, hasMarkedText: false
    ) == .newline)
}

@MainActor
@Test func `staged attachments are cleared on navigation so they cannot be sent to another channel`() async {
    let model = AppModel(launchMode: .offlineTesting, provider: TypingTestProvider())
    await model.start()
    #expect(await model.addComposerAttachments([URL(fileURLWithPath: "/tmp/sakuracord-composer-0")], to: .channel))
    #expect(!model.channelComposerAttachments.isEmpty)
    model.selectedChannelID = ChannelID(rawValue: 12)
    #expect(model.channelComposerAttachments.isEmpty)
}

@MainActor
@Test(arguments: [true, false])
func `account or thread draft replacement invalidates an external upload result`(resetsAccount: Bool) async throws {
    let uploader = SequencedAttachmentUploadTestUploader()
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: TypingTestProvider(),
        externalAttachmentUploader: uploader,
        attachmentSettingsStore: AttachmentSettingsStore(preferences: SettingsPreferenceStore(defaults: InMemoryPreferences()))
    )
    await model.start()
    let channelID = try #require(model.selectedChannelID)
    let destination: MessageComposerDestination = resetsAccount ? .channel : .thread
    if !resetsAccount {
        model.sideConversations.thread = .threadCreation(ThreadCreationDraft(parentID: channelID,
                                                                             permissions: .init(canCreatePublic: true, canCreatePrivate: false)))
    }
    let prompt = OversizedAttachmentPrompt(
        fileURL: URL(fileURLWithPath: "/tmp/account-reset.bin"),
        fileSize: DiscordAttachmentUploadPolicy.baseLimit + 1,
        discordLimit: DiscordAttachmentUploadPolicy.baseLimit,
        premiumType: 0,
        destination: destination,
        context: try #require(model.attachmentComposerContext(for: destination))
    )
    model.oversizedAttachmentPrompt = prompt
    model.uploadOversizedAttachment(prompt, using: .catbox)
    #expect(await eventually { await uploader.callCount == 1 })

    if resetsAccount {
        await model.resetAccountScopedLoadsAndForumState()
    } else {
        model.closeThread()
        model.sideConversations.thread = .threadCreation(ThreadCreationDraft(parentID: channelID,
                                                                             permissions: .init(canCreatePublic: true, canCreatePrivate: false)))
    }
    await uploader.release(
        call: 1,
        with: URL(string: "https://files.catbox.moe/stale.bin")!
    )
    #expect(await eventually { model.externalAttachmentUploadTask == nil })
    #expect(model.externalAttachmentUploadPresentation == nil)
    #expect(model.draft.isEmpty)
    #expect(model.threadDraft.isEmpty)
}

@MainActor
@Test(arguments: AttachmentHandlingPolicy.allCases, [false, true])
func `oversized files reach an external host only when the upload policy allows`(external: AttachmentHandlingPolicy, compacts: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("oversized.bin")
    try createSparseFile(file, size: DiscordAttachmentUploadPolicy.baseLimit + 1)
    let worker = AttachmentCompactionTestWorker(outputSize: DiscordAttachmentUploadPolicy.baseLimit + 1)
    let uploader = AttachmentUploadTestUploader(result: URL(string: "https://litter.catbox.moe/test.png")!)
    let model = AppModel(launchMode: .offlineTesting, provider: TypingTestProvider(),
                         externalAttachmentUploader: uploader, attachmentCompactor: worker,
                         attachmentSettingsStore: AttachmentSettingsStore(preferences: SettingsPreferenceStore(defaults: InMemoryPreferences())))
    await model.start()
    model.snapshot?.currentUser.premiumType = 0
    model.attachmentSettings.compactionPolicy = compacts ? .always : .never
    model.attachmentSettings.externalUploadPolicy = external
    #expect(await model.addComposerAttachments([file], to: .channel))
    await model.attachmentCompactionTask?.value
    #expect(await worker.calls == (compacts ? 1 : 0))
    #expect(model.channelComposerAttachments.isEmpty)
    switch external {
    case .ask:
        #expect(try #require(model.oversizedAttachmentPrompt).stage == .externalUpload)
        #expect(await uploader.callCount == 0)
    case .always:
        await model.externalAttachmentUploadTask?.value
        #expect(await uploader.callCount == 1)
        #expect(model.draft == "https://litter.catbox.moe/test.png")
    case .never:
        #expect(await uploader.callCount == 0)
        #expect(model.oversizedAttachmentPrompt == nil)
    }
}

@MainActor
@Test func `compaction leaves the original file intact and skips files within the account limit`() async throws {
    let directory = try ComposerPromisedFileStorage.makeReceivingDirectory()
    defer { ComposerPromisedFileStorage.removeDirectory(directory) }
    let exact = directory.appendingPathComponent("exact.bin")
    let oversized = directory.appendingPathComponent("oversized.bin")
    try createSparseFile(exact, size: DiscordAttachmentUploadPolicy.baseLimit)
    try createSparseFile(oversized, size: DiscordAttachmentUploadPolicy.baseLimit + 1)
    let worker = AttachmentCompactionTestWorker(outputSize: DiscordAttachmentUploadPolicy.baseLimit)
    let uploader = AttachmentUploadTestUploader(result: URL(string: "https://litter.catbox.moe/unused.png")!)
    let model = AppModel(launchMode: .offlineTesting, provider: TypingTestProvider(),
                         externalAttachmentUploader: uploader, attachmentCompactor: worker,
                         attachmentSettingsStore: AttachmentSettingsStore(preferences: SettingsPreferenceStore(defaults: InMemoryPreferences())))
    await model.start()
    model.snapshot?.currentUser.premiumType = 0
    model.attachmentSettings.compactionPolicy = .always
    model.attachmentSettings.externalUploadPolicy = .always
    #expect(await model.addPromisedComposerAttachments(.init(directory: directory, urls: [exact, oversized]), to: .channel))
    await model.attachmentCompactionTask?.value
    #expect(await worker.calls == 1)
    #expect(await uploader.callCount == 0)
    #expect(model.channelComposerAttachments.count == 2)
    #expect(model.channelComposerAttachments.first?.url == exact)
    let compacted = try #require(model.channelComposerAttachments.last?.url)
    #expect(compacted != oversized)
    #expect(model.attachmentFileSize(at: oversized) == DiscordAttachmentUploadPolicy.baseLimit + 1)
    model.clearComposerAttachments(for: .channel)
    #expect(!FileManager.default.fileExists(atPath: compacted.path))
}

private actor AttachmentCompactionTestWorker: AttachmentCompacting {
    let outputSize: Int64
    var calls = 0
    init(outputSize: Int64) { self.outputSize = outputSize }
    func compact(_ source: URL, in directory: URL, options: AttachmentCompactionOptions) async throws -> URL {
        calls += 1
        let output = directory.appendingPathComponent("compacted.bin")
        try createSparseFile(output, size: outputSize)
        return output
    }
}

@MainActor
@Test func `composer paste of a file attaches it instead of inserting its local path`() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sakuracord-paste-file-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("notes.txt")
    try Data("pasted file".utf8).write(to: file)

    let pasteboard = NSPasteboard(name: .init("sakuracord-paste-file-\(UUID().uuidString)"))
    defer { pasteboard.clearContents() }
    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([file as NSURL]))
    #expect(pasteboard.setString(file.path, forType: .string))

    let textView = ComposerNSTextView()
    var received: [ComposerIncomingAttachments] = []
    textView.onReceiveAttachments = { attachments, _ in
        received.append(attachments)
        return true
    }
    textView.canReceiveAttachments = { true }
    #expect(textView.readSelection(from: pasteboard))
    guard case let .external(urls) = try #require(received.first) else {
        Issue.record("Expected the pasted file to stay in place")
        return
    }
    #expect(urls == [file])
    #expect(textView.string.isEmpty)
}

@MainActor
@Test func `managed pasted files cannot escape their batch directory`() throws {
    #expect(ComposerPromisedFileStorage.makeBatch(writing: Data("x".utf8), named: "../escaped.png") == nil)
    let batch = try #require(ComposerPromisedFileStorage.makeBatch(writing: Data("x".utf8), named: "safe.png"))
    defer { batch.discard() }
    #expect(batch.urls.map { $0.deletingLastPathComponent().standardizedFileURL } == [batch.directory.standardizedFileURL])
}

@MainActor
@Test func `instant attachment upload preserves the current draft and staged files`() async {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let staged = URL(fileURLWithPath: "/tmp/sakuracord-staged")
    let instant = URL(fileURLWithPath: "/tmp/sakuracord-instant")
    model.updateDraft("keep editing this")
    await model.addComposerAttachments([staged], to: .channel)

    #expect(await model.sendAttachmentsImmediately([ForumPostAttachment(url: instant)], to: .channel))
    #expect(model.draft == "keep editing this")
    #expect(model.channelComposerAttachments.map(\.url) == [staged])
    #expect(model.messages.last?.attachments.map(\.url) == [instant])
    #expect(await provider.sendCount == 1)
}

@MainActor
@Test func `editing a staged attachment keeps its anonymised filename`() async throws {
    let store = PrivacySafetySettingsStore(preferences: SettingsPreferenceStore(defaults: InMemoryPreferences()))
    var privacy = store.load()
    privacy.anonymisesFileNames = true
    privacy.removesMediaMetadata = false // This test edits names of a synthetic, nonexistent file.
    store.save(privacy)
    let model = AppModel(launchMode: .offlineTesting, provider: TypingTestProvider(), privacySafetySettingsStore: store)
    await model.start()
    let url = URL(fileURLWithPath: "/tmp/sakuracord-editable-attachment.png")
    await model.addComposerAttachments([url], to: .channel)
    var attachment = try #require(model.channelComposerAttachments.first)
    #expect(attachment.isFilenameAnonymised)
    #expect(attachment.filename != url.lastPathComponent)

    attachment.description = "A useful description"
    model.updateComposerAttachment(attachment, in: .channel)
    #expect(model.channelComposerAttachments.first?.filename == attachment.filename)
}

@MainActor
@Test func `ordinary text typed around a mention serializes one exact mention token`() throws {
    let token = "<@123>"
    let presentation = MentionPresentation(
        rawToken: token,
        label: "@Ari",
        target: .user(UserID(rawValue: 123))
    )
    let textView = ComposerNSTextView()
    textView.plainTypingAttributes = ComposerEmojiAttributedText.textAttributes(
        .systemFont(ofSize: 15)
    )
    textView.textStorage?.setAttributedString(
        ComposerEmojiAttributedText.make(token, mentionPresentations: [token: presentation])
    )

    textView.setSelectedRange(NSRange(location: 0, length: 0))
    textView.insertText("before ", replacementRange: textView.selectedRange())
    textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
    textView.insertText(" after", replacementRange: textView.selectedRange())

    let serialized = ComposerEmojiAttributedText.serialize(textView.attributedString())
    #expect(serialized == "before <@123> after")
    #expect(serialized.unicodeScalars.allSatisfy { $0.value != 0xFFFC })
    #expect(serialized.components(separatedBy: token).count == 2)
}

@MainActor
@Test func `notification deep link switches accounts before navigating`() async throws {
    let targetAccount = CredentialHandle(accountID: "target-account")
    let credentials = NotificationCredentialStore(handles: [targetAccount])
    let model = AppModel(
        launchMode: .normal,
        discordNetworkDisabledOverride: false,
        restoresStoredSession: false,
        credentialStore: credentials,
        authenticatedProviderFactory: { _, _ in MockChatProvider() },
        accountDatabaseFactory: { _ in
            try? SakuraCordDatabase(inMemory: true)
        }
    )
    await model.start()
    #expect(
        await model.connectAuthenticatedAccount(
            CredentialHandle(accountID: "other-account")
        )
    )
    #expect(model.readState.accountID == "other-account")

    let channel = try #require(
        model.snapshot?.channels.first { $0.id == ChannelID(rawValue: 200) }
    )
    let expectedGuildID = channel.guildID
    let expectedChannelID = channel.id
    let target = MessageID(rawValue: 1001)
    await model.navigate(
        from: NotificationDeepLink(
            accountID: targetAccount.accountID,
            guildID: expectedGuildID,
            channelID: expectedChannelID,
            messageID: target
        )
    )

    let didNavigate = await until {
        model.readState.accountID == "target-account"
            && model.selectedGuildID == expectedGuildID
            && model.selectedChannelID == expectedChannelID
            && model.messageNavigationRequest?.channelID == expectedChannelID
            && model.messageNavigationRequest?.messageID == target
    }
    #expect(didNavigate)
}

@MainActor
@Test func `an AutoMod blocked message is not resent and keeps the failed draft and newer composer text`() async throws {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let channelID = try #require(model.selectedChannelID)
    let attachment = ForumPostAttachment(url: URL(fileURLWithPath: "/tmp/synthetic-automod.txt"))
    await provider.failNextSend()
    await provider.suspendNextSend()
    let delivery = try #require(model.enqueueChannelMessage(
        channelID: channelID, content: "blocked", replyTo: .init(rawValue: 42),
        replyPreview: nil, attachments: [attachment], clearsComposer: true
    ))
    await provider.waitUntilSendStarts()
    model.updateDraft("New draft")
    await provider.releaseSend()
    #expect(!(await delivery.value))
    let ordinaryFailure = try #require(model.messages.first { $0.content == "blocked" })
    await provider.blockNextSendWithAutoMod()
    #expect(!(await model.retrySending(ordinaryFailure)))
    let failed = try #require(model.messages.first { $0.content == "blocked" })
    let nonce = try #require(failed.nonce)
    #expect(failed.sendFailure == .autoModeration(explanation: "Synthetic rule explanation"))
    #expect(!failed.canRetrySending)
    #expect(await provider.sendCount == 2)
    #expect(!(await model.retrySending(failed)))
    #expect(!(await model.retrySending(ordinaryFailure)))
    #expect(await provider.sendCount == 2)
    #expect(model.composer.outbox.draftsByNonce[nonce]?.attachments == [attachment])
    #expect(model.draft == "New draft")
}

@MainActor
@Test func `profile message retry after a timeout reuses the failed outbox nonce`() async throws {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let recipient = User(id: UserID(rawValue: 2), username: "recipient", displayName: "Recipient")
    let channelID = try #require(model.selectedChannelID)
    let index = try #require(model.snapshot?.channels.firstIndex { $0.id == channelID })
    model.snapshot?.channels[index].recipients = [recipient]
    await provider.timeOutNextSend()
    let nonce = ClientNonce.make()
    #expect(await model.sendProfileMessage(to: recipient.id, content: "retry privately", nonce: nonce) == false)
    // Failed profile sends outlive bounded history windows and cache eviction.
    model.messages = []
    model.messageCache[channelID] = nil
    #expect(await model.sendProfileMessage(to: recipient.id, content: "retry privately", nonce: nonce))
    let drafts = await provider.sentDrafts
    #expect(drafts.count == 2)
    #expect(drafts[0] == drafts[1])
    #expect(await model.sendProfileMessage(to: recipient.id, content: "retry privately", nonce: nonce))
    #expect(await provider.sendCount == 2)
}

@MainActor
@Test(arguments: [false, true])
func `profile send retains a Gateway receipt across timeout and history eviction`(confirmsAfterTimeout: Bool) async throws {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let recipient = provider.otherUser
    let channelID = try #require(model.selectedChannelID)
    let index = try #require(model.snapshot?.channels.firstIndex { $0.id == channelID })
    model.snapshot?.channels[index].recipients = [recipient]
    await provider.timeOutNextSend()
    await provider.suspendNextSend()
    let nonce = ClientNonce.make()
    let send = Task { await model.sendProfileMessage(to: recipient.id, content: "confirmed privately", nonce: nonce) }
    await provider.waitUntilSendStarts()
    #expect(!(await model.sendProfileMessage(to: recipient.id, content: "confirmed privately", nonce: nonce)))
    let pending = try #require(model.messages.first { $0.nonce == nonce })
    var confirmation = Message(
        id: MessageID(rawValue: 9_001), channelID: channelID, author: pending.author,
        content: pending.content, nonce: nonce
    )
    if confirmsAfterTimeout {
        await provider.releaseSend()
        #expect(!(await send.value))
    }
    model.consumeMessageCreated(&confirmation, preparedTextPlan: nil)
    model.messages = []
    model.messageCache[channelID] = nil
    if confirmsAfterTimeout {
        #expect(await model.sendProfileMessage(to: recipient.id, content: "confirmed privately", nonce: nonce))
    } else {
        await provider.releaseSend()
        #expect(await send.value)
    }
    #expect(model.composer.outbox.draftsByNonce[nonce] == nil)
    #expect(await provider.sendCount == 1)
}

@MainActor
@Test func `retrying a timed out send resends the exact draft under the same nonce`() async throws {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    await provider.timeOutNextSend()
    let attachment = ForumPostAttachment(
        url: URL(fileURLWithPath: "/tmp/sakuracord-retry-image.png"),
        filename: "renamed-image.png",
        description: "exact attachment description",
        isSpoiler: true
    )

    model.updateDraft("retry this exact message")
    #expect(!(await model.sendComposerMessage(attachments: [attachment])))
    let failed = try #require(model.messages.first {
        $0.content == "retry this exact message"
    })
    #expect(await model.retrySending(failed))

    let sentDrafts = await provider.sentDrafts
    #expect(sentDrafts.count == 2)
    #expect(sentDrafts[0] == sentDrafts[1])
    #expect(sentDrafts[1].content == "retry this exact message")
    #expect(sentDrafts[1].attachments == [attachment])
}

@MainActor
@Test func `queued sends are delivered in order and a full queue refuses without losing the draft`() async throws {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()

    await provider.suspendNextSend()
    let contents = (0 ... OutgoingMessageState.maximumWaitingDeliveries).map { "queued \($0)" }
    var deliveries: [Task<Bool, Never>] = []
    for content in contents {
        model.updateDraft(content)
        guard case let .enqueued(delivery) = await model.submitComposerMessage(attachments: []) else {
            Issue.record("\(content) was not queued")
            return
        }
        deliveries.append(delivery)
        if deliveries.count == 1 { await provider.waitUntilSendStarts() }
    }

    model.updateDraft("refused")
    #expect(!(await model.submitComposerMessage(attachments: [])).consumedComposer)
    #expect(model.draft == "refused")

    await provider.releaseSend()
    for delivery in deliveries {
        #expect(await delivery.value)
    }
    #expect(await provider.sentDrafts.map(\.content) == contents)
}

@MainActor
@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func `timeout during thread creation preserves its unsent message without replacing another thread draft`(navigatesAway: Bool) async throws {
    let permissions = DiscordPermissionBits.viewChannel | DiscordPermissionBits.readMessageHistory
        | DiscordPermissionBits.sendMessages | DiscordPermissionBits.sendMessagesInThreads
        | DiscordPermissionBits.createPublicThreads | DiscordPermissionBits.attachFiles
    let guild = Guild(id: GuildID(rawValue: 20), name: "Guild", currentUserPermissions: permissions)
    let provider = TypingTestProvider(guild: guild)
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    await model.memberLoadTask?.value
    defer { model.onboarding.reset() }
    let channelID = try #require(model.selectedChannelID)
    let creation = ThreadCreationDraft(parentID: channelID, permissions: model.selectedChannelThreadCreationPermissions)
    try #require(creation.permissions.canCreatePublic)
    creation.name = "Thread"
    model.sideConversations.thread = .threadCreation(creation)
    let originalDraft = "  Keep this first message\n"
    let attachment = ForumPostAttachment(url: URL(fileURLWithPath: "/tmp/thread-timeout-draft.txt"))
    model.threadDraft = originalDraft
    model.threadComposerAttachments = [attachment]

    let submission = Task { await model.submitThreadCreation(creation, attachments: [attachment]) }
    await provider.waitUntilThreadCreationStarts()
    var member = Member(user: try #require(model.currentUser), roleName: "Member", isOnline: false)
    member.communicationDisabledUntil = .now.addingTimeInterval(300)
    model.consumeMembersChanged(guildID: guild.id, members: [member], groups: [])
    let otherThread = MessageThreadSummary(
        id: ChannelID(rawValue: 31), guildID: guild.id, parentID: channelID, name: "Other"
    )
    let otherAttachment = ForumPostAttachment(url: URL(fileURLWithPath: "/tmp/other-thread-draft.txt"))
    if navigatesAway {
        model.open(otherThread)
        model.threadDraft = "Other thread draft"
        model.threadComposerAttachments = [otherAttachment]
    }

    await provider.completeThreadCreation()
    let result = await submission.value

    #expect(!result.consumedComposer)
    #expect(await provider.sendCount == 0)
    #expect(model.composer.outbox.waitingDeliveryCount == 0)
    #expect(model.openThread?.id == (navigatesAway ? otherThread.id : ChannelID(rawValue: 30)))
    #expect(model.threadDraft == (navigatesAway ? "Other thread draft" : originalDraft))
    #expect(model.threadComposerAttachments == [navigatesAway ? otherAttachment : attachment])
}

@MainActor
@Test func `queued retry confirmed outside the visible history is not sent again`() async throws {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    await provider.timeOutNextSend()
    model.updateDraft("ambiguous send")
    #expect(!(await model.sendComposerMessage(attachments: [])))
    let failed = try #require(model.messages.first { $0.content == "ambiguous send" })

    await provider.suspendNextSend()
    model.updateDraft("in flight")
    guard case let .enqueued(inFlight) = await model.submitComposerMessage(attachments: []) else {
        Issue.record("The blocking send was not queued")
        return
    }
    await provider.waitUntilSendStarts()
    let retry = Task { @MainActor in await model.retrySending(failed) }
    #expect(await until { model.composer.outbox.waitingDeliveryCount == 1 })

    // The timed-out original lands while an older history window is shown.
    model.hasMoreLaterMessages = true
    var confirmation = Message(
        id: MessageID(rawValue: 9_000), channelID: failed.channelID, author: failed.author,
        content: failed.content, nonce: failed.nonce
    )
    model.consumeMessageCreated(&confirmation, preparedTextPlan: nil)

    await provider.releaseSend()
    #expect(await inFlight.value)
    #expect(await retry.value)
    #expect(await provider.sentNonces.filter { $0 == failed.nonce }.count == 1)
}

@MainActor
@Test(arguments: [false, true])
func `Gateway confirmation wins before or after a send timeout`(confirmsBeforeTimeout: Bool) async throws {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    await provider.timeOutNextSend()
    await provider.suspendNextSend()
    model.updateDraft("confirmed through Gateway")
    let send = Task { await model.send() }
    await provider.waitUntilSendStarts()
    let pending = try #require(model.messages.last { $0.content == "confirmed through Gateway" })
    let nonce = try #require(pending.nonce)
    let confirmed = Message(
        id: MessageID(rawValue: 500),
        channelID: pending.channelID,
        author: pending.author,
        content: pending.content,
        nonce: nonce
    )

    if confirmsBeforeTimeout {
        model.consumeImmediately(.messageCreated(confirmed))
    }
    await provider.releaseSend()
    #expect(await send.value == confirmsBeforeTimeout)
    if !confirmsBeforeTimeout {
        #expect(model.outgoingState(nonce: nonce, channelID: pending.channelID) == .failed)
        model.consumeImmediately(.messageCreated(confirmed))
    }

    let reconciled = model.messages.filter { $0.nonce == nonce }
    #expect(reconciled.count == 1)
    #expect(reconciled.first?.id == confirmed.id)
    #expect(reconciled.first?.outboxState == .confirmed)
    #expect(model.composer.outbox.draftsByNonce[nonce] == nil)
    var staleFailedMessage = pending
    staleFailedMessage.outboxState = .failed
    #expect(!(await model.retrySending(staleFailedMessage)))
    #expect(await provider.sendCount == 1)
}

private func createSparseFile(_ url: URL, size: Int64) throws {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: UInt64(size))
}

private actor AttachmentUploadTestUploader: ExternalAttachmentUploading {
    let result: URL
    private(set) var callCount = 0

    init(result: URL) {
        self.result = result
    }

    func upload(
        fileURL _: URL,
        using _: ExternalAttachmentHostingService
    ) async throws -> URL {
        callCount += 1
        return result
    }
}

private actor SequencedAttachmentUploadTestUploader: ExternalAttachmentUploading {
    private(set) var callCount = 0
    private var continuations: [Int: CheckedContinuation<URL, Never>] = [:]

    func upload(
        fileURL _: URL,
        using _: ExternalAttachmentHostingService
    ) async throws -> URL {
        callCount += 1
        let call = callCount
        return await withCheckedContinuation { continuation in
            continuations[call] = continuation
        }
    }

    func release(call: Int, with url: URL) {
        continuations.removeValue(forKey: call)?.resume(returning: url)
    }
}

@MainActor
@Test(arguments: [UInt64(10), 13])
func `Diagnostics sharing binds confirmation to its source and preserves drafts and retry files`(sourceID: UInt64) async throws {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let source = ChannelID(rawValue: sourceID)
    let thread = MessageThreadSummary(id: ChannelID(rawValue: 13), parentID: ChannelID(rawValue: 10), name: "thread")
    model.snapshot?.threads = [thread]
    model.openThread = thread
    let staged = URL(fileURLWithPath: "/tmp/sakuracord-diagnostics-staged")
    await provider.failNextSend()
    let sent = await model.shareDiagnostics(in: source, confirm: { name in
        #expect(name == [10: "text", 13: "thread"][sourceID])
        #expect(await model.shareDiagnostics(in: source, confirm: { _ in
            Issue.record("Duplicate click must not present another confirmation")
            return true
        }) == false)
        model.selectedChannelID = ChannelID(rawValue: 12)
        model.updateDraft("unfinished message")
        await model.addComposerAttachments([staged], to: .channel)
        return true
    }, export: { Data("sanitised fixture".utf8) })
    #expect(!sent)
    let outgoing = try #require(await provider.sentDrafts.first)
    #expect(outgoing.channelID == source)
    #expect(outgoing.content.isEmpty)
    #expect(model.draft == "unfinished message")
    #expect(model.channelComposerAttachments.map(\.url) == [staged])
    let file = try #require(outgoing.attachmentURLs.first)
    #expect(try String(contentsOf: file, encoding: .utf8) == "sanitised fixture")
    let failed = try #require(model.composer.outbox.draftsByNonce[outgoing.nonce])
    #expect(await model.performOutgoingSend(failed, isRetry: true))
    #expect(await provider.sentDrafts.map(\.channelID) == [source, source])
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@MainActor
@Test(arguments: ["cancel", "session", "permission"])
func `Diagnostics sharing stops before delivery when confirmation is cancelled or the session or access changes`(reason: String) async {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let source = ChannelID(rawValue: 10)
    let sent = await model.shareDiagnostics(in: source, confirm: { _ in
        if reason == "session" { model.invalidateAccountSession() }
        if reason == "permission" {
            model.snapshot?.channels.removeAll { $0.id == source }
            model.visibleChannels.removeAll { $0.id == source }
        }
        return reason != "cancel"
    }, export: {
        Issue.record("A rejected confirmation must not export diagnostics")
        return Data()
    })
    #expect(!sent)
    #expect(await provider.sendCount == 0)
    #expect(model.composer.outbox.draftsByNonce.isEmpty)
    #expect(!model.diagnosticsShareInFlight)
}

private actor TypingTestProvider: ChatProvider {
    private enum SendFailure {
        case definite
        case timedOut
        case autoModeration
    }

    let currentUser = User(id: UserID(rawValue: 1), username: "me", displayName: "Me")
    let otherUser = User(id: UserID(rawValue: 2), username: "other", displayName: "Other")
    private let guild: Guild?
    private var channels: [Channel] { [
        Channel(id: ChannelID(rawValue: 10), guildID: guild?.id, name: "text", kind: guild == nil ? .directMessage : .text),
        Channel(id: ChannelID(rawValue: 11), guildID: nil, name: "voice", kind: .voice),
        Channel(id: ChannelID(rawValue: 12), guildID: nil, name: "group", kind: .groupDirectMessage)
    ] }
    private var continuation: AsyncStream<ClientEvent>.Continuation?
    private(set) var sendCount = 0
    private(set) var editCount = 0
    private(set) var sentNonces: [String] = []
    private(set) var sentDrafts: [SendMessageDraft] = []
    private var nextMessageID: UInt64 = 100
    private var nextSendFailure: SendFailure?
    private var suspendsNextSend = false
    private var sendStartedWaiter: CheckedContinuation<Void, Never>?
    private var sendReleaseWaiter: CheckedContinuation<Void, Never>?
    private var didStartSuspendedSend = false
    private var threadCreationStarted: CheckedContinuation<Void, Never>?
    private var threadCreationResponse: CheckedContinuation<MessageThreadSummary, Error>?

    init(guild: Guild? = nil) {
        self.guild = guild
    }

    func bootstrap() async throws -> BootstrapSnapshot {
        continuation?.yield(.connectionChanged(.ready))
        return BootstrapSnapshot(currentUser: currentUser, guilds: guild.map { [$0] } ?? [], channels: channels, members: [])
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        channels
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        []
    }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("not used")
    }

    func currentStatus() async -> PresenceStatus {
        .online
    }

    func updateStatus(_ status: PresenceStatus) async throws {}
    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws -> MessagePage {
        MessagePage(messages: [], hasMoreBefore: false)
    }

    func sendTyping(in channelID: ChannelID) async throws {}

    func createThread(_ draft: CreateThreadDraft) async throws -> MessageThreadSummary {
        try await withCheckedThrowingContinuation { continuation in
            threadCreationResponse = continuation
            threadCreationStarted?.resume()
            threadCreationStarted = nil
        }
    }

    func waitUntilThreadCreationStarts() async {
        if threadCreationResponse != nil { return }
        await withCheckedContinuation { threadCreationStarted = $0 }
    }

    func completeThreadCreation() {
        threadCreationResponse?.resume(returning: MessageThreadSummary(
            id: ChannelID(rawValue: 30), guildID: guild?.id, parentID: channels[0].id, name: "Thread"
        ))
        threadCreationResponse = nil
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        sendCount += 1
        sentNonces.append(draft.nonce)
        sentDrafts.append(draft)
        let failure = nextSendFailure
        nextSendFailure = nil
        if suspendsNextSend {
            suspendsNextSend = false
            didStartSuspendedSend = true
            sendStartedWaiter?.resume()
            sendStartedWaiter = nil
            await withCheckedContinuation { continuation in
                sendReleaseWaiter = continuation
            }
        }
        if let failure {
            switch failure {
            case .definite:
                throw ChatProviderError.invalidRequest("Synthetic send failure")
            case .timedOut:
                throw URLError(.timedOut)
            case .autoModeration:
                throw ChatProviderError.autoModerationBlocked(explanation: "Synthetic rule explanation")
            }
        }
        nextMessageID += 1
        let message = Message(
            id: MessageID(rawValue: nextMessageID),
            channelID: draft.channelID,
            author: currentUser,
            content: draft.content,
            attachments: draft.attachmentURLs.enumerated().map {
                Attachment(id: "\(nextMessageID)-\($0.offset)", filename: $0.element.lastPathComponent, url: $0.element)
            },
            nonce: draft.nonce,
            stickers: draft.stickerIDs.map {
                MessageSticker(id: $0, name: "Confirmed Sticker", format: .png)
            }
        )
        continuation?.yield(.messageCreated(message))
        return message
    }

    func suspendNextSend() {
        suspendsNextSend = true
        didStartSuspendedSend = false
    }

    func failNextSend() {
        nextSendFailure = .definite
    }

    func blockNextSendWithAutoMod() {
        nextSendFailure = .autoModeration
    }

    func timeOutNextSend() {
        nextSendFailure = .timedOut
    }

    func waitUntilSendStarts() async {
        if didStartSuspendedSend { return }
        await withCheckedContinuation { continuation in
            sendStartedWaiter = continuation
        }
    }

    func releaseSend() {
        sendReleaseWaiter?.resume()
        sendReleaseWaiter = nil
    }

    func supports(_ capability: ChatCapability) async -> Bool {
        capability == .stickerSending
    }

    func edit(_ message: Message, content: String) async throws -> Message {
        editCount += 1
        throw ChatProviderError.invalidRequest("not used")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {}
    func eventStream() async -> AsyncStream<ClientEvent> {
        let stream = AsyncStream<ClientEvent>.makeStream(bufferingPolicy: .bufferingNewest(50))
        continuation = stream.continuation
        return stream.stream
    }

    func disconnect() async {
        continuation?.yield(.connectionChanged(.disconnected))
    }
}

private actor NotificationCredentialStore: CredentialStore {
    let storedHandles: [CredentialHandle]

    init(handles: [CredentialHandle]) {
        storedHandles = handles
    }

    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        CredentialHandle(accountID: accountID)
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        Data()
    }

    func remove(_ handle: CredentialHandle) async throws {}

    func handles() async throws -> [CredentialHandle] {
        storedHandles
    }
}

@MainActor
@Test(arguments: [false, true])
func `a late translation cannot repopulate a draft that was already sent`(completesBeforeSend: Bool) async throws {
    let provider = TypingTestProvider()
    let translator = ControlledTranslationTestService()
    let state = TranslationState(
        settingsStore: TranslationSettingsStore(preferences: SettingsPreferenceStore(defaults: InMemoryPreferences())),
        translator: translator
    )
    let model = AppModel(launchMode: .offlineTesting, provider: provider, translation: state)
    await model.start()
    model.selectedChannelID = ChannelID(rawValue: 10)
    model.applyTranslationSettings(.init(isEnabled: true, messageLanguage: "en", draftLanguage: "en"))
    model.updateDraft("Hallo")
    model.translateDraft(in: .channel)
    let translationTask = try #require(state.draftTasks[.channel])
    await translator.waitForRequests(1)
    if completesBeforeSend {
        translator.complete(0, text: "Translated")
        await translationTask.value
        #expect(model.draft == "Translated")
    }
    #expect(await provider.sendCount == 0)
    #expect(await provider.editCount == 0)
    #expect(await model.send())
    if !completesBeforeSend {
        translator.complete(0, text: "Late translation")
        await translationTask.value
    }
    #expect(model.draft.isEmpty)
    #expect(state.drafts[.channel] == nil)
    #expect(await provider.sendCount == 1)
    let message = Message(id: MessageID(rawValue: 999), channelID: ChannelID(rawValue: 10),
                          author: provider.otherUser, content: "Hallo")
    model.toggleMessageTranslation(message)
    let messageTask = try #require(state.messageTasks[message.id])
    await translator.waitForRequests(2)
    translator.complete(1)
    await messageTask.value
    #expect(await provider.sendCount == 1)
    #expect(await provider.editCount == 0)
}
