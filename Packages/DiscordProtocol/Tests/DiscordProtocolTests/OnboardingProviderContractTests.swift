@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

extension ProviderRequestContractTests {
    @Test func `onboarding reads coalesce and cache while response mutations use exact verbs`() async throws {
        RateLimitURLProtocol.reset()
        let provider = onboardingProvider()
        let guildID = GuildID(rawValue: 100)

        async let first = provider.onboardingConfiguration(in: guildID)
        async let second = provider.onboardingConfiguration(in: guildID)
        let (firstValue, secondValue) = try await (first, second)
        #expect(firstValue == secondValue)
        _ = try await provider.onboardingConfiguration(in: guildID)
        #expect(RateLimitURLProtocol.onboardingMethods == ["GET"])

        let submission = GuildOnboardingResponseSubmission.completeSnapshot(
            configuration: firstValue,
            selectedOptionIDs: ["option"],
            timestampMilliseconds: 1_786_000_000_123
        )
        _ = try await provider.submitOnboardingResponses(
            in: guildID, submission: submission, isInitial: true
        )
        let updated = try await provider.submitOnboardingResponses(
            in: guildID, submission: submission, isInitial: false
        )

        #expect(updated.prompts == firstValue.prompts)
        #expect(updated.selectedOptionIDs == ["option"])

        #expect(RateLimitURLProtocol.onboardingMethods == ["GET", "POST", "PUT"])
        #expect(RateLimitURLProtocol.onboardingPaths == [
            "/api/v9/guilds/100/onboarding",
            "/api/v9/guilds/100/onboarding-responses",
            "/api/v9/guilds/100/onboarding-responses",
        ])
        for body in RateLimitURLProtocol.onboardingBodies {
            #expect(body["onboarding_responses"] as? [String] == ["option"])
            let prompts = body["onboarding_prompts_seen"] as? [String: NSNumber]
            let options = body["onboarding_responses_seen"] as? [String: NSNumber]
            #expect(prompts?["prompt"]?.int64Value == 1_786_000_000_123)
            #expect(options?["option"]?.int64Value == 1_786_000_000_123)
        }
    }

    @Test func `channel opt in mutation preserves unrelated guild and channel flags`() async throws {
        RateLimitURLProtocol.reset()
        let provider = onboardingProvider()
        let unrelatedGuildFlag: UInt64 = 1 << 5
        let unrelatedChannelFlag: UInt64 = 1 << 6

        try await provider.updateChannelOptIns(
            in: GuildID(rawValue: 100),
            channelFlags: [
                ChannelID(rawValue: 200): unrelatedChannelFlag
                    | DiscordChannelSettingsFlags.optInEnabled
            ],
            guildFlags: unrelatedGuildFlag | DiscordGuildSettingsFlags.optInChannelsOff
        )

        #expect(RateLimitURLProtocol.guildNotificationRequestCount == 1)
        #expect(RateLimitURLProtocol.guildNotificationMethod == "PATCH")
        let guilds = RateLimitURLProtocol.guildNotificationBody?["guilds"] as? [String: Any]
        let guild = guilds?["100"] as? [String: Any]
        let flags = (guild?["flags"] as? NSNumber)?.uint64Value
        #expect(flags == unrelatedGuildFlag | DiscordGuildSettingsFlags.optInChannelsOn)
        let overrides = guild?["channel_overrides"] as? [String: Any]
        let channel = overrides?["200"] as? [String: Any]
        #expect((channel?["flags"] as? NSNumber)?.uint64Value
            == unrelatedChannelFlag | DiscordChannelSettingsFlags.optInEnabled)
    }

    private func onboardingProvider() -> DiscordRESTProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        return DiscordRESTProvider(
            credentials: TestCredentialStore(),
            handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration)
        )
    }
}
