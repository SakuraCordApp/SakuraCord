import DiscordProtocol
import Foundation
import SakuraCordModels

private struct ForwardDestinationResolution: Sendable {
    let index: Int
    let channelID: ChannelID?
    let failure: String?
}

extension AppModel {
    func consumeForwardSearchPeopleEvent(_ event: ClientEvent) -> Bool {
        switch event {
        case .privateMembersChanged(let value):
            if selectedGuildID == nil { members = value }
        case .knownUsersChanged(let users):
            updateForwardSnapshot { $0.knownUsers = users }
        case .quickSwitcherUserIDsChanged(let userIDs):
            updateForwardSnapshot { $0.quickSwitcherUserIDs = userIDs }
        case .messageSearchUsersChanged(let users):
            updateForwardSnapshot { $0.messageSearchUsers = users }
        case .userSearchAliasesChanged(let aliases):
            updateForwardSnapshot { $0.userSearchAliasesByUserID = aliases }
        case .quickSwitcherGuildMemberUserIDsChanged(let userIDsByGuildID):
            updateForwardSnapshot { $0.quickSwitcherGuildMemberUserIDs = userIDsByGuildID }
        case .quickSwitcherJoinedMemberIDsChanged(let userIDsByGuildID):
            updateForwardSnapshot { $0.quickSwitcherJoinedGuildMemberUserIDs = userIDsByGuildID }
        case .quickSwitcherGuildMemberAliasesChanged(let aliasesByGuildID):
            updateForwardSnapshot { $0.quickSwitcherGuildMemberAliases = aliasesByGuildID }
        default:
            return false
        }
        return true
    }

    private func updateForwardSnapshot(
        _ update: (inout BootstrapSnapshot) -> Void
    ) {
        guard var value = snapshot else { return }
        update(&value)
        snapshot = value
        forwardSearchSourceRevision &+= 1
    }

    nonisolated static func updatedForwardDestinationHistory(
        _ history: [ChannelID],
        visiting channelID: ChannelID
    ) -> [ChannelID] {
        var result = history.filter { $0 != channelID }
        result.insert(channelID, at: 0)
        return Array(result.prefix(8))
    }

    func configureForwardDestinationHistoryScope(_ scope: String) {
        let safeScope = scope.replacingOccurrences(
            of: #"[^A-Za-z0-9_.-]"#, with: "-", options: .regularExpression
        )
        let historyKey = "dev.sakuracord.forward-destination-history.\(safeScope)"
        let deltasKey = "dev.sakuracord.forward-frecency-deltas.\(safeScope)"
        if discordFrecencyUsageDeltasDefaultsKey != deltasKey {
            appliedDiscordFrecencyDeltasKey = nil
        }
        forwardDestinationHistoryDefaultsKey = historyKey
        discordFrecencyUsageDeltasDefaultsKey = deltasKey
        guard launchMode == .normal else {
            forwardDestinationHistory = []
            persistedDiscordFrecencyUsageDeltas = [:]
            appliedDiscordFrecencyDeltasKey = nil
            return
        }
        forwardDestinationHistory = Array(
            (UserDefaults.standard.stringArray(forKey: historyKey) ?? [])
                .compactMap(ChannelID.init)
                .prefix(8)
        )
        if let data = UserDefaults.standard.data(forKey: discordFrecencyUsageDeltasDefaultsKey),
           let value = try? JSONDecoder().decode(
               [String: DiscordFrecencyUsage].self,
               from: data
           )
        {
            persistedDiscordFrecencyUsageDeltas = value
        } else {
            persistedDiscordFrecencyUsageDeltas = [:]
        }
        if hasLoadedDiscordEmojiSettings,
           appliedDiscordFrecencyDeltasKey
            != discordFrecencyUsageDeltasDefaultsKey
        {
            applyPersistedDiscordFrecencyUsageDeltas()
        }
    }

    func recordForwardDestinationVisit(_ channelID: ChannelID) {
        forwardDestinationHistory = Self.updatedForwardDestinationHistory(
            forwardDestinationHistory,
            visiting: channelID
        )
        guard launchMode == .normal else { return }
        UserDefaults.standard.set(
            forwardDestinationHistory.map(\.description),
            forKey: forwardDestinationHistoryDefaultsKey
        )
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        if lastDiscordFrecencyChannelID != channelID {
            lastDiscordFrecencyChannelID = channelID
            recordDiscordFrecencyUse(channelID.description, timestamp: now)
        }
        let guildID = snapshot?.channels.first(where: { $0.id == channelID })?.guildID
        if lastDiscordFrecencyGuildID != guildID {
            lastDiscordFrecencyGuildID = guildID
            if let guildID {
                recordDiscordFrecencyUse(guildID.description, timestamp: now)
            }
        }
    }

    func recordDiscordFrecencyUse(_ key: String, timestamp: UInt64) {
        recordPersistedDiscordFrecencyUsageDelta(key, timestamp: timestamp)
        guard hasLoadedDiscordEmojiSettings else {
            pendingDiscordFrecencyUses.append((key, timestamp))
            return
        }
        if discordGuildAndChannelUsage[key] == nil {
            discordGuildAndChannelUsageOrder.append(key)
        }
        var usage = discordGuildAndChannelUsage[key]
            ?? DiscordFrecencyUsage(totalUses: 0, recentUses: [])
        usage.totalUses += 1
        usage.recentUses.append(timestamp)
        while usage.recentUses.count > 10 {
            usage.recentUses.removeFirst()
        }
        discordGuildAndChannelUsage[key] = usage
        discordGuildAndChannelUsageScores[key] = Self.discordFrecencyScore(
            usage,
            nowMilliseconds: timestamp
        )
    }

    func applyPersistedDiscordFrecencyUsageDeltas() {
        guard appliedDiscordFrecencyDeltasKey
            != discordFrecencyUsageDeltasDefaultsKey
        else { return }
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        let orderedDeltas = persistedDiscordFrecencyUsageDeltas.sorted { lhs, rhs in
            let left = lhs.value.recentUses.min() ?? .max
            let right = rhs.value.recentUses.min() ?? .max
            return left == right ? lhs.key < rhs.key : left < right
        }
        for (key, delta) in orderedDeltas {
            if discordGuildAndChannelUsage[key] == nil {
                discordGuildAndChannelUsageOrder.append(key)
            }
            let usage = Self.mergedDiscordFrecencyUsage(
                base: discordGuildAndChannelUsage[key],
                delta: delta
            )
            discordGuildAndChannelUsage[key] = usage
            discordGuildAndChannelUsageScores[key] = Self.discordFrecencyScore(
                usage,
                nowMilliseconds: now
            )
        }
        pendingDiscordFrecencyUses = []
        appliedDiscordFrecencyDeltasKey =
            discordFrecencyUsageDeltasDefaultsKey
    }

    nonisolated static func mergedDiscordFrecencyUsage(
        base: DiscordFrecencyUsage?,
        delta: DiscordFrecencyUsage
    ) -> DiscordFrecencyUsage {
        DiscordFrecencyUsage(
            totalUses: (base?.totalUses ?? 0) + delta.totalUses,
            recentUses: Array(
                ((base?.recentUses ?? []) + delta.recentUses).sorted().suffix(10)
            )
        )
    }

    private func recordPersistedDiscordFrecencyUsageDelta(
        _ key: String,
        timestamp: UInt64
    ) {
        guard launchMode == .normal else { return }
        var delta = persistedDiscordFrecencyUsageDeltas[key]
            ?? DiscordFrecencyUsage(totalUses: 0, recentUses: [])
        delta.totalUses += 1
        delta.recentUses.append(timestamp)
        delta.recentUses.sort()
        delta.recentUses = Array(delta.recentUses.suffix(10))
        persistedDiscordFrecencyUsageDeltas[key] = delta
        if let data = try? JSONEncoder().encode(persistedDiscordFrecencyUsageDeltas) {
            UserDefaults.standard.set(data, forKey: discordFrecencyUsageDeltasDefaultsKey)
        }
    }

    nonisolated static func discordFrecencyScore(
        _ usage: DiscordFrecencyUsage,
        nowMilliseconds: UInt64
    ) -> Int? {
        let samples = usage.recentUses.prefix(10)
        guard !samples.isEmpty else { return nil }
        let day: UInt64 = 86_400_000
        let score = samples.reduce(into: 0) { result, timestamp in
            let age = timestamp >= nowMilliseconds
                ? 0
                : Int((nowMilliseconds - timestamp) / day)
            let weight = switch age {
            case 0: 100
            case 1: 70
            case 2 ... 3: 50
            case 4 ... 6: 30
            default: 10
            }
            result += weight
        }
        let value = ceil(Double(usage.totalUses * score) / Double(samples.count))
        return value >= Double(Int.max) ? Int.max : Int(value)
    }

    func presentForwarding(_ message: Message) {
        guard canForward(message) else { return }
        forwardingErrorMessage = nil
        forwardingMessage = message
    }

    func dismissForwarding() {
        forwardingMessage = nil
        forwardingErrorMessage = nil
    }

    @discardableResult
    func forward(
        _ message: Message,
        to destinationChannelIDs: [ChannelID],
        context: String
    ) async -> Bool {
        await forward(
            message,
            to: destinationChannelIDs.map(ForwardDestinationID.channel),
            context: context
        )
    }

    @discardableResult
    func forward(
        _ message: Message,
        to destinationIDs: [ForwardDestinationID],
        context: String
    ) async -> Bool {
        let requestedDestinations = uniqueForwardDestinations(destinationIDs)
        guard supportedCapabilities.contains(.messageForwarding),
              canForward(message),
              !requestedDestinations.isEmpty
        else {
            forwardingErrorMessage = "Choose up to five available conversations."
            return false
        }
        let context = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard context.count <= 2_000 else {
            forwardingErrorMessage = "The optional message cannot exceed 2,000 characters."
            return false
        }
        let session = accountSession()
        forwardingErrorMessage = nil
        isForwardingMessages = true
        defer { isForwardingMessages = false }
        let resolutions = await resolveForwardDestinations(requestedDestinations, session: session)
        guard isCurrentAccountSession(session) else { return false }
        return await dispatchResolvedForwards(
            resolutions,
            message: message,
            context: context,
            session: session
        )
    }

    private func uniqueForwardDestinations(
        _ destinationIDs: [ForwardDestinationID]
    ) -> [ForwardDestinationID] {
        var seen: Set<ForwardDestinationID> = []
        return Array(destinationIDs.filter { seen.insert($0).inserted }.prefix(5))
    }

    private func resolveForwardDestinations(
        _ destinationIDs: [ForwardDestinationID],
        session: AppModelAccountSession
    ) async -> [ForwardDestinationResolution] {
        let knownChannels = snapshot?.channels ?? []
        let knownThreadIDs = Set(snapshot?.threads.map(\.id) ?? [])
        return await withTaskGroup(
            of: ForwardDestinationResolution.self,
            returning: [ForwardDestinationResolution].self
        ) { group in
            for (index, destination) in destinationIDs.enumerated() {
                group.addTask {
                    await Self.resolveForwardDestination(
                        destination,
                        index: index,
                        knownChannels: knownChannels,
                        knownThreadIDs: knownThreadIDs,
                        provider: session.provider
                    )
                }
            }
            var results: [ForwardDestinationResolution] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.index < $1.index }
        }
    }

    nonisolated private static func resolveForwardDestination(
        _ destination: ForwardDestinationID,
        index: Int,
        knownChannels: [Channel],
        knownThreadIDs: Set<ChannelID>,
        provider: any ChatProvider
    ) async -> ForwardDestinationResolution {
        switch destination {
        case .channel(let channelID):
            let isKnown = knownChannels.contains {
                $0.id == channelID && supportsForwardDestination($0.kind)
            } || knownThreadIDs.contains(channelID)
            return ForwardDestinationResolution(
                index: index,
                channelID: isKnown ? channelID : nil,
                failure: isKnown ? nil : "Destination is no longer available."
            )
        case .user(let userID):
            if let directMessage = knownChannels.first(where: {
                $0.kind == .directMessage && $0.recipients.contains { $0.id == userID }
            }) {
                return ForwardDestinationResolution(
                    index: index, channelID: directMessage.id, failure: nil
                )
            }
            do {
                let channel = try await provider.ensurePrivateChannel(for: userID)
                return ForwardDestinationResolution(
                    index: index, channelID: channel.id, failure: nil
                )
            } catch {
                return ForwardDestinationResolution(
                    index: index, channelID: nil, failure: error.localizedDescription
                )
            }
        }
    }

    private func dispatchResolvedForwards(
        _ resolutions: [ForwardDestinationResolution],
        message: Message,
        context: String,
        session: AppModelAccountSession
    ) async -> Bool {
        let destinations = resolutions.compactMap(\.channelID)
        let resolutionFailures = resolutions.compactMap(\.failure)
        // The official modal closes after destination resolution and before
        // dispatch. With exactly one resolved channel it also transitions to
        // that conversation before sending the forward.
        forwardingMessage = nil
        if destinations.count == 1 { navigate(to: destinations[0]) }
        guard !destinations.isEmpty else {
            recordForwardingFailures(
                resolutionFailures.isEmpty
                    ? ["The selected conversations are no longer available."]
                    : resolutionFailures
            )
            return false
        }
        let contextDestinationIDs = Set(destinations.filter(shouldSendForwardContext))
        let failures = await sendForwards(
            message,
            destinations: destinations,
            context: context,
            contextDestinationIDs: contextDestinationIDs,
            provider: session.provider,
            existingFailures: resolutionFailures
        )
        guard isCurrentAccountSession(session) else { return false }
        guard !failures.isEmpty else { return true }
        recordForwardingFailures(failures)
        return false
    }

    private func sendForwards(
        _ message: Message,
        destinations: [ChannelID],
        context: String,
        contextDestinationIDs: Set<ChannelID>,
        provider: any ChatProvider,
        existingFailures: [String]
    ) async -> [String] {
        await withTaskGroup(of: String?.self, returning: [String].self) { group in
            for destinationID in destinations {
                group.addTask {
                    do {
                        _ = try await provider.forward(ForwardMessageDraft(
                            sourceMessageID: message.id,
                            sourceChannelID: message.channelID,
                            sourceGuildID: message.guildID,
                            destinationChannelID: destinationID
                        ))
                        if !context.isEmpty, contextDestinationIDs.contains(destinationID) {
                            _ = try await provider.send(SendMessageDraft(
                                channelID: destinationID,
                                content: context
                            ))
                        }
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }
            }
            var failures = existingFailures
            for await failure in group {
                if let failure { failures.append(failure) }
            }
            return failures
        }
    }

    private func recordForwardingFailures(_ failures: [String]) {
        forwardingErrorMessage = failures.count == 1
            ? failures[0]
            : "Forwarding failed for \(failures.count) destinations."
        errorMessage = forwardingErrorMessage
    }

    nonisolated static func supportsForwardDestination(_ kind: ChannelKindValue) -> Bool {
        switch kind {
        case .text, .announcement, .voice, .directMessage, .groupDirectMessage: true
        case .forum, .unknown: false
        }
    }

    nonisolated static func supportsForwardSearchCandidate(_ kind: ChannelKindValue) -> Bool {
        switch kind {
        case .text, .announcement, .forum, .voice, .groupDirectMessage: true
        case .directMessage, .unknown: false
        }
    }
}
