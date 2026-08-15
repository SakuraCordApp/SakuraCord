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
        return .object([
            "parse": .array([
                .string("users"),
                .string("roles"),
                .string("everyone"),
            ]),
            "replied_user": .bool(false),
        ])
    }
}
