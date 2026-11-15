import Foundation
import Observation
import SakuraCordModels

/// Discord's Leave Group confirmation and the conversations being left,
/// closed or decided.
@Observable
final class DirectMessageExitStore {
    struct Confirmation: Identifiable, Equatable {
        /// The group as it was when the confirmation opened.
        let channel: Channel
        var id: ChannelID { channel.id }
    }

    var confirmation: Confirmation?
    /// Discord's "Leave without notifying other members" checkbox.
    var leavesSilently = false
    /// Conversations `exitDirectMessage` is leaving, closing or deciding,
    /// so a repeat request is ignored.
    var exitingChannelIDs: Set<ChannelID> = []

    func reset() {
        confirmation = nil
        leavesSilently = false
        exitingChannelIDs = []
    }
}
