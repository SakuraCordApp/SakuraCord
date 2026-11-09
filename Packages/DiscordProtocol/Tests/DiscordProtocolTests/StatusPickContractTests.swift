@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing

/// Shares the serialized suite that owns `DirectMessageURLProtocol`'s state.
extension DirectMessageProviderContractTests {
    @Test func `status pick sends presence then one sibling preserving settings write and ignores its echo`() async throws {
        DirectMessageURLProtocol.reset()
        // StatusSettings: invisible, empty show_current_game, created-at, and a
        // custom status, all of which a pick other than status must preserve.
        let base = try #require(Data(base64Encoded: "CgsKCWludmlzaWJsZRoAKgcIxf7s0YU0"))
        let retained = try #require(DiscordSettingsProto.statusSettings(
            in: DiscordSettingsProto.updatingCustomStatus(ProfileCustomStatus(text: "Gardening"), in: base)
        ))
        let session = try await readyStatusPickProvider(
            settings: DiscordSettingsProto.protoLengthDelimitedField(11, retained)
        )
        defer { DiscordRESTProvider.removePendingStatusEdit(accountID: session.accountID) }
        let provider = session.provider, socket = session.socket, events = session.events
        #expect(await provider.currentStatus() == .invisible)

        try await provider.updateStatus(.dnd)

        #expect(await socket.sentOpcodes() == [2, 4, 3, 41, 40, 3])
        let presence = try #require(await socket.sentPayload(opcode: 3))
        let presenceObject = try #require(JSONSerialization.jsonObject(with: presence) as? [String: Any])
        #expect((presenceObject["d"] as? [String: Any])?["status"] as? String == "dnd")
        #expect(DirectMessageURLProtocol.requests.count == 1)
        let request = try #require(DirectMessageURLProtocol.requests.first)
        #expect(request.method == "PATCH")
        #expect(request.encodedPath == "/api/v9/users/@me/settings-proto/1")
        #expect(request.hadAuthorization)
        #expect(request.body?.keys.sorted() == ["settings"])
        // The official presence updater sends opcode 3 before the settings save.
        #expect(try #require(await socket.sentInstants.last) < request.receivedAt)
        let body = try #require(Data(base64Encoded: request.body?["settings"] as? String ?? ""))
        let rootFields = protoFieldNumbers(body)
        #expect(rootFields == [11])
        let written = try #require(DiscordSettingsProto.statusSettings(in: body))
        #expect(DiscordSettingsProto.presenceStatus(in: written) == .dnd)
        #expect(DiscordSettingsProto.customStatus(in: written)?.text == "Gardening")
        #expect(protoFieldNumbers(written) == [1, 2, 3, 5])
        #expect(protoField(5, in: written) != protoField(5, in: retained))
        #expect(protoField(3, in: written) == protoField(3, in: retained))

        // The Gateway echo of the saved settings changes nothing and sends nothing.
        await provider.receiveGatewayDispatchForTesting(name: "USER_SETTINGS_PROTO_UPDATE", data: .object([
            "settings": .object(["type": .number(1), "proto": .string(request.body?["settings"] as? String ?? "")]),
            "partial": .bool(true),
        ]))
        #expect(await provider.currentStatus() == .dnd)
        #expect(await socket.sentPayloadCount(opcode: 3) == 2)
        #expect(DirectMessageURLProtocol.requests.count == 1)

        // Re-picking the same status keeps its original creation time.
        try await provider.updateStatus(.dnd)
        #expect(await socket.sentPayloadCount(opcode: 3) == 2)
        #expect(DirectMessageURLProtocol.requests.count == 2)
        let repeated = try #require(Data(base64Encoded: DirectMessageURLProtocol.requests.last?.body?["settings"] as? String ?? ""))
        #expect(protoField(5, in: try #require(DiscordSettingsProto.statusSettings(in: repeated))) == protoField(5, in: written))
        await provider.disconnect()
        #expect(await statusEvents(events) == [.dnd])
    }

    @Test func `account status follows settings updates and republishes only changed presence`() async throws {
        DirectMessageURLProtocol.reset()
        let session = try await readyStatusPickProvider(settings: statusSettingsFixture("dnd"))
        defer { DiscordRESTProvider.removePendingStatusEdit(accountID: session.accountID) }
        let provider = session.provider, socket = session.socket

        await settingsUpdate(provider, statusSettingsFixture("idle"))
        #expect(await provider.currentStatus() == .idle)
        #expect(await presenceStatuses(socket) == ["dnd", "idle"])

        // Unchanged or unrelated settings send nothing.
        await settingsUpdate(provider, DiscordSettingsProto.protoLengthDelimitedField(13, Data()))
        await settingsUpdate(provider, statusSettingsFixture("idle"), partial: false)
        #expect(await presenceStatuses(socket) == ["dnd", "idle"])

        // As in the official client, an absent or unknown status is online.
        let customStatusOnly = DiscordSettingsProto.updatingCustomStatus(ProfileCustomStatus(text: "away"), in: Data())
        await settingsUpdate(provider, customStatusOnly)
        #expect(await provider.currentStatus() == .online)
        await settingsUpdate(provider, statusSettingsFixture("unknown"), partial: false)
        await settingsUpdate(provider, Data(), partial: false)
        #expect(await presenceStatuses(socket) == ["dnd", "idle", "online"])
        #expect(DirectMessageURLProtocol.requests.isEmpty)
        await provider.disconnect()
        #expect(await statusEvents(session.events) == [.dnd, .idle, .online])
    }

    @Test func `presence beyond five sends in twenty seconds defers only the latest value`() async throws {
        DirectMessageURLProtocol.reset()
        let session = try await readyStatusPickProvider(settings: statusSettingsFixture("dnd"))
        defer { DiscordRESTProvider.removePendingStatusEdit(accountID: session.accountID) }
        let provider = session.provider, socket = session.socket
        // The post-READY presence and four changes fill the official window.
        for status in ["idle", "online", "idle", "online", "idle", "dnd"] {
            await settingsUpdate(provider, statusSettingsFixture(status))
        }
        #expect(await presenceStatuses(socket) == ["dnd", "idle", "online", "idle", "online"])
        #expect(await provider.hasDeferredPresenceForTesting())

        await provider.reopenPresenceSendWindowForTesting()
        #expect(await presenceStatuses(socket).last == "dnd")
        #expect(await socket.sentPayloadCount(opcode: 3) == 6)
        #expect(await provider.hasDeferredPresenceForTesting() == false)
        await provider.disconnect()
    }

    @Test func `queued status writes save only the newest pick and merge it into custom status writes`() async throws {
        DirectMessageURLProtocol.reset()
        let session = try await readyStatusPickProvider(settings: statusSettingsFixture("online"))
        defer { DiscordRESTProvider.removePendingStatusEdit(accountID: session.accountID) }
        let provider = session.provider, socket = session.socket
        await provider.holdStatusSettingsSaveForTesting()
        let custom = Task { try await provider.updateProfileCustomStatus(ProfileCustomStatus(text: "Gardening")) }
        #expect(await eventually { await provider.statusSettingsSaveWaiterCountForTesting() == 1 })
        let first = Task { try await provider.updateStatus(.idle) }
        #expect(await eventually { await provider.statusSettingsSaveWaiterCountForTesting() == 2 })
        let second = Task { try await provider.updateStatus(.dnd) }
        #expect(await eventually { await provider.statusSettingsSaveWaiterCountForTesting() == 3 })

        // A settings update that is not the pick's own save cannot replace it.
        await settingsUpdate(provider, statusSettingsFixture("online"))
        #expect(await provider.currentStatus() == .dnd)

        await provider.releaseStatusSettingsSaveForTesting()
        _ = try await custom.value
        try await first.value
        try await second.value
        let written = try DirectMessageURLProtocol.requests.map { try writtenStatusSettings($0) }
        // Whichever writer runs first carries the pending pick; the replaced
        // pick is never written.
        #expect((1 ... 2).contains(written.count))
        #expect(written.allSatisfy { DiscordSettingsProto.presenceStatus(in: $0) == .dnd })
        #expect(written.last.flatMap(DiscordSettingsProto.customStatus(in:))?.text == "Gardening")
        #expect(await provider.currentStatus() == .dnd)
        #expect(await provider.pendingStatusEditForTesting() == nil)
        #expect(await socket.sentPayloadCount(opcode: 3) == 3)
        await provider.disconnect()
    }

    @Test(arguments: [false, true])
    func `a failed status save stays pending across relaunch and is saved once per READY`(outOfDate: Bool) async throws {
        DirectMessageURLProtocol.reset()
        let first = try await readyStatusPickProvider(settings: statusSettingsFixture("online", dataVersion: 7))
        defer { DiscordRESTProvider.removePendingStatusEdit(accountID: first.accountID) }
        DirectMessageURLProtocol.settingsReplies = [.init(500, "{}")]
        await #expect(throws: ChatProviderError.self) { try await first.provider.updateStatus(.dnd) }
        // The pick keeps its status without a retry, and a later settings
        // update neither replaces it nor saves it again.
        await settingsUpdate(first.provider, statusSettingsFixture("idle", dataVersion: 8))
        #expect(await first.provider.currentStatus() == .dnd)
        #expect(await first.provider.runScheduledStatusEditSaveForTesting() == false)
        #expect(DirectMessageURLProtocol.requests.count == 1)
        // Closing records the current data version with the persisted edit.
        await first.provider.disconnect()

        let second = try await readyStatusPickProvider(
            settings: statusSettingsFixture("idle", dataVersion: 8), accountID: first.accountID, restoresPendingEdit: true
        )
        let provider = second.provider
        #expect(await presenceStatuses(second.socket) == ["dnd"])
        #expect(DirectMessageURLProtocol.requests.count == 1)

        // Each READY schedules one silent attempt; a failure waits for the next.
        DirectMessageURLProtocol.settingsReplies = [.init(500, "{}")]
        #expect(await provider.runScheduledStatusEditSaveForTesting())
        #expect(await provider.runScheduledStatusEditSaveForTesting() == false)
        #expect(DirectMessageURLProtocol.requests.count == 2)
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": .object(["id": .string("2"), "username": .string("maya")]),
            "guilds": .array([]),
            "user_settings_proto": .string(statusSettingsFixture("idle", dataVersion: 8).base64EncodedString()),
        ]))
        if outOfDate {
            DirectMessageURLProtocol.settingsReplies = [.init(200, try settingsResponse(statusSettingsFixture("online", dataVersion: 9), outOfDate: true))]
        }
        #expect(await provider.runScheduledStatusEditSaveForTesting())
        #expect(DirectMessageURLProtocol.requests.count == 3)
        for request in DirectMessageURLProtocol.requests.dropFirst() {
            #expect(request.body?["required_data_version"] as? Int == 8)
            #expect(DiscordSettingsProto.presenceStatus(in: try writtenStatusSettings(request)) == .dnd)
        }
        // Success and out_of_date both end the edit; out_of_date adopts the server's settings.
        #expect(await provider.pendingStatusEditForTesting() == nil)
        #expect(UserDefaults.standard.object(forKey: "dev.sakuracord.pending-status-edit.\(first.accountID)") == nil)
        #expect(await provider.currentStatus() == (outOfDate ? .online : .dnd))
        #expect(await presenceStatuses(second.socket) == (outOfDate ? ["dnd", "online"] : ["dnd"]))
        await provider.disconnect()
        #expect(await statusEvents(second.events) == (outOfDate ? [.dnd, .online] : [.dnd]))
    }

    @Test func `invalid settings data discards the pick and reloads the server settings`() async throws {
        DirectMessageURLProtocol.reset()
        let session = try await readyStatusPickProvider(settings: statusSettingsFixture("online", dataVersion: 3))
        defer { DiscordRESTProvider.removePendingStatusEdit(accountID: session.accountID) }
        DirectMessageURLProtocol.settingsReplies = [
            .init(400, #"{"code":50105,"message":"Invalid user settings data"}"#),
            .init(200, try settingsResponse(statusSettingsFixture("idle", dataVersion: 4))),
        ]
        await #expect(throws: ChatProviderError.self) { try await session.provider.updateStatus(.dnd) }
        #expect(DirectMessageURLProtocol.requests.map { "\($0.method) \($0.path)" } == [
            "PATCH /api/v9/users/@me/settings-proto/1", "GET /api/v9/users/@me/settings-proto/1",
        ])
        #expect(await session.provider.pendingStatusEditForTesting() == nil)
        #expect(await session.provider.currentStatus() == .idle)
        #expect(await presenceStatuses(session.socket) == ["online", "dnd", "online", "idle"])
        #expect(await !session.provider.requestSafetyCircuitIsOpen)
        // The Inbox writer handles 50105 the same way.
        DirectMessageURLProtocol.settingsReplies = [
            .init(400, #"{"code":50105}"#), .init(200, try settingsResponse(statusSettingsFixture("idle", dataVersion: 5))),
        ]
        await #expect(throws: ChatProviderError.self) { try await session.provider.updateInboxTab(.unread) }
        #expect(DirectMessageURLProtocol.requests.suffix(2).map(\.method) == ["PATCH", "GET"])
        #expect(await !session.provider.requestSafetyCircuitIsOpen)
        await session.provider.disconnect()
    }

    @Test func `a newer pick replaces a failed one`() async throws {
        DirectMessageURLProtocol.reset()
        let session = try await readyStatusPickProvider(settings: statusSettingsFixture("online", dataVersion: 5))
        defer { DiscordRESTProvider.removePendingStatusEdit(accountID: session.accountID) }
        let provider = session.provider
        DirectMessageURLProtocol.settingsReplies = [.init(500, "{}")]
        await #expect(throws: ChatProviderError.self) { try await provider.updateStatus(.idle) }
        try await provider.updateStatus(.dnd)
        #expect(DirectMessageURLProtocol.requests.count == 2)
        let request = try #require(DirectMessageURLProtocol.requests.last)
        #expect(request.body?.keys.sorted() == ["settings"])
        #expect(DiscordSettingsProto.presenceStatus(in: try writtenStatusSettings(request)) == .dnd)
        #expect(await provider.pendingStatusEditForTesting() == nil)
        // The replaced pick is not saved by a later session.
        await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
            "user": .object(["id": .string("2"), "username": .string("maya")]),
            "guilds": .array([]),
            "user_settings_proto": .string(statusSettingsFixture("dnd", dataVersion: 6).base64EncodedString()),
        ]))
        #expect(await provider.runScheduledStatusEditSaveForTesting() == false)
        #expect(await provider.currentStatus() == .dnd)
        await provider.disconnect()
    }

    @Test func `a live pick drops a stale data version but a write carrying the offline edit keeps it`() async throws {
        DirectMessageURLProtocol.reset()
        let accountID = "status-stale-\(UUID().uuidString)"
        let key = "dev.sakuracord.pending-status-edit.\(accountID)"
        defer { DiscordRESTProvider.removePendingStatusEdit(accountID: accountID) }
        UserDefaults.standard.set(["status": "idle", "requiredDataVersion": 5], forKey: key)
        let session = try await readyStatusPickProvider(
            settings: statusSettingsFixture("online", dataVersion: 6), accountID: accountID, restoresPendingEdit: true
        )
        let provider = session.provider
        #expect(await provider.pendingStatusEditForTesting()?.requiredDataVersion == 5)

        // A pick on an open connection replaces the offline edit and its version.
        DirectMessageURLProtocol.settingsReplies = [.init(500, "{}")]
        await #expect(throws: ChatProviderError.self) { try await provider.updateStatus(.dnd) }
        #expect(DirectMessageURLProtocol.requests.last?.body?.keys.sorted() == ["settings"])
        #expect(await provider.pendingStatusEditForTesting()?.requiredDataVersion == nil)

        // A custom status carrying an offline edit keeps its version, and a
        // discarded user save is reported with the server's settings kept.
        UserDefaults.standard.set(["status": "invisible", "requiredDataVersion": 5], forKey: key)
        await provider.loadPendingStatusEdit()
        DirectMessageURLProtocol.settingsReplies = [
            .init(200, try settingsResponse(statusSettingsFixture("online", dataVersion: 7), outOfDate: true)),
        ]
        await #expect(throws: ChatProviderError.self) {
            try await provider.updateProfileCustomStatus(ProfileCustomStatus(text: "Gardening"))
        }
        let custom = try #require(DirectMessageURLProtocol.requests.last)
        #expect(custom.body?["required_data_version"] as? Int == 5)
        #expect(DiscordSettingsProto.presenceStatus(in: try writtenStatusSettings(custom)) == .invisible)
        #expect(DirectMessageURLProtocol.requests.count == 2)
        #expect(await provider.pendingStatusEditForTesting() == nil)
        #expect(await provider.currentStatus() == .online)
        await provider.disconnect()
    }

    @Test func `a resumed session saves a pending status edit once`() async throws {
        DirectMessageURLProtocol.reset()
        let session = try await readyStatusPickProvider(settings: statusSettingsFixture("online", dataVersion: 4))
        defer { DiscordRESTProvider.removePendingStatusEdit(accountID: session.accountID) }
        let provider = session.provider
        DirectMessageURLProtocol.settingsReplies = [.init(500, "{}")]
        await #expect(throws: ChatProviderError.self) { try await provider.updateStatus(.dnd) }
        await provider.handleGatewaySessionEvent(.stateChanged(.resuming))
        await provider.receiveGatewayDispatchForTesting(name: "RESUMED", data: .object([:]))
        #expect(await provider.runScheduledStatusEditSaveForTesting())
        #expect(await provider.runScheduledStatusEditSaveForTesting() == false)
        #expect(DirectMessageURLProtocol.requests.count == 2)
        let request = try #require(DirectMessageURLProtocol.requests.last)
        #expect(request.body?["required_data_version"] as? Int == 4)
        #expect(DiscordSettingsProto.presenceStatus(in: try writtenStatusSettings(request)) == .dnd)
        #expect(await provider.pendingStatusEditForTesting() == nil)
        await provider.disconnect()
    }

    @Test func `republished member lists carry the adopted account status`() async throws {
        DirectMessageURLProtocol.reset()
        let session = try await readyStatusPickProvider(settings: statusSettingsFixture("dnd"))
        defer { DiscordRESTProvider.removePendingStatusEdit(accountID: session.accountID) }
        let provider = session.provider
        let me = try #require(await provider.currentUser)
        let guildID = GuildID(rawValue: 10)
        // The member cache keeps whatever status the member was built with.
        await provider.publishMemberChange(Member(user: me, roleName: "Member", status: .online), guildID: guildID)
        await settingsUpdate(provider, statusSettingsFixture("idle"))
        let other = User(id: UserID(rawValue: 77), username: "other", displayName: "Other")
        await provider.publishMemberChange(Member(user: other, roleName: "Member", status: .online), guildID: guildID)
        await provider.disconnect()
        var selfStatuses: [PresenceStatus?] = []
        for await event in session.events {
            if case let .membersChanged(_, members, _) = event { selfStatuses.append(members.first { $0.id == me.id }?.status) }
        }
        #expect(selfStatuses == [.dnd, .idle])
    }

    @Test func `losing focus flushes a failed pick once`() async throws {
        DirectMessageURLProtocol.reset()
        let session = try await readyStatusPickProvider(settings: statusSettingsFixture("online", dataVersion: 1))
        defer { DiscordRESTProvider.removePendingStatusEdit(accountID: session.accountID) }
        let provider = session.provider
        DirectMessageURLProtocol.settingsReplies = [.init(500, "{}"), .init(500, "{}")]
        await #expect(throws: ChatProviderError.self) { try await provider.updateStatus(.dnd) }

        await provider.holdStatusSettingsSaveForTesting()
        await provider.updateClientAppState(isFocused: false)
        #expect(await eventually { await provider.statusSettingsSaveWaiterCountForTesting() == 1 })
        await provider.updateClientAppState(isFocused: true)
        await provider.updateClientAppState(isFocused: false)
        #expect(await provider.runScheduledStatusEditSaveForTesting() == false)
        await provider.releaseStatusSettingsSaveForTesting()
        #expect(await eventually { DirectMessageURLProtocol.requests.count == 2 })

        // The failed flush leaves the pick pending without another attempt.
        await provider.updateClientAppState(isFocused: true)
        await provider.updateClientAppState(isFocused: false)
        #expect(await provider.runScheduledStatusEditSaveForTesting() == false)
        #expect(await provider.pendingStatusEditForTesting()?.status == .dnd)
        #expect(DirectMessageURLProtocol.requests.count == 2)
        await provider.disconnect()
    }

    @Test(arguments: zip(["invisible", "online"], ["online", "invisible"]))
    func `only a device-only Invisible from earlier releases is carried over`(
        deviceStatus: String, accountStatus: String
    ) async throws {
        DirectMessageURLProtocol.reset()
        let accountID = "status-carry-over-\(UUID().uuidString)"
        let legacyKey = "dev.sakuracord.presence.\(accountID)"
        UserDefaults.standard.set(deviceStatus, forKey: legacyKey)
        defer {
            UserDefaults.standard.removeObject(forKey: legacyKey)
            DiscordRESTProvider.removePendingStatusEdit(accountID: accountID)
        }
        let session = try await readyStatusPickProvider(
            settings: statusSettingsFixture(accountStatus, dataVersion: 11), accountID: accountID, restoresPendingEdit: true
        )
        let provider = session.provider
        #expect(UserDefaults.standard.object(forKey: legacyKey) == nil)
        // Invisible wins either way and is never exposed as online first.
        #expect(await presenceStatuses(session.socket) == ["invisible"])
        let carried = deviceStatus == "invisible"
        #expect(await provider.runScheduledStatusEditSaveForTesting() == carried)
        #expect(DirectMessageURLProtocol.requests.count == (carried ? 1 : 0))
        if let request = DirectMessageURLProtocol.requests.first {
            #expect(request.body?["required_data_version"] as? Int == 11)
            #expect(DiscordSettingsProto.presenceStatus(in: try writtenStatusSettings(request)) == .invisible)
        }
        #expect(await provider.pendingStatusEditForTesting() == nil)
        #expect(await provider.currentStatus() == .invisible)
        await provider.disconnect()
        #expect(await statusEvents(session.events).isEmpty)
    }

    @Test(arguments: [false, true])
    func `a late settings save preserves newer Gateway state and a newer pending pick`(replaced: Bool) async throws {
        DirectMessageURLProtocol.reset()
        let session = try await readyStatusPickProvider(settings: statusSettingsFixture("online", dataVersion: 10))
        defer { DiscordRESTProvider.removePendingStatusEdit(accountID: session.accountID) }
        let provider = session.provider
        let savedEdit = await provider.beginStatusEdit(.idle)
        let latest = statusSettingsFixture("dnd", dataVersion: 12)
        await settingsUpdate(provider, latest)
        if replaced { _ = await provider.beginStatusEdit(.invisible) }
        let stale = statusSettingsFixture("idle", dataVersion: 11)
        let accepted = await provider.acceptSavedStatusSettings(
            try #require(DiscordSettingsProto.statusSettings(in: stale)), root: stale, editID: savedEdit.id
        )
        #expect(DiscordSettingsProto.presenceStatus(in: accepted) == .dnd)
        #expect(await provider.currentStatus() == (replaced ? .invisible : .dnd))
        #expect(await provider.pendingStatusEditForTesting()?.status == (replaced ? .invisible : nil))
        // A late Gateway echo cannot roll the authoritative settings back either.
        await settingsUpdate(provider, stale)
        await provider.pendingStatusEditConnectionClosed()
        if replaced { #expect(await provider.pendingStatusEditForTesting()?.requiredDataVersion == 12) }
        #expect(await provider.currentStatus() == (replaced ? .invisible : .dnd))
        await provider.disconnect()
    }

    @Test func `an unrelated newer partial update does not suppress a saved status`() async throws {
        DirectMessageURLProtocol.reset()
        let session = try await readyStatusPickProvider(settings: statusSettingsFixture("online", dataVersion: 10))
        defer { DiscordRESTProvider.removePendingStatusEdit(accountID: session.accountID) }
        let provider = session.provider
        let edit = await provider.beginStatusEdit(.idle)
        let unrelated = DiscordSettingsProto.protoLengthDelimitedField(1, DiscordSettingsProto.protoVarintField(3, 12))
        await settingsUpdate(provider, unrelated)
        let response = statusSettingsFixture("idle", dataVersion: 11)
        _ = await provider.acceptSavedStatusSettings(
            try #require(DiscordSettingsProto.statusSettings(in: response)), root: response, editID: edit.id
        )
        #expect(await provider.currentStatus() == .idle)
        #expect(await provider.pendingStatusEditForTesting() == nil)
        let next = await provider.beginStatusEdit(.dnd)
        await provider.pendingStatusEditConnectionClosed()
        #expect(await provider.pendingStatusEditForTesting()?.requiredDataVersion == 12)
        await provider.endPendingStatusEdit(next.id)
        await provider.disconnect()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func `a rate limited status PATCH cannot dispatch its old body after Gateway reconnect`(resumed: Bool, cooldownAlreadyExists: Bool) async throws {
        DirectMessageURLProtocol.reset()
        let session = try await readyStatusPickProvider(settings: statusSettingsFixture("idle", dataVersion: 10))
        defer { DiscordRESTProvider.removePendingStatusEdit(accountID: session.accountID) }
        let provider = session.provider
        DirectMessageURLProtocol.settingsReplies = [.init(429, #"{"retry_after":5.0,"global":false}"#)]
        let generation = await provider.profileEditingGeneration
        if cooldownAlreadyExists {
            await #expect(throws: ChatProviderError.self) {
                _ = try await provider.patchUserSettings(
                    ["settings": .string(statusSettingsFixture("idle", dataVersion: 10).base64EncodedString())],
                    retriesRateLimit: false
                )
            }
        }
        let save = Task { try await provider.updateStatus(.online) }
        // Observe the actual transport's 429 backoff before reconnecting. This
        // is not an assumed sleep before delivering READY.
        let waiting = await eventually {
            let limited = await provider.routeRateLimitDates.values.contains { $0 > .now }
            let saving = await provider.profileStatusSaveID != nil
            return limited && saving
        }
        guard waiting else {
            save.cancel()
            _ = await save.result
            await provider.disconnect()
            try #require(waiting, "The first actual PATCH must enter 429 backoff")
            return
        }
        #expect(DirectMessageURLProtocol.requests.count == 1)
        #expect(DirectMessageURLProtocol.requests.first?.body?["required_data_version"] == nil)
        await provider.handleGatewaySessionEvent(.stateChanged(.backingOff))
        #expect(await provider.pendingStatusEditForTesting()?.requiredDataVersion == 10)
        if resumed {
            await settingsUpdate(provider, statusSettingsFixture("dnd", dataVersion: 12))
            await provider.receiveGatewayDispatchForTesting(name: "RESUMED", data: .object([:]))
            #expect(await provider.profileEditingGeneration == generation)
        } else {
            await provider.receiveGatewayDispatchForTesting(name: "READY", data: .object([
                "session_id": .string("replacement-status-session"),
                "user": .object(["id": .string("2"), "username": .string("maya")]),
                "guilds": .array([]),
                "user_settings_proto": .string(statusSettingsFixture("dnd", dataVersion: 12).base64EncodedString()),
            ]))
            #expect(await provider.profileEditingGeneration > generation)
        }
        // Exclude the new generation's separately scheduled versioned save;
        // only the old transport retry is under examination.
        await provider.cancelStatusEditSave()
        _ = await save.result
        let writes = DirectMessageURLProtocol.requests.filter { $0.method == "PATCH" }
        #expect(writes.count == 1, "A status body prepared before reconnect must not be transmitted afterward")
        #expect(DiscordSettingsProto.presenceStatus(in: await provider.profileStatusSettings ?? Data()) == .dnd)
        await provider.disconnect()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func `a delayed rejected save recovery preserves newer fields and accepts untouched fields`(changesInbox: Bool) async throws {
        DirectMessageURLProtocol.reset()
        let old = statusSettingsFixture("online", dataVersion: 10)
            + DiscordInboxSettingsProto.updatingTab(.mentions, in: Data())
        let session = try await readyStatusPickProvider(settings: statusSettingsFixture("online", dataVersion: 9))
        defer { DiscordRESTProvider.removePendingStatusEdit(accountID: session.accountID) }
        let provider = session.provider
        let gate = StatusRecoveryResponseGate()
        defer { gate.release() }
        DirectMessageURLProtocol.settingsReplies = [
            .init(400, #"{"code":50105,"message":"Invalid user settings data"}"#),
            .init(200, try settingsResponse(old), gate: gate),
        ]
        let save = Task { try await provider.updateStatus(.dnd) }
        let started = await eventually { gate.didCapture }
        guard started else {
            gate.release(); save.cancel(); _ = await save.result; await provider.disconnect()
            try #require(started, "Recovery GET must be held before delivering the newer update")
            return
        }
        var newer = DiscordSettingsProto.protoLengthDelimitedField(1, DiscordSettingsProto.protoVarintField(3, 11))
        newer += DiscordSettingsProto.protoLengthDelimitedField(13, DiscordSettingsProto.protoVarintField(2, 1))
        // GuildFolders.guild_positions: fixed64 guild ID42.
        newer += DiscordSettingsProto.protoLengthDelimitedField(14, Data([17, 42, 0, 0, 0, 0, 0, 0, 0]))
        if changesInbox {
            newer += DiscordInboxSettingsProto.updatingTab(.unread, in: Data())
            newer += DiscordInboxSettingsProto.updatingCollapsed(true, channelID: ChannelID(rawValue: 42), guildID: GuildID(rawValue: 10), in: Data())
        }
        await settingsUpdate(provider, newer)
        #expect(await provider.profileDeveloperMode)
        #expect(await provider.cachedGuildLayout?.guildPositions == [GuildID(rawValue: 42)])
        gate.release()
        _ = await save.result
        let tab = DiscordInboxSettingsProto.settings(in: await provider.inboxSettingsProto ?? Data()).tab
        #expect(tab == (changesInbox ? .unread : .mentions), "Only fields actually changed by the newer partial update supersede the full snapshot")
        #expect(await provider.profileDeveloperMode, "A stale full GET must not clear newer appearance settings")
        #expect(await provider.cachedGuildLayout?.guildPositions == [GuildID(rawValue: 42)])
        let inbox = DiscordInboxSettingsProto.settings(in: await provider.inboxSettingsProto ?? Data())
        #expect(inbox.collapsedChannelIDs.contains(ChannelID(rawValue: 42)) == changesInbox)
        // A genuinely newer full snapshot still clears omitted fields.
        await settingsUpdate(provider, statusSettingsFixture("online", dataVersion: 12), partial: false)
        #expect(await !provider.profileDeveloperMode)
        #expect(await provider.cachedGuildLayout?.guildPositions.isEmpty == true)
        #expect(DiscordInboxSettingsProto.settings(in: await provider.inboxSettingsProto ?? Data()).collapsedChannelIDs.isEmpty)
        await provider.disconnect()
    }

    @Test(.timeLimit(.minutes(1)))
    func `a rejected status with failed recovery does not keep broadcasting the rejected pick`() async throws {
        DirectMessageURLProtocol.reset()
        let session = try await readyStatusPickProvider(settings: statusSettingsFixture("online", dataVersion: 10))
        defer { DiscordRESTProvider.removePendingStatusEdit(accountID: session.accountID) }
        let provider = session.provider
        DirectMessageURLProtocol.settingsReplies = [
            .init(400, #"{"code":50105,"message":"Invalid user settings data"}"#),
            .init(500, "{}"), .init(500, "{}"),
        ]
        await #expect(throws: ChatProviderError.self) { try await provider.updateStatus(.dnd) }
        let status = await provider.currentStatus()
        #expect(await provider.pendingStatusEditForTesting() == nil)
        #expect(status == .online, "A rejected pick must not remain the active presence while claiming saved state was restored")
        #expect(await presenceStatuses(session.socket).last == "online")
        await provider.disconnect()
    }

    private func settingsResponse(_ settings: Data, outOfDate: Bool = false) throws -> String {
        var object: [String: Any] = ["settings": settings.base64EncodedString()]
        if outOfDate { object["out_of_date"] = true }
        return try #require(String(bytes: JSONSerialization.data(withJSONObject: object), encoding: .utf8))
    }

    private func settingsUpdate(_ provider: DiscordRESTProvider, _ proto: Data, partial: Bool = true) async {
        await provider.receiveGatewayDispatchForTesting(name: "USER_SETTINGS_PROTO_UPDATE", data: .object([
            "settings": .object(["type": .number(1), "proto": .string(proto.base64EncodedString())]),
            "partial": .bool(partial),
        ]))
    }

    private func writtenStatusSettings(_ request: CapturedDirectMessageRequest) throws -> Data {
        let body = try #require(Data(base64Encoded: request.body?["settings"] as? String ?? ""))
        return try #require(DiscordSettingsProto.statusSettings(in: body))
    }

    private func readyStatusPickProvider(
        settings: Data, accountID: String = "status-pick-\(UUID().uuidString)", restoresPendingEdit: Bool = false
    ) async throws -> StatusPickSession {
        let socket = ReadyGatewaySocket()
        await socket.push(gatewayMessage(op: 10, data: .object(["heartbeat_interval": .number(60_000)])))
        await socket.push(gatewayMessage(
            op: 0,
            data: .object([
                "session_id": .string("status-pick-session"),
                "resume_gateway_url": .string("wss://gateway.discord.gg"),
                "user": .object(["id": .string("2"), "username": .string("maya")]),
                "guilds": .array([]),
                "user_settings_proto": .string(settings.base64EncodedString()),
            ]),
            sequence: 1,
            eventName: "READY"
        ))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DirectMessageURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: DirectMessageCredentialStore(),
            handle: CredentialHandle(accountID: accountID),
            session: URLSession(configuration: configuration),
            gatewayTransport: ReadyGatewayTransport(socket: socket),
            gatewayClock: HeldGatewayClock(),
            usesDesktopHeartbeat: true,
            installationID: "server-issued-installation"
        )
        if restoresPendingEdit { await provider.loadPendingStatusEdit() }
        let events = await provider.eventStream()
        try await provider.startGateway()
        #expect(await eventually { await socket.sentCount == 5 })
        return StatusPickSession(accountID: accountID, provider: provider, socket: socket, events: events)
    }

    private func protoFieldNumbers(_ data: Data) -> [Int] {
        var reader = ProtoReader(data: data)
        var numbers: [Int] = []
        while let field = reader.readRawField() { numbers.append(field.field) }
        return numbers
    }

    private func protoField(_ number: Int, in data: Data) -> Data? {
        var reader = ProtoReader(data: data)
        var result: Data?
        while let field = reader.readRawField() {
            if field.field == number { result = field.raw }
        }
        return result
    }
}

struct StatusPickSession {
    let accountID: String
    let provider: DiscordRESTProvider
    let socket: ReadyGatewaySocket
    let events: AsyncStream<ClientEvent>
}

extension DirectMessageProviderContractTests {
    @Test(.timeLimit(.minutes(1)))
    func `rate limited presence is retried after its cooldown`() async throws {
        DirectMessageURLProtocol.reset()
        let session = try await readyStatusPickProvider(settings: statusSettingsFixture("online", dataVersion: 1))
        defer { DiscordRESTProvider.removePendingStatusEdit(accountID: session.accountID) }
        let provider = session.provider
        await provider.receiveGatewayDispatchForTesting(name: "RATE_LIMITED", data: .object([
            "opcode": .number(3), "retry_after": .number(0.05),
        ]))
        #expect(await eventually { await session.socket.sentPayloadCount(opcode: 3) == 2 })
        #expect(await presenceStatuses(session.socket).last == "online")
        await provider.disconnect()
    }

    @Test(.timeLimit(.minutes(1)))
    func `resumed READY obeys the existing presence send budget`() async throws {
        DirectMessageURLProtocol.reset()
        let session = try await readyStatusPickProvider(settings: statusSettingsFixture("online", dataVersion: 1))
        defer { DiscordRESTProvider.removePendingStatusEdit(accountID: session.accountID) }
        let provider = session.provider
        for status in ["idle", "dnd", "online", "idle"] {
            await settingsUpdate(provider, statusSettingsFixture(status))
        }
        #expect(await session.socket.sentPayloadCount(opcode: 3) == 5)
        await provider.handleGatewaySessionEvent(.stateChanged(.resuming))
        await provider.handleGatewaySessionEvent(.stateChanged(.ready))
        #expect(await session.socket.sentPayloadCount(opcode: 3) == 5)
        #expect(await provider.hasDeferredPresenceForTesting())
        await provider.reopenPresenceSendWindowForTesting()
        #expect(await session.socket.sentPayloadCount(opcode: 3) == 6)
        #expect(await presenceStatuses(session.socket).last == "idle")
        await provider.disconnect()
    }

    @Test(.timeLimit(.minutes(1)))
    func `cancelled queued status writer releases its waiter`() async throws {
        DirectMessageURLProtocol.reset()
        let session = try await readyStatusPickProvider(settings: statusSettingsFixture("online", dataVersion: 1))
        defer { DiscordRESTProvider.removePendingStatusEdit(accountID: session.accountID) }
        let provider = session.provider
        await provider.holdStatusSettingsSaveForTesting()
        let save = Task { try await provider.updateProfileCustomStatus(ProfileCustomStatus(text: "cancelled fixture")) }
        #expect(await eventually { await provider.statusSettingsSaveWaiterCountForTesting() == 1 })
        save.cancel()
        #expect(await eventually { await provider.statusSettingsSaveWaiterCountForTesting() == 0 })
        await provider.releaseStatusSettingsSaveForTesting()
        _ = try? await save.value
        #expect(DirectMessageURLProtocol.requests.isEmpty)
        await provider.disconnect()
    }
}
