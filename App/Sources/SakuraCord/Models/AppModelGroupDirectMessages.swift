import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    /// Discord offers Edit Group and Leave Group to every member of a group
    /// DM, never in a 1:1 DM.
    func offersGroupDirectMessageActions(_ channel: Channel) -> Bool {
        channel.guildID == nil && channel.kind == .groupDirectMessage
    }

    private func groupDirectMessage(_ channelID: ChannelID) -> Channel? {
        snapshot?.channels.first { $0.id == channelID && offersGroupDirectMessageActions($0) }
    }

    func presentGroupDirectMessageEditor(for channelID: ChannelID) {
        guard let channel = groupDirectMessage(channelID) else { return }
        groupDirectMessageEditor.presentation = GroupDirectMessageEditorStore.Presentation(
            channel: channel,
            placeholder: groupDirectMessagePlaceholder(for: channel)
        )
    }

    /// Discord's untitled group name: members by friend nickname, then name,
    /// or your own group once nobody else remains.
    private func groupDirectMessagePlaceholder(for channel: Channel) -> String {
        guard channel.recipients.isEmpty else {
            return channel.recipients.map { friendNickname(for: $0.id) ?? $0.displayName }.joined(separator: ", ")
        }
        return currentUser.map { "\($0.displayName)'s Group" } ?? "Group Direct Message"
    }

    /// Saves the open dialog once. An unchanged dialog closes without a
    /// request; the provider publishes the saved group, and failures keep the
    /// draft for another try.
    func saveGroupDirectMessage(_ presentation: GroupDirectMessageEditorStore.Presentation) {
        let store = groupDirectMessageEditor
        guard store.presentation == presentation, !store.isSaving else { return }
        let changes = store.changes
        guard changes.hasChanges else {
            store.presentation = nil
            return
        }
        let revision = store.revision
        store.isSaving = true
        store.error = nil
        startAccountChildTask(account: accountSession()) { model, session in
            do {
                _ = try await session.provider.editGroupDirectMessage(presentation.channel.id, changes: changes)
                guard model.isCurrentAccountSession(session), store.revision == revision else { return }
                store.isSaving = false
                store.presentation = nil
            } catch {
                guard model.isCurrentAccountSession(session), store.revision == revision else { return }
                if !(error is CancellationError) {
                    DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                }
                store.isSaving = false
                store.error = error is CancellationError
                    ? "The group change was interrupted. Check the group before trying again."
                    : error.localizedDescription
            }
        }
    }

    /// Opens Discord's Leave Group confirmation. `/leave` passes its `silent`
    /// option as the checkbox's initial state.
    func presentLeaveGroupDirectMessage(for channelID: ChannelID, silently: Bool = false) {
        guard let channel = groupDirectMessage(channelID) else { return }
        let store = groupDirectMessageLeave
        store.leavesSilently = silently
        store.confirmation = GroupDirectMessageLeaveStore.Confirmation(channel: channel)
    }

    /// Leaves a confirmed group once. The provider removes it from the DM
    /// list, which moves a selection on it to the next conversation; failures
    /// use the workspace error alert and keep the group.
    func leaveGroupDirectMessage(_ confirmation: GroupDirectMessageLeaveStore.Confirmation, silently: Bool) {
        let store = groupDirectMessageLeave
        let channel = confirmation.channel
        guard store.leaving.insert(channel.id).inserted else { return }
        startAccountChildTask(account: accountSession()) { model, session in
            defer {
                if model.isCurrentAccountSession(session) { store.leaving.remove(channel.id) }
            }
            do {
                try await session.provider.leaveGroupDirectMessage(channel.id, silently: silently)
            } catch is CancellationError {
                return
            } catch {
                guard model.isCurrentAccountSession(session) else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                model.errorMessage = "SakuraCord couldn’t leave \(channel.name). \(error.localizedDescription)"
            }
        }
    }
}
