import Foundation
import Translation

/// A session stays in the nonisolated SwiftUI callback for the entire operation.
/// Apple sessions are not Sendable: do not send one back to the Main Actor or
/// retain it after the SwiftUI task returns. Only our Sendable result crosses back.
nonisolated enum AppleTranslationSessionRunner {
    nonisolated struct Response: Sendable {
        let slot: TranslationTokenProtector.Slot
        let detectedSourceLanguage: String?
    }

    static func translate(text: String, session: any TranslationSessionClient) async throws -> TranslationResult {
        let plan = TranslationTokenProtector(text)
        guard plan.hasTranslatableText else { throw LocalTranslationError.emptyText }
        try Task.checkCancellation()
        // Submit one same-language batch so automatic detection and consent apply
        // to the operation, rather than repeatedly to short prose fragments.
        let responses = try await session.translations(from: plan.slots)
        try Task.checkCancellation()
        return try TranslationResult(
            text: plan.restore(responses.map(\.slot)),
            detectedSourceLanguage: responses.first?.detectedSourceLanguage
        )
    }
}

nonisolated protocol TranslationSessionClient {
    func translations(from slots: [TranslationTokenProtector.Slot]) async throws -> [AppleTranslationSessionRunner.Response]
}

nonisolated final class AppleTranslationSessionClient: TranslationSessionClient {
    private let session: TranslationSession

    init(session: TranslationSession) {
        self.session = session
    }

    func translations(from slots: [TranslationTokenProtector.Slot]) async throws -> [AppleTranslationSessionRunner.Response] {
        let requests = slots.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.index)) }
        let responses = try await session.translations(from: requests)
        return try responses.map { response in
            guard let identifier = response.clientIdentifier, let index = Int(identifier) else {
                throw LocalTranslationError.protectedTokenChanged
            }
            return AppleTranslationSessionRunner.Response(
                slot: .init(index: index, text: response.targetText),
                detectedSourceLanguage: response.sourceLanguage.maximalIdentifier
            )
        }
    }
}
