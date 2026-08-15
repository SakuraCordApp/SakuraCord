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
    let animationState: WindowModalAnimationState

    var body: some View {
        ZStack {
            Color.black.opacity(presentation == .quickSwitcher ? 0.14 : 0.32)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { model.dismissWorkspaceNavigationOverlay() }

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

private struct QuickSwitcherView: View {
    let model: AppModel
    let animationState: WindowModalAnimationState
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
                HStack(spacing: 11) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .medium))
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
                .padding(.horizontal, 18)
                .frame(height: 58)

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
                    enableMouseFocus: { mouseFocusDisabled = false },
                    focus: { selectedResultID = $0 },
                    activate: activate
                )
            }
            .frame(width: 570, height: 460)
            .contentShape(ConcentricRectangle(cornerRadius: 18, style: .continuous))
            .glassEffect(
                .regular,
                in: ConcentricRectangle(cornerRadius: 18, style: .continuous)
            )
            .containerShape(.rect(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 24, y: 14)
            .onContinuousHover(coordinateSpace: .local) { phase in
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
                    let currentUserID = model.snapshot?.currentUser.id
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
            .onChange(of: model.members.map(\.id)) { _, _ in
                // The retained quick switcher is preloaded before the current
                // guild's member viewport may finish hydrating. Re-rank from
                // the live member store instead of freezing that early,
                // incomplete eligibility snapshot for the whole session.
                if let searchIndex {
                    searchInput = makeSearchInput(searchIndex: searchIndex)
                    contextRevision &+= 1
                }
            }
            .task(id: model.forwardSearchSourceRevision) {
                if memberSearchRequest != nil {
                    ForwardDestinationSearchIndexCache.shared.invalidate(for: model)
                }
                if !model.hasLoadedDiscordEmojiSettings {
                    Task { @MainActor in
                        await model.loadDiscordEmojiSettings()
                    }
                }
                let userID = model.snapshot?.currentUser.id
                let revision = model.forwardSearchSourceRevision
                let exact = ForwardDestinationSearchIndexCache.shared.value(
                    for: model,
                    userID: userID,
                    revision: revision
                )
                if searchIndex == nil,
                   let immediatelyAvailable = exact
                    ?? ForwardDestinationSearchIndexCache.shared.latestValue(
                        for: model,
                        userID: userID
                    )
                {
                    applySearchIndex(immediatelyAvailable)
                }
                let prepared: ForwardDestinationSearchPolicy.Index?
                if let exact {
                    prepared = exact
                } else {
                    prepared = await ForwardDestinationSearchIndexCache.shared.prepare(
                        for: model,
                        priority: animationState.isVisible ? .userInitiated : .utility
                    )
                }
                guard !Task.isCancelled else { return }
                if animationState.isVisible, let searchIndex {
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
            .task(id: searchRequest) {
                await refreshDisplayedResults(for: searchRequest)
            }
            .task(id: memberSearchRequest) {
                guard let memberSearchRequest else { return }
                await requestQuickSwitcherMembersIfNeeded(for: memberSearchRequest)
            }
    }

    private var searchRequest: QuickSwitcherSearchRequest {
        QuickSwitcherSearchRequest(
            query: query,
            indexRevision: searchIndexRevision,
            contextRevision: contextRevision
        )
    }

    private var memberSearchRequest: QuickSwitcherMemberQuery? {
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
        guard !Task.isCancelled, searchRequest == request else { return }
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

private struct QuickSwitcherResultList: NSViewRepresentable {
    let rows: [QuickSwitcherRowPresentation]
    let selectedResultID: QuickSwitcherResultID?
    let keyboardNavigationActive: Bool
    let presentationID: UInt64
    let reportFrame: @MainActor () -> Void
    let enableMouseFocus: () -> Void
    let focus: (QuickSwitcherResultID) -> Void
    let activate: (QuickSwitcherResult) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let canvas = QuickSwitcherResultCanvas()
        canvas.autoresizingMask = [.width]
        canvas.setAccessibilityIdentifier("quick-switch-results")
        let scrollView = NSScrollView()
        scrollView.documentView = canvas
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        canvas.installViewportObservation(on: scrollView.contentView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let canvas = scrollView.documentView as? QuickSwitcherResultCanvas else { return }
        AppPerformanceSignposts.measureSync("QuickSwitcherViewportUpdate") {
            canvas.update(QuickSwitcherCanvasConfiguration(
                rows: rows,
                selectedResultID: selectedResultID,
                keyboardNavigationActive: keyboardNavigationActive,
                presentationID: presentationID,
                reportFrame: reportFrame,
                enableMouseFocus: enableMouseFocus,
                focus: focus,
                activate: activate
            ))
        }
    }
}

private struct QuickSwitcherCanvasConfiguration {
    let rows: [QuickSwitcherRowPresentation]
    let selectedResultID: QuickSwitcherResultID?
    let keyboardNavigationActive: Bool
    let presentationID: UInt64
    let reportFrame: @MainActor () -> Void
    let enableMouseFocus: () -> Void
    let focus: (QuickSwitcherResultID) -> Void
    let activate: (QuickSwitcherResult) -> Void
}

private final class QuickSwitcherResultCanvas: NSView {
    private static let horizontalInset: CGFloat = 8
    private static let contentInset: CGFloat = 10
    private static let topInset: CGFloat = 8
    private static let spacing: CGFloat = 2
    private static let headingHeight: CGFloat = 28
    private static let resultHeight: CGFloat = 34

    override var isFlipped: Bool { true }

    private var rows: [QuickSwitcherRowPresentation] = []
    private var origins: [CGFloat] = []
    private var selectedResultID: QuickSwitcherResultID?
    private var keyboardNavigationActive = true
    private var enableMouseFocus: () -> Void = {}
    private var focus: (QuickSwitcherResultID) -> Void = { _ in }
    private var activate: (QuickSwitcherResult) -> Void = { _ in }
    private var hoveredIndex: Int?
    private var pressedIndex: Int?
    private var trackingArea: NSTrackingArea?
    private var viewportObserver: NSObjectProtocol?
    private var accessibilityRows: [QuickSwitcherResultID: QuickSwitcherAccessibilityRow] = [:]
    private var images: [URL: CGImage] = [:]
    private var imageTasks: [URL: Task<Void, Never>] = [:]
    private var reportedPresentationID: UInt64?
    private var pendingPresentationID: UInt64?
    private var pendingReport: (@MainActor () -> Void)?

    func installViewportObservation(on clipView: NSClipView) {
        if let viewportObserver { NotificationCenter.default.removeObserver(viewportObserver) }
        viewportObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.viewportDidChange()
            }
        }
    }

    func update(_ configuration: QuickSwitcherCanvasConfiguration) {
        let previousSelection = self.selectedResultID
        rows = configuration.rows
        selectedResultID = configuration.selectedResultID
        keyboardNavigationActive = configuration.keyboardNavigationActive
        enableMouseFocus = configuration.enableMouseFocus
        focus = configuration.focus
        activate = configuration.activate
        rebuildDocument()
        if configuration.keyboardNavigationActive,
           previousSelection != configuration.selectedResultID,
           let selectedResultID = configuration.selectedResultID,
           let index = configuration.rows.firstIndex(where: { $0.id == selectedResultID })
        {
            scrollToVisible(rowRect(at: index))
        }
        if reportedPresentationID != configuration.presentationID {
            pendingPresentationID = configuration.presentationID
            pendingReport = configuration.reportFrame
        }
        reconcileVisibleResources()
        needsDisplay = true
    }

    private func rebuildDocument() {
        var verticalOffset = Self.topInset
        origins = rows.map { row in
            defer {
                verticalOffset += (row.heading == nil ? Self.resultHeight : Self.headingHeight)
                    + Self.spacing
            }
            return verticalOffset
        }
        let height = max(1, verticalOffset + Self.topInset - Self.spacing)
        let width = enclosingScrollView?.contentSize.width ?? frame.width
        frame = CGRect(x: 0, y: 0, width: width, height: height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reconcileVisibleResources()
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let index = selectableIndex(at: convert(event.locationInWindow, from: nil))
        guard index != hoveredIndex else { return }
        hoveredIndex = index
        guard let index else { return }
        if keyboardNavigationActive {
            keyboardNavigationActive = false
            enableMouseFocus()
        }
        focus(rows[index].id)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
    }

    override func mouseDown(with event: NSEvent) {
        pressedIndex = selectableIndex(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let index = selectableIndex(at: convert(event.locationInWindow, from: nil))
        defer { pressedIndex = nil }
        guard index == pressedIndex, let index else { return }
        activate(rows[index].result)
    }

    private func selectableIndex(at point: CGPoint) -> Int? {
        guard point.x >= Self.horizontalInset,
              point.x <= bounds.maxX - Self.horizontalInset
        else { return nil }
        return rows.indices.first { index in
            rows[index].heading == nil && rowRect(at: index).contains(point)
        }
    }

    private func rowRect(at index: Int) -> CGRect {
        CGRect(
            x: Self.horizontalInset,
            y: origins[index],
            width: max(0, bounds.width - Self.horizontalInset * 2),
            height: rows[index].heading == nil ? Self.resultHeight : Self.headingHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setAllowsAntialiasing(true)
        for index in rows.indices where rowRect(at: index).intersects(dirtyRect) {
            draw(row: rows[index], at: index, in: context)
        }
        context.restoreGState()
        guard let presentationID = pendingPresentationID,
              reportedPresentationID != presentationID,
              let report = pendingReport
        else { return }
        reportedPresentationID = presentationID
        pendingPresentationID = nil
        pendingReport = nil
        report()
    }

    private func draw(
        row: QuickSwitcherRowPresentation,
        at index: Int,
        in context: CGContext
    ) {
        let rect = rowRect(at: index)
        if let heading = row.heading {
            drawText(
                heading.uppercased(),
                font: .systemFont(ofSize: 11, weight: .semibold),
                color: .secondaryLabelColor,
                rect: CGRect(x: rect.minX + 10, y: rect.minY + 10, width: rect.width - 20, height: 15)
            )
            return
        }

        if selectedResultID == row.id {
            NSColor.labelColor.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }

        let iconRect = CGRect(x: rect.minX + Self.contentInset, y: rect.minY + 6, width: 22, height: 22)
        drawIcon(for: row, in: iconRect, context: context)

        let trailingFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let trailingWidth = row.trailingDetail.map {
            min(150, ceil(textSize($0, font: trailingFont).width))
        } ?? 0
        let trailingX = rect.maxX - Self.contentInset - trailingWidth
        if let trailing = row.trailingDetail, trailingWidth > 0 {
            drawText(
                trailing,
                font: trailingFont,
                color: .secondaryLabelColor,
                rect: CGRect(x: trailingX, y: rect.minY + 9, width: trailingWidth, height: 18),
                alignment: .right
            )
        }

        let textX = iconRect.maxX + 8
        let remainingWidth = max(0, trailingX - (trailingWidth > 0 ? 10 : 0) - textX)
        let titleFont = NSFont.systemFont(ofSize: 15, weight: .medium)
        let inlineFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let mentionFont = NSFont.systemFont(ofSize: 11, weight: .bold)
        let mentionWidth = row.mentionCount > 0
            ? max(20, ceil(textSize(String(row.mentionCount), font: mentionFont).width) + 12) : 0
        let inlineWidth = row.inlineDetail.map {
            min(max(0, remainingWidth * 0.45), ceil(textSize($0, font: inlineFont).width))
        } ?? 0
        let maximumTitleWidth = max(0, remainingWidth - inlineWidth - mentionWidth
            - (inlineWidth > 0 ? 6 : 0) - (mentionWidth > 0 ? 6 : 0))
        let titleWidth = min(maximumTitleWidth, ceil(textSize(row.title, font: titleFont).width))
        drawText(
            row.title,
            font: titleFont,
            color: .labelColor,
            rect: CGRect(x: textX, y: rect.minY + 8, width: titleWidth, height: 19)
        )
        var horizontalOffset = textX + titleWidth
        if let inline = row.inlineDetail, inlineWidth > 0 {
            horizontalOffset += 6
            drawText(
                inline,
                font: inlineFont,
                color: .secondaryLabelColor,
                rect: CGRect(
                    x: horizontalOffset,
                    y: rect.minY + 10,
                    width: inlineWidth,
                    height: 16
                )
            )
            horizontalOffset += inlineWidth
        }
        if row.mentionCount > 0 {
            horizontalOffset += 6
            let badge = CGRect(
                x: horizontalOffset,
                y: rect.minY + 7,
                width: mentionWidth,
                height: 20
            )
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
            drawText(
                String(row.mentionCount),
                font: mentionFont,
                color: .white,
                rect: badge.offsetBy(dx: 0, dy: 3),
                alignment: .center
            )
        }
    }

    private func drawIcon(
        for row: QuickSwitcherRowPresentation,
        in rect: CGRect,
        context: CGContext
    ) {
        if case .guild = row.result {
            context.saveGState()
            let clipPath = NSBezierPath(
                concentricRoundedRect: rect,
                cornerRadius: QuickSwitcherIconGeometry.serverCornerRadius(
                    iconSize: rect.width
                )
            )
            context.addPath(clipPath.cgPath)
            context.clip()
            context.setFillColor(NSColor.secondaryLabelColor.withAlphaComponent(0.16).cgColor)
            context.fill(rect)
            if let url = row.imageURL {
                if let image = images[url] {
                    drawImage(image, in: rect, context: context)
                }
                context.restoreGState()
                return
            }
            context.restoreGState()
        } else if let url = row.imageURL {
            context.saveGState()
            context.addEllipse(in: rect)
            context.clip()
            if let image = images[url] {
                drawImage(image, in: rect, context: context)
            } else {
                NSColor.controlAccentColor.setFill()
                context.fillEllipse(in: rect)
                drawText(
                    String(row.title.prefix(1)).uppercased(),
                    font: .systemFont(ofSize: 10, weight: .semibold),
                    color: .white,
                    rect: rect.offsetBy(dx: 0, dy: 5),
                    alignment: .center
                )
            }
            context.restoreGState()
            return
        }
        drawSystemImage(row.systemImage, in: rect)
    }

    private func drawImage(
        _ image: CGImage,
        in rect: CGRect,
        context: CGContext
    ) {
        let destination = QuickSwitcherIconGeometry.aspectFillRect(
            imageSize: CGSize(width: image.width, height: image.height),
            in: rect
        )
        context.interpolationQuality = .high
        context.translateBy(
            x: 0,
            y: destination.minY * 2 + destination.height
        )
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: destination)
    }

    private func drawSystemImage(_ name: String, in rect: CGRect) {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 15,
            weight: .medium
        ).applying(
            NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor])
        )
        guard let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration)
        else { return }
        let destination = NativeTimelineSymbolGeometry.opticallyFitted(
            sourceSize: image.size,
            alignmentRect: image.alignmentRect,
            in: rect.insetBy(dx: 2, dy: 2)
        )
        image.draw(
            in: destination,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    private func drawText(
        _ value: String,
        font: NSFont,
        color: NSColor,
        rect: CGRect,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        (value as NSString).draw(
            in: rect,
            withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        )
    }

    private func textSize(_ value: String, font: NSFont) -> CGSize {
        (value as NSString).size(withAttributes: [.font: font])
    }

    private func viewportDidChange() {
        reconcileVisibleResources()
        needsDisplay = true
    }

    private func visibleIndexes() -> [Int] {
        let visible = enclosingScrollView?.documentVisibleRect ?? bounds
        return rows.indices.filter { rowRect(at: $0).intersects(visible) }
    }

    private func reconcileVisibleResources() {
        let visible = visibleIndexes()
        var visibleIDs: Set<QuickSwitcherResultID> = []
        var wantedURLs: Set<URL> = []
        for index in visible {
            let row = rows[index]
            visibleIDs.insert(row.id)
            if let url = row.imageURL {
                wantedURLs.insert(url)
                requestImage(url)
            }
            let proxy = accessibilityRows[row.id] ?? {
                let proxy = QuickSwitcherAccessibilityRow()
                addSubview(proxy)
                accessibilityRows[row.id] = proxy
                return proxy
            }()
            proxy.configure(
                row: row,
                isSelected: selectedResultID == row.id,
                activate: { [weak self] in self?.activate(row.result) }
            )
            proxy.frame = rowRect(at: index)
        }
        for (id, proxy) in accessibilityRows where !visibleIDs.contains(id) {
            proxy.removeFromSuperview()
            accessibilityRows[id] = nil
        }
        setAccessibilityChildren(visible.compactMap { accessibilityRows[rows[$0].id] })
        for (url, task) in imageTasks where !wantedURLs.contains(url) {
            task.cancel()
            imageTasks[url] = nil
        }
        for url in images.keys.filter({ !wantedURLs.contains($0) }) {
            images[url] = nil
        }
    }

    private func requestImage(_ url: URL) {
        guard images[url] == nil, imageTasks[url] == nil else { return }
        imageTasks[url] = Task { [weak self] in
            let image = await SharedDecodedImageLoader.shared.image(
                for: url,
                maximumPixelDimension: 96,
                priority: .visible
            )
            guard !Task.isCancelled, let self else { return }
            imageTasks[url] = nil
            guard let image else { return }
            images[url] = image
            for index in rows.indices where rows[index].imageURL == url {
                setNeedsDisplay(rowRect(at: index))
            }
        }
    }

}

private final class QuickSwitcherAccessibilityRow: NSView {
    private var activation: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(
        row: QuickSwitcherRowPresentation,
        isSelected: Bool,
        activate: @escaping () -> Void
    ) {
        activation = row.heading == nil ? activate : nil
        setAccessibilityElement(true)
        setAccessibilityRole(row.heading == nil ? .button : .staticText)
        setAccessibilityLabel(row.accessibilityLabel)
        setAccessibilityIdentifier(
            row.accessibilityResultIdentifier.map { "quick-switch-result-\($0)" }
        )
        setAccessibilityValue(isSelected ? "Selected" : "")
    }

    override func accessibilityPerformPress() -> Bool {
        guard let activation else { return false }
        activation()
        return true
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
        field.font = .systemFont(ofSize: 19)
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
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
    }
    .padding(.horizontal, 20)
    .padding(.top, 18)
    .padding(.bottom, 14)
}
