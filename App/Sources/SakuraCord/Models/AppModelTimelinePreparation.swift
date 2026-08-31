import Foundation
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
                newMessages: restoredMessages,
                continuationInterval: interfaceSettings.groupingInterval
            )
        }
        publishMessageRowsUpdate(invalidatesAllRows: true)
        messageRowsNonAppendRevision &+= 1
    }

    func prepareTimelineRows(
        for messages: [Message],
        priority: TaskPriority
    ) async -> [MessageRowPresentation] {
        let groupingInterval = interfaceSettings.groupingInterval
        let rows = await AppPerformanceSignposts.measure(
            "TimelineRowGrouping"
        ) {
            await Task.detached(priority: priority) {
                await MessageGrouping.rowsCooperatively(
                    for: messages,
                    continuationInterval: groupingInterval
                )
            }.value
        }
        let preparations = rows.compactMap { row in
            NativeTimelineTextPresentation.preparation(
                message: row.message,
                plan: row.textPlan,
                model: self,
                baseFontSize: row.message.type.hasGeneratedContent
                    ? row.textPlan.baseFontSize
                    : InterfaceTypographyMetrics.messageTextSize,
                underlinesLinks: !row.message.type.hasGeneratedContent
                    && interfaceSettings.underlinesLinks
            )
        }
        guard !preparations.isEmpty else { return rows }
        await AppPerformanceSignposts.measure(
            "TimelineResolvedTextPrewarming"
        ) {
            await Task.detached(priority: priority) {
                for (index, preparation) in preparations.enumerated() {
                    guard !Task.isCancelled else { return }
                    _ = autoreleasepool {
                        NativeTimelineTextPresentation.prewarm(preparation)
                    }
                    if (index + 1).isMultiple(of: 4),
                       index + 1 < preparations.endIndex
                    {
                        await Task.yield()
                    }
                }
            }.value
        }
        return rows
    }
}
