import SakuraCordModels
import SwiftUI

struct ForwardMessageOverlay: View {
    let model: AppModel
    let message: Message
    @Environment(\.windowModalContext) private var dismiss
    @State private var query = ""
    @State private var context = ""
    @State private var selectedDestinationIDs: [ForwardDestinationID] = []
    @State private var searchPinnedDestinationIDs: [ForwardDestinationID] = []
    @State private var searchIndex: ForwardDestinationSearchPolicy.Index?
    @State private var searchIndexRevision = 0
    @State private var displayedDestinations: [ForwardDestination] = []
    @State private var unqueriedDestinations: [ForwardDestination] = []
    @State private var destinationScrollPosition: ForwardDestinationID?
    @FocusState private var focus: Field?

    private enum Field { case search, context }

    private struct SearchRequest: Hashable {
        let query: String
        let pinnedDestinationIDs: [ForwardDestinationID]
        let indexRevision: Int
    }

    private func rebuildSearchIndex() async {
        // Frecency settings improve ranking, but destination discovery itself
        // is entirely local. Never hold the first picker population behind the
        // authenticated enrichment request; its revision will rebuild this
        // index when it settles.
        if !model.hasLoadedDiscordEmojiSettings {
            Task { @MainActor in
                await model.loadDiscordEmojiSettings()
            }
        }
        guard !Task.isCancelled else { return }
        guard let index = await ForwardDestinationSearchIndexCache.shared.prepare(
            for: model,
            priority: .userInitiated
        ), !Task.isCancelled
        else { return }
        searchIndex = index
        searchIndexRevision &+= 1
    }

    private func refreshDisplayedDestinations() async {
        guard let searchIndex else {
            displayedDestinations = []
            return
        }
        let query = query
        let pins = searchPinnedDestinationIDs
        let indexRevision = searchIndexRevision
        let history = model.forwardDestinationHistory
        let originChannelID = message.channelID
        let searchTask = Task.detached(priority: .userInitiated) {
            searchIndex.results(
                query: query,
                recentChannelIDs: history,
                pinnedDestinationIDs: pins,
                originChannelID: originChannelID
            )
        }
        let results = await withTaskCancellationHandler {
            await searchTask.value
        } onCancel: {
            searchTask.cancel()
        }
        guard !Task.isCancelled else { return }
        guard self.query == query,
              searchPinnedDestinationIDs == pins,
              searchIndexRevision == indexRevision
        else { return }

        var validatedResults = validateContentPermissions(in: results)
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validatedResults = ForwardDestinationSelectionPolicy.mergingPinnedDestinations(
                pins,
                into: validatedResults,
                fallbacks: displayedDestinations + unqueriedDestinations
            )
            unqueriedDestinations = validatedResults
        }
        displayedDestinations = validatedResults
    }

    private func validateContentPermissions(
        in results: [ForwardDestination]
    ) -> [ForwardDestination] {
        let needsContentPermissionValidation = !message.attachments.isEmpty
            || !message.embeds.isEmpty
            || !message.stickers.isEmpty
            || message.flags.contains(.voiceMessage)
        guard needsContentPermissionValidation else {
            return results
        }
        return results.map { destination in
            var destination = destination
            let permissionChannel: Channel? = switch destination.kind {
            case .channel(let channel): channel
            case .thread(_, let parent): parent
            case .user: nil
            }
            if let permissionChannel {
                destination.unavailableReason = model.forwardUnavailableReason(
                    for: message,
                    destination: permissionChannel
                )
            }
            return destination
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            destinationList
            Divider()
            composer
        }
        .windowModalSize(width: ForwardPickerLayoutMetrics.width, height: ForwardPickerLayoutMetrics.height)
        // Discord's UserSearchContextManager stays subscribed to UserStore,
        // GuildMemberStore, ChannelStore, and supplemental READY updates while
        // the modal is open. Rebuild only when those source stores advance;
        // typing changes the lightweight result task below and never rebuilds
        // the index.
        .task(id: model.forwardSearchSourceRevision) {
            await rebuildSearchIndex()
        }
        .task(id: SearchRequest(
            query: query,
            pinnedDestinationIDs: searchPinnedDestinationIDs,
            indexRevision: searchIndexRevision
        )) {
            await refreshDisplayedDestinations()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Forward To")
    }

    /// The pickers' inline search header; Cancel and Escape close the picker.
    private var header: some View {
        PickerSearchHeader(text: $query, focus: { focus = .search }, input: {
            TextField(searchPlaceholder, text: $query)
                .textFieldStyle(.plain)
                .font(.interfaceSystem(size: ChatChromeMetrics.pickerSearchHeaderFontSize))
                .tint(SakuraCordAccentColor.color)
                .focused($focus, equals: .search)
        })
        .accessibilityIdentifier("forward-search")
        .task {
            await Task.yield()
            focus = .search
        }
    }

    private var searchPlaceholder: String {
        selectedDestinationIDs.count >= ForwardDestinationSearchPolicy.maximumSelections
            ? "Maximum 5 places at once"
            : "Forward to…"
    }

    private var destinationList: some View {
        ScrollView {
            // Discord caps each result category at 20, so the picker has at most
            // 80 rows. Keeping that bounded list eager avoids SwiftUI's lazy
            // collection invalidation trap when accessibility scroll actions
            // race a live search-index update.
            VStack(spacing: InterfaceScale.metric(2)) {
                ForEach(displayedDestinations) { destination in
                    ForwardDestinationRow(
                        destination: destination,
                        isSelected: selectedDestinationIDs.contains(destination.id)
                    ) {
                        toggle(destination.id)
                    }
                }
            }
            .padding(InterfaceScale.metric(8))
            .scrollTargetLayout()
        }
        .scrollPosition(id: $destinationScrollPosition, anchor: .top)
        .overlay {
            if searchIndex == nil {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading conversations")
            } else if displayedDestinations.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    /// The forwarded message and its optional note share one row 8 points
    /// inside the panel; the footer capsules sit 12 points inside it.
    private var composer: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
                ForwardedMessagePreview(model: model, message: message)
                TextField("Add an optional message…", text: $context, axis: .vertical)
                    .textFieldStyle(.plain)
                    .tint(SakuraCordAccentColor.color)
                    .lineLimit(1 ... 3)
                    .focused($focus, equals: .context)
                    .padding(.horizontal, InterfaceScale.metric(8))
                    .padding(.vertical, InterfaceScale.metric(6))
            }
            .modifier(ModalRowBackground(isHighlighted: focus == .context) { focus = .context })
            .padding(InterfaceScale.metric(8))
            if let error = model.forwardingErrorMessage {
                Text(error)
                    .font(.interface(.callout))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, InterfaceScale.metric(20))
                    .padding(.bottom, InterfaceScale.metric(4))
            }
            Divider()
            HStack {
                ModalGlassButton(symbol: "xmark", label: "Cancel") { dismiss?() }
                Spacer(minLength: InterfaceScale.metric(16))
                ModalGlassButton(
                    symbol: "arrowshape.turn.up.right.fill",
                    label: selectedDestinationIDs.count > 1 ? "Send (\(selectedDestinationIDs.count))" : "Send",
                    primary: true,
                    isLoading: model.isForwardingMessages
                ) {
                    let destinations = selectedDestinationIDs
                    Task { await model.forward(message, to: destinations, context: context) }
                }
                .disabled(selectedDestinationIDs.isEmpty || model.isForwardingMessages)
            }
            .padding(InterfaceScale.metric(12))
        }
    }

    private func toggle(_ destinationID: ForwardDestinationID) {
        let selectedFromSearch = !query.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
        let updatedPins = ForwardDestinationSelectionPolicy.searchPins(
            afterSelecting: destinationID,
            query: query,
            selectedDestinationIDs: selectedDestinationIDs,
            existing: searchPinnedDestinationIDs
        )
        if selectedFromSearch {
            displayedDestinations = ForwardDestinationSelectionPolicy
                .mergingPinnedDestinations(
                updatedPins,
                into: unqueriedDestinations,
                fallbacks: displayedDestinations
            )
            unqueriedDestinations = displayedDestinations
            searchPinnedDestinationIDs = updatedPins
            query = ""
            destinationScrollPosition = destinationID
        }
        if let index = selectedDestinationIDs.firstIndex(of: destinationID) {
            selectedDestinationIDs.remove(at: index)
            return
        }
        guard selectedDestinationIDs.count < ForwardDestinationSearchPolicy.maximumSelections else {
            NSSound.beep()
            return
        }
        selectedDestinationIDs.insert(destinationID, at: 0)
    }
}
