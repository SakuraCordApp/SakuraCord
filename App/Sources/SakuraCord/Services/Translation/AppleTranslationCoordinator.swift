import Foundation
import Observation
import Translation

/// Bounded, window-owned work queue. It retains values and continuations, never
/// a SwiftUI-provided TranslationSession. Every removal finishes exactly once.
@MainActor
@Observable
final class AppleTranslationCoordinator: TextTranslating {
    nonisolated struct Operation: Identifiable, Equatable, Sendable {
        let id: UUID
        let text: String
        let targetPreference: String
        var target: TranslationLanguage?
    }

    private(set) var active: Operation?
    let languages: TranslationLanguages
    @ObservationIgnored private var host: UUID?
    private var queue: [Operation] = []
    @ObservationIgnored private var continuations: [UUID: CheckedContinuation<TranslationResult, any Error>] = [:]
    static let capacity = 8
    var pendingCount: Int { queue.count + (active == nil ? 0 : 1) }

    init(languages: TranslationLanguages = TranslationLanguages()) {
        self.languages = languages
    }

    func attachHost(_ id: UUID) {
        guard host != id else { return }
        cancelAll()
        host = id
    }

    func detachHost(_ id: UUID) {
        guard host == id else { return }
        host = nil
        cancelAll()
    }

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        guard host != nil else { throw LocalTranslationError.hostUnavailable }
        try Task.checkCancellation()
        guard continuations.count < Self.capacity else { throw LocalTranslationError.queueFull }
        let operation = Operation(id: UUID(), text: request.text, targetPreference: request.targetLanguage)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                continuations[operation.id] = continuation
                queue.append(operation)
                advance()
            }
        } onCancel: {
            Task { @MainActor in self.finish(operation.id, with: .failure(CancellationError())) }
        }
    }

    /// Called by the operation view's task, so catalog lookup is also bounded
    /// and tied to the window lifetime. A late lookup cannot revive cancelled work.
    func prepare(_ operation: Operation) async {
        guard active?.id == operation.id, active?.target == nil else { return }
        do {
            let target = try await languages.resolve(operation.targetPreference)
            try Task.checkCancellation()
            guard active?.id == operation.id else { return }
            active?.target = target
        } catch {
            finish(operation.id, with: .failure(Self.mappedError(error)))
        }
    }

    func finish(_ id: UUID, with result: Result<TranslationResult, any Error>) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        queue.removeAll { $0.id == id }
        if active?.id == id { active = nil }
        continuation.resume(with: result)
        advance()
    }

    func cancelAll() {
        let pending = continuations.values
        continuations.removeAll()
        queue.removeAll()
        active = nil
        for continuation in pending { continuation.resume(throwing: CancellationError()) }
    }

    private func advance() {
        if active == nil, !queue.isEmpty { active = queue.removeFirst() }
    }
}

/// Scoped to the translationTask callback. No session escapes this call.
@MainActor
extension AppleTranslationCoordinator {
    nonisolated func perform(_ operation: Operation, using session: any TranslationSessionClient) async {
        do {
            try await validate(operation)
            let result = try await AppleTranslationSessionRunner.translate(text: operation.text, session: session)
            await finish(operation.id, with: .success(result))
        } catch {
            await finish(operation.id, with: .failure(Self.mappedError(error)))
        }
    }

    private func validate(_ operation: Operation) async throws {
        guard active?.id == operation.id, let target = operation.target else { throw CancellationError() }
        // A failed auto-detection check still reaches the system language UI.
        let status = try? await languages.provider.status(for: operation.text, target: target)
        try Task.checkCancellation()
        guard active?.id == operation.id else { throw CancellationError() }
        if status == .sameLanguage { throw LocalTranslationError.sameLanguage }
        if status == .unsupported { throw LocalTranslationError.unsupportedPair }
    }

    nonisolated static func mappedError(_ error: any Error) -> any Error {
        switch error {
        case is CancellationError, TranslationError.alreadyCancelled: CancellationError()
        case let local as LocalTranslationError: local
        case TranslationError.unsupportedSourceLanguage, TranslationError.unsupportedLanguagePairing:
            LocalTranslationError.unsupportedPair
        case TranslationError.unsupportedTargetLanguage: LocalTranslationError.unsupportedTarget
        case TranslationError.unableToIdentifyLanguage: LocalTranslationError.ambiguousSource
        case TranslationError.nothingToTranslate: LocalTranslationError.sameLanguage
        case TranslationError.notInstalled: LocalTranslationError.downloadRequired
        case let url as URLError where url.code == .cancelled: CancellationError()
        case is URLError: LocalTranslationError.downloadFailed
        default: LocalTranslationError.failed
        }
    }
}
