import Foundation
import Observation
import SakuraCordModels

nonisolated struct InboxUnreadGroup: Equatable, Identifiable, Sendable {
    var id: ChannelID { channelID }
    let channelID: ChannelID
    let guildID: GuildID?
    let title: String
    let subtitle: String?
    let oldestReadMessageID: MessageID?
    let newestUnreadMessageID: MessageID
    let mentionCount: Int
    var isForum = false
    var isEvents = false
    var isAgeRestricted = false
    var events: [InboxScheduledEvent] = []
    var messages: [Message] = []
    var forumPosts: [ForumPost] = []
    var isLoaded = false
    /// Loaded content stays visible while an explicit refresh replaces it.
    var needsRevalidation = false
    var isCollapsed = false
    var errorMessage: String?

    /// Whether retained content still describes the same unread range.
    func canReuseContent(of retained: Self) -> Bool {
        retained.isLoaded && retained.errorMessage == nil && !isAgeRestricted
            && retained.isEvents == isEvents && retained.isForum == isForum
            && retained.oldestReadMessageID == oldestReadMessageID
            && retained.newestUnreadMessageID == newestUnreadMessageID
    }
}

/// A collapse change made in this window that Discord has not yet confirmed.
nonisolated struct InboxCollapseIntent: Equatable, Sendable {
    let isCollapsed: Bool
    let guildID: GuildID?
    let isEvents: Bool
}

@MainActor
@Observable
final class InboxState {
    var scrollRequest = MessageTimelineScrollRequest(target: .top)
    var isPresented = false
    var selectedMessageID: MessageID?
    var tab = InboxTab.unread
    var query = InboxMentionQuery()
    var settings = InboxSettings()
    var scheduledEvents = InboxScheduledEvents()
    var selectedEvent: InboxScheduledEvent?
    var ageRestrictedGuildID: GuildID?
    var acceptedAgeRestrictedGuildIDs = Set((PRBuildProfile.defaults.stringArray(forKey: "dev.sakuracord.inbox-age-agreements") ?? []).compactMap(GuildID.init))
    @ObservationIgnored var ageRestrictedAction: (@MainActor () -> Void)?
    @ObservationIgnored var eventMutationTasks: [GuildID: Task<Void, Never>] = [:]
    @ObservationIgnored var pendingEventAcknowledgements: [GuildID: ScheduledEventID] = [:]
    @ObservationIgnored var locallyUndoneEventGuilds: Set<GuildID> = []
    @ObservationIgnored var eventInterestTasks: [ScheduledEventID: Task<Void, Never>] = [:]
    var mentions: [Message] = []
    /// The filter `mentions` was fetched with; a different filter starts over.
    @ObservationIgnored var mentionsQuery: InboxMentionQuery?
    var hasMoreMentions = false
    @ObservationIgnored var needsMentionRevalidation = false
    var hiddenMentionIDs: Set<MessageID> = []
    var obscuredMentionIDs: Set<MessageID> = []
    var visibleMentions: [Message] { mentions.filter { !hiddenMentionIDs.contains($0.id) } }
    var threads: [ChannelID: MessageThreadSummary] = [:]
    var groups: [InboxUnreadGroup] = []
    var undoGroups: [InboxUnreadGroup] = []
    @ObservationIgnored var unreadOrder: [ChannelID] = []
    var isLoading = false
    /// Set only by an explicit refresh, so background revalidation stays quiet.
    var isRefreshing = false
    var hasMore: Bool {
        tab == .mentions ? hasMoreMentions
            : groups.contains { ($0.needsRevalidation || !$0.isLoaded) && !$0.isCollapsed }
    }
    var errorMessage: String?
    // Local choices win over remote echoes until their own save settles.
    @ObservationIgnored var pendingTab: InboxTab?
    @ObservationIgnored var pendingCollapse: [ChannelID: InboxCollapseIntent] = [:]
    @ObservationIgnored var settingsSyncTask: Task<Void, Never>?
    var dismissingIDs: Set<MessageID> = []
    @ObservationIgnored var rows: [MessageRowPresentation] = []
    @ObservationIgnored var rowsRevision: UInt64 = 0
    @ObservationIgnored let rowsUpdateJournal = MessageRowsUpdateJournal()
    @ObservationIgnored var loadTask: Task<Void, Never>?
    @ObservationIgnored var generation: UInt64 = 0
    @ObservationIgnored var nextBefore: MessageID?
    // Tombstones and the shared journal win over an older in-flight page.
    @ObservationIgnored var removedIDs: Set<MessageID> = []
    @ObservationIgnored var deletedIDs: Set<MessageID> = []
    @ObservationIgnored var refreshJournal: ConversationRefreshJournal?
    @ObservationIgnored var metadataTasks: [ChannelID: Task<Void, Never>] = [:]
    @ObservationIgnored var mutationTasks: [MessageID: Task<Void, Never>] = [:]
    @ObservationIgnored var settingsTask: Task<Void, Never>?
    @ObservationIgnored var bulkTask: Task<Void, Never>?

    var retainedMessages: some Sequence<Message> {
        ([mentions] + groups.map(\.messages) + undoGroups.map(\.messages)).joined()
    }

    /// Update every retained copy; report whether visible rows need publication.
    @discardableResult
    func replaceRetainedMessage(_ id: MessageID, with replacement: Message?) -> Bool {
        func updatedMessages(_ messages: [Message]) -> [Message]? {
            guard let index = messages.firstIndex(where: { $0.id == id }) else { return nil }
            if let replacement, messages[index] == replacement { return nil }
            var updated = messages
            if let replacement {
                updated[index] = replacement
            } else { updated.remove(at: index) }
            return updated
        }
        var visibleChanged = false
        if let updated = updatedMessages(mentions) {
            mentions = updated
            visibleChanged = true
        }
        for index in groups.indices {
            if let updated = updatedMessages(groups[index].messages) {
                groups[index].messages = updated
                visibleChanged = true
            }
        }
        for index in undoGroups.indices {
            if let updated = updatedMessages(undoGroups[index].messages) {
                undoGroups[index].messages = updated
            }
        }
        return visibleChanged
    }

    func rowInputs(channels: [Channel], guilds: [Guild]) -> [InboxMessageRowInput] {
        var messages = visibleMentions
        if tab == .unread {
            messages = []
            for group in groups where !group.isCollapsed {
                messages.append(contentsOf: group.messages)
                if !group.isLoaded { break }
            }
        }
        let channelsByID = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let guildsByID = Dictionary(uniqueKeysWithValues: guilds.map { ($0.id, $0) })
        return messages.map { source in
            var message = source
            if tab == .mentions, obscuredMentionIDs.contains(message.id) {
                message.attachments = []
                message.embeds = []
                message.components = []
                message.stickers = []
                message.poll = nil
                message.hasPoll = false
                message.forwardedSnapshot = nil
            }
            let channel = channelsByID[message.channelID]
            let thread = threads[message.channelID]
            let isForumPost = thread?.parentID.flatMap { channelsByID[$0]?.kind } == .forum
                || groups.contains { $0.isForum && $0.channelID == thread?.parentID }
            let context: MessageSearchRowContext? = tab == .mentions || isForumPost ? MessageSearchRowContext(
                channelID: message.channelID,
                sectionTitle: thread?.name ?? channel?.name ?? "Conversation",
                sectionSubtitle: (message.guildID ?? channel?.guildID ?? thread?.guildID).flatMap { guildsByID[$0]?.name },
                systemImage: isForumPost ? "bubble.left.and.bubble.right"
                    : thread != nil ? SakuraCordSystemSymbol.thread : channel?.guildID == nil ? "bubble.left" : "number",
                showsSectionHeader: true, isInbox: true
            ) : nil
            return InboxMessageRowInput(message: message, context: context)
        }
    }

    func publish(channels: [Channel], guilds: [Guild], preparedRows: [MessageRowPresentation]? = nil, notifying model: AnyObject) {
        let oldRows = rows
        rows = preparedRows ?? InboxMessageRowInput.reusingRows(rows, inputs: rowInputs(channels: channels, guilds: guilds))
        rowsRevision &+= 1
        rowsUpdateJournal.append(MessageRowsUpdateRecordBuilder.make(oldRows: oldRows, newRows: rows, revision: rowsRevision))
        NotificationCenter.default.post(name: .sakuracordMessageRowsDidChange, object: model)
    }

    func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
        generation &+= 1
        isLoading = false
        refreshJournal = nil
    }

    func clear(notifying model: AnyObject) {
        cancelLoad()
        metadataTasks.values.forEach { $0.cancel() }
        metadataTasks = [:]
        mutationTasks.values.forEach { $0.cancel() }
        mutationTasks = [:]
        settingsTask?.cancel()
        settingsTask = nil
        settingsSyncTask?.cancel()
        settingsSyncTask = nil
        pendingTab = nil
        pendingCollapse = [:]
        bulkTask?.cancel()
        bulkTask = nil
        isPresented = false
        selectedMessageID = nil
        tab = .unread
        query = InboxMentionQuery()
        settings = InboxSettings()
        scheduledEvents = InboxScheduledEvents()
        selectedEvent = nil
        ageRestrictedGuildID = nil
        ageRestrictedAction = nil
        eventMutationTasks.values.forEach { $0.cancel() }
        eventMutationTasks = [:]
        eventInterestTasks.values.forEach { $0.cancel() }
        eventInterestTasks = [:]
        pendingEventAcknowledgements = [:]
        locallyUndoneEventGuilds = []
        mentions = []
        mentionsQuery = nil
        hasMoreMentions = false
        needsMentionRevalidation = false
        hiddenMentionIDs = []
        obscuredMentionIDs = []
        threads = [:]
        groups = []
        undoGroups = []
        unreadOrder = []
        nextBefore = nil
        errorMessage = nil
        isRefreshing = false
        dismissingIDs = []
        removedIDs = []
        deletedIDs = []
        publish(channels: [], guilds: [], notifying: model)
    }
}

nonisolated struct InboxMessageRowInput: Equatable, Sendable {
    let message: Message
    let context: MessageSearchRowContext?

    static func reusingRows(_ oldRows: [MessageRowPresentation], inputs: [Self]) -> [MessageRowPresentation] {
        let previous = Dictionary(uniqueKeysWithValues: oldRows.map { ($0.message.id, $0) })
        func continues(_ first: Self, _ second: Self) -> Bool {
            first.context == nil && second.context == nil && first.message.channelID == second.message.channelID
                && MessageGrouping.continuesGroup(from: first.message, to: second.message,
                                                  calendar: .autoupdatingCurrent,
                                                  continuationInterval: MessageGrouping.defaultContinuationInterval)
        }
        return inputs.enumerated().map { index, input in
            let message = input.message
            let startsGroup = index == 0 || !continues(inputs[index - 1], input)
            let endsGroup = index == inputs.count - 1 || !continues(input, inputs[index + 1])
            let startsDay = input.context == nil && (index == 0
                || inputs[index - 1].message.channelID != message.channelID
                || !Calendar.autoupdatingCurrent.isDate(inputs[index - 1].message.timestamp, inSameDayAs: message.timestamp))
            if let row = previous[message.id], row.message == message, row.searchContext == input.context,
               row.startsGroup == startsGroup, row.endsGroup == endsGroup, row.startsDay == startsDay { return row }
            return MessageRowPresentation(message: message, startsGroup: startsGroup, endsGroup: endsGroup, startsDay: startsDay,
                                          replyPreview: message.replyPreview, isReplyAvailable: message.replyPreview != nil,
                                          searchContext: input.context)
        }
    }
}
