import DiscordProtocol
import AppKit
import Foundation
import MessageRendering
import MediaPipeline
@testable import SakuraCord
import SakuraCordModels
import SakuraCordPersistence
import Testing

@MainActor
@Test func `typing state supports multiple users independent refresh and self suppression`() {
    let state = TypingStateModel(expiry: .milliseconds(40))
    let channel = ChannelID(rawValue: 10)
    let current = User(id: UserID(rawValue: 1), username: "me", displayName: "Me")
    let amy = User(id: UserID(rawValue: 2), username: "amy", displayName: "Amy")
    let ben = User(id: UserID(rawValue: 3), username: "ben", displayName: "Ben")
    let cy = User(id: UserID(rawValue: 4), username: "cy", displayName: "Cy")

    state.receive(channelID: channel, user: current, currentUserID: current.id)
    #expect(state.presentation(in: channel) == nil)
    state.receive(channelID: channel, user: amy, currentUserID: current.id)
    #expect(state.presentation(in: channel) == "Amy is typing…")
    state.receive(channelID: channel, user: ben, currentUserID: current.id)
    #expect(state.presentation(in: channel) == "Amy and Ben are typing…")
    state.receive(channelID: channel, user: cy, currentUserID: current.id)
    #expect(state.presentation(in: channel) == "Amy, Ben, and 1 other are typing…")

    state.clear(userID: ben.id, in: channel)
    #expect(state.presentation(in: channel) == "Amy and Cy are typing…")
    let amyGeneration = state.expiryGenerationForTesting(channelID: channel, userID: amy.id)
    let oldCyGeneration = state.expiryGenerationForTesting(channelID: channel, userID: cy.id)
    state.receive(channelID: channel, user: cy, currentUserID: current.id)
    let refreshedCyGeneration = state.expiryGenerationForTesting(channelID: channel, userID: cy.id)
    state.applyExpiryForTesting(channelID: channel, userID: amy.id, generation: amyGeneration ?? 0)
    #expect(state.presentation(in: channel) == "Cy is typing…")
    state.applyExpiryForTesting(channelID: channel, userID: cy.id, generation: oldCyGeneration ?? 0)
    #expect(state.presentation(in: channel) == "Cy is typing…")
    state.applyExpiryForTesting(channelID: channel, userID: cy.id, generation: refreshedCyGeneration ?? 0)
    #expect(state.presentation(in: channel) == nil)
}

@MainActor
@Test func `remote typing is channel scoped cleared by message and disconnect`() async throws {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider, typingExpiry: .seconds(1))
    await model.start()
    let text = try #require(model.selectedChannel)
    let other = provider.otherUser
    let third = User(id: UserID(rawValue: 3), username: "third", displayName: "Third")

    await provider.emit(.typing(channelID: text.id, user: other))
    await provider.emit(.typing(channelID: ChannelID(rawValue: 12), user: third))
    #expect(await eventuallyOnMain { model.typingState.presentation(in: text.id) == "Other is typing…" })
    #expect(await eventuallyOnMain {
        model.typingState.presentation(in: ChannelID(rawValue: 12)) == "Third is typing…"
    })

    await provider.emit(.messageCreated(Message(
        id: MessageID(rawValue: 99),
        channelID: text.id,
        author: other,
        content: "sent"
    )))
    #expect(await eventuallyOnMain { model.typingState.presentation(in: text.id) == nil })

    await provider.emit(.connectionChanged(.disconnected))
    #expect(await eventuallyOnMain { model.typingState.presentation(in: ChannelID(rawValue: 12)) == nil })
}

@MainActor
@Test func `mock typing is deterministic and rejects voice channels`() async throws {
    let provider = MockChatProvider()
    _ = try await provider.bootstrap()
    try await provider.sendTyping(in: ChannelID(rawValue: 210))
    try await provider.sendTyping(in: ChannelID(rawValue: 210))
    #expect(await provider.typingRequests == [ChannelID(rawValue: 210), ChannelID(rawValue: 210)])
    await #expect(throws: ChatProviderError.self) {
        try await provider.sendTyping(in: ChannelID(rawValue: 230))
    }
}

@MainActor
@Test func `composer return decision covers setting shift command and IME`() {
    #expect(ComposerReturnAction.decide(
        sendWithReturn: true, shift: false, command: false, hasMarkedText: false
    ) == .send)
    #expect(ComposerReturnAction.decide(
        sendWithReturn: true, shift: true, command: false, hasMarkedText: false
    ) == .newline)
    #expect(ComposerReturnAction.decide(
        sendWithReturn: false, shift: false, command: false, hasMarkedText: false
    ) == .newline)
    #expect(ComposerReturnAction.decide(
        sendWithReturn: false, shift: false, command: true, hasMarkedText: false
    ) == .send)
    #expect(ComposerReturnAction.decide(
        sendWithReturn: true, shift: false, command: false, hasMarkedText: true
    ) == .inputMethod)
    #expect(ComposerReturnAction.decide(
        sendWithReturn: false, shift: true, command: true, hasMarkedText: false
    ) == .newline)
    #expect(ComposerReturnAction.decide(
        sendWithReturn: false, shift: false, command: true, hasMarkedText: true
    ) == .inputMethod)
}

@Test func `up arrow edit target skips newer messages from other users`() {
    let currentUser = User(
        id: UserID(rawValue: 1),
        username: "current",
        displayName: "Current"
    )
    let otherUser = User(
        id: UserID(rawValue: 2),
        username: "other",
        displayName: "Other"
    )
    let channelID = ChannelID(rawValue: 10)
    let messages = [
        Message(
            id: MessageID(rawValue: 100),
            channelID: channelID,
            author: currentUser,
            content: "older current-user message",
            timestamp: Date(timeIntervalSince1970: 100)
        ),
        Message(
            id: MessageID(rawValue: 101),
            channelID: channelID,
            author: currentUser,
            content: "latest current-user message",
            timestamp: Date(timeIntervalSince1970: 101)
        ),
        Message(
            id: MessageID(rawValue: 102),
            channelID: channelID,
            author: otherUser,
            content: "newer message from someone else",
            timestamp: Date(timeIntervalSince1970: 102)
        )
    ]

    #expect(
        ComposerLatestMessageEditingPolicy.messageID(
            in: messages,
            currentUserID: currentUser.id
        ) == MessageID(rawValue: 101)
    )
    #expect(
        ComposerLatestMessageEditingPolicy.messageID(
            in: messages,
            currentUserID: nil
        ) == nil
    )
    #expect(
        ComposerLatestMessageEditingPolicy.messageID(
            in: Array(messages.suffix(1)),
            currentUserID: currentUser.id
        ) == nil
    )
}

@MainActor
@Test func `plain up arrow in an empty composer requests latest message editing`() throws {
    let textView = ComposerNSTextView()
    let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 320, height: 80),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = textView
    #expect(window.makeFirstResponder(textView))
    #expect(window.firstResponder === textView)
    var editRequestCount = 0
    textView.onAutocompleteCommand = { _ in false }
    textView.onEditLatestMessage = {
        editRequestCount += 1
        return true
    }

    textView.keyDown(with: try upArrowKeyEvent())
    #expect(editRequestCount == 1)
    #expect(window.firstResponder !== textView)
    #expect(!ComposerLatestMessageEditingPolicy.shouldRequest(
        keyCode: 126,
        modifierFlags: [],
        composerIsEmpty: false
    ))
    #expect(!ComposerLatestMessageEditingPolicy.shouldRequest(
        keyCode: 126,
        modifierFlags: [.shift],
        composerIsEmpty: true
    ))
}

@MainActor
@Test func `command arrows request directional reply navigation`() throws {
    let textView = ComposerNSTextView()
    var directions: [MessageReplyNavigationDirection] = []
    textView.onAutocompleteCommand = { _ in false }
    textView.onNavigateReplySelection = { direction in
        directions.append(direction)
        return true
    }

    textView.keyDown(with: try upArrowKeyEvent(modifiers: [.command]))
    textView.keyDown(with: try downArrowKeyEvent(modifiers: [.command]))

    #expect(directions == [.older, .newer])
    #expect(ComposerNSTextView.replyNavigationDirection(
        for: try upArrowKeyEvent(modifiers: [.command])
    ) == .older)
    #expect(ComposerNSTextView.replyNavigationDirection(
        for: try downArrowKeyEvent(modifiers: [.command])
    ) == .newer)
    #expect(ComposerNSTextView.replyNavigationDirection(
        for: try upArrowKeyEvent(modifiers: [.command, .shift])
    ) == nil)
}

@MainActor
@Test func `timeline edit request rechecks current user ownership`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let currentUser = try #require(model.snapshot?.currentUser)
    let otherUser = User(
        id: UserID(rawValue: currentUser.id.rawValue + 1),
        username: "other",
        displayName: "Other"
    )
    let channelID = ChannelID(rawValue: 12_345)
    let messages = [
        Message(
            id: MessageID(rawValue: 20_001),
            channelID: channelID,
            author: currentUser,
            content: "editable",
            timestamp: Date(timeIntervalSince1970: 20_001)
        ),
        Message(
            id: MessageID(rawValue: 20_002),
            channelID: channelID,
            author: otherUser,
            content: "not editable",
            timestamp: Date(timeIntervalSince1970: 20_002)
        )
    ]
    let items = MessageGrouping.rows(for: messages).map {
        NativeMessageTimelineItem.message(
            $0,
            isUnreadBoundary: false,
            isHighlighted: false
        )
    }
    let layouts = items.map {
        NativeTimelineRowLayout.make(item: $0, width: 560)
    }
    let storage = NativeTimelineCanvasStorage()
    storage.items = items
    storage.layouts = layouts
    storage.rowOrigins = layouts.dropLast().reduce(into: [CGFloat(0)]) {
        $0.append(($0.last ?? 0) + $1.height)
    }
    storage.contentHeight = layouts.reduce(0) { $0 + $1.height }
    let canvas = NativeTimelineCanvasView(
        frame: CGRect(
            x: 0,
            y: 0,
            width: 560,
            height: storage.contentHeight
        )
    )
    canvas.apply(
        storage: storage,
        model: model,
        actions: NativeTimelineRowActions(
            loadEarlier: {},
            openReply: { _ in },
            reply: nil,
            retry: { _ in },
            edit: { _, _ in },
            markUnread: { _ in },
            delete: { _ in },
            react: { _, _ in },
            openThread: { _ in },
            submitComponent: { _, _, _, _ in }
        ),
        viewportWidth: 560,
        minimumHeight: storage.contentHeight,
        bottomSpacerHeight: 0,
        contentOriginY: 0
    )

    #expect(
        !canvas.beginEditingCurrentUserMessage(
            MessageID(rawValue: 20_002)
        )
    )
    #expect(canvas.editingMessageID == nil)
    #expect(
        canvas.beginEditingCurrentUserMessage(
            MessageID(rawValue: 20_001)
        )
    )
    #expect(canvas.editingMessageID == MessageID(rawValue: 20_001))
}

@Test func `message edit submission trims edges and rejects empty input`() {
    #expect(MessageEditInputPolicy.submission(from: "") == nil)
    #expect(MessageEditInputPolicy.submission(from: " \n\t ") == nil)
    #expect(MessageEditInputPolicy.submission(from: "  edited message  \n") == "edited message")
    #expect(MessageEditInputPolicy.submission(from: "first line\nsecond line") == "first line\nsecond line")
}

@MainActor
@Test func `message edit return policy saves return preserves multiline and respects IME`() {
    #expect(MessageEditInputPolicy.returnAction(
        shift: false, command: false, hasMarkedText: false
    ) == .send)
    #expect(MessageEditInputPolicy.returnAction(
        shift: true, command: false, hasMarkedText: false
    ) == .newline)
    #expect(MessageEditInputPolicy.returnAction(
        shift: false, command: false, hasMarkedText: true
    ) == .inputMethod)
}

@MainActor
@Test func `attachment only send works and whitespace only does not send`() async {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let before = await provider.sendCount
    model.updateDraft("  \n")
    await model.send()
    #expect(await provider.sendCount == before)

    let attachment = URL(fileURLWithPath: "/tmp/sakuracord-test-attachment")
    await model.send(attachments: [attachment])
    #expect(await provider.sendCount == before + 1)
}

@MainActor
@Test func `composer stages at most ten attachments and clears them on Escape and navigation`() async throws {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let urls = (0 ..< 12).map {
        URL(fileURLWithPath: "/tmp/sakuracord-composer-\($0)")
    }

    #expect(await model.addComposerAttachments([urls[0], urls[0]] + urls.dropFirst(), to: .channel))
    #expect(
        model.channelComposerAttachments.map(\.url)
            == [urls[0], urls[0]] + Array(urls.dropFirst().prefix(8))
    )
    #expect(Set(model.channelComposerAttachments.map(\.id)).count == 10)
    #expect(model.errorMessage?.contains("10") == true)

    let firstID = try #require(model.channelComposerAttachments.first?.id)
    model.removeComposerAttachment(firstID, from: .channel)
    #expect(model.channelComposerAttachments.filter { $0.url == urls[0] }.count == 1)

    #expect(model.consumeEscapeForComposerAttachments(in: .channel))
    #expect(model.channelComposerAttachments.isEmpty)
    #expect(!model.consumeEscapeForComposerAttachments(in: .channel))

    #expect(await model.addComposerAttachments([urls[0]], to: .channel))
    model.selectedChannelID = ChannelID(rawValue: 12)
    #expect(model.channelComposerAttachments.isEmpty)
}

@MainActor
@Test func `oversized attachment is rejected at selection and external upload stays opt in`() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sakuracord-attachment-limit-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let exact = directory.appendingPathComponent("exact.bin")
    let oversized = directory.appendingPathComponent("oversized.bin")
    try createSparseFile(exact, size: DiscordAttachmentUploadPolicy.baseLimit)
    try createSparseFile(oversized, size: DiscordAttachmentUploadPolicy.baseLimit + 1)

    let uploader = AttachmentUploadTestUploader(
        result: URL(string: "https://files.catbox.moe/test.bin")!
    )
    let privacySafetySettingsStore = PrivacySafetySettingsStore(
        preferences: SettingsPreferenceStore(defaults: InMemoryPreferences())
    )
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: TypingTestProvider(),
        externalAttachmentUploader: uploader,
        attachmentSettingsStore: AttachmentSettingsStore(preferences: SettingsPreferenceStore(defaults: InMemoryPreferences())),
        privacySafetySettingsStore: privacySafetySettingsStore
    )
    await model.start()
    model.snapshot?.currentUser.premiumType = 0

    #expect(await model.addComposerAttachments([exact, oversized], to: .channel))
    #expect(model.channelComposerAttachments.map(\.url) == [exact])
    let prompt = try #require(model.oversizedAttachmentPrompt)
    #expect(prompt.fileURL == oversized)
    #expect(prompt.discordLimit == DiscordAttachmentUploadPolicy.baseLimit)
    #expect(prompt.availableServices == [.catbox, .litterbox])
    #expect(await uploader.callCount == 0)

    #expect(prompt.stage == .compaction)
    model.skipAttachmentCompaction(prompt)
    let externalPrompt = try #require(model.oversizedAttachmentPrompt)
    #expect(externalPrompt.stage == .externalUpload)
    model.dismissOversizedAttachmentPrompt(id: prompt.id)
    #expect(model.oversizedAttachmentPrompt?.id == externalPrompt.id)
    model.updateDraft("look")
    model.uploadOversizedAttachment(externalPrompt, using: .catbox)
    #expect(await eventuallyOnMain { model.externalAttachmentUploadPresentation == nil })
    #expect(await uploader.callCount == 1)
    #expect(model.draft == "look https://files.catbox.moe/test.bin")
}

@MainActor
@Test func `repeated alert dismissal cannot skip the next oversized attachment`() async throws {
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: TypingTestProvider(),
        attachmentSettingsStore: AttachmentSettingsStore(preferences: SettingsPreferenceStore(defaults: InMemoryPreferences()))
    )
    await model.start()
    let channelID = try #require(model.selectedChannelID)
    let first = OversizedAttachmentPrompt(
        fileURL: URL(fileURLWithPath: "/tmp/first-oversized.bin"),
        fileSize: DiscordAttachmentUploadPolicy.baseLimit + 1,
        discordLimit: DiscordAttachmentUploadPolicy.baseLimit,
        premiumType: 0,
        destination: .channel,
        channelID: channelID
    )
    let second = OversizedAttachmentPrompt(
        fileURL: URL(fileURLWithPath: "/tmp/second-oversized.bin"),
        fileSize: DiscordAttachmentUploadPolicy.baseLimit + 1,
        discordLimit: DiscordAttachmentUploadPolicy.baseLimit,
        premiumType: 0,
        destination: .channel,
        channelID: channelID
    )
    model.oversizedAttachmentPrompt = first
    model.queuedOversizedAttachmentPrompts = [second]

    model.dismissOversizedAttachmentPrompt(id: first.id)
    model.dismissOversizedAttachmentPrompt(id: first.id)

    #expect(model.oversizedAttachmentPrompt?.id == second.id)
    #expect(model.queuedOversizedAttachmentPrompts.isEmpty)
}

@MainActor
@Test func `cancelled external upload cannot clear or populate its replacement`() async throws {
    let uploader = SequencedAttachmentUploadTestUploader()
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: TypingTestProvider(),
        externalAttachmentUploader: uploader,
        attachmentSettingsStore: AttachmentSettingsStore(preferences: SettingsPreferenceStore(defaults: InMemoryPreferences()))
    )
    await model.start()
    let channelID = try #require(model.selectedChannelID)
    let first = OversizedAttachmentPrompt(
        fileURL: URL(fileURLWithPath: "/tmp/first.bin"),
        fileSize: DiscordAttachmentUploadPolicy.baseLimit + 1,
        discordLimit: DiscordAttachmentUploadPolicy.baseLimit,
        premiumType: 0,
        destination: .channel,
        channelID: channelID
    )
    let second = OversizedAttachmentPrompt(
        fileURL: URL(fileURLWithPath: "/tmp/second.bin"),
        fileSize: DiscordAttachmentUploadPolicy.baseLimit + 1,
        discordLimit: DiscordAttachmentUploadPolicy.baseLimit,
        premiumType: 0,
        destination: .channel,
        channelID: channelID
    )
    model.oversizedAttachmentPrompt = first
    model.queuedOversizedAttachmentPrompts = [second]

    model.uploadOversizedAttachment(first, using: .catbox)
    #expect(await eventuallyUploadCallCount(1, from: uploader))
    model.cancelExternalAttachmentUpload()
    #expect(model.oversizedAttachmentPrompt?.fileURL == second.fileURL)

    model.uploadOversizedAttachment(second, using: .catbox)
    #expect(await eventuallyUploadCallCount(2, from: uploader))
    await uploader.release(
        call: 1,
        with: URL(string: "https://files.catbox.moe/first.bin")!
    )
    #expect(await eventuallyOnMain {
        model.externalAttachmentUploadPresentation?.fileName == "second.bin"
    })
    #expect(model.draft.isEmpty)

    await uploader.release(
        call: 2,
        with: URL(string: "https://files.catbox.moe/second.bin")!
    )
    #expect(await eventuallyOnMain { model.externalAttachmentUploadPresentation == nil })
    #expect(model.draft == "https://files.catbox.moe/second.bin")
}

@MainActor
@Test func `account reset invalidates an external upload result`() async throws {
    let uploader = SequencedAttachmentUploadTestUploader()
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: TypingTestProvider(),
        externalAttachmentUploader: uploader,
        attachmentSettingsStore: AttachmentSettingsStore(preferences: SettingsPreferenceStore(defaults: InMemoryPreferences()))
    )
    await model.start()
    let channelID = try #require(model.selectedChannelID)
    let prompt = OversizedAttachmentPrompt(
        fileURL: URL(fileURLWithPath: "/tmp/account-reset.bin"),
        fileSize: DiscordAttachmentUploadPolicy.baseLimit + 1,
        discordLimit: DiscordAttachmentUploadPolicy.baseLimit,
        premiumType: 0,
        destination: .channel,
        channelID: channelID
    )
    model.oversizedAttachmentPrompt = prompt
    model.uploadOversizedAttachment(prompt, using: .catbox)
    #expect(await eventuallyUploadCallCount(1, from: uploader))

    await model.resetAccountScopedLoadsAndForumState()
    await uploader.release(
        call: 1,
        with: URL(string: "https://files.catbox.moe/stale.bin")!
    )
    #expect(await eventuallyOnMain { model.externalAttachmentUploadTask == nil })
    #expect(model.externalAttachmentUploadPresentation == nil)
    #expect(model.draft.isEmpty)
}

@MainActor
@Test(arguments: AttachmentHandlingPolicy.allCases, AttachmentHandlingPolicy.allCases)
func oversizedAttachmentPolicies(compaction: AttachmentHandlingPolicy, external: AttachmentHandlingPolicy) async throws {
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
    model.attachmentSettings.compactionPolicy = compaction
    model.attachmentSettings.externalUploadPolicy = external
    #expect(await model.addComposerAttachments([file], to: .channel))
    if compaction == .ask {
        let prompt = try #require(model.oversizedAttachmentPrompt)
        #expect(prompt.stage == .compaction)
        #expect(await worker.calls == 0)
        model.compactOversizedAttachment(prompt)
    }
    await model.attachmentCompactionTask?.value
    #expect(await worker.calls == (compaction == .never ? 0 : 1))
    #expect(model.channelComposerAttachments.isEmpty)
    switch external {
    case .ask:
        let prompt = try #require(model.oversizedAttachmentPrompt)
        #expect(prompt.stage == .externalUpload)
        #expect((prompt.compactionOutcome != nil) == (compaction != .never))
        #expect(await uploader.callCount == 0)
    case .always:
        await model.externalAttachmentUploadTask?.value
        #expect(await uploader.callCount == 1)
        #expect(model.draft == "https://litter.catbox.moe/test.png")
    case .never:
        #expect(await uploader.callCount == 0)
        #expect(model.oversizedAttachmentPrompt == nil)
        #expect(model.errorMessage != nil)
    }
}

@MainActor
@Test func compactionFitsPreservesOriginalAndSkipsFilesWithinAccountLimit() async throws {
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
    #expect(model.attachmentFileSize(at: compacted) == DiscordAttachmentUploadPolicy.baseLimit)
    #expect(model.attachmentFileSize(at: oversized) == DiscordAttachmentUploadPolicy.baseLimit + 1)
    model.clearComposerAttachments(for: .channel)
    #expect(!FileManager.default.fileExists(atPath: compacted.path))
    #expect(!FileManager.default.fileExists(atPath: directory.path))
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

@Test func `external attachment hosts enforce size type and request contracts`() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sakuracord-host-contract-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("notes.txt")
    try Data("hello".utf8).write(to: file)
    let blocked = directory.appendingPathComponent("unsafe.jar")

    #expect(ExternalAttachmentHostingService.catbox.canUpload(
        fileURL: file,
        size: 200_000_000
    ))
    #expect(!ExternalAttachmentHostingService.catbox.canUpload(
        fileURL: file,
        size: 200_000_001
    ))
    #expect(ExternalAttachmentHostingService.litterbox.canUpload(
        fileURL: file,
        size: 1_000_000_000
    ))
    #expect(!ExternalAttachmentHostingService.litterbox.canUpload(
        fileURL: file,
        size: 1_000_000_001
    ))
    #expect(!ExternalAttachmentHostingService.litterbox.canUpload(fileURL: blocked, size: 1))

    let catboxBody = try CatboxAttachmentUploader.makeMultipartFile(
        sourceURL: file,
        service: .catbox,
        boundary: "test-boundary"
    )
    defer { try? FileManager.default.removeItem(at: catboxBody.deletingLastPathComponent()) }
    let catboxText = String(decoding: try Data(contentsOf: catboxBody), as: UTF8.self)
    #expect(catboxText.contains("name=\"reqtype\"\r\n\r\nfileupload"))
    #expect(catboxText.contains("name=\"fileToUpload\"; filename=\"notes.txt\""))
    #expect(!catboxText.contains("name=\"time\""))

    let litterboxBody = try CatboxAttachmentUploader.makeMultipartFile(
        sourceURL: file,
        service: .litterbox,
        boundary: "test-boundary"
    )
    defer { try? FileManager.default.removeItem(at: litterboxBody.deletingLastPathComponent()) }
    let litterboxText = String(decoding: try Data(contentsOf: litterboxBody), as: UTF8.self)
    #expect(litterboxText.contains("name=\"time\"\r\n\r\n24h"))
}

@MainActor
@Test func `composer paste prefers arbitrary files over their compatibility path text`() throws {
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
    textView.commandPasteboard = pasteboard
    var pastedURLs: [URL] = []
    textView.onPasteAttachments = { pastedURLs = $0 }
    textView.paste(nil)

    #expect(pastedURLs == [file])
    #expect(textView.string.isEmpty)
}

@MainActor
@Test func `composer paste materializes clipboard image data as a png attachment`() throws {
    let pasteboard = NSPasteboard(name: .init("sakuracord-paste-image-\(UUID().uuidString)"))
    defer { pasteboard.clearContents() }
    let image = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { bounds in
        NSColor.systemPink.setFill()
        bounds.fill()
        return true
    }
    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([image]))

    let url = try #require(ComposerPasteboardAttachments.urls(from: pasteboard).first)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    #expect(url.pathExtension == "png")
    #expect((try Data(contentsOf: url)).isEmpty == false)
    #expect(NSImage(contentsOf: url)?.isValid == true)
}

@MainActor
@Test func `promised attachment drops use isolated storage and publish successful files once`() throws {
    let firstDirectory = try ComposerPromisedFileDropView.makeReceivingDirectory()
    let secondDirectory = try ComposerPromisedFileDropView.makeReceivingDirectory()
    defer {
        try? FileManager.default.removeItem(at: firstDirectory)
        try? FileManager.default.removeItem(at: secondDirectory)
    }
    #expect(firstDirectory != secondDirectory)
    #expect(FileManager.default.fileExists(atPath: firstDirectory.path))
    #expect(FileManager.default.fileExists(atPath: secondDirectory.path))

    let screenshot = firstDirectory.appendingPathComponent("Screenshot.png")
    try Data("promised screenshot".utf8).write(to: screenshot)
    var completedBatch: ComposerPromisedFileBatch?
    let collector = ComposerPromisedFileCollector(
        expectedCount: 2,
        directory: firstDirectory
    ) {
        completedBatch = $0
    }
    collector.receive(url: screenshot, error: nil)
    #expect(completedBatch == nil)
    collector.receive(
        url: secondDirectory.appendingPathComponent("failed.png"),
        error: CocoaError(.fileReadUnknown)
    )
    #expect(completedBatch?.urls == [screenshot])
    #expect(completedBatch?.directory == firstDirectory)
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

    #expect(
        await model.sendAttachmentsImmediately(
            [ForumPostAttachment(url: instant)],
            to: .channel
        )
    )
    #expect(model.draft == "keep editing this")
    #expect(model.channelComposerAttachments.map(\.url) == [staged])
    #expect(model.messages.last?.attachments.map(\.url) == [instant])
    #expect(await provider.sendCount == 1)
}

@MainActor
@Test(arguments: [false, true])
func `composer attachment controls preserve edits and spoiler state`(anonymisesFileNames: Bool) async throws {
    let store = PrivacySafetySettingsStore(preferences: SettingsPreferenceStore(defaults: InMemoryPreferences()))
    var privacy = store.load()
    privacy.anonymisesFileNames = anonymisesFileNames
    privacy.removesMediaMetadata = false // This test edits names of a synthetic, nonexistent file.
    store.save(privacy)
    let model = AppModel(launchMode: .offlineTesting, provider: TypingTestProvider(), privacySafetySettingsStore: store)
    await model.start()
    let url = URL(fileURLWithPath: "/tmp/sakuracord-editable-attachment.png")
    await model.addComposerAttachments([url], to: .channel)
    var attachment = try #require(model.channelComposerAttachments.first)
    #expect(attachment.isFilenameAnonymised == anonymisesFileNames)
    if anonymisesFileNames {
        #expect(attachment.filename != url.lastPathComponent)
        #expect((attachment.filename as NSString).pathExtension == "png")
        model.updateComposerAttachment(attachment, in: .channel)
        #expect(model.channelComposerAttachments.first?.filename == attachment.filename)
        attachment.setFilenameAnonymised(false)
        model.updateComposerAttachment(attachment, in: .channel)
        #expect(model.channelComposerAttachments.first?.filename == url.lastPathComponent)
        #expect(model.channelComposerAttachments.first?.isFilenameAnonymised == false)
        attachment.setFilenameAnonymised(true)
        model.updateComposerAttachment(attachment, in: .channel)
        #expect(model.channelComposerAttachments.first?.filename == attachment.filename)
    }

    model.toggleComposerAttachmentSpoiler(attachment.id, in: .channel)
    #expect(model.channelComposerAttachments.first?.isSpoiler == true)

    attachment.rename("renamed.png")
    attachment.description = "A useful description"
    attachment.isSpoiler = true
    model.updateComposerAttachment(attachment, in: .channel)
    #expect(model.channelComposerAttachments.first?.filename == "renamed.png")
    #expect(model.channelComposerAttachments.first?.description == "A useful description")
    #expect(model.channelComposerAttachments.first?.isSpoiler == true)
}

@MainActor
@Test func `window attachment drops reject non-message channel surfaces`() async {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    #expect(model.isComposerDropEligible(.channel))

    model.selectedChannelID = ChannelID(rawValue: 11)
    #expect(!model.isComposerDropEligible(.channel))
    #expect(
        !(await model.addComposerAttachments(
            [URL(fileURLWithPath: "/tmp/not-for-voice")],
            to: .channel
        ))
    )
}

@Test func `composer insertion repairs stale selections and inserts emoji without spaces`() {
    let inserted = ComposerDraftEditing.insert(
        "✨", into: "hello", replacing: NSRange(location: 99, length: 4)
    )
    #expect(inserted == ComposerDraftEdit(
        text: "hello✨",
        selection: NSRange(location: 6, length: 0)
    ))

    let emoji = ComposerDraftEditing.insertCustomEmoji(
        "<:wave:123>", into: "hello world", replacing: NSRange(location: 5, length: 0)
    )
    #expect(emoji.text == "hello<:wave:123> world")
    #expect(emoji.selection.location == "hello<:wave:123>".utf16.count)
}

@MainActor
@Test func `colon emoji completion waits for two characters and recognizes a closing colon`() throws {
    #expect(ColonAutocompleteContext(text: ":w", selection: nil) == nil)
    let open = try #require(ColonAutocompleteContext(text: "hello :wa", selection: nil))
    #expect(open.query == "wa")
    #expect(open.range == NSRange(location: 6, length: 3))

    let closed = try #require(ClosedColonAutocompleteContext(text: "hello :wave:", selection: nil))
    #expect(closed.query == "wave")
    #expect(closed.range == NSRange(location: 6, length: 6))
}

@MainActor
@Test func `emoji completion includes other guilds and preserves linked image fallback`() throws {
    let currentGuild = GuildID(rawValue: 10)
    let otherGuild = GuildID(rawValue: 20)
    let current = DiscordEmoji(id: "100", name: "wave", guildID: currentGuild)
    let other = DiscordEmoji(id: "200", name: "wave", guildID: otherGuild)
    let suggestions = ColonAutocompleteSuggestionFactory.suggestions(
        query: "wave",
        customEmojis: [current, other],
        customValue: { emoji in
            emoji.guildID == currentGuild ? emoji.messageToken : emoji.linkedImageMarkdown
        },
        customSource: { emoji in emoji.guildID == currentGuild ? "Current Server" : "Other Server" }
    )
    let custom = suggestions.filter { $0.customEmoji != nil }

    #expect(custom.map(\.customEmoji?.id) == ["100", "200"])
    #expect(custom[0].value == current.messageToken)
    #expect(custom[1].value == other.linkedImageMarkdown)
    #expect(custom.map(\.detail) == [":wave:", ":wave~1:"])
    #expect(custom.map(\.source) == ["Current Server", "Other Server"])
    #expect(custom[0].matchesCompletionName("WAVE"))
}

@Test func `emoji permissions preserve message fallbacks and profile entitlement locks`() {
    let currentGuild = GuildID(rawValue: 10)
    let otherGuild = GuildID(rawValue: 20)
    let localStatic = DiscordEmoji(id: "100", name: "local", guildID: currentGuild)
    let remoteStatic = DiscordEmoji(id: "200", name: "remote", guildID: otherGuild)
    let localAnimated = DiscordEmoji(
        id: "300",
        name: "local_dance",
        isAnimated: true,
        guildID: currentGuild
    )
    let remoteAnimated = DiscordEmoji(
        id: "400",
        name: "remote_dance",
        isAnimated: true,
        guildID: otherGuild
    )

    #expect(DiscordEmojiPermissionPolicy.composerText(
        for: localStatic, currentGuildID: currentGuild, premiumType: 0
    ) == localStatic.messageToken)
    #expect(DiscordEmojiPermissionPolicy.composerText(
        for: remoteStatic, currentGuildID: currentGuild, premiumType: 0
    ) == remoteStatic.linkedImageMarkdown)
    #expect(DiscordEmojiPermissionPolicy.composerText(
        for: localAnimated, currentGuildID: currentGuild, premiumType: 0
    ) == localAnimated.linkedImageMarkdown)
    #expect(DiscordEmojiPermissionPolicy.composerText(
        for: remoteAnimated, currentGuildID: currentGuild, premiumType: 0
    ) == remoteAnimated.linkedImageMarkdown)
    #expect(DiscordEmojiPermissionPolicy.composerText(
        for: remoteStatic, currentGuildID: currentGuild, premiumType: 0, fakeNitroEnabled: false
    ) == ":remote:")
    #expect(DiscordEmojiPermissionPolicy.composerText(
        for: localStatic, currentGuildID: currentGuild, premiumType: 0, fakeNitroEnabled: false
    ) == localStatic.messageToken)
    #expect(localAnimated.linkedImageMarkdown.contains(".gif?"))
    for useCase in [DiscordEmojiUseCase.profile, .customStatus] {
        #expect(DiscordEmojiPermissionPolicy.canShow(remoteStatic, for: useCase, premiumType: 0))
        #expect(DiscordEmojiPermissionPolicy.isPremiumLocked(remoteStatic, for: useCase, premiumType: 0))
        #expect(DiscordEmojiPermissionPolicy.isPremiumLocked(localStatic, for: useCase, premiumType: 0))
        #expect(!DiscordEmojiPermissionPolicy.isPremiumLocked(remoteAnimated, for: useCase, premiumType: 2))
    }
    let managed = DiscordEmoji(id: "500", name: "managed", guildID: otherGuild, isManaged: true)
    #expect(!DiscordEmojiPermissionPolicy.isPremiumLocked(managed, for: .profile, premiumType: 0))
    #expect(DiscordEmojiPermissionPolicy.isPremiumLocked(managed, for: .customStatus, premiumType: 0))

    for premiumType in 1 ... 3 {
        #expect(DiscordEmojiPermissionPolicy.composerText(
            for: remoteStatic, currentGuildID: currentGuild, premiumType: premiumType
        ) == remoteStatic.messageToken)
        #expect(DiscordEmojiPermissionPolicy.composerText(
            for: localAnimated, currentGuildID: currentGuild, premiumType: premiumType
        ) == localAnimated.messageToken)
    }
}

@Test func `sticker sending chooses exactly one native or FakeNitro route`() {
    let currentGuild = GuildID(rawValue: 10)
    let local = MessageSticker(id: "100", name: "Local", guildID: currentGuild)
    let remote = MessageSticker(
        id: "200",
        name: "Remote",
        guildID: GuildID(rawValue: 20)
    )
    let standard = MessageSticker(id: "300", name: "Standard")

    #expect(StickerSendPolicy.route(
        for: local, currentGuildID: currentGuild, premiumType: 0
    ) == .native)
    #expect(StickerSendPolicy.route(
        for: standard, currentGuildID: currentGuild, premiumType: 0
    ) == .native)
    #expect(StickerSendPolicy.route(
        for: remote, currentGuildID: currentGuild, premiumType: 0
    ) == .fakeNitroUpload)
    #expect(StickerSendPolicy.route(
        for: remote, currentGuildID: currentGuild, premiumType: 2
    ) == .native)
    #expect(StickerSendPolicy.route(
        for: remote, currentGuildID: currentGuild, premiumType: 0, fakeNitroEnabled: false
    ) == nil)
    #expect(StickerSendPolicy.route(
        for: local, currentGuildID: currentGuild, premiumType: 0, fakeNitroEnabled: false
    ) == .native)
    #expect(StickerSendPolicy.route(
        for: remote, currentGuildID: currentGuild, premiumType: 2, fakeNitroEnabled: false
    ) == .native)
}

@Test func `reaction emoji permissions filter new choices and allow existing reactions`() {
    let currentGuild = GuildID(rawValue: 10)
    let otherGuild = GuildID(rawValue: 20)
    let localStatic = DiscordEmoji(id: "100", name: "local", guildID: currentGuild)
    let remoteStatic = DiscordEmoji(id: "200", name: "remote", guildID: otherGuild)
    let localAnimated = DiscordEmoji(
        id: "300", name: "dance", isAnimated: true, guildID: currentGuild
    )

    #expect(DiscordEmojiPermissionPolicy.canShow(
        localStatic, for: .reaction(guildID: currentGuild), premiumType: 0
    ))
    #expect(!DiscordEmojiPermissionPolicy.canShow(
        remoteStatic, for: .reaction(guildID: currentGuild), premiumType: 0
    ))
    #expect(!DiscordEmojiPermissionPolicy.canShow(
        localAnimated, for: .reaction(guildID: currentGuild), premiumType: 0
    ))
    #expect(DiscordEmojiPermissionPolicy.canShow(
        localAnimated, for: .reaction(guildID: currentGuild), premiumType: 2
    ))
    #expect(!DiscordEmojiPermissionPolicy.canShowGuild(
        otherGuild, for: .reaction(guildID: currentGuild), premiumType: 0
    ))
    #expect(DiscordEmojiPermissionPolicy.canShowGuild(
        otherGuild, for: .reaction(guildID: currentGuild), premiumType: 2
    ))

    #expect(DiscordEmojiPermissionPolicy.canToggleReaction(
        "👍", existingReactions: [], currentGuildEmojis: [localStatic, localAnimated], premiumType: 0
    ))
    #expect(DiscordEmojiPermissionPolicy.canToggleReaction(
        localStatic.messageToken,
        existingReactions: [],
        currentGuildEmojis: [localStatic, localAnimated],
        premiumType: 0
    ))
    #expect(!DiscordEmojiPermissionPolicy.canToggleReaction(
        remoteStatic.messageToken,
        existingReactions: [],
        currentGuildEmojis: [localStatic, localAnimated],
        premiumType: 0
    ))
    #expect(!DiscordEmojiPermissionPolicy.canToggleReaction(
        localAnimated.messageToken,
        existingReactions: [],
        currentGuildEmojis: [localStatic, localAnimated],
        premiumType: 0
    ))
    #expect(DiscordEmojiPermissionPolicy.canToggleReaction(
        localAnimated.messageToken,
        existingReactions: [],
        currentGuildEmojis: [localStatic, localAnimated],
        premiumType: 2
    ))
    #expect(DiscordEmojiPermissionPolicy.canToggleReaction(
        remoteStatic.messageToken,
        existingReactions: [
            Reaction(emoji: remoteStatic.messageToken, count: 1)
        ],
        currentGuildEmojis: [localStatic, localAnimated],
        premiumType: 0
    ))
    #expect(DiscordEmojiPermissionPolicy.canToggleReaction(
        localAnimated.messageToken,
        existingReactions: [Reaction(emoji: localAnimated.messageToken, count: 1)],
        currentGuildEmojis: [localStatic, localAnimated],
        premiumType: 0
    ))
}

@MainActor
@Test func `custom emoji catalog follows server order and disambiguates duplicate names`() throws {
    let firstGuild = GuildID(rawValue: 10)
    let secondGuild = GuildID(rawValue: 20)
    let first = DiscordEmoji(id: "100", name: "catscared", guildID: firstGuild)
    let second = DiscordEmoji(id: "200", name: "catscared", guildID: secondGuild)
    let other = DiscordEmoji(id: "201", name: "scales", guildID: secondGuild)
    let ordered = DiscordCustomEmojiCatalog.ordered(
        emojisByGuild: [firstGuild: [first], secondGuild: [second, other]],
        guildOrder: [secondGuild, firstGuild]
    )

    #expect(ordered.map(\.id) == ["200", "201", "100"])
    let suggestions = ColonAutocompleteSuggestionFactory.suggestions(
        query: "catscared",
        customEmojis: ordered,
        customValue: (\.messageToken)
    ).filter { $0.customEmoji != nil }
    #expect(suggestions.map(\.detail) == [":catscared:", ":catscared~1:"])
    #expect(suggestions.last?.value == first.messageToken)
    #expect(suggestions.last?.matchesCompletionName("catscared~1") == true)

    let localURL = URL(fileURLWithPath: "/tmp/catscared.webp")
    let local = DiscordEmoji(
        id: "300",
        name: "local",
        guildID: firstGuild,
        assetURL: localURL
    )
    let imageURLs = DiscordCustomEmojiCatalog.imageURLsByID(from: [first, local])
    #expect(imageURLs["100"] == first.imageURL)
    #expect(imageURLs["300"] == localURL)
    #expect(imageURLs["missing"] == nil)
    var animated = first
    animated.isAnimated = true
    let changedURLs = DiscordCustomEmojiCatalog.imageURLsByID(from: [first, animated, local])
    #expect(changedURLs["100"] == animated.imageURL)
    #expect(imageURLs["100"] == first.imageURL)
    #expect(changedURLs.differs(from: imageURLs, cancellationCheck: { false }) == true)
    #expect(changedURLs.differs(from: changedURLs, cancellationCheck: { true }) == nil)

    let prepared = try #require(DiscordCustomEmojiCatalog.prepare(
        emojisByGuild: [
            firstGuild: [first, local],
            secondGuild: [second, other]
        ],
        guildOrder: [secondGuild, firstGuild],
        previousOrderedEmojis: [],
        previousImageURLsByID: [:]
    ))
    let preparedOrder = try #require(prepared.orderedEmojis)
    let preparedURLs = try #require(prepared.imageURLsByID)
    #expect(preparedOrder.map(\.id) == ["200", "201", "100", "300"])
    #expect(preparedURLs["300"] == localURL)

    let unchanged = try #require(DiscordCustomEmojiCatalog.prepare(
        emojisByGuild: [
            firstGuild: [first, local],
            secondGuild: [second, other]
        ],
        guildOrder: [secondGuild, firstGuild],
        previousOrderedEmojis: preparedOrder,
        previousImageURLsByID: preparedURLs
    ))
    #expect(unchanged.orderedEmojis == nil)
    #expect(unchanged.imageURLsByID == nil)
    #expect(DiscordCustomEmojiCatalog.prepare(
        emojisByGuild: [firstGuild: [first]],
        guildOrder: [firstGuild],
        previousOrderedEmojis: [],
        previousImageURLsByID: [:],
        cancellationCheck: { true }
    ) == nil)
}

@MainActor
@Test func `native emoji autocomplete searches aliases but displays the primary shortcode`() {
    #expect(DiscordEmojiSearchAliases.english["100"]?.contains("score") == true)
    let suggestions = NativeEmojiAutocompleteCatalog.search("fa")

    #expect(!suggestions.isEmpty)
    #expect(suggestions.contains { $0.shortcode == "alien" })
    #expect(NativeEmojiAutocompleteCatalog.search("sc").contains { $0.shortcode == "100" })
    #expect(suggestions.allSatisfy { suggestion in
        suggestion.completionNames.contains {
            EmojiSearchMatcher.autocompleteNormalized($0).contains("fa")
        }
    })
}

@MainActor
@Test func `emoji completion matches authenticated Discord visible composer order`() {
    let guildID = GuildID(rawValue: 30)
    let customNames = [
        "catscared", "SClongcat1", "SClongcat2", "SClongcat3",
        "DiscordKit", "EVIL_scared",
    ]
    let customEmojis = customNames.enumerated().map { offset, name in
        DiscordEmoji(id: String(900 + offset), name: name, guildID: guildID)
    }
    let suggestions = ColonAutocompleteSuggestionFactory.suggestions(
        query: "sc",
        customEmojis: customEmojis,
        customValue: (\.messageToken),
        customSource: { _ in "Test Server" },
        discordFavoriteKeys: ["900"],
        discordSettingsAreLoaded: true
    )

    #expect(Array(suggestions.prefix(21).map(\.detail)) == [
        ":catscared:", ":SClongcat1:", ":SClongcat2:", ":SClongcat3:",
        ":scales:", ":scarf:", ":school:", ":school_satchel:", ":scientist:",
        ":scissors:", ":scooter:", ":scorpion:", ":scorpius:", ":scotland:",
        ":scream:", ":scream_cat:", ":screwdriver:", ":scroll:", ":100:",
        ":DiscordKit:", ":EVIL_scared:",
    ])
    let native = suggestions.filter { $0.customEmoji == nil }
    #expect(Array(native.prefix(15).map(\.detail)) == [
        ":scales:", ":scarf:", ":school:", ":school_satchel:", ":scientist:",
        ":scissors:", ":scooter:", ":scorpion:", ":scorpius:", ":scotland:",
        ":scream:", ":scream_cat:", ":screwdriver:", ":scroll:", ":100:",
    ])
    #expect(!native.contains { $0.detail == ":sc:" })
    #expect(NativeEmojiAutocompleteCatalog.search("sey").contains {
        $0.value == "🇸🇨" && $0.rankingName == "seychelles"
    })
}

@MainActor
@Test func `emoji completion hoists account favorites but ignores local usage order`() {
    let guildID = GuildID(rawValue: 30)
    let custom = DiscordEmoji(id: "900", name: "catscared", guildID: guildID)
    let suggestions = ColonAutocompleteSuggestionFactory.suggestions(
        query: "sc",
        customEmojis: [custom],
        customValue: (\.messageToken),
        discordFavoriteKeys: ["900"],
        usageCounts: ["unicode:🙀": 10_000]
    )

    #expect(suggestions.first?.detail == ":catscared:")
    let native = suggestions.filter { $0.customEmoji == nil }
    #expect(native.first?.detail == ":scales:")
}

@MainActor
@Test func `live emoji settings event replaces account favorites`() {
    let model = AppModel(launchMode: .offlineTesting)
    model.discordFavoriteEmojiKeys = ["old"]
    model.hasLoadedDiscordEmojiSettings = false

    model.consumeImmediately(.emojiUserSettingsChanged(EmojiUserSettings(
        favoriteKeys: ["new"]
    )))

    #expect(model.discordFavoriteEmojiKeys == ["new"])
    #expect(model.hasLoadedDiscordEmojiSettings)
}

@MainActor
@Test func `mention tokens are atomic attachments and serialize exact raw text`() throws {
    let userID = UserID(rawValue: 123)
    let roleID = RoleID(rawValue: 456)
    let channelID = ChannelID(rawValue: 789)
    let source = "hi <@123> <@&456> <#789>"
    let values: [String: MentionPresentation] = [
        "<@123>": MentionPresentation(
            rawToken: "<@123>", label: "@Ari", target: .user(userID)
        ),
        "<@&456>": MentionPresentation(
            rawToken: "<@&456>", label: "@Design", target: .role(roleID), colorHex: 0xff5599
        ),
        "<#789>": MentionPresentation(
            rawToken: "<#789>", label: "#general", target: .channel(channelID)
        ),
    ]
    let attributed = ComposerEmojiAttributedText.make(source, mentionPresentations: values)
    var attachmentCount = 0
    attributed.enumerateAttribute(
        .discordMentionToken,
        in: NSRange(location: 0, length: attributed.length)
    ) { token, _, _ in
        if token != nil { attachmentCount += 1 }
    }

    #expect(attachmentCount == 3)
    #expect(ComposerEmojiAttributedText.serialize(attributed) == source)
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
@Test func `pasted discord message link becomes an atomic mention and serializes unchanged`() throws {
    let link = "https://discord.com/channels/100/200/300"
    let presentation = MentionPresentation(
        rawToken: link,
        label: "# general ›",
        target: .message(
            guildID: GuildID(rawValue: 100),
            channelID: ChannelID(rawValue: 200),
            messageID: MessageID(rawValue: 300)
        )
    )

    let attributed = ComposerEmojiAttributedText.make(
        "Open \(link)",
        mentionPresentations: [link: presentation]
    )
    let attachment = try #require(attributed.attribute(
        .attachment,
        at: attributed.length - 1,
        effectiveRange: nil
    ) as? MentionTextAttachment)

    #expect(attachment.presentation.target == presentation.target)
    #expect(ComposerEmojiAttributedText.serialize(attributed) == "Open \(link)")
}

@MainActor
@Test func `pasted discord forum post link becomes an atomic post mention`() throws {
    let link = "https://discord.com/channels/100/200"
    let mention = try #require(RenderedMention(rawToken: link))
    let presentation = MentionPresentation(
        rawToken: link,
        label: "A forum post",
        target: .linkedChannel(
            guildID: GuildID(rawValue: 100),
            channelID: ChannelID(rawValue: 200)
        ),
        systemImage: ChannelIconPresentation.forumPostSystemImage
    )
    let attributed = ComposerEmojiAttributedText.make(
        "Open \(link)",
        mentionPresentations: [link: presentation]
    )
    let attachment = try #require(attributed.attribute(
        .attachment,
        at: attributed.length - 1,
        effectiveRange: nil
    ) as? MentionTextAttachment)

    #expect(mention.kind == .channelLink)
    #expect(attachment.presentation.systemImage == "bubble.left.fill")
    #expect(ComposerEmojiAttributedText.serialize(attributed) == "Open \(link)")
}

@MainActor
@Test func `pasted message link refreshes its fallback attachment when channel data resolves`() {
    let link = "https://discord.com/channels/100/200/300"
    let fallback = ComposerEmojiAttributedText.make(link)
    let resolved = MentionPresentation(
        rawToken: link,
        label: "# general ›",
        target: .message(
            guildID: GuildID(rawValue: 100),
            channelID: ChannelID(rawValue: 200),
            messageID: MessageID(rawValue: 300)
        )
    )

    #expect(!ComposerEmojiAttributedText.usesCurrentMentionPresentations(
        fallback,
        mentionPresentations: [link: resolved]
    ))
    let refreshed = ComposerEmojiAttributedText.make(
        link,
        mentionPresentations: [link: resolved]
    )
    #expect(ComposerEmojiAttributedText.usesCurrentMentionPresentations(
        refreshed,
        mentionPresentations: [link: resolved]
    ))
}

@MainActor
@Test func `channel mention only includes server for a proven cross server target`() async throws {
    let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
    await model.start()

    let sourceChannel = try #require(model.selectedChannel)
    let sameGuildChannel = try #require(model.snapshot?.channels.first {
        $0.guildID == sourceChannel.guildID && $0.id != sourceChannel.id
    })
    let crossGuildChannel = try #require(model.snapshot?.channels.first {
        $0.guildID != nil && $0.guildID != sourceChannel.guildID
    })
    let message = Message(
        id: MessageID(rawValue: 999),
        channelID: sourceChannel.id,
        author: try #require(model.snapshot?.currentUser),
        content: "",
        guildID: nil
    )
    let resolver = MessageMentionResolver(model: model, message: message)
    let sameMention = try #require(RenderedMention(rawToken: "<#\(sameGuildChannel.id)>"))
    let crossMention = try #require(RenderedMention(rawToken: "<#\(crossGuildChannel.id)>"))
    let crossGuildID = try #require(crossGuildChannel.guildID)
    let crossGuildName = try #require(model.serverRailGuildsByID[crossGuildID]).name

    #expect(resolver.presentation(sameMention).label == sameGuildChannel.name)
    #expect(
        resolver.presentation(sameMention).systemImage
            == ChannelIconPresentation.systemImage(for: sameGuildChannel.kind, isHidden: false)
    )
    #expect(
        resolver.presentation(crossMention).label
            == "\(crossGuildName) / \(crossGuildChannel.name)"
    )
    model.snapshot?.channels.reverse()
    let targetIndex = try #require(model.snapshot?.channels.firstIndex { $0.id == crossGuildChannel.id })
    model.snapshot?.channels[targetIndex].name = "renamed-channel"
    #expect(resolver.presentation(crossMention).label == "\(crossGuildName) / renamed-channel")
    model.snapshot?.channels.remove(at: targetIndex)
    #expect(resolver.presentation(crossMention).label == "unknown-channel")
    model.visibleChannels.append(crossGuildChannel)
    #expect(resolver.presentation(crossMention).label == "\(crossGuildName) / \(crossGuildChannel.name)")
}

@MainActor
@Test func `message link navigation selects and publishes the exact message target`() async throws {
    let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
    await model.start()

    let channel = try #require(model.snapshot?.channels.first { $0.id == ChannelID(rawValue: 200) })
    let target = MessageID(rawValue: 1001)
    model.navigate(to: channel.guildID, channelID: channel.id, messageID: target)

    #expect(await eventuallyOnMain {
        model.messageNavigationRequest?.channelID == channel.id
            && model.messageNavigationRequest?.messageID == target
    })
}

@MainActor
@Test func `notification deep link navigates within its exact account channel and message`() async
    throws
{
    let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
    await model.start()

    let channel = try #require(model.snapshot?.channels.first { $0.id == ChannelID(rawValue: 200) })
    let target = MessageID(rawValue: 1001)
    await model.navigate(
        from: NotificationDeepLink(
            accountID: "offline",
            guildID: channel.guildID,
            channelID: channel.id,
            messageID: target
        )
    )

    #expect(await eventuallyOnMain {
        model.readState.accountID == "offline"
            && model.selectedGuildID == channel.guildID
            && model.selectedChannelID == channel.id
            && model.messageNavigationRequest?.channelID == channel.id
            && model.messageNavigationRequest?.messageID == target
    })
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

    let didNavigate = await eventuallyOnMain {
        model.readState.accountID == "target-account"
            && model.selectedGuildID == expectedGuildID
            && model.selectedChannelID == expectedChannelID
            && model.messageNavigationRequest?.channelID == expectedChannelID
            && model.messageNavigationRequest?.messageID == target
    }
    #expect(didNavigate)
}

@MainActor
@Test func `mention autocomplete opens immediately and scopes the replacement`() throws {
    let members = try #require(MentionAutocompleteContext(text: "hello @", selection: nil))
    #expect(members.kind == .member)
    #expect(members.query.isEmpty)
    #expect(members.range == NSRange(location: 6, length: 1))

    let channels = try #require(MentionAutocompleteContext(text: "go #gen", selection: nil))
    #expect(channels.kind == .channel)
    #expect(channels.query == "gen")
    #expect(channels.range == NSRange(location: 3, length: 4))
}

@MainActor
@Test func `member autocomplete ranks prefixes before fuzzy store order then reserves roles`() {
    func member(_ id: UInt64, _ displayName: String, _ username: String) -> Member {
        Member(
            user: User(id: UserID(rawValue: id), username: username, displayName: displayName),
            roleName: "Member",
            status: .offline
        )
    }

    let fluffy = member(1, "fluffy wizkers", "f1uffi3r_wizk3rrz")
    let kitten = member(2, "cute (and smart) kitten", "theunfunny_clown")
    let yawortsa = member(3, "yawortsa", "yawortsa")
    let giveaway = member(4, "GiveawayBot", "GiveawayBot")
    let teenarazzi = member(5, "Teenarazzi Awards", "Teenarazzi Awards")
    let idk = member(6, "Idk what my username should be", "furby2010")
    let raph = member(7, "Raphawouel", "raph9367_89144")
    let recentMessages = [
        Message(id: MessageID(rawValue: 10), channelID: ChannelID(rawValue: 20), author: idk.user, content: "oldest"),
        Message(id: MessageID(rawValue: 11), channelID: ChannelID(rawValue: 20), author: teenarazzi.user, content: "older"),
        Message(id: MessageID(rawValue: 12), channelID: ChannelID(rawValue: 20), author: giveaway.user, content: "older"),
        Message(id: MessageID(rawValue: 13), channelID: ChannelID(rawValue: 20), author: raph.user, content: "older"),
        Message(id: MessageID(rawValue: 14), channelID: ChannelID(rawValue: 20), author: yawortsa.user, content: "older"),
        Message(id: MessageID(rawValue: 15), channelID: ChannelID(rawValue: 20), author: kitten.user, content: "older"),
        Message(id: MessageID(rawValue: 16), channelID: ChannelID(rawValue: 20), author: fluffy.user, content: "newest"),
    ]
    let roles = [
        GuildRole(
            id: RoleID(rawValue: 30), name: "Yellow", position: 1, isMentionable: false
        ),
        GuildRole(id: RoleID(rawValue: 31), name: "White", position: 3),
        GuildRole(id: RoleID(rawValue: 32), name: "Giveaway Ping", position: 2),
    ]

    let suggestions = MentionAutocompleteSuggestionFactory.memberSuggestions(
        query: "w",
        recentMessages: recentMessages,
        localMembers: [yawortsa, giveaway, teenarazzi, kitten, fluffy, idk, raph],
        remoteMembers: [fluffy, kitten, yawortsa, raph, giveaway, teenarazzi, idk],
        roles: roles,
        canMentionNonMentionableRoles: true
    )

    #expect(suggestions.map(\.title) == [
        "fluffy wizkers", "cute (and smart) kitten", "yawortsa", "Raphawouel",
        "GiveawayBot", "Teenarazzi Awards", "Idk what my username should be",
        "@White", "@Giveaway Ping", "@Yellow",
    ])
    #expect(suggestions.prefix(7).allSatisfy {
        if case .user = $0.target { true } else { false }
    })
    #expect(suggestions.suffix(3).allSatisfy {
        if case .role = $0.target { true } else { false }
    })
    #expect(MentionAutocompleteSuggestionFactory.memberHeading(query: "w") == "MEMBERS MATCHING @W")
}

@MainActor
@Test func `nonempty remote member search narrows stale local candidates`() {
    func member(_ id: UInt64, _ name: String) -> Member {
        Member(
            user: User(id: UserID(rawValue: id), username: name, displayName: name),
            roleName: "Member",
            status: .offline
        )
    }
    let yawortsa = member(1, "yawortsa")
    let evil = Member(
        user: User(
            id: UserID(rawValue: 2),
            username: "theunfunny_clown",
            displayName: "evil stupid cat"
        ),
        roleName: "Member",
        status: .offline
    )
    let staleFluffy = member(3, "fluffy wizkers")

    let suggestions = MentionAutocompleteSuggestionFactory.memberSuggestions(
        query: "w",
        recentMessages: [],
        localMembers: [yawortsa, evil, staleFluffy],
        remoteMembers: [yawortsa, evil],
        roles: []
    )

    #expect(suggestions.map(\.title) == ["yawortsa", "evil stupid cat"])
}

@MainActor
@Test func `empty member autocomplete uses recent authors up to the shared result limit before roles`() {
    let members = (1 ... 6).map { id in
        Member(
            user: User(
                id: UserID(rawValue: UInt64(id)),
                username: "user\(id)",
                displayName: "Member \(id)"
            ),
            roleName: "Member",
            status: .offline
        )
    }
    let messages = members.enumerated().map { index, member in
        Message(
            id: MessageID(rawValue: UInt64(index + 1)),
            channelID: ChannelID(rawValue: 20),
            author: member.user,
            content: "message"
        )
    }
    let role = GuildRole(id: RoleID(rawValue: 40), name: "Access", position: 1)

    let suggestions = MentionAutocompleteSuggestionFactory.memberSuggestions(
        query: "",
        recentMessages: messages,
        localMembers: members,
        remoteMembers: [],
        roles: [role]
    )

    #expect(suggestions.map(\.title) == [
        "Member 6", "Member 5", "Member 4", "Member 3", "Member 2", "Member 1", "@Access",
    ])
    #expect(MentionAutocompleteSuggestionFactory.memberHeading(query: "") == "MEMBERS")
}

@MainActor
@Test func `role autocomplete uses match sorter ranks and alphabetical ties`() {
    let roles = [
        GuildRole(id: RoleID(rawValue: 1), name: "Yellow", position: 100),
        GuildRole(id: RoleID(rawValue: 2), name: "Giveaway Ping", position: 200),
        GuildRole(id: RoleID(rawValue: 3), name: "White", position: 1),
        GuildRole(id: RoleID(rawValue: 4), name: "@everyone", position: 999),
    ]

    let suggestions = MentionAutocompleteSuggestionFactory.memberSuggestions(
        query: "w",
        recentMessages: [],
        localMembers: [],
        remoteMembers: [],
        roles: roles
    )

    #expect(suggestions.map(\.title) == ["@White", "@Giveaway Ping", "@Yellow"])
}

@MainActor
@Test func `member autocomplete matches a global name behind a guild nickname and only exact snowflakes`() {
    let member = Member(
        user: User(
            id: UserID(rawValue: 123),
            username: "account_name",
            displayName: "Guild Nickname"
        ),
        roleName: "Member",
        status: .offline,
        globalDisplayName: "World Traveler"
    )

    let globalName = MentionAutocompleteSuggestionFactory.memberSuggestions(
        query: "world",
        recentMessages: [],
        localMembers: [member],
        remoteMembers: [],
        roles: []
    )
    #expect(globalName.map(\.title) == ["Guild Nickname"])

    let partialSnowflake = MentionAutocompleteSuggestionFactory.memberSuggestions(
        query: "12",
        recentMessages: [],
        localMembers: [member],
        remoteMembers: [],
        roles: []
    )
    #expect(partialSnowflake.isEmpty)

    let exactSnowflake = MentionAutocompleteSuggestionFactory.memberSuggestions(
        query: "123",
        recentMessages: [],
        localMembers: [member],
        remoteMembers: [],
        roles: []
    )
    #expect(exactSnowflake.map(\.title) == ["Guild Nickname"])
}

@MainActor
@Test func `message mention labels prefer guild member display names`() async throws {
    let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
    await model.start()

    let member = try #require(model.members.first)
    let channelID = try #require(model.selectedChannelID)
    let globalUser = User(
        id: member.id,
        username: member.user.username,
        displayName: "Global Display Name"
    )
    let rawToken = "<@\(member.id.rawValue)>"
    let mention = try #require(RenderedMention(rawToken: rawToken))
    let message = Message(
        id: MessageID(rawValue: 987_654),
        channelID: channelID,
        author: model.snapshot?.currentUser ?? globalUser,
        content: rawToken,
        guildID: model.selectedGuildID,
        mentionedUsers: [globalUser]
    )

    let presentation = MessageMentionResolver(model: model, message: message).presentation(mention)
    #expect(presentation.label == "@\(member.user.displayName)")
    #expect(presentation.label != "@Global Display Name")
}

@MainActor
@Test func `mention media discovery only returns user avatars`() throws {
    let model = AppModel(launchMode: .offlineTesting)
    let userID = UserID(rawValue: 7_001)
    let userAvatarURL = try #require(
        URL(string: "https://cdn.example/user-avatar.png")
    )
    let guildAvatarURL = try #require(
        URL(string: "https://cdn.example/guild-avatar.png")
    )
    let member = Member(
        user: User(
            id: userID,
            username: "avatar-user",
            displayName: "Avatar User",
            avatarURL: userAvatarURL
        ),
        roleName: "Member",
        isOnline: true,
        guildAvatarURL: guildAvatarURL
    )
    model.knownMentionMembers = [userID: member]
    let userMention = try #require(
        RenderedMention(rawToken: "<@\(userID.rawValue)>")
    )
    let channelMention = try #require(
        RenderedMention(rawToken: "<#7002>")
    )
    let resolver = MessageMentionResolver(model: model)

    #expect(resolver.avatarURL(userMention) == guildAvatarURL)
    #expect(resolver.avatarURL(channelMention) == nil)
}

@MainActor
@Test func `channel autocomplete follows guild positions and shows category metadata without duplicate hashes`() {
    let guildID = GuildID(rawValue: 50)
    let currentUser = User(id: UserID(rawValue: 60), username: "current", displayName: "Current")
    let memberRole = GuildRole(
        id: RoleID(rawValue: 51),
        name: "Member",
        permissions: 1 << 17
    )
    let currentMember = Member(
        user: currentUser,
        roleName: "Member",
        status: .online,
        roles: [memberRole]
    )
    let everyone = GuildRole(
        id: RoleID(rawValue: guildID.rawValue),
        name: "@everyone",
        permissions: 1 << 10
    )
    let channels = [
        Channel(
            id: ChannelID(rawValue: 3), guildID: guildID, name: "voice", kind: .voice,
            category: "VOICE", position: 0, categoryPosition: 0
        ),
        Channel(
            id: ChannelID(rawValue: 2), guildID: guildID, name: "rules", kind: .text,
            category: "INFO", position: 2, categoryPosition: 0
        ),
        Channel(
            id: ChannelID(rawValue: 1), guildID: guildID, name: "welcome", kind: .text,
            category: "INFO", position: 1, categoryPosition: 0
        ),
        Channel(
            id: ChannelID(rawValue: 4), guildID: guildID, name: "general", kind: .text,
            category: "MAIN", position: 0, categoryPosition: 1
        ),
        Channel(
            id: ChannelID(rawValue: 5), guildID: guildID, name: "bot-updates", kind: .text,
            category: "INFO", position: 3, categoryPosition: 0,
            permissionOverwrites: [
                ChannelPermissionOverwrite(
                    id: guildID.description,
                    type: 0,
                    deny: 1 << 10
                ),
            ]
        ),
        Channel(
            id: ChannelID(rawValue: 6), guildID: guildID, name: "member-lounge", kind: .text,
            category: "INFO", position: 4, categoryPosition: 0,
            permissionOverwrites: [
                ChannelPermissionOverwrite(
                    id: guildID.description,
                    type: 0,
                    deny: 1 << 10
                ),
                ChannelPermissionOverwrite(
                    id: memberRole.id.description,
                    type: 0,
                    allow: 1 << 10
                ),
            ]
        ),
    ]

    let suggestions = MentionAutocompleteSuggestionFactory.channelSuggestions(
        query: "",
        channels: channels,
        guilds: [:],
        currentUserID: currentUser.id,
        currentMember: currentMember,
        roles: [everyone, memberRole]
    )

    #expect(suggestions.map(\.title) == [
        "welcome", "rules", "bot-updates", "member-lounge", "general",
    ])
    #expect(suggestions.map(\.detail) == ["INFO", "INFO", "INFO", "INFO", "MAIN"])
    #expect(suggestions.allSatisfy { !$0.title.hasPrefix("#") })
    #expect(
        suggestions.map(\.systemImage)
            == Array(
                repeating: ChannelIconPresentation.systemImage(for: .text, isHidden: false),
                count: 5
            )
    )
    #expect(MentionAutocompleteSuggestionFactory.canMentionNonMentionableRoles(
        in: channels.first { $0.name == "general" },
        currentUserID: currentUser.id,
        currentMember: currentMember,
        roles: [everyone, memberRole]
    ))
    #expect(MentionAutocompleteSuggestionFactory.canMentionNonMentionableRoles(
        in: channels.first { $0.name == "general" },
        guild: Guild(
            id: guildID,
            name: "Guild",
            currentUserPermissions: (1 << 10) | (1 << 17)
        ),
        currentUserID: currentUser.id,
        currentMember: nil,
        roles: [everyone, memberRole]
    ))
}

@MainActor
@Test func `channel autocomplete ranks exact prefix contains and fuzzy before sidebar position`() {
    let guildID = GuildID(rawValue: 50)
    let channels = [
        Channel(
            id: ChannelID(rawValue: 1), guildID: guildID, name: "misc-ann", kind: .text,
            category: "INFO", position: 0, categoryPosition: 0
        ),
        Channel(
            id: ChannelID(rawValue: 2), guildID: guildID, name: "announcements", kind: .text,
            category: "INFO", position: 4, categoryPosition: 0
        ),
        Channel(
            id: ChannelID(rawValue: 3), guildID: guildID, name: "planning", kind: .text,
            category: "INFO", position: 1, categoryPosition: 0
        ),
        Channel(
            id: ChannelID(rawValue: 4), guildID: guildID, name: "photography", kind: .text,
            category: "MEDIA", position: 0, categoryPosition: 1
        ),
    ]

    let contains = MentionAutocompleteSuggestionFactory.channelSuggestions(
        query: "ann", channels: channels, guilds: [:]
    )
    #expect(contains.map(\.title) == ["announcements", "misc-ann", "planning"])

    let exact = MentionAutocompleteSuggestionFactory.channelSuggestions(
        query: "planning", channels: channels, guilds: [:]
    )
    #expect(exact.map(\.title) == ["planning"])

    let fuzzy = MentionAutocompleteSuggestionFactory.channelSuggestions(
        query: "ptg", channels: channels, guilds: [:]
    )
    #expect(fuzzy.map(\.title) == ["photography"])
}

@MainActor
@Test func `empty channel autocomplete hoists every positive frecency equally then keeps sidebar order`() {
    let guildID = GuildID(rawValue: 50)
    let channels = [
        Channel(
            id: ChannelID(rawValue: 1), guildID: guildID, name: "welcome", kind: .text,
            category: "INFO", position: 0, categoryPosition: 0
        ),
        Channel(
            id: ChannelID(rawValue: 2), guildID: guildID, name: "rules", kind: .text,
            category: "INFO", position: 1, categoryPosition: 0
        ),
        Channel(
            id: ChannelID(rawValue: 3), guildID: guildID, name: "current-channel", kind: .text,
            category: "MAIN", position: 0, categoryPosition: 1
        ),
        Channel(
            id: ChannelID(rawValue: 4), guildID: guildID, name: "logs", kind: .text,
            category: "LOGS", position: 0, categoryPosition: 9
        ),
    ]

    let suggestions = MentionAutocompleteSuggestionFactory.channelSuggestions(
        query: "",
        channels: channels,
        guilds: [:],
        guildAndChannelUsageScores: ["1": 1, "3": 250, "4": 9_999]
    )

    // The current client gives any positive frecency the same full boost. It
    // then preserves the channel store/sidebar order among equally boosted
    // entries rather than sorting by the numeric frecency value.
    #expect(suggestions.map(\.title) == ["welcome", "current-channel", "logs", "rules"])
}

@MainActor
@Test func `emoji completion returns every matching custom emoji`() {
    let guildID = GuildID(rawValue: 30)
    let emojis = (0 ..< 24).map {
        DiscordEmoji(id: String($0), name: "match_\($0)", guildID: guildID)
    }
    let suggestions = ColonAutocompleteSuggestionFactory.suggestions(
        query: "match_",
        customEmojis: emojis,
        customValue: (\.messageToken),
        customSource: { _ in "Complete Catalog" }
    )

    #expect(suggestions.filter { $0.customEmoji != nil }.count == emojis.count)
}

@Test func `unfocused typing redirect accepts text but preserves shortcuts and control keys`() {
    #expect(ComposerUnfocusedTypingMonitor.shouldRedirect(
        characters: "s",
        modifierFlags: []
    ))
    #expect(ComposerUnfocusedTypingMonitor.shouldRedirect(
        characters: "S",
        modifierFlags: [.shift]
    ))
    #expect(!ComposerUnfocusedTypingMonitor.shouldRedirect(
        characters: "s",
        modifierFlags: [.command]
    ))
    #expect(!ComposerUnfocusedTypingMonitor.shouldRedirect(
        characters: "\t",
        modifierFlags: []
    ))
    #expect(ComposerUnfocusedTypingMonitor.shouldOfferReturn(36))
    #expect(ComposerUnfocusedTypingMonitor.shouldOfferReturn(76))
    #expect(!ComposerUnfocusedTypingMonitor.shouldOfferReturn(49))
    #expect(KeyboardShortcutPolicy.isPlainEscape(keyCode: 53, modifierFlags: []))
    #expect(!KeyboardShortcutPolicy.isPlainEscape(keyCode: 49, modifierFlags: []))
}

@MainActor
@Test func `unfocused plain up arrow is consumed before sidebar navigation`() {
    var editRequestCount = 0
    let requestEdit = {
        editRequestCount += 1
        return true
    }

    #expect(ComposerUnfocusedTypingMonitor.handleEditLatestMessage(
        keyCode: 126,
        modifierFlags: [],
        composerIsEmpty: true,
        onEditLatestMessage: requestEdit
    ))
    #expect(editRequestCount == 1)
    #expect(ComposerUnfocusedTypingMonitor.handleEditLatestMessage(
        keyCode: 126,
        modifierFlags: [.function, .numericPad],
        composerIsEmpty: true,
        onEditLatestMessage: requestEdit
    ))
    #expect(editRequestCount == 2)
    #expect(!ComposerUnfocusedTypingMonitor.handleEditLatestMessage(
        keyCode: 126,
        modifierFlags: [.shift],
        composerIsEmpty: true,
        onEditLatestMessage: requestEdit
    ))
    #expect(!ComposerUnfocusedTypingMonitor.handleEditLatestMessage(
        keyCode: 126,
        modifierFlags: [],
        composerIsEmpty: false,
        onEditLatestMessage: requestEdit
    ))
    #expect(!ComposerUnfocusedTypingMonitor.handleEditLatestMessage(
        keyCode: 125,
        modifierFlags: [],
        composerIsEmpty: true,
        onEditLatestMessage: requestEdit
    ))
    #expect(editRequestCount == 2)

    #expect(ComposerUnfocusedTypingMonitor.handleEditLatestMessage(
        keyCode: 126,
        modifierFlags: [],
        composerIsEmpty: true,
        onEditLatestMessage: { false }
    ))
}

@MainActor
@Test func `escape is consumed by the native composer after autocomplete declines it`() throws {
    let textView = ComposerNSTextView()
    var escapeCount = 0
    textView.onAutocompleteCommand = { _ in false }
    textView.onEscape = { escapeCount += 1 }
    textView.keyDown(with: try escapeKeyEvent())
    #expect(escapeCount == 1)
}

@MainActor
@Test func `inline editor cancel handles focused and unfocused Escape`() throws {
    var cancelCount = 0
    let actions = InlineMessageEditorComposerActions(
        onSubmit: {},
        onEscape: { cancelCount += 1 }
    )
    let textView = ComposerNSTextView()
    textView.onAutocompleteCommand = { _ in false }
    textView.onEscape = actions.onEscape
    textView.keyDown(with: try escapeKeyEvent())
    #expect(cancelCount == 1)

    #expect(ComposerUnfocusedTypingMonitor.handleEscape(
        keyCode: 53,
        modifierFlags: [],
        onEscape: actions.onEscape
    ))
    #expect(cancelCount == 2)
    #expect(!ComposerUnfocusedTypingMonitor.handleEscape(
        keyCode: 49,
        modifierFlags: [],
        onEscape: actions.onEscape
    ))
    #expect(!ComposerUnfocusedTypingMonitor.handleEscape(
        keyCode: 53,
        modifierFlags: .shift,
        onEscape: actions.onEscape
    ))
    #expect(cancelCount == 2)
}

@MainActor
private func escapeKeyEvent() throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "\u{1B}",
        charactersIgnoringModifiers: "\u{1B}",
        isARepeat: false,
        keyCode: 53
    ))
}

@MainActor
private func upArrowKeyEvent(
    modifiers: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: String(NSEvent.SpecialKey.upArrow.unicodeScalar),
        charactersIgnoringModifiers: String(
            NSEvent.SpecialKey.upArrow.unicodeScalar
        ),
        isARepeat: false,
        keyCode: 126
    ))
}

@MainActor
private func downArrowKeyEvent(
    modifiers: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: String(NSEvent.SpecialKey.downArrow.unicodeScalar),
        charactersIgnoringModifiers: String(
            NSEvent.SpecialKey.downArrow.unicodeScalar
        ),
        isARepeat: false,
        keyCode: 125
    ))
}

@MainActor
@Test func `definite send failure keeps the optimistic message retryable`() async throws {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    await provider.failNextSend()

    model.updateDraft("keep me")
    let didSend = await model.send()
    #expect(!didSend)
    let failed = try #require(model.messages.first { $0.content == "keep me" })
    #expect(failed.outboxState == .failed)
    #expect(failed.nonce != nil)
    #expect(model.draft.isEmpty)
    #expect(model.errorMessage == nil)
    #expect(MessageOutboxPresentation.textOpacity(for: failed.outboxState) == 1)
    let failedInteraction = MessageOutboxPresentation.interactionMode(
        for: failed.outboxState
    )
    #expect(failedInteraction.allowsHoverActions)
    #expect(failedInteraction.allowsMessageContextMenu)
    #expect(!failedInteraction.allowsMediaContextMenu)
    #expect(
        MessageRowPersistentHighlight.resolve(
            message: failed,
            currentUserID: model.snapshot?.currentUser.id
        ) == .failed
    )
    #expect(
        NativeTimelineMessageMenuPolicy.entries(
            canEdit: true,
            canDelete: true,
            canRetry: true,
            canReply: true,
            canForward: true
        ) == [
            .action(
                .retrySending,
                title: "Retry Send",
                systemImage: "arrow.clockwise"
            ),
            .separator,
            .action(
                .copyText,
                title: "Copy Text",
                systemImage: "doc.on.doc"
            ),
            .separator,
            .action(
                .discardFailedMessage,
                title: "Delete Message…",
                systemImage: "trash",
                isDestructive: true
            ),
        ]
    )
    #expect(await provider.sendCount == 1)
    let nonce = try #require(failed.nonce)
    #expect(model.composer.outbox.draftsByNonce[nonce] != nil)

    model.discardFailedOutgoingMessage(failed)

    #expect(model.messages.allSatisfy { $0.nonce != nonce })
    #expect(model.composer.outbox.draftsByNonce[nonce] == nil)
    #expect(await provider.sendCount == 1)
}

@MainActor
@Test(arguments: [false, true])
func `retry resends the exact failed draft through sending and confirmed states`(timesOut: Bool) async throws {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    if timesOut {
        await provider.timeOutNextSend()
    } else {
        await provider.failNextSend()
    }
    let attachment = ForumPostAttachment(
        url: URL(fileURLWithPath: "/tmp/sakuracord-retry-image.png"),
        filename: "renamed-image.png",
        description: "exact attachment description",
        isSpoiler: true
    )

    model.updateDraft("retry this exact message")
    let didSend = await model.sendComposerMessage(attachments: [attachment])
    #expect(!didSend)
    let failed = try #require(model.messages.first {
        $0.content == "retry this exact message"
    })
    #expect(failed.outboxState == .failed)

    await provider.suspendNextSend()
    let retry = Task { @MainActor in
        await model.retrySending(failed)
    }
    await provider.waitUntilSendStarts()

    let retrying = try #require(model.messages.first { $0.nonce == failed.nonce })
    #expect(retrying.outboxState == .sending)
    #expect(MessageOutboxPresentation.textOpacity(for: retrying.outboxState) == 0.55)
    let sentDrafts = await provider.sentDrafts
    #expect(sentDrafts.count == 2)
    #expect(sentDrafts[0] == sentDrafts[1])
    #expect(sentDrafts[1].content == "retry this exact message")
    #expect(sentDrafts[1].attachments == [attachment])

    await provider.releaseSend()
    #expect(await retry.value)
    let confirmed = try #require(model.messages.first { $0.nonce == failed.nonce })
    #expect(confirmed.outboxState == .confirmed)
}

@MainActor
@Test func `send confirmation preserves a local attachment preview with remote fallback`() async throws {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let channelID = try #require(model.selectedChannelID)
    let user = try #require(model.snapshot?.currentUser)
    let localURL = URL(fileURLWithPath: "/tmp/sakuracord-local-preview.png")
    let remoteURL = try #require(URL(string: "https://cdn.example/confirmed-image.png"))
    let nonce = "local-preview-nonce"
    model.appendSelectedMessage(Message(
        id: MessageID(rawValue: UInt64.max),
        channelID: channelID,
        author: user,
        content: "image",
        attachments: [Attachment(
            id: "optimistic-0",
            filename: "image.png",
            url: localURL,
            mediaType: "image/png"
        )],
        nonce: nonce,
        outboxState: .sending
    ))
    let optimisticRow = try #require(
        model.messageRows.first(where: { $0.message.nonce == nonce })
    )
    let optimisticIdentity = optimisticRow.identity
    let optimisticMediaKey = try #require(
        optimisticRow.message.attachments.first.flatMap {
            NativeTimelineMediaKey.attachment($0)
        }
    )
    let incoming = Message(
        id: MessageID(rawValue: 500),
        channelID: channelID,
        author: user,
        content: "image",
        attachments: [Attachment(
            id: "remote-0",
            filename: "image.png",
            url: remoteURL,
            mediaType: "image/png"
        )],
        nonce: nonce
    )

    let resolved = model.reconcileVisibleOrCached(incoming)

    #expect(resolved.attachments.first?.url == remoteURL)
    #expect(resolved.attachments.first?.proxyURL == localURL)
    let mediaKey = try #require(resolved.attachments.first.flatMap {
        NativeTimelineMediaKey.attachment($0)
    })
    #expect(mediaKey.url == localURL)
    #expect(mediaKey.fallbackURL == remoteURL)
    #expect(mediaKey == optimisticMediaKey)
    #expect(mediaKey.cacheKey == optimisticMediaKey.cacheKey)
    let confirmedRow = try #require(
        model.messageRows.first(where: { $0.message.id == incoming.id })
    )
    #expect(confirmedRow.identity == optimisticIdentity)
    #expect(
        NativeMessageTimelineItem.message(
            confirmedRow,
            isUnreadBoundary: false,
            isHighlighted: false
        ).identifier == .message(optimisticIdentity)
    )
}

@MainActor
@Test func `optimistic message is pending until send confirmation`() async {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()

    await provider.suspendNextSend()
    model.updateDraft("pending message")
    let send = Task { await model.send() }
    await provider.waitUntilSendStarts()

    let pending = model.messages.last { $0.content == "pending message" }
    #expect(pending?.outboxState == .sending)
    let pendingInteraction = pending.map {
        MessageOutboxPresentation.interactionMode(for: $0.outboxState)
    }
    #expect(pendingInteraction == .disabled)
    #expect(pendingInteraction?.allowsHoverActions == false)
    #expect(pendingInteraction?.allowsMessageContextMenu == false)
    #expect(pendingInteraction?.allowsMediaContextMenu == false)
    #expect(
        pending.map {
            MessageOutboxPresentation.textOpacity(for: $0.outboxState)
        } == 0.55
    )

    await provider.releaseSend()
    #expect(await send.value)
    let confirmed = model.messages.last { $0.content == "pending message" }
    #expect(confirmed?.outboxState == .confirmed)
    #expect(
        confirmed.map {
            MessageOutboxPresentation.textOpacity(for: $0.outboxState)
        } == 1
    )
}

@MainActor
@Test func `native sticker send is optimistic and preserves its loaded media on confirmation`() async throws {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let sticker = MessageSticker(
        id: "sticker-optimistic",
        name: "Optimistic Sticker",
        format: .apng
    )

    await provider.suspendNextSend()
    let send = Task { @MainActor in
        await model.sendSticker(sticker)
    }
    await provider.waitUntilSendStarts()

    let pending = try #require(model.messages.last { message in
        message.stickers.contains { $0.id == sticker.id }
    })
    let pendingIdentity = MessageRowIdentity(pending)
    #expect(pending.outboxState == .sending)
    #expect(pending.stickers.first?.mediaURL == sticker.pickerMediaURL)
    #expect(MessageOutboxPresentation.mediaOpacity(for: pending.outboxState) == 0.55)
    let nonce = try #require(pending.nonce)
    #expect(model.composer.outbox.draftsByNonce[nonce]?.stickerIDs == [sticker.id])

    await provider.releaseSend()
    #expect(await send.value)
    let confirmed = try #require(model.messages.last { $0.nonce == nonce })
    #expect(confirmed.outboxState == .confirmed)
    #expect(confirmed.stickers.first?.mediaURL == sticker.pickerMediaURL)
    #expect(MessageRowIdentity(confirmed) == pendingIdentity)
    #expect(MessageOutboxPresentation.mediaOpacity(for: confirmed.outboxState) == 1)
    #expect(model.composer.outbox.draftsByNonce[nonce] == nil)
}

@MainActor
@Test func `failed native sticker send uses the normal retryable outbox state`() async throws {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let sticker = MessageSticker(
        id: "sticker-retry",
        name: "Retry Sticker",
        format: .png
    )
    await provider.failNextSend()

    let didSend = await model.sendSticker(sticker)
    #expect(!didSend)
    let failed = try #require(model.messages.last { message in
        message.stickers.contains { $0.id == sticker.id }
    })
    #expect(failed.outboxState == .failed)
    #expect(MessageOutboxPresentation.interactionMode(for: failed.outboxState) == .failed)
    let nonce = try #require(failed.nonce)
    #expect(model.composer.outbox.draftsByNonce[nonce]?.stickerIDs == [sticker.id])

    #expect(await model.retrySending(failed))
    let confirmed = try #require(model.messages.last { $0.nonce == nonce })
    #expect(confirmed.outboxState == .confirmed)
    #expect(confirmed.stickers.first?.mediaURL == sticker.pickerMediaURL)
    #expect(await provider.sendCount == 2)
}

@MainActor
@Test func `timed out send can be discarded without replaying the request`() async throws {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    await provider.timeOutNextSend()

    model.updateDraft("timed out message")
    let didSend = await model.send()
    #expect(!didSend)

    let failed = try #require(model.messages.last { $0.content == "timed out message" })
    let nonce = try #require(failed.nonce)
    #expect(failed.outboxState == .failed)
    #expect(model.composer.outbox.draftsByNonce[nonce] != nil)
    #expect(await provider.sendCount == 1)

    model.discardFailedOutgoingMessage(failed)

    #expect(model.messages.allSatisfy { $0.nonce != nonce })
    #expect(model.composer.outbox.draftsByNonce[nonce] == nil)
    #expect(await provider.sendCount == 1)
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

@MainActor
@Test func `send confirmation stays with its original channel after navigation`() async {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let originalChannel = try! #require(model.selectedChannelID)

    await provider.suspendNextSend()
    model.updateDraft("channel scoped")
    let send = Task { await model.send() }
    await provider.waitUntilSendStarts()
    model.selectedChannelID = ChannelID(rawValue: 12)
    await provider.releaseSend()
    #expect(await send.value)
    #expect(model.messages.allSatisfy { $0.channelID == model.selectedChannelID })

    model.selectedChannelID = originalChannel
    #expect(await eventuallyOnMain {
        model.messages.count { $0.content == "channel scoped" } == 1
            && model.messages.last(where: { $0.content == "channel scoped" })?.outboxState == .confirmed
    })
}

@MainActor
private func eventuallyOnMain(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    for _ in 0 ..< 200 {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

private func eventuallyUploadCallCount(
    _ expectedCount: Int,
    from uploader: SequencedAttachmentUploadTestUploader
) async -> Bool {
    for _ in 0 ..< 200 {
        if await uploader.callCount == expectedCount {
            return true
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await uploader.callCount == expectedCount
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
@Test(arguments: [UInt64(10), 11, 13, 14])
func `Diagnostics sharing binds confirmation to its source and preserves drafts and retry files`(sourceID: UInt64) async throws {
    let provider = TypingTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let source = ChannelID(rawValue: sourceID)
    let thread = MessageThreadSummary(id: ChannelID(rawValue: 13), parentID: ChannelID(rawValue: 10), name: "thread")
    let post = MessageThreadSummary(id: ChannelID(rawValue: 14), parentID: ChannelID(rawValue: 15), name: "post")
    model.snapshot?.channels.append(Channel(id: ChannelID(rawValue: 15), guildID: nil, name: "forum", kind: .forum))
    model.snapshot?.threads = [thread, post]
    model.openThread = thread
    let staged = URL(fileURLWithPath: "/tmp/sakuracord-diagnostics-staged")
    await provider.failNextSend()
    let sent = await model.shareDiagnostics(in: source, confirm: { name in
        #expect(name == [10: "text", 11: "voice", 13: "thread", 14: "post"][sourceID])
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
@Test(arguments: ["cancel", "session", "permission", "oversize", "export-error"])
func `Diagnostics sharing stops before delivery when confirmation or export becomes invalid`(reason: String) async {
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
        if reason == "export-error" { throw CocoaError(.fileWriteUnknown) }
        if reason == "oversize" { return Data(count: Int(model.discordAttachmentLimit) + 1) }
        Issue.record("A rejected confirmation must not export diagnostics")
        return Data()
    })
    #expect(!sent)
    #expect(await provider.sendCount == 0)
    #expect(model.composer.outbox.draftsByNonce.isEmpty)
    #expect(!model.diagnosticsShareInFlight)
}

@MainActor
@Test func `Diagnostics require source send and attachment permissions for channels threads and voice chat`() {
    let model = AppModel(launchMode: .offlineTesting)
    let user = User(id: UserID(rawValue: 1), username: "me", displayName: "Me")
    let permissions = DiscordPermissionBits.viewChannel | DiscordPermissionBits.readMessageHistory
        | DiscordPermissionBits.sendMessages | DiscordPermissionBits.sendMessagesInThreads
        | DiscordPermissionBits.attachFiles | DiscordPermissionBits.connect
    let guild = Guild(id: GuildID(rawValue: 20), name: "Guild", currentUserPermissions: permissions)
    let channel = Channel(id: ChannelID(rawValue: 21), guildID: guild.id, name: "source", kind: .text)
    let voice = Channel(id: ChannelID(rawValue: 22), guildID: guild.id, name: "voice", kind: .voice)
    let thread = MessageThreadSummary(id: ChannelID(rawValue: 23), guildID: guild.id, parentID: channel.id, name: "thread")
    model.snapshot = BootstrapSnapshot(currentUser: user, guilds: [guild], channels: [channel, voice], members: [])
    model.snapshot?.threads = [thread]
    model.serverRailGuildsByID = [guild.id: guild]
    model.currentUserRoleIDsByGuild[guild.id] = []
    for id in [channel.id, voice.id, thread.id] {
        #expect(model.diagnosticsDestinationName(in: id) != nil)
    }
    for denied in [DiscordPermissionBits.attachFiles, DiscordPermissionBits.viewChannel] {
        var restricted = guild
        restricted.currentUserPermissions = permissions & ~denied
        model.serverRailGuildsByID[guild.id] = restricted
        for id in [channel.id, voice.id, thread.id] {
            #expect(model.diagnosticsDestinationName(in: id) == nil)
        }
    }
    var restricted = guild
    restricted.currentUserPermissions = permissions & ~DiscordPermissionBits.sendMessagesInThreads
    model.serverRailGuildsByID[guild.id] = restricted
    #expect(model.diagnosticsDestinationName(in: channel.id) != nil)
    #expect(model.diagnosticsDestinationName(in: thread.id) == nil)
    model.serverRailGuildsByID[guild.id] = guild
    model.snapshot?.threads[0].isLocked = true
    #expect(model.diagnosticsDestinationName(in: thread.id) == nil)
}

private actor TypingTestProvider: ChatProvider {
    private enum SendFailure {
        case definite
        case timedOut
    }

    let currentUser = User(id: UserID(rawValue: 1), username: "me", displayName: "Me")
    let otherUser = User(id: UserID(rawValue: 2), username: "other", displayName: "Other")
    private let channels = [
        Channel(id: ChannelID(rawValue: 10), guildID: nil, name: "text", kind: .directMessage),
        Channel(id: ChannelID(rawValue: 11), guildID: nil, name: "voice", kind: .voice),
        Channel(id: ChannelID(rawValue: 12), guildID: nil, name: "group", kind: .groupDirectMessage)
    ]
    private var continuation: AsyncStream<ClientEvent>.Continuation?
    private(set) var typingChannels: [ChannelID] = []
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

    var typingCount: Int {
        typingChannels.count
    }

    func bootstrap() async throws -> BootstrapSnapshot {
        continuation?.yield(.connectionChanged(.ready))
        return BootstrapSnapshot(currentUser: currentUser, guilds: [], channels: channels, members: [])
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

    func sendTyping(in channelID: ChannelID) async throws {
        typingChannels.append(channelID)
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

    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message {
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

    func emit(_ event: ClientEvent) {
        continuation?.yield(event)
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
@Test func `translation never sends or edits Discord and explicit sending cancels pending translation`() async throws {
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
    #expect(await provider.sendCount == 0)
    #expect(await provider.editCount == 0)
    #expect(await model.send())
    translator.complete(0, text: "Late translation")
    await translationTask.value
    #expect(model.draft.isEmpty)
    #expect(state.drafts[.channel] == nil)
    #expect(await provider.sendCount == 1)
    let message = Message(id: MessageID(rawValue: 999), channelID: ChannelID(rawValue: 10),
                          author: await provider.otherUser, content: "Hallo")
    model.toggleMessageTranslation(message)
    let messageTask = try #require(state.messageTasks[message.id])
    await translator.waitForRequests(2)
    translator.complete(1)
    await messageTask.value
    #expect(await provider.sendCount == 1)
    #expect(await provider.editCount == 0)
}
