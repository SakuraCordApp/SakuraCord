import Foundation
import SakuraCordModels

extension AppModel {
    func prepareTimelineRows(
        for messages: [Message],
        priority: TaskPriority
    ) async -> [MessageRowPresentation] {
        let rows = await AppPerformanceSignposts.measure(
            "TimelineRowGrouping"
        ) {
            await Task.detached(priority: priority) {
                await MessageGrouping.rowsCooperatively(for: messages)
            }.value
        }
        let preparations = rows.compactMap { row in
            NativeTimelineTextPresentation.preparation(
                message: row.message,
                plan: row.textPlan,
                model: self
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
