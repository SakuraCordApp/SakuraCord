import DiscordProtocol
import Foundation
import SakuraCordModels

struct GuildOnboardingPresentation: Identifiable, Equatable {
    let guildID: GuildID
    let guildName: String
    let configuration: GuildOnboardingConfiguration
    let isSubmitting: Bool
    let isWaitingForConfirmation: Bool
    let errorMessage: String?

    var id: GuildID { guildID }
}

@MainActor
extension AppModel {
    func resetOnboardingState() {
        onboardingSaveTasks.values.forEach { $0.cancel() }
        onboardingSaveTasks = [:]
        onboardingConfigurationsByGuild = [:]
        onboardingLoadingGuildIDs = []
        onboardingErrorsByGuild = [:]
        currentUserMemberFlagsByGuild = [:]
        onboardingSubmissionGuildIDs = []
        onboardingWaitingGuildIDs = []
        channelsAndRolesPreviewChannelID = nil
        guildUtilityDestination = nil
    }

    var selectedGuildSupportsOnboarding: Bool {
        guard let guildID = selectedGuildID,
              let guild = serverRailGuildsByID[guildID]
        else { return false }
        return guild.features.contains("GUILD_ONBOARDING")
    }

    var initialOnboardingPresentation: GuildOnboardingPresentation? {
        guard let guildID = selectedGuildID,
              let guild = serverRailGuildsByID[guildID],
              let configuration = onboardingConfigurationsByGuild[guildID],
              configuration.isEnabled,
              configuration.prompts.contains(where: \.isInOnboarding)
        else { return nil }
        let flags = currentUserMemberFlagsByGuild[guildID, default: 0]
        guard flags & DiscordGuildMemberFlags.startedOnboarding != 0,
              flags & DiscordGuildMemberFlags.completedOnboarding == 0
        else { return nil }
        return GuildOnboardingPresentation(
            guildID: guildID,
            guildName: guild.name,
            configuration: configuration,
            isSubmitting: onboardingSubmissionGuildIDs.contains(guildID),
            isWaitingForConfirmation: onboardingWaitingGuildIDs.contains(guildID),
            errorMessage: onboardingErrorsByGuild[guildID]
        )
    }

    func loadOnboardingIfNeeded(for guildID: GuildID?) async {
        guard let guildID,
              serverRailGuildsByID[guildID]?.features.contains("GUILD_ONBOARDING") == true,
              !onboardingLoadingGuildIDs.contains(guildID)
        else { return }
        onboardingLoadingGuildIDs.insert(guildID)
        defer { onboardingLoadingGuildIDs.remove(guildID) }
        let account = accountSession()
        do {
            let configuration = try await account.provider.onboardingConfiguration(in: guildID)
            guard isCurrentAccountSession(account) else { return }
            onboardingConfigurationsByGuild[guildID] = configuration
            onboardingErrorsByGuild[guildID] = nil
        } catch {
            guard isCurrentAccountSession(account) else { return }
            onboardingErrorsByGuild[guildID] = error.localizedDescription
        }
    }

    func openChannelsAndRoles(for guildID: GuildID) {
        channelsAndRolesPreviewChannelID = nil
        guildUtilityDestination = .channelsAndRoles(guildID)
        selectedChannelID = nil
        Task { await loadOnboardingIfNeeded(for: guildID) }
    }

    func dismissChannelsAndRoles() {
        channelsAndRolesPreviewChannelID = nil
        guildUtilityDestination = nil
        if let guildID = selectedGuildID {
            selectedChannelID = Self.preferredInitialChannelID(
                in: visibleChannels.filter { $0.guildID == guildID }
            )
        }
    }

    func openChannelsAndRolesPreview(_ channel: Channel) {
        guard channel.guildID == selectedGuildID,
              channel.kind == .text || channel.kind == .announcement
        else { return }
        channelsAndRolesPreviewChannelID = channel.id
        selectedChannelID = channel.id
    }

    func closeChannelsAndRolesPreview() {
        guard channelsAndRolesPreviewChannelID != nil else { return }
        channelsAndRolesPreviewChannelID = nil
        selectedChannelID = nil
    }

    func updateOnboardingSelection(
        guildID: GuildID,
        promptID: String,
        optionID: String,
        isSelected: Bool,
        submitsImmediately: Bool = false
    ) {
        guard var configuration = onboardingConfigurationsByGuild[guildID],
              let prompt = configuration.prompts.first(where: { $0.id == promptID })
        else { return }
        var selections = Set(configuration.selectedOptionIDs)
        if prompt.isSingleSelect {
            selections.subtract(prompt.options.map(\.id))
        }
        if isSelected {
            selections.insert(optionID)
        } else {
            selections.remove(optionID)
        }
        configuration.selectedOptionIDs = configuration.prompts
            .flatMap(\.options).map(\.id).filter(selections.contains)
        onboardingConfigurationsByGuild[guildID] = configuration
        guard !submitsImmediately else { return }
        scheduleOnboardingSave(guildID: guildID)
    }

    func submitInitialOnboarding(guildID: GuildID) async {
        guard let configuration = onboardingConfigurationsByGuild[guildID],
              validatesRequiredOnboardingPrompts(configuration)
        else {
            onboardingErrorsByGuild[guildID] = "Choose an answer for every required question."
            return
        }
        onboardingSubmissionGuildIDs.insert(guildID)
        onboardingErrorsByGuild[guildID] = nil
        defer { onboardingSubmissionGuildIDs.remove(guildID) }
        let account = accountSession()
        let submission = onboardingSubmission(configuration)
        do {
            let response = try await account.provider.submitOnboardingResponses(
                in: guildID,
                submission: submission,
                isInitial: true
            )
            guard isCurrentAccountSession(account) else { return }
            onboardingConfigurationsByGuild[guildID] = configuration.reconcilingUserResponse(
                response,
                submission: submission,
                guildID: guildID
            )
            onboardingWaitingGuildIDs.insert(guildID)
        } catch {
            guard isCurrentAccountSession(account) else { return }
            onboardingErrorsByGuild[guildID] = error.localizedDescription
        }
    }

    func setChannelOptIn(_ isOptedIn: Bool, channel: Channel) async {
        guard let guildID = channel.guildID else { return }
        let current = onboardingGuildSettings(guildID: guildID)
        var flags = current.channelOverrides.last(where: {
            $0.channelID == channel.id
        })?.flags ?? 0
        if isOptedIn {
            flags |= DiscordChannelSettingsFlags.optInEnabled
        } else {
            flags &= ~DiscordChannelSettingsFlags.optInEnabled
            flags &= ~DiscordChannelSettingsFlags.favorited
        }
        let account = accountSession()
        do {
            try await account.provider.updateChannelOptIns(
                in: guildID,
                channelFlags: [channel.id: flags],
                guildFlags: current.flags
            )
            guard isCurrentAccountSession(account) else { return }
            applyAcceptedChannelOptIns(
                guildID: guildID,
                channelFlags: [channel.id: flags],
                guildFlags: current.flags
            )
        } catch {
            guard isCurrentAccountSession(account) else { return }
            onboardingErrorsByGuild[guildID] = error.localizedDescription
        }
    }

    func isChannelOptedIn(_ channel: Channel) -> Bool {
        guard let guildID = channel.guildID else { return true }
        let settings = onboardingGuildSettings(guildID: guildID)
        guard settings.usesOptInChannelList else { return true }
        let overrides = settings.channelOverrides
        if overrides.last(where: { $0.channelID == channel.id })?.isOptedIn == true {
            return true
        }
        return channel.categoryID.map { categoryID in
            overrides.last(where: { $0.channelID == categoryID })?.isOptedIn == true
        } ?? false
    }

    func isChannelDirectlyOptedIn(_ channel: Channel) -> Bool {
        guard let guildID = channel.guildID else { return true }
        let settings = onboardingGuildSettings(guildID: guildID)
        guard settings.usesOptInChannelList else { return true }
        return settings.channelOverrides.last(where: {
            $0.channelID == channel.id
        })?.isOptedIn == true
    }

    func isChannelInheritedFromOptedInCategory(_ channel: Channel) -> Bool {
        guard !isChannelDirectlyOptedIn(channel),
              let guildID = channel.guildID,
              onboardingGuildSettings(guildID: guildID).usesOptInChannelList,
              let categoryID = channel.categoryID
        else { return false }
        return onboardingGuildSettings(guildID: guildID).channelOverrides.last(where: {
            $0.channelID == categoryID
        })?.isOptedIn == true
    }

    func isCategoryOptedIn(guildID: GuildID, categoryID: ChannelID) -> Bool {
        let settings = onboardingGuildSettings(guildID: guildID)
        guard settings.usesOptInChannelList else { return true }
        return settings.channelOverrides.last(where: {
            $0.channelID == categoryID
        })?.isOptedIn == true
    }

    func setCategoryOptIn(
        _ isOptedIn: Bool,
        guildID: GuildID,
        categoryID: ChannelID
    ) async {
        let current = onboardingGuildSettings(guildID: guildID)
        var flags = current.channelOverrides.last(where: {
            $0.channelID == categoryID
        })?.flags ?? 0
        if isOptedIn {
            flags |= DiscordChannelSettingsFlags.optInEnabled
        } else {
            flags &= ~DiscordChannelSettingsFlags.optInEnabled
            flags &= ~DiscordChannelSettingsFlags.favorited
        }
        let account = accountSession()
        do {
            try await account.provider.updateChannelOptIns(
                in: guildID,
                channelFlags: [categoryID: flags],
                guildFlags: current.flags
            )
            guard isCurrentAccountSession(account) else { return }
            applyAcceptedChannelOptIns(
                guildID: guildID,
                channelFlags: [categoryID: flags],
                guildFlags: current.flags
            )
        } catch {
            guard isCurrentAccountSession(account) else { return }
            onboardingErrorsByGuild[guildID] = error.localizedDescription
        }
    }

    func personalizationHiddenChannelIDs(guildID: GuildID) -> Set<ChannelID> {
        Set(visibleChannels.compactMap { channel in
            let isSelectedOutsidePreview = selectedChannelID == channel.id
                && channelsAndRolesPreviewChannelID != channel.id
            guard channel.guildID == guildID,
                  conversationAccess(for: channel) != .hidden,
                  !isChannelOptedIn(channel),
                  channel.mentionCount == 0,
                  !isSelectedOutsidePreview
            else { return nil }
            return channel.id
        })
    }

    func suppressesOrdinaryNotificationsForPersonalization(channelID: ChannelID) -> Bool {
        guard let channel = snapshot?.channels.first(where: { $0.id == channelID }),
              let guildID = channel.guildID,
              onboardingGuildSettings(guildID: guildID).usesOptInChannelList
        else { return false }
        return !isChannelOptedIn(channel)
    }

    func accessibleChannelsForBrowse(guildID: GuildID) -> [Channel] {
        visibleChannels.filter {
            $0.guildID == guildID && conversationAccess(for: $0) != .hidden
        }
    }

    private func scheduleOnboardingSave(guildID: GuildID) {
        onboardingSaveTasks[guildID]?.cancel()
        let account = accountSession()
        onboardingSaveTasks[guildID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self,
                  isCurrentAccountSession(account),
                  let configuration = onboardingConfigurationsByGuild[guildID]
            else { return }
            let submission = onboardingSubmission(configuration)
            do {
                let response = try await account.provider.submitOnboardingResponses(
                    in: guildID,
                    submission: submission,
                    isInitial: false
                )
                guard !Task.isCancelled, isCurrentAccountSession(account) else { return }
                let reconciled = configuration.reconcilingUserResponse(
                    response,
                    submission: submission,
                    guildID: guildID
                )
                onboardingConfigurationsByGuild[guildID] = reconciled
                try await enableExistingMemberOptInsIfNeeded(
                    guildID: guildID,
                    configuration: reconciled,
                    account: account
                )
                onboardingErrorsByGuild[guildID] = nil
            } catch {
                guard !Task.isCancelled, isCurrentAccountSession(account) else { return }
                onboardingErrorsByGuild[guildID] = error.localizedDescription
            }
        }
    }

    private func onboardingGuildSettings(guildID: GuildID) -> GuildNotificationSettings {
        snapshot?.notificationSettings.last(where: { $0.guildID == guildID })
            ?? GuildNotificationSettings(guildID: guildID)
    }

    private func enableExistingMemberOptInsIfNeeded(
        guildID: GuildID,
        configuration: GuildOnboardingConfiguration,
        account: AppModelAccountSession
    ) async throws {
        let current = onboardingGuildSettings(guildID: guildID)
        guard !current.usesOptInChannelList else { return }
        let selected = Set(configuration.selectedOptionIDs)
        let channelIDs = Set(configuration.defaultChannelIDs).union(
            configuration.prompts.flatMap(\.options).filter {
                selected.contains($0.id)
            }.flatMap(\.channelIDs)
        )
        guard !channelIDs.isEmpty else { return }
        let existingFlags = Dictionary(
            uniqueKeysWithValues: current.channelOverrides.map {
                ($0.channelID, $0.flags)
            }
        )
        let flags = Dictionary(uniqueKeysWithValues: channelIDs.map { channelID in
            (channelID, existingFlags[channelID, default: 0]
                | DiscordChannelSettingsFlags.optInEnabled)
        })
        try await account.provider.updateChannelOptIns(
            in: guildID,
            channelFlags: flags,
            guildFlags: current.flags
        )
        guard isCurrentAccountSession(account) else { return }
        applyAcceptedChannelOptIns(
            guildID: guildID,
            channelFlags: flags,
            guildFlags: current.flags
        )
    }

    private func applyAcceptedChannelOptIns(
        guildID: GuildID,
        channelFlags: [ChannelID: UInt64],
        guildFlags: UInt64?
    ) {
        var settings = onboardingGuildSettings(guildID: guildID)
        if let guildFlags {
            settings.flags =
                (guildFlags | DiscordGuildSettingsFlags.optInChannelsOn)
                    & ~DiscordGuildSettingsFlags.optInChannelsOff
        }
        for (channelID, flags) in channelFlags {
            if let index = settings.channelOverrides.lastIndex(where: {
                $0.channelID == channelID
            }) {
                settings.channelOverrides[index].flags = flags
            } else {
                settings.channelOverrides.append(
                    ChannelNotificationOverride(channelID: channelID, flags: flags)
                )
            }
        }
        applyNotificationSettings(settings)
    }

    private func onboardingSubmission(
        _ configuration: GuildOnboardingConfiguration
    ) -> GuildOnboardingResponseSubmission {
        GuildOnboardingResponseSubmission.completeSnapshot(
            configuration: configuration,
            selectedOptionIDs: configuration.selectedOptionIDs,
            timestampMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
        )
    }

    private func validatesRequiredOnboardingPrompts(
        _ configuration: GuildOnboardingConfiguration
    ) -> Bool {
        let selected = Set(configuration.selectedOptionIDs)
        return configuration.prompts.filter {
            $0.isInOnboarding && $0.isRequired
        }.allSatisfy { prompt in
            prompt.options.contains { selected.contains($0.id) }
        }
    }
}
