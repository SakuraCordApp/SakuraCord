import Foundation

/// Older history for a channel, written out the first time the channel is
/// looked up. Large worlds would take too long to build and hold otherwise;
/// the seed makes the history the same whenever it's generated.
struct HistoryPlan: Sendable {
    var count: Int
    var seed: UInt64
    var authors: [Snowflake]
    var kind: CommunityKind
    /// The history spans `start` up to `end`, which is before the channel's first stored message.
    var start: Date
    var end: Date
}

extension World {
    func planHistory(_ channelID: Snowflake, _ plan: HistoryPlan) {
        guard plan.count > 0, !plan.authors.isEmpty else { return }
        pendingHistory[channelID] = plan
    }

    func materializeHistory(_ channelID: Snowflake) {
        guard let plan = pendingHistory.removeValue(forKey: channelID), let channel = channels[channelID] else { return }
        var rng = SeededRandom(seed: plan.seed)
        let step = plan.end.timeIntervalSince(plan.start) / Double(plan.count)
        var history: [Message] = []
        for index in 0 ..< plan.count {
            // Bursts of conversation: most messages follow closely, some after a long pause.
            let at = plan.start.addingTimeInterval(step * (Double(index) + rng.unit() * 0.9))
            var message = Message(id: nextID(at: at), channelID: channelID, authorID: rng.pick(plan.authors),
                                  content: DemoText.communityMessage(plan.kind, &rng))
            if let previous = history.last, rng.chance(0.1) {
                message.type = 19
                message.reference = MessageReference(type: 0, messageID: previous.id, channelID: channelID, guildID: channel.guildID)
                if previous.authorID != message.authorID { message.mentions = [previous.authorID] }
            }
            if rng.chance(0.15) {
                var reaction = Reaction(emojiName: rng.pick(["👍", "😂", "❤️", "🔥", "👀", "🎉", "😭", "💯"]))
                reaction.users = Array(Set((0 ..< 1 + Int(rng.next() % 4)).map { _ in rng.pick(plan.authors) })).sorted()
                message.reactions = [reaction]
            }
            if rng.chance(0.04) { message.editedAt = at.addingTimeInterval(120) }
            history.append(message)
        }
        channels[channelID]?.messages.insert(contentsOf: history, at: 0)
        channels[channelID]?.totalMessageSent += history.count
    }
}
