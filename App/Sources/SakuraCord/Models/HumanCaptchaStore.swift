import DiscordProtocol
import Foundation
import Observation
import SakuraCordModels

/// One account-scoped human challenge. Completion resumes the original
/// request's task once; dismissal, cancellation and account reset reject it.
@Observable
final class HumanCaptchaStore {
    private(set) var challenge: DiscordCaptchaChallenge?
    @ObservationIgnored private var continuation: CheckedContinuation<String, any Error>?
    @ObservationIgnored private let busyError: any Error
    @ObservationIgnored private let failureError: any Error

    init(busyError: any Error, failureError: any Error) {
        self.busyError = busyError
        self.failureError = failureError
    }

    static func serverInvites() -> HumanCaptchaStore {
        HumanCaptchaStore(
            busyError: ServerInviteError.failed("Finish the current CAPTCHA before joining another server."),
            failureError: ServerInviteError.failed("CAPTCHA verification failed or expired. Try joining again.")
        )
    }

    static func friends() -> HumanCaptchaStore {
        HumanCaptchaStore(
            busyError: RelationshipActionError.failed("Finish the current CAPTCHA first."),
            failureError: RelationshipActionError.failed("CAPTCHA verification failed or expired. Try again.")
        )
    }

    func solution(for challenge: DiscordCaptchaChallenge) async throws -> String {
        try Task.checkCancellation()
        guard self.challenge == nil else { throw busyError }
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
            result = .failure(failureError)
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
