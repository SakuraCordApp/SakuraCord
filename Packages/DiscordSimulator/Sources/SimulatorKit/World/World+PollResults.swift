import Foundation

/// Ending a poll early and the poll-result message Discord posts for it.
extension World {
    /// `POST /channels/{id}/polls/{id}/expire`: answers with the poll as it closes,
    /// then the poll counts as final and its result message follows.
    func expirePoll(_ messageID: Snowflake, in channelID: Snowflake, by userID: Snowflake) async throws -> JSON {
        let existing = try message(messageID, in: channelID)
        guard let poll = existing.poll else { throw WorldError.invalidBody("message has no poll") }
        guard existing.authorID == userID else { throw WorldError.missingPermissions }
        if poll.finalized || poll.expiry <= clock.now { throw WorldError(status: 400, code: 520_001, message: "This poll has already ended") }
        let now = clock.now
        let closing = try updateMessage(messageID, in: channelID) { $0.poll?.expiry = now }
        let response = renderMessage(closing, viewer: userID)
        let final = try updateMessage(messageID, in: channelID) { $0.poll?.finalized = true }
        var result = Message(id: nextID(), channelID: channelID, authorID: userID, content: "")
        result.type = 46
        result.reference = MessageReference(type: 0, messageID: messageID, channelID: channelID, guildID: nil)
        result.embeds = [pollResultEmbed(final.poll ?? poll)]
        channels[channelID]?.messages.append(result)
        await emit("MESSAGE_CREATE", renderMessageEvent(result), to: audience(for: try channel(channelID)))
        return response
    }

    /// The `poll_result` embed: question and totals, plus the winning answer when there is a single winner.
    private func pollResultEmbed(_ poll: Poll) -> JSON {
        let counts = poll.answers.map(\.voters.count)
        let total = counts.reduce(0, +)
        let best = counts.max() ?? 0
        func field(_ name: String, _ value: String) -> JSON {
            .object(JSONObject([("inline", false), ("name", .string(name)), ("value", .string(value))]))
        }
        var fields = [field("poll_question_text", poll.question), field("victor_answer_votes", String(best)), field("total_votes", String(total))]
        if best > 0, counts.count(where: { $0 == best }) == 1, let winner = poll.answers.first(where: { $0.voters.count == best }) {
            fields.append(field("victor_answer_id", String(winner.id)))
            fields.append(field("victor_answer_text", winner.text))
            if let emoji = winner.emoji { fields.append(field("victor_answer_emoji_name", emoji)) }
        }
        return .object(JSONObject([("type", "poll_result"), ("fields", .array(fields)), ("content_scan_version", 0)]))
    }
}
