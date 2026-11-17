import DiscordProtocol
import Foundation
import SakuraCordModels

/// Recently visited conversation destinations and the guild and channel
/// frecency Discord ranks them by.
extension AppModel {
    nonisolated static func updatedConversationDestinationHistory(
        _ history: [ChannelID],
        visiting channelID: ChannelID
    ) -> [ChannelID] {
        var result = history.filter { $0 != channelID }
        result.insert(channelID, at: 0)
        return Array(result.prefix(8))
    }

    func configureConversationDestinationHistoryScope(_ scope: String) {
        let safeScope = DiscordFrecencyStore.safeScope(scope)
        let historyKey = "dev.sakuracord.forward-destination-history.\(safeScope)"
        let deltasKey = "dev.sakuracord.forward-frecency-deltas.\(safeScope)"
        if discordFrecencyUsageDeltasDefaultsKey != deltasKey {
            appliedDiscordFrecencyDeltasKey = nil
        }
        destinationHistoryDefaultsKey = historyKey
        discordFrecencyUsageDeltasDefaultsKey = deltasKey
        guard !isEphemeral else {
            conversationDestinationHistory = []
            persistedDiscordFrecencyUsageDeltas = [:]
            appliedDiscordFrecencyDeltasKey = nil
            return
        }
        conversationDestinationHistory = Array(
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

    func recordConversationDestinationVisit(_ channelID: ChannelID) {
        conversationDestinationHistory = Self.updatedConversationDestinationHistory(
            conversationDestinationHistory,
            visiting: channelID
        )
        guard !isEphemeral else { return }
        UserDefaults.standard.set(
            conversationDestinationHistory.map(\.description),
            forKey: destinationHistoryDefaultsKey
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
        guard !isEphemeral else { return }
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
}
