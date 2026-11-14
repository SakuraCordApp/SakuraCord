import Foundation
import Observation
import SakuraCordModels

/// Presentation state for Discord's Change Nickname and friend-nickname
/// dialogs. The draft stays local until Save; Discord confirms the value.
/// Your own server nickname is edited in per-server profile settings.
@Observable
final class NicknameEditorStore {
    static let maximumLength = 32

    enum Target: Equatable {
        /// Another member's server nickname, visible to everyone in that server.
        case server(GuildID)
        /// A friend nickname, visible only to the current account.
        case friend
    }

    struct Presentation: Identifiable, Equatable {
        let target: Target
        let user: User
        let currentNickname: String?
        /// The name shown when the nickname is empty.
        let fallbackName: String
        var id: String {
            switch target {
            case let .server(guildID): "server-\(guildID)-\(user.id)"
            case .friend: "friend-\(user.id)"
            }
        }
    }

    var presentation: Presentation? {
        didSet {
            guard presentation?.id != oldValue?.id else { return }
            revision &+= 1
            isSaving = false
            // A closing dialog keeps its text through the exit animation.
            guard let presentation else { return }
            draft = presentation.currentNickname ?? ""
            error = nil
        }
    }
    var draft = ""
    var isSaving = false
    var error: String?
    /// Incremented to open Settings on a per-server profile.
    var settingsRequest: UInt64 = 0
    @ObservationIgnored var revision: UInt64 = 0
    @ObservationIgnored var memberLoads: [String: Task<Void, Never>] = [:]

    func reset() {
        memberLoads.cancelAll()
        presentation = nil
    }
}
