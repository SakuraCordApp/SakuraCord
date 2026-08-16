import CoreText
import DiscordProtocol
import Foundation
import MessageRendering
import SakuraCordModels

nonisolated enum MemberStoreMerge {
    static func merging(
        existing: [UserID: Member],
        updates: [Member]
    ) -> [UserID: Member] {
        var result = existing
        for var member in updates {
            if member.memberListIndex == nil {
                member.memberListIndex = result[member.id]?.memberListIndex
            }
            result[member.id] = member
        }
        return result
    }
}

actor OfflineCredentialStore: CredentialStore {
    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        throw ChatProviderError.invalidRequest(
            "Credential storage is unavailable in offline testing mode.")
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        throw ChatProviderError.invalidRequest(
            "Credentials are unavailable in offline testing mode.")
    }

    func remove(_ handle: CredentialHandle) async throws {}

    func handles() async throws -> [CredentialHandle] {
        []
    }
}

nonisolated final class NativeTimelineAttributedTextBox: @unchecked Sendable {
    let value: NSAttributedString
    let framesetter: CTFramesetter
    let layoutHeightAdjustment: CGFloat

    nonisolated init(
        _ value: NSAttributedString,
        layoutHeightAdjustment: CGFloat = 0
    ) {
        self.value = value
        self.layoutHeightAdjustment = layoutHeightAdjustment
        framesetter = CTFramesetterCreateWithAttributedString(value)
    }
}

struct NativeTimelineTextPlan: Equatable, Sendable {
    let preparedText: RichMessageAttributedText.Prepared?
    let linkedImages: [LinkedImageReference]
    let attributedText: NativeTimelineAttributedTextBox?
    let baseFontSize: CGFloat

    nonisolated static func == (
        lhs: NativeTimelineTextPlan,
        rhs: NativeTimelineTextPlan
    ) -> Bool {
        lhs.preparedText == rhs.preparedText
            && lhs.linkedImages == rhs.linkedImages
            && lhs.baseFontSize == rhs.baseFontSize
    }

    nonisolated static func make(
        for message: Message,
        currentUserID: UserID? = nil
    ) -> Self {
        let baseFontSize: CGFloat =
            if message.type.hasGeneratedContent {
                13
            } else {
                15
            }
        let visibleContent =
            if message.type.hasGeneratedContent {
                SystemMessagePresentation.label(
                    for: message,
                    currentUserID: currentUserID
                )
            } else {
                MessageEmbedPresentation.visibleMessageContent(for: message)
            }
        let linkedPresentation = LinkedImagePresentation(content: visibleContent)
        let prepared = linkedPresentation.visibleText.isEmpty
            ? nil
            : RichMessageAttributedText.prepare(
                source: linkedPresentation.visibleText
            )
        // Embed descriptions and field values are parsed again when their
        // width-dependent Core Text boxes are built. Prime the bounded,
        // process-local parse cache while message rows are already being
        // prepared off-main so a cold rich channel cannot move markdown
        // tokenization back onto the UI thread during first layout.
        for embed in MessageEmbedPresentation.visibleEmbeds(for: message) {
            if let description = embed.description {
                _ = RichMessageAttributedText.prepare(source: description)
            }
            for field in embed.fields {
                _ = RichMessageAttributedText.prepare(source: field.value)
            }
        }
        let attributed: NativeTimelineAttributedTextBox?
        if message.type.hasGeneratedContent {
            attributed = NativeTimelineAttributedTextBox(
                SystemMessagePresentation.attributedLabel(
                    for: message,
                    currentUserID: currentUserID,
                    baseFontSize: baseFontSize
                )
            )
        } else if let prepared, prepared.tokens.isEmpty {
            attributed = NativeTimelineAttributedTextBox(
                DiscordMarkdown.appKitAttributed(
                    prepared.markdownPlan,
                    baseFontSize: prepared.isEmojiOnly
                        ? 48
                        : baseFontSize
                )
            )
        } else {
            attributed = nil
        }
        return Self(
            preparedText: prepared,
            linkedImages: linkedPresentation.images,
            attributedText: attributed,
            baseFontSize: baseFontSize
        )
    }
}

nonisolated struct MessageSearchRowContext: Equatable, Sendable {
    let channelID: ChannelID
    let sectionTitle: String
    let sectionSubtitle: String?
    let systemImage: String
    let showsSectionHeader: Bool
}

final class MessageRowPresentation: Identifiable, Equatable, Sendable {
    var id: MessageID {
        message.id
    }

    let message: Message
    let startsGroup: Bool
    let startsDay: Bool
    let replyPreview: MessageReplyPreview?
    let isReplyAvailable: Bool
    let textPlan: NativeTimelineTextPlan
    let searchContext: MessageSearchRowContext?

    var replyMessageID: MessageID? {
        message.replyTo ?? replyPreview?.messageID
    }

    nonisolated init(
        message: Message,
        startsGroup: Bool,
        startsDay: Bool,
        replyPreview: MessageReplyPreview?,
        isReplyAvailable: Bool,
        textPlan: NativeTimelineTextPlan? = nil,
        searchContext: MessageSearchRowContext? = nil
    ) {
        self.message = message
        self.startsGroup = startsGroup
        self.startsDay = startsDay
        self.replyPreview = replyPreview
        self.isReplyAvailable = isReplyAvailable
        self.textPlan = textPlan ?? NativeTimelineTextPlan.make(for: message)
        self.searchContext = searchContext
    }

    nonisolated static func == (
        lhs: MessageRowPresentation,
        rhs: MessageRowPresentation
    ) -> Bool {
        if lhs === rhs {
            return true
        }
        return lhs.message == rhs.message
            && lhs.startsGroup == rhs.startsGroup
            && lhs.startsDay == rhs.startsDay
            && lhs.replyPreview == rhs.replyPreview
            && lhs.isReplyAvailable == rhs.isReplyAvailable
            && lhs.textPlan == rhs.textPlan
            && lhs.searchContext == rhs.searchContext
    }
}

nonisolated enum MessageSearchPresentation {
    static func rows(
        for page: MessageSearchPage,
        channelsByID: [ChannelID: Channel]
    ) -> [MessageRowPresentation] {
        var previousChannelID: ChannelID?
        return page.results.map { result in
            let message = result.hit
            let channel = channelsByID[message.channelID]
            let contextMessagesByID = Dictionary(
                uniqueKeysWithValues: result.messages.map { ($0.id, $0) }
            )
            let replyPreview = message.replyTo.flatMap { replyID in
                contextMessagesByID[replyID].map(MessageReplyPreview.init(message:))
                    ?? message.replyPreview
            }
            let showsSectionHeader = previousChannelID != message.channelID
            previousChannelID = message.channelID
            return MessageRowPresentation(
                message: message,
                startsGroup: true,
                startsDay: false,
                replyPreview: replyPreview,
                isReplyAvailable: replyPreview != nil,
                searchContext: MessageSearchRowContext(
                    channelID: message.channelID,
                    sectionTitle: sectionTitle(for: channel, message: message),
                    sectionSubtitle: channel?.category,
                    systemImage: sectionSystemImage(for: channel),
                    showsSectionHeader: showsSectionHeader
                )
            )
        }
    }

    private static func sectionTitle(
        for channel: Channel?,
        message: Message
    ) -> String {
        guard let channel else {
            return "Channel \(message.channelID.description.suffix(6))"
        }
        switch channel.kind {
        case .directMessage, .groupDirectMessage:
            return channel.name
        default:
            return "# \(channel.name)"
        }
    }

    private static func sectionSystemImage(for channel: Channel?) -> String {
        switch channel?.kind {
        case .directMessage:
            return "at"
        case .groupDirectMessage:
            return "person.2.fill"
        case .announcement:
            return "megaphone.fill"
        case .forum:
            return "bubble.left.and.bubble.right.fill"
        case .voice:
            return "bubble.left.fill"
        default:
            return "number"
        }
    }
}

nonisolated enum MessageGrouping {
    /// Discord's current cozy layout uses a seven-minute continuation barrier.
    private static let continuationInterval: TimeInterval = 7 * 60

    static func rows(for messages: [Message], calendar: Calendar = .autoupdatingCurrent)
        -> [MessageRowPresentation]
    {
        let messagesByID = messageLookup(for: messages)
        return messages.indices.map { index in
            row(
                at: index,
                in: messages,
                messagesByID: messagesByID,
                calendar: calendar
            )
        }
    }

    static func rowsCooperatively(
        for messages: [Message],
        calendar: Calendar = .autoupdatingCurrent,
        batchSize: Int = 4
    ) async -> [MessageRowPresentation] {
        let messagesByID = messageLookup(for: messages)
        let batchSize = max(1, batchSize)
        var result: [MessageRowPresentation] = []
        result.reserveCapacity(messages.count)
        for index in messages.indices {
            result.append(
                autoreleasepool {
                    row(
                        at: index,
                        in: messages,
                        messagesByID: messagesByID,
                        calendar: calendar
                    )
                }
            )
            if (index + 1).isMultiple(of: batchSize),
               index + 1 < messages.endIndex
            {
                await Task.yield()
            }
        }
        return result
    }

    private static func messageLookup(
        for messages: [Message]
    ) -> [MessageID: Message] {
        guard messages.contains(where: { $0.replyTo != nil }) else {
            return [:]
        }
        return Dictionary(
            messages.map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
    }

    private static func row(
        at index: Int,
        in messages: [Message],
        messagesByID: [MessageID: Message],
        calendar: Calendar
    ) -> MessageRowPresentation {
        let message = messages[index]
        let replyPreview =
            message.replyTo.flatMap { messageID -> MessageReplyPreview? in
                if let referenced = messagesByID[messageID] {
                    return MessageReplyPreview(message: referenced)
                }
                return message.replyPreview
            }
        guard index > 0 else {
            return MessageRowPresentation(
                message: message,
                startsGroup: true,
                startsDay: true,
                replyPreview: replyPreview,
                isReplyAvailable:
                    replyPreview.map {
                        messagesByID[$0.messageID] != nil
                    } ?? false
            )
        }
        let previous = messages[index - 1]
        return MessageRowPresentation(
            message: message,
            startsGroup: !continuesGroup(
                from: previous,
                to: message,
                calendar: calendar
            ),
            startsDay: !calendar.isDate(
                previous.timestamp,
                inSameDayAs: message.timestamp
            ),
            replyPreview: replyPreview,
            isReplyAvailable:
                replyPreview.map {
                    messagesByID[$0.messageID] != nil
                } ?? false
        )
    }

    private static func isGroupable(_ message: Message) -> Bool {
        !message.type.hasGeneratedContent && message.type != .chatInputCommand
    }

    static func appendingRow(
        for message: Message,
        after previous: Message?,
        replyPreview: MessageReplyPreview?,
        isReplyAvailable: Bool,
        textPlan: NativeTimelineTextPlan? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) -> MessageRowPresentation {
        guard let previous else {
            return MessageRowPresentation(
                message: message,
                startsGroup: true,
                startsDay: true,
                replyPreview: replyPreview,
                isReplyAvailable: isReplyAvailable,
                textPlan: textPlan
            )
        }
        return MessageRowPresentation(
            message: message,
            startsGroup: !continuesGroup(
                from: previous,
                to: message,
                calendar: calendar
            ),
            startsDay: !calendar.isDate(
                previous.timestamp,
                inSameDayAs: message.timestamp
            ),
            replyPreview: replyPreview,
            isReplyAvailable: isReplyAvailable,
            textPlan: textPlan
        )
    }

    static func reconcileChangedMessage(
        id changedID: MessageID,
        replacement: Message?,
        messages: [Message],
        availableMessageIDs: Set<MessageID>,
        rows: inout [MessageRowPresentation],
        neighborIndex: Int? = nil,
        messageIndex: ((MessageID) -> Int?)? = nil,
        replyingMessageIDs: Set<MessageID>? = nil,
        replacementTextPlan: NativeTimelineTextPlan? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) -> IndexSet {
        guard rows.count == messages.count else {
            rows = self.rows(for: messages, calendar: calendar)
            return IndexSet(integersIn: messages.indices)
        }
        var affected = IndexSet()
        if let replacement,
           let index =
                messageIndex?(replacement.id)
                ?? messages.firstIndex(where: { $0.id == replacement.id })
        {
            affected.insert(index)
            if messages.indices.contains(index + 1) {
                affected.insert(index + 1)
            }
        } else if let neighborIndex,
                  messages.indices.contains(neighborIndex)
        {
            affected.insert(neighborIndex)
        }
        if let replyingMessageIDs, let messageIndex {
            for replyingMessageID in replyingMessageIDs {
                if let index = messageIndex(replyingMessageID) {
                    affected.insert(index)
                }
            }
        } else {
            for index in messages.indices
            where messages[index].replyTo == changedID {
                affected.insert(index)
            }
        }

        for index in affected {
            let message = messages[index]
            let priorRow = rows[index]
            let replyPreview: MessageReplyPreview?
            if message.replyTo == changedID, let replacement {
                replyPreview = MessageReplyPreview(message: replacement)
            } else {
                replyPreview = message.replyPreview ?? priorRow.replyPreview
            }
            let startsGroup: Bool
            let startsDay: Bool
            if index == messages.startIndex {
                startsGroup = true
                startsDay = true
            } else {
                startsGroup = !continuesGroup(
                    from: messages[index - 1],
                    to: message,
                    calendar: calendar
                )
                startsDay = !calendar.isDate(
                    messages[index - 1].timestamp,
                    inSameDayAs: message.timestamp
                )
            }
            rows[index] = MessageRowPresentation(
                message: message,
                startsGroup: startsGroup,
                startsDay: startsDay,
                replyPreview: replyPreview,
                isReplyAvailable:
                    replyPreview.map {
                        availableMessageIDs.contains($0.messageID)
                    } ?? false,
                textPlan:
                    priorRow.message == message
                    ? priorRow.textPlan
                    : message.id == replacement?.id
                    ? replacementTextPlan
                    : nil
            )
        }
        return affected
    }

    static func prependRows(
        for insertedMessages: [Message],
        into existingRows: inout [MessageRowPresentation],
        preparedInsertedRows: [MessageRowPresentation]? = nil,
        existingMessageIndex: ((MessageID) -> Int?)? = nil,
        replyingMessageIDsByTarget:
            [MessageID: Set<MessageID>]? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        guard !insertedMessages.isEmpty else { return }
        let insertedRows =
            if let preparedInsertedRows,
               preparedInsertedRows.count == insertedMessages.count,
               zip(preparedInsertedRows, insertedMessages).allSatisfy({ pair in
                   pair.0.message.id == pair.1.id
               })
            {
                preparedInsertedRows
            } else {
                rows(for: insertedMessages, calendar: calendar)
            }
        guard !existingRows.isEmpty else {
            existingRows = insertedRows
            return
        }

        let insertedByID = Dictionary(
            uniqueKeysWithValues: insertedMessages.map { ($0.id, $0) }
        )
        let insertedLast = insertedMessages[insertedMessages.count - 1]

        var affectedExistingIndexes = IndexSet(integer: 0)
        if let existingMessageIndex,
           let replyingMessageIDsByTarget
        {
            for insertedMessage in insertedMessages {
                for replyingMessageID in
                    replyingMessageIDsByTarget[insertedMessage.id] ?? []
                {
                    if let index = existingMessageIndex(replyingMessageID) {
                        affectedExistingIndexes.insert(index)
                    }
                }
            }
        } else {
            for (index, row) in existingRows.enumerated()
            where row.message.replyTo.map({
                insertedByID[$0] != nil
            }) == true {
                affectedExistingIndexes.insert(index)
            }
        }

        var replacements: [(index: Int, row: MessageRowPresentation)] = []
        replacements.reserveCapacity(affectedExistingIndexes.count)
        for index in affectedExistingIndexes
        where existingRows.indices.contains(index) {
            let row = existingRows[index]
            let message = row.message
            let referenced = message.replyTo.flatMap { insertedByID[$0] }
            let replyPreview =
                referenced.map {
                    MessageReplyPreview(message: $0)
                } ?? row.replyPreview
            let startsGroup =
                index == 0
                ? !continuesGroup(
                    from: insertedLast,
                    to: message,
                    calendar: calendar
                )
                : row.startsGroup
            let startsDay =
                index == 0
                ? !calendar.isDate(
                    insertedLast.timestamp,
                    inSameDayAs: message.timestamp
                )
                : row.startsDay
            replacements.append(
                (
                    index,
                    MessageRowPresentation(
                        message: message,
                        startsGroup: startsGroup,
                        startsDay: startsDay,
                        replyPreview: replyPreview,
                        isReplyAvailable:
                            referenced != nil || row.isReplyAvailable,
                        textPlan: row.textPlan
                    )
                )
            )
        }
        // Mutate the existing buffer so its geometric spare capacity is
        // reused across pagination. Rebuilding an exact-sized row array for
        // every 50-message page left one progressively larger 4–9 MB malloc
        // region behind per page, producing both the periodic hitch and a
        // hundreds-of-megabytes allocator high-water mark after long runs.
        existingRows.insert(contentsOf: insertedRows, at: 0)
        for replacement in replacements {
            existingRows[insertedMessages.count + replacement.index] =
                replacement.row
        }
    }

    static func appendRows(
        for insertedMessages: [Message],
        into existingRows: inout [MessageRowPresentation],
        after previousMessage: Message?,
        preparedInsertedRows: [MessageRowPresentation]? = nil,
        existingMessage: ((MessageID) -> Message?)? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        guard !insertedMessages.isEmpty else { return }
        var insertedRows =
            if let preparedInsertedRows,
               preparedInsertedRows.count == insertedMessages.count,
               zip(preparedInsertedRows, insertedMessages).allSatisfy({ pair in
                   pair.0.message.id == pair.1.id
               })
            {
                preparedInsertedRows
            } else {
                rows(for: insertedMessages, calendar: calendar)
            }

        for index in insertedMessages.indices {
            let message = insertedMessages[index]
            let prepared = insertedRows[index]
            let predecessor =
                index == insertedMessages.startIndex
                    ? previousMessage
                    : insertedMessages[index - 1]
            let referenced = message.replyTo.flatMap { existingMessage?($0) }
            insertedRows[index] = appendingRow(
                for: message,
                after: predecessor,
                replyPreview:
                    referenced.map(MessageReplyPreview.init(message:))
                        ?? prepared.replyPreview,
                isReplyAvailable:
                    referenced != nil || prepared.isReplyAvailable,
                textPlan: prepared.textPlan,
                calendar: calendar
            )
        }
        existingRows.append(contentsOf: insertedRows)
    }

    private static func continuesGroup(
        from previous: Message, to message: Message, calendar: Calendar
    ) -> Bool {
        isGroupable(previous)
            && isGroupable(message)
            && previous.author.id == message.author.id
            && message.replyTo == nil
            && message.timestamp.timeIntervalSince(previous.timestamp) >= 0
            && message.timestamp.timeIntervalSince(previous.timestamp) < continuationInterval
            && calendar.isDate(previous.timestamp, inSameDayAs: message.timestamp)
    }

    static func updating(
        existing: [MessageRowPresentation], oldMessages: [Message], newMessages: [Message],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [MessageRowPresentation] {
        guard existing.count == oldMessages.count, !oldMessages.isEmpty else {
            return rows(for: newMessages, calendar: calendar)
        }

        if newMessages.count >= oldMessages.count,
           newMessages.prefix(oldMessages.count).elementsEqual(oldMessages)
        {
            var result = existing
            let appended = newMessages[oldMessages.count...]
            let byID =
                appended.contains(where: { $0.replyTo != nil })
                    ? Dictionary(uniqueKeysWithValues: newMessages.map { ($0.id, $0) })
                    : [:]
            for index in oldMessages.count ..< newMessages.count {
                result.append(
                    presentation(at: index, in: newMessages, messagesByID: byID, calendar: calendar)
                )
            }
            return result
        }

        if newMessages.count > oldMessages.count {
            let insertedCount = newMessages.count - oldMessages.count
            if newMessages.suffix(oldMessages.count).elementsEqual(oldMessages) {
                let insertedMessages = newMessages.prefix(insertedCount)
                let insertedByID = Dictionary(
                    uniqueKeysWithValues: insertedMessages.map { ($0.id, $0) }
                )
                var result =
                    rows(for: Array(insertedMessages), calendar: calendar) + existing
                let insertedIDs = Set(insertedMessages.map(\.id))
                var affected = Set<Int>()
                for (index, message) in newMessages.enumerated()
                    where message.replyTo.map(insertedIDs.contains) == true {
                    affected.insert(index)
                }
                for index in affected where newMessages.indices.contains(index) {
                    result[index] = presentation(
                        at: index,
                        in: newMessages,
                        messagesByID: insertedByID,
                        calendar: calendar
                    )
                }
                if newMessages.indices.contains(insertedCount),
                   !affected.contains(insertedCount)
                {
                    let prior = existing[0]
                    let message = newMessages[insertedCount]
                    result[insertedCount] = MessageRowPresentation(
                        message: message,
                        startsGroup: !continuesGroup(
                            from: newMessages[insertedCount - 1],
                            to: message,
                            calendar: calendar
                        ),
                        startsDay: !calendar.isDate(
                            newMessages[insertedCount - 1].timestamp,
                            inSameDayAs: message.timestamp
                        ),
                        replyPreview: prior.replyPreview,
                        isReplyAvailable: prior.isReplyAvailable,
                        textPlan: prior.textPlan
                    )
                }
                return result
            }
        }

        if newMessages.count == oldMessages.count,
           zip(newMessages, oldMessages).allSatisfy({ $0.0.id == $0.1.id })
        {
            var result = existing
            var changed: [Int] = []
            changed.reserveCapacity(1)
            for index in newMessages.indices where newMessages[index] != oldMessages[index] {
                changed.append(index)
            }
            guard !changed.isEmpty else { return result }
            let byID = Dictionary(uniqueKeysWithValues: newMessages.map { ($0.id, $0) })
            let changedIDs = Set(changed.lazy.map { newMessages[$0].id })
            var affected = Set(changed)
            for index in changed where newMessages.indices.contains(index + 1) {
                affected.insert(index + 1)
            }
            for (index, message) in newMessages.enumerated()
                where message.replyTo.map(changedIDs.contains) == true {
                affected.insert(index)
            }
            for index in affected {
                result[index] = presentation(
                    at: index, in: newMessages, messagesByID: byID, calendar: calendar
                )
            }
            return result
        }
        return rows(for: newMessages, calendar: calendar)
    }

    private static func presentation(
        at index: Int, in messages: [Message], messagesByID: [MessageID: Message],
        calendar: Calendar
    ) -> MessageRowPresentation {
        let message = messages[index]
        let replyPreview = message.replyTo.flatMap { id in
            messagesByID[id].map {
                MessageReplyPreview(message: $0)
            } ?? message.replyPreview
        }
        guard index > 0 else {
            return MessageRowPresentation(
                message: message,
                startsGroup: true,
                startsDay: true,
                replyPreview: replyPreview,
                isReplyAvailable: replyPreview.map { messagesByID[$0.messageID] != nil } ?? false
            )
        }
        let continues = continuesGroup(
            from: messages[index - 1], to: message, calendar: calendar
        )
        return MessageRowPresentation(
            message: message,
            startsGroup: !continues,
            startsDay: !calendar.isDate(
                messages[index - 1].timestamp,
                inSameDayAs: message.timestamp
            ),
            replyPreview: replyPreview,
            isReplyAvailable: replyPreview.map { messagesByID[$0.messageID] != nil } ?? false
        )
    }
}
