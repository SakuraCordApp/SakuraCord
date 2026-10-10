import Foundation
import Observation
import SakuraCordModels

/// Presentation state for Discord's Leave Group confirmation.
@Observable
final class GroupDirectMessageLeaveStore {
    struct Confirmation: Identifiable, Equatable {
        /// The group as it was when the confirmation opened.
        let channel: Channel
        var id: ChannelID { channel.id }
    }

    var confirmation: Confirmation?
    /// Discord's "Leave without notifying other members" checkbox.
    var leavesSilently = false
    /// Groups with a leave request in flight, so a second confirmation is ignored.
    var leaving: Set<ChannelID> = []

    func reset() {
        confirmation = nil
        leavesSilently = false
        leaving = []
    }
}
