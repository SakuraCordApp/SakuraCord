import DiscordProtocol
import Foundation
import MessageRendering
import SakuraCordModels

nonisolated enum GuildWorkspacePage: Hashable, Sendable {
    case channelsAndRoles, guide
}

struct GuildGuideEntry {
    let identity = UUID()
    var configuration: GuildGuide?
    var profile: GuildProfile?
    var progress: GuildGuideProgress?
    var progressRevision: UInt64 = 0
    var isLoading = false
    var error: String?
    var completing: Set<ChannelID> = []
}

/// The open Guide resource side chat's messages, read forward from the
/// channel's first message. It lives only while that side chat is open.
struct GuildResourceState {
    let channelID: ChannelID
    var messages: [Message] = []
    var changedMessageIDs: Set<MessageID> = []
    var rows: [MessageRowPresentation] = []
    var revision: UInt64 = 0
    let journal = MessageRowsUpdateJournal()
    var loading = false
    var hasMore = true
    var error: String?
    var requestID = UUID()
    var refreshJournal: ConversationRefreshJournal?
    // Live events and deletions must not move the REST pagination boundary.
    var nextAfter: MessageID?
    /// A reconnect found a read in flight; read forward again once it ends.
    var revalidationPending = false

    /// Publishes rows with the journal record the native timeline applies.
    mutating func publishRows(_ newRows: [MessageRowPresentation]) {
        let oldRows = rows
        rows = newRows
        revision &+= 1
        journal.append(MessageRowsUpdateRecordBuilder.make(oldRows: oldRows, newRows: rows, revision: revision))
    }
}

extension AppModel {
    func hasGuildNavigationDestination(_ destination: GuildNavigationMention, in guildID: GuildID) -> Bool {
        guard let guild = serverRailGuildsByID[guildID], !guild.isUnavailable else { return false }
        switch destination {
        case .guide: return hasGuildGuide(in: guildID)
        case .browse: return featuresSettings.channelManagement && hasChannelsAndRoles(in: guildID)
        case .customize: return hasChannelsAndRoles(in: guildID) && hasCustomizationQuestions(in: guildID)
        }
    }

    func openGuildNavigationDestination(_ destination: GuildNavigationMention, in guildID: GuildID) {
        guard hasGuildNavigationDestination(destination, in: guildID) else { return }
        startConversationNavigation { model, account in
            if model.selectedGuildID != guildID { await model.activateGuild(guildID, account: account) }
            guard !Task.isCancelled, model.isCurrentAccountSession(account), model.selectedGuildID == guildID,
                  model.hasGuildNavigationDestination(destination, in: guildID) else { return }
            switch destination {
            case .guide: model.openGuildGuide(in: guildID)
            case .browse, .customize:
                model.openChannelsAndRoles(in: guildID)
                model.showGuildCustomizationChannels(destination == .browse)
            }
        }
    }

    var onboardingEntryGuildID: GuildID? {
        guard let guildID = selectedGuildID,
              serverRailGuildsByID[guildID]?.features.contains("GUILD_ONBOARDING") == true else { return nil }
        let member = onboardingMember(in: guildID)
        return member?.requiresOnboarding == true ? guildID : nil
    }

    var guildWorkspacePage: GuildWorkspacePage? {
        guard let guildID = selectedGuildID, onboarding.presentedGuildID == guildID else { return nil }
        if onboarding.page == .channelsAndRoles, !hasChannelsAndRoles(in: guildID) { return nil }
        return onboarding.page
    }

    func hasChannelsAndRoles(in guildID: GuildID) -> Bool {
        serverRailGuildsByID[guildID]?.features.contains("COMMUNITY") == true
            && (featuresSettings.channelManagement || hasCustomizationQuestions(in: guildID))
    }

    func hasCustomizationQuestions(in guildID: GuildID) -> Bool {
        serverRailGuildsByID[guildID]?.features.isSuperset(of: ["COMMUNITY", "GUILD_ONBOARDING_HAS_PROMPTS"]) == true
    }

    func customizationTitle(in guildID: GuildID?) -> String {
        if !featuresSettings.channelManagement { return "Roles" }
        return guildID.map { hasCustomizationQuestions(in: $0) } == true ? "Channels & Roles" : "Browse Channels"
    }

    func hasGuildGuide(in guildID: GuildID) -> Bool {
        guard let guild = serverRailGuildsByID[guildID],
              guild.features.isSuperset(of: ["COMMUNITY", "GUILD_ONBOARDING", "GUILD_SERVER_GUIDE"]) else { return false }
        // Official navigation uses membership age/action flags and resource
        // channel flags, not GUILD_SERVER_GUIDE alone (READY carries both).
        return hasPendingGuildGuideActions(in: guildID)
            || guildIDsWithResourceChannels.contains(guildID)
    }

    func hasPendingGuildGuideActions(in guildID: GuildID) -> Bool {
        guard let member = onboardingMember(in: guildID), !member.hasCompletedGuildGuide,
              let joinedAt = member.joinedAt else { return false }
        return Date.now.timeIntervalSince(joinedAt) < 7 * 24 * 60 * 60
    }

    func openGuildGuide(in guildID: GuildID) {
        guard hasGuildGuide(in: guildID) else {
            onboarding.presentedGuildID = nil
            return
        }
        closeSideConversations()
        onboarding.page = .guide
        onboarding.presentedGuildID = guildID
        suspendSelectedConversationPresentation()
        refreshGuildGuide(in: guildID)
    }

    func refreshGuildGuide(in guildID: GuildID) {
        guard !accountTransitionIsActive,
              serverRailGuildsByID[guildID]?.features.contains("GUILD_SERVER_GUIDE") == true,
              onboarding.guides[guildID]?.isLoading != true else { return }
        var entry = onboarding.guides[guildID] ?? .init()
        entry.isLoading = true
        entry.error = nil
        onboarding.guides[guildID] = entry
        let identity = entry.identity
        startAccountChildTask(account: accountSession()) { model, account in
            do {
                async let configuration = account.provider.guildGuide(in: guildID)
                async let progress = account.provider.guildGuideProgress(in: guildID)
                async let profile = try? account.provider.guildProfile(in: guildID)
                let (guide, actions, serverProfile) = try await (configuration, progress, profile)
                guard model.isCurrentAccountSession(account), !Task.isCancelled, model.onboarding.guides[guildID]?.identity == identity else { return }
                model.onboarding.guides[guildID]?.configuration = guide
                if let serverProfile { model.onboarding.guides[guildID]?.profile = serverProfile }
                var refreshed = actions
                if let current = model.onboarding.guides[guildID], current.progressRevision != entry.progressRevision {
                    // Preserve actions confirmed after this read began. A later
                    // uncontended refresh may still reflect a server-side reset.
                    refreshed.channelActions.merge(current.progress?.channelActions.filter { $0.value.completed } ?? [:]) { _, new in new }
                }
                model.onboarding.guides[guildID]?.progress = refreshed
                if case .guideResource(guildID, let channelID)? = model.sideConversations.context,
                   !guide.resourceChannels.contains(where: { $0.channelID == channelID }) {
                    model.closeSideConversations()
                }
            } catch {
                guard model.isCurrentAccountSession(account), model.onboarding.guides[guildID]?.identity == identity else { return }
                model.onboarding.guides[guildID]?.error = error.localizedDescription
            }
            guard model.isCurrentAccountSession(account), model.onboarding.guides[guildID]?.identity == identity else { return }
            model.onboarding.guides[guildID]?.isLoading = false
        }
    }

    func visitGuideTask(_ action: GuildGuideChannel, guildID: GuildID) {
        guard let channel = snapshot?.channels.first(where: { $0.id == action.channelID }),
              conversationAccess(for: channel).isReadable else {
            onboarding.guides[guildID]?.error = "This channel is no longer available to you. Refresh the guide."
            return
        }
        navigate(to: action.channelID)
        if action.actionType == 0 { confirmGuideVisit(action.channelID, guildID: guildID) }
    }

    private func confirmGuideVisit(_ channelID: ChannelID, guildID: GuildID) {
        // A successful history read confirms access before recording the visit.
        guard let identity = onboarding.guides[guildID]?.identity else { return }
        startAccountChildTask(account: accountSession()) { model, account in
            do {
                _ = try await account.provider.messages(in: channelID, before: nil, limit: 1)
                guard model.isCurrentAccountSession(account), !Task.isCancelled, model.onboarding.guides[guildID]?.identity == identity else { return }
                model.completeGuideAction(channelID, guildID: guildID, type: 0)
            } catch {
                guard model.isCurrentAccountSession(account), model.onboarding.guides[guildID]?.identity == identity else { return }
                model.onboarding.guides[guildID]?.error = error.localizedDescription
            }
        }
    }

    func receiveGuideMessage(_ message: Message) {
        guard message.author.id == currentUser?.id,
              let guildID = snapshot?.channels.first(where: { $0.id == message.channelID })?.guildID else { return }
        completeGuideAction(message.channelID, guildID: guildID, type: 1)
    }

    private func completeGuideAction(_ channelID: ChannelID, guildID: GuildID, type: Int) {
        guard hasPendingGuildGuideActions(in: guildID),
              var entry = onboarding.guides[guildID], entry.configuration?.enabled == true,
              entry.configuration?.newMemberActions.contains(where: { $0.channelID == channelID && $0.actionType == type }) == true,
              entry.progress?.isCompleted(channelID) != true,
              entry.completing.insert(channelID).inserted else { return }
        onboarding.guides[guildID] = entry
        let identity = entry.identity
        startAccountChildTask(account: accountSession()) { model, account in
            do {
                let confirmed = try await account.provider.completeGuildGuideAction(in: guildID, channelID: channelID)
                guard model.isCurrentAccountSession(account), !Task.isCancelled, model.onboarding.guides[guildID]?.identity == identity else { return }
                model.onboarding.guides[guildID]?.progressRevision &+= 1
                if var progress = model.onboarding.guides[guildID]?.progress {
                    progress.channelActions.merge(confirmed.channelActions) { _, new in new }
                    model.onboarding.guides[guildID]?.progress = progress
                } else {
                    model.onboarding.guides[guildID]?.progress = confirmed
                }
            } catch {
                guard model.isCurrentAccountSession(account), model.onboarding.guides[guildID]?.identity == identity else { return }
                if model.onboardingMember(in: guildID)?.hasCompletedGuildGuide != true {
                    model.onboarding.guides[guildID]?.error = error.localizedDescription
                }
            }
            guard model.isCurrentAccountSession(account), model.onboarding.guides[guildID]?.identity == identity else { return }
            model.onboarding.guides[guildID]?.completing.remove(channelID)
        }
    }

    func receiveGuideResourceEvent(_ event: ClientEvent) {
        guard var resource = presentedGuideResource else { return }
        switch event {
        case .messageCreated(let message) where message.channelID == resource.channelID:
            guard !resource.hasMore, !resource.messages.contains(where: { $0.id == message.id }) else { return }
            resource.messages.append(message)
            resource.changedMessageIDs.insert(message.id)
        case .messageUpdated(let message) where message.channelID == resource.channelID:
            guard let index = resource.messages.firstIndex(where: { $0.id == message.id }),
                  resource.messages[index] != message else { return }
            resource.messages[index] = message
            resource.changedMessageIDs.insert(message.id)
        case .messageDeleted(let channelID, let messageID) where channelID == resource.channelID:
            resource.messages.removeAll { $0.id == messageID }
            resource.changedMessageIDs.insert(messageID)
        default: return
        }
        resource.publishRows(MessageGrouping.resourceRows(for: resource.messages, reusing: resource.rows))
        guideResource = resource
        NotificationCenter.default.post(name: .sakuracordMessageRowsDidChange, object: self)
    }

    func openGuideResource(_ channelID: ChannelID, guildID: GuildID) {
        guard onboarding.guides[guildID]?.configuration?.resourceChannels.contains(where: { $0.channelID == channelID }) == true else { return }
        openSideConversation(.guideResource(guildID, channelID))
        guideResource = GuildResourceState(channelID: channelID)
        loadGuideResource()
    }

    /// Live messages stop at a Gateway gap. A resource that had reached its
    /// newest message reads forward from its REST boundary again; live
    /// arrivals wait until that read reaches the newest message.
    func revalidateGuideResourceAfterReconnect() {
        guard let resource = guideResource else { return }
        guard !resource.loading else {
            guideResource?.revalidationPending = true
            return
        }
        guard !resource.hasMore else { return }
        guideResource?.hasMore = true
        loadGuideResource()
    }

    func loadGuideResource() {
        guard var resource = guideResource, !resource.loading else { return }
        resource.loading = true
        resource.error = nil
        resource.requestID = UUID()
        conversationRefreshJournalRevision &+= 1
        resource.refreshJournal = ConversationRefreshJournal(revision: conversationRefreshJournalRevision)
        let requestID = resource.requestID
        let channelID = resource.channelID
        let existingIDs = Set(resource.messages.map(\.id))
        let anchor = resource.nextAfter ?? resource.messages.last?.id ?? MessageID(rawValue: channelID.rawValue)
        let requestEpoch = historyEpoch
        guideResource = resource
        startAccountChildTask(account: accountSession()) { model, account in
            do {
                let page = try await account.provider.messages(in: channelID, anchoredAt: .after(anchor), limit: 50)
                let preparedRows = await Task.detached(priority: .userInitiated) {
                    page.messages.filter { !existingIDs.contains($0.id) }.sorted { $0.id < $1.id }
                        .map(MessageGrouping.resourceRow(for:))
                }.value
                guard model.isCurrentAccountSession(account), !Task.isCancelled,
                      var current = model.guideResource,
                      current.requestID == requestID else { return }
                let retainedIDs = Set(current.messages.map(\.id)).union(current.changedMessageIDs)
                let cursor = page.messages.map(\.id).max() ?? anchor
                // A read from before a Gateway gap cannot reach the live tail.
                let isStale = requestEpoch != model.historyEpoch
                let hasMore = (page.hasMoreAfter && cursor > anchor) || isStale
                let mutations = ConversationRefreshMutations(
                    messages: current.refreshJournal?.mutationsByMessageID ?? [:],
                    updatedUsers: current.refreshJournal?.updatedUsers ?? [:]
                )
                let refreshed = Self.applyingConversationRefreshMutations(mutations, to: preparedRows.map(\.message))
                let preparedByID = Dictionary(uniqueKeysWithValues: preparedRows.map { ($0.id, $0) })
                // Keep the loaded prefix contiguous until REST reaches the live tail.
                let additions = refreshed.filter {
                    !retainedIDs.contains($0.id) && $0.id > anchor && (!hasMore || $0.id <= cursor)
                }.sorted { $0.id < $1.id }.map { incoming in
                    let message = model.pollVotePresentationPreserving(model.reactionPresentationPreserving(incoming))
                    if let row = preparedByID[message.id], row.message == message { return row }
                    return MessageGrouping.resourceRow(for: message)
                }
                current.messages += additions.map(\.message)
                current.publishRows(current.rows + additions)
                current.hasMore = hasMore
                current.nextAfter = cursor
                current.refreshJournal = nil
                current.loading = false
                let readsAgain = current.revalidationPending || isStale
                current.revalidationPending = false
                model.guideResource = current
                NotificationCenter.default.post(name: .sakuracordMessageRowsDidChange, object: model)
                if readsAgain { model.loadGuideResource() }
            } catch {
                guard model.isCurrentAccountSession(account), model.guideResource?.requestID == requestID else { return }
                model.guideResource?.loading = false
                model.guideResource?.refreshJournal = nil
                model.guideResource?.revalidationPending = false
                model.guideResource?.error = error.localizedDescription
            }
        }
    }
}
