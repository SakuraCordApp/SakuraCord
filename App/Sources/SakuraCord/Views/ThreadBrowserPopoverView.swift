import SakuraCordModels
import SwiftUI

/// The Threads browser for the selected text or announcement channel.
struct ThreadBrowserPopoverView: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @FocusState private var isSearchFocused: Bool

    private var reduceMotion: Bool { systemReduceMotion || !model.animates(.overlays) }

    var body: some View {
        @Bindable var browser = model.threadBrowser
        VStack(spacing: 0) {
            header(browser)
            Divider()
            content(browser)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: InterfaceScale.metric(440), height: InterfaceScale.metric(560))
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: model.threadBrowserSections)
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: browser.search)
        .onExitCommand { model.dismissThreadBrowser() }
        .onChange(of: model.selectedChannelID) { model.dismissThreadBrowser() }
        .onDisappear {
            if browser.isPresented { model.dismissThreadBrowser() }
        }
    }

    /// The pickers' inline search header, with Create at its trailing end.
    private func header(_ browser: ThreadBrowserState) -> some View {
        @Bindable var browser = browser
        return HStack(spacing: 0) {
            PickerSearchHeader(text: $browser.searchText, focus: { isSearchFocused = true }, input: {
                TextField("Search Threads", text: $browser.searchText)
                    .textFieldStyle(.plain)
                    .font(.interfaceSystem(size: ChatChromeMetrics.pickerSearchHeaderFontSize))
                    .tint(SakuraCordAccentColor.color)
                    .focused($isSearchFocused)
                    .onSubmit(model.submitThreadBrowserSearch)
                    .accessibilityIdentifier("thread-browser-search")
            })
            if model.canCreateThreadInSelectedChannel {
                HoverActionButton(
                    systemImage: "square.and.pencil", help: "Create Thread",
                    action: model.createThreadFromBrowser
                )
                .padding(.trailing, InterfaceScale.metric(9))
            }
        }
        .onChange(of: browser.searchText) { _, text in
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.clearThreadBrowserSearch()
            }
        }
        .task {
            await Task.yield()
            isSearchFocused = true
        }
    }

    @ViewBuilder
    private func content(_ browser: ThreadBrowserState) -> some View {
        if let search = browser.search {
            searchContent(search, browser: browser)
        } else {
            sectionsContent(browser)
        }
    }

    @ViewBuilder
    private func searchContent(_ search: ThreadBrowserSearch, browser: ThreadBrowserState) -> some View {
        if !search.hasLoaded {
            loading("Searching threads…")
        } else if let error = browser.searchErrorMessage {
            ContentUnavailableView {
                Label("Couldn't Search Threads", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again", action: model.submitThreadBrowserSearch)
            }
        } else if model.threadBrowserSearchResults.isEmpty {
            ContentUnavailableView.search(text: search.query)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    rows(model.threadBrowserSearchResults, showsJoined: true)
                }
                .padding(InterfaceScale.metric(8))
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }

    @ViewBuilder
    private func sectionsContent(_ browser: ThreadBrowserState) -> some View {
        let sections = model.threadBrowserSections
        let listing = browser.listing
        let isLoadingFirstPage = listing?.hasLoadedFirstPage != true && browser.archivedErrorMessage == nil
        if sections.isEmpty, isLoadingFirstPage {
            loading("Loading threads…")
        } else if sections.isEmpty, listing?.hasMore == false {
            ContentUnavailableView(
                "No Threads",
                systemImage: "bubble.left.and.text.bubble.right",
                description: Text("Threads started in this channel appear here.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !sections.joined.isEmpty {
                        sectionHeader("Joined", count: sections.joined.count)
                        rows(sections.joined, showsJoined: false)
                    }
                    if !sections.otherActive.isEmpty {
                        sectionHeader("Other Active", count: sections.otherActive.count)
                        rows(sections.otherActive, showsJoined: false)
                    }
                    sectionHeader("Older", count: nil)
                    rows(sections.older, showsJoined: true)
                    archivedFooter(browser, sections: sections)
                        .padding(.horizontal, InterfaceScale.metric(16))
                        .padding(.vertical, InterfaceScale.metric(8))
                }
                .padding(InterfaceScale.metric(8))
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }

    private func sectionHeader(_ title: String, count: Int?) -> some View {
        Text(count.map { "\(title) — \($0)" } ?? title)
            .font(.interfaceSystem(size: InterfaceTypographyMetrics.interfaceTextSize, weight: .semibold))
            .foregroundStyle(.secondary)
            .opacity(0.7)
            .padding(.horizontal, InterfaceScale.metric(16))
            .padding(.top, InterfaceScale.metric(12))
            .padding(.bottom, InterfaceScale.metric(4))
            .accessibilityAddTraits(.isHeader)
    }

    private func loading(_ title: LocalizedStringKey) -> some View {
        VStack(spacing: InterfaceScale.metric(10)) {
            ProgressView()
            Text(title)
                .font(.interface(.caption))
                .foregroundStyle(.secondary)
        }
    }

    private func rows(_ posts: [ForumPost], showsJoined: Bool) -> some View {
        ForEach(posts) { post in
            ThreadBrowserRow(post: post, showsJoined: showsJoined) { model.openThreadFromBrowser(post) }
        }
    }

    @ViewBuilder
    private func archivedFooter(_ browser: ThreadBrowserState, sections: ThreadBrowserSections) -> some View {
        if let error = browser.archivedErrorMessage {
            HStack {
                Text(error)
                    .font(.interface(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Try Again", action: model.loadMoreArchivedThreads)
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        } else if browser.listing?.hasMore != false {
            // Reaching the end of the list loads the next page.
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .onAppear(perform: model.loadMoreArchivedThreads)
            // A page can add no visible rows; a new identity per offset makes
            // the footer request the next page again.
            .id(browser.listing?.nextOffset)
        } else if sections.older.isEmpty {
            Text("No older threads")
                .font(.interface(.caption))
                .foregroundStyle(.secondary)
        }
    }
}

/// A thread row with the Forward picker's metrics: a leading tile, a medium
/// title over a caption, and a soft rounded hover.
private struct ThreadBrowserRow: View {
    let post: ForumPost
    let showsJoined: Bool
    let open: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: open) {
            HStack(spacing: InterfaceScale.metric(12)) {
                tile
                VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                    HStack(spacing: InterfaceScale.metric(4)) {
                        Text(post.thread.name)
                            .font(.interface(.body).weight(.medium))
                            .lineLimit(1)
                        indicators
                    }
                    Text(subtitle)
                        .font(.interface(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, InterfaceScale.metric(16))
            .frame(height: InterfaceScale.metric(48))
            .contentShape(RoundedRectangle(cornerRadius: InterfaceScale.metric(9), style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: InterfaceScale.metric(9), style: .continuous)
                    .fill(.primary.opacity(isHovered ? 0.075 : 0.001))
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.14), value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isJoined ? "Joined" : "")
    }

    private var isJoined: Bool { post.thread.notificationSettings != nil }

    private var tile: some View {
        ConcentricRectangle(cornerRadius: InterfaceScale.metric(9), style: .continuous)
            .fill(Color.secondary.opacity(0.16))
            .frame(width: InterfaceScale.metric(28), height: InterfaceScale.metric(28))
            .overlay {
                SakuraCordSystemSymbol.swiftUIImage(named: SakuraCordSystemSymbol.thread)
                    .font(.interfaceSystem(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var indicators: some View {
        Group {
            if post.thread.isPrivate {
                Image(systemName: "lock.shield").accessibilityLabel("Private")
            }
            if post.thread.isLocked {
                Image(systemName: "lock.fill").accessibilityLabel("Locked")
            }
            if post.thread.isArchived {
                Image(systemName: "archivebox").accessibilityLabel("Archived")
            }
        }
        .font(.interface(.caption))
        .foregroundStyle(.secondary)
    }

    private var subtitle: String {
        let count = post.thread.messageCount
        var parts = [count == 1 ? "1 message" : "\(count) messages"]
        parts.append("Last active \(post.lastActivityAt.formatted(.relative(presentation: .named)))")
        if showsJoined, isJoined { parts.insert("Joined", at: 0) }
        return parts.joined(separator: " · ")
    }
}
