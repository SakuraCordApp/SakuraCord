import SwiftUI

/// Discord's Leave Group confirmation. Its "Leave without notifying other
/// members" checkbox is the alert's suppression toggle, scoped to a background
/// host so other alerts in the window never show it.
struct LeaveGroupPresentationModifier: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.background {
            LeaveGroupConfirmationHost(model: model, store: model.groupDirectMessageLeave)
        }
    }
}

private struct LeaveGroupConfirmationHost: View {
    let model: AppModel
    @Bindable var store: GroupDirectMessageLeaveStore

    var body: some View {
        Color.clear
            .alert(
                "Leave ‘\(store.confirmation?.channel.name ?? "Group")’",
                isPresented: Binding(
                    get: { store.confirmation != nil },
                    set: { if !$0 { store.confirmation = nil } }
                ),
                presenting: store.confirmation
            ) { confirmation in
                Button("Leave Group", role: .destructive) {
                    model.leaveGroupDirectMessage(confirmation, silently: store.leavesSilently)
                }
                Button("Cancel", role: .cancel) {}
            } message: { confirmation in
                Text("Are you sure you want to leave \(confirmation.channel.name)? You won’t be able to rejoin this group unless you are re-invited.")
            }
            .dialogSuppressionToggle("Leave without notifying other members", isSuppressed: $store.leavesSilently)
    }
}
