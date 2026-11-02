import DiscordProtocol
import Foundation
import Observation

/// The app's one human challenge presentation for every REST route.
/// Concurrent challenges wait their turn instead of stacking sheets. Each
/// resumes its request once; dismissal, failure, cancellation and account
/// reset resume it without a solution.
@Observable
final class HumanCaptchaStore {
    private(set) var challenge: DiscordCaptchaChallenge?
    /// Set by the window's presentation; without one, a challenge would wait forever.
    @ObservationIgnored var isPresentable = false
    @ObservationIgnored private var waiting: [(challenge: DiscordCaptchaChallenge, continuation: CheckedContinuation<String?, Never>)] = []

    func solution(for challenge: DiscordCaptchaChallenge) async -> String? {
        // Empty: it could not be shown, as opposed to closed (nil).
        guard isPresentable else { return "" }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                waiting.append((challenge, continuation))
                if self.challenge == nil { self.challenge = challenge }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id: challenge.id) }
        }
    }

    func complete(id: UUID, token: String?) {
        guard let index = waiting.firstIndex(where: { $0.challenge.id == id }) else { return }
        let continuation = waiting.remove(at: index).continuation
        challenge = waiting.first?.challenge
        continuation.resume(returning: token)
    }

    /// Without an identifier, releases every waiting challenge.
    func cancel(id: UUID? = nil) {
        guard let id else {
            let released = waiting
            waiting = []
            challenge = nil
            for entry in released { entry.continuation.resume(returning: nil) }
            return
        }
        complete(id: id, token: nil)
    }
}
