import Darwin
import Foundation
import OSLog
import SakuraCordModels

enum AppPerformanceSignposts {
    nonisolated static let signposter = OSSignposter(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "PointsOfInterest"
    )

    private static var startupInterval: OSSignpostIntervalState?
    private static var startupPresentationReadiness =
        StartupPresentationReadiness()
    private static var conversationNavigationInterval:
        (channelID: ChannelID, state: OSSignpostIntervalState)?
    private static var navigationHistoryReadyChannelID: ChannelID?
    private static var conversationFirstFrameWaiters:
        [ChannelID: [CheckedContinuation<Void, Never>]] = [:]
    private static var guildActivationDepth = 0
    private static var quickSwitcherOpenInterval: OSSignpostIntervalState?
    private static var quickSwitcherQueryInterval: OSSignpostIntervalState?
    private static var quickSwitcherCloseInterval: OSSignpostIntervalState?
    private static var messageSearchOpenInterval: OSSignpostIntervalState?
    private static var messageSearchRequestInterval: OSSignpostIntervalState?
    private static var messageSearchPaginationInterval: OSSignpostIntervalState?
    private static var messageSearchScrollInterval: OSSignpostIntervalState?
    private static var pinnedMessagesOpenInterval: OSSignpostIntervalState?
    private static var pinnedMessagesCloseInterval: OSSignpostIntervalState?
    private static var pinnedMessagesRequestInterval: OSSignpostIntervalState?
    private static var pinnedMessagesPaginationInterval: OSSignpostIntervalState?
    private static var pinnedMessagesScrollInterval: OSSignpostIntervalState?
    private static var resourceWindowStartNanoseconds: UInt64?

    static func beginStartup() {
        guard startupInterval == nil else { return }
        startupInterval = signposter.beginInterval("StartupToWorkspace")
        signposter.emitEvent("AppInitializationStarted")
    }

    static func reportRootViewAppeared() {
        signposter.emitEvent("RootViewAppeared")
    }

    static func expectStartupConversation(_ channelID: ChannelID?) {
        startupPresentationReadiness.expectedConversationID = channelID
    }

    static func reportStartupConversationHistoryReady(
        channelID: ChannelID
    ) {
        guard startupInterval != nil else { return }
        signposter.emitEvent("StartupConversationHistoryReady")
        startupPresentationReadiness.reportHistoryReady(channelID: channelID)
    }

    static func reportNonTimelineWorkspaceFrame() {
        finishStartupPresentation()
    }

    private static func finishStartupPresentation() {
        guard let startupInterval else { return }
        signposter.emitEvent("WorkspacePresented")
        signposter.endInterval("StartupToWorkspace", startupInterval)
        self.startupInterval = nil
    }

    static func beginConversationNavigation(to channelID: ChannelID) {
        if let current = conversationNavigationInterval {
            signposter.endInterval(
                "ConversationNavigationToFirstFrame",
                current.state
            )
            signposter.emitEvent("ConversationNavigationSuperseded")
            resumeConversationFirstFrameWaiters(for: current.channelID)
        }
        conversationNavigationInterval = (
            channelID,
            signposter.beginInterval(
                "ConversationNavigationToFirstFrame"
            )
        )
        navigationHistoryReadyChannelID = nil
    }

    static func ensureConversationNavigation(to channelID: ChannelID) {
        guard conversationNavigationInterval?.channelID != channelID else {
            return
        }
        beginConversationNavigation(to: channelID)
    }

    @discardableResult
    static func reportConversationFirstFrame(
        channelID: ChannelID
    ) -> Bool {
        var completedPresentation = false
        if startupInterval != nil,
           startupPresentationReadiness.reportFramePresented(
            channelID: channelID
           )
        {
            signposter.emitEvent("StartupConversationFramePresented")
            finishStartupPresentation()
            completedPresentation = true
        }
        guard let current = conversationNavigationInterval,
              current.channelID == channelID,
              navigationHistoryReadyChannelID == channelID
        else { return completedPresentation }
        signposter.emitEvent("ConversationFirstFrameDrawn")
        signposter.endInterval(
            "ConversationNavigationToFirstFrame",
            current.state
        )
        conversationNavigationInterval = nil
        navigationHistoryReadyChannelID = nil
        resumeConversationFirstFrameWaiters(for: channelID)
        return true
    }

    static func reportConversationHistoryReady(channelID: ChannelID) {
        guard conversationNavigationInterval?.channelID == channelID else { return }
        navigationHistoryReadyChannelID = channelID
        signposter.emitEvent("ConversationHistoryReady")
    }

    static func cancelConversationNavigation() {
        guard let current = conversationNavigationInterval else { return }
        signposter.endInterval(
            "ConversationNavigationToFirstFrame",
            current.state
        )
        conversationNavigationInterval = nil
        navigationHistoryReadyChannelID = nil
        resumeConversationFirstFrameWaiters(for: current.channelID)
    }

    static func waitForConversationFirstFrame(channelID: ChannelID) async {
        guard conversationNavigationInterval?.channelID == channelID else { return }
        await withCheckedContinuation { continuation in
            conversationFirstFrameWaiters[channelID, default: []].append(continuation)
        }
    }

    static var isConversationPresentationWorkActive: Bool {
        conversationNavigationInterval != nil || guildActivationDepth > 0
    }

    static func beginGuildActivationWork() {
        guildActivationDepth += 1
    }

    static func endGuildActivationWork() {
        guildActivationDepth = max(0, guildActivationDepth - 1)
    }

    private static func resumeConversationFirstFrameWaiters(for channelID: ChannelID) {
        let waiters = conversationFirstFrameWaiters.removeValue(forKey: channelID) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    static func beginQuickSwitcherOpen() {
        if let current = quickSwitcherOpenInterval {
            signposter.endInterval("QuickSwitcherOpenToFirstFrame", current)
        }
        quickSwitcherOpenInterval = signposter.beginInterval(
            "QuickSwitcherOpenToFirstFrame"
        )
    }

    static func beginQuickSwitcherQuery() {
        if let current = quickSwitcherQueryInterval {
            signposter.endInterval("QuickSwitcherQueryToFirstFrame", current)
        }
        quickSwitcherQueryInterval = signposter.beginInterval(
            "QuickSwitcherQueryToFirstFrame"
        )
    }

    static func reportQuickSwitcherFirstFrame() {
        if let current = quickSwitcherOpenInterval {
            signposter.endInterval("QuickSwitcherOpenToFirstFrame", current)
            quickSwitcherOpenInterval = nil
        }
        if let current = quickSwitcherQueryInterval {
            signposter.endInterval("QuickSwitcherQueryToFirstFrame", current)
            quickSwitcherQueryInterval = nil
        }
    }

    static func beginQuickSwitcherClose() {
        if let current = quickSwitcherCloseInterval {
            signposter.endInterval("QuickSwitcherClose", current)
        }
        quickSwitcherCloseInterval = signposter.beginInterval("QuickSwitcherClose")
    }

    static func reportQuickSwitcherClosed() {
        guard let current = quickSwitcherCloseInterval else { return }
        signposter.endInterval("QuickSwitcherClose", current)
        quickSwitcherCloseInterval = nil
    }

    static func beginMessageSearchOpen() {
        if let current = messageSearchOpenInterval {
            signposter.endInterval("MessageSearchOpenToFirstFrame", current)
        }
        messageSearchOpenInterval = signposter.beginInterval(
            "MessageSearchOpenToFirstFrame"
        )
    }

    static func beginPinnedMessagesOpen() {
        if let current = pinnedMessagesOpenInterval {
            signposter.endInterval("PinnedMessagesOpenToFirstFrame", current)
        }
        pinnedMessagesOpenInterval = signposter.beginInterval(
            "PinnedMessagesOpenToFirstFrame"
        )
    }

    static func reportPinnedMessagesPanelReady() {
        guard let current = pinnedMessagesOpenInterval else { return }
        signposter.endInterval("PinnedMessagesOpenToFirstFrame", current)
        pinnedMessagesOpenInterval = nil
    }

    static func beginPinnedMessagesClose() {
        if let current = pinnedMessagesCloseInterval {
            signposter.endInterval("PinnedMessagesClose", current)
        }
        pinnedMessagesCloseInterval = signposter.beginInterval("PinnedMessagesClose")
    }

    static func reportPinnedMessagesClosed() {
        guard let current = pinnedMessagesCloseInterval else { return }
        signposter.endInterval("PinnedMessagesClose", current)
        pinnedMessagesCloseInterval = nil
    }

    static func beginPinnedMessagesRequest(isPagination: Bool) {
        if isPagination {
            if let current = pinnedMessagesPaginationInterval {
                signposter.endInterval("PinnedMessagesPaginationToResults", current)
            }
            pinnedMessagesPaginationInterval = signposter.beginInterval(
                "PinnedMessagesPaginationToResults"
            )
        } else {
            if let current = pinnedMessagesRequestInterval {
                signposter.endInterval("PinnedMessagesRequestToResults", current)
            }
            pinnedMessagesRequestInterval = signposter.beginInterval(
                "PinnedMessagesRequestToResults"
            )
        }
    }

    static func endPinnedMessagesRequest(isPagination: Bool) {
        if isPagination, let current = pinnedMessagesPaginationInterval {
            signposter.endInterval("PinnedMessagesPaginationToResults", current)
            pinnedMessagesPaginationInterval = nil
            return
        }
        guard !isPagination, let current = pinnedMessagesRequestInterval else { return }
        signposter.endInterval("PinnedMessagesRequestToResults", current)
        pinnedMessagesRequestInterval = nil
    }

    static func beginPinnedMessagesScroll() {
        guard pinnedMessagesScrollInterval == nil else { return }
        pinnedMessagesScrollInterval = signposter.beginInterval("PinnedMessagesUserScroll")
    }

    static func endPinnedMessagesScroll() {
        guard let current = pinnedMessagesScrollInterval else { return }
        signposter.endInterval("PinnedMessagesUserScroll", current)
        pinnedMessagesScrollInterval = nil
    }

    static func reportMessageSearchPanelReady() {
        guard let current = messageSearchOpenInterval else { return }
        signposter.endInterval("MessageSearchOpenToFirstFrame", current)
        messageSearchOpenInterval = nil
    }

    static func beginMessageSearchRequest() {
        if let current = messageSearchRequestInterval {
            signposter.endInterval("MessageSearchRequestToResults", current)
        }
        messageSearchRequestInterval = signposter.beginInterval(
            "MessageSearchRequestToResults"
        )
    }

    static func reportMessageSearchResultsReady() {
        guard let current = messageSearchRequestInterval else { return }
        signposter.endInterval("MessageSearchRequestToResults", current)
        messageSearchRequestInterval = nil
        signposter.emitEvent("MessageSearchResultsReady")
    }

    static func cancelMessageSearchRequest() {
        guard let current = messageSearchRequestInterval else { return }
        signposter.endInterval("MessageSearchRequestToResults", current)
        messageSearchRequestInterval = nil
    }

    static func beginMessageSearchPagination() {
        if let current = messageSearchPaginationInterval {
            signposter.endInterval("MessageSearchPaginationToResults", current)
        }
        messageSearchPaginationInterval = signposter.beginInterval(
            "MessageSearchPaginationToResults"
        )
    }

    static func reportMessageSearchPaginationReady() {
        guard let current = messageSearchPaginationInterval else { return }
        signposter.endInterval("MessageSearchPaginationToResults", current)
        messageSearchPaginationInterval = nil
        signposter.emitEvent("MessageSearchPaginationReady")
    }

    static func cancelMessageSearchPagination() {
        guard let current = messageSearchPaginationInterval else { return }
        signposter.endInterval("MessageSearchPaginationToResults", current)
        messageSearchPaginationInterval = nil
    }

    static func beginMessageSearchScroll() {
        if let current = messageSearchScrollInterval {
            signposter.endInterval("MessageSearchUserScroll", current)
            endResourceWindow(named: "MessageSearchScrollBenchmark")
        }
        beginResourceWindow(named: "MessageSearchScrollBenchmark")
        messageSearchScrollInterval = signposter.beginInterval(
            "MessageSearchUserScroll"
        )
    }

    static func endMessageSearchScroll() {
        guard let current = messageSearchScrollInterval else { return }
        signposter.endInterval("MessageSearchUserScroll", current)
        messageSearchScrollInterval = nil
        endResourceWindow(named: "MessageSearchScrollBenchmark")
    }

    static func beginResourceWindow(named name: String) {
        guard configuredResourceWindowName == name else { return }
        resourceWindowStartNanoseconds = monotonicNanoseconds()
    }

    static func endResourceWindow(
        named name: String,
        nominalDuration: TimeInterval? = nil
    ) {
        guard configuredResourceWindowName == name,
              let startedAt = resourceWindowStartNanoseconds,
              let observedEnd = monotonicNanoseconds(),
              observedEnd >= startedAt
        else { return }
        resourceWindowStartNanoseconds = nil
        let endedAt: UInt64
        if let nominalDuration, nominalDuration > 0 {
            endedAt = startedAt &+ UInt64(
                nominalDuration * 1_000_000_000
            )
        } else {
            endedAt = observedEnd
        }
        guard let path = ProcessInfo.processInfo.environment[
            "SAKURACORD_PERFORMANCE_WINDOW_PATH"
        ] else { return }
        let contents = "\(startedAt)\t\(endedAt)\n"
        try? contents.write(
            to: URL(fileURLWithPath: path),
            atomically: true,
            encoding: .utf8
        )
    }

    private static var configuredResourceWindowName: String? {
        ProcessInfo.processInfo.environment[
            "SAKURACORD_PERFORMANCE_WINDOW_NAME"
        ]
    }

    private static func monotonicNanoseconds() -> UInt64? {
        var value = timespec()
        guard clock_gettime(CLOCK_MONOTONIC_RAW, &value) == 0,
              value.tv_sec >= 0,
              value.tv_nsec >= 0
        else { return nil }
        return UInt64(value.tv_sec) * 1_000_000_000
            + UInt64(value.tv_nsec)
    }

#if DEBUG
    static var navigationChannelIDForTesting: ChannelID? {
        conversationNavigationInterval?.channelID
    }
#endif

    static func measure<T>(
        _ name: StaticString,
        operation: () async throws -> T
    ) async rethrows -> T {
        let interval = signposter.beginInterval(
            name,
            id: signposter.makeSignpostID()
        )
        defer { signposter.endInterval(name, interval) }
        return try await operation()
    }

    nonisolated static func measureSync<T>(
        _ name: StaticString,
        operation: () throws -> T
    ) rethrows -> T {
        let interval = signposter.beginInterval(
            name,
            id: signposter.makeSignpostID()
        )
        defer { signposter.endInterval(name, interval) }
        return try operation()
    }
}

nonisolated struct StartupPresentationReadiness {
    var expectedConversationID: ChannelID?
    private(set) var historyReadyConversationIDs: Set<ChannelID> = []

    mutating func reportHistoryReady(channelID: ChannelID) {
        historyReadyConversationIDs.insert(channelID)
    }

    func reportFramePresented(channelID: ChannelID) -> Bool {
        expectedConversationID == channelID
            && historyReadyConversationIDs.contains(channelID)
    }
}
