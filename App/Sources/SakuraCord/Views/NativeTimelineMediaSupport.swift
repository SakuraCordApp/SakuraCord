import SakuraCordModels

enum NativeTimelineReplyMediaPolicy {
    static func avatarKey(
        for preview: MessageReplyPreview?
    ) -> MediaImageKey? {
        preview?.author.avatarURL.map(MediaImageKey.avatar)
    }
}
