import AppIntents
import Foundation

nonisolated enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case signedOut
    case notInVoice
    case statusUpdateFailed
    case accountUnavailable
    case switchAccount(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut:
            "Sign in to SakuraCord first."
        case .notInVoice:
            "Join a voice channel first."
        case .statusUpdateFailed:
            "SakuraCord couldn’t change your status."
        case .accountUnavailable:
            "That conversation belongs to an account that’s no longer signed in."
        case let .switchAccount(name):
            "Switch to \(name) to open this."
        }
    }
}

@MainActor
enum IntentModelAccess {
    static func requireWorkspaceModel() async throws -> AppModel {
        guard let model = await workspaceModel() else {
            throw IntentError.signedOut
        }
        return model
    }

    static func requireVoiceModel() async throws -> AppModel {
        let model = try await requireWorkspaceModel()
        guard model.activeVoiceChannel != nil else {
            throw IntentError.notInVoice
        }
        return model
    }

    /// On a cold launch the intent can run before the saved session finishes
    /// restoring, so wait for the workspace instead of reporting signed out.
    /// Without a saved account there is nothing to wait for.
    static func workspaceModel(timeout: Duration = .seconds(10)) async -> AppModel? {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            let model = SakuraCordRuntimeModelHolder.shared.model
            if let model {
                switch model.sessionState {
                case .workspace:
                    return model
                case .signedOut:
                    return nil
                case .restoring, .connecting:
                    break
                }
            }
            guard UserDefaultsSavedAccountStore.shared.hasSavedAccounts,
                  clock.now < deadline,
                  !Task.isCancelled
            else { return nil }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}
