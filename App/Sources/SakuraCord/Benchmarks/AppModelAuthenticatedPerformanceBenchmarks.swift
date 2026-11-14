import AppKit
import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    /// The real server the member-list and loading-overlap benchmarks open,
    /// which bootstrap therefore keeps cold.
    static let benchmarkGuildName = "Google Labs"
}

#if DEBUG
    private enum AuthenticatedNavigationBenchmarkKind {
        case directMessage
        case server
        case channel

        var intervalName: StaticString {
            switch self {
            case .directMessage: "AuthenticatedDirectMessageOpen"
            case .server: "AuthenticatedServerOpen"
            case .channel: "AuthenticatedChannelOpen"
            }
        }
    }

    extension AppModel {
        func prepareAuthenticatedMemberListScrollPerformanceBenchmark() async {
            guard runsChatPerformanceBenchmark,
                  sessionState == .workspace
            else { return }
            await channelLoadTask?.value
            guard !Task.isCancelled,
                  let snapshot,
                  let targetGuild = snapshot.guilds.first(where: {
                      $0.name.localizedCaseInsensitiveCompare(Self.benchmarkGuildName)
                          == .orderedSame
                  }),
                  let channel = benchmarkTargetChannel(in: targetGuild.id, of: snapshot)
            else {
                AppPerformanceSignposts.signposter.emitEvent(
                    "MemberListAutoScrollBenchmarkTargetUnavailable"
                )
                return
            }
            guard await runAuthenticatedNavigationBenchmarkOperation(
                channel: channel,
                kind: .server
            ) else { return }
            await memberLoadTask?.value
        }

        func prepareAuthenticatedTimelineScrollPerformanceBenchmark() async {
            guard runsChatPerformanceBenchmark,
                  sessionState == .workspace
            else { return }
            await channelLoadTask?.value
            // The timeline starts its run on the first channel with more
            // history and pages in the rest itself.
            if hasMoreMessages { return }
            guard let snapshot else { return }
            let originalChannelID = selectedChannelID
            let candidates = benchmarkEligibleChannels(snapshot.channels)
                .filter { $0.id != originalChannelID }
                .sorted {
                    ($0.lastMessageID?.rawValue ?? 0)
                        > ($1.lastMessageID?.rawValue ?? 0)
                }
            for channel in candidates.prefix(12) {
                guard !Task.isCancelled else { return }
                let kind: AuthenticatedNavigationBenchmarkKind =
                    channel.guildID != selectedGuildID ? .server : .channel
                guard await runAuthenticatedNavigationBenchmarkOperation(
                    channel: channel,
                    kind: kind
                ) else { continue }
                if hasMoreMessages { return }
            }
        }

        private func prepareSelectedTimelineScrollHistory() async -> Bool {
            let channelID = selectedChannelID
            var pageCount = 0
            while !Task.isCancelled,
                  selectedChannelID == channelID,
                  messages.count < 100,
                  hasMoreMessages,
                  pageCount < 5
            {
                let previousCount = messages.count
                await loadEarlier()
                await waitForHistoryIdle(
                    for: .zero,
                    polling: .milliseconds(10),
                    isLoading: { isLoadingEarlier },
                    while: { selectedChannelID == channelID }
                )
                pageCount += 1
                guard messages.count > previousCount else { break }
            }
            return messages.count >= 100
        }

        /// Waits up to 12 seconds until `isLoading` has stayed false for
        /// `idleDuration`, stopping early once `staysRelevant` is false.
        private func waitForHistoryIdle(
            for idleDuration: Duration,
            polling pollInterval: Duration,
            isLoading: () -> Bool,
            while staysRelevant: () -> Bool = { true }
        ) async {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(12))
            var idleSince: ContinuousClock.Instant?
            while !Task.isCancelled, staysRelevant(), clock.now < deadline {
                if isLoading() {
                    idleSince = nil
                } else {
                    let since = idleSince ?? clock.now
                    if since.duration(to: clock.now) >= idleDuration { return }
                    idleSince = since
                }
                try? await Task.sleep(for: pollInterval)
            }
        }

        private func waitForSelectedEarlierHistoryIdle() async {
            let channelID = selectedChannelID
            await waitForHistoryIdle(
                for: .milliseconds(250),
                polling: .milliseconds(10),
                isLoading: { isLoadingEarlier },
                while: { selectedChannelID == channelID }
            )
        }

        func runAuthenticatedHistoryPaginationPerformanceBenchmark() async {
            guard runsChatPerformanceBenchmark, sessionState == .workspace else { return }
            await channelLoadTask?.value
            await waitForSelectedEarlierHistoryIdle()
            if !hasMoreMessages, let snapshot {
                let candidates = benchmarkEligibleChannels(snapshot.channels)
                for channel in candidates where !hasMoreMessages {
                    guard !Task.isCancelled else { return }
                    _ = await runAuthenticatedNavigationBenchmarkOperation(
                        channel: channel,
                        kind: channel.guildID == nil ? .directMessage : .channel
                    )
                    await waitForSelectedEarlierHistoryIdle()
                }
            }
            guard !Task.isCancelled, hasMoreMessages, selectedChannelID != nil else {
                writeAuthenticatedHistoryPaginationBenchmarkResult(
                    outcome: "unavailable",
                    pageCount: 0
                )
                return
            }

            var pageCount = 0
            await AppPerformanceSignposts.measuredBenchmark(
                "AuthenticatedHistoryPaginationBenchmark",
                completedEvent: "AuthenticatedHistoryPaginationBenchmarkCompleted"
            ) {
                while pageCount < 5, hasMoreMessages, !Task.isCancelled {
                    let messageCount = messages.count
                    await loadEarlier()
                    if messages.count > messageCount {
                        pageCount += 1
                    } else {
                        break
                    }
                    await Task.yield()
                }
            }
            writeAuthenticatedHistoryPaginationBenchmarkResult(
                outcome: pageCount > 0 ? "completed" : "failed",
                pageCount: pageCount
            )
        }

        private func writeAuthenticatedHistoryPaginationBenchmarkResult(
            outcome: String,
            pageCount: Int
        ) {
            PerformanceBenchmarkHarness.writeResultFields {
                [("outcome", outcome), ("page_count", pageCount)]
            }
        }

        func runAuthenticatedAccountSwitchPerformanceBenchmark() async {
            guard runsChatPerformanceBenchmark, sessionState == .workspace else { return }
            let originalPreferredAccountID = await savedAccountStore.preferredAccountID()
            let sourceAccountID = activeAccountID ?? originalPreferredAccountID
            let handles: [CredentialHandle]
            do {
                handles = try await credentialStore.handles()
                rememberCredentialHandles(handles)
            } catch {
                writeAuthenticatedAccountSwitchBenchmarkResult(
                    outcome: "credential-error",
                    switchCount: 0,
                    sourceAccountID: sourceAccountID,
                    targetAccountID: nil
                )
                return
            }
            guard let target = handles
                .filter({ $0.accountID != activeAccountID })
                .sorted(by: { $0.accountID < $1.accountID })
                .first
            else {
                writeAuthenticatedAccountSwitchBenchmarkResult(
                    outcome: "unavailable",
                    switchCount: 0,
                    sourceAccountID: sourceAccountID,
                    targetAccountID: nil
                )
                return
            }

            await awaitAuthenticatedBenchmarkReadiness()
            guard !Task.isCancelled else { return }

            var switched = false
            var reachedFirstFrame = false
            await AppPerformanceSignposts.measuredBenchmark(
                "AuthenticatedAccountSwitchBenchmark",
                completedEvent: "AuthenticatedAccountSwitchBenchmarkCompleted"
            ) {
                switched = await switchAccount(to: target.accountID)
                guard switched, let selectedChannelID else { return }
                async let firstFrame: Void =
                    AppPerformanceSignposts.waitForConversationFirstFrame(
                        channelID: selectedChannelID
                    )
                await channelLoadTask?.value
                await firstFrame
                reachedFirstFrame = hasCompletedInitialMessageLoad
                    && self.selectedChannelID == selectedChannelID
            }

            await savedAccountStore.setPreferredAccountID(
                originalPreferredAccountID
            )
            writeAuthenticatedAccountSwitchBenchmarkResult(
                outcome: switched && reachedFirstFrame ? "completed" : "failed",
                switchCount: switched && reachedFirstFrame ? 1 : 0,
                sourceAccountID: sourceAccountID,
                targetAccountID: target.accountID
            )
        }

        private func writeAuthenticatedAccountSwitchBenchmarkResult(
            outcome: String,
            switchCount: Int,
            sourceAccountID: String?,
            targetAccountID: String?
        ) {
            PerformanceBenchmarkHarness.writeResultFields {
                [
                    ("outcome", outcome),
                    ("switch_count", switchCount),
                    ("source_account_id", sourceAccountID ?? ""),
                    ("target_account_id", targetAccountID ?? ""),
                ]
            }
        }

        func runAuthenticatedGestureScrollPerformanceBenchmark() async {
            guard runsChatPerformanceBenchmark,
                  sessionState == .workspace
            else { return }
            await awaitAuthenticatedBenchmarkReadiness()
            guard !Task.isCancelled else { return }

            await AppPerformanceSignposts.measuredBenchmark(
                "AuthenticatedGestureScrollBenchmark",
                completedEvent: "AuthenticatedGestureScrollBenchmarkCompleted"
            ) {
                AppPerformanceSignposts.signposter.emitEvent(
                    "AuthenticatedGestureScrollBenchmarkReady"
                )
                try? await Task.sleep(for: .seconds(20))
            }
            writeAuthenticatedScrollInteractionBenchmarkResult(
                outcome: Task.isCancelled ? "cancelled" : "completed",
                target: "current",
                messageCount: messages.count
            )
        }

        func runAuthenticatedLoadingScrollOverlapPerformanceBenchmark() async {
            guard runsChatPerformanceBenchmark,
                  sessionState == .workspace
            else { return }
            await awaitAuthenticatedBenchmarkReadiness()
            guard !Task.isCancelled else {
                writeAuthenticatedLoadingScrollUnavailable("cancelled-before-setup")
                return
            }
            guard let snapshot else {
                writeAuthenticatedLoadingScrollUnavailable("snapshot-missing")
                return
            }
            guard let targetGuild = serverRailGuildsByID.values.first(where: {
                $0.name.localizedCaseInsensitiveCompare(Self.benchmarkGuildName)
                    == .orderedSame
            }) else {
                writeAuthenticatedLoadingScrollUnavailable("target-guild-missing")
                return
            }
            guard selectedGuildID != targetGuild.id else {
                writeAuthenticatedLoadingScrollUnavailable("target-preselected")
                return
            }
            guard let channel = benchmarkTargetChannel(in: targetGuild.id, of: snapshot) else {
                writeAuthenticatedLoadingScrollUnavailable("target-channels-missing")
                return
            }

            await settleAuthenticatedLoadingScrollIdleControl()
            guard !Task.isCancelled else {
                writeAuthenticatedLoadingScrollUnavailable("cancelled-during-idle-warmup")
                return
            }

            var opened = false
            var initialMessageCount = 0
            await AppPerformanceSignposts.measuredBenchmark(
                "AuthenticatedLoadingScrollOverlapBenchmark",
                completedEvent: "AuthenticatedLoadingScrollOverlapBenchmarkCompleted"
            ) {
                AppPerformanceSignposts.signposter.emitEvent(
                    "AuthenticatedLoadingScrollOverlapBenchmarkReady"
                )
                AppPerformanceSignposts.signposter.emitEvent(
                    "AuthenticatedLoadingScrollIdleControlReady"
                )
                let idleControl = AppPerformanceSignposts.signposter.beginInterval(
                    "AuthenticatedLoadingScrollIdleControl"
                )
                try? await Task.sleep(for: .seconds(8))
                AppPerformanceSignposts.signposter.endInterval(
                    "AuthenticatedLoadingScrollIdleControl",
                    idleControl
                )

                let loadingWork = AppPerformanceSignposts.signposter.beginInterval(
                    "AuthenticatedLoadingScrollWork"
                )
                opened = await runAuthenticatedNavigationBenchmarkOperation(
                    channel: channel,
                    kind: .server
                )
                initialMessageCount = opened ? messages.count : 0
                if opened {
                    await memberLoadTask?.value
                    _ = await prepareSelectedTimelineScrollHistory()
                }
                AppPerformanceSignposts.signposter.endInterval(
                    "AuthenticatedLoadingScrollWork",
                    loadingWork
                )
                try? await Task.sleep(for: .seconds(3))
            }
            writeAuthenticatedScrollInteractionBenchmarkResult(
                outcome:
                    opened
                        && initialMessageCount == 10
                        && messages.count >= 100
                        && !Task.isCancelled
                    ? "completed"
                    : (Task.isCancelled ? "cancelled" : "failed"),
                target: targetGuild.name,
                messageCount: messages.count,
                initialMessageCount: initialMessageCount,
                channel: channel
            )
        }

        private func settleAuthenticatedLoadingScrollIdleControl() async {
            await waitForSelectedTimelineHistoryIdle()
            _ = await prepareSelectedTimelineScrollHistory()
            await memberLoadTask?.value
            guard !Task.isCancelled else { return }
            // The model operations above await their state commits, while
            // SwiftUI/AppKit presentation follows on the next display turns.
            // Keep those final publications outside the idle control so its
            // latency distribution contains only user scrolling, never a
            // bootstrap pagination-boundary redraw.
            await waitForSelectedTimelineHistoryIdle()
        }

        private func waitForSelectedTimelineHistoryIdle() async {
            await waitForHistoryIdle(
                for: .milliseconds(500),
                polling: .milliseconds(20),
                isLoading: { isLoadingEarlier || isLoadingLater }
            )
        }

        private func awaitAuthenticatedBenchmarkReadiness() async {
            await channelLoadTask?.value
            if let selectedChannelID {
                await AppPerformanceSignposts.waitForConversationFirstFrame(
                    channelID: selectedChannelID
                )
            }
        }

        private func writeAuthenticatedLoadingScrollUnavailable(_ detail: String) {
            writeAuthenticatedScrollInteractionBenchmarkResult(
                outcome: "unavailable",
                target: Self.benchmarkGuildName,
                messageCount: 0,
                initialMessageCount: 0,
                detail: detail
            )
        }

        private func benchmarkTargetChannel(
            in guildID: GuildID,
            of snapshot: BootstrapSnapshot
        ) -> Channel? {
            benchmarkConversationChannels(
                snapshot.channels.filter { $0.guildID == guildID }
            ).sorted(by: Self.prefersStableLoadingBenchmarkChannel).first
        }

        private nonisolated static func prefersStableLoadingBenchmarkChannel(
            _ lhs: Channel,
            _ rhs: Channel
        ) -> Bool {
            let lhsIsGeneral = lhs.name.localizedLowercase.hasSuffix("general")
            let rhsIsGeneral = rhs.name.localizedLowercase.hasSuffix("general")
            if lhsIsGeneral != rhsIsGeneral {
                return lhsIsGeneral
            }
            let lhsHasHistory = lhs.lastMessageID != nil
            let rhsHasHistory = rhs.lastMessageID != nil
            if lhsHasHistory != rhsHasHistory {
                return lhsHasHistory
            }
            return lhs.id.rawValue < rhs.id.rawValue
        }

        private func writeAuthenticatedScrollInteractionBenchmarkResult(
            outcome: String,
            target: String,
            messageCount: Int,
            initialMessageCount: Int? = nil,
            detail: String = "",
            channel: Channel? = nil
        ) {
            PerformanceBenchmarkHarness.writeResultFields {
                [
                    ("outcome", outcome),
                    ("detail", detail),
                    ("target", target),
                    ("target_channel_id", channel?.id.rawValue.description ?? ""),
                    ("target_channel_name", channel?.name ?? ""),
                    ("surface", PerformanceBenchmarkHarness.scrollSurface),
                    (
                        "display_maximum_frames_per_second",
                        max(1, NSApp.keyWindow?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60)
                    ),
                    ("initial_message_count", initialMessageCount ?? messageCount),
                    ("message_count", messageCount),
                ]
            }
        }

        func runAuthenticatedNavigationPerformanceBenchmark() async {
            guard runsChatPerformanceBenchmark, sessionState == .workspace else { return }
            await awaitAuthenticatedBenchmarkReadiness()
            guard !Task.isCancelled, let snapshot else {
                writeAuthenticatedNavigationBenchmarkResult(
                    outcome: "unavailable",
                    directMessageCount: 0,
                    serverCount: 0,
                    channelCount: 0
                )
                return
            }

            var directMessageCount = 0
            var serverCount = 0
            var channelCount = 0
            await AppPerformanceSignposts.measuredBenchmark(
                "AuthenticatedNavigationBenchmark",
                completedEvent: "AuthenticatedNavigationBenchmarkCompleted"
            ) {
                let initialChannelID = selectedChannelID
                let privateNavigation = await runAuthenticatedPrivateNavigationBenchmark(
                    snapshot: snapshot,
                    initialChannelID: initialChannelID
                )
                directMessageCount = privateNavigation.count
                var visitedChannelIDs = privateNavigation.visitedChannelIDs

                let initialGuildID = selectedGuildID
                let orderedGuildIDs = serverRailItems.flatMap { item -> [GuildID] in
                    switch item {
                    case .guild(let guildID): [guildID]
                    case .folder(let folder): folder.guildIDs
                    }
                }
                var visitedGuildIDs: Set<GuildID> = []
                for guildID in orderedGuildIDs where serverCount < 3 {
                    guard !Task.isCancelled else { return }
                    guard guildID != initialGuildID,
                          visitedGuildIDs.insert(guildID).inserted
                    else { continue }
                    let candidates = benchmarkEligibleChannels(
                        snapshot.channels.filter { $0.guildID == guildID }
                    )
                    guard let serverChannel = candidates.first(where: {
                        !visitedChannelIDs.contains($0.id)
                    }) else { continue }
                    visitedChannelIDs.insert(serverChannel.id)
                    if await runAuthenticatedNavigationBenchmarkOperation(
                        channel: serverChannel,
                        kind: .server
                    ) {
                        serverCount += 1
                    }
                    guard !Task.isCancelled,
                          let secondChannel = candidates.first(where: {
                              !visitedChannelIDs.contains($0.id)
                          })
                    else { continue }
                    visitedChannelIDs.insert(secondChannel.id)
                    if await runAuthenticatedNavigationBenchmarkOperation(
                        channel: secondChannel,
                        kind: .channel
                    ) {
                        channelCount += 1
                    }
                }
            }
            writeAuthenticatedNavigationBenchmarkResult(
                outcome: Task.isCancelled ? "cancelled" : "completed",
                directMessageCount: directMessageCount,
                serverCount: serverCount,
                channelCount: channelCount
            )
        }

        private func runAuthenticatedPrivateNavigationBenchmark(
            snapshot: BootstrapSnapshot,
            initialChannelID: ChannelID?
        ) async -> (count: Int, visitedChannelIDs: Set<ChannelID>) {
            var visitedChannelIDs: Set<ChannelID> = initialChannelID.map { [$0] } ?? []
            let unorderedChannels = benchmarkEligibleChannels(
                snapshot.channels.filter { $0.guildID == nil }
            )
            let preferredChannelID = Self.preferredInitialChannelID(in: unorderedChannels)
            let channels = unorderedChannels.sorted { lhs, rhs in
                lhs.id == preferredChannelID && rhs.id != preferredChannelID
            }
            var count = 0
            for channel in channels where count < 2 {
                guard !Task.isCancelled else { break }
                guard visitedChannelIDs.insert(channel.id).inserted else { continue }
                if await runAuthenticatedNavigationBenchmarkOperation(
                    channel: channel,
                    kind: .directMessage
                ) {
                    count += 1
                }
            }
            return (count, visitedChannelIDs)
        }

        private func benchmarkEligibleChannels(_ channels: [Channel]) -> [Channel] {
            benchmarkConversationChannels(channels).filter {
                conversationAccess(for: $0).isReadable
            }
        }

        private func benchmarkConversationChannels(
            _ channels: [Channel]
        ) -> [Channel] {
            channels.filter { channel in
                switch channel.kind {
                case .text, .announcement, .directMessage, .groupDirectMessage:
                    true
                default:
                    false
                }
            }
        }

        private func runAuthenticatedNavigationBenchmarkOperation(
            channel: Channel,
            kind: AuthenticatedNavigationBenchmarkKind
        ) async -> Bool {
            let interval = AppPerformanceSignposts.signposter.beginInterval(
                kind.intervalName
            )
            defer {
                AppPerformanceSignposts.signposter.endInterval(
                    kind.intervalName,
                    interval
                )
            }
            if selectedGuildID != channel.guildID {
                if let guildID = channel.guildID {
                    lastOpenedChannelIDsByGuild[guildID] = channel.id
                }
                await activateGuild(channel.guildID)
            }
            guard !Task.isCancelled else { return false }
            if selectedChannelID != channel.id {
                selectedChannelID = channel.id
            }
            guard selectedChannelID == channel.id else { return false }
            async let firstFrame: Void =
                AppPerformanceSignposts.waitForConversationFirstFrame(
                    channelID: channel.id
                )
            await channelLoadTask?.value
            await firstFrame
            return !Task.isCancelled
                && selectedChannelID == channel.id
                && hasCompletedInitialMessageLoad
        }

        private func writeAuthenticatedNavigationBenchmarkResult(
            outcome: String,
            directMessageCount: Int,
            serverCount: Int,
            channelCount: Int
        ) {
            PerformanceBenchmarkHarness.writeResultFields {
                [
                    ("outcome", outcome),
                    ("direct_message_count", directMessageCount),
                    ("server_count", serverCount),
                    ("channel_count", channelCount),
                ]
            }
        }
    }
#endif
