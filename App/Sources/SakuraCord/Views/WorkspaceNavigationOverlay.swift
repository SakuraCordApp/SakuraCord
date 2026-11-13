import AppKit
import OSLog
import SakuraCordModels
import SwiftUI

enum WorkspaceNavigationOverlay: String, Identifiable {
    case quickSwitcher

    var id: Self { self }
}

struct WorkspaceNavigationOverlayView: View {
    let model: AppModel
    let presentation: WorkspaceNavigationOverlay
    let animationState: WindowModalContext

    var body: some View {
        ZStack {
            WindowModalBackdrop(dismiss: model.dismissWorkspaceNavigationOverlay)

            QuickSwitcherView(model: model, animationState: animationState)
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityHidden(!animationState.isVisible)
    }
}

private nonisolated struct QuickSwitcherSearchInput: Sendable {
    let index: ForwardDestinationSearchPolicy.Index
    let userIndex: ForwardDestinationSearchPolicy.Index
    let guilds: [Guild]
    let usageScores: [String: Int]
    let history: [ChannelID]
    let currentChannelID: ChannelID?
    let currentGuildID: GuildID?
    let currentUserID: UserID?
    let searchableUserIDs: Set<UserID>
    let friendUserIDs: Set<UserID>
    let currentGuildMemberIDs: Set<UserID>
    let currentGuildLiveMemberIDs: Set<UserID>
    let unreadChannelIDs: Set<ChannelID>
    let mutedChannelIDs: Set<ChannelID>
    let mentionedChannelIDs: [ChannelID]
    let draftChannelIDs: [ChannelID]
    let recentlyTalkedUserIDs: [UserID]

    func results(query: String) -> [QuickSwitcherResult] {
        let signposter = OSSignposter(
            subsystem: "dev.sakuracord.SakuraCord",
            category: "PointsOfInterest"
        )
        let interval = signposter.beginInterval("QuickSwitcherRanking")
        defer { signposter.endInterval("QuickSwitcherRanking", interval) }
        return QuickSwitcherSearchPolicy.results(
            query: query,
            context: QuickSwitcherSearchContext(
                index: index,
                userIndex: userIndex,
                guilds: guilds,
                usageScores: usageScores,
                history: history,
                currentChannelID: currentChannelID,
                currentGuildID: currentGuildID,
                currentUserID: currentUserID,
                searchableUserIDs: searchableUserIDs,
                friendUserIDs: friendUserIDs,
                currentGuildMemberIDs: currentGuildMemberIDs,
                currentGuildLiveMemberIDs: currentGuildLiveMemberIDs,
                unreadChannelIDs: unreadChannelIDs,
                mutedChannelIDs: mutedChannelIDs,
                mentionedChannelIDs: mentionedChannelIDs,
                draftChannelIDs: draftChannelIDs,
                recentlyTalkedUserIDs: recentlyTalkedUserIDs
            )
        )
    }
}

private nonisolated struct QuickSwitcherSearchRequest: Hashable, Sendable {
    let query: String
    let indexRevision: UInt64
    let contextRevision: UInt64
}

private nonisolated struct QuickSwitcherMemberQuery: Hashable, Sendable {
    let guildID: GuildID
    let query: String
}

private nonisolated struct QuickSwitcherIndexRequest: Hashable, Sendable {
    let revision: UInt64
}

private struct QuickSwitcherView: View {
    let model: AppModel
    let animationState: WindowModalContext
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var searchIndex: ForwardDestinationSearchPolicy.Index?
    @State private var searchInput: QuickSwitcherSearchInput?
    @State private var searchIndexRevision: UInt64 = 0
    @State private var contextRevision: UInt64 = 0
    @State private var displayedResults: [QuickSwitcherResult] = []
    @State private var selectableResults: [QuickSwitcherResult] = []
    @State private var mentionCountsByChannelID: [ChannelID: Int] = [:]
    @State private var completedQuery = ""
    @State private var selectedResultID: QuickSwitcherResultID?
    @State private var mouseFocusDisabled = true
    @State private var lastPointerLocation: CGPoint?
    @State private var framePresentationID: UInt64 = 0
    @State private var requestedMemberQueries: Set<QuickSwitcherMemberQuery> = []

    var body: some View {
        VStack(spacing: 0) {
                HStack(spacing: InterfaceScale.metric(11)) {
                    Image(systemName: "magnifyingglass")
                        .font(.interfaceSystem(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                    QuickSwitcherSearchField(
                        text: $query,
                        placeholder: "Where would you like to go?",
                        isPresented: animationState.isVisible,
                        handleKeyDown: handleKeyDown
                    )
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, InterfaceScale.metric(18))
                .frame(height: InterfaceScale.metric(58))

                Divider()

                QuickSwitcherResultList(
                    rows: displayedResults.map(makeRowPresentation),
                    selectedResultID: selectedResultID,
                    keyboardNavigationActive: mouseFocusDisabled,
                    presentationID: framePresentationID,
                    reportFrame: {
                        if searchIndex != nil {
                            AppPerformanceSignposts.reportQuickSwitcherFirstFrame()
                        }
                    },
                    focus: { selectedResultID = $0 },
                    activate: activate
                )
            }
            .frame(width: InterfaceScale.metric(570), height: InterfaceScale.metric(460))
            .contentShape(ConcentricRectangle(cornerRadius: InterfaceScale.metric(18), style: .continuous))
            .glassEffect(
                .regular,
                in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(18), style: .continuous)
            )
            .containerShape(.rect(cornerRadius: InterfaceScale.metric(18), style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: InterfaceScale.metric(24), y: 14)
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard animationState.isInputActive else { return }
                switch phase {
                case .active(let location):
                    if let lastPointerLocation,
                       lastPointerLocation != location
                    {
                        mouseFocusDisabled = false
                    }
                    lastPointerLocation = location
                case .ended:
                    lastPointerLocation = nil
                }
            }
            .onChange(of: query) { _, _ in
                AppPerformanceSignposts.beginQuickSwitcherQuery()
            }
            .onChange(of: animationState.isVisible) { _, isVisible in
                if isVisible {
                    let currentUserID = model.currentUser?.id
                    let sourceRevision = model.forwardSearchSourceRevision
                    if let exact = ForwardDestinationSearchIndexCache.shared.value(
                        for: model,
                        userID: currentUserID,
                        revision: sourceRevision
                    ) {
                        applySearchIndex(exact)
                    } else if let searchIndex {
                        searchInput = makeSearchInput(searchIndex: searchIndex)
                    }
                    contextRevision &+= 1
                    framePresentationID &+= 1
                    return
                }
                query = ""
                mouseFocusDisabled = true
                lastPointerLocation = nil
                selectedResultID = nil
            }
            .onChange(
                of: animationState.isVisible ? model.members.map(\.id) : []
            ) { _, _ in
                // The retained quick switcher is preloaded before the current
                // guild's member viewport may finish hydrating. Re-rank from
                // the live member store instead of freezing that early,
                // incomplete eligibility snapshot for the whole session.
                if animationState.isVisible, let searchIndex {
                    searchInput = makeSearchInput(searchIndex: searchIndex)
                    contextRevision &+= 1
                }
            }
            .task(id: activeIndexRequest) {
                guard let activeIndexRequest else {
                    // Keep the immutable corpus warm without making the
                    // retained, invisible view observe every source revision.
                    // The cache owns and coalesces this background work.
                    if model.snapshot != nil {
                        ForwardDestinationSearchIndexCache.shared.schedulePrewarm(
                            for: model
                        )
                    }
                    return
                }
                if activeMemberSearchRequest != nil {
                    ForwardDestinationSearchIndexCache.shared.invalidate(for: model)
                }
                if !model.hasLoadedDiscordEmojiSettings {
                    Task { @MainActor in
                        await model.loadDiscordEmojiSettings()
                    }
                }
                let userID = model.currentUser?.id
                let revision = activeIndexRequest.revision
                let exact = ForwardDestinationSearchIndexCache.shared.value(
                    for: model,
                    userID: userID,
                    revision: revision
                )
                let latest = ForwardDestinationSearchIndexCache.shared.latestValue(
                    for: model,
                    userID: userID
                )
                if searchIndex == nil,
                   let immediatelyAvailable = exact
                    ?? latest
                {
                    applySearchIndex(immediatelyAvailable)
                }
                let prepared: ForwardDestinationSearchPolicy.Index?
                if let exact {
                    prepared = exact
                } else {
                    prepared = await ForwardDestinationSearchIndexCache.shared.prepare(
                        for: model,
                        priority: .userInitiated
                    )
                }
                guard !Task.isCancelled else { return }
                if let searchIndex {
                    // Membership/read-state projections are small live inputs
                    // to the retained index. Refresh those without rebuilding
                    // or swapping the expensive immutable search corpus.
                    searchInput = makeSearchInput(searchIndex: searchIndex)
                    contextRevision &+= 1
                }
                // Show the retained index immediately, then adopt the exact
                // account-synchronized frecency snapshot as soon as it is
                // ready. Discord does the same asynchronous store hydration;
                // retaining the stale index for the whole first presentation
                // made a clean launch rank differently until close/reopen.
                if let prepared {
                    applySearchIndex(prepared)
                }
            }
            .task(id: activeSearchRequest) {
                guard let activeSearchRequest else { return }
                await refreshDisplayedResults(for: activeSearchRequest)
            }
            .task(id: activeMemberSearchRequest) {
                guard let activeMemberSearchRequest else { return }
                await requestQuickSwitcherMembersIfNeeded(
                    for: activeMemberSearchRequest
                )
            }
    }

    private var searchRequest: QuickSwitcherSearchRequest {
        QuickSwitcherSearchRequest(
            query: query,
            indexRevision: searchIndexRevision,
            contextRevision: contextRevision
        )
    }

    private var activeIndexRequest: QuickSwitcherIndexRequest? {
        guard animationState.isVisible else { return nil }
        return QuickSwitcherIndexRequest(
            revision: model.forwardSearchSourceRevision
        )
    }

    private var activeSearchRequest: QuickSwitcherSearchRequest? {
        animationState.isVisible ? searchRequest : nil
    }

    private var activeMemberSearchRequest: QuickSwitcherMemberQuery? {
        guard animationState.isVisible else { return nil }
        let parsed = QuickSwitcherParsedQuery(query)
        guard parsed.mode == .user,
              !parsed.searchValue.isEmpty,
              let guildID = model.selectedGuildID
        else { return nil }
        return QuickSwitcherMemberQuery(
            guildID: guildID,
            query: parsed.searchValue.lowercased()
        )
    }

    private func applySearchIndex(
        _ index: ForwardDestinationSearchPolicy.Index
    ) {
        searchIndex = index
        searchInput = makeSearchInput(searchIndex: index)
        searchIndexRevision &+= 1
    }

    private func makeSearchInput(
        searchIndex: ForwardDestinationSearchPolicy.Index
    ) -> QuickSwitcherSearchInput? {
        guard let snapshot = model.snapshot else { return nil }
        let guildsByID = Dictionary(
            snapshot.guilds.map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        var seenGuildIDs = Set<GuildID>()
        let guildsInStoreOrder = snapshot.forwardGuildStoreOrder.compactMap { guildID in
            guard seenGuildIDs.insert(guildID).inserted else { return nil }
            return guildsByID[guildID]
        } + snapshot.guilds.filter { seenGuildIDs.insert($0.id).inserted }
        let projection = model.readState.quickSwitcherProjection()
        let currentGuildMemberIDs: Set<UserID> = model.selectedGuildID.flatMap { guildID in
            let indexed = Set(snapshot.quickSwitcherGuildMemberUserIDs[guildID] ?? [])
            let live = Set(model.membersByGuildID[guildID]?.keys.map { $0 } ?? [])
            return indexed.union(live)
        } ?? []
        let currentGuildLiveMemberIDs: Set<UserID> = model.selectedGuildID.map { guildID in
            var userIDs = Set(
                snapshot.quickSwitcherJoinedGuildMemberUserIDs[guildID] ?? []
            )
            // Discord's current-channel MessageStore records may already carry
            // a current guild-member object even when a separate member lookup
            // did not echo that user. Bare @ reads this live MessageStore path;
            // a message-derived worker marker without a member remains ineligible.
            userIDs.formUnion(model.messages.lazy.compactMap { message in
                message.guildID == guildID && message.guildMember != nil
                    ? message.author.id : nil
            })
            return userIDs
        } ?? []
        var seenRecentlyTalkedUserIDs: Set<UserID> = []
        let recentlyTalkedUserIDs = model.messages.reversed().compactMap { message in
            seenRecentlyTalkedUserIDs.insert(message.author.id).inserted
                ? message.author.id : nil
        }
        mentionCountsByChannelID = projection.mentionsByChannelID
        return QuickSwitcherSearchInput(
            index: searchIndex,
            userIndex: searchIndex.quickSwitcherUserIndex(
                // SearchContextManager seeds every live nickname held by
                // GuildMemberStore at connection-open. Forwarding's durable
                // message cache must not change results after a relaunch.
                userSearchAliasesByUserID: quickSwitcherAliases(
                    snapshot.quickSwitcherGuildMemberAliases,
                    guildOrder: guildsInStoreOrder.map(\.id)
                )
            ),
            guilds: guildsInStoreOrder,
            usageScores: model.discordGuildAndChannelUsageScores,
            history: model.forwardDestinationHistory,
            currentChannelID: model.selectedChannelID,
            currentGuildID: model.selectedGuildID,
            currentUserID: snapshot.currentUser.id,
            searchableUserIDs: Set(snapshot.quickSwitcherUserIDs),
            friendUserIDs: snapshot.friendUserIDs,
            currentGuildMemberIDs: currentGuildMemberIDs,
            currentGuildLiveMemberIDs: currentGuildLiveMemberIDs,
            unreadChannelIDs: projection.unreadChannelIDs,
            mutedChannelIDs: projection.mutedChannelIDs,
            mentionedChannelIDs: projection.mentionedChannelIDs,
            draftChannelIDs: model.quickSwitcherDraftChannelIDs,
            recentlyTalkedUserIDs: recentlyTalkedUserIDs
        )
    }

    private func quickSwitcherAliases(
        _ aliasesByGuildID: [GuildID: [UserID: String]],
        guildOrder: [GuildID]
    ) -> [UserID: [String]] {
        var result: [UserID: [String]] = [:]
        var seenGuildIDs = Set<GuildID>()
        let orderedGuildIDs = guildOrder.filter { seenGuildIDs.insert($0).inserted }
            + aliasesByGuildID.keys.sorted().filter { seenGuildIDs.insert($0).inserted }
        for guildID in orderedGuildIDs {
            for userID in (aliasesByGuildID[guildID] ?? [:]).keys.sorted() {
                guard let alias = aliasesByGuildID[guildID]?[userID],
                      result[userID, default: []].contains(where: {
                          $0.localizedCaseInsensitiveCompare(alias) == .orderedSame
                      }) == false
                else { continue }
                result[userID, default: []].append(alias)
            }
        }
        return result
    }

    private func refreshDisplayedResults(
        for request: QuickSwitcherSearchRequest
    ) async {
        guard let input = searchInput else {
            displayedResults = []
            selectableResults = []
            selectedResultID = nil
            return
        }
        // Ranking is a bounded, local index operation. Keeping it in this
        // presentation task avoids a detached-task hop plus a second main-actor
        // hop before rows can be committed to the native viewport.
        let results = input.results(query: request.query)
        guard !Task.isCancelled, activeSearchRequest == request else { return }
        let selectable = results.filter(\.isSelectable)
        let preservesSelection = completedQuery == request.query
        displayedResults = results
        selectableResults = selectable
        completedQuery = request.query
        selectedResultID = QuickSwitcherSelectionPolicy.synchronized(
            current: selectedResultID,
            selectableIDs: selectable.map(\.id),
            preservesCurrent: preservesSelection
        )
        framePresentationID &+= 1
    }

    private func requestQuickSwitcherMembersIfNeeded(
        for memberQuery: QuickSwitcherMemberQuery
    ) async {
        // Discord ranks from its local UserStore and opportunistically asks
        // the selected guild for prefix matches only in explicit @ mode.
        // Ordinary text search must not alter the candidate store.
        do {
            // The current clean client sends at roughly 430–525 ms after an
            // input fill. Keep this coalescing latency entirely
            // outside the local ranking task.
            try await Task.sleep(for: .milliseconds(400))
        } catch {
            return
        }
        guard !Task.isCancelled,
              requestedMemberQueries.insert(memberQuery).inserted
        else { return }
        let session = model.accountSession()
        do {
            try await session.provider.requestQuickSwitcherMembers(
                in: memberQuery.guildID,
                query: memberQuery.query,
                limit: 100
            )
            guard !Task.isCancelled,
                  model.isCurrentAccountSession(session)
            else { return }
            // GUILD_MEMBERS_CHUNK updates the provider's UserStore mirror and
            // publishes a new immutable search-index revision. The retained
            // sheet adopts that revision without blocking local keystrokes.
        } catch is CancellationError {
            requestedMemberQueries.remove(memberQuery)
        } catch {
            guard model.isCurrentAccountSession(session) else { return }
            requestedMemberQueries.remove(memberQuery)
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        mouseFocusDisabled = true
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53:
            if query.isEmpty {
                model.dismissWorkspaceNavigationOverlay()
            } else {
                query = ""
            }
            return true
        case 36, 76:
            activateSelectedResult()
            return true
        case 125:
            moveSelection(by: 1)
            return true
        case 126:
            moveSelection(by: -1)
            return true
        default:
            let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if modifiers.contains(.control), characters == "n" {
                moveSelection(by: 1)
                return true
            }
            if modifiers.contains(.control), characters == "p" {
                moveSelection(by: -1)
                return true
            }
            if modifiers.contains(.command) || modifiers.contains(.control),
               ["k", "t"].contains(characters)
            {
                model.dismissWorkspaceNavigationOverlay()
                return true
            }
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        selectedResultID = AppPerformanceSignposts.measureSync(
            "QuickSwitcherKeyboardNavigation"
        ) {
            QuickSwitcherSelectionPolicy.moved(
                current: selectedResultID,
                selectableIDs: selectableResults.map(\.id),
                delta: delta
            )
        }
    }

    private func activateSelectedResult() {
        guard let selectedResultID,
              let result = selectableResults.first(where: { $0.id == selectedResultID })
        else { return }
        activate(result)
    }

    private func activate(_ result: QuickSwitcherResult) {
        switch result {
        case .heading:
            return
        case .guild(let guild):
            model.dismissWorkspaceNavigationOverlay()
            model.selectGuild(guild.id)
        case .destination(let destination):
            model.activateQuickSwitcherDestination(destination)
        case .navigation:
            model.dismissWorkspaceNavigationOverlay()
            openSettings()
        }
    }

    private func makeRowPresentation(
        _ result: QuickSwitcherResult
    ) -> QuickSwitcherRowPresentation {
        switch result {
        case .heading(_, let title):
            return QuickSwitcherRowPresentation(result: result, heading: title)
        case .guild(let guild):
            return QuickSwitcherRowPresentation(
                result: result,
                title: guild.name,
                inlineDetail: "Server",
                systemImage: "person.3.fill",
                imageURL: guild.iconURL
            )
        case .destination(let destination):
            let metadata = destinationMetadata(destination)
            return QuickSwitcherRowPresentation(
                result: result,
                title: destination.title,
                inlineDetail: metadata.inlineDetail,
                trailingDetail: metadata.trailingDetail,
                mentionCount: destination.resolvedChannelID.map {
                    mentionCountsByChannelID[$0, default: 0]
                } ?? 0,
                systemImage: destinationSystemImage(destination),
                imageURL: destinationImageURL(destination)
            )
        case .navigation(let navigation):
            return QuickSwitcherRowPresentation(
                result: result,
                title: navigation.title,
                systemImage: navigation.id == "SETTINGS" ? "gearshape.fill" : "sparkles"
            )
        }
    }

    private func destinationMetadata(
        _ destination: ForwardDestination
    ) -> (inlineDetail: String?, trailingDetail: String?) {
        switch destination.kind {
        case .user(let user, _):
            return (user.tag, nil)
        case .thread(_, let parent):
            return (parent?.name, destination.guild?.name)
        case .channel(let channel):
            if channel.kind == .directMessage || channel.kind == .groupDirectMessage {
                return (destination.detail.isEmpty ? nil : destination.detail, nil)
            }
            return (channel.category, destination.guild?.name)
        }
    }

    private func destinationImageURL(_ destination: ForwardDestination) -> URL? {
        switch destination.kind {
        case .user:
            destination.avatarURL
        case .channel(let channel) where channel.kind == .directMessage
            || channel.kind == .groupDirectMessage:
            destination.avatarURL
        case .channel, .thread:
            nil
        }
    }

    private func destinationSystemImage(_ destination: ForwardDestination) -> String {
        switch destination.kind {
        case .user: "person.crop.circle"
        case .thread: "number"
        case .channel(let channel):
            switch channel.kind {
            case .voice: "speaker.wave.2.fill"
            case .directMessage, .groupDirectMessage: "person.crop.circle"
            case .announcement: "megaphone.fill"
            case .forum: "rectangle.3.group.bubble.left.fill"
            default: "number"
            }
        }
    }

}

private struct QuickSwitcherRowPresentation: Identifiable, Equatable {
    let result: QuickSwitcherResult
    var heading: String?
    var title: String
    var inlineDetail: String?
    var trailingDetail: String?
    var mentionCount: Int
    var systemImage: String
    var imageURL: URL?

    var id: QuickSwitcherResultID { result.id }

    init(result: QuickSwitcherResult, heading: String) {
        self.result = result
        self.heading = heading
        title = ""
        inlineDetail = nil
        trailingDetail = nil
        mentionCount = 0
        systemImage = ""
        imageURL = nil
    }

    init(
        result: QuickSwitcherResult,
        title: String,
        inlineDetail: String? = nil,
        trailingDetail: String? = nil,
        mentionCount: Int = 0,
        systemImage: String,
        imageURL: URL? = nil
    ) {
        self.result = result
        heading = nil
        self.title = title
        self.inlineDetail = inlineDetail
        self.trailingDetail = trailingDetail
        self.mentionCount = mentionCount
        self.systemImage = systemImage
        self.imageURL = imageURL
    }

    var accessibilityLabel: String {
        if let heading { return heading }
        return [
            title,
            inlineDetail,
            mentionCount > 0 ? "\(mentionCount) mentions" : nil,
            trailingDetail,
        ].compactMap { $0 }.joined(separator: ", ")
    }

    var accessibilityResultIdentifier: String? {
        switch result {
        case .heading:
            nil
        case .guild(let guild):
            "GUILD:\(guild.id)"
        case .navigation(let navigation):
            "IN_APP_NAVIGATION:\(navigation.id)"
        case .destination(let destination):
            switch destination.kind {
            case .user(let user, _):
                "USER:\(user.id)"
            case .thread(let channel, _):
                "TEXT_CHANNEL:\(channel.id)"
            case .channel(let channel):
                switch channel.kind {
                case .voice:
                    "VOICE_CHANNEL:\(channel.id)"
                case .groupDirectMessage:
                    "GROUP_DM:\(channel.id)"
                case .directMessage:
                    "USER:\(channel.id)"
                default:
                    "TEXT_CHANNEL:\(channel.id)"
                }
            }
        }
    }

}

nonisolated enum QuickSwitcherIconGeometry {
    static func serverCornerRadius(iconSize: CGFloat) -> CGFloat {
        iconSize * 14 / 44
    }

    static func aspectFillRect(
        imageSize: CGSize,
        in bounds: CGRect
    ) -> CGRect {
        guard imageSize.width > 0,
              imageSize.height > 0,
              bounds.width > 0,
              bounds.height > 0
        else { return bounds }
        let scale = max(
            bounds.width / imageSize.width,
            bounds.height / imageSize.height
        )
        let size = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

private struct QuickSwitcherResultList: View {
    let rows: [QuickSwitcherRowPresentation]
    let selectedResultID: QuickSwitcherResultID?
    let keyboardNavigationActive: Bool
    let presentationID: UInt64
    let reportFrame: @MainActor () -> Void
    let focus: (QuickSwitcherResultID) -> Void
    let activate: (QuickSwitcherResult) -> Void
    @State private var pointerLocationAtContentChange: CGPoint?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: InterfaceScale.metric(2)) {
                    ForEach(rows) { row in
                        if let heading = row.heading {
                            QuickSwitcherHeadingRow(title: heading)
                        } else {
                            QuickSwitcherResultRow(
                                row: row,
                                isSelected: row.id == selectedResultID,
                                isPointerFocusEnabled: !keyboardNavigationActive,
                                hover: pointerHovered,
                                activate: activate
                            )
                            .equatable()
                        }
                    }
                }
                .padding(InterfaceScale.metric(8))
            }
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGFloat.self, of: \.contentOffset.y) { _, _ in
                pointerLocationAtContentChange = NSEvent.mouseLocation
            }
            .onChange(of: presentationID) {
                pointerLocationAtContentChange = NSEvent.mouseLocation
            }
            .accessibilityIdentifier("quick-switch-results")
            .onChange(of: selectedResultID) { _, selectedResultID in
                guard keyboardNavigationActive, let selectedResultID else { return }
                proxy.scrollTo(selectedResultID)
            }
            .background {
                DisplayCompleteFrameReporter(presentationID: presentationID, report: reportFrame)
            }
        }
    }

    /// Rows scrolling or re-ranking under a resting pointer report hover
    /// too; only a pointer that moved since then may take the selection.
    private func pointerHovered(over id: QuickSwitcherResultID) {
        guard NSEvent.mouseLocation != pointerLocationAtContentChange else { return }
        focus(id)
    }
}

private struct QuickSwitcherHeadingRow: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.interfaceSystem(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, InterfaceScale.metric(10))
            .padding(.bottom, InterfaceScale.metric(3))
            .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(28), alignment: .bottomLeading)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct QuickSwitcherResultRow: View, Equatable {
    let row: QuickSwitcherRowPresentation
    let isSelected: Bool
    let isPointerFocusEnabled: Bool
    let hover: (QuickSwitcherResultID) -> Void
    let activate: (QuickSwitcherResult) -> Void
    @Environment(\.windowModalInputAllowed) private var inputAllowed

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row
            && lhs.isSelected == rhs.isSelected
            && lhs.isPointerFocusEnabled == rhs.isPointerFocusEnabled
    }

    var body: some View {
        Button {
            activate(row.result)
        } label: {
            HStack(spacing: InterfaceScale.metric(8)) {
                QuickSwitcherRowIcon(row: row)
                HStack(spacing: InterfaceScale.metric(6)) {
                    Text(row.title)
                        .font(.interfaceSystem(size: 15, weight: .medium))
                    if let inlineDetail = row.inlineDetail {
                        Text(inlineDetail)
                            .font(.interfaceSystem(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if row.mentionCount > 0 {
                        Text(row.mentionCount, format: .number)
                            .font(.interfaceSystem(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, InterfaceScale.metric(6))
                            .frame(minWidth: InterfaceScale.metric(20), minHeight: InterfaceScale.metric(20))
                            .background(.red, in: .rect(cornerRadius: InterfaceScale.metric(5)))
                            .layoutPriority(2)
                    }
                }
                Spacer(minLength: InterfaceScale.metric(10))
                if let trailingDetail = row.trailingDetail {
                    Text(trailingDetail)
                        .font(.interfaceSystem(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: InterfaceScale.metric(150), alignment: .trailing)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, InterfaceScale.metric(10))
            .frame(height: InterfaceScale.metric(34))
            .background(
                isSelected ? Color.primary.opacity(0.09) : .clear,
                in: .rect(cornerRadius: InterfaceScale.metric(6), style: .continuous)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onContinuousHover { phase in
            // The panel enables pointer focus only after real movement.
            if case .active = phase, inputAllowed, isPointerFocusEnabled, !isSelected {
                hover(row.id)
            }
        }
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(
            row.accessibilityResultIdentifier.map { "quick-switch-result-\($0)" } ?? ""
        )
    }
}

private struct QuickSwitcherRowIcon: View {
    let row: QuickSwitcherRowPresentation

    private var size: CGFloat { InterfaceScale.metric(22) }

    var body: some View {
        Group {
            if case .guild(let guild) = row.result {
                let cornerRadius = QuickSwitcherIconGeometry.serverCornerRadius(iconSize: size)
                GuildIconView(
                    name: guild.name,
                    iconURL: guild.iconURL,
                    size: size,
                    cornerRadius: cornerRadius,
                    animates: false
                )
                .background(.secondary.opacity(0.16), in: .rect(cornerRadius: cornerRadius, style: .continuous))
            } else if let imageURL = row.imageURL {
                // The initial shows until the image loads, or if it fails.
                AvatarView(name: row.title, url: imageURL, size: size, animates: false, isHovered: false)
                    .background { AvatarView(name: row.title, url: nil, size: size, isHovered: false) }
            } else {
                Image(systemName: row.systemImage)
                    .font(.interfaceSystem(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct QuickSwitcherSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isPresented: Bool
    let handleKeyDown: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, handleKeyDown: handleKeyDown)
    }

    func makeNSView(context: Context) -> KeyHandlingTextField {
        let field = KeyHandlingTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .interfaceSystemFont(ofSize: 19)
        field.placeholderString = placeholder
        field.setAccessibilityIdentifier("quick-switch-search")
        field.handleKeyDown = handleKeyDown
        return field
    }

    func updateNSView(_ field: KeyHandlingTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
        let font = NSFont.interfaceSystemFont(ofSize: 19)
        if field.font != font {
            field.font = font
            (field.currentEditor() as? NSTextView)?.font = font
        }
        field.handleKeyDown = handleKeyDown
        context.coordinator.handleKeyDown = handleKeyDown
        if isPresented,
           let window = field.window,
           window.firstResponder !== field.currentEditor()
        {
            window.makeFirstResponder(field)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding private var text: String
        var handleKeyDown: (NSEvent) -> Bool

        init(
            text: Binding<String>,
            handleKeyDown: @escaping (NSEvent) -> Bool
        ) {
            _text = text
            self.handleKeyDown = handleKeyDown
            // The retained modal constructs this coordinator while hidden.
            // Load TextKit's field-editor classes now so first focus does not
            // pay their dynamic-link and text-layout initialization cost.
            let textSystemPrewarmer = NSTextView(frame: .zero)
            _ = textSystemPrewarmer.textLayoutManager
            _ = textSystemPrewarmer.textContentStorage
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            (field.currentEditor() as? NSTextView)?
                .applySakuraCordTextSelectionAppearance()
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard let event = NSApp.currentEvent else { return false }
            return handleKeyDown(event)
        }
    }
}

private final class KeyHandlingTextField: NSTextField {
    var handleKeyDown: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        guard handleKeyDown?(event) != true else { return }
        super.keyDown(with: event)
    }
}

private func overlayHeader(title: String, subtitle: String) -> some View {
    HStack {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(3)) {
            Text(title).font(.interface(.title2).weight(.semibold))
            Text(subtitle).font(.interface(.callout)).foregroundStyle(.secondary)
        }
        Spacer()
    }
    .padding(.horizontal, InterfaceScale.metric(20))
    .padding(.top, InterfaceScale.metric(18))
    .padding(.bottom, InterfaceScale.metric(14))
}
