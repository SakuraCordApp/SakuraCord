@testable import SakuraCord
import Foundation
import SakuraCordModels
import Testing

/// Each test explicitly releases every request, including cancelled ones, so
/// cancellation-ignoring and out-of-order services exercise publication guards.
@MainActor
final class ControlledTranslationTestService: TextTranslating {
    var requests: [TranslationRequest] = []
    private var completions: [Int: CheckedContinuation<TranslationResult, any Error>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        let index = requests.count
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            completions[index] = continuation
            let ready = waiters.filter { requests.count >= $0.0 }
            waiters.removeAll { requests.count >= $0.0 }
            for waiter in ready { waiter.1.resume() }
        }
    }

    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func complete(_ index: Int, text: String = "Hello") {
        completions.removeValue(forKey: index)?.resume(returning: .init(text: text, detectedSourceLanguage: "nl"))
    }

    func fail(_ index: Int, error: any Error = LocalTranslationError.failed) {
        completions.removeValue(forKey: index)?.resume(throwing: error)
    }
}

@MainActor
private func translationFixture(_ translator: ControlledTranslationTestService) -> AppModel {
    let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
    let state = TranslationState(settingsStore: TranslationSettingsStore(preferences: preferences), translator: translator)
    let model = AppModel(launchMode: .offlineTesting, translation: state)
    model.applyTranslationSettings(.init(isEnabled: true, messageLanguage: "en", draftLanguage: "en"))
    model.selectedChannelID = ChannelID(rawValue: 200)
    return model
}

private func translationMessage(_ id: UInt64 = 300, content: String = "Hallo <@1>") -> Message {
    Message(id: MessageID(rawValue: id), channelID: ChannelID(rawValue: 200),
            author: User(id: UserID(rawValue: 1), username: "fixture", displayName: "Fixture"), content: content)
}

@MainActor
@Test func `message translation loading success hide cache error and retry remain local`() async throws {
    let translator = ControlledTranslationTestService()
    let model = translationFixture(translator)
    let message = translationMessage()
    model.replaceSelectedMessages(with: [message])
    #expect(translator.requests.isEmpty)
    model.toggleMessageTranslation(message)
    #expect(model.messageTranslationPresentation(for: message)?.status == .loading)
    let task = try #require(model.translation.messageTasks[message.id])
    await translator.waitForRequests(1)
    translator.complete(0, text: "Hello <@1>")
    await task.value
    #expect(model.translatedMessageText(message) == "Hello <@1>")
    #expect(model.messages.first?.content == message.content)
    #expect(model.messages.first?.editedTimestamp == message.editedTimestamp)
    model.toggleMessageTranslation(message)
    #expect(model.messageTranslationPresentation(for: message) == nil)
    model.toggleMessageTranslation(message)
    #expect(model.translatedMessageText(message) == "Hello <@1>")
    #expect(translator.requests.count == 1)
    let other = translationMessage(301)
    model.toggleMessageTranslation(other)
    let failing = try #require(model.translation.messageTasks[other.id])
    await translator.waitForRequests(2)
    translator.fail(1)
    await failing.value
    #expect(model.messageTranslationPresentation(for: other)?.status == .failed(LocalTranslationError.failed.localizedDescription))
    model.performMessageTranslationCaptionAction(other)
    #expect(model.messageTranslationPresentation(for: other) == nil)
}

@MainActor
@Test func `message edits deletes settings and evictions invalidate pending identities`() async throws {
    let translator = ControlledTranslationTestService()
    let model = translationFixture(translator)
    let message = translationMessage()
    model.toggleMessageTranslation(message)
    let old = try #require(model.translation.messageTasks[message.id])
    await translator.waitForRequests(1)
    model.invalidateMessageTranslation(message.id, content: "Edited")
    model.toggleMessageTranslation(message)
    let newer = try #require(model.translation.messageTasks[message.id])
    await translator.waitForRequests(2)
    translator.complete(0, text: "old")
    await old.value
    #expect(model.translation.messageTasks[message.id] != nil)
    translator.complete(1, text: "new")
    await newer.value
    #expect(model.translatedMessageText(message) == "new")
    model.invalidateMessageTranslation(message.id)
    #expect(model.translation.messages[message.id] == nil)
    for number in 0 ... MessageTranslationStore.capacity {
        let id = MessageID(rawValue: UInt64(1000 + number))
        let evicted = model.translation.messages.set(.init(sourceContent: "Hello", language: "en", status: .loading), for: id)
        for evictedID in evicted { model.translation.removeMessage(evictedID) }
    }
    #expect(model.translation.messages[MessageID(rawValue: 1000)] == nil)
    model.applyTranslationSettings(.defaults)
    #expect(model.translation.messages.isEmpty)
}

@MainActor
@Test(arguments: [MessageComposerDestination.channel, .thread])
func `draft translation toggles preserve translated edits and dismissal keeps current text`(_ destination: MessageComposerDestination) async throws {
    let translator = ControlledTranslationTestService()
    let model = translationFixture(translator)
    if destination == .channel { model.updateDraft("Hallo") } else { model.updateThreadDraft("Hallo") }
    model.translateDraft(in: destination)
    let task = try #require(model.translation.draftTasks[destination])
    await translator.waitForRequests(1)
    translator.complete(0)
    await task.value
    if destination == .channel { model.updateDraft("Hello edited") } else { model.updateThreadDraft("Hello edited") }
    model.showOriginalDraft(in: destination)
    #expect((destination == .channel ? model.draft : model.threadDraft) == "Hallo")
    model.translateDraft(in: destination)
    #expect((destination == .channel ? model.draft : model.threadDraft) == "Hello edited")
    #expect(translator.requests.count == 1)
    model.dismissDraftTranslation(in: destination)
    #expect((destination == .channel ? model.draft : model.threadDraft) == "Hello edited")
    #expect(model.draftTranslation(for: destination) == nil)
}

@MainActor
@Test(arguments: [false, true])
func `draft revision prevents late results after typing even when reverted`(_ revert: Bool) async throws {
    let translator = ControlledTranslationTestService()
    let model = translationFixture(translator)
    model.updateDraft("Hallo")
    model.translateDraft(in: .channel)
    let task = try #require(model.translation.draftTasks[.channel])
    await translator.waitForRequests(1)
    model.updateDraft("New text")
    if revert { model.updateDraft("Hallo") }
    translator.complete(0)
    await task.value
    #expect(model.draft == (revert ? "Hallo" : "New text"))
    #expect(model.draftTranslation(for: .channel) == nil)
}

@MainActor
@Test func `cancelled draft completion cannot clear or overwrite a newer request`() async throws {
    let translator = ControlledTranslationTestService()
    let model = translationFixture(translator)
    model.updateDraft("Hallo")
    model.translateDraft(in: .channel)
    let old = try #require(model.translation.draftTasks[.channel])
    await translator.waitForRequests(1)
    model.dismissDraftTranslation(in: .channel)
    model.translateDraft(in: .channel)
    let fresh = try #require(model.translation.draftTasks[.channel])
    await translator.waitForRequests(2)
    translator.fail(0, error: CancellationError())
    await old.value
    #expect(model.translation.draftTasks[.channel] != nil)
    translator.complete(1, text: "Fresh")
    await fresh.value
    #expect(model.draft == "Fresh")
    model.updateDraft("Edited after translation")
    model.applyTranslationSettings(.init(isEnabled: true, messageLanguage: "nl", draftLanguage: "ja"))
    #expect(model.draft == "Edited after translation")
    #expect(model.draftTranslation(for: .channel) == nil)
}

@MainActor
@Test(arguments: ["navigate", "account", "disable", "thread-close"])
func `destination and account teardown cancel pending translation without replacing composer text`(_ action: String) async throws {
    let translator = ControlledTranslationTestService()
    let model = translationFixture(translator)
    let destination: MessageComposerDestination = action == "thread-close" ? .thread : .channel
    if destination == .thread { model.updateThreadDraft("Hallo") } else { model.updateDraft("Hallo") }
    model.translateDraft(in: destination)
    let task = try #require(model.translation.draftTasks[destination])
    await translator.waitForRequests(1)
    switch action {
    case "navigate": model.selectedChannelID = ChannelID(rawValue: 900)
    case "account": await model.resetAccountScopedLoadsAndForumState()
    case "disable": model.applyTranslationSettings(.defaults)
    default: model.closeThread()
    }
    let retained = destination == .channel ? model.draft : model.threadDraft
    translator.complete(0)
    await task.value
    #expect((destination == .channel ? model.draft : model.threadDraft) == retained)
    #expect(model.draftTranslation(for: destination) == nil)
}

@MainActor
@Test(arguments: ["/giphy flowers", "   /test", "<@123>", "`code`", "   "])
func `commands and nontext drafts never invoke translation`(_ draft: String) {
    let translator = ControlledTranslationTestService()
    let model = translationFixture(translator)
    model.updateDraft(draft)
    model.translateDraft(in: .channel)
    #expect(!model.canTranslateDraft(in: .channel))
    #expect(translator.requests.isEmpty)
    #expect(model.draft == draft)
}
