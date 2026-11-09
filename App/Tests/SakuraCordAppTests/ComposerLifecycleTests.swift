@testable import SakuraCord
import AppKit
import DiscordProtocol
import Foundation
import SakuraCordModels
import SakuraCordPersistence
import SwiftUI
import Testing

@MainActor
@Test(arguments: ["", "destination draft", "source 日本"])
func composerCompositionStaysWithinConversation(destinationDraft: String) throws {
    _ = NSApplication.shared
    let sourceID = ChannelID(rawValue: 200)
    let destinationID = ChannelID(rawValue: 201)
    var writes: [ChannelID: [String]] = [:]
    var selection: NSRange?
    func input(_ text: String, in channelID: ChannelID) -> ComposerTextView {
        ComposerTextView(
            text: text, conversationID: channelID, placeholder: "Message", sendWithReturn: true,
            onTextChange: { writes[channelID, default: []].append($0) }, onSubmit: {},
            selection: Binding(get: { selection }, set: { selection = $0 }),
            isFocused: .constant(false)
        )
    }
    let host = NSHostingView(rootView: input("source ", in: sourceID))
    host.frame = NSRect(x: 0, y: 0, width: 500, height: 100)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }
    host.layoutSubtreeIfNeeded()
    func editor(in view: NSView) -> ComposerNSTextView? {
        if let editor = view as? ComposerNSTextView { return editor }
        return view.subviews.lazy.compactMap { editor(in: $0) }.first
    }
    let view = try #require(editor(in: host))
    let currentSelection = NSRange(location: NSNotFound, length: 0)
    view.setSelectedRange(NSRange(location: 7, length: 0))
    view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: currentSelection)
    host.rootView = input("source ", in: sourceID)
    host.layoutSubtreeIfNeeded()
    #expect(view.string == "source に")
    #expect(view.hasMarkedText(), "Ordinary redraws must preserve composition")
    view.insertText("日本", replacementRange: currentSelection)
    #expect(writes[sourceID] == ["source 日本"])

    host.rootView = input("source 日本", in: sourceID)
    host.layoutSubtreeIfNeeded()
    view.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0), replacementRange: currentSelection)
    selection = nil
    host.rootView = input(destinationDraft, in: destinationID)
    host.layoutSubtreeIfNeeded()
    #expect(view.string == destinationDraft)
    #expect(!view.hasMarkedText())
    #expect(writes[sourceID] == ["source 日本"], "Discarding composition must not publish the old draft")
    #expect(writes[destinationID] == nil, "Switching conversations must not write into the new draft")

    view.setSelectedRange(NSRange(location: destinationDraft.utf16.count, length: 0))
    view.setMarkedText("い", selectedRange: NSRange(location: 1, length: 0), replacementRange: currentSelection)
    view.insertText("異", replacementRange: currentSelection)
    #expect(writes[destinationID] == [destinationDraft + "異"])
}

@MainActor
@Test(arguments: ["", "destination draft"], [false, true])
func cachedChannelDraftIsolation(destinationDraft: String, editsDuringRestoration: Bool) async throws {
    let model = AppModel(launchMode: .offlineTesting)
    let database = try #require(model.database)
    let user = User(id: UserID(rawValue: 1), username: "author", displayName: "Author")
    let source = Channel(id: ChannelID(rawValue: 200), guildID: nil, name: "source", kind: .directMessage)
    let destination = Channel(id: ChannelID(rawValue: 201), guildID: nil, name: "destination", kind: .directMessage)
    model.snapshot = BootstrapSnapshot(currentUser: user, guilds: [], channels: [source, destination], members: [])
    model.hasMoreCache[source.id] = false
    model.hasMoreCache[destination.id] = false
    try await database.saveDraft(destinationDraft, channelID: destination.id)

    model.selectedChannelID = source.id
    await model.channelLoadTask?.value
    model.updateDraft("source draft")
    model.selectedChannelID = destination.id
    #expect(model.draft.isEmpty, "The source draft must disappear before destination restoration suspends")
    if editsDuringRestoration { model.updateDraft("new destination edit") }
    await model.channelLoadTask?.value
    let expectedDestinationDraft = editsDuringRestoration ? "new destination edit" : destinationDraft
    #expect(model.draft == expectedDestinationDraft)

    model.selectedChannelID = source.id
    await model.channelLoadTask?.value
    #expect(model.draft == "source draft")
    await model.composer.flushDraftOperations()
    #expect(try await database.draft(channelID: source.id) == "source draft")
    #expect(try await database.draft(channelID: destination.id) == expectedDestinationDraft)
}

@MainActor
@Test func `composer reset drains ordered writes into their original account database`() async throws {
    let first = try SakuraCordDatabase(inMemory: true)
    let second = try SakuraCordDatabase(inMemory: true)
    let composer = MessageComposerState()
    let channelID = ChannelID(rawValue: 1)
    for index in 0 ..< 50 {
        composer.persistDraft("edit \(index)", channelID: channelID, database: first)
    }
    composer.draft = "pending"
    composer.threadDraft = "thread"
    composer.outbox.draftsByNonce["pending"] = SendMessageDraft(channelID: channelID, content: "pending")
    await composer.reset()
    #expect(try await first.draft(channelID: channelID) == "edit 49")
    #expect(try await second.draft(channelID: channelID).isEmpty)
    #expect(composer.draft.isEmpty)
    #expect(composer.threadDraft.isEmpty)
    #expect(composer.outbox.draftsByNonce.isEmpty)
    composer.persistDraft("new account", channelID: channelID, database: second)
    await composer.reset()
    #expect(try await first.draft(channelID: channelID) == "edit 49")
    #expect(try await second.draft(channelID: channelID) == "new account")
}

@MainActor
@Test func `session invalidation clears composer and returns to saved account sign in`() async throws {
    let model = AppModel(launchMode: .normal, provider: MockChatProvider())
    model.draft = "old account"
    model.threadDraft = "old thread"
    model.isAuthenticated = true
    model.sessionState = .workspace
    model.pinnedMessages.isPresented = true
    model.pinnedMessages.channelID = ChannelID(rawValue: 200)
    model.pinnedMessages.errorMessage = "previous account"
    let pair = AsyncStream<ClientEvent>.makeStream()
    model.installEventTask(pair.stream, account: model.accountSession())
    let consumer = model.eventTask
    pair.continuation.yield(.sessionInvalidated("Reconnect to reload state"))
    pair.continuation.finish()
    await consumer?.value
    #expect(model.sessionState == .signedOut)
    #expect(!model.isAuthenticated)
    #expect(model.draft.isEmpty)
    #expect(model.threadDraft.isEmpty)
    #expect(model.errorMessage?.contains("Reconnect") == true)
    #expect(model.eventTask == nil)
    #expect(!model.pinnedMessages.isPresented)
    #expect(model.pinnedMessages.channelID == nil)
    #expect(model.pinnedMessages.errorMessage == nil)
}

@MainActor
@Test func `uncached sparse edits survive visible reconciliation and pending history refresh`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    let channelID = ChannelID(rawValue: 200)
    let author = User(id: UserID(rawValue: 1), username: "author", displayName: "Author")
    let original = Message(id: MessageID(rawValue: 300), channelID: channelID, author: author, content: "original")
    model.selectedChannelID = channelID
    model.replaceSelectedMessages(with: [original])
    var edit = MessageUpdate(messageID: original.id, channelID: channelID)
    edit.content = "edited"
    await model.consume(.messagePatched(edit))
    #expect(model.messages.first?.content == "edited")
    #expect(model.messages.first?.author == author)

    model.replaceSelectedMessages(with: [])
    model.conversationRefreshJournals[channelID] = ConversationRefreshJournal(revision: 1)
    model.consumeImmediately(.messagePatched(edit))
    var pin = MessageUpdate(messageID: original.id, channelID: channelID)
    pin.isPinned = true
    model.consumeImmediately(.messagePatched(pin))
    let mutations = model.conversationRefreshMutations(in: channelID, revision: 1)
    let merged = AppModel.applyingConversationRefreshMutations(mutations, to: [original])
    #expect(merged.first?.content == "edited")
    #expect(merged.first?.isPinned == true)
    model.recordConversationRefreshMutation(.delete, messageID: original.id, channelID: channelID)
    model.consumeImmediately(.messagePatched(edit))
    #expect(AppModel.applyingConversationRefreshMutations(model.conversationRefreshMutations(in: channelID, revision: 1), to: [original]).isEmpty)
}

@MainActor
@Test(arguments: [false, true])
func `visible sparse edits preserve unrelated fresh history fields`(usesAsyncConsumer: Bool) async {
    let model = AppModel(launchMode: .offlineTesting)
    let channelID = ChannelID(rawValue: 200)
    let user = User(id: UserID(rawValue: 1), username: "author", displayName: "Author")
    let original = Message(id: MessageID(rawValue: 300), channelID: channelID, author: user, content: "old")
    model.selectedChannelID = channelID
    model.replaceSelectedMessages(with: [original])
    let revision = model.beginConversationRefresh(in: channelID)
    var patch = MessageUpdate(messageID: original.id, channelID: channelID)
    patch.content = "edited"
    if usesAsyncConsumer {
        await model.consume(.messagePatched(patch))
    } else {
        model.consumeImmediately(.messagePatched(patch))
    }
    #expect(model.messages.first?.content == "edited")
    var fresh = original
    fresh.isPinned = true
    let merged = AppModel.applyingConversationRefreshMutations(
        model.conversationRefreshMutations(in: channelID, revision: revision), to: [fresh]
    )
    #expect(merged.first?.content == "edited")
    #expect(merged.first?.isPinned == true)
}

@MainActor
@Test(arguments: [false, true], [false, true])
func `draft clearing orders earlier and later edits around deletion`(editsAfterClear: Bool, clearsAll: Bool) async throws {
    let database = try SakuraCordDatabase(inMemory: true)
    let inactiveDatabase = try SakuraCordDatabase(inMemory: true)
    let inactiveChannelID = ChannelID(rawValue: 201)
    try await inactiveDatabase.saveDraft("other account", channelID: inactiveChannelID)
    let model = AppModel(launchMode: .offlineTesting, accountDatabaseFactory: { _ in inactiveDatabase })
    model.activeAccountID = "1"
    model.savedAccounts = [SavedAccount(handle: CredentialHandle(accountID: "2"))]
    model.installAccountSession(provider: MockChatProvider(), database: database)
    let channelID = ChannelID(rawValue: 200)
    model.selectedChannelID = channelID
    for index in 0 ..< 100 { model.updateDraft("pending edit \(index)") }
    let clearing = Task {
        if clearsAll { try await model.clearAllLocalDrafts() }
        else { try await model.clearLocalDrafts() }
    }
    // The empty composer acknowledges that deletion has entered the queue.
    while !model.draft.isEmpty, !Task.isCancelled { await Task.yield() }
    if editsAfterClear { model.updateDraft("new edit") }
    try await cancellableValue(of: clearing)
    #expect(model.draft == (editsAfterClear ? "new edit" : ""))
    #expect(model.quickSwitcherDraftChannelIDs.contains(channelID) == editsAfterClear)
    await model.composer.reset()
    #expect(try await database.draft(channelID: channelID) == (editsAfterClear ? "new edit" : ""))
    #expect(try await inactiveDatabase.draft(channelID: inactiveChannelID) == (clearsAll ? "" : "other account"))
}

@MainActor
@Test func `profile changes update retained authors and mentions without replacing fresh history fields`() {
    let model = AppModel(launchMode: .offlineTesting)
    let old = User(id: UserID(rawValue: 1), username: "old", displayName: "Old")
    let other = User(id: UserID(rawValue: 2), username: "other", displayName: "Other")
    var renamed = old
    renamed.displayName = "New"
    renamed.avatarURL = URL(string: "https://example.com/new.png")
    let channelID = ChannelID(rawValue: 200)
    let message = Message(id: MessageID(rawValue: 300), channelID: channelID, author: old, content: "retained")
    model.selectedChannelID = channelID
    model.replaceSelectedMessages(with: [message])
    var cached = Message(id: MessageID(rawValue: 301), channelID: ChannelID(rawValue: 201), author: other, content: "mention")
    cached.mentionedUsers = [old]
    model.messageCache[cached.channelID] = [cached]
    let revision = model.beginConversationRefresh(in: channelID)
    model.consumeImmediately(.currentUserChanged(renamed))
    #expect(model.messages.first?.author == renamed)
    #expect(model.messageCache[cached.channelID]?.first?.mentionedUsers == [renamed])
    var fresh = message
    fresh.isPinned = true
    fresh.content = "fresh content"
    let merged = AppModel.applyingConversationRefreshMutations(
        model.conversationRefreshMutations(in: channelID, revision: revision), to: [fresh]
    )
    #expect(merged.first?.author == renamed)
    #expect(merged.first?.isPinned == true)
    #expect(merged.first?.content == "fresh content")
}

@MainActor
@Test func `GIF send from an older window first restores contiguous newest history`() async throws {
    let provider = MockChatProvider(timelineMessageCount: 500)
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let channelID = ChannelID(rawValue: 210)
    let targetID = MessageID(rawValue: 5_000_100)
    model.navigate(to: GuildID(rawValue: 100), channelID: channelID, messageID: targetID)
    #expect(await eventually {
        model.messageNavigationRequest?.messageID == targetID && model.messages.contains(where: { $0.id == targetID })
    })
    try #require(model.hasMoreLaterMessages)
    let gif = GIFSearchResult(id: "audit", title: "Audit", url: URL(string: "https://example.com/audit.gif")!, previewURL: URL(string: "https://example.com/preview.gif")!)
    try #require(await model.sendGIF(gif))
    #expect(!model.hasMoreLaterMessages, "Sending should first replace the old window with newest history")
    #expect(model.messages.contains(where: { $0.id == MessageID(rawValue: 5_000_499) }), "The newest original messages must remain reachable")
    await model.loadLater()
    #expect(model.messages.contains(where: { $0.id == MessageID(rawValue: 5_000_125) }) || model.messages.contains(where: { $0.id == MessageID(rawValue: 5_000_499) }), "Pagination must not skip the missing middle history")
}

@MainActor
@Test func `sparse updates discard plans prepared before history replacement`() throws {
    let model = AppModel(launchMode: .offlineTesting)
    let channelID = ChannelID(rawValue: 200)
    let user = User(id: UserID(rawValue: 1), username: "audit", displayName: "Audit")
    let original = Message(id: MessageID(rawValue: 300), channelID: channelID, author: user, content: "old content")
    model.selectedChannelID = channelID
    model.replaceSelectedMessages(with: [original])
    var patch = MessageUpdate(messageID: original.id, channelID: channelID)
    patch.isPinned = true
    // Exact state on the two sides of consume's detached text-plan await.
    let preparedSource = try #require(model.applyingMessageUpdate(patch))
    let prepared = NativeTimelineTextPlan.make(for: preparedSource)
    var fresh = original
    fresh.content = "fresh history content"
    model.replaceSelectedMessages(with: [fresh])
    model.consumeImmediately(.messagePatched(patch), preparedTextPlan: prepared, preparedTextPlanSource: preparedSource)
    try #require(model.messages.first?.content == fresh.content)
    #expect(model.messageRows.first?.textPlan == NativeTimelineTextPlan.make(for: model.messages[0]), "Displayed text must match the merged message")
}

@MainActor
@Test func `identity changes reconcile pages still awaiting publication`() {
    let model = AppModel(launchMode: .offlineTesting)
    let old = User(id: UserID(rawValue: 1), username: "old", displayName: "Old")
    var renamed = old
    renamed.displayName = "New"
    let channelID = ChannelID(rawValue: 200)
    let pageAwaitingPresentation = [Message(id: MessageID(rawValue: 300), channelID: channelID, author: old, content: "pending history")]
    model.selectedChannelID = channelID
    model.snapshot = BootstrapSnapshot(currentUser: old, guilds: [], channels: [], members: [])
    let revision = model.beginConversationRefresh(in: channelID)
    model.consumeImmediately(.currentUserChanged(renamed))
    let committed = AppModel.applyingConversationRefreshMutations(
        model.conversationRefreshMutations(in: channelID, revision: revision),
        to: pageAwaitingPresentation
    )
    #expect(committed.first?.author.displayName == "New")
}

@MainActor
@Test(arguments: [false, true], [false, true])
func `refresh identity replay preserves event order and later guild mentions`(retainsMessage: Bool, identityLast: Bool) {
    for usesFullMessage in [false, true] {
        let model = AppModel(launchMode: .offlineTesting)
        let channelID = ChannelID(rawValue: 200)
        let old = User(id: UserID(rawValue: 1), username: "person", displayName: "Old")
        var global = old
        global.displayName = "New global name"
        global.avatarURL = URL(string: "https://example.com/global.png")
        var guild = global
        guild.displayName = "Guild nickname"
        guild.avatarURL = URL(string: "https://example.com/guild.png")
        var original = Message(id: MessageID(rawValue: 300), channelID: channelID, author: old, content: "original")
        original.mentionedUsers = [old]
        model.selectedChannelID = channelID
        if retainsMessage { model.replaceSelectedMessages(with: [original]) }
        let revision = model.beginConversationRefresh(in: channelID)
        if !identityLast { model.consumeImmediately(.currentUserChanged(global)) }
        if usesFullMessage {
            var newer = original
            newer.mentionedUsers = [guild]
            model.consumeImmediately(.messageUpdated(newer))
        } else {
            var patch = MessageUpdate(messageID: original.id, channelID: channelID)
            patch.mentionedUsers = [guild]
            model.consumeImmediately(.messagePatched(patch))
        }
        if identityLast { model.consumeImmediately(.currentUserChanged(global)) }
        let committed = AppModel.applyingConversationRefreshMutations(
            model.conversationRefreshMutations(in: channelID, revision: revision), to: [original]
        )
        #expect(committed.first?.mentionedUsers == [identityLast ? global : guild])
        #expect(committed.first?.author == (usesFullMessage && !identityLast ? old : global))
        if retainsMessage { #expect(committed.first == model.messages.first) }

        // A later identity event must still update earlier explicit fields.
        global.displayName = "Latest global name"
        model.consumeImmediately(.currentUserChanged(global))
        let final = AppModel.applyingConversationRefreshMutations(
            model.conversationRefreshMutations(in: channelID, revision: revision), to: [original]
        )
        #expect(final.first?.author == global)
        #expect(final.first?.mentionedUsers == [global])
    }
}

@MainActor
@Test func `draft restoration sees the latest accepted write`() async throws {
    let database = try SakuraCordDatabase(inMemory: true)
    let model = AppModel(launchMode: .offlineTesting)
    model.installAccountSession(provider: MockChatProvider(), database: database)
    let channelID = ChannelID(rawValue: 200)
    for index in 0 ..< 100 {
        model.composer.persistDraft("accepted edit \(index)", channelID: channelID, database: database)
    }
    let revision = model.composer.draftRevision
    let restored = await model.storedDraft(in: channelID, account: model.accountSession())
    model.composer.restoreDraft(restored, ifUnchangedSince: revision)
    #expect(model.draft == "accepted edit 99")
    await model.composer.reset()
    #expect(restored == "accepted edit 99")
    #expect(try await database.draft(channelID: channelID) == "accepted edit 99")
}

@MainActor
@Test(arguments: [false, true], [false, true])
func `clearing drafts invalidates unpublished restorations`(clearsAll: Bool, editsAfterClear: Bool) async throws {
    let database = try SakuraCordDatabase(inMemory: true)
    let model = AppModel(launchMode: .offlineTesting)
    model.installAccountSession(provider: MockChatProvider(), database: database)
    let channelID = ChannelID(rawValue: 200)
    model.selectedChannelID = channelID
    model.composer.persistDraft("old draft", channelID: channelID, database: database)
    let revision = model.composer.draftRevision
    let savedDraft = await model.storedDraft(in: channelID, account: model.accountSession())
    #expect(savedDraft == "old draft")

    // Hold the read result across deletion to deterministically exercise delayed
    // publication, including when the composer was already empty before Clear.
    if clearsAll { try await model.clearAllLocalDrafts() }
    else { try await model.clearLocalDrafts() }
    if editsAfterClear { model.updateDraft("new draft") }
    model.composer.restoreDraft(savedDraft, ifUnchangedSince: revision)
    await model.composer.flushDraftOperations()
    #expect(model.draft == (editsAfterClear ? "new draft" : ""))
    #expect(try await database.draft(channelID: channelID) == (editsAfterClear ? "new draft" : ""))
    #expect(model.quickSwitcherDraftChannelIDs.contains(channelID) == editsAfterClear)
}

@MainActor
@Test func `clearing local activity resets the active saved search order`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    model.snapshot?.forwardChannelStoreOrder = [ChannelID(rawValue: 200), ChannelID(rawValue: 201)]
    let revision = model.forwardSearchSourceRevision
    try await model.clearLocalActivity()
    #expect(model.snapshot?.forwardChannelStoreOrder.isEmpty == true)
    #expect(model.forwardSearchSourceRevision > revision)
}

@MainActor
@Test func threadCreationNameNormalizesEdits() {
    let creation = ThreadCreationDraft(
        parentID: ChannelID(rawValue: 7),
        permissions: ThreadCreationPermissions(canCreatePublic: true, canCreatePrivate: false)
    )

    creation.name = "Release\nnotes\r\n" + String(repeating: "x", count: 120)

    #expect(creation.name.hasPrefix("Release notes "))
    #expect(creation.name.count == ThreadCreationDraft.maximumNameLength)
}
