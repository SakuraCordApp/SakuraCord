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
                limit: 20
            )
            guard !Task.isCancelled,
                  isCurrentAccountSession(session),
                  selectedChannelID == request.channelID
            else { return }
            let reconcileStart = ProcessInfo.processInfo.systemUptime
            let inserted = page.messages.filter {
                !selectedMessageIDs.contains($0.id)
            }
            let filterEnd = ProcessInfo.processInfo.systemUptime
            guard await commitSelectedMessageHistory(
                inserted,
                direction: direction,
                channelID: request.channelID
            ) else { return }
            let commitEnd = ProcessInfo.processInfo.systemUptime
            applySelectedMessageHistoryBoundary(
                page,
                direction: direction,
                channelID: request.channelID
            )
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
        channelID: ChannelID
    ) async -> Bool {
        guard !inserted.isEmpty else { return true }
        switch direction {
        case .earlier:
            return await prependSelectedMessages(
                inserted,
                channelID: channelID
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
