@testable import DiscordProtocol
import Foundation
@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
@Test func `name style effect changes preserve inactive draft colors and reset discards them`() async throws {
    let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
    await model.start()
    let editor = ProfileEditorState(model: model)
    await editor.load()
    let original = try #require(editor.displayProfile?.user.displayNameStyle)
    try #require(original.effectID == ProfileNameEffect.gradient.rawValue && original.colors.count == 2)

    editor.setStyle(editor.nameStyle(for: .solid, darkAppearance: true))
    #expect(editor.displayProfile?.user.displayNameStyle?.colors == Array(original.colors.prefix(1)))
    editor.setStyle(editor.nameStyle(for: .gradient, darkAppearance: true))
    #expect(editor.displayProfile?.user.displayNameStyle == original)
    #expect(!editor.hasChanges)

    let palette: [UInt32] = [0x112233, 0x445566, 0x778899, 0xAABBCC, 0xDDEEFF]
    editor.setStyle(DisplayNameStyle(effectID: ProfileNameEffect.prism.rawValue, colors: palette))
    var solid = editor.nameStyle(for: .solid, darkAppearance: true)
    solid.colors = [0x123456]
    editor.setStyle(solid)
    editor.setStyle(editor.nameStyle(for: .gradient, darkAppearance: true))
    editor.setStyle(editor.nameStyle(for: .prism, darkAppearance: true))
    #expect(editor.displayProfile?.user.displayNameStyle?.colors == [0x123456] + palette.dropFirst())

    editor.resetDraft()
    let defaults = DiscordProfileNameStyles.defaultColors(for: .prism, darkAppearance: true)
    #expect(editor.nameStyle(for: .prism, darkAppearance: true).colors == original.colors + defaults.dropFirst(2))
    #expect(!editor.hasChanges)

    // The official Solid/Default reset sends an empty array, retaining the
    // font and effect. It must also discard the previous custom palette.
    editor.setStyle(DisplayNameStyle())
    var defaultStyle = editor.nameStyle(for: .solid, darkAppearance: true)
    #expect(defaultStyle.colors.isEmpty)
    defaultStyle.fontID = 2
    editor.setStyle(defaultStyle)
    let request = try #require(ProfileEditingRequest.identity(editor.changes.identity, in: .main))
    #expect(request.body == [
        "display_name_font_id": .number(2), "display_name_effect_id": .number(1), "display_name_colors": .array([]),
    ])
    #expect(editor.nameStyle(for: .prism, darkAppearance: true).colors == defaults)
}

@MainActor
@Test func `server tag drafts use the same account identity in main and server editors`() async throws {
    let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
    await model.start()
    let editor = ProfileEditorState(model: model)
    let tag = PrimaryGuildIdentity(guildID: GuildID(rawValue: 999), tag: "TEST")
    for scope in [ProfileEditingScope.main, .server(GuildID(rawValue: 100))] {
        await editor.load(scope)
        _ = try #require(editor.snapshot)
        editor.setServerTag(tag)
        #expect(editor.changes.serverTag == .set(GuildID(rawValue: 999)))
        #expect(editor.preview?.user.primaryGuild == tag)
        #expect(editor.canSave)
        editor.resetDraft()
        #expect(!editor.changes.serverTag.isChanged)
    }
}

@MainActor
@Test func `clearing profile text preserves explicit empty values and restoring it removes the draft`() async throws {
    let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
    await model.start()
    let editor = ProfileEditorState(model: model)
    await editor.load()
    let snapshot = try #require(editor.snapshot)
    let name = try #require(snapshot.identity.name.value)
    let bio = try #require(snapshot.metadata.bio.value)
    let pronouns = try #require(snapshot.metadata.pronouns.value)
    try #require(!name.isEmpty && !bio.isEmpty && !pronouns.isEmpty)

    editor.name = ""
    editor.bio = ""
    editor.pronouns = ""
    #expect(editor.changes.identity.name == .set(""))
    #expect(editor.changes.metadata.bio == .set(""))
    #expect(editor.changes.metadata.pronouns == .set(""))
    #expect(editor.canSave)

    await editor.loadIfNeeded(refreshExisting: true)
    #expect(editor.name.isEmpty && editor.bio.isEmpty && editor.pronouns.isEmpty)
    #expect(editor.hasChanges)

    editor.name = name
    editor.bio = bio
    editor.pronouns = pronouns
    #expect(!editor.hasChanges)

    await editor.load(.server(GuildID(rawValue: 100)))
    _ = try #require(editor.snapshot)
    editor.name = ""
    editor.bio = ""
    editor.pronouns = ""
    #expect(!editor.hasChanges)
    await editor.loadIfNeeded(refreshExisting: true)
    #expect(editor.scope == .server(GuildID(rawValue: 100)))
    #expect(!editor.hasChanges)
}

@MainActor
@Test func `profile editing reuses fresh scopes and refreshes stale data without discarding edits`() async throws {
    let provider = ProfileEditorCacheProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    model.serverRailGuildsByID[GuildID(rawValue: 100)]?.currentUserPermissions = DiscordPermissionBits.changeNickname
    var time = ContinuousClock.now
    let editor = ProfileEditorState(model: model, now: { time })
    let server = ProfileEditingScope.server(GuildID(rawValue: 100))
    await editor.load()
    await editor.load(server)
    let initialGeneration = editor.draftGeneration
    await editor.loadIfNeeded(refreshExisting: true)
    #expect(editor.draftGeneration == initialGeneration)
    for _ in 0 ..< 5 {
        await editor.load(.main)
        await editor.load(server)
        await editor.loadIfNeeded(refreshExisting: true)
    }
    #expect(await provider.reads == [.main, server])
    time = time.advanced(by: .seconds(60))
    await provider.suspendNextRead()
    let refresh = Task { await editor.load(server) }
    await provider.waitForRead()
    #expect(editor.snapshot?.scope == server)
    #expect(!editor.isLoading)
    // Reentering the same scope during a refresh must not send another request.
    await editor.load(server)
    editor.name = "Unsaved nickname"
    // A late profile read must finish before a save can replace its baseline.
    #expect(!editor.canSave)
    await provider.resumeRead()
    await refresh.value
    #expect(editor.name == "Unsaved nickname")
    #expect(editor.canSave)
    #expect(editor.hasChanges)
    #expect(await provider.reads == [.main, server, server])
    await editor.load(.main)
    #expect(editor.scope == server)
    #expect(editor.showsUnsavedReminder)
    editor.resetDraft()
    await editor.load(server)
    #expect(!editor.hasChanges)
    #expect(await provider.reads == [.main, server, server])
}

@MainActor
@Test(arguments: [ProfileEditingScope.main, .server(GuildID(rawValue: 100))])
func `profile editor uses a preloaded editable baseline without another read`(scope: ProfileEditingScope) async throws {
    let provider = ProfileEditorCacheProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    model.serverRailGuildsByID[GuildID(rawValue: 100)]?.currentUserPermissions = DiscordPermissionBits.changeNickname
    let editor = ProfileEditorState(model: model)
    if scope != .main { await editor.load() }
    let preloaded = try await provider.profileEditingSnapshot(in: scope)
    await provider.suspendNextCacheRead()
    let loading = Task { await editor.load(scope) }
    await provider.waitForRead()
    // A provider actor hop must not flash the loading overlay, but the old
    // scope must remain locked until the new editable baseline arrives.
    #expect(!editor.isLoading)
    #expect(editor.isResolvingScope)
    #expect(editor.canEditWidgets == (scope != .main))
    #expect(!editor.canSave)
    await provider.resumeRead()
    await loading.value
    #expect(editor.snapshot == preloaded)
    #expect(!editor.isLoading && !editor.isResolvingScope)
    #expect(await provider.reads == (scope == .main ? [.main] : [.main, scope]))
    if scope != .main {
        await provider.suspendNextCacheRead()
        let switching = Task { await editor.load(.main) }
        await provider.waitForRead()
        editor.name = "Typed before the cached baseline arrived"
        await provider.resumeRead()
        await switching.value
        #expect(editor.scope == scope)
        #expect(editor.name == "Typed before the cached baseline arrived")
        #expect(editor.showsUnsavedReminder)
    }
}

@MainActor
@Test func `prepared editor baseline is editable on construction and does not replace drafts`() async throws {
    let provider = ProfileEditorCacheProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let baseline = try await provider.profileEditingSnapshot(in: .main)
    model.preparedProfileEditingSnapshot = baseline
    let editor = ProfileEditorState(model: model)
    #expect(editor.snapshot == baseline)
    #expect(!editor.isResolvingScope && editor.canEditWidgets)
    editor.name = "Immediate local edit"
    await editor.loadIfNeeded(refreshExisting: true)
    #expect(editor.name == "Immediate local edit")
    #expect(editor.hasChanges && editor.canSave)
    #expect(await provider.reads == [.main])
    model.dismissAllProfiles(clearsCache: true)
    #expect(model.preparedProfileEditingSnapshot == nil)
    #expect(ProfileEditorState(model: model).snapshot == nil)
}

@MainActor
@Test func `unloaded server profile retains the current canvas but cannot save its baseline`() async throws {
    let provider = ProfileEditorCacheProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let editor = ProfileEditorState(model: model)
    await editor.load()
    let previous = try #require(editor.preview)
    let server = ProfileEditingScope.server(GuildID(rawValue: 100))
    await provider.suspendNextRead()
    let loading = Task { await editor.load(server) }
    await provider.waitForRead()
    #expect(editor.isLoading)
    #expect(editor.preview == previous)
    #expect(editor.scope == .main)
    #expect(!editor.canSave && !editor.canEditWidgets)
    await provider.resumeRead()
    await loading.value
    #expect(editor.scope == server)
    #expect(editor.snapshot?.scope == server)
    #expect(!editor.isLoading)
}

@MainActor
@Test func `widget drafts remain removable and reordering preserves the exact save order`() async throws {
    let first = ProfileWidget(serverID: "1", content: .application(id: "10"))
    let second = ProfileWidget(serverID: "2", content: .application(id: "20"))
    let games = [ProfileWidgetGame(id: "a", comment: "Keep this comment"), ProfileWidgetGame(id: "b"), ProfileWidgetGame(id: "c")]
    let third = ProfileWidget(serverID: "3", content: .games(.liked, games))
    let provider = ProfileEditorCacheProvider(widgets: [first, second, third])
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let editor = ProfileEditorState(model: model)
    await editor.load()
    editor.moveWidgetGames(widgetID: third.id, ids: ["c", "a"], before: "b")
    #expect(editor.widgets.last?.content == .games(.liked, [games[0], games[2], games[1]]))
    #expect(editor.changes.widgets?.last?.content == editor.widgets.last?.content)
    let reordered = editor.widgets
    editor.moveWidgetGames(widgetID: third.id, ids: ["a"], before: "removed-during-drag")
    editor.moveWidgetGames(widgetID: third.id, ids: ["a"], before: "a")
    #expect(editor.widgets == reordered)
    editor.moveWidgetGames(widgetID: third.id, ids: ["c"], before: nil)
    #expect(editor.widgets.last == third)
    #expect(!editor.hasChanges)

    let blank = ProfileWidget(content: .personal(ProfilePersonalWidget(sections: [.cover(ProfileWidgetCover())])))
    editor.addWidget(blank)
    #expect(editor.widgets.first?.id == blank.id)
    #expect(!editor.hasChanges)
    editor.removeWidget(id: blank.id)
    #expect(editor.widgets == [first, second, third])
    #expect(!editor.hasChanges)

    editor.addWidget(blank)
    editor.updateWidgetCover(id: blank.id, section: 0) { $0.title = "Partial content" }
    #expect(editor.hasChanges && !editor.canSave)
    editor.updatePersonalWidget(id: blank.id) { $0.header = "About" }
    #expect(editor.canSave)
    editor.moveWidgets([blank.id, third.id], before: second.id)
    #expect(editor.widgets.map(\.id) == [first.id, blank.id, third.id, second.id])
    #expect(editor.changes.widgets?.map(\.id) == editor.widgets.map(\.id))
    // Reordering back to the saved baseline removes the mutation, even when
    // the board still contains an empty local placeholder.
    editor.updateWidgetCover(id: blank.id, section: 0) { $0.title = "" }
    editor.moveWidgets([second.id], before: third.id)
    #expect(!editor.hasChanges)
    #expect(editor.widgets.contains { $0.id == blank.id })
    editor.moveWidgets([first.id], before: nil)
    #expect(editor.changes.widgets?.map(\.id) == [second.id, third.id, first.id])
    let beforeInvalidMove = editor.widgets
    editor.moveWidgets([third.id], before: "removed-during-drag")
    editor.moveWidgets([third.id], before: third.id)
    #expect(editor.widgets == beforeInvalidMove)
    editor.resetDraft()
    #expect(editor.widgets == [first, second, third])
    #expect(!editor.hasChanges)
}

@MainActor
@Test func `external profile changes refresh immediately while preserving the preview and unsaved edits`() async throws {
    let widget = ProfileWidget(serverID: "1", content: .application(id: "10"))
    let provider = ProfileEditorCacheProvider(widgets: [widget])
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let editor = ProfileEditorState(model: model)
    await editor.load()
    let original = try #require(editor.preview)
    await provider.replaceWidgets([])
    await provider.suspendNextRead()
    editor.invalidateSnapshot()
    let refresh = Task { await editor.refreshIfNeeded() }
    await provider.waitForRead()
    #expect(editor.preview == original)
    #expect(!editor.isLoading)
    await provider.resumeRead()
    await refresh.value
    #expect(editor.widgets.isEmpty)
    #expect(await provider.reads == [.main, .main])

    editor.name = "Unsaved name"
    await provider.replaceWidgets([widget])
    editor.invalidateSnapshot()
    await editor.refreshIfNeeded()
    #expect(editor.name == "Unsaved name")
    #expect(await provider.reads == [.main, .main])
    editor.resetDraft()
    await editor.refreshIfNeeded()
    #expect(editor.widgets == [widget])
    #expect(await provider.reads == [.main, .main, .main])
    await editor.loadIfNeeded(refreshExisting: true)
    #expect(await provider.reads == [.main, .main, .main])

    // An unfinished widget has no saveable changes, but still belongs to the draft.
    let blank = ProfileWidget(content: .personal(ProfilePersonalWidget(sections: [.cover(ProfileWidgetCover())])))
    editor.addWidget(blank)
    #expect(!editor.hasChanges)
    editor.invalidateSnapshot()
    await editor.refreshIfNeeded()
    await editor.loadIfNeeded(refreshExisting: true)
    await editor.load(.main)
    #expect(editor.widgets == [blank, widget])
    #expect(await provider.reads == [.main, .main, .main])
    editor.removeWidget(id: blank.id)
    await editor.refreshIfNeeded()
    #expect(editor.widgets == [widget])
    #expect(await provider.reads == [.main, .main, .main, .main])
}

@MainActor
@Test func `status drafts stay local survive gateway updates and reset with profile edits`() async throws {
    let provider = ProfileEditorCacheProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let editor = ProfileEditorState(model: model)
    await editor.load()
    let original = editor.snapshot?.customStatus
    let draft = ProfileStatusDraft(status: ProfileCustomStatus(text: "Local draft", emojiName: "🌸"), expiresAfter: 3600)
    editor.setCustomStatusDraft(draft)
    #expect(editor.canSave)
    #expect(editor.preview?.customStatus == "🌸 Local draft")
    #expect(editor.snapshot?.customStatus == original)
    #expect(await provider.statusWrites.isEmpty)
    await editor.load(.server(GuildID(rawValue: 100)))
    #expect(editor.scope == .main)
    #expect(editor.showsUnsavedReminder)
    let remote = ProfileCustomStatus(text: "Changed elsewhere")
    model.consumeProfileCustomStatusChanged(userID: try #require(editor.snapshot?.presentation.id), status: remote)
    editor.receiveCustomStatus(remote)
    #expect(editor.customStatusDraft == draft)
    editor.resetDraft()
    #expect(!editor.hasChanges)
    #expect(editor.preview?.customStatus == remote.displayText)
    #expect(await provider.statusWrites.isEmpty)

    editor.setCustomStatusDraft(nil)
    #expect(editor.canSave)
    #expect(editor.preview?.customStatus == nil)
    await editor.save()
    #expect(!editor.hasChanges)
    #expect(await provider.statusWrites.count == 1)
    #expect(await provider.statusWrites[0] == nil)
}

@MainActor
@Test func `profile save keeps failed status pending without repeating acknowledged profile writes`() async throws {
    let provider = ProfileEditorCacheProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let editor = ProfileEditorState(model: model)
    await editor.load()
    editor.bio = "Updated bio"
    editor.setCustomStatusDraft(ProfileStatusDraft(status: ProfileCustomStatus(text: "Pending status"), expiresAfter: 3600))
    await provider.failNextStatusSave()
    await editor.save()
    #expect(editor.errorMessage != nil)
    #expect(!editor.changes.hasChanges)
    #expect(editor.hasChanges)
    #expect(editor.customStatusDraft?.status.text == "Pending status")
    #expect(await provider.profileWrites == 1)
    let beforeSave = Date.now
    await editor.save()
    #expect(editor.errorMessage == nil)
    #expect(!editor.hasChanges)
    #expect(await provider.profileWrites == 1)
    #expect(await provider.statusWrites.count == 2)
    let status = try #require(editor.snapshot?.customStatus)
    #expect(model.profileCustomStatus == status)
    #expect(model.profileCustomStatusUserID == editor.snapshot?.presentation.id)
    #expect(status.text == "Pending status")
    #expect(try #require(status.expiresAt) >= beforeSave.addingTimeInterval(3600))
}

@MainActor
@Test func `own status survives stale member refreshes and explicit clears replace cached values`() async throws {
    let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
    await model.start()
    let user = try #require(model.snapshot?.currentUser)
    var member = Member(user: user, roleName: "You", status: .offline)
    var profile = UserProfile(user: user)
    profile.customStatus = "Saved profile status"
    let key = SakuraCord.ProfileCacheKey(userID: user.id, guildID: model.selectedGuildID)
    model.profileCache[key] = profile
    model.presentProfile(for: member, in: model.selectedGuildID, destination: .contextual)
    let editor = ProfileEditorState(model: model)
    await editor.load()

    let status = ProfileCustomStatus(text: "Updated elsewhere", emojiName: "🌸")
    model.consumeProfileCustomStatusChanged(userID: user.id, status: status)
    #expect(model.liveProfilePresentation(for: .contextual)?.member.customStatus == status.displayText)
    #expect(editor.customStatusDraft?.status == status)
    member.customStatus = "Stale member status"
    model.consumeProfileCustomStatusChanged(userID: user.id, status: nil)
    model.membersByID[user.id] = member
    model.presentProfile(for: member, in: model.selectedGuildID, destination: .expanded)
    #expect(model.liveProfilePresentation(for: .contextual)?.member.customStatus == nil)
    #expect(model.liveProfilePresentation(for: .expanded)?.member.customStatus == nil)
    model.currentStatus = .dnd
    #expect(model.liveProfilePresentation(for: .expanded)?.member.status == .dnd)
    #expect(model.profileCache[key]?.customStatus == nil)
    #expect(editor.customStatusDraft == nil)
}

private actor ProfileEditorCacheProvider: ChatProvider {
    private let fixture = MockChatProvider()
    private(set) var profileWrites = 0
    private(set) var statusWrites: [ProfileCustomStatus?] = []
    private var failsStatusSave = false
    func failNextStatusSave() { failsStatusSave = true }
    func updateProfileCustomStatus(_ status: ProfileCustomStatus?) async throws -> ProfileCustomStatus? {
        statusWrites.append(status)
        if failsStatusSave {
            failsStatusSave = false
            throw ChatProviderError.invalidRequest("Status rejected")
        }
        return status
    }
    func saveProfileChanges(_ changes: ProfileEditChanges, in scope: ProfileEditingScope,
                            didSave: @Sendable (ProfileSaveConfirmation) async -> Void) async throws {
        profileWrites += 1
        var value = try await fixture.profileEditingSnapshot(in: scope)
        value.mainMetadata.bio = changes.metadata.bio.applying(to: value.mainMetadata.bio)
        await didSave(ProfileSaveConfirmation(stage: .metadata, snapshot: value))
    }
    private var widgets: [ProfileWidget]?
    init(widgets: [ProfileWidget]? = nil) { self.widgets = widgets }
    private var cache: [ProfileEditingScope: ProfileEditingSnapshot] = [:]
    private(set) var reads: [ProfileEditingScope] = []
    private var suspendsRead = false
    private var suspendsCacheRead = false
    private var pendingRead: CheckedContinuation<Void, Never>?
    private var readStarted: CheckedContinuation<Void, Never>?

    func suspendNextRead() { suspendsRead = true }
    func suspendNextCacheRead() { suspendsCacheRead = true }
    func replaceWidgets(_ widgets: [ProfileWidget]) { self.widgets = widgets }
    func waitForRead() async {
        if pendingRead != nil { return }
        await withCheckedContinuation { readStarted = $0 }
    }
    func resumeRead() { pendingRead?.resume(); pendingRead = nil }
    func cachedProfileEditingSnapshot(in scope: ProfileEditingScope) async throws -> ProfileEditingSnapshot? {
        if suspendsCacheRead {
            suspendsCacheRead = false
            await withCheckedContinuation {
                pendingRead = $0
                readStarted?.resume(); readStarted = nil
            }
        }
        return cache[scope]
    }
    func profileEditingSnapshot(in scope: ProfileEditingScope) async throws -> ProfileEditingSnapshot {
        reads.append(scope)
        if suspendsRead {
            suspendsRead = false
            await withCheckedContinuation {
                pendingRead = $0
                readStarted?.resume(); readStarted = nil
            }
        }
        var value = try await fixture.profileEditingSnapshot(in: scope)
        if let widgets {
            value.presentation.widgets = widgets
            value.mainPresentation.widgets = widgets
            value.widgetEligibility = ProfileWidgetEligibility(hasFullNitro: true, hasPersonalWidgetAccess: true)
        }
        cache[scope] = value
        return value
    }
    func bootstrap() async throws -> BootstrapSnapshot { try await fixture.bootstrap() }
    func channels(in guildID: GuildID?) async throws -> [Channel] { [] }
    func members(in guildID: GuildID?) async throws -> [Member] { [] }
    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile { try await fixture.profile(for: userID, in: guildID) }
    func currentStatus() async -> PresenceStatus { .offline }
    func updateStatus(_ status: PresenceStatus) async throws {}
    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws -> MessagePage { MessagePage(messages: [], hasMoreBefore: false) }
    func send(_ draft: SendMessageDraft) async throws -> Message { throw ChatProviderError.invalidRequest("unused") }
    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message { throw ChatProviderError.invalidRequest("unused") }
    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {}
    func eventStream() async -> AsyncStream<ClientEvent> { AsyncStream { $0.finish() } }
    func disconnect() async {}
}

@MainActor
@Test func `server nickname editing follows current permissions and rejects revoked drafts`() async throws {
    let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider())
    await model.start()
    let editor = ProfileEditorState(model: model)
    await editor.load()
    #expect(editor.canEditName)

    let guildID = GuildID(rawValue: 100)
    var guild = try #require(model.serverRailGuildsByID[guildID])
    guild.isOwnedByCurrentUser = false
    guild.currentUserPermissions = 0
    model.serverRailGuildsByID[guildID] = guild
    await editor.load(.server(guildID))
    let original = editor.name
    #expect(!editor.canEditName)
    editor.name = "Blocked nickname"
    #expect(editor.name == original)
    #expect(!editor.hasChanges)
    editor.bio = "An unrelated profile edit"
    #expect(editor.canSave)
    editor.resetDraft()

    // Managing other members' nicknames does not grant the self-change permission.
    for permissions: UInt64 in [1 << 27, DiscordPermissionBits.changeNickname, DiscordPermissionBits.administrator] {
        guild.currentUserPermissions = permissions
        model.serverRailGuildsByID[guildID] = guild
        #expect(editor.canEditName == (permissions != 1 << 27))
    }
    guild.currentUserPermissions = 0
    guild.isOwnedByCurrentUser = true
    model.serverRailGuildsByID[guildID] = guild
    #expect(editor.canEditName)
    editor.name = "Allowed nickname"
    #expect(editor.changes.identity.name.isChanged)

    guild.isOwnedByCurrentUser = false
    model.serverRailGuildsByID[guildID] = guild
    await editor.save()
    #expect(editor.errorMessage?.contains("permission") == true)
    #expect(editor.changes.identity.name.isChanged)
    #expect(editor.snapshot?.identity.name.value ?? "" == original)

    editor.resetDraft()
    model.serverRailGuildsByID[guildID] = nil
    #expect(!editor.canEditName)
}

@MainActor
@Test func `nickname editor resolves missing members before drafting and rechecks hierarchy`() async throws {
    let provider = MockChatProvider()
    let guildID = GuildID(rawValue: 100)
    let target = try #require(try await provider.members(in: guildID).first { $0.id == UserID(rawValue: 5) })
    _ = try await provider.setMemberNickname("Existing nickname", for: target.id, in: guildID)
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    model.snapshot = try await provider.bootstrap()
    model.serverRailGuildsByID[guildID] = Guild(id: guildID, name: "Fixture", ownerID: UserID(rawValue: 9),
                                              currentUserPermissions: DiscordPermissionBits.manageNicknames)
    let actorRole = RoleID(rawValue: 11)
    model.currentUserRoleIDsByGuild[guildID] = [actorRole]
    model.guildRolesByGuildID[guildID] = target.roles + [GuildRole(id: actorRole, name: "Moderator", position: 18)]
    #expect(model.profileMember(target.id, in: guildID) == nil)
    #expect(!model.canChangeNickname(of: target.id, in: guildID))
    #expect(!model.nicknameMenuActions(for: target.user, in: guildID).contains { $0.title == "Change Nickname" })
    await model.resolveNicknameMenuMember(target.id, in: guildID).value
    #expect(model.nicknameMenuActions(for: target.user, in: guildID).contains { $0.title == "Change Nickname" })
    model.presentNicknameEditor(for: target.user, in: guildID)
    let presentation = try #require(model.nicknameEditor.presentation)
    #expect(presentation.currentNickname == "Existing nickname")
    #expect(model.nicknameEditor.draft == "Existing nickname")

    // Losing the cached record must not turn an explicit reset into a no-op.
    model.membersByGuildID[guildID] = nil
    model.nicknameEditor.draft = ""
    model.saveNickname(presentation)
    for task in Array(model.accountChildTasks.values) { await task.value }
    #expect(try await provider.members(in: guildID).first { $0.id == target.id }?.guildNickname == nil)

    // Hydrating a higher-ranked target must not expose an editable draft.
    model.guildRolesByGuildID[guildID] = target.roles + [GuildRole(id: actorRole, name: "Moderator", position: 14)]
    await model.resolveNicknameMenuMember(target.id, in: guildID).value
    #expect(!model.canChangeNickname(of: target.id, in: guildID))
    model.presentNicknameEditor(for: target.user, in: guildID)
    #expect(model.nicknameEditor.presentation == nil)

    model.membersByGuildID[guildID] = nil
    let cancelled = model.resolveNicknameMenuMember(target.id, in: guildID)
    model.nicknameEditor.reset()
    await cancelled.value
    #expect(model.profileMember(target.id, in: guildID) == nil)
    model.guildRolesByGuildID[guildID] = target.roles + [GuildRole(id: actorRole, name: "Moderator", position: 18)]
    var guest = target
    guest.joinedAt = nil
    model.membersByGuildID[guildID] = [guest.id: guest]
    #expect(!model.canChangeNickname(of: guest.id, in: guildID))
}

@MainActor
@Test func `edit group drafts the saved name and saves only changes through the provider`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let groupID = ChannelID(rawValue: 401)
    let store = model.groupDirectMessageEditor
    model.presentGroupDirectMessageEditor(for: groupID)
    let unchanged = try #require(store.presentation)
    #expect(store.draftName == "Design crew")
    #expect(unchanged.placeholder == unchanged.channel.recipients.map(\.displayName).joined(separator: ", "))
    #expect(!store.showsIcon)
    // Whitespace alone and removing an absent icon are not changes.
    store.draftName = " Design crew "
    store.icon = .removed
    #expect(!store.changes.hasChanges)
    model.saveGroupDirectMessage(unchanged)
    #expect(store.presentation == nil)

    model.presentGroupDirectMessageEditor(for: groupID)
    let presentation = try #require(store.presentation)
    let icon = ProfileImageUpload(data: Data([1, 2, 3]), mediaType: "image/png", description: "icon.png")
    store.draftName = "  Road trip "
    store.icon = .upload(icon)
    #expect(store.changes == GroupDirectMessageChanges(name: .set("Road trip"), icon: .set(icon)))
    model.saveGroupDirectMessage(presentation)
    #expect(store.isSaving)
    for task in Array(model.accountChildTasks.values) { await task.value }
    #expect(store.presentation == nil)
    #expect(store.error == nil)
    let saved = try #require(await provider.snapshot.channels.first { $0.id == groupID })
    #expect(saved.name == "Road trip")
    #expect(saved.iconURL != nil)

    // The provider's event publishes the group; clearing then returns it to
    // its member-list title.
    while model.snapshot?.channels.first(where: { $0.id == groupID })?.name != "Road trip", !Task.isCancelled {
        await Task.yield()
    }
    model.presentGroupDirectMessageEditor(for: groupID)
    #expect(store.draftName == "Road trip")
    #expect(store.showsIcon)
    store.draftName = ""
    store.icon = .removed
    #expect(store.changes == GroupDirectMessageChanges(name: .clear, icon: .clear))
}

@MainActor
@Test func `leave group confirms, leaves once through the provider and moves selection off the group`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let groupID = ChannelID(rawValue: 401)
    let store = model.groupDirectMessageLeave
    // A 1:1 DM never offers Leave Group.
    model.presentLeaveGroupDirectMessage(for: ChannelID(rawValue: 400))
    #expect(store.confirmation == nil)

    model.selectedGuildID = nil
    model.selectedChannelID = groupID
    // `/leave silent:True` opens the same confirmation with the checkbox checked.
    let leave = try #require(DiscordBuiltInCommands.all.first { $0.name == "leave" })
    model.runBuiltInCommand(ApplicationCommandInvocation(command: leave, channelID: groupID, guildID: nil, values: [
        ApplicationCommandOptionValue(optionID: "-15/silent", name: "silent", type: .boolean, argument: .boolean(true)),
    ]))
    let confirmation = try #require(store.confirmation)
    #expect(confirmation.id == groupID)
    #expect(store.leavesSilently)

    model.leaveGroupDirectMessage(confirmation, silently: store.leavesSilently)
    model.leaveGroupDirectMessage(confirmation, silently: store.leavesSilently)
    for task in Array(model.accountChildTasks.values) { await task.value }
    let requests = await provider.groupLeaveRequests
    #expect(requests.map(\.channelID) == [groupID])
    #expect(requests.map(\.silently) == [true])
    while model.snapshot?.channels.contains(where: { $0.id == groupID }) == true, !Task.isCancelled {
        await Task.yield()
    }
    let selected = try #require(model.selectedChannelID)
    #expect(selected != groupID)
    #expect(model.snapshot?.channels.contains { $0.id == selected && $0.guildID == nil } == true)
    #expect(model.errorMessage == nil)
    #expect(store.leaving.isEmpty)
}
