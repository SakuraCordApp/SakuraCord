import DiscordProtocol
import Foundation
import SakuraCordModels

nonisolated enum GuildWorkspacePage: Hashable, Sendable {
    case channelsAndRoles, guide
}

struct GuildGuideEntry {
    let identity = UUID()
    var configuration: GuildGuide?
    var profile: GuildGuideProfile?
    var progress: GuildGuideProgress?
    var progressRevision: UInt64 = 0
    var isLoading = false
    var error: String?
    var completing: Set<ChannelID> = []
    var resource: GuildResourceState?
}

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
}

extension AppModel {
    var onboardingEntryGuildID: GuildID? {
        guard let guildID = selectedGuildID,
              serverRailGuildsByID[guildID]?.features.contains("GUILD_ONBOARDING") == true else { return nil }
        let member = onboardingMember(in: guildID)
        return member?.requiresOnboarding == true ? guildID : nil
    }

    var guildWorkspacePage: GuildWorkspacePage? {
        guard onboarding.presentedGuildID == selectedGuildID, selectedGuildID != nil else { return nil }
        return onboarding.page
    }

    func hasChannelsAndRoles(in guildID: GuildID) -> Bool {
        snapshot?.guilds.first { $0.id == guildID }?.features.contains("GUILD_ONBOARDING") == true
    }

    func hasGuildGuide(in guildID: GuildID) -> Bool {
        guard let guild = snapshot?.guilds.first(where: { $0.id == guildID }),
              guild.features.isSuperset(of: ["COMMUNITY", "GUILD_ONBOARDING", "GUILD_SERVER_GUIDE"]) else { return false }
        // Official navigation uses membership age/action flags and resource
        // channel flags, not GUILD_SERVER_GUIDE alone (READY carries both).
        return hasPendingGuildGuideActions(in: guildID)
            || snapshot?.channels.contains { $0.guildID == guildID && $0.flags & (1 << 7) != 0 } == true
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
        onboarding.page = .guide
        onboarding.presentedGuildID = guildID
        onboarding.guides[guildID]?.resource = nil
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
                async let profile = try? account.provider.guildGuideProfile(in: guildID)
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
                if let resource = model.onboarding.guides[guildID]?.resource,
                   !guide.resourceChannels.contains(where: { $0.channelID == resource.channelID }) {
                    model.onboarding.guides[guildID]?.resource = nil
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
        guard guildWorkspacePage == .guide, let guildID = selectedGuildID,
              var resource = onboarding.guides[guildID]?.resource else { return }
        let oldRows = resource.rows
        switch event {
        case .messageCreated(let message) where message.channelID == resource.channelID:
            guard !resource.hasMore, !resource.messages.contains(where: { $0.id == message.id }) else { return }
            resource.messages.append(message)
            resource.changedMessageIDs.insert(message.id)
        case .messageUpdated(let message) where message.channelID == resource.channelID:
            guard let index = resource.messages.firstIndex(where: { $0.id == message.id }) else { return }
            resource.messages[index] = message
            resource.changedMessageIDs.insert(message.id)
        case .messagePatched(let update) where update.channelID == resource.channelID:
            guard let index = resource.messages.firstIndex(where: { $0.id == update.messageID }) else { return }
            update.apply(to: &resource.messages[index])
            resource.changedMessageIDs.insert(update.messageID)
        case .messageDeleted(let channelID, let messageID) where channelID == resource.channelID:
            resource.messages.removeAll { $0.id == messageID }
            resource.changedMessageIDs.insert(messageID)
        default: return
        }
        let retainedRows = Dictionary(uniqueKeysWithValues: oldRows.map { ($0.id, $0) })
        resource.rows = resource.messages.map { message in
            if let row = retainedRows[message.id], row.message == message { return row }
            return MessageRowPresentation(message: message, startsGroup: false, startsDay: false,
                                          replyPreview: nil, isReplyAvailable: false, isResource: true)
        }
        resource.revision &+= 1
        resource.journal.append(MessageRowsUpdateRecordBuilder.make(oldRows: oldRows, newRows: resource.rows, revision: resource.revision))
        onboarding.guides[guildID]?.resource = resource
        NotificationCenter.default.post(name: .sakuracordMessageRowsDidChange, object: self)
    }

    func openGuideResource(_ channelID: ChannelID, guildID: GuildID) {
        guard onboarding.guides[guildID]?.configuration?.resourceChannels.contains(where: { $0.channelID == channelID }) == true else { return }
        onboarding.guides[guildID]?.resource = GuildResourceState(channelID: channelID)
        loadGuideResource(guildID: guildID)
    }

    func loadGuideResource(guildID: GuildID) {
        guard var resource = onboarding.guides[guildID]?.resource, !resource.loading else { return }
        resource.loading = true
        resource.error = nil
        resource.requestID = UUID()
        let requestID = resource.requestID
        let channelID = resource.channelID
        let existingIDs = Set(resource.messages.map(\.id))
        let anchor = resource.messages.last?.id ?? MessageID(rawValue: channelID.rawValue)
        onboarding.guides[guildID]?.resource = resource
        startAccountChildTask(account: accountSession()) { model, account in
            do {
                let page = try await account.provider.messages(in: channelID, anchoredAt: .after(anchor), limit: 50)
                let preparedRows = await Task.detached(priority: .userInitiated) {
                    page.messages.filter { !existingIDs.contains($0.id) }.sorted { $0.id < $1.id }.map {
                        MessageRowPresentation(message: $0, startsGroup: false, startsDay: false,
                                               replyPreview: nil, isReplyAvailable: false, isResource: true)
                    }
                }.value
                guard model.isCurrentAccountSession(account), !Task.isCancelled,
                      var current = model.onboarding.guides[guildID]?.resource,
                      current.requestID == requestID else { return }
                let oldRows = current.rows
                let retainedIDs = Set(current.messages.map(\.id)).union(current.changedMessageIDs)
                let additions = preparedRows.filter { !retainedIDs.contains($0.id) }
                current.messages += additions.map(\.message)
                current.rows += additions
                current.revision &+= 1
                current.journal.append(MessageRowsUpdateRecordBuilder.make(oldRows: oldRows, newRows: current.rows, revision: current.revision))
                current.hasMore = page.hasMoreAfter && !preparedRows.isEmpty
                current.loading = false
                model.onboarding.guides[guildID]?.resource = current
                NotificationCenter.default.post(name: .sakuracordMessageRowsDidChange, object: model)
            } catch {
                guard model.isCurrentAccountSession(account), model.onboarding.guides[guildID]?.resource?.requestID == requestID else { return }
                model.onboarding.guides[guildID]?.resource?.loading = false
                model.onboarding.guides[guildID]?.resource?.error = error.localizedDescription
            }
        }
    }
}
