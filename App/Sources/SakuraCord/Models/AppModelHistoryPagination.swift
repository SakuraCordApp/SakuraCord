import DiscordProtocol
import Foundation
import SakuraCordModels

enum SelectedMessageHistoryDirection: String, Sendable {
    case earlier
    case later
}

private struct SelectedMessageHistoryRequest {
    let channelID: ChannelID
    let anchor: MessageHistoryAnchor
}

extension AppModel {
    func loadEarlier(account: AppModelAccountSession? = nil) async {
        await loadSelectedMessageHistory(.earlier, account: account)
    }

    func loadLater(account: AppModelAccountSession? = nil) async {
        await loadSelectedMessageHistory(.later, account: account)
    }

    private func loadSelectedMessageHistory(
        _ direction: SelectedMessageHistoryDirection,
        account: AppModelAccountSession? = nil
    ) async {
        let session = account ?? accountSession()
        guard !Task.isCancelled, isCurrentAccountSession(session) else { return }
        guard let request = selectedMessageHistoryRequest(direction) else { return }
        let paginationName: StaticString = switch direction {
        case .earlier: "EarlierHistoryPagination"
        case .later: "LaterHistoryPagination"
        }
        let pagination = AppPerformanceSignposts.signposter.beginInterval(
            paginationName,
            id: AppPerformanceSignposts.signposter.makeSignpostID()
        )
        defer {
            AppPerformanceSignposts.signposter.endInterval(
                paginationName, pagination
            )
        }
        clearSelectedMessageHistoryError()
        setSelectedMessageHistoryLoading(true, direction: direction)
        defer {
            if isCurrentAccountSession(session),
               selectedChannelID == request.channelID
            {
                setSelectedMessageHistoryLoading(false, direction: direction)
            }
        }
        do {
            let page = try await session.provider.messages(
                in: request.channelID,
                anchoredAt: request.anchor,
                limit: historyPageFetchLimit
            )
            // A window replaced meanwhile, such as by a jump, no longer
            // continues from the edge this page was read from.
            guard !Task.isCancelled,
                  isCurrentAccountSession(session),
                  selectedChannelID == request.channelID,
                  selectedMessageHistoryEdge(direction) == request.anchor
            else { return }
            let reconcileStart = ProcessInfo.processInfo.systemUptime
            let inserted = AppPerformanceSignposts.measureSync(
                "HistoryPageReconciliation"
            ) {
                page.messages.filter {
                    !selectedMessageIDs.contains($0.id)
                }
            }
            let filterEnd = ProcessInfo.processInfo.systemUptime
            let committed = await AppPerformanceSignposts.measure(
                "HistoryPageCommit"
            ) {
                await commitSelectedMessageHistory(
                    inserted,
                    direction: direction,
                    request: request
                )
            }
            guard committed else { return }
            let commitEnd = ProcessInfo.processInfo.systemUptime
            AppPerformanceSignposts.measureSync("HistoryBoundaryStateUpdate") {
                applySelectedMessageHistoryBoundary(
                    page,
                    direction: direction,
                    channelID: request.channelID
                )
            }
            clearSelectedMessageHistoryError()
            logSelectedMessageHistoryPerformance(
                direction: direction,
                reconcileStart: reconcileStart,
                filterEnd: filterEnd,
                commitEnd: commitEnd
            )
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentAccountSession(session),
                  selectedChannelID == request.channelID
            else { return }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            messageLoadError = error.localizedDescription
            messageLoadErrorIsEarlierPage = direction == .earlier
            messageLoadErrorIsLaterPage = direction == .later
        }
    }

    func selectedMessageHistoryEdge(
        _ direction: SelectedMessageHistoryDirection
    ) -> MessageHistoryAnchor? {
        // Unconfirmed sends sort last and carry local IDs, so the REST edges
        // are the outermost confirmed messages.
        switch direction {
        case .earlier: messages.first { $0.outboxState == .confirmed }.map { .before($0.id) }
        case .later: messages.last { $0.outboxState == .confirmed }.map { .after($0.id) }
        }
    }

    /// The window still ends at the edge a page was requested from.
    func windowContinues(from edge: MessageHistoryAnchor?, _ direction: SelectedMessageHistoryDirection) -> Bool {
        edge.map { selectedMessageHistoryEdge(direction) == $0 } ?? true
    }

    private func selectedMessageHistoryRequest(
        _ direction: SelectedMessageHistoryDirection
    ) -> SelectedMessageHistoryRequest? {
        guard let channelID = selectedChannelID,
              let anchor = selectedMessageHistoryEdge(direction)
        else { return nil }
        // Like the official scroller, one page is in flight at a time, even
        // when a short detached window is near both edges.
        guard !isLoadingEarlier, !isLoadingLater else { return nil }
        switch direction {
        case .earlier:
            guard hasMoreMessages else { return nil }
        case .later:
            guard hasMoreLaterMessages else { return nil }
        }
        return SelectedMessageHistoryRequest(channelID: channelID, anchor: anchor)
    }

    private func setSelectedMessageHistoryLoading(
        _ isLoading: Bool,
        direction: SelectedMessageHistoryDirection
    ) {
        switch direction {
        case .earlier: isLoadingEarlier = isLoading
        case .later: isLoadingLater = isLoading
        }
    }

    private func clearSelectedMessageHistoryError() {
        messageLoadError = nil
        messageLoadErrorIsEarlierPage = false
        messageLoadErrorIsLaterPage = false
    }

    private func commitSelectedMessageHistory(
        _ inserted: [Message],
        direction: SelectedMessageHistoryDirection,
        request: SelectedMessageHistoryRequest
    ) async -> Bool {
        guard !inserted.isEmpty else { return true }
        switch direction {
        case .earlier:
            return await prependSelectedMessages(
                inserted,
                channelID: request.channelID,
                continuing: request.anchor
            )
        case .later:
            return await appendSelectedHistoryMessages(
                inserted,
                channelID: request.channelID,
                continuing: request.anchor
            )
        }
    }

    private func applySelectedMessageHistoryBoundary(
        _ page: MessagePage,
        direction: SelectedMessageHistoryDirection,
        channelID: ChannelID
    ) {
        switch direction {
        case .earlier:
            hasMoreMessages = page.hasMoreBefore
            hasMoreCache[channelID] = page.hasMoreBefore
        case .later:
            hasMoreLaterMessages = page.hasMoreAfter
        }
    }

    private func logSelectedMessageHistoryPerformance(
        direction: SelectedMessageHistoryDirection,
        reconcileStart: TimeInterval,
        filterEnd: TimeInterval,
        commitEnd: TimeInterval
    ) {
        guard runsChatPerformanceBenchmark else { return }
        let stateEnd = ProcessInfo.processInfo.systemUptime
        let milliseconds = (stateEnd - reconcileStart) * 1_000
        guard milliseconds >= 4 else { return }
        NSLog(
            "SakuraCord %@ history phases: filter %.2f ms; commit %.2f ms; state %.2f ms (%d rows)",
            direction.rawValue,
            (filterEnd - reconcileStart) * 1_000,
            (commitEnd - filterEnd) * 1_000,
            (stateEnd - commitEnd) * 1_000,
            messages.count
        )
    }
}
