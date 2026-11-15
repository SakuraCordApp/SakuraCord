import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    func applyGuildSettingsProto(
        _ encoded: String?,
        replacesAllSettings: Bool = false
    ) {
        guard let settings = DiscordSettingsProto.acceptedField(
            in: encoded, replacesAllSettings: replacesAllSettings, dataVersion: &guildLayoutDataVersion,
            field: DiscordSettingsProto.guildFoldersSettings(in:)
        ) else { return }
        guildFoldersSettings = settings
        // A rearrangement that is still waiting to be saved stays on the rail;
        // its save replaces these settings and the response reconciles them.
        guard pendingGuildFoldersSettings == nil else { return }
        applyGuildLayout(DiscordSettingsProto.layout(fromGuildFolders: settings))
    }

    private func applyGuildLayout(
        _ layout: DiscordGuildLayout,
        alreadyPresented presented: [GuildRailItem]? = nil
    ) {
        cachedGuildLayout = layout
        // A current desktop READY can provide every guild ID and its channels
        // while omitting the catalogue metadata required to construct Guilds.
        // Preserve the settings until bootstrap's bounded guild-list fallback
        // has installed that catalogue instead of replacing the cached rail
        // with an empty layout event here.
        guard !cachedGuilds.isEmpty else { return }
        let result = Self.applyingGuildLayout(layout, to: guildsInCurrentRailOrder())
        cachedGuilds = Dictionary(uniqueKeysWithValues: result.guilds.map { ($0.id, $0) })
        guard result.railItems != cachedGuildRailItems || presented != nil else { return }
        cachedGuildRailItems = result.railItems
        guard result.railItems != presented else { return }
        continuation?.yield(.guildLayoutChanged(guilds: result.guilds, railItems: result.railItems))
    }

    public func updateGuildRailLayout(_ items: [GuildRailItem]) async throws {
        guard let saved = guildFoldersSettings else {
            throw ChatProviderError.invalidRequest(
                "Wait for your account settings to finish loading before rearranging servers."
            )
        }
        let updated = DiscordSettingsProto.updatingGuildFolders(
            items,
            in: pendingGuildFoldersSettings ?? saved
        )
        pendingGuildFoldersSettings = updated
        guildFoldersRevision &+= 1
        applyGuildLayout(
            DiscordSettingsProto.layout(fromGuildFolders: updated),
            alreadyPresented: items
        )
        scheduleGuildFoldersFlush()
    }

    /// Saves the newest pending rearrangement. Overlapping saves are never
    /// sent; callers join the active save before checking for newer edits.
    func flushGuildFoldersIfNeeded() async {
        // The request has its own task, so cancelling the timer cannot cancel
        // a save that disconnect must join before clearing the account state.
        guildFoldersFlushTask?.cancel()
        guildFoldersFlushTask = nil
        let generation = guildFoldersGeneration
        while let save = guildFoldersSaveTask {
            await save.value
            guard generation == guildFoldersGeneration else { return }
        }
        guard let settings = pendingGuildFoldersSettings else { return }
        let revision = guildFoldersRevision
        let save = Task {
            await saveGuildFolders(settings, revision: revision, generation: generation)
        }
        guildFoldersSaveTask = save
        await save.value
    }

    private func saveGuildFolders(_ settings: Data, revision: UInt64, generation: UInt64) async {
        defer { guildFoldersSaveTask = nil }
        do {
            let response: UserSettingsProtoDTO = try await request(
                "/users/@me/settings-proto/1",
                method: "PATCH",
                body: ["settings": .string(
                    DiscordSettingsProto.protoLengthDelimitedField(14, settings).base64EncodedString()
                )]
            )
            guard generation == guildFoldersGeneration else { return }
            // Both transports update the same versioned authoritative cache.
            // Keep presentation deferred until the latest local edit is saved.
            applyGuildSettingsProto(response.settings)
            guard guildFoldersRevision == revision else {
                scheduleGuildFoldersFlush()
                return
            }
            pendingGuildFoldersSettings = nil
            applyGuildLayout(
                DiscordSettingsProto.layout(fromGuildFolders: guildFoldersSettings ?? Data())
            )
        } catch {
            guard generation == guildFoldersGeneration else { return }
            guard guildFoldersRevision == revision else {
                scheduleGuildFoldersFlush()
                return
            }
            gatewayLogger.error(
                "Could not save the server order: \(error.localizedDescription, privacy: .public)"
            )
            pendingGuildFoldersSettings = nil
            applyGuildLayout(
                DiscordSettingsProto.layout(fromGuildFolders: guildFoldersSettings ?? Data())
            )
            continuation?.yield(.guildLayoutSaveFailed(reason: error.localizedDescription))
        }
    }

    func finishGuildFoldersEdits() async {
        // A newer edit can be queued while a request is suspended. Drain it
        // before disconnect invalidates the generation or cancels REST tasks.
        repeat {
            await flushGuildFoldersIfNeeded()
        } while pendingGuildFoldersSettings != nil || guildFoldersSaveTask != nil
        resetGuildFoldersState()
    }

    func resetGuildFoldersState() {
        // A same-account READY resets profile editing, but active rail saves
        // still belong to this account. Invalidate them only at teardown.
        guildFoldersGeneration &+= 1
        guildFoldersFlushTask?.cancel()
        guildFoldersFlushTask = nil
        pendingGuildFoldersSettings = nil
        guildFoldersSettings = nil
    }

    /// The first-party settings manager saves ten seconds after the first
    /// unsaved rearrangement, sending whatever the layout is by then.
    private func scheduleGuildFoldersFlush() {
        guard guildFoldersFlushTask == nil else { return }
        guildFoldersFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await self?.flushGuildFoldersIfNeeded()
        }
    }

    func guildsInCurrentRailOrder() -> [Guild] {
        let existingOrder = cachedGuildRailItems.flatMap { item -> [GuildID] in
            switch item {
            case .guild(let id): [id]
            case .folder(let folder): folder.guildIDs
            }
        }
        let existingSet = Set(existingOrder)
        let orderedGuilds =
            existingOrder.compactMap { cachedGuilds[$0] }
                + cachedGuilds.values
                .filter { !existingSet.contains($0.id) }
                .sorted { $0.id.rawValue > $1.id.rawValue }
        return orderedGuilds
    }
}
