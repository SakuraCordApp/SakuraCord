import Foundation
import Observation
import SakuraCordModels

/// Where a thread action was invoked. Joining and leaving report it to
/// Discord as the first-party `location`.
nonisolated enum ThreadActionSurface: Equatable, Sendable {
    case channelList
    case forumCard
    case sidePane
    case fullView
    /// The open forum post's Follow toggle.
    case forumPostHeader

    var membershipLocation: ThreadMembershipLocation {
        switch self {
        case .channelList, .forumCard: .contextMenu
        case .sidePane: .sidePaneMenu
        case .fullView: .fullViewMenu
        case .forumPostHeader: .forumToolbar
        }
    }
}

/// Presentation state for the Edit Thread/Edit Post dialog and the Delete
/// confirmation. The name stays local until Save; Discord confirms the
/// renamed thread through its response and THREAD_UPDATE.
@Observable
final class ThreadActionStore {
    struct RenamePresentation: Identifiable, Equatable {
        /// The thread as it was when the dialog opened.
        let thread: MessageThreadSummary
        let isForumPost: Bool
        var id: ChannelID { thread.id }
    }

    struct DeletionConfirmation: Identifiable, Equatable {
        let thread: MessageThreadSummary
        let isForumPost: Bool
        var id: ChannelID { thread.id }
    }

    var renaming: RenamePresentation? {
        didSet {
            guard renaming?.id != oldValue?.id else { return }
            revision &+= 1
            isSaving = false
            // A closing dialog keeps its draft through the exit animation.
            guard let renaming else { return }
            draftName = renaming.thread.name
            error = nil
        }
    }

    var draftName = ""
    var isSaving = false
    var error: String?
    var deletion: DeletionConfirmation?
    @ObservationIgnored var revision: UInt64 = 0

    /// The trimmed name to save, or nil while it is empty or unchanged.
    var nameToSave: String? {
        guard let renaming, let name = ThreadNamePolicy.validatedName(draftName),
              name != renaming.thread.name else { return nil }
        return name
    }

    func reset() {
        renaming = nil
        deletion = nil
        draftName = ""
        isSaving = false
        error = nil
    }
}
