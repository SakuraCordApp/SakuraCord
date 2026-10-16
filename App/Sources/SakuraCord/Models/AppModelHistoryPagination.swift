import DiscordProtocol
import Foundation
import SakuraCordModels

private enum SelectedMessageHistoryDirection: String, Sendable {
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
                // Filling the timeline's 8 000 pt prefetch window is a fixed
                // amount of history, so chunk size only changes how many
                // serialized reads it takes. Each page also awaits its own
                // Gateway member resolution (`hydrateHistoryMembers`), which
                // made a 20-message page cost two round trips. 100 is Discord's
                // ceiling and the ceiling `requestMembersByID` batches into, so
                // the same window now resolves members in one round trip.
                limit: historyPageLimit
            )
            guard !Task.isCancelled,
                  isCurrentAccountSession(session),
                  selectedChannelID == request.channelID
            else { return }
            // A cached-tail refresh can replace the window while this page is
            // in flight (gap case: the fetched page starts strictly newer
            // than the restored window ends). Committing the stale page
            // against the replaced window would splice a non-adjacent run
            // and adopt a boundary that strands everything between them. The
            // preserved boundary lets normal scrolling re-anchor below the
            // replacement and fill downward instead. Later pages need no
            // check: the refresh clears their flag, and live appends merge
            // by identifier.
            if case .before(let anchorID) = request.anchor,
               messages.first?.id != anchorID
            {
                return
            }
            let reconcileStart = ProcessInfo.processInfo.systemUptime
            let inserted = AppPerformanceSignposts.measureSync(
                "HistoryPageReconciliation"
            ) {
                page.messages.filter {
                    !selectedMessageIDs.contains($0.id)
                }
            }
            let filterEnd = ProcessInfo.processInfo.systemUptime
            // The oldest row this page was requested against. Later pages
            // carry none: their flag is cleared by a tail refresh, and live
            // appends merge by identifier.
            let anchorID: MessageID?
            switch (direction, request.anchor) {
            case (.earlier, .before(let id)): anchorID = id
            case (.earlier, _), (.later, _): anchorID = nil
            }
            let committed = await AppPerformanceSignposts.measure(
                "HistoryPageCommit"
            ) {
                await commitSelectedMessageHistory(
                    inserted,
                    direction: direction,
                    channelID: request.channelID,
                    anchorID: anchorID
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

    private func selectedMessageHistoryRequest(
        _ direction: SelectedMessageHistoryDirection
    ) -> SelectedMessageHistoryRequest? {
        guard let channelID = selectedChannelID else { return nil }
        switch direction {
        case .earlier:
            guard let first = messages.first,
                  hasMoreMessages,
                  !isLoadingEarlier
            else { return nil }
            return SelectedMessageHistoryRequest(
                channelID: channelID,
                anchor: .before(first.id)
            )
        case .later:
            guard let last = messages.last,
                  hasMoreLaterMessages,
                  !isLoadingLater
            else { return nil }
            return SelectedMessageHistoryRequest(
                channelID: channelID,
                anchor: .after(last.id)
            )
        }
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
        channelID: ChannelID,
        anchorID: MessageID?
    ) async -> Bool {
        guard !inserted.isEmpty else { return true }
        switch direction {
        case .earlier:
            return await prependSelectedMessages(
                inserted,
                channelID: channelID,
                anchorID: anchorID
            )
        case .later:
            return await appendSelectedHistoryMessages(
                inserted,
                channelID: channelID
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
