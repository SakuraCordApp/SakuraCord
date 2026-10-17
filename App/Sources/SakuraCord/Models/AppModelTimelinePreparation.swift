import Foundation
import SakuraCordModels

extension AppModel {
    func messagePresentationChannel(_ channelID: ChannelID) -> Channel? {
        if let channels = snapshot?.channels {
            // Keep positions, never channel values. Revalidate the identity
            // after every reorder or replacement and read the current value,
            // including renamed channels and channels from a new account.
            if let index = messagePresentationChannelPositions[channelID],
               channels.indices.contains(index), channels[index].id == channelID {
                return channels[index]
            }
            if let index = channels.firstIndex(where: { $0.id == channelID }) {
                if messagePresentationChannelPositions.count >= 512 {
                    messagePresentationChannelPositions.removeAll(keepingCapacity: true)
                }
                messagePresentationChannelPositions[channelID] = index
                return channels[index]
            }
        }
        return visibleChannels.first { $0.id == channelID }
    }

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

    // Per-call worker checkpoints support deterministic cancellation verification
    // without global hooks; normal loads retain their existing batching.
    func prepareTimelineRows(
        for messages: [Message],
        priority: TaskPriority,
        groupingCheckpoint: (@Sendable (Int) async -> Void)? = nil,
        prewarmingCheckpoint: (@Sendable (Int) async -> Void)? = nil
    ) async -> [MessageRowPresentation] {
        guard !Task.isCancelled else { return [] }
        let sessionGeneration = accountSessionGeneration
        let rows = await AppPerformanceSignposts.measure(
            "TimelineRowGrouping"
        ) {
            let worker = Task.detached(priority: priority) {
                await MessageGrouping.rowsCooperatively(for: messages, checkpoint: groupingCheckpoint)
            }
            return await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
        }
        var preparations: [NativeTimelineTextPresentation.Preparation] = []
        var replyPreparations: [String] = []
        var sliceStart = ProcessInfo.processInfo.systemUptime
        for row in rows {
            guard !Task.isCancelled, accountSessionGeneration == sessionGeneration else { return [] }
            if let preparation = NativeTimelineTextPresentation.preparation(
                message: row.message,
                plan: row.textPlan,
                model: self,
                baseFontSize: row.message.type.hasGeneratedContent
                    ? row.textPlan.baseFontSize
                    : InterfaceScale.fontSize(InterfaceTypographyMetrics.messageTextSize)
            ) {
                preparations.append(preparation)
            }
            if let preview = row.replyPreview,
               let preparation = MessageReplySummary.preparation(
                   content: preview.content,
                   mentionLabel: MessageMentionResolver(model: self, message: row.message).label
               ) {
                replyPreparations.append(preparation)
            }
            if ProcessInfo.processInfo.systemUptime - sliceStart >= 0.0015 {
                // Yield the run loop as well as the actor, so input and drawing
                // can run while resolving a cold page's mentions and replies.
                do {
                    try await Task.sleep(for: .milliseconds(1))
                } catch {
                    return []
                }
                sliceStart = ProcessInfo.processInfo.systemUptime
            }
        }
        guard !Task.isCancelled, accountSessionGeneration == sessionGeneration else { return [] }
        // The native timeline initially measures every row to establish scroll
        // geometry. Keep its text warm rather than shifting cold CoreText work
        // into that synchronous first layout.
        guard !preparations.isEmpty || !replyPreparations.isEmpty else { return rows }
        let preparedReplies = await AppPerformanceSignposts.measure(
            "TimelineResolvedTextPrewarming"
        ) {
            let worker = Task.detached(priority: priority) { [preparations, replyPreparations] in
                await Self.prewarmTimelineText(
                    preparations, replies: replyPreparations, checkpoint: prewarmingCheckpoint
                )
            }
            return await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
        }
        guard !Task.isCancelled, accountSessionGeneration == sessionGeneration else { return [] }
        for prepared in preparedReplies {
            MessageReplySummary.install(prepared)
        }
        return rows
    }

    private nonisolated static func prewarmTimelineText(
        _ preparations: [NativeTimelineTextPresentation.Preparation],
        replies: [String],
        checkpoint: (@Sendable (Int) async -> Void)?
    ) async -> [MessageReplySummary.Prepared] {
        for (index, preparation) in preparations.enumerated() {
            guard !Task.isCancelled else { return [] }
            _ = autoreleasepool {
                NativeTimelineTextPresentation.prewarm(preparation)
            }
            if let checkpoint { await checkpoint(index + 1) }
            if (index + 1).isMultiple(of: 4),
               index + 1 < preparations.endIndex
            {
                await Task.yield()
            }
        }
        var preparedReplies: [MessageReplySummary.Prepared] = []
        for (index, source) in replies.enumerated() {
            guard !Task.isCancelled else { return [] }
            preparedReplies.append(MessageReplySummary.prepare(source))
            if let checkpoint { await checkpoint(preparations.count + index + 1) }
            if (index + 1).isMultiple(of: 4) {
                await Task.yield()
            }
        }
        return preparedReplies
    }

}
