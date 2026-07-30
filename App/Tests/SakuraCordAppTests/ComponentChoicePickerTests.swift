import DiscordProtocol
import SakuraCordModels
import Testing
@testable import SakuraCord

@Test func `component select policy covers every select kind`() {
    #expect(
        NativeTimelineComponentSelectPolicy.isEnabled(
            kind: .string,
            hasStaticOptions: true,
            supportsComponents: true,
            supportsRemoteChoices: false,
            interactionUnavailable: false
        )
    )
    #expect(
        !NativeTimelineComponentSelectPolicy.isEnabled(
            kind: .string,
            hasStaticOptions: false,
            supportsComponents: true,
            supportsRemoteChoices: true,
            interactionUnavailable: false
        )
    )
    for kind in [
        ComponentSelectKind.user,
        .role,
        .mentionable,
        .channel,
    ] {
        #expect(
            NativeTimelineComponentSelectPolicy.isEnabled(
                kind: kind,
                hasStaticOptions: false,
                supportsComponents: true,
                supportsRemoteChoices: true,
                interactionUnavailable: false
            )
        )
        #expect(
            !NativeTimelineComponentSelectPolicy.isEnabled(
                kind: kind,
                hasStaticOptions: false,
                supportsComponents: true,
                supportsRemoteChoices: false,
                interactionUnavailable: false
            )
        )
    }
    #expect(
        !NativeTimelineComponentSelectPolicy.isEnabled(
            kind: .user,
            hasStaticOptions: false,
            supportsComponents: false,
            supportsRemoteChoices: true,
            interactionUnavailable: false
        )
    )
    #expect(
        !NativeTimelineComponentSelectPolicy.isEnabled(
            kind: .user,
            hasStaticOptions: false,
            supportsComponents: true,
            supportsRemoteChoices: true,
            interactionUnavailable: true
        )
    )
}

@MainActor
@Test func `component picker cancels obsolete requests and keeps latest results`()
    async throws
{
    let probe = ComponentChoiceLoaderProbe()
    let model = ComponentChoicePickerModel(debounce: .zero) { query in
        try await probe.load(query)
    }

    model.updateQuery("first")
    try await Task.sleep(for: .milliseconds(25))
    model.updateQuery("second")

    #expect(
        await eventuallyComponentChoice {
            model.state == .loaded
        }
    )
    #expect(model.choices.map(\.value) == ["second"])
    #expect(await probe.queries() == ["first", "second"])
    #expect(await probe.maximumActiveRequestCount() == 1)
}

@MainActor
@Test func `component picker represents empty results`() async {
    let model = ComponentChoicePickerModel(debounce: .zero) { _ in [] }

    model.loadInitialChoices()

    #expect(
        await eventuallyComponentChoice {
            model.state == .loaded
        }
    )
    #expect(model.choices.isEmpty)
}

@MainActor
@Test func `app model exposes only capability gated bounded choices`()
    async throws
{
    let disabledModel = AppModel(
        launchMode: .normal,
        discordNetworkDisabledOverride: true
    )
    await #expect(throws: ChatProviderError.self) {
        _ = try await disabledModel.componentChoices(
            kind: .user,
            query: "",
            guildID: nil,
            channelID: ChannelID(rawValue: 1)
        )
    }

    let offlineModel = AppModel(launchMode: .offlineTesting)
    await offlineModel.start()
    let choices = try await offlineModel.componentChoices(
        kind: .mentionable,
        query: "",
        guildID: GuildID(rawValue: 100),
        channelID: ChannelID(rawValue: 210)
    )

    #expect(offlineModel.supportsCapability(.remoteComponentChoices))
    #expect(!choices.isEmpty)
    #expect(choices.count <= 25)
}

private actor ComponentChoiceLoaderProbe {
    private var recordedQueries: [String] = []
    private var activeRequestCount = 0
    private var maximumActiveCount = 0

    func load(_ query: String) async throws -> [ComponentSelectOption] {
        recordedQueries.append(query)
        activeRequestCount += 1
        maximumActiveCount = max(
            maximumActiveCount,
            activeRequestCount
        )
        defer { activeRequestCount -= 1 }
        try await Task.sleep(for: .milliseconds(120))
        return [
            ComponentSelectOption(
                label: query,
                value: query
            )
        ]
    }

    func queries() -> [String] {
        recordedQueries
    }

    func maximumActiveRequestCount() -> Int {
        maximumActiveCount
    }
}

@MainActor
private func eventuallyComponentChoice(
    attempts: Int = 80,
    condition: @MainActor () -> Bool
) async -> Bool {
    for _ in 0 ..< attempts {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
