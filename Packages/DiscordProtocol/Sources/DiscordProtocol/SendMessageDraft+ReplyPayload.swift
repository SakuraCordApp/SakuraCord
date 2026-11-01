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
    /// reply that was sent without the ping keeps it off.
    var editAllowedMentionsPayload: JSONValue? {
        guard replyTo != nil, let repliedAuthor = replyPreview?.author,
              !mentionedUsers.contains(where: { $0.id == repliedAuthor.id })
        else { return nil }
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
