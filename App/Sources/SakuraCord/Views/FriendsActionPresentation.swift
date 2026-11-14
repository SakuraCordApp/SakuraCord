import SakuraCordModels
import SwiftUI

/// Relationship dialogs belong to the workspace, regardless of the initiating surface.
struct FriendsActionPresentation: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        let friends = model.friends
        let joinsVoice = model.ignoredUsers.voiceConfirmation != nil
        let warningChannel = model.ignoredUsers.voiceWarning
        content
        .onChange(of: model.selectedChannel, initial: true) { model.reconcileIgnoredGroupWarning() }
        .onChange(of: model.ignoredUsers.ignoredUserIDs) { model.reconcileIgnoredGroupWarning() }
        .alert("An ignored account is in this group", isPresented: Binding(
            get: { model.ignoredUsers.groupWarning != nil },
            set: { if !$0 { model.ignoredUsers.groupWarning = nil } }
        ), presenting: model.ignoredUsers.groupWarning) { channel in
            Button("Continue", role: .cancel) { model.dismissIgnoredGroupWarning(channel) }
        } message: { _ in
            Text("Their messages stay hidden until you reveal them. You can still send messages and join calls together.")
        }
        .windowModal(
            item: Binding(
                get: { RelationshipConfirmationPresentation(friends.confirmation) },
                set: { if $0 == nil, RelationshipConfirmationPresentation(friends.confirmation) != nil { friends.confirmation = nil } }
            ),
            cornerRadius: InterfaceScale.metric(32),
            cornerStyle: .circular
        ) { RelationshipConfirmationView(model: model, presentation: $0) }
        .alert(
            confirmationTitle(alertConfirmation),
            isPresented: Binding(
                get: { alertConfirmation != nil },
                set: { if !$0, alertConfirmation != nil { friends.confirmation = nil } }
            ),
            presenting: alertConfirmation
        ) { confirmation in
            if let action = confirmation.alertAction {
                Button(action.title, role: action.role) {
                    model.confirmFriendsAction(confirmation)
                }
            }
            Button("Cancel", role: .cancel) { friends.confirmation = nil }
        } message: { confirmation in
            Text(confirmationMessage(confirmation))
        }
        .alert("An ignored account is in this call", isPresented: Binding(
            get: { model.ignoredUsers.voiceWarning != nil },
            set: { if !$0 { model.ignoredUsers.voiceWarning = nil } }
        )) {
            Button(joinsVoice ? "Join Anyway" : "Stay in Call") {
                model.ignoredUsers.resolveVoiceWarning(true)
            }
            Button(joinsVoice ? "Cancel" : "Leave Call", role: .cancel) {
                let leavesCall = !joinsVoice && model.activeVoiceChannel?.id == warningChannel?.id
                model.ignoredUsers.resolveVoiceWarning(false)
                if leavesCall { Task { await model.leaveVoice() } }
            }
        } message: {
            Text(joinsVoice ? "You may hear or see them if you join." : "You may hear or see them while you’re in this call.")
        }
        .alert(
            "Friend request failed",
            isPresented: Binding(get: { friends.requestFailure != nil }, set: { if !$0 { friends.requestFailure = nil } })
        ) {
            Button("OK", role: .cancel) { friends.requestFailure = nil }
        } message: {
            Text(friends.requestFailure ?? "")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { friends.actionError != nil }, set: { if !$0 { friends.actionError = nil } })
        ) {
            Button("OK", role: .cancel) { friends.actionError = nil }
        } message: {
            Text(friends.actionError ?? "")
        }
    }

    private var alertConfirmation: FriendsConfirmation? {
        model.friends.confirmation.flatMap { $0.alertAction == nil ? nil : $0 }
    }

    // Official stable633029 copy for removal.
    private func confirmationTitle(_ confirmation: FriendsConfirmation?) -> String {
        switch confirmation {
        case .removeFriend(let user): "Remove ‘\(model.friendDisplayName(user))’"
        case .acceptStranger: "Accept Friend Request?"
        case .block, .ignore, nil: ""
        }
    }

    private func confirmationMessage(_ confirmation: FriendsConfirmation) -> String {
        switch confirmation {
        case .removeFriend(let user):
            "Are you sure you want to remove \(model.friendDisplayName(user)) from your friends?"
        case .acceptStranger(let user):
            "Discord wants you to confirm that you know \(model.friendDisplayName(user)) before accepting their request."
        case .block, .ignore: ""
        }
    }
}

private extension FriendsConfirmation {
    /// The confirming button for the confirmations that stay alerts; Ignore
    /// and Block use the relationship modal.
    var alertAction: (title: String, role: ButtonRole?)? {
        switch self {
        case .removeFriend: ("Remove Friend", .destructive)
        case .acceptStranger: ("Accept", nil)
        case .block, .ignore: nil
        }
    }
}
