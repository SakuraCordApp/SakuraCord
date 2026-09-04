@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing
@testable import SakuraCord

@Test func `onboarding questions compact automatically after twelve options`() {
    let options = (1 ... 13).map {
        GuildOnboardingOption(id: "device-\($0)", title: "Device \($0)")
    }
    let cardPrompt = GuildOnboardingPrompt(
        id: "cards",
        type: 1,
        options: Array(options.prefix(12)),
        title: "Twelve devices"
    )
    let listPrompt = GuildOnboardingPrompt(
        id: "list",
        type: 0,
        options: options,
        title: "Thirteen devices"
    )
    #expect(!cardPrompt.usesCompactOptionList)
    #expect(listPrompt.usesCompactOptionList)
}

@Test func `custom onboarding emoji retains its animated CDN metadata`() throws {
    let emoji = GuildOnboardingEmoji(id: "123456", name: "device", isAnimated: true)
    let url = try #require(emoji.imageURL(size: 64))
    #expect(url.path == "/emojis/123456.gif")
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [
        URLQueryItem(name: "size", value: "64"),
        URLQueryItem(name: "quality", value: "lossless"),
    ])
}

@Test func `onboarding decoding preserves administrator prompt and option order`() throws {
    let data = Data(
        #"""
        {
          "prompts": [
            {
              "id": "second-prompt",
              "type": 0,
              "options": [
                {
                  "id": "second-option",
                  "channel_ids": [],
                  "role_ids": [],
                  "title": "Second"
                },
                {
                  "id": "first-option",
                  "channel_ids": [],
                  "role_ids": [],
                  "title": "First"
                }
              ],
              "title": "Displayed first",
              "single_select": false,
              "required": false,
              "in_onboarding": true
            },
            {
              "id": "first-prompt",
              "type": 0,
              "options": [],
              "title": "Displayed second",
              "single_select": false,
              "required": false,
              "in_onboarding": true
            }
          ]
        }
        """#.utf8
    )

    let configuration = try JSONDecoder().decode(GuildOnboardingConfiguration.self, from: data)
    #expect(configuration.prompts.map(\.id) == ["second-prompt", "first-prompt"])
    #expect(configuration.prompts[0].options.map(\.id) == ["second-option", "first-option"])
}

@MainActor
@Test func `initial onboarding remains blocking until Discord confirms completion`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let guildID = GuildID(rawValue: 100)
    model.selectGuild(guildID)
    model.currentUserMemberFlagsByGuild[guildID] = DiscordGuildMemberFlags.startedOnboarding
    await model.loadOnboardingIfNeeded(for: guildID)

    #expect(model.initialOnboardingPresentation?.guildID == guildID)
    await model.submitInitialOnboarding(guildID: guildID)
    #expect(await provider.onboardingResponseRequests.map(\.isInitial) == [true])
    #expect(model.onboardingWaitingGuildIDs.contains(guildID))
    #expect(model.initialOnboardingPresentation != nil)

    model.consumeWorkspaceEvent(.currentUserMemberFlagsChanged(
        guildID: guildID,
        flags: DiscordGuildMemberFlags.startedOnboarding
            | DiscordGuildMemberFlags.completedOnboarding
    ))
    #expect(model.initialOnboardingPresentation == nil)
    #expect(!model.onboardingWaitingGuildIDs.contains(guildID))
}

@MainActor
@Test func `existing member response save enables opt in mode additively`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let guildID = GuildID(rawValue: 100)
    model.selectGuild(guildID)
    await model.loadOnboardingIfNeeded(for: guildID)

    model.updateOnboardingSelection(
        guildID: guildID,
        promptID: "mock-channel-prompt",
        optionID: "mock-forum-option",
        isSelected: true
    )

    #expect(await eventuallyOnboarding {
        let responseCount = await provider.onboardingResponseRequests.count
        let optInCount = await provider.channelOptInRequests.count
        return responseCount == 1 && optInCount == 1
    })
    let response = try #require(await provider.onboardingResponseRequests.first)
    #expect(response.isInitial == false)
    #expect(Set(response.submission.selectedOptionIDs) == [
        "mock-design-role", "mock-forum-option",
    ])
    let optIn = try #require(await provider.channelOptInRequests.first)
    #expect(Set(optIn.channelFlags.keys) == [
        ChannelID(rawValue: 210), ChannelID(rawValue: 220),
    ])
    #expect(optIn.channelFlags.values.allSatisfy {
        $0 & DiscordChannelSettingsFlags.optInEnabled != 0
    })
    #expect(optIn.guildFlags == 0)
}

@MainActor
@Test func `partial role response preserves every guild question and selection`() async throws {
    let provider = MockChatProvider(returnsPartialOnboardingMutationResponse: true)
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let editedGuildID = GuildID(rawValue: 100)
    let untouchedGuildID = GuildID(rawValue: 200)
    model.selectGuild(editedGuildID)
    await model.loadOnboardingIfNeeded(for: editedGuildID)
    let original = try #require(model.onboardingConfigurationsByGuild[editedGuildID])
    var untouched = original
    untouched.guildID = untouchedGuildID
    untouched.selectedOptionIDs = ["mock-development-role"]
    model.onboardingConfigurationsByGuild[untouchedGuildID] = untouched

    model.updateOnboardingSelection(
        guildID: editedGuildID,
        promptID: "mock-role-prompt",
        optionID: "mock-development-role",
        isSelected: true
    )

    #expect(await eventuallyOnboarding {
        await provider.onboardingResponseRequests.count == 1
    })
    let edited = try #require(model.onboardingConfigurationsByGuild[editedGuildID])
    #expect(edited.prompts == original.prompts)
    #expect(Set(edited.selectedOptionIDs) == ["mock-design-role", "mock-development-role"])
    #expect(model.onboardingConfigurationsByGuild[untouchedGuildID] == untouched)
}

@Test func `followed category disables individual channel controls`() {
    #expect(ChannelIconPresentation.channelsAndRolesSystemImage
        == "rectangle.and.text.magnifyingglass")
    #expect(!BrowseChannelPresentation.individualToggleIsEnabled(isCategoryFollowed: true))
    #expect(BrowseChannelPresentation.individualToggleIsEnabled(isCategoryFollowed: false))
}

@Test func `browse channel activity uses only the largest relevant unit`() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(BrowseChannelPresentation.activityText(
        since: now.addingTimeInterval(-19 * 86_400 - 17 * 3_600),
        now: now
    ) == "Active 19 days ago")
    #expect(BrowseChannelPresentation.activityText(
        since: now.addingTimeInterval(-20 * 3_600 - 11 * 60),
        now: now
    ) == "Active 20 hours ago")
    #expect(BrowseChannelPresentation.activityText(
        since: now.addingTimeInterval(-11 * 60),
        now: now
    ) == "Active 11 minutes ago")
}

@Test func `customize role projection updates managed roles and preserves unrelated roles`() {
    let designRoleID = RoleID(rawValue: 1002)
    let developmentRoleID = RoleID(rawValue: 1003)
    let unrelatedRoleID = RoleID(rawValue: 9000)
    let configuration = GuildOnboardingConfiguration(
        prompts: [
            GuildOnboardingPrompt(
                id: "roles",
                options: [
                    GuildOnboardingOption(
                        id: "design", roleIDs: [designRoleID], title: "Design"
                    ),
                    GuildOnboardingOption(
                        id: "development",
                        roleIDs: [developmentRoleID],
                        title: "Development"
                    ),
                ],
                title: "Roles"
            ),
        ],
        defaultChannelIDs: [],
        selectedOptionIDs: ["development"]
    )

    #expect(configuration.projectedRoleIDs(
        currentRoleIDs: [unrelatedRoleID, designRoleID]
    ) == [unrelatedRoleID, developmentRoleID])
}

@MainActor
@Test func `functional channel preview preserves utility selection and permits acknowledgement`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let guildID = GuildID(rawValue: 100)
    model.selectGuild(guildID)
    model.openChannelsAndRoles(for: guildID)
    let channel = try #require(model.snapshot?.channels.first {
        $0.id == ChannelID(rawValue: 210)
    })

    model.openChannelsAndRolesPreview(channel)

    #expect(model.guildUtilityDestination == .channelsAndRoles(guildID))
    #expect(model.channelsAndRolesPreviewChannelID == channel.id)
    #expect(model.selectedChannelID == channel.id)
    #expect(model.readState.presentationState(channelID: channel.id)?.blocksAutomaticAcknowledgement == false)

    model.markConversationRead(channelID: channel.id)
    #expect(await eventuallyOnboarding {
        await provider.acknowledgementRequests.contains { request in
            request.channelID == channel.id
        }
    })

    var optInSettings = GuildNotificationSettings(
        guildID: guildID,
        flags: DiscordGuildSettingsFlags.optInChannelsOn,
        channelOverrides: []
    )
    model.applyNotificationSettings(optInSettings)
    #expect(model.personalizationHiddenChannelIDs(guildID: guildID).contains(channel.id))

    optInSettings.channelOverrides = [
        ChannelNotificationOverride(
            channelID: channel.id,
            flags: DiscordChannelSettingsFlags.optInEnabled
        ),
    ]
    model.applyNotificationSettings(optInSettings)
    #expect(!model.personalizationHiddenChannelIDs(guildID: guildID).contains(channel.id))

    model.closeChannelsAndRolesPreview()

    #expect(model.guildUtilityDestination == .channelsAndRoles(guildID))
    #expect(model.channelsAndRolesPreviewChannelID == nil)
    #expect(model.selectedChannelID == nil)
}

@MainActor
@Test func `category opt in and direct channel opt out preserve unrelated flags`() async throws {
    let provider = MockChatProvider(emitsChannelOptInSettingsEvents: false)
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let guildID = GuildID(rawValue: 100)
    let categoryID = ChannelID(rawValue: 190)
    let channel = try #require(model.snapshot?.channels.first {
        $0.guildID == guildID && $0.categoryID == categoryID
    })
    var settings = GuildNotificationSettings(
        guildID: guildID,
        flags: (1 << 5) | DiscordGuildSettingsFlags.optInChannelsOn,
        channelOverrides: [
            ChannelNotificationOverride(
                channelID: channel.id,
                flags: (1 << 6) | DiscordChannelSettingsFlags.optInEnabled
                    | DiscordChannelSettingsFlags.favorited
            )
        ]
    )
    model.applyNotificationSettings(settings)
    model.openChannelsAndRoles(for: guildID)

    await model.setChannelOptIn(false, channel: channel)
    var request = try #require(await provider.channelOptInRequests.last)
    let channelFlags = try #require(request.channelFlags[channel.id])
    #expect(channelFlags & (1 << 6) != 0)
    #expect(channelFlags & DiscordChannelSettingsFlags.optInEnabled == 0)
    #expect(channelFlags & DiscordChannelSettingsFlags.favorited == 0)
    #expect(request.guildFlags == settings.flags)
    #expect(model.personalizationHiddenChannelIDs(guildID: guildID).contains(channel.id))

    settings.channelOverrides = []
    model.applyNotificationSettings(settings)
    await model.setCategoryOptIn(true, guildID: guildID, categoryID: categoryID)
    request = try #require(await provider.channelOptInRequests.last)
    #expect(request.channelFlags[categoryID] == DiscordChannelSettingsFlags.optInEnabled)
}

@MainActor
@Test func `account reset cancels a pending onboarding mutation`() async {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let guildID = GuildID(rawValue: 100)
    model.selectGuild(guildID)
    await model.loadOnboardingIfNeeded(for: guildID)

    model.updateOnboardingSelection(
        guildID: guildID,
        promptID: "mock-channel-prompt",
        optionID: "mock-forum-option",
        isSelected: true
    )
    model.resetAccountPresentationState()
    try? await Task.sleep(for: .seconds(1.2))

    #expect(await provider.onboardingResponseRequests.isEmpty)
    #expect(await provider.channelOptInRequests.isEmpty)
}

@MainActor
private func eventuallyOnboarding(
    timeout: Duration = .seconds(3),
    condition: @escaping @MainActor () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
