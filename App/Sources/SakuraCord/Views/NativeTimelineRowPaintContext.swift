import AppKit
import SakuraCordModels

/// What timeline rows read from the app while they paint, gathered on the
/// main thread.
///
/// The row painter reads `current` wherever it once read `AppModel`. Callers
/// that rasterize rows set it around the paint; a caller on the main thread
/// that does not gets one built from the model it passes.
nonisolated final class NativeTimelineRowPaintContext: @unchecked Sendable {
    @TaskLocal static var current: NativeTimelineRowPaintContext?

    let currentUserID: UserID?
    let underlinesLinks: Bool
    let roleColorDisplay: RoleColorDisplay
    let interfaceSettings: InterfaceSettingsSnapshot
    let cosmeticPolicy: ProfileCosmeticPolicy
    let customEmojiURLsByID: CustomEmojiImageURLs
    let voiceSpeedLabel: String
    let activeVoiceMessageID: VoiceMessagePlaybackID?

    private let roleIDsByGuild: [GuildID: Set<RoleID>]
    private let authors: [MessageID: MessageAuthorPresentation]
    private let replyAuthors: [MessageID: MessageAuthorPresentation]
    private let replySummaries: [MessageID: MessageReplySummary.Prepared]
    private let threadPreviews: [ChannelID: Message]
    private let reactionUpdates: Set<MessageID>
    private let reactionCreations: Set<MessageID>
    private let pollVotes: Set<MessageID>
    private let pollVoteRemovals: Set<MessageID>

    @MainActor
    init(
        model: AppModel,
        items: some Sequence<NativeMessageTimelineItem>
    ) {
        currentUserID = model.currentUser?.id
        underlinesLinks = model.accessibilitySettings.underlinesLinks
        roleColorDisplay = model.accessibilitySettings.roleColorDisplay
        interfaceSettings = model.interfaceSettings
        cosmeticPolicy = model.cosmeticPolicy
        customEmojiURLsByID = model.customEmojiURLsByID
        voiceSpeedLabel = model.voiceMessagePlayback.speedLabel
        activeVoiceMessageID = model.voiceMessagePlayback.activeID

        var roleIDsByGuild: [GuildID: Set<RoleID>] = [:]
        var authors: [MessageID: MessageAuthorPresentation] = [:]
        var replyAuthors: [MessageID: MessageAuthorPresentation] = [:]
        var replySummaries: [MessageID: MessageReplySummary.Prepared] = [:]
        var threadPreviews: [ChannelID: Message] = [:]
        var reactionUpdates: Set<MessageID> = []
        var reactionCreations: Set<MessageID> = []
        var pollVotes: Set<MessageID> = []
        var pollVoteRemovals: Set<MessageID> = []
        for item in items {
            guard case let .message(row, _, _) = item else { continue }
            let message = row.message
            if let guildID = message.guildID, roleIDsByGuild[guildID] == nil {
                roleIDsByGuild[guildID] = model.currentUserRoleIDs(for: guildID)
            }
            authors[message.id] = model.authorPresentation(for: message)
            if let preview = row.replyPreview {
                replyAuthors[message.id] = model.authorPresentation(for: preview, in: message)
                replySummaries[message.id] = NativeTimelineReplyMetrics.summary(for: preview, in: message, model: model)
            }
            if let thread = message.thread, let preview = model.threadPreviewMessages[thread.id] {
                threadPreviews[thread.id] = preview
                // The thread card shows its preview as a reply line of its own.
                let line = MessageReplyPreview.presenting(preview)
                replyAuthors[preview.id] = model.authorPresentation(for: line, in: preview)
                replySummaries[preview.id] = NativeTimelineReplyMetrics.summary(for: line, in: preview, model: model)
            }
            if model.canUpdateReactions(on: message) { reactionUpdates.insert(message.id) }
            if model.canCreateReactions(on: message) { reactionCreations.insert(message.id) }
            if message.poll != nil {
                if model.canUpdatePollVote(on: message) { pollVotes.insert(message.id) }
                if model.canUpdatePollVote(on: message, removing: true) { pollVoteRemovals.insert(message.id) }
            }
        }
        self.roleIDsByGuild = roleIDsByGuild
        self.authors = authors
        self.replyAuthors = replyAuthors
        self.replySummaries = replySummaries
        self.threadPreviews = threadPreviews
        self.reactionUpdates = reactionUpdates
        self.reactionCreations = reactionCreations
        self.pollVotes = pollVotes
        self.pollVoteRemovals = pollVoteRemovals
    }

    /// The context set around this paint, or, on the main thread, one built
    /// from the caller's model.
    static func fallback(model: AppModel?, item: NativeMessageTimelineItem) -> NativeTimelineRowPaintContext? {
        if let current { return current }
        guard let model, Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated { NativeTimelineRowPaintContext(model: model, items: [item]) }
    }

    func currentUserRoleIDs(for guildID: GuildID?) -> Set<RoleID> {
        guildID.flatMap { roleIDsByGuild[$0] } ?? []
    }

    func authorPresentation(for message: Message) -> MessageAuthorPresentation? {
        authors[message.id]
    }

    func authorPresentation(forReplyIn message: Message) -> MessageAuthorPresentation? {
        replyAuthors[message.id]
    }

    func replySummary(for preview: MessageReplyPreview, in message: Message) -> MessageReplySummary.Prepared {
        replySummaries[message.id] ?? MessageReplySummary.prepare(preview.content)
    }

    func threadPreviewMessage(for threadID: ChannelID) -> Message? {
        threadPreviews[threadID]
    }

    func canUpdateReactions(on message: Message) -> Bool {
        reactionUpdates.contains(message.id)
    }

    func canCreateReactions(on message: Message) -> Bool {
        reactionCreations.contains(message.id)
    }

    func canUpdatePollVote(on message: Message, removing: Bool = false) -> Bool {
        (removing ? pollVoteRemovals : pollVotes).contains(message.id)
    }

    func isVoiceMessageActive(_ id: VoiceMessagePlaybackID) -> Bool {
        activeVoiceMessageID == id
    }
}
