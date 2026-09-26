import DiscordProtocol
import Foundation
import Observation
import SakuraCordModels

/// One account-scoped human challenge. Completion resumes the original join task once.
@Observable
final class ServerInviteCaptchaStore {
    private(set) var challenge: DiscordCaptchaChallenge?
    @ObservationIgnored private var continuation: CheckedContinuation<String, any Error>?

    func solution(for challenge: DiscordCaptchaChallenge) async throws -> String {
        try Task.checkCancellation()
        guard self.challenge == nil else {
            throw ServerInviteError.failed("Finish the current CAPTCHA before joining another server.")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.challenge = challenge
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id: challenge.id) }
        }
    }

    func complete(id: UUID, token: String?) {
        guard challenge?.id == id else { return }
        let result: Result<String, any Error>
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = .success(token)
        } else {
            result = .failure(ServerInviteError.failed("CAPTCHA verification failed or expired. Try joining again."))
        }
        finish(result)
    }

    func cancel(id: UUID? = nil) {
        guard id == nil || challenge?.id == id else { return }
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<String, any Error>) {
        let pending = continuation
        continuation = nil
        challenge = nil
        pending?.resume(with: result)
    }
}
