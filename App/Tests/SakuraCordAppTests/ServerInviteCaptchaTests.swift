import DiscordProtocol
import Foundation
import Observation
@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
struct ServerInviteCaptchaTests {
    @Test func `CAPTCHA completion ignores stale callbacks and consumes its continuation once`() async throws {
        let store = ServerInviteCaptchaStore()
        let challenge = makeChallenge()
        let task = Task { try await store.solution(for: challenge) }
        #expect(await presented(store, id: challenge.id))
        store.complete(id: UUID(), token: "stale-solution")
        #expect(store.challenge?.id == challenge.id)
        await #expect(throws: ServerInviteError.self) { try await store.solution(for: makeChallenge()) }
        store.complete(id: challenge.id, token: "human-solution")
        store.complete(id: challenge.id, token: "duplicate-solution")
        #expect(try await task.value == "human-solution")
        #expect(store.challenge == nil)
    }

    @Test(arguments: ["close", "account-reset", "task-cancel", "failure"])
    func `dismissing or invalidating a challenge always releases the waiting join`(action: String) async {
        let invites = ServerInvitePresentationStore()
        let store = invites.captcha
        let challenge = makeChallenge()
        let task = Task { try await store.solution(for: challenge) }
        #expect(await presented(store, id: challenge.id))
        switch action {
        case "close": store.cancel()
        case "account-reset": invites.reset()
        case "task-cancel": task.cancel()
        default: store.complete(id: challenge.id, token: nil)
        }
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(store.challenge == nil)
        let replacement = makeChallenge()
        let next = Task { try await store.solution(for: replacement) }
        #expect(await presented(store, id: replacement.id))
        store.complete(id: challenge.id, token: "late-old-account-token")
        store.cancel(id: challenge.id)
        #expect(store.challenge?.id == replacement.id)
        store.cancel()
        await #expect(throws: CancellationError.self) { try await next.value }
    }

    private func makeChallenge() -> DiscordCaptchaChallenge {
        .init(siteKey: "fixture", rqdata: nil, rqtoken: nil, sessionID: nil, shouldServeInvisible: false)
    }

    private func presented(_ store: ServerInviteCaptchaStore, id: UUID) async -> Bool {
        if store.challenge?.id == id { return true }
        // Wait for publication rather than racing other main-actor tests
        // against a wall-clock deadline on a busy CI runner.
        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = store.challenge
            } onChange: {
                continuation.resume()
            }
        }
        return store.challenge?.id == id
    }
}
