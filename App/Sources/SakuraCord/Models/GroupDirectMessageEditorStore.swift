import Foundation
import Observation
import SakuraCordModels

/// Presentation state for Discord's Edit Group dialog. The name and icon stay
/// local until Save; Discord confirms the saved group.
@Observable
final class GroupDirectMessageEditorStore {
    struct Presentation: Identifiable, Equatable {
        /// The group as it was when the dialog opened.
        let channel: Channel
        /// The member-list title Discord shows when the name is empty.
        let placeholder: String
        var id: ChannelID { channel.id }
        /// The group's own name, or nil while it is titled from its members.
        var currentName: String? { channel.hasExplicitName ? channel.name : nil }
    }

    enum IconDraft: Equatable {
        case unchanged
        case removed
        case upload(ProfileImageUpload)
    }

    var presentation: Presentation? {
        didSet {
            guard presentation?.id != oldValue?.id else { return }
            revision &+= 1
            isSaving = false
            // A closing dialog keeps its draft through the exit animation.
            guard let presentation else { return }
            draftName = presentation.currentName ?? ""
            icon = .unchanged
            error = nil
        }
    }
    var draftName = ""
    var icon: IconDraft = .unchanged
    var isSaving = false
    var error: String?
    @ObservationIgnored var revision: UInt64 = 0

    /// The icon the dialog shows: a pending upload, nothing after Remove, or
    /// the group's saved icon.
    var showsIcon: Bool {
        switch icon {
        case .unchanged: presentation?.channel.iconURL != nil
        case .removed: false
        case .upload: true
        }
    }

    /// The edit Save would send; an unchanged name or icon is omitted.
    var changes: GroupDirectMessageChanges {
        guard let presentation else { return GroupDirectMessageChanges() }
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        var changes = GroupDirectMessageChanges()
        if name != (presentation.currentName ?? "") {
            changes.name = name.isEmpty ? .clear : .set(name)
        }
        switch icon {
        case .unchanged: break
        case .removed: if presentation.channel.iconURL != nil { changes.icon = .clear }
        case let .upload(upload): changes.icon = .set(upload)
        }
        return changes
    }

    func reset() {
        presentation = nil
    }
}
