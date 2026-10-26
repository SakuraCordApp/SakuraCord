import DiscordProtocol
import Foundation
import Observation
import OSLog
import SakuraCordModels

@Observable
@MainActor
final class ProfileEditorState {
    private(set) var scope: ProfileEditingScope = .main
    private(set) var snapshot: ProfileEditingSnapshot?
    private(set) var inventory: ProfileCollectibleInventory?
    private(set) var history: [ProfileAvatarHistoryEntry] = []
    private(set) var changes = ProfileEditChanges()
    private var customStatusChange: ProfileChange<ProfileStatusDraft> = .unchanged
    private var widgetDraft: [ProfileWidget]?
    private var nameStylePalette: [UInt32] = []
    private(set) var draftGeneration = UUID()
    private(set) var widgetResources: ProfileWidgetResources?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var requiresReload = false
    var errorMessage: String?
    var fieldErrors: [String: [String]] = [:]
    var showsUnsavedReminder = false
    var avatarPreviewURL: URL?
    var bannerPreviewURL: URL?
    var selectedServerTag: PrimaryGuildIdentity?

    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var session: AppModelAccountSession?
    @ObservationIgnored let model: AppModel
    @ObservationIgnored private var ownedPreviewURLs: Set<URL> = []
    @ObservationIgnored private var loadedAt: [ProfileEditingScope: ContinuousClock.Instant] = [:]
    private var loadingScope: ProfileEditingScope?
    @ObservationIgnored private var needsExternalRefresh = false
    @ObservationIgnored private let now: () -> ContinuousClock.Instant

    init(model: AppModel, now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.model = model
        self.now = now
        if let prepared = model.preparedProfileEditingSnapshot, prepared.presentation.id == model.currentUser?.id {
            session = model.accountSession()
            snapshot = prepared
            widgetResources = prepared.presentation.widgetResources
            loadedAt[.main] = now()
        }
    }

    deinit {
        for url in ownedPreviewURLs { try? FileManager.default.removeItem(at: url) }
    }

    var hasChanges: Bool { changes.hasChanges || customStatusChange.isChanged }
    var canEditName: Bool {
        guard snapshot != nil else { return false }
        guard let guildID = scope.guildID else { return true }
        guard let basis = model.conversationPermissionBasis(for: guildID) else { return false }
        if basis.guild.isOwnedByCurrentUser == true { return true }
        guard let permissions = basis.resolvedBasePermissions else { return false }
        return permissions & (DiscordPermissionBits.administrator | DiscordPermissionBits.changeNickname) != 0
    }

    var isNitro: Bool { snapshot?.widgetEligibility.hasFullNitro == true }
    var canSave: Bool { snapshot != nil && hasChanges && !isSaving && loadingScope == nil && !requiresReload && bio.utf16.count <= 300 && widgetsAreValid }
    var isResolvingScope: Bool { snapshot == nil || (loadingScope != nil && loadingScope != scope) }
    var canEditWidgets: Bool { snapshot != nil && !isLoading && !isSaving && !requiresReload }
    var canEditPersonalWidget: Bool { canEditWidgets && snapshot?.widgetEligibility.canEditPersonalWidget == true }
    var hasAvatarSelection: Bool {
        switch changes.identity.avatar {
        case .unchanged: snapshot?.identity.avatarHash.value != nil
        case .clear: false
        case .set: true
        }
    }
    var hasBannerSelection: Bool {
        switch changes.metadata.banner {
        case .unchanged: snapshot?.metadata.bannerHash.value != nil
        case .clear: false
        case .set: true
        }
    }
    var hasNameStyleSelection: Bool {
        changes.identity.displayNameStyle.applying(to: snapshot?.identity.displayNameStyle ?? .missing).value != nil
    }

    func selectedCollectibleID(_ kind: ProfileCollectibleKind) -> String? {
        switch kind {
        case .avatarDecoration: changes.identity.decorationSKUID.applying(to: snapshot?.identity.decorationSKUID ?? .missing).value
        case .nameplate: changes.identity.nameplateSKUID.applying(to: snapshot?.identity.nameplateSKUID ?? .missing).value
        case .effect, .frame:
            switch changes.metadata.collectibleSKUIDs {
            case .unchanged: snapshot?.metadata.collectibles.value?.first { $0.type == kind.rawValue }?.skuID
            case .clear: nil
            case let .set(ids): ids.first { id in
                inventory?.item(id: id)?.kind == kind || snapshot?.metadata.collectibles.value?.contains { $0.skuID == id && $0.type == kind.rawValue } == true
            }
            }
        }
    }
    var widgets: [ProfileWidget] { widgetDraft ?? snapshot?.presentation.widgets ?? [] }
    private var widgetsAreValid: Bool {
        widgets.filter { !$0.isDiscardable }.allSatisfy { widget in
            switch widget.content {
            case let .personal(personal):
                !personal.header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && personal.header.utf16.count <= 50
            case let .games(kind, entries): entries.count <= kind.capacity && entries.allSatisfy { ($0.comment?.utf16.count ?? 0) <= 200 }
            case .application, .unrecognized: true
            }
        }
    }
    var preview: UserProfile? {
        snapshot.map {
            var result = ProfileDraftProjection.resolve(
                snapshot: $0, changes: changes, inventory: inventory,
                avatarUploadURL: avatarPreviewURL, bannerUploadURL: bannerPreviewURL, serverTag: selectedServerTag
            )
            result.customStatus = customStatusDraft?.status.displayText
            if let widgetDraft { result.widgets = widgetDraft }
            if let widgetResources { result.widgetResources = widgetResources }
            return result
        }
    }

    /// The account bar's presentation is safe to display while editable fields load.
    /// It is never used as the baseline for a save.
    var displayProfile: UserProfile? {
        if let session, model.isCurrentAccountSession(session), let preview { return preview }
        guard let user = model.currentUser else { return nil }
        return model.profileCache[ProfileCacheKey(userID: user.id, guildID: nil)]
            ?? model.profileCache.first(where: { $0.key.userID == user.id })?.value
            ?? UserProfile(user: user)
    }

    var name: String {
        get { changes.identity.name.applying(to: snapshot?.identity.name ?? .missing).value ?? "" }
        set {
            guard canEditName else { return }
            changes.identity.name = textChange(newValue, original: snapshot?.identity.name)
            fieldErrors["global_name"] = nil
            fieldErrors["nick"] = nil
        }
    }

    var bio: String {
        get { changes.metadata.bio.applying(to: snapshot?.metadata.bio ?? .missing).value ?? "" }
        set { changes.metadata.bio = textChange(newValue, original: snapshot?.metadata.bio); fieldErrors["bio"] = nil }
    }

    var pronouns: String {
        get { changes.metadata.pronouns.applying(to: snapshot?.metadata.pronouns ?? .missing).value ?? "" }
        set { changes.metadata.pronouns = textChange(newValue, original: snapshot?.metadata.pronouns); fieldErrors["pronouns"] = nil }
    }

    func loadIfNeeded(preferCached: Bool = true, refreshExisting: Bool = false) async {
        if let session, model.isCurrentAccountSession(session), snapshot != nil {
            if needsExternalRefresh {
                await refreshIfNeeded()
                return
            }
            guard refreshExisting, !hasChanges, widgetDraft == nil, !isSaving, !requiresReload else { return }
            await load(loadingScope ?? scope, preferCached: preferCached)
            return
        }
        // Join a requested scope that is still loading instead of replacing it.
        await load(loadingScope ?? .main, preferCached: preferCached)
    }

    func invalidateSnapshot() {
        loadedAt = [:]
        needsExternalRefresh = snapshot != nil || loadingScope != nil
    }

    func refreshIfNeeded() async {
        guard needsExternalRefresh, loadingScope == nil, !hasChanges, widgetDraft == nil, !isSaving, !requiresReload else { return }
        needsExternalRefresh = false
        await load(scope, preferCached: false)
    }

    func load(_ requestedScope: ProfileEditingScope = .main, preferCached: Bool = true) async {
        if let previous = session, !model.isCurrentAccountSession(previous) {
            revision = UUID()
            isLoading = false
            loadingScope = nil
            loadedAt = [:]
            needsExternalRefresh = false
            isSaving = false
            inventory = nil
            history = []
            widgetResources = nil
            snapshot = nil
            resetDraft()
        }
        guard !isSaving else { return }
        guard loadingScope != requestedScope else { return }
        if !requiresReload, hasChanges || (requestedScope == scope && widgetDraft != nil) {
            if requestedScope != scope { showsUnsavedReminder = true }
            return
        }
        let requestRevision = UUID()
        let interval = AppPerformanceSignposts.signposter.beginInterval("ProfileEditorLoad", id: AppPerformanceSignposts.signposter.makeSignpostID())
        defer { AppPerformanceSignposts.signposter.endInterval("ProfileEditorLoad", interval) }
        let remainingStatus = customStatusChange
        let remainingChanges = requiresReload && requestedScope == scope ? changes : ProfileEditChanges()
        if !requiresReload || requestedScope != scope { widgetDraft = nil }
        let remainingWidgets = widgetDraft
        revision = requestRevision
        loadingScope = requestedScope
        isLoading = false
        let account = model.accountSession()
        session = account
        changes = remainingChanges
        errorMessage = nil
        fieldErrors = [:]
        defer { finishLoad(revision: requestRevision) }
        do {
            await joinCurrentProfilePrefetch(for: requestedScope)
            guard isCurrent(account, revision: requestRevision) else { return }
            let cached = preferCached && !requiresReload ? try await account.provider.cachedProfileEditingSnapshot(in: requestedScope) : nil
            // A cache lookup does not disable the rendered controls. If an
            // existing responder edited the draft while it was suspended, keep it.
            guard isCurrent(account, revision: requestRevision),
                  customStatusChange == remainingStatus,
                  canReplaceBaseline(changes: remainingChanges, widgets: remainingWidgets, requestedScope: requestedScope) else { return }
            let value: ProfileEditingSnapshot
            if let cached {
                selectLoadedScope(requestedScope)
                adoptBaseline(cached)
                isLoading = false
                // Adopt a preloaded baseline without an immediate duplicate read.
                // Subsequent editor visits refresh after the one-minute reuse window.
                loadedAt[requestedScope] = loadedAt[requestedScope] ?? now()
                if let loaded = loadedAt[requestedScope], loaded.duration(to: now()) < .seconds(60) {
                    AppPerformanceSignposts.signposter.emitEvent("ProfileEditorCacheHit")
                    return
                }
                AppPerformanceSignposts.signposter.emitEvent("ProfileEditorBackgroundRefresh")
                value = try await account.provider.profileEditingSnapshot(in: requestedScope)
            } else {
                isLoading = snapshot == nil || snapshot?.scope != requestedScope
                AppPerformanceSignposts.signposter.emitEvent("ProfileEditorCacheMiss")
                value = try await account.provider.profileEditingSnapshot(in: requestedScope)
            }
            guard isCurrent(account, revision: requestRevision) else { return }
            loadedAt[requestedScope] = now()
            guard changes == remainingChanges, customStatusChange == remainingStatus, !isSaving else { return }
            selectLoadedScope(requestedScope)
            adoptBaseline(value)
            requiresReload = false
            showsUnsavedReminder = false
        } catch {
            guard isCurrent(account, revision: requestRevision) else { return }
            if error is CancellationError { return }
            // A failed refresh must not replace a usable cached profile.
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            errorMessage = error.localizedDescription
        }
    }

    private func adoptBaseline(_ value: ProfileEditingSnapshot) {
        if !changes.identity.displayNameStyle.isChanged { nameStylePalette = [] }
        snapshot = value
        widgetResources = value.presentation.widgetResources
        if value.scope == .main { model.preparedProfileEditingSnapshot = value }
    }

    private func canReplaceBaseline(changes expectedChanges: ProfileEditChanges, widgets expectedWidgets: [ProfileWidget]?, requestedScope: ProfileEditingScope) -> Bool {
        guard changes == expectedChanges, widgetDraft == expectedWidgets else {
            if requestedScope != scope { showsUnsavedReminder = true }
            return false
        }
        return true
    }

    private func joinCurrentProfilePrefetch(for requestedScope: ProfileEditingScope) async {
        // Join the existing account-bar preload instead of racing it with another
        // request when Settings opens during startup.
        guard snapshot == nil, let prefetch = model.currentUserProfilePrefetch,
              requestedScope == .main || prefetch.key.guildID == requestedScope.guildID else { return }
        await prefetch.task.value
    }

    private func finishLoad(revision requestRevision: UUID) {
        guard revision == requestRevision else { return }
        isLoading = false
        loadingScope = nil
        if needsExternalRefresh { Task { await refreshIfNeeded() } }
    }

    private func selectLoadedScope(_ requestedScope: ProfileEditingScope) {
        // Rebuild local editors only when their baseline changes. Resetting the
        // entire canvas before awaiting a cache read adds avoidable layout work.
        if requestedScope != scope || requiresReload { draftGeneration = UUID() }
        scope = requestedScope
    }

    func loadInventory() async throws {
        guard inventory == nil, let session, model.isCurrentAccountSession(session) else { return }
        let requestRevision = revision
        let value = try await session.provider.profileCollectibleInventory()
        guard isCurrent(session, revision: requestRevision) else { throw CancellationError() }
        inventory = value
    }

    func loadHistory() async throws {
        guard let session, model.isCurrentAccountSession(session) else { throw CancellationError() }
        let requestRevision = revision
        let value = try await session.provider.profileAvatarHistory()
        guard isCurrent(session, revision: requestRevision) else { throw CancellationError() }
        history = value
    }

    func refreshWidgetConnections() async {
        guard let session, model.isCurrentAccountSession(session), let userID = snapshot?.presentation.id,
              let resources = widgetResources, !resources.applications.isEmpty else { return }
        let requestRevision = revision
        do {
            let connections = try await session.provider.profileWidgetConnections(applicationIDs: resources.applications.map { $0.connectionApplicationID ?? $0.applicationID })
            let identities = try await session.provider.profileWidgetApplicationIdentities(for: userID)
            guard isCurrent(session, revision: requestRevision) else { return }
            widgetResources?.connections = connections
            widgetResources?.identities = identities
        } catch is CancellationError { return } catch {
            guard isCurrent(session, revision: requestRevision) else { return }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            errorMessage = error.localizedDescription
        }
    }

    func defaultWidgetGames() async throws -> [ProfileGame] {
        guard let session, model.isCurrentAccountSession(session) else { throw CancellationError() }
        let requestRevision = revision
        let games = try await session.provider.defaultProfileWidgetGames()
        guard isCurrent(session, revision: requestRevision) else { throw CancellationError() }
        var resources = widgetResources ?? ProfileWidgetResources()
        let ids = Set(games.map(\.id))
        resources.games.removeAll { ids.contains($0.id) }
        resources.games += games
        widgetResources = resources
        return games
    }

    func searchWidgetGames(query: String) async throws -> [ProfileGame] {
        guard let session, model.isCurrentAccountSession(session) else { throw CancellationError() }
        let requestRevision = revision
        let games = try await session.provider.searchProfileWidgetGames(query: query)
        guard isCurrent(session, revision: requestRevision) else { throw CancellationError() }
        return games
    }

    @discardableResult
    func loadWidgetGames(ids: [String]) async throws -> [ProfileGame] {
        guard let session, model.isCurrentAccountSession(session) else { throw CancellationError() }
        let requestRevision = revision
        let games = try await session.provider.profileWidgetGames(ids: ids)
        guard isCurrent(session, revision: requestRevision) else { throw CancellationError() }
        var resources = widgetResources ?? ProfileWidgetResources()
        let newIDs = Set(games.map(\.id))
        resources.games.removeAll { newIDs.contains($0.id) }
        resources.games += games
        widgetResources = resources
        return games
    }

    func uploadWidgetImage(fileURL: URL, filename: String, contentType: String) async throws -> ProfileWidgetImage {
        guard canEditPersonalWidget, let session, model.isCurrentAccountSession(session) else { throw CancellationError() }
        let requestRevision = revision
        let generation = draftGeneration
        let image = try await session.provider.uploadProfileWidgetImage(fileURL: fileURL, filename: filename, contentType: contentType)
        guard isCurrent(session, revision: requestRevision), draftGeneration == generation else { throw CancellationError() }
        ownedPreviewURLs.insert(fileURL)
        return image
    }

    func deleteHistory(_ entry: ProfileAvatarHistoryEntry) async throws {
        guard let session, model.isCurrentAccountSession(session) else { throw CancellationError() }
        let requestRevision = revision
        try await session.provider.deleteProfileAvatarHistoryEntry(id: entry.id)
        guard isCurrent(session, revision: requestRevision) else { throw CancellationError() }
        history.removeAll { $0.id == entry.id }
    }

    func save() async {
        guard canSave else { return }
        await saveChanges(changes, statusChange: customStatusChange)
    }

    func saveGameWidgetShortcut(gameID: String, kind: ProfileGameWidgetKind) async {
        guard scope == .main, canEditWidgets, !isResolvingScope else { return }
        if let widget = widgets.first(where: { if case let .games(value, _) = $0.content { value == kind } else { false } }),
           case let .games(_, games) = widget.content {
            if games.contains(where: { $0.id == gameID }) { removeWidgetGame(widgetID: widget.id, gameID: gameID) } else {
                guard games.count < kind.capacity else { return }
                addWidgetGame(widgetID: widget.id, gameID: gameID)
            }
        } else { addWidget(ProfileWidget(content: .games(kind, [ProfileWidgetGame(id: gameID)]))) }
        guard widgetsAreValid else {
            errorMessage = "Finish editing the other widgets before saving this game."
            return
        }
        var widgetChanges = ProfileEditChanges()
        widgetChanges.widgets = widgets.filter { !$0.isDiscardable }
        await saveChanges(widgetChanges)
    }

    private func saveChanges(_ submittedChanges: ProfileEditChanges, statusChange: ProfileChange<ProfileStatusDraft> = .unchanged) async {
        guard let session, model.isCurrentAccountSession(session) else { return }
        guard !submittedChanges.identity.name.isChanged || canEditName else {
            errorMessage = "You don’t have permission to change your nickname in this server. Reset your changes to continue."
            return
        }
        let requestRevision = revision
        isSaving = true
        errorMessage = nil
        fieldErrors = [:]
        defer { if revision == requestRevision { isSaving = false } }
        do {
            if submittedChanges.hasChanges {
                try await session.provider.saveProfileChanges(submittedChanges, in: scope) { [weak self] confirmation in
                    await self?.acknowledge(confirmation, account: session, revision: requestRevision)
                }
            }
            guard isCurrent(session, revision: requestRevision), !requiresReload else { return }
            if statusChange.isChanged {
                let status: ProfileCustomStatus? = if case let .set(draft) = statusChange { draft.submission(at: .now) } else { nil }
                let saved = try await session.provider.updateProfileCustomStatus(status)
                guard isCurrent(session, revision: requestRevision) else { return }
                customStatusChange = .unchanged
                receiveCustomStatus(saved)
                if let userID = snapshot?.presentation.id {
                    model.consumeProfileCustomStatusChanged(userID: userID, status: saved)
                }
            }
            showsUnsavedReminder = false
        } catch {
            guard isCurrent(session, revision: requestRevision) else { return }
            errorMessage = error.localizedDescription
            if let validation = error as? ProfileValidationError { fieldErrors = validation.fields }
            if let failure = error as? ProfileSaveFailure {
                fieldErrors = failure.fields
                requiresReload = requiresReload || failure.requiresReload
            }
            if error is URLError || error is CancellationError { requiresReload = true }
        }
    }

    func resetDraft() {
        guard !isSaving else { return }
        draftGeneration = UUID()
        for url in ownedPreviewURLs { try? FileManager.default.removeItem(at: url) }
        ownedPreviewURLs.removeAll()
        changes = ProfileEditChanges()
        customStatusChange = .unchanged
        widgetDraft = nil
        avatarPreviewURL = nil
        nameStylePalette = []
        bannerPreviewURL = nil
        selectedServerTag = nil
        errorMessage = nil
        fieldErrors = [:]
        showsUnsavedReminder = false
    }

    func setStyle(_ style: DisplayNameStyle?) {
        // Keep inactive stops in the editor, while the submitted style contains
        // only the colors used by its effect. This survives picker dismissal.
        let currentColors = displayProfile?.user.displayNameStyle?.colors ?? []
        let palette = currentColors + nameStylePalette.dropFirst(currentColors.count)
        if let style, !style.colors.isEmpty {
            nameStylePalette = style.colors + palette.dropFirst(style.colors.count)
        } else {
            nameStylePalette = []
        }
        changes.identity.displayNameStyle = change(style, original: snapshot?.identity.displayNameStyle)
    }

    func nameStyle(for effect: ProfileNameEffect, darkAppearance: Bool) -> DisplayNameStyle {
        var value = displayProfile?.user.displayNameStyle ?? DisplayNameStyle()
        let palette = value.colors + nameStylePalette.dropFirst(value.colors.count)
        let defaults = DiscordProfileNameStyles.defaultColors(for: effect, darkAppearance: darkAppearance)
        value.colors = effect == .solid && palette.isEmpty ? []
            : defaults.indices.map { palette.indices.contains($0) ? palette[$0] : defaults[$0] }
        value.effectID = effect.rawValue
        return value
    }

    func setServerTag(_ identity: PrimaryGuildIdentity?) {
        let original = snapshot?.serverTag.value
        let originalID = original?.isEnabled.value == true ? original?.guildID.value : nil
        let selectedID = identity?.guildID
        selectedServerTag = identity
        changes.serverTag = selectedID == originalID ? .unchanged : selectedID.map(ProfileChange.set) ?? .clear
    }

    func receiveCustomStatus(_ status: ProfileCustomStatus?) {
        snapshot?.customStatus = status
        snapshot?.presentation.customStatus = status?.displayText
        snapshot?.mainPresentation.customStatus = status?.displayText
    }

    private var savedCustomStatus: ProfileCustomStatus? {
        if model.profileCustomStatusUserID == snapshot?.presentation.id, model.profileCustomStatusUserID != nil {
            return model.profileCustomStatus
        }
        return snapshot?.customStatus
    }

    var customStatusDraft: ProfileStatusDraft? {
        switch customStatusChange {
        case .unchanged: savedCustomStatus.map { ProfileStatusDraft(status: $0) }
        case .clear: nil
        case let .set(draft): draft
        }
    }

    func setCustomStatusDraft(_ value: ProfileStatusDraft?) {
        guard canEditWidgets, !isResolvingScope else { return }
        let value = value.flatMap { $0.status.displayText.isEmpty ? nil : $0 }
        let original = savedCustomStatus.map { ProfileStatusDraft(status: $0) }
        customStatusChange = value == original ? .unchanged : value.map(ProfileChange.set) ?? .clear
    }

    func setWidgets(_ value: [ProfileWidget]) {
        guard canEditWidgets, !isResolvingScope else { return }
        let original = snapshot?.presentation.widgets ?? []
        widgetDraft = value == original ? nil : value
        let saveable = value.filter { !$0.isDiscardable }
        let unchanged = saveable.count == original.count && zip(saveable, original).allSatisfy { $0.hasSameEditableContent(as: $1) }
        changes.widgets = unchanged ? nil : saveable
        fieldErrors["widgets"] = nil
    }

    func addWidget(_ widget: ProfileWidget) {
        if case .personal = widget.content, !canEditPersonalWidget { return }
        setWidgets([widget] + widgets)
    }

    func updateWidget(_ widget: ProfileWidget) {
        guard let index = widgets.firstIndex(where: { $0.id == widget.id }) else { return }
        var updated = widgets
        updated[index] = widget
        setWidgets(updated)
    }

    func removeWidget(id: String) {
        setWidgets(widgets.filter { $0.id != id })
    }

    func addWidgetGame(widgetID: String, gameID: String) {
        guard var widget = widgets.first(where: { $0.id == widgetID }),
              case let .games(kind, games) = widget.content, games.count < kind.capacity,
              !games.contains(where: { $0.id == gameID }) else { return }
        widget.content = .games(kind, [ProfileWidgetGame(id: gameID)] + games)
        updateWidget(widget)
    }

    func updateWidgetGame(widgetID: String, game: ProfileWidgetGame) {
        guard var widget = widgets.first(where: { $0.id == widgetID }),
              case let .games(kind, games) = widget.content,
              let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        var updated = games
        updated[index] = game
        widget.content = .games(kind, updated)
        updateWidget(widget)
    }

    func removeWidgetGame(widgetID: String, gameID: String) {
        guard var widget = widgets.first(where: { $0.id == widgetID }),
              case let .games(kind, games) = widget.content else { return }
        widget.content = .games(kind, games.filter { $0.id != gameID })
        updateWidget(widget)
    }

    func moveWidgetGames(widgetID: String, ids: [String], before destination: String?) {
        guard canEditWidgets, var widget = widgets.first(where: { $0.id == widgetID }),
              case let .games(kind, games) = widget.content else { return }
        let moving = Set(ids)
        guard !moving.isEmpty, destination.map({ !moving.contains($0) }) ?? true,
              destination == nil || games.contains(where: { $0.id == destination }) else { return }
        let moved = games.filter { moving.contains($0.id) }
        guard !moved.isEmpty else { return }
        var remaining = games.filter { !moving.contains($0.id) }
        let insertion = destination.flatMap { id in remaining.firstIndex { $0.id == id } } ?? remaining.endIndex
        remaining.insert(contentsOf: moved, at: insertion)
        widget.content = .games(kind, remaining)
        updateWidget(widget)
    }

    func moveWidget(id: String, to index: Int) {
        var updated = widgets
        guard let oldIndex = updated.firstIndex(where: { $0.id == id }) else { return }
        let moved = updated.remove(at: oldIndex)
        updated.insert(moved, at: min(max(0, index), updated.count))
        setWidgets(updated)
    }

    func moveWidgets(_ ids: [String], before destination: String?) {
        let moving = Set(ids)
        guard !moving.isEmpty, destination.map({ !moving.contains($0) }) ?? true else { return }
        let current = widgets
        guard destination == nil || current.contains(where: { $0.id == destination }) else { return }
        let moved = current.filter { moving.contains($0.id) }
        guard !moved.isEmpty else { return }
        var remaining = current.filter { !moving.contains($0.id) }
        let insertion = destination.flatMap { id in remaining.firstIndex { $0.id == id } } ?? remaining.endIndex
        remaining.insert(contentsOf: moved, at: insertion)
        setWidgets(remaining)
    }

    func setTheme(_ colors: ProfileThemeColors?) {
        changes.metadata.themeColors = change(colors, original: snapshot?.metadata.themeColors)
    }

    func setBannerColor(_ color: UInt32?) {
        changes.metadata.accentColor = change(color, original: snapshot?.metadata.accentColor)
    }

    func setAvatar(_ selection: ProfileAvatarSelection?, previewURL: URL? = nil) {
        releasePreview(avatarPreviewURL)
        if case .upload = selection, let previewURL, previewURL.isFileURL { ownedPreviewURLs.insert(previewURL) }
        changes.identity.avatar = selection.map(ProfileChange.set) ?? (snapshot?.identity.avatarHash.value == nil ? .unchanged : .clear)
        avatarPreviewURL = previewURL
    }

    func setBanner(_ upload: ProfileImageUpload?, previewURL: URL? = nil) {
        releasePreview(bannerPreviewURL)
        if upload != nil, let previewURL, previewURL.isFileURL { ownedPreviewURLs.insert(previewURL) }
        changes.metadata.banner = upload.map(ProfileChange.set) ?? (snapshot?.metadata.bannerHash.value == nil ? .unchanged : .clear)
        bannerPreviewURL = previewURL
    }

    func setCollectible(_ item: ProfileCollectibleItem?, kind: ProfileCollectibleKind) {
        switch kind {
        case .avatarDecoration:
            changes.identity.decorationSKUID = change(item?.id, original: snapshot?.identity.decorationSKUID)
        case .nameplate:
            changes.identity.nameplateSKUID = change(item?.id, original: snapshot?.identity.nameplateSKUID)
        case .effect, .frame:
            var ids: [String]
            switch changes.metadata.collectibleSKUIDs {
            case .unchanged: ids = snapshot?.metadata.collectibles.value?.map(\.skuID) ?? []
            case .clear: ids = []
            case let .set(value): ids = value
            }
            let originalItems = snapshot?.metadata.collectibles.value ?? []
            ids.removeAll { id in inventory?.item(id: id)?.kind == kind || originalItems.contains { $0.skuID == id && $0.type == kind.rawValue } }
            if let item { ids.append(item.id) }
            changes.metadata.collectibleSKUIDs = ids == (snapshot?.metadata.collectibles.value?.map(\.skuID) ?? []) ? .unchanged : .set(ids)
        }
    }

    private func acknowledge(_ confirmation: ProfileSaveConfirmation, account: AppModelAccountSession, revision: UUID) {
        guard isCurrent(account, revision: revision) else { return }
        changes.acknowledge(confirmation.stage)
        if confirmation.stage == .widgets { widgetDraft = nil }
        if let value = confirmation.snapshot {
            snapshot = value
            loadedAt[scope] = now()
            if confirmation.stage == .identity { releasePreview(avatarPreviewURL); avatarPreviewURL = nil }
            if confirmation.stage == .metadata { releasePreview(bannerPreviewURL); bannerPreviewURL = nil }
        } else {
            requiresReload = true
        }
    }

    private func releasePreview(_ url: URL?) {
        guard let url, ownedPreviewURLs.remove(url) != nil else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func isCurrent(_ account: AppModelAccountSession, revision: UUID) -> Bool {
        self.revision == revision && model.isCurrentAccountSession(account)
    }

    private func textChange(_ value: String, original: ProfileStoredValue<String>?) -> ProfileChange<String> {
        if value == (original?.value ?? "") { return .unchanged }
        return .set(value)
    }

    private func change<Value: Hashable & Sendable>(_ value: Value?, original: ProfileStoredValue<Value>?) -> ProfileChange<Value> {
        if value == original?.value { return .unchanged }
        return value.map(ProfileChange.set) ?? .clear
    }
}
