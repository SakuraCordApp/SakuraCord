import AppKit
import DiscordProtocol
import Foundation
import SakuraCordModels

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
                      $0.name.localizedCaseInsensitiveCompare("Google Labs")
                          == .orderedSame
                  }),
                  let channel = benchmarkConversationChannels(
                      snapshot.channels.filter { $0.guildID == targetGuild.id }
                  ).sorted(by: Self.prefersStableLoadingBenchmarkChannel).first
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
                await waitForSelectedEarlierHistoryRequest(channelID: channelID)
                pageCount += 1
                guard messages.count > previousCount else { break }
            }
            return messages.count >= 100
        }

        private func waitForSelectedEarlierHistoryRequest(
            channelID: ChannelID?
        ) async {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(12))
            while !Task.isCancelled,
                  selectedChannelID == channelID,
                  isLoadingEarlier,
                  clock.now < deadline
            {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        func runAuthenticatedHistoryPaginationPerformanceBenchmark() async {
            guard runsChatPerformanceBenchmark, sessionState == .workspace else { return }
            await channelLoadTask?.value
            await waitForSelectedEarlierHistoryIdle(
                channelID: selectedChannelID
            )
            if !hasMoreMessages, let snapshot {
                let candidates = benchmarkEligibleChannels(snapshot.channels)
                for channel in candidates where !hasMoreMessages {
                    guard !Task.isCancelled else { return }
                    _ = await runAuthenticatedNavigationBenchmarkOperation(
                        channel: channel,
                        kind: channel.guildID == nil ? .directMessage : .channel
                    )
                    await waitForSelectedEarlierHistoryIdle(
                        channelID: selectedChannelID
                    )
                }
            }
            guard !Task.isCancelled, hasMoreMessages, selectedChannelID != nil else {
                writeAuthenticatedHistoryPaginationBenchmarkResult(
                    outcome: "unavailable",
                    pageCount: 0
                )
                return
            }

            let overall = AppPerformanceSignposts.signposter.beginInterval(
                "AuthenticatedHistoryPaginationBenchmark"
            )
            AppPerformanceSignposts.beginResourceWindow(
                named: "AuthenticatedHistoryPaginationBenchmark"
            )
            var pageCount = 0
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
            AppPerformanceSignposts.signposter.endInterval(
                "AuthenticatedHistoryPaginationBenchmark",
                overall
            )
            AppPerformanceSignposts.endResourceWindow(
                named: "AuthenticatedHistoryPaginationBenchmark"
            )
            AppPerformanceSignposts.signposter.emitEvent(
                "AuthenticatedHistoryPaginationBenchmarkCompleted"
            )
            writeAuthenticatedHistoryPaginationBenchmarkResult(
                outcome: pageCount > 0 ? "completed" : "failed",
                pageCount: pageCount
            )
        }

        private func waitForSelectedEarlierHistoryIdle(
            channelID: ChannelID?
        ) async {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(12))
            var idleSince: ContinuousClock.Instant?
            while !Task.isCancelled,
                  selectedChannelID == channelID,
                  clock.now < deadline
            {
                if isLoadingEarlier {
                    idleSince = nil
                } else if let idleSince {
                    if idleSince.duration(to: clock.now)
                        >= .milliseconds(250)
                    {
                        return
                    }
                } else {
                    idleSince = clock.now
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        private func writeAuthenticatedHistoryPaginationBenchmarkResult(
            outcome: String,
            pageCount: Int
        ) {
            guard let path = ProcessInfo.processInfo.environment[
                "SAKURACORD_PERFORMANCE_RESULT_PATH"
            ] else { return }
            let contents = """
            outcome\t\(outcome)
            page_count\t\(pageCount)

            """
            try? contents.write(
                to: URL(fileURLWithPath: path),
                atomically: true,
                encoding: .utf8
            )
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

            await channelLoadTask?.value
            if let selectedChannelID {
                await AppPerformanceSignposts.waitForConversationFirstFrame(
                    channelID: selectedChannelID
                )
            }
            guard !Task.isCancelled else { return }

            let overall = AppPerformanceSignposts.signposter.beginInterval(
                "AuthenticatedAccountSwitchBenchmark"
            )
            AppPerformanceSignposts.beginResourceWindow(
                named: "AuthenticatedAccountSwitchBenchmark"
            )
            let switched = await switchAccount(to: target.accountID)
            var reachedFirstFrame = false
            if switched, let selectedChannelID {
                async let firstFrame: Void =
                    AppPerformanceSignposts.waitForConversationFirstFrame(
                        channelID: selectedChannelID
                    )
                await channelLoadTask?.value
                await firstFrame
                reachedFirstFrame = hasCompletedInitialMessageLoad
                    && self.selectedChannelID == selectedChannelID
            }
            AppPerformanceSignposts.signposter.endInterval(
                "AuthenticatedAccountSwitchBenchmark",
                overall
            )
            AppPerformanceSignposts.endResourceWindow(
                named: "AuthenticatedAccountSwitchBenchmark"
            )
            AppPerformanceSignposts.signposter.emitEvent(
                "AuthenticatedAccountSwitchBenchmarkCompleted"
            )

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
            guard let path = ProcessInfo.processInfo.environment[
                "SAKURACORD_PERFORMANCE_RESULT_PATH"
            ] else { return }
            let contents = """
            outcome\t\(outcome)
            switch_count\t\(switchCount)
            source_account_id\t\(sourceAccountID ?? "")
            target_account_id\t\(targetAccountID ?? "")

            """
            try? contents.write(
                to: URL(fileURLWithPath: path),
                atomically: true,
                encoding: .utf8
            )
        }

        func runAuthenticatedGestureScrollPerformanceBenchmark() async {
            guard runsChatPerformanceBenchmark,
                  sessionState == .workspace
            else { return }
            await channelLoadTask?.value
            if let selectedChannelID {
                await AppPerformanceSignposts.waitForConversationFirstFrame(
                    channelID: selectedChannelID
                )
            }
            guard !Task.isCancelled else { return }

            let overall = AppPerformanceSignposts.signposter.beginInterval(
                "AuthenticatedGestureScrollBenchmark"
            )
            AppPerformanceSignposts.beginResourceWindow(
                named: "AuthenticatedGestureScrollBenchmark"
            )
            AppPerformanceSignposts.signposter.emitEvent(
                "AuthenticatedGestureScrollBenchmarkReady"
            )
            try? await Task.sleep(for: .seconds(20))
            AppPerformanceSignposts.signposter.endInterval(
                "AuthenticatedGestureScrollBenchmark",
                overall
            )
            AppPerformanceSignposts.endResourceWindow(
                named: "AuthenticatedGestureScrollBenchmark"
            )
            AppPerformanceSignposts.signposter.emitEvent(
                "AuthenticatedGestureScrollBenchmarkCompleted"
            )
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
                $0.name.localizedCaseInsensitiveCompare("Google Labs")
                    == .orderedSame
            }) else {
                writeAuthenticatedLoadingScrollUnavailable("target-guild-missing")
                return
            }
            guard selectedGuildID != targetGuild.id else {
                writeAuthenticatedLoadingScrollUnavailable("target-preselected")
                return
            }
            guard let channel = benchmarkConversationChannels(
                snapshot.channels.filter {
                    $0.guildID == targetGuild.id
                }
            ).sorted(by: Self.prefersStableLoadingBenchmarkChannel).first else {
                writeAuthenticatedLoadingScrollUnavailable("target-channels-missing")
                return
            }

            await settleAuthenticatedLoadingScrollIdleControl()
            guard !Task.isCancelled else {
                writeAuthenticatedLoadingScrollUnavailable("cancelled-during-idle-warmup")
                return
            }

            let overall = AppPerformanceSignposts.signposter.beginInterval(
                "AuthenticatedLoadingScrollOverlapBenchmark"
            )
            AppPerformanceSignposts.beginResourceWindow(
                named: "AuthenticatedLoadingScrollOverlapBenchmark"
            )
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
            let opened = await runAuthenticatedNavigationBenchmarkOperation(
                channel: channel,
                kind: .server
            )
            let initialMessageCount = opened ? messages.count : 0
            if opened {
                await memberLoadTask?.value
                _ = await prepareSelectedTimelineScrollHistory()
            }
            AppPerformanceSignposts.signposter.endInterval(
                "AuthenticatedLoadingScrollWork",
                loadingWork
            )
            try? await Task.sleep(for: .seconds(3))
            AppPerformanceSignposts.signposter.endInterval(
                "AuthenticatedLoadingScrollOverlapBenchmark",
                overall
            )
            AppPerformanceSignposts.endResourceWindow(
                named: "AuthenticatedLoadingScrollOverlapBenchmark"
            )
            AppPerformanceSignposts.signposter.emitEvent(
                "AuthenticatedLoadingScrollOverlapBenchmarkCompleted"
            )
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
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(12))
            var idleSince: ContinuousClock.Instant?
            while !Task.isCancelled, clock.now < deadline {
                if isLoadingEarlier || isLoadingLater {
                    idleSince = nil
                } else if let idleSince {
                    if idleSince.duration(to: clock.now)
                        >= .milliseconds(500)
                    {
                        return
                    }
                } else {
                    idleSince = clock.now
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
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
                target: "Google Labs",
                messageCount: 0,
                initialMessageCount: 0,
                detail: detail
            )
        }

        private nonisolated static func prefersActiveBenchmarkChannel(
            _ lhs: Channel,
            _ rhs: Channel
        ) -> Bool {
            let lhsLastMessage = lhs.lastMessageID?.rawValue ?? 0
            let rhsLastMessage = rhs.lastMessageID?.rawValue ?? 0
            if lhsLastMessage != rhsLastMessage {
                return lhsLastMessage > rhsLastMessage
            }
            return lhs.id.rawValue < rhs.id.rawValue
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
            guard let path = ProcessInfo.processInfo.environment[
                "SAKURACORD_PERFORMANCE_RESULT_PATH"
            ] else { return }
            let contents = """
            outcome\t\(outcome)
            detail\t\(detail)
            target\t\(target)
            target_channel_id\t\(channel?.id.rawValue.description ?? "")
            target_channel_name\t\(channel?.name ?? "")
            surface\t\(ProcessInfo.processInfo.environment["SAKURACORD_PERFORMANCE_SCROLL_SURFACE"] ?? "all")
            display_maximum_frames_per_second\t\(max(1, NSApp.keyWindow?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60))
            initial_message_count\t\(initialMessageCount ?? messageCount)
            message_count\t\(messageCount)

            """
            try? contents.write(
                to: URL(fileURLWithPath: path),
                atomically: true,
                encoding: .utf8
            )
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

            let overall = AppPerformanceSignposts.signposter.beginInterval(
                "AuthenticatedNavigationBenchmark"
            )
            AppPerformanceSignposts.beginResourceWindow(
                named: "AuthenticatedNavigationBenchmark"
            )
            var directMessageCount = 0
            var serverCount = 0
            var channelCount = 0
            defer {
                AppPerformanceSignposts.signposter.endInterval(
                    "AuthenticatedNavigationBenchmark",
                    overall
                )
                AppPerformanceSignposts.endResourceWindow(
                    named: "AuthenticatedNavigationBenchmark"
                )
                AppPerformanceSignposts.signposter.emitEvent(
                    "AuthenticatedNavigationBenchmarkCompleted"
                )
                writeAuthenticatedNavigationBenchmarkResult(
                    outcome: Task.isCancelled ? "cancelled" : "completed",
                    directMessageCount: directMessageCount,
                    serverCount: serverCount,
                    channelCount: channelCount
                )
            }

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
            benchmarkConversationChannels(channels).filter { channel in
                guard conversationAccess(for: channel).isReadable else { return false }
                return true
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
            guard let path = ProcessInfo.processInfo.environment[
                "SAKURACORD_PERFORMANCE_RESULT_PATH"
            ] else { return }
            let contents = """
            outcome\t\(outcome)
            direct_message_count\t\(directMessageCount)
            server_count\t\(serverCount)
            channel_count\t\(channelCount)

            """
            try? contents.write(
                to: URL(fileURLWithPath: path),
                atomically: true,
                encoding: .utf8
            )
        }
    }
#endif
