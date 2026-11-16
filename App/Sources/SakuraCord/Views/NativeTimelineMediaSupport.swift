import SakuraCordModels

enum NativeTimelineReplyMediaPolicy {
    static func avatarKey(
        for preview: MessageReplyPreview?
    ) -> MediaImageKey? {
        preview.map { .avatar($0.author.avatarURL) }
    }

    static func emojiKeys(
        for preview: MessageReplyPreview,
        in message: Message,
        model: AppModel?
    ) -> [MediaImageKey] {
        let summary = NativeTimelineReplyMetrics.summary(for: preview, in: message, model: model)
        return summary.emojis.compactMap { item in
            .emoji(EmojiReference(rawToken: item.emoji.rawToken), in: model?.customEmojiURLsByID)
        }
    }
}
