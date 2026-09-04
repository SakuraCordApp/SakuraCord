import Foundation
import SakuraCordModels

public extension DiscordRESTProvider {
    internal static let onboardingCacheLifetime: TimeInterval = 8 * 60 * 60

    func onboardingConfiguration(in guildID: GuildID) async throws
        -> GuildOnboardingConfiguration
    {
        if let cached = cachedOnboardingConfigurations[guildID],
           Date().timeIntervalSince(cached.storedAt) < Self.onboardingCacheLifetime
        {
            return cached.value
        }
        if let task = onboardingConfigurationTasks[guildID] {
            return try await task.value
        }
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            var value: GuildOnboardingConfiguration = try await self.request(
                "/guilds/\(guildID)/onboarding"
            )
            value.guildID = guildID
            return value
        }
        onboardingConfigurationTasks[guildID] = task
        do {
            let value = try await task.value
            onboardingConfigurationTasks[guildID] = nil
            cachedOnboardingConfigurations[guildID] = (value, Date())
            return value
        } catch {
            onboardingConfigurationTasks[guildID] = nil
            throw error
        }
    }

    func submitOnboardingResponses(
        in guildID: GuildID,
        submission: GuildOnboardingResponseSubmission,
        isInitial: Bool
    ) async throws -> GuildOnboardingConfiguration {
        var response: GuildOnboardingConfiguration = try await request(
            "/guilds/\(guildID)/onboarding-responses",
            method: isInitial ? "POST" : "PUT",
            body: [
                "onboarding_responses": .array(submission.selectedOptionIDs.map(JSONValue.string)),
                "onboarding_prompts_seen": .object(
                    submission.promptsSeen.mapValues { .number(Double($0)) }
                ),
                "onboarding_responses_seen": .object(
                    submission.optionsSeen.mapValues { .number(Double($0)) }
                ),
            ]
        )
        response.guildID = guildID
        let value = cachedOnboardingConfigurations[guildID]?.value
            .reconcilingUserResponse(response, submission: submission, guildID: guildID)
            ?? response
        cachedOnboardingConfigurations[guildID] = (value, Date())
        return value
    }

    func updateChannelOptIns(
        in guildID: GuildID,
        channelFlags: [ChannelID: UInt64],
        guildFlags: UInt64?
    ) async throws {
        var settings: [String: JSONValue] = [
            "channel_overrides": .object(
                Dictionary(uniqueKeysWithValues: channelFlags.map { channelID, flags in
                    (channelID.description, .object(["flags": .number(Double(flags))]))
                })
            )
        ]
        if let currentFlags = guildFlags {
            settings["flags"] = .number(Double(
                (currentFlags | DiscordGuildSettingsFlags.optInChannelsOn)
                    & ~DiscordGuildSettingsFlags.optInChannelsOff
            ))
        }
        try await updateGuildNotificationSettings(guildID: guildID, settings: settings)
    }
}
