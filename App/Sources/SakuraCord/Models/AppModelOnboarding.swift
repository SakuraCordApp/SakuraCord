import DiscordProtocol
import Foundation
import Observation
import SakuraCordModels

@Observable
final class GuildOnboardingStore {
    struct Entry {
        var configuration: GuildOnboarding?
        var responses: Set<String> = []
        var promptID: String?
        var initial = false
        var refreshedAt: Date?
        var isLoading = false
        var isSaving = false
        var isSynchronizing = false
        var needsRefresh = false
        var error: String?
        var notice: String?
        var revision = UUID()
        var editRevision = UUID()
    }

    var entries: [GuildID: Entry] = [:]
    var members: [GuildID: Member] = [:]
    var presentedGuildID: GuildID?
    var previewChannelID: ChannelID?
    var previewReturnChannelID: ChannelID?
    var profiles: [GuildID: UserProfile] = [:]
    var browsingChannels = false
    var channelSearch = ""
    var isChannelSearchFocused = false
    var page: GuildWorkspacePage = .channelsAndRoles
    var guides: [GuildID: GuildGuideEntry] = [:]
    var channelSelections: [GuildID: GuildChannelSelectionMutation] = [:]
    @ObservationIgnored var customizationDebounce: @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }

    func reset() {
        entries = [:]
        members = [:]
        guides = [:]
        presentedGuildID = nil
        previewChannelID = nil
        previewReturnChannelID = nil
        profiles = [:]
        browsingChannels = false
        channelSearch = ""
        isChannelSearchFocused = false
        channelSelections = [:]
    }
}

extension AppModel {
    nonisolated static func resolveConversationAccess(
        for channel: Channel,
        permissionBasis: ConversationPermissionBasis?
    ) -> ConversationAccess {
        guard channel.guildID != nil else {
            return .readable(canSend: !channel.isOfficialSystemDirectMessage)
        }
        guard let permissionBasis, permissionBasis.currentUserOnboardingIsKnown else { return .checking }
        let permissions = ConversationPermissionResolver.effectivePermissions(
            guild: permissionBasis.guild,
            channel: channel,
            resolvedBasePermissions: permissionBasis.resolvedBasePermissions,
            overwritePrincipals: permissionBasis.overwritePrincipals,
            hasCurrentRoleIdentity: permissionBasis.hasCurrentRoleIdentity
        )
        if permissionBasis.currentUserIsPending || permissionBasis.currentUserRequiresOnboarding {
            let access = ConversationPermissionResolver.channelAccess(effectivePermissions: permissions)
            return access.isReadable ? .readable(canSend: false) : access
        }
        if channel.kind == .voice {
            return ConversationPermissionResolver.voiceChannelAccess(
                effectivePermissions: permissions
            )
        }
        return ConversationPermissionResolver.channelAccess(effectivePermissions: permissions)
    }

    func onboardingMember(in guildID: GuildID) -> Member? {
        onboarding.members[guildID] ?? currentUser.flatMap { membersByGuildID[guildID]?[$0.id] }
    }

    func requiresOnboarding(in guildID: GuildID) -> Bool {
        serverRailGuildsByID[guildID]?.features.contains("GUILD_ONBOARDING") == true
            && onboardingMember(in: guildID)?.requiresOnboarding == true
    }

    func openChannelsAndRoles(in guildID: GuildID) {
        closeCustomizationPreview()
        closeThread()
        closeVoiceChat()
        onboarding.browsingChannels = false
        onboarding.channelSearch = ""
        onboarding.isChannelSearchFocused = false
        onboarding.page = .channelsAndRoles
        if onboarding.entries[guildID] == nil { onboarding.entries[guildID] = .init() }
        onboarding.presentedGuildID = guildID
        onboarding.previewChannelID = nil
        suspendSelectedConversationPresentation()
        if hasCustomizationQuestions(in: guildID) || requiresOnboarding(in: guildID) { refreshOnboarding(in: guildID) }
    }

    func refreshSelectedGuildOnboarding(force: Bool = false) {
        guard let guildID = selectedGuildID, let guild = serverRailGuildsByID[guildID] else { return }
        if guild.features.contains("GUILD_ONBOARDING") || guild.features.contains("GUILD_ONBOARDING_HAS_PROMPTS") {
            let entry = onboarding.entries[guildID]
            if force || entry?.needsRefresh == true || entry?.refreshedAt.map({ Date.now.timeIntervalSince($0) >= 30 }) != false {
                refreshOnboarding(in: guildID)
            }
        }
        refreshGuildGuide(in: guildID)
    }

    func refreshOnboarding(in guildID: GuildID) {
        guard !accountTransitionIsActive, let guild = serverRailGuildsByID[guildID], !guild.isUnavailable,
              onboarding.entries[guildID]?.isLoading != true,
              onboarding.entries[guildID]?.isSaving != true else { return }
        let store = onboarding
        var entry = store.entries[guildID] ?? .init()
        entry.revision = UUID()
        entry.isLoading = true
        entry.error = nil
        let revision = entry.revision
        store.entries[guildID] = entry
        startAccountChildTask(account: accountSession()) { model, account in
            do {
                async let configuration = account.provider.guildOnboarding(in: guildID)
                async let member = account.provider.refreshCurrentMember(in: guildID)
                let (value, confirmedMember) = try await (configuration, member)
                guard model.isCurrentAccountSession(account), !Task.isCancelled,
                      store.entries[guildID]?.revision == revision else { return }
                let initial = confirmedMember.requiresOnboarding && guild.features.contains("GUILD_ONBOARDING")
                if !initial, let current = store.entries[guildID],
                   current.editRevision != entry.editRevision || current.isSaving {
                    store.entries[guildID]?.isLoading = false
                    store.entries[guildID]?.refreshedAt = .now
                    model.receiveOnboardingMember(confirmedMember, guildID: guildID)
                    return
                }
                var next = GuildOnboardingStore.Entry()
                next.configuration = value
                next.refreshedAt = .now
                next.initial = initial
                next.responses = value.validResponses(Set(value.responses), initial: initial)
                if initial, let current = store.entries[guildID], current.initial,
                   model.onboardingMember(in: guildID)?.joinedAt == confirmedMember.joinedAt,
                   Set(current.configuration?.responses ?? []) == Set(value.responses) {
                    next.responses = value.validResponses(current.responses, initial: true)
                    next.promptID = current.promptID
                    if next.responses != current.responses { next.notice = "Some options were removed. Review your answers before continuing." }
                }
                let questions = value.questions(initial: initial)
                if next.promptID != nil, !questions.contains(where: { $0.id == next.promptID }) {
                    next.promptID = questions.first?.id
                }
                model.receiveOnboardingMember(confirmedMember, guildID: guildID)
                store.entries[guildID] = next
            } catch {
                guard model.isCurrentAccountSession(account), store.entries[guildID]?.revision == revision else { return }
                store.entries[guildID]?.isLoading = false
                store.entries[guildID]?.needsRefresh = true
                store.entries[guildID]?.error = error.localizedDescription
            }
        }
    }

    func receiveOnboardingMember(_ member: Member, guildID: GuildID) {
        guard member.id == currentUser?.id else { return }
        let old = onboarding.members[guildID]
        var member = member
        member.flags = member.flags ?? old?.flags
        member.isPending = member.isPending ?? old?.isPending
        member.joinedAt = member.joinedAt ?? old?.joinedAt
        onboarding.members[guildID] = member
        // Flags can arrive without a role change. Rebuild the same projection
        // that owns sidebar locks and resumes an initial history load waiting
        // for access; publishing the member alone leaves both stale.
        if old?.flags != member.flags || old?.isPending != member.isPending {
            refreshUnreadPresentation(appliesAccessImmediately: true, accessAffectedGuildIDs: [guildID])
        }
        if let old, old.roles != member.roles, onboarding.presentedGuildID == guildID {
            startAccountChildTask(account: accountSession()) { model, _ in
                await model.synchronizeGuildCustomization(in: guildID)
            }
        }
        if let old, old.requiresOnboarding != member.requiresOnboarding,
           onboarding.entries[guildID]?.isSaving != true,
           onboarding.entries[guildID]?.isLoading != true,
           onboarding.presentedGuildID == guildID {
            refreshOnboarding(in: guildID)
        }
    }

    func selectOnboardingOption(_ option: GuildOnboardingOption, prompt: GuildOnboardingPrompt, guildID: GuildID) {
        let responses = onboarding.entries[guildID]?.responses ?? []
        var selected = responses.intersection(prompt.options.map(\.id))
        if selected.contains(option.id) { selected.remove(option.id) } else {
            if prompt.singleSelect { selected.removeAll() }
            selected.insert(option.id)
        }
        setOnboardingOptions(selected, prompt: prompt, guildID: guildID)
    }

    func setOnboardingOptions(_ selected: Set<String>, prompt: GuildOnboardingPrompt, guildID: GuildID) {
        guard var entry = onboarding.entries[guildID], entry.configuration != nil, !(entry.initial && entry.isSaving), !entry.needsRefresh,
              let currentPrompt = entry.configuration?.prompts.first(where: { $0.id == prompt.id }) else { return }
        let optionIDs = Set(currentPrompt.options.map(\.id))
        let selected = selected.intersection(optionIDs)
        guard !currentPrompt.singleSelect || selected.count <= 1,
              entry.initial || !currentPrompt.required || !selected.isEmpty else { return }
        let responses = entry.responses.subtracting(optionIDs).union(selected)
        guard responses != entry.responses else { return }
        entry.responses = responses
        entry.error = nil
        entry.editRevision = UUID()
        onboarding.entries[guildID] = entry
        if !entry.initial {
            scheduleOnboardingAnswers(in: guildID)
        }
    }

    func setOnboardingPrompt(_ promptID: String, guildID: GuildID) {
        onboarding.entries[guildID]?.promptID = promptID
    }

    func saveOnboarding(in guildID: GuildID) {
        let store = onboarding
        guard let entry = store.entries[guildID], let configuration = entry.configuration,
              !entry.isLoading, !entry.isSaving, !entry.needsRefresh else { return }
        if let error = configuration.validationError(entry.responses, initial: entry.initial) {
            store.entries[guildID]?.error = error
            return
        }
        store.entries[guildID]?.isSaving = true
        store.entries[guildID]?.error = nil
        startAccountChildTask(account: accountSession()) { model, account in
            do {
                let saved = try await account.provider.saveGuildOnboarding(in: guildID, responses: entry.responses, initial: entry.initial)
                guard model.isCurrentAccountSession(account), !Task.isCancelled, store.entries[guildID]?.revision == entry.revision else { return }
                if entry.initial {
                    // Reconcile the provider's confirmed membership into the app
                    // even if its member event has not reached the UI yet.
                    let member = try await account.provider.refreshCurrentMember(in: guildID)
                    guard model.isCurrentAccountSession(account), store.entries[guildID]?.revision == entry.revision else { return }
                    guard member.flags.map({ $0 & 2 != 0 }) == true else {
                        throw ChatProviderError.invalidRequest("Discord has not confirmed onboarding completion. Refresh to continue.")
                    }
                    model.receiveOnboardingMember(member, guildID: guildID)
                }
                store.entries[guildID]?.configuration = saved
                store.entries[guildID]?.responses = Set(saved.responses)
                store.entries[guildID]?.isSaving = false
                store.entries[guildID]?.initial = false
                if entry.initial { model.openGuildGuide(in: guildID) }
            } catch {
                guard model.isCurrentAccountSession(account), store.entries[guildID]?.revision == entry.revision else { return }
                store.entries[guildID]?.isSaving = false
                store.entries[guildID]?.needsRefresh = true
                if case ChatProviderError.invalidRequest = error {
                    store.entries[guildID]?.error = error.localizedDescription
                } else {
                    store.entries[guildID]?.error = "\(error.localizedDescription) Refresh to check what Discord saved before trying again."
                }
            }
        }
    }

    func allowOnboardingSubmission(in channelID: ChannelID) -> Bool {
        let parentID = snapshot?.threads.first { $0.id == channelID }?.parentID
            ?? snapshot?.activeJoinedThreads.first { $0.id == channelID }?.parentID
            ?? (openThread?.id == channelID ? openThread?.parentID : nil)
            ?? channelID
        let channel = snapshot?.channels.first { $0.id == parentID }
            ?? visibleChannels.first { $0.id == parentID }
        guard let guildID = channel?.guildID else { return true }
        if requiresOnboarding(in: guildID) || (serverRailGuildsByID[guildID]?.features.contains("GUILD_ONBOARDING") == true && onboardingMember(in: guildID)?.flags == nil) {
            openChannelsAndRoles(in: guildID)
            return false
        }
        return onboardingMember(in: guildID)?.isPending != true
    }

    func reconcileSelectedOnboardingChannel() {
        guard featuresSettings.channelManagement, guildWorkspacePage == nil, let guildID = selectedGuildID,
              let channelID = selectedChannelID else { return }
        let groups = ChannelGroup.make(from: visibleChannels)
        let channels = selectedChannelGroups(groups, guildID: guildID).flatMap(\.channels)
        guard !channels.contains(where: { $0.id == channelID }) else { return }
        if let next = channels.first(where: { conversationAccess(for: $0).isReadable }) { navigate(to: next.id) } else { selectedChannelID = nil }
    }

    func selectedChannelGroups(_ groups: [ChannelGroup], guildID: GuildID?) -> [ChannelGroup] {
        guard let guildID else { return groups }
        let guide = onboarding.guides[guildID]?.configuration
        let resources = guide?.enabled == true ? Set(guide?.resourceChannels.map(\.channelID) ?? []) : []
        let settings = presentedGuildChannelSettings(in: guildID)
        // `showsAllChannels` re-derives the same settings struct; read the one
        // flag it needs from the copy already taken instead of building a second.
        let filtersSelection = featuresSettings.channelManagement
            && hasChannelsAndRoles(in: guildID)
            && settings.flags & GuildChannelSelection.enabledFlag != 0
        // `hasGuildGuide` scans every channel in the snapshot, and
        // `GuildChannelSelection.isSelected` linearly scans the guild's
        // overrides. Both are independent of the channel being filtered, so
        // resolve them once here instead of once per channel.
        let hasGuide = filtersSelection && hasGuildGuide(in: guildID)
        let selectedChannelIDs = Set(
            settings.channelOverrides
                .filter { $0.flags & GuildChannelSelection.selectedFlag != 0 }
                .map(\.channelID)
        )
        let activeChannelID = guildWorkspacePage == nil ? selectedChannelID : nil
        return groups.compactMap { group -> ChannelGroup? in
            var group = group
            let categoryIsSelected = group.categoryID.map { selectedChannelIDs.contains($0) } ?? false
            group.channels.removeAll { channel in
                guard filtersSelection else { return false }
                if hasGuide, resources.contains(channel.id) || channel.flags & (1 << 7) != 0,
                   channel.id != activeChannelID { return true }
                guard !selectedChannelIDs.contains(channel.id),
                      !categoryIsSelected,
                      channel.id != activeVoiceChannel?.id, channel.id != activeChannelID,
                      channel.mentionCount == 0 else { return false }
                return true
            }
            return group.channels.isEmpty ? nil : group
        }
    }
}
