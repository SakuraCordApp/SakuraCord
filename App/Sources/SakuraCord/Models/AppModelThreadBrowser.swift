import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    /// Browsing needs View Channel and Read Message History on a text or
    /// announcement channel; that also covers the browser's search field.
    var canBrowseThreadsInSelectedChannel: Bool {
        guard let channel = selectedChannel, channel.guildID != nil,
              let permissions = selectedEffectivePermissions
        else { return false }
        return ThreadActionPolicy.canBrowseThreads(parentKind: channel.kind, permissions: permissions)
    }

    /// The browser's sections limited to threads the user can read: a private
    /// thread needs membership or Manage Threads. Reading the current records
    /// and permissions makes the projection follow membership and role changes.
    var threadBrowserSections: ThreadBrowserSections {
        threadBrowser.sections.filtered(threadBrowserCanRead)
    }

    var threadBrowserSearchResults: [ForumPost] {
        (threadBrowser.search?.results ?? []).filter(threadBrowserCanRead)
    }

    private var threadBrowserCanRead: (ForumPost) -> Bool {
        guard let parentID = threadBrowser.parentID,
              let parent = knownRootChannel(parentID),
              let permissions = effectiveMessagePermissions(in: parent),
              let currentUserID = currentUser?.id
        else { return { _ in false } }
        return { post in
            ThreadActionPolicy(
                thread: post.thread, currentUserID: currentUserID,
                parentPermissions: permissions, parentKind: parent.kind
            ).canRead
        }
    }

    func toggleThreadBrowser() {
        if threadBrowser.isPresented { dismissThreadBrowser() } else { presentThreadBrowser() }
    }

    /// Joined and other active threads come from local state; older threads
    /// load once per connection and are then kept current by live events.
    func presentThreadBrowser() {
        guard sessionState == .workspace, canBrowseThreadsInSelectedChannel,
              let parentID = selectedChannelID
        else { return }
        threadBrowser.present(parentID: parentID)
        let generation = threadBrowser.generation
        let since = threadBrowser.liveSequence
        threadBrowser.recordsTask = startAccountChildTask(account: accountSession()) { model, account in
            let active = await account.provider.activeThreads(in: parentID)
            guard !Task.isCancelled, model.threadBrowser.generation == generation else { return }
            for post in model.threadBrowser.reconciling(active, since: since) where model.threadBrowser.records[post.id] == nil {
                model.threadBrowser.records[post.id] = post
            }
        }
        if threadBrowser.listing?.hasLoadedFirstPage != true {
            loadMoreArchivedThreads()
        }
    }

    func dismissThreadBrowser() {
        threadBrowser.dismiss()
    }

    /// Loads the next page of older threads; also retries a failed page.
    func loadMoreArchivedThreads() {
        guard threadBrowser.isPresented, !threadBrowser.isLoadingArchived,
              let parentID = threadBrowser.parentID
        else { return }
        let listing = threadBrowser.listings[parentID] ?? ThreadBrowserListing()
        guard let offset = listing.nextOffset else { return }
        threadBrowser.listings[parentID] = listing
        threadBrowser.isLoadingArchived = true
        threadBrowser.archivedErrorMessage = nil
        let generation = threadBrowser.generation
        let since = threadBrowser.liveSequence
        threadBrowser.archivedTask = startAccountChildTask(account: accountSession()) { model, account in
            do {
                let page = try await account.provider.threadBrowserPage(
                    in: parentID,
                    query: ThreadBrowserQuery(scope: .archived(offset: offset))
                )
                guard !Task.isCancelled, model.threadBrowser.generation == generation else { return }
                var reconciled = page
                reconciled.posts = model.threadBrowser.reconciling(page.posts, since: since)
                // Records deleted or reopened in flight, whether the provider
                // or live changes here dropped them, moved later records back.
                let stillArchived = Set(reconciled.posts.filter(\.thread.isArchived).map(\.id))
                let departedCount = page.departedCount
                    + page.posts.count { $0.thread.isArchived && !stillArchived.contains($0.id) }
                let isCurrent = model.threadBrowser.listings[parentID, default: ThreadBrowserListing()]
                    .append(reconciled, requestedOffset: offset, departedCount: departedCount)
                // Page records are as new as the provider's; a thread they show
                // archived must leave the active sections.
                for post in reconciled.posts where model.threadBrowser.records[post.id] != nil {
                    model.threadBrowser.records[post.id] = post
                }
                // A thread archived while the page was in flight may be absent
                // from it; apply the current records to the loaded range.
                let records = Array(model.threadBrowser.records.values)
                model.threadBrowser.listings[parentID]?.reconcile(with: records)
                model.threadBrowser.isLoadingArchived = false
                // A loaded thread left while the page was in flight, moving the
                // next offset; request the page at the current one instead.
                // A page that advanced no further is requested again, as the
                // footer's identity did not change.
                if !isCurrent || model.threadBrowser.listings[parentID]?.nextOffset == offset {
                    model.loadMoreArchivedThreads()
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, model.threadBrowser.generation == generation else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                model.threadBrowser.isLoadingArchived = false
                model.threadBrowser.archivedErrorMessage = error.localizedDescription
            }
        }
    }

    /// Runs the name search on submit, as the first-party browser does.
    func submitThreadBrowserSearch() {
        let query = threadBrowser.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard threadBrowser.isPresented, let parentID = threadBrowser.parentID else { return }
        threadBrowser.searchTask?.cancel()
        threadBrowser.searchErrorMessage = nil
        guard !query.isEmpty else {
            threadBrowser.search = nil
            return
        }
        threadBrowser.search = ThreadBrowserSearch(query: query)
        let generation = threadBrowser.generation
        let since = threadBrowser.liveSequence
        threadBrowser.searchTask = startAccountChildTask(account: accountSession()) { model, account in
            do {
                let page = try await account.provider.threadBrowserPage(
                    in: parentID,
                    query: ThreadBrowserQuery(scope: .search(query))
                )
                guard !Task.isCancelled, model.threadBrowser.generation == generation,
                      model.threadBrowser.search?.query == query
                else { return }
                let posts = model.threadBrowser.reconciling(page.posts, since: since)
                model.threadBrowser.search?.results = posts
                model.threadBrowser.search?.hasLoaded = true
                // Results are as new as the provider's records; an active match
                // the browser had not seen joins its sections.
                for post in posts {
                    model.threadBrowser.records[post.id] = post
                }
                let records = Array(model.threadBrowser.records.values)
                model.threadBrowser.listings[parentID]?.reconcile(with: records)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, model.threadBrowser.generation == generation,
                      model.threadBrowser.search?.query == query
                else { return }
                DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                model.threadBrowser.search?.hasLoaded = true
                model.threadBrowser.searchErrorMessage = error.localizedDescription
            }
        }
    }

    func clearThreadBrowserSearch() {
        threadBrowser.searchTask?.cancel()
        threadBrowser.search = nil
        threadBrowser.searchErrorMessage = nil
    }

    /// Opens the thread in full view, as the first-party browser does.
    func openThreadFromBrowser(_ post: ForumPost) {
        dismissThreadBrowser()
        openSidebarThread(post.thread)
    }

    func createThreadFromBrowser() {
        dismissThreadBrowser()
        beginThreadCreation()
    }

    /// A fresh READY starts a new connection: older threads load again when
    /// next needed, and immediately if the browser is open.
    func reloadThreadBrowserAfterReady() {
        threadBrowser.invalidateArchivedListings()
        // Snapshots merge into the records, so a thread the new connection no
        // longer offers, such as a private thread left while offline, would
        // linger. The active records are fetched again below or on presentation.
        threadBrowser.records = [:]
        guard threadBrowser.isPresented else { return }
        presentThreadBrowser()
    }
}
