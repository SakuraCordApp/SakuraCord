@testable import SakuraCord
import Foundation
import Observation
import Testing
import Translation

@MainActor
private final class FixtureLanguages: TranslationLanguageProviding {
    var reads = 0
    var pair: TranslationPairStatus = .supported
    func supportedLanguages() async -> [TranslationLanguage] {
        reads += 1
        return ["en-Latn-US", "nl-Latn-NL", "zh-Hans-CN", "zh-Hant-TW"].map { TranslationLanguage(id: $0) }
    }
    func status(for _: String, target _: TranslationLanguage) async throws -> TranslationPairStatus { pair }
}

@MainActor
private func activeOperation(_ coordinator: AppleTranslationCoordinator) async throws -> AppleTranslationCoordinator.Operation {
    if coordinator.active == nil {
        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = coordinator.active
            } onChange: {
                continuation.resume()
            }
        }
    }
    let operation = try #require(coordinator.active)
    await coordinator.prepare(operation)
    return try #require(coordinator.active)
}

@MainActor
@Test func `translation coordinator is inactive until explicitly requested and repeats identical pairs`() async throws {
    let provider = FixtureLanguages()
    let coordinator = AppleTranslationCoordinator(languages: TranslationLanguages(provider: provider))
    coordinator.attachHost(UUID())
    #expect(provider.reads == 0)
    #expect(coordinator.active == nil)
    var identities: Set<UUID> = []
    for _ in 0 ..< 3 {
        let task = Task { try await coordinator.translate(.init(text: "Hallo", targetLanguage: "en")) }
        let operation = try await activeOperation(coordinator)
        identities.insert(operation.id)
        coordinator.finish(operation.id, with: .success(.init(text: "Hello", detectedSourceLanguage: "nl")))
        #expect(try await task.value.text == "Hello")
    }
    #expect(identities.count == 3)
    #expect(coordinator.active == nil)
}

@MainActor
@Test func `host removal completes waiting operations and old completions cannot finish a replacement`() async throws {
    let coordinator = AppleTranslationCoordinator(languages: TranslationLanguages(provider: FixtureLanguages()))
    let host = UUID()
    coordinator.attachHost(host)
    let old = Task { try await coordinator.translate(.init(text: "Hallo", targetLanguage: "en")) }
    let first = try await activeOperation(coordinator)
    coordinator.detachHost(host)
    await #expect(throws: CancellationError.self) { try await old.value }
    coordinator.attachHost(UUID())
    let next = Task { try await coordinator.translate(.init(text: "Hallo", targetLanguage: "en")) }
    let second = try await activeOperation(coordinator)
    coordinator.finish(first.id, with: .success(.init(text: "outdated", detectedSourceLanguage: nil)))
    coordinator.detachHost(host)
    #expect(coordinator.active?.id == second.id)
    coordinator.finish(second.id, with: .success(.init(text: "fresh", detectedSourceLanguage: nil)))
    #expect(try await next.value.text == "fresh")
}

@MainActor
@Test func `cancelling a coordinator request ends it and permits retry`() async throws {
    let coordinator = AppleTranslationCoordinator(languages: TranslationLanguages(provider: FixtureLanguages()))
    coordinator.attachHost(UUID())
    let task = Task { try await coordinator.translate(.init(text: "Hallo", targetLanguage: "en")) }
    let operation = try await activeOperation(coordinator)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    coordinator.finish(operation.id, with: .success(.init(text: "late", detectedSourceLanguage: nil)))
    #expect(coordinator.active == nil)
    coordinator.cancelAll()
}

@MainActor
@Test func `language resolution preserves scripts and refuses unsupported saved settings`() async throws {
    let provider = FixtureLanguages()
    let languages = TranslationLanguages(provider: provider)
    #expect(try await languages.resolve("", preferred: ["xx", "nl-BE"]).id == "nl-Latn-NL")
    #expect(try await languages.resolve("zh-TW").id == "zh-Hant-TW")
    #expect(try await languages.resolve("zh-CN").id == "zh-Hans-CN")
    await #expect(throws: LocalTranslationError.unsupportedTarget) { try await languages.resolve("xx") }
    for status in [TranslationPairStatus.installed, .supported, .unsupported] {
        provider.pair = status
        #expect(try await provider.status(for: "Hallo", target: TranslationLanguage(id: "en")) == status)
    }
    #expect(TranslationLanguages.match("zh-Hant", supported: [.init(id: "zh-Hans-CN")]) == nil)
}

@MainActor
@Test func `Apple translation errors stay actionable without Apple Intelligence prerequisites`() {
    #expect(AppleTranslationCoordinator.mappedError(TranslationError.nothingToTranslate) as? LocalTranslationError == .sameLanguage)
    #expect(AppleTranslationCoordinator.mappedError(TranslationError.unableToIdentifyLanguage) as? LocalTranslationError == .ambiguousSource)
    #expect(AppleTranslationCoordinator.mappedError(TranslationError.notInstalled) as? LocalTranslationError == .downloadRequired)
    #expect(AppleTranslationCoordinator.mappedError(URLError(.notConnectedToInternet)) as? LocalTranslationError == .downloadFailed)
    #expect(AppleTranslationCoordinator.mappedError(TranslationError.alreadyCancelled) is CancellationError)
}

@MainActor
@Test(arguments: [TranslationPairStatus.installed, .supported, .unsupported, .sameLanguage])
func `availability checks permit supported downloads and reject unsupported pairs`(_ status: TranslationPairStatus) async throws {
    let provider = FixtureLanguages()
    provider.pair = status
    let coordinator = AppleTranslationCoordinator(languages: TranslationLanguages(provider: provider))
    coordinator.attachHost(UUID())
    let task = Task { try await coordinator.translate(.init(text: "Hallo <@1> ||geheim||", targetLanguage: "en")) }
    let operation = try await activeOperation(coordinator)
    let session = FixtureSession()
    await coordinator.perform(operation, using: session)
    if status == .unsupported || status == .sameLanguage {
        let error: LocalTranslationError = status == .sameLanguage ? .sameLanguage : .unsupportedPair
        await #expect(throws: error) { try await task.value }
        #expect(await session.calls == 0)
    } else {
        #expect(try await task.value.text == "Hello <@1> ||secret||")
        #expect(await session.calls == 2)
    }
}

@MainActor
@Test func `coordinator fails closed for model generated syntax`() async throws {
    let coordinator = AppleTranslationCoordinator(languages: TranslationLanguages(provider: FixtureLanguages()))
    coordinator.attachHost(UUID())
    let task = Task { try await coordinator.translate(.init(text: "Hallo <@1>", targetLanguage: "en")) }
    let operation = try await activeOperation(coordinator)
    await coordinator.perform(operation, using: FixtureSession(corrupt: true))
    await #expect(throws: LocalTranslationError.protectedTokenChanged) { try await task.value }
}

private actor FixtureSession: TranslationSessionClient {
    private(set) var calls = 0
    var corrupt: Bool
    init(corrupt: Bool = false) { self.corrupt = corrupt }
    func translate(_ text: String) async throws -> TranslationResult {
        calls += 1
        return .init(text: corrupt ? "Hello <@99>" : (text == "Hallo" ? "Hello" : "secret"), detectedSourceLanguage: "nl")
    }
}

@MainActor
@Test func `queue admission is bounded before language lookup and teardown resumes all waiters`() async throws {
    let provider = FixtureLanguages()
    let coordinator = AppleTranslationCoordinator(languages: TranslationLanguages(provider: provider))
    let host = UUID()
    coordinator.attachHost(host)
    var tasks: [Task<TranslationResult, any Error>] = []
    for count in 1 ... AppleTranslationCoordinator.capacity {
        tasks.append(Task { try await coordinator.translate(.init(text: "Hallo", targetLanguage: "en")) })
        if coordinator.pendingCount < count {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = coordinator.pendingCount } onChange: { continuation.resume() }
            }
        }
        #expect(coordinator.pendingCount == count)
    }
    #expect(provider.reads == 0)
    await #expect(throws: LocalTranslationError.queueFull) {
        try await coordinator.translate(.init(text: "extra", targetLanguage: "en"))
    }
    coordinator.detachHost(host)
    for task in tasks { await #expect(throws: CancellationError.self) { try await task.value } }
    #expect(coordinator.pendingCount == 0)
}
