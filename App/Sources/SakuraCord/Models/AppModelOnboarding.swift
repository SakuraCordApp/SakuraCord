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
    // Member events can precede initial bootstrap publication, when the app
    // does not yet know which user is self. Retain only each member's latest
    // value until that identity is available.
    @ObservationIgnored var bootstrapMembers: [GuildID: [UserID: Member]] = [:]
    @ObservationIgnored var timeoutExpiryTasks: [GuildID: Task<Void, Never>] = [:]
    @ObservationIgnored var timeoutRevisions: [GuildID: UInt64] = [:]
    var presentedGuildID: GuildID?
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
        bootstrapMembers = [:]
        for task in timeoutExpiryTasks.values { task.cancel() }
        timeoutExpiryTasks = [:]
        timeoutRevisions = [:]
        guides = [:]
        presentedGuildID = nil
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
            hasCurrentRoleIdentity: permissionBasis.hasCurrentRoleIdentity,
            communicationDisabledUntil: permissionBasis.currentUserCommunicationDisabledUntil
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
        onboarding.members[guildID] ?? currentUser.flatMap {
            membersByGuildID[guildID]?[$0.id] ?? (guildID == selectedGuildID ? membersByID[$0.id] : nil)
        }
    }

    func requiresOnboarding(in guildID: GuildID) -> Bool {
        serverRailGuildsByID[guildID]?.features.contains("GUILD_ONBOARDING") == true
            && onboardingMember(in: guildID)?.requiresOnboarding == true
    }

    func openChannelsAndRoles(in guildID: GuildID) {
        closeSideConversations()
        onboarding.browsingChannels = false
        onboarding.channelSearch = ""
        onboarding.isChannelSearchFocused = false
        onboarding.page = .channelsAndRoles
        if onboarding.entries[guildID] == nil { onboarding.entries[guildID] = .init() }
        onboarding.presentedGuildID = guildID
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
                let timeoutRevision = store.timeoutRevisions[guildID, default: 0]
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
                    model.receiveOnboardingMember(confirmedMember, guildID: guildID, timeoutRevision: timeoutRevision)
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
                model.receiveOnboardingMember(confirmedMember, guildID: guildID, timeoutRevision: timeoutRevision)
                store.entries[guildID] = next
            } catch {
                guard model.isCurrentAccountSession(account), store.entries[guildID]?.revision == revision else { return }
                store.entries[guildID]?.isLoading = false
                store.entries[guildID]?.needsRefresh = true
                store.entries[guildID]?.error = error.localizedDescription
            }
        }
    }

    func receiveOnboardingMember(_ member: Member, guildID: GuildID, timeoutRevision: UInt64? = nil) {
        guard let currentUserID = currentUser?.id else {
            onboarding.bootstrapMembers[guildID, default: [:]][member.id] = member
            return
        }
        guard member.id == currentUserID else { return }
        let old = onboarding.members[guildID]
        var member = member
        if let timeoutRevision, onboarding.timeoutRevisions[guildID, default: 0] != timeoutRevision {
            // A member read can wait behind unrelated onboarding configuration
            // work while a live timeout update or local expiry overtakes it.
            member.communicationDisabledUntil = old?.communicationDisabledUntil
        }
        member.flags = member.flags ?? old?.flags
        member.isPending = member.isPending ?? old?.isPending
        member.joinedAt = member.joinedAt ?? old?.joinedAt
        onboarding.members[guildID] = member
        onboarding.timeoutRevisions[guildID, default: 0] &+= 1
        if old?.communicationDisabledUntil != member.communicationDisabledUntil {
            scheduleGuildTimeoutExpiry(in: guildID)
            timelinePresentationRevision &+= 1
            forwardSearchSourceRevision &+= 1
        }
        // Flags can arrive without a role change. Rebuild the same projection
        // that owns sidebar locks and resumes an initial history load waiting
        // for access; publishing the member alone leaves both stale.
        if old?.flags != member.flags || old?.isPending != member.isPending
            || old?.communicationDisabledUntil != member.communicationDisabledUntil {
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
                    let timeoutRevision = store.timeoutRevisions[guildID, default: 0]
                    let member = try await account.provider.refreshCurrentMember(in: guildID)
                    guard model.isCurrentAccountSession(account), store.entries[guildID]?.revision == entry.revision else { return }
                    guard member.flags.map({ $0 & 2 != 0 }) == true else {
                        throw ChatProviderError.invalidRequest("Discord has not confirmed onboarding completion. Refresh to continue.")
                    }
                    model.receiveOnboardingMember(member, guildID: guildID, timeoutRevision: timeoutRevision)
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

    func selectedChannelGroups(
        _ groups: [ChannelGroup],
        guildID: GuildID?,
        threadsByParentID: [ChannelID: [SidebarThreadRow]]? = nil
    ) -> [ChannelGroup] {
        let groups = channelSelectionGroups(groups, guildID: guildID)
        guard let guildID, presentedGuildChannelSettings(in: guildID).hideMutedChannels else { return groups }
        let threads = threadsByParentID
            ?? sidebarThreadLayout(guildID: guildID, channelGroups: groups, now: .now).threadsByParentID
        let activeChannelID = guildWorkspacePage == nil ? selectedChannelID : nil
        return groups.compactMap { group -> ChannelGroup? in
            var group = group
            group.channels.removeAll { channel in
                let isFocused = channel.id == activeChannelID || channel.id == activeVoiceChannel?.id
                    || (isThreadFullWidth && openThread?.parentID == channel.id)
                // Discord keeps focused channels, mentions and visible joined
                // threads discoverable. A server/category mute is not a direct
                // channel mute and must not hide all of its children here.
                return readState.isChannelMuted(channel) && !isFocused && channel.mentionCount == 0
                    && threads[channel.id, default: []].isEmpty
            }
            return group.channels.isEmpty ? nil : group
        }
    }

    func channelSelectionGroups(
        _ groups: [ChannelGroup],
        guildID: GuildID?
    ) -> [ChannelGroup] {
        guard let guildID else { return groups }
        let guide = onboarding.guides[guildID]?.configuration
        let resources = guide?.enabled == true ? Set(guide?.resourceChannels.map(\.channelID) ?? []) : []
        let settings = presentedGuildChannelSettings(in: guildID)
        let filtersSelection = !showsAllChannels(in: guildID)
        let hasGuide = filtersSelection && hasGuildGuide(in: guildID)
        let activeChannelID = guildWorkspacePage == nil ? selectedChannelID : nil
        return groups.compactMap { group -> ChannelGroup? in
            var group = group
            group.channels.removeAll { channel in
                let isFocused = channel.id == activeChannelID || channel.id == activeVoiceChannel?.id
                    || (isThreadFullWidth && openThread?.parentID == channel.id)
                if filtersSelection {
                    if hasGuide, resources.contains(channel.id) || channel.flags & (1 << 7) != 0,
                       channel.id != activeChannelID { return true }
                    if !GuildChannelSelection.isSelected(channel.id, settings: settings),
                       !(group.categoryID.map { GuildChannelSelection.isSelected($0, settings: settings) } ?? false),
                       !isFocused, channel.mentionCount == 0 { return true }
                }
                return false
            }
            return group.channels.isEmpty ? nil : group
        }
    }
}
