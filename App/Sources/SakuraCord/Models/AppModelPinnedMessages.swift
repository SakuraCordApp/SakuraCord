import DiscordProtocol
import Foundation
import Observation
import SakuraCordModels

@MainActor
@Observable
final class PinnedMessagesState {
    struct MutationIntent {
        var channelID: ChannelID
        var desired: Bool
        var generation: UInt64
    }
    var isPresented = false
    var channelID: ChannelID?
    var items: [PinnedMessage] = []
    var isLoading = false
    var isLoadingMore = false
    var hasMore = false
    var errorMessage: String?
    var hasReadPermission = true
    @ObservationIgnored var rows: [MessageRowPresentation] = []
    @ObservationIgnored var rowsRevision: UInt64 = 0
    @ObservationIgnored let rowsUpdateJournal = MessageRowsUpdateJournal()
    @ObservationIgnored var loadTask: Task<Void, Never>?
    @ObservationIgnored var loadGeneration: UInt64 = 0
    @ObservationIgnored var mutationTasks: [MessageID: Task<Void, Never>] = [:]
    @ObservationIgnored var mutationGenerations: [MessageID: UInt64] = [:]
    @ObservationIgnored var mutationIntents: [MessageID: MutationIntent] = [:]

    func replaceItems(
        _ newItems: [PinnedMessage],
        preparedRows: [MessageRowPresentation]? = nil,
        notifying notificationObject: AnyObject? = nil
    ) {
        let oldRows = rows
        let newRows = preparedRows ?? PinnedMessagePresentation.reusingRows(
            oldItems: items,
            oldRows: rows,
            for: newItems
        )
        precondition(newRows.count == newItems.count)
        items = newItems
        rows = newRows
        let nextRevision = rowsRevision &+ 1
        rowsUpdateJournal.append(MessageRowsUpdateRecordBuilder.make(
            oldRows: oldRows,
            newRows: rows,
            revision: nextRevision
        ))
        rowsRevision = nextRevision
        NotificationCenter.default.post(
            name: .sakuracordMessageRowsDidChange,
            object: notificationObject
        )
    }

    func clear(notifying notificationObject: AnyObject? = nil) {
        loadTask?.cancel()
        loadGeneration &+= 1
        loadTask = nil
        for task in mutationTasks.values { task.cancel() }
        mutationTasks = [:]
        mutationGenerations = [:]
        mutationIntents = [:]
        isPresented = false
        channelID = nil
        isLoading = false
        isLoadingMore = false
        hasMore = false
        errorMessage = nil
        hasReadPermission = true
        replaceItems([], notifying: notificationObject)
    }
}

@MainActor
extension AppModel {
    var activePinsChannelID: ChannelID? {
        if let thread = openThread { return thread.id }
        guard selectedChannelSupportsPins else { return nil }
        return selectedChannelID
    }

    var selectedChannelSupportsPins: Bool {
        guard let channel = selectedChannel else { return false }
        return switch channel.kind {
        case .text, .announcement, .voice, .directMessage, .groupDirectMessage:
            true
        case .forum, .unknown:
            false
        }
    }

    var canManageSelectedChannelPins: Bool {
        guard let selectedChannelID else { return false }
        return canManagePins(in: selectedChannelID)
    }

    var canManageActiveConversationPins: Bool {
        guard let channelID = activePinsChannelID else { return false }
        return canManagePins(in: channelID)
    }

    func canManagePins(for message: Message) -> Bool {
        return canManagePins(in: message.channelID)
    }

    private func canManagePins(in channelID: ChannelID) -> Bool {
        guard let context = pinPermissionContext(for: channelID) else { return false }
        let channel = context.channel
        if channel.guildID == nil {
            return !channel.isOfficialSystemDirectMessage
        }
        guard context.isThread || selectedChannelSupportsPins(channel) else {
            return false
        }
        return effectivePinPermissions(in: channel).map { permissions in
            permissions & DiscordPermissionBits.viewChannel != 0
                && permissions & DiscordPermissionBits.readMessageHistory != 0
                && permissions & DiscordPermissionBits.pinMessages != 0
        } ?? false
    }

    private func pinPermissionContext(
        for channelID: ChannelID
    ) -> (channel: Channel, isThread: Bool)? {
        if let channel = rootPinChannel(channelID) {
            return (channel, false)
        }
        if openThread?.id == channelID, let selectedChannel {
            return (selectedChannel, true)
        }
        let parentID = snapshot?.threads.first(where: { $0.id == channelID })?.parentID
            ?? snapshot?.activeJoinedThreads.first(where: { $0.id == channelID })?.parentID
            ?? messageSearch.page?.channels.first(where: { $0.id == channelID })?.categoryID
        guard let parentID, let parent = rootPinChannel(parentID) else { return nil }
        return (parent, true)
    }

    private func rootPinChannel(_ channelID: ChannelID) -> Channel? {
        snapshot?.channels.first(where: { $0.id == channelID })
            ?? visibleChannels.first(where: { $0.id == channelID })
    }

    private func selectedChannelSupportsPins(_ channel: Channel) -> Bool {
        switch channel.kind {
        case .text, .announcement, .voice, .directMessage, .groupDirectMessage:
            true
        case .forum, .unknown:
            false
        }
    }

    private func effectivePinPermissions(in channel: Channel) -> UInt64? {
        guard let guildID = channel.guildID,
              let basis = conversationPermissionBasis(for: guildID)
        else { return channel.guildID == nil ? .max : nil }
        return ConversationPermissionResolver.effectivePermissions(
            guild: basis.guild,
            channel: channel,
            resolvedBasePermissions: basis.resolvedBasePermissions,
            overwritePrincipals: basis.overwritePrincipals,
            hasCurrentRoleIdentity: basis.hasCurrentRoleIdentity
        )
    }

    func presentPinnedMessages(channelID: ChannelID? = nil) {
        guard sessionState == .workspace,
              let target = channelID ?? activePinsChannelID,
              target == activePinsChannelID
        else { return }
        pinnedMessages.channelID = target
        pinnedMessages.isPresented = true
        AppPerformanceSignposts.beginPinnedMessagesOpen()
        pinnedMessages.hasReadPermission = canReadPins(in: target)
        loadPinnedMessages(replacing: true)
    }

    func presentPinnedMessagesFromSystemMessage(channelID: ChannelID) {
        if channelID == activePinsChannelID {
            presentPinnedMessages(channelID: channelID)
            return
        }
        if rootPinChannel(channelID) != nil {
            navigate(to: channelID)
        } else {
            let guildID = snapshot?.threads.first(where: { $0.id == channelID })?.guildID
                ?? snapshot?.activeJoinedThreads.first(where: { $0.id == channelID })?.guildID
                ?? messageSearch.page?.channels.first(where: { $0.id == channelID })?.guildID
            guard guildID != nil else { return }
            navigate(to: guildID, linkedChannelID: channelID)
        }
        let navigationTask = guildActivationTask
        let session = accountSession()
        Task { @MainActor [weak self] in
            await navigationTask?.value
            guard let self,
                  isCurrentAccountSession(session),
                  activePinsChannelID == channelID
            else { return }
            presentPinnedMessages(channelID: channelID)
        }
    }

    private func canReadPins(in channelID: ChannelID) -> Bool {
        if channelID == openThread?.id {
            guard openThreadAccess.isReadable else { return false }
        } else if channelID != selectedChannelID {
            return false
        }
        guard selectedChannel?.guildID != nil else { return true }
        return selectedEffectivePermissions.map {
            $0 & DiscordPermissionBits.viewChannel != 0
                && $0 & DiscordPermissionBits.readMessageHistory != 0
        } ?? false
    }

    func dismissPinnedMessages() {
        guard pinnedMessages.isPresented else { return }
        AppPerformanceSignposts.beginPinnedMessagesClose()
        pinnedMessages.isPresented = false
        pinnedMessages.loadTask?.cancel()
        pinnedMessages.loadGeneration &+= 1
        pinnedMessages.loadTask = nil
        pinnedMessages.isLoading = false
        pinnedMessages.isLoadingMore = false
        AppPerformanceSignposts.endPinnedMessagesRequest(isPagination: false)
        AppPerformanceSignposts.endPinnedMessagesRequest(isPagination: true)
        AppPerformanceSignposts.endPinnedMessagesScroll()
    }

    func loadMorePinnedMessages() {
        guard pinnedMessages.hasMore,
              !pinnedMessages.isLoading,
              !pinnedMessages.isLoadingMore
        else { return }
        loadPinnedMessages(replacing: false)
    }

    func preparePinnedMessagesPerformanceBenchmark(
        minimumCount: Int = 100
    ) async {
        guard pinnedMessages.isPresented else { return }
        while pinnedMessages.items.count < minimumCount,
              pinnedMessages.hasMore,
              !Task.isCancelled
        {
            let previousCount = pinnedMessages.items.count
            loadMorePinnedMessages()
            guard let task = pinnedMessages.loadTask else { return }
            await task.value
            guard pinnedMessages.items.count > previousCount else { return }
        }
    }

    private func loadPinnedMessages(replacing: Bool) {
        guard let channelID = pinnedMessages.channelID,
              pinnedMessages.hasReadPermission
        else { return }
        pinnedMessages.loadTask?.cancel()
        pinnedMessages.loadGeneration &+= 1
        let generation = pinnedMessages.loadGeneration
        if replacing {
            pinnedMessages.isLoading = true
            pinnedMessages.errorMessage = nil
        } else {
            pinnedMessages.isLoadingMore = true
        }
        let before = replacing ? nil : pinnedMessages.items.last?.pinnedAt
        AppPerformanceSignposts.beginPinnedMessagesRequest(isPagination: !replacing)
        let session = accountSession()
        pinnedMessages.loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await session.provider.pinnedMessages(
                    in: channelID,
                    before: before,
                    limit: 25
                )
                await self.commitPinnedMessagesPage(
                    page,
                    channelID: channelID,
                    replacing: replacing,
                    generation: generation,
                    session: session
                )
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled,
                      self.isCurrentAccountSession(session),
                      self.pinnedMessages.channelID == channelID,
                      self.pinnedMessages.loadGeneration == generation
                else { return }
                self.pinnedMessages.errorMessage = error.localizedDescription
            }
            guard self.pinnedMessages.loadGeneration == generation else { return }
            AppPerformanceSignposts.endPinnedMessagesRequest(isPagination: !replacing)
            self.pinnedMessages.isLoading = false
            self.pinnedMessages.isLoadingMore = false
            self.pinnedMessages.loadTask = nil
        }
    }

    private func commitPinnedMessagesPage(
        _ page: PinnedMessagePage,
        channelID: ChannelID,
        replacing: Bool,
        generation: UInt64,
        session: AppModelAccountSession
    ) async {
        guard isCurrentPinnedMessagesLoad(
            channelID: channelID,
            generation: generation,
            session: session
        ) else { return }
        let previousItems = pinnedMessages.items
        let combined = replacing ? page.items : mergePinnedPages(
            previousItems,
            page.items
        )
        let newItems = applyingPinIntents(
            to: combined,
            channelID: channelID,
            previousItems: previousItems
        )
        let oldRows = pinnedMessages.rows
        let preparedRows = await Task.detached(priority: .userInitiated) {
            PinnedMessagePresentation.reusingRows(
                oldItems: previousItems,
                oldRows: oldRows,
                for: newItems
            )
        }.value
        guard isCurrentPinnedMessagesLoad(
            channelID: channelID,
            generation: generation,
            session: session
        ) else { return }
        let latestPreviousItems = pinnedMessages.items
        let latestCombined = replacing ? page.items : mergePinnedPages(
            latestPreviousItems,
            page.items
        )
        let latestItems = applyingPinIntents(
            to: latestCombined,
            channelID: channelID,
            previousItems: latestPreviousItems
        )
        let commitRows = if latestItems == newItems,
            latestPreviousItems == previousItems
        {
            preparedRows
        } else {
            PinnedMessagePresentation.reusingRows(
                oldItems: latestPreviousItems,
                oldRows: pinnedMessages.rows,
                for: latestItems
            )
        }
        pinnedMessages.replaceItems(
            latestItems,
            preparedRows: commitRows,
            notifying: self
        )
        if replacing {
            reconcilePinSnapshot(
                channelID: channelID,
                previous: previousItems,
                currentPage: page
            )
        } else {
            for item in page.items {
                applyPinTruth(true, message: item.message)
            }
        }
        pinnedMessages.hasMore = page.hasMore
        pinnedMessages.errorMessage = nil
    }

    private func isCurrentPinnedMessagesLoad(
        channelID: ChannelID,
        generation: UInt64,
        session: AppModelAccountSession
    ) -> Bool {
        !Task.isCancelled
            && isCurrentAccountSession(session)
            && pinnedMessages.channelID == channelID
            && pinnedMessages.loadGeneration == generation
    }

    private func mergePinnedPages(
        _ existing: [PinnedMessage],
        _ incoming: [PinnedMessage]
    ) -> [PinnedMessage] {
        var byID = Dictionary(
            uniqueKeysWithValues: existing.map { ($0.id, $0) }
        )
        for item in incoming { byID[item.id] = item }
        return byID.values.sorted {
            if $0.pinnedAt != $1.pinnedAt { return $0.pinnedAt > $1.pinnedAt }
            return $0.message.id > $1.message.id
        }
    }

    private func reconcilePinSnapshot(
        channelID: ChannelID,
        previous: [PinnedMessage],
        currentPage: PinnedMessagePage
    ) {
        let currentIDs = Set(currentPage.items.map(\.id))
        for item in currentPage.items {
            applyPinTruth(true, message: item.message)
        }
        let oldestAuthoritativeDate = currentPage.items.last?.pinnedAt
        for old in previous where !currentIDs.contains(old.id) {
            let isWithinAuthoritativeWindow = !currentPage.hasMore
                || oldestAuthoritativeDate.map { old.pinnedAt >= $0 } == true
            guard isWithinAuthoritativeWindow,
                  old.message.channelID == channelID
            else { continue }
            applyPinTruth(false, message: old.message)
        }
    }

    private func applyingPinIntents(
        to items: [PinnedMessage],
        channelID: ChannelID,
        previousItems: [PinnedMessage]
    ) -> [PinnedMessage] {
        var result = items
        for (messageID, intent) in pinnedMessages.mutationIntents
        where intent.channelID == channelID {
            if intent.desired {
                guard !result.contains(where: { $0.id == messageID }),
                      let prior = previousItems.first(where: { $0.id == messageID })
                else { continue }
                result.append(prior)
            } else {
                result.removeAll { $0.id == messageID }
            }
        }
        return result.sorted {
            if $0.pinnedAt != $1.pinnedAt { return $0.pinnedAt > $1.pinnedAt }
            return $0.id > $1.id
        }
    }

    private func applyPinTruth(_ isPinned: Bool, message source: Message) {
        let isPinned = pinnedMessages.mutationIntents[source.id]?.desired ?? isPinned
        var message = source
        message.isPinned = isPinned
        consumeMessageUpdated(message, preparedTextPlan: nil)
        guard var page = messageSearch.page else { return }
        var changed = false
        for resultIndex in page.results.indices {
            for messageIndex in page.results[resultIndex].messages.indices
            where page.results[resultIndex].messages[messageIndex].id == message.id {
                page.results[resultIndex].messages[messageIndex].isPinned = isPinned
                changed = true
            }
        }
        guard changed else { return }
        let oldRows = messageSearch.rows
        messageSearch.page = page
        let channels = messageSearchChannelsByID(additionalChannels: page.channels)
        messageSearch.rows = MessageSearchPresentation.rows(
            for: page,
            channelsByID: channels
        )
        let nextRevision = messageSearch.rowsRevision &+ 1
        messageSearch.rowsUpdateJournal.append(MessageRowsUpdateRecordBuilder.make(
            oldRows: oldRows,
            newRows: messageSearch.rows,
            revision: nextRevision
        ))
        messageSearch.rowsRevision = nextRevision
    }

    func togglePinnedState(for message: Message) {
        guard canManagePins(for: message) else { return }
        let current = currentPinMessage(for: message)
        let desired = !current.isPinned
        applyOptimisticPin(desired, to: current)
        let previousTask = pinnedMessages.mutationTasks[message.id]
        let generation = (pinnedMessages.mutationGenerations[message.id] ?? 0) &+ 1
        pinnedMessages.mutationGenerations[message.id] = generation
        pinnedMessages.mutationIntents[message.id] = .init(
            channelID: message.channelID,
            desired: desired,
            generation: generation
        )
        let session = accountSession()
        let task = Task { [weak self] in
            _ = await previousTask?.result
            guard let self,
                  !Task.isCancelled,
                  self.isCurrentAccountSession(session)
            else { return }
            do {
                try await session.provider.setMessagePinned(
                    desired,
                    messageID: message.id,
                    channelID: message.channelID
                )
            } catch {
                guard self.isCurrentAccountSession(session) else { return }
                if Self.isDefinitePinMutationFailure(error) {
                    if self.pinnedMessages.mutationIntents[message.id]?.generation
                        == generation {
                        self.pinnedMessages.mutationIntents[message.id] = nil
                        self.applyOptimisticPin(!desired, to: current)
                    }
                } else if self.pinnedMessages.isPresented {
                    if self.pinnedMessages.mutationIntents[message.id]?.generation
                        == generation {
                        self.pinnedMessages.mutationIntents[message.id] = nil
                    }
                    self.loadPinnedMessages(replacing: true)
                }
                self.errorMessage = error.localizedDescription
            }
            if self.pinnedMessages.mutationGenerations[message.id] == generation {
                self.pinnedMessages.mutationTasks[message.id] = nil
                self.pinnedMessages.mutationGenerations[message.id] = nil
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self,
                          self.isCurrentAccountSession(session),
                          self.pinnedMessages.mutationIntents[message.id]?.generation
                            == generation
                    else { return }
                    self.pinnedMessages.mutationIntents[message.id] = nil
                }
            }
        }
        pinnedMessages.mutationTasks[message.id] = task
    }

    private func currentPinMessage(for fallback: Message) -> Message {
        if let item = pinnedMessages.items.first(where: { $0.id == fallback.id }) {
            return item.message
        }
        if let message = messages.first(where: { $0.id == fallback.id }) {
            return message
        }
        if let message = threadMessages.first(where: { $0.id == fallback.id }) {
            return message
        }
        if let page = messageSearch.page {
            for result in page.results {
                if let message = result.messages.first(where: { $0.id == fallback.id }) {
                    return message
                }
            }
        }
        return fallback
    }

    private func applyOptimisticPin(_ isPinned: Bool, to source: Message) {
        var message = source
        message.isPinned = isPinned
        applyPinTruth(isPinned, message: message)
        var items = pinnedMessages.items
        if isPinned {
            if let index = items.firstIndex(where: { $0.id == message.id }) {
                items[index].message = message
            } else if pinnedMessages.channelID == message.channelID {
                items.insert(PinnedMessage(pinnedAt: .now, message: message), at: 0)
            }
        } else {
            items.removeAll { $0.id == message.id }
        }
        pinnedMessages.replaceItems(items, notifying: self)
    }

    nonisolated private static func isDefinitePinMutationFailure(_ error: Error) -> Bool {
        guard let providerError = error as? ChatProviderError else { return false }
        if case let .transport(status, _) = providerError {
            return (400 ..< 500).contains(status)
        }
        return true
    }

    func reconcilePinnedMessage(_ message: Message) {
        guard let index = pinnedMessages.items.firstIndex(where: { $0.id == message.id })
        else { return }
        var items = pinnedMessages.items
        if message.isPinned {
            items[index].message = message
        } else {
            items.remove(at: index)
        }
        pinnedMessages.replaceItems(items, notifying: self)
    }

    func applyingPendingPinIntent(to incoming: Message) -> Message {
        guard let intent = pinnedMessages.mutationIntents[incoming.id],
              intent.channelID == incoming.channelID
        else { return incoming }
        if incoming.isPinned == intent.desired {
            pinnedMessages.mutationIntents[incoming.id] = nil
            return incoming
        }
        var preserved = incoming
        preserved.isPinned = intent.desired
        return preserved
    }

    func invalidatePinnedMessages(in channelID: ChannelID) {
        guard pinnedMessages.channelID == channelID else { return }
        if pinnedMessages.isPresented {
            loadPinnedMessages(replacing: true)
        } else {
            pinnedMessages.replaceItems([], notifying: self)
            pinnedMessages.hasMore = false
            pinnedMessages.errorMessage = nil
        }
    }

    func removeDeletedPinnedMessage(channelID: ChannelID, messageID: MessageID) {
        guard pinnedMessages.channelID == channelID,
              pinnedMessages.items.contains(where: { $0.id == messageID })
        else { return }
        pinnedMessages.replaceItems(
            pinnedMessages.items.filter { $0.id != messageID },
            notifying: self
        )
    }
}
