import SakuraCordModels

extension SendMessageDraft {
    func replyReferencePayload(for messageID: MessageID) -> JSONValue {
        .object([
            "type": .number(0),
            "message_id": .string(messageID.description),
            "channel_id": .string(channelID.description),
        ])
    }

    var replyAllowedMentionsPayload: JSONValue? {
        guard replyTo != nil, !mentionsRepliedUser else { return nil }
        return .quietReplyAllowedMentions
    }
}

extension Message {
    /// An edit that omits `allowed_mentions` pings the replied user again, so a
    /// reply keeps the ping off unless it was sent with it. Discord lists the
    /// replied user in `mentions` for the ping and for a mention in the text,
    /// so only a mention without such a token shows the ping was on.
    var editAllowedMentionsPayload: JSONValue? {
        guard replyTo != nil else { return nil }
        if let repliedID = replyPreview?.author.id,
           mentionedUsers.contains(where: { $0.id == repliedID }),
           !content.contains("<@\(repliedID.rawValue)>"),
           !content.contains("<@!\(repliedID.rawValue)>")
        {
            return nil
        }
        return .quietReplyAllowedMentions
    }
}

private extension JSONValue {
    static let quietReplyAllowedMentions: JSONValue = .object([
        "parse": .array([
            .string("users"),
            .string("roles"),
            .string("everyone"),
        ]),
        "replied_user": .bool(false),
    ])
}
