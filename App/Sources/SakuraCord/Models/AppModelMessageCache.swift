import MessageRendering
import SakuraCordModels

extension AppModel {
    func restoreSelectedMessages(
        _ restoredMessages: [Message],
        preparedRows: [MessageRowPresentation]?
    ) {
        let oldMessages = messages
        messages = restoredMessages
        rebuildSelectedMessageIndexes()
        if let preparedRows,
           Self.rows(preparedRows, match: restoredMessages)
        {
            messageRows = preparedRows
        } else {
            messageRows = MessageGrouping.updating(
                existing: messageRows,
                oldMessages: oldMessages,
                newMessages: restoredMessages
            )
        }
        publishMessageRowsUpdate(invalidatesAllRows: true)
        messageRowsNonAppendRevision &+= 1
    }

    func reconcileCachedMessageUpdate(_ message: Message) {
        guard var cached = messageCache[message.channelID],
              let index = cached.firstIndex(where: { $0.id == message.id })
        else { return }
        var resolved = message
        resolved.replyTo = resolved.replyTo ?? cached[index].replyTo
        resolved.replyPreview =
            resolved.replyPreview ?? cached[index].replyPreview
        guard resolved != cached[index] else { return }
        cached[index] = resolved
        messageCache[message.channelID] = cached
    }
}
