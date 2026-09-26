import Foundation
import Translation

/// A session stays in the nonisolated SwiftUI callback for the entire operation.
/// Apple sessions are not Sendable: do not send one back to the Main Actor or
/// retain it after the SwiftUI task returns. Only our Sendable result crosses back.
nonisolated enum AppleTranslationSessionRunner {
    static func translate(text: String, session: any TranslationSessionClient) async throws -> TranslationResult {
        let plan = TranslationTokenProtector(text)
        guard plan.hasTranslatableText else { throw LocalTranslationError.emptyText }
        var responses: [TranslationTokenProtector.Slot] = []
        var sourceLanguage: String?
        for slot in plan.slots {
            try Task.checkCancellation()
            let response = try await session.translate(slot.text)
            sourceLanguage = response.detectedSourceLanguage
            responses.append(.init(index: slot.index, text: response.text))
        }
        try Task.checkCancellation()
        return try TranslationResult(text: plan.restore(responses), detectedSourceLanguage: sourceLanguage)
    }
}

nonisolated protocol TranslationSessionClient {
    func translate(_ text: String) async throws -> TranslationResult
}

nonisolated final class AppleTranslationSessionClient: TranslationSessionClient {
    private let session: TranslationSession

    init(session: TranslationSession) {
        self.session = session
    }

    func translate(_ text: String) async throws -> TranslationResult {
        let response = try await session.translate(text)
        return TranslationResult(text: response.targetText, detectedSourceLanguage: response.sourceLanguage.maximalIdentifier)
    }
}
