import Foundation
import SakuraCordModels

public extension DiscordRESTProvider {
    func currentStatus() async -> PresenceStatus {
        presenceStatus
    }

    func currentActivities() async -> [String: OutgoingActivityPayload] {
        activeActivities
    }

    func updateActivity(_ activity: OutgoingActivityPayload?, sourceID: String) async throws {
        presenceGeneration &+= 1
        if let activity {
            activeActivities[sourceID] = activity
        } else {
            activeActivities.removeValue(forKey: sourceID)
        }
        await sendPresenceIfChanged()
    }

    func clearActivities(sourceID: String? = nil) async throws {
        presenceGeneration &+= 1
        if let sourceID {
            activeActivities.removeValue(forKey: sourceID)
        } else {
            activeActivities.removeAll()
        }
        await sendPresenceIfChanged()
    }

    // Official stable622805 module827827 and module594061 `markDirty`.
    /// Applies a pick at once and saves it; only this first save reports a failure.
    func updateStatus(_ status: PresenceStatus) async throws {
        guard currentUser != nil else { throw ChatProviderError.unauthenticated }
        guard profileStatusSettings != nil else {
            throw ChatProviderError.invalidRequest("Wait for your account settings to finish loading before changing your status.")
        }
        let edit = beginStatusEdit(status)
        await sendPresenceIfChanged()
        try await savePendingStatusEdit(edit, userInitiated: true)
    }
}

// Official stable622805 module617617 `editInfo.protoToSave` and `offlineEditDataVersion`.
/// The one unsaved account-status pick; only a save of this `id` ends it.
struct PendingStatusEdit: Equatable, Sendable {
    let id: UInt64
    var status: PresenceStatus
    /// Sent as `required_data_version`.
    var requiredDataVersion: UInt32?
}

extension DiscordRESTProvider {
    /// Retains authoritative StatusSettings and adopts their status unless an
    /// edit is pending; an absent or unknown status is online.
    func adoptStatusSettings(_ settings: Data) {
        profileStatusSettings = settings
        guard pendingStatusEdit == nil else { return }
        setPresenceStatus(DiscordSettingsProto.presenceStatus(in: settings) ?? .online)
    }

    /// Gives the current user's member the account status. Member caches can
    /// hold an older one, so every published or returned member list uses this.
    func membersWithCurrentStatus(_ members: [Member]) -> [Member] {
        guard let userID = currentUser?.id else { return members }
        return members.map { member in
            guard member.id == userID, member.status != presenceStatus else { return member }
            var member = member
            member.status = presenceStatus
            return member
        }
    }

    func publishMembers(guildID: GuildID, members: [Member], groups: [GuildMemberListGroup]) {
        publishThreadMembers(guildID: guildID)
        discardInaccessibleMemberLists(guildID: guildID)
        if let selected = selectedMemberListID[guildID],
           !isMemberListAccessible(guildID: guildID, memberListID: selected) {
            continuation?.yield(.membersChanged(guildID: guildID, members: [], groups: []))
            return
        }
        continuation?.yield(.membersChanged(guildID: guildID, members: membersWithCurrentStatus(members), groups: groups))
    }

    func setPresenceStatus(_ status: PresenceStatus) {
        guard presenceStatus != status else { return }
        presenceGeneration &+= 1
        presenceStatus = status
        continuation?.yield(.currentUserStatusChanged(status))
    }

    func activeActivitiesList() -> [OutgoingActivityPayload] {
        activeActivities.values.sorted { lhs, rhs in
            if lhs.priorityRank != rhs.priorityRank {
                return lhs.priorityRank < rhs.priorityRank
            }
            return lhs.name < rhs.name
        }
    }

    // Official stable622805 PresenceUpdater.
    /// Sends a changed presence, at most five per 20 seconds, deferring the latest.
    func sendPresenceIfChanged() async {
        deferredPresenceTask?.cancel()
        deferredPresenceTask = nil
        let activities = activeActivitiesList()
        let statusChanged = presenceStatus != lastSentPresenceStatus
        let activitiesChanged = activities != lastSentActivities
        guard gatewayReady, statusChanged || activitiesChanged else { return }
        let now = Date.now
        presenceSendWindowEnds.removeAll { $0 <= now }
        let budgetReopens = presenceSendWindowEnds.count >= 5 ? presenceSendWindowEnds.first ?? now : now
        let reopens = max(budgetReopens, gatewayOpcodeRateLimitDates[3] ?? now)
        if reopens > now {
            deferredPresenceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(reopens.timeIntervalSince(now)))
                guard !Task.isCancelled else { return }
                await self?.sendDeferredPresence()
            }
            return
        }
        do {
            try await sendPresence()
        } catch {
            gatewayLogger.error("Presence update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Runs from the deferred task, which must not cancel itself.
    private func sendDeferredPresence() async {
        deferredPresenceTask = nil
        await sendPresenceIfChanged()
    }

    private struct ExternalAssetDTO: Decodable {
        let url: String
        let externalAssetPath: String

        enum CodingKeys: String, CodingKey {
            case url
            case externalAssetPath = "external_asset_path"
        }
    }

    private func resolveExternalAsset(url: String, applicationID: String) async -> String? {
        if url.hasPrefix("https://i.scdn.co/image/") {
            let hash = String(url.dropFirst("https://i.scdn.co/image/".count))
            return "spotify:\(hash)"
        }
        if let cached = externalAssetCache[url] {
            return cached
        }
        let targetAppID = applicationID.allSatisfy(\.isNumber) && !applicationID.isEmpty
            ? applicationID
            : "1247654840780460125"
        do {
            let body: [String: JSONValue] = [
                "urls": .array([.string(url)])
            ]
            let dtos: [ExternalAssetDTO] = try await request(
                "/applications/\(targetAppID)/external-assets",
                method: "POST",
                body: body
            )
            if let first = dtos.first {
                let rawPath = first.externalAssetPath
                let path: String = if rawPath.hasPrefix("mp:") {
                    rawPath
                } else if rawPath.hasPrefix("/") {
                    "mp:\(rawPath.dropFirst())"
                } else {
                    "mp:\(rawPath)"
                }
                if externalAssetCache[url] == nil {
                    if externalAssetCacheKeys.count >= 128 {
                        let oldest = externalAssetCacheKeys.removeFirst()
                        externalAssetCache.removeValue(forKey: oldest)
                    }
                    externalAssetCacheKeys.append(url)
                }
                externalAssetCache[url] = path
                return path
            }
        } catch {
            gatewayLogger.debug("External asset resolution for \(url) failed: \(error.localizedDescription)")
        }
        return nil
    }

    private func buildGatewayActivityDictionaries(
        activities: [OutgoingActivityPayload]
    ) async -> [[String: Any]] {
        var activityDictionaries: [[String: Any]] = []
        for activity in activities {
            var dict = activity.gatewayDictionary
            let appID = activity.applicationId ?? ""
            if var ast = dict["assets"] as? [String: Any] {
                if let largeImage = ast["large_image"] as? String,
                   largeImage.hasPrefix("http://") || largeImage.hasPrefix("https://") {
                    if let proxied = await resolveExternalAsset(url: largeImage, applicationID: appID) {
                        ast["large_image"] = proxied
                    }
                }
                if let smallImage = ast["small_image"] as? String,
                   smallImage.hasPrefix("http://") || smallImage.hasPrefix("https://") {
                    if let proxied = await resolveExternalAsset(url: smallImage, applicationID: appID) {
                        ast["small_image"] = proxied
                    }
                }
                dict["assets"] = ast
            }
            activityDictionaries.append(dict)
        }
        return activityDictionaries
    }

    func sendPresence() async throws {
        let currentGeneration = presenceGeneration
        let status = presenceStatus
        let activities = activeActivitiesList()

        let activityDictionaries = await buildGatewayActivityDictionaries(activities: activities)

        guard currentGeneration == presenceGeneration else { return }
        let statusChanged = status != lastSentPresenceStatus
        let activitiesChanged = activities != lastSentActivities
        guard statusChanged || activitiesChanged else { return }

        let now = Date.now
        presenceSendWindowEnds.removeAll { $0 <= now }
        let budgetReopens = presenceSendWindowEnds.count >= 5 ? presenceSendWindowEnds.first ?? now : now
        let reopens = max(budgetReopens, gatewayOpcodeRateLimitDates[3] ?? now)
        if reopens > now {
            deferredPresenceTask?.cancel()
            deferredPresenceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(reopens.timeIntervalSince(now)))
                guard !Task.isCancelled else { return }
                await self?.sendDeferredPresence()
            }
            return
        }

        presenceSendWindowEnds.append(now.addingTimeInterval(20))
        lastSentPresenceStatus = status
        lastSentActivities = activities
        do {
            try await sendGateway([
                "op": 3,
                "d": [
                    "since": 0,
                    "activities": activityDictionaries,
                    "status": status.rawValue,
                    "afk": false,
                ] as [String: Any],
            ])
        } catch {
            if lastSentPresenceStatus == status { lastSentPresenceStatus = nil }
            if lastSentActivities == activities { lastSentActivities = nil }
            throw error
        }
    }
}

// MARK: - Pending status edit

extension DiscordRESTProvider {
    /// Makes `status` the pending edit. On an open connection it needs no data
    /// version; offline it keeps the replaced edit's, as the official merge does.
    func beginStatusEdit(_ status: PresenceStatus) -> PendingStatusEdit {
        statusEditGeneration &+= 1
        let edit = PendingStatusEdit(
            id: statusEditGeneration, status: status,
            requiredDataVersion: gatewayReady ? nil : pendingStatusEdit?.requiredDataVersion ?? settingsDataVersion
        )
        pendingStatusEdit = edit
        cancelStatusEditSave()
        persistPendingStatusEdit()
        setPresenceStatus(status)
        return edit
    }

    /// Saves `edit` unless it was replaced or already saved. A new Gateway
    /// session meanwhile leaves it pending for that session's save.
    func savePendingStatusEdit(_ edit: PendingStatusEdit, userInitiated: Bool) async throws {
        do {
            _ = try await saveStatusSettings(pendingEdit: edit.id, userInitiated: userInitiated)
        } catch is CancellationError {}
    }

    /// Ends the pending edit only if it is still the one identified by `id`.
    func endPendingStatusEdit(_ id: UInt64?) {
        guard let id, pendingStatusEdit?.id == id else { return }
        pendingStatusEdit = nil
        persistPendingStatusEdit()
    }

    // Official stable622805 module617617 CONNECTION_CLOSED.
    /// Records the data version on a pending edit and stops its scheduled save.
    func pendingStatusEditConnectionClosed() {
        statusSettingsConnectionGeneration &+= 1
        cancelStatusEditSave()
        guard var edit = pendingStatusEdit, edit.requiredDataVersion == nil, let settingsDataVersion else { return }
        edit.requiredDataVersion = settingsDataVersion
        pendingStatusEdit = edit
        persistPendingStatusEdit()
    }

    /// Runs before READY's settings are applied, so its status never shows
    /// before a pending edit. An edit READY matches is done; one without a
    /// data version takes READY's.
    func reconcilePendingStatusEdit(readySettings encoded: String?) {
        guard var edit = pendingStatusEdit else { return }
        if let root = encoded.flatMap({ Data(base64Encoded: $0) }) {
            let accountStatus = DiscordSettingsProto.statusSettings(in: root)
                .flatMap(DiscordSettingsProto.presenceStatus(in:)) ?? .online
            guard accountStatus != edit.status else {
                endPendingStatusEdit(edit.id)
                return
            }
            if edit.requiredDataVersion == nil, let version = DiscordSettingsProto.dataVersion(in: root) {
                edit.requiredDataVersion = version
                pendingStatusEdit = edit
                persistPendingStatusEdit()
            }
        }
        setPresenceStatus(edit.status)
    }

    // Official stable622805 module594061 `scheduleSaveFromOfflineEdit`.
    /// Schedules one silent save 5 to 10 seconds after READY or RESUMED.
    func schedulePendingStatusEditSave() {
        flushedStatusEditID = nil
        guard pendingStatusEdit != nil, profileStatusSettings != nil else { return cancelStatusEditSave() }
        scheduleStatusEditSave(after: .milliseconds(5000 + Int.random(in: 0 ..< 5000)))
    }

    // Official stable622805 APP_STATE_UPDATE flush.
    /// Saves a pending edit when the app loses focus, once per edit per session start.
    func flushPendingStatusEdit() {
        guard let edit = pendingStatusEdit, edit.id != flushedStatusEditID,
              gatewayReady, profileStatusSettings != nil else { return }
        flushedStatusEditID = edit.id
        scheduleStatusEditSave(after: .zero)
    }

    private func scheduleStatusEditSave(after delay: Duration) {
        cancelStatusEditSave()
        let token = statusEditSaveToken
        statusEditSaveTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            await self?.runStatusEditSave(token)
        }
    }

    /// Stops a scheduled save that has not started; a running save finishes.
    func cancelStatusEditSave() {
        statusEditSaveToken &+= 1
        statusEditSaveTask?.cancel()
        statusEditSaveTask = nil
    }

    func runStatusEditSave(_ token: UInt64) async {
        guard token == statusEditSaveToken else { return }
        statusEditSaveTask = nil
        guard let edit = pendingStatusEdit else { return }
        do {
            try await savePendingStatusEdit(edit, userInitiated: false)
        } catch {
            gatewayLogger.error("Pending status save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Pending status edit persistence

// Official stable622805 module617617 persists offline edits in its store cache.
/// The pending edit survives relaunch under `dev.sakuracord.pending-status-edit.<account>`.
extension DiscordRESTProvider {
    private static func pendingStatusEditKey(_ accountID: String) -> String {
        "dev.sakuracord.pending-status-edit.\(accountID)"
    }

    /// Earlier releases' device-only status, read once at launch.
    private static func legacyPresenceKey(_ accountID: String) -> String {
        "dev.sakuracord.presence.\(accountID)"
    }

    /// Restores a saved edit. A device-only Invisible from earlier releases
    /// becomes an edit without a data version; any other device value is dropped.
    func loadPendingStatusEdit() {
        guard let accountID else { return }
        let defaults = DiscordLocalPreferences.defaults
        let stored = defaults.dictionary(forKey: Self.pendingStatusEditKey(accountID))
        let legacy = defaults.string(forKey: Self.legacyPresenceKey(accountID)) == PresenceStatus.invisible.rawValue
            ? PresenceStatus.invisible : nil
        defaults.removeObject(forKey: Self.legacyPresenceKey(accountID))
        pendingStatusEdit = ((stored?["status"] as? String).flatMap(PresenceStatus.init(rawValue:)) ?? legacy)
            .map { status in
                statusEditGeneration &+= 1
                return PendingStatusEdit(
                    id: statusEditGeneration, status: status,
                    requiredDataVersion: (stored?["requiredDataVersion"] as? NSNumber)?.uint32Value
                )
            }
        persistPendingStatusEdit()
    }

    /// Stores the edit with its recorded data version, or the latest one seen.
    func persistPendingStatusEdit() {
        guard let accountID else { return }
        let key = Self.pendingStatusEditKey(accountID)
        guard let edit = pendingStatusEdit else {
            DiscordLocalPreferences.defaults.removeObject(forKey: key)
            return
        }
        var value: [String: Any] = ["status": edit.status.rawValue]
        if let version = edit.requiredDataVersion ?? settingsDataVersion { value["requiredDataVersion"] = Int(version) }
        DiscordLocalPreferences.defaults.set(value, forKey: key)
    }

    // Official stable622805 module617617 LOGOUT.
    /// Drops an account's unsaved edit when the account is removed.
    public static func removePendingStatusEdit(accountID: String) {
        DiscordLocalPreferences.defaults.removeObject(forKey: pendingStatusEditKey(accountID))
        DiscordLocalPreferences.defaults.removeObject(forKey: legacyPresenceKey(accountID))
    }
}
