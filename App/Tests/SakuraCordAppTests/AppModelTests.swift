import AppKit
import DiscordProtocol
import Foundation
@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
@Test func `native emoji catalog loads every fully qualified unicode 17 emoji`() {
    #expect(NativeEmojiCatalogDiagnostics.sourceEntryCount == 3944)
    #expect(NativeEmojiCatalogDiagnostics.itemCount < NativeEmojiCatalogDiagnostics.sourceEntryCount)
    #expect(NativeEmojiCatalogDiagnostics.skinToneCapableItemCount > 100)
    #expect(NativeEmojiCatalogDiagnostics.wavingHandValues == ["👋", "👋🏻", "👋🏼", "👋🏽", "👋🏾", "👋🏿"])
    #expect(NativeEmojiCatalogDiagnostics.mediumToneVariationSelectorValues == ["✌🏽", "☝🏽", "✍🏽"])
    #expect(NativeEmojiCatalogDiagnostics.baseItemsContainingSkinToneModifier == 0)
    #expect(NativeEmojiCatalogDiagnostics.categoryItemCounts.count == 9)
    #expect(NativeEmojiCatalogDiagnostics.categoryItemCounts.values.allSatisfy { $0 > 0 })
    #expect(NativeEmojiCatalogDiagnostics.shortcode(for: "🤍") == ":white_heart:")
    // Tone variants share their base emoji's aliases, so the collapsed picker catalog is smaller
    // than Emojibase's 3,808 keyed source records.
    #expect(NativeEmojiCatalogDiagnostics.emojiCountWithDiscordShortcodes == 1884)
    #expect(NativeEmojiCatalogDiagnostics.discordShortcodeAliasCount == 2551)
    #expect(NativeEmojiCatalogDiagnostics.shortcodes(for: "🎉") == ["tada", "party_popper"])
    #expect(NativeEmojiCatalogDiagnostics.shortcode(for: "🎉") == ":tada:")
    #expect(NativeEmojiCatalogDiagnostics.searchMatches(value: "🎉", query: ":party_popper:"))
    #expect(NativeEmojiCatalogDiagnostics.searchMatches(value: "👍", query: "+1"))
    #expect(EmojiSearchMatcher.normalized(":grinning_face:") == "grinning_face")
}

@MainActor
@Test func `emoji picker uses one continuous recycled document`() {
    #expect(EmojiPickerPerformanceDiagnostics.itemsPerRecycledRow == 9)
    #expect(EmojiPickerPerformanceDiagnostics.nativeSectionIDs.count == 9)
    #expect(Set(EmojiPickerPerformanceDiagnostics.nativeSectionIDs).count == 9)
    #expect(EmojiPickerPerformanceDiagnostics.nativeDocumentRowCount
        < EmojiPickerPerformanceDiagnostics.nativeItemCount / 4)
    #expect(NativeEmojiCatalogDiagnostics.categoryItemCounts["people", default: 0] > 300)
    #expect(!EmojiPickerPerformanceDiagnostics.nativeSidebarIsVisible(
        bounds: nil,
        viewportHeight: 300
    ))
    #expect(!EmojiPickerPerformanceDiagnostics.nativeSidebarIsVisible(
        bounds: CGRect(x: 0, y: 320, width: 46, height: 300),
        viewportHeight: 300
    ))
    #expect(EmojiPickerPerformanceDiagnostics.nativeSidebarIsVisible(
        bounds: CGRect(x: 0, y: 280, width: 46, height: 300),
        viewportHeight: 300
    ))
}

@Test func `emoji picker keyboard navigation wraps rows and clamps columns`() {
    let rows = [
        ["a", "b", "c"],
        ["d", "e", "f"],
        ["g"]
    ]

    #expect(EmojiPickerGridNavigation.destinationID(
        rows: rows, currentID: nil, direction: .right
    ) == "a")
    #expect(EmojiPickerGridNavigation.destinationID(
        rows: rows, currentID: "a", direction: .left
    ) == "a")
    #expect(EmojiPickerGridNavigation.destinationID(
        rows: rows, currentID: "c", direction: .right
    ) == "d")
    #expect(EmojiPickerGridNavigation.destinationID(
        rows: rows, currentID: "d", direction: .left
    ) == "c")
    #expect(EmojiPickerGridNavigation.destinationID(
        rows: rows, currentID: "c", direction: .down
    ) == "f")
    #expect(EmojiPickerGridNavigation.destinationID(
        rows: rows, currentID: "f", direction: .down
    ) == "g")
    #expect(EmojiPickerGridNavigation.destinationID(
        rows: rows, currentID: "g", direction: .up
    ) == "d")
}

@Test func `emoji picker only stays open for explicit persistent shift selection`() {
    #expect(EmojiPickerActivationPolicy.keepsPickerPresented(
        allowsPersistentSelection: true,
        shiftPressed: true
    ))
    #expect(!EmojiPickerActivationPolicy.keepsPickerPresented(
        allowsPersistentSelection: true,
        shiftPressed: false
    ))
    #expect(!EmojiPickerActivationPolicy.keepsPickerPresented(
        allowsPersistentSelection: false,
        shiftPressed: true
    ))
}

@MainActor
@Test func `custom emoji preference keys retain their display name`() {
    let emoji = DiscordEmoji(
        id: "123",
        name: "party_blob",
        guildID: GuildID(rawValue: 1)
    )
    #expect(EmojiPickerSelection.custom(emoji).usageKey == "custom:party_blob:123")
}

@Test func `message actions remain visible while their reaction picker is presented`() {
    #expect(MessageActionVisibilityPolicy.isVisible(
        isRowHovered: true,
        isReactionPickerPresented: false,
        isEditing: false
    ))
    #expect(MessageActionVisibilityPolicy.isVisible(
        isRowHovered: false,
        isReactionPickerPresented: true,
        isEditing: false
    ))
    #expect(!MessageActionVisibilityPolicy.isVisible(
        isRowHovered: false,
        isReactionPickerPresented: false,
        isEditing: false
    ))
    #expect(!MessageActionVisibilityPolicy.isVisible(
        isRowHovered: true,
        isReactionPickerPresented: true,
        isEditing: true
    ))
}

@Test func `emoji picker only asks the scroll view to reveal changed rows`() {
    #expect(!EmojiPickerScrollPolicy.shouldReveal(
        previousRowID: "row:4",
        destinationRowID: "row:4"
    ))
    #expect(EmojiPickerScrollPolicy.shouldReveal(
        previousRowID: "row:4",
        destinationRowID: "row:5"
    ))
    #expect(EmojiPickerScrollPolicy.shouldReveal(
        previousRowID: nil,
        destinationRowID: "row:1"
    ))
}

@MainActor
@Test func `app model loads demo and sends message`() async {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    #expect(model.snapshot != nil)
    #expect(model.selectedChannel != nil)
    #expect(model.supportsCapability(.components))
    let before = model.messages.count
    model.updateDraft("hello from test")
    await model.send()
    #expect(model.messages.count == before + 1)
    #expect(model.messages.last?.content == "hello from test")
}

@Test func `component control identity is scoped to its message`() {
    let first = ComponentControlKey(messageID: MessageID(rawValue: 1), customID: "confirm")
    let second = ComponentControlKey(messageID: MessageID(rawValue: 2), customID: "confirm")
    #expect(first != second)
    #expect(Set([first, second]).count == 2)
}

@Test func `rich message selection copies custom emoji as its discord token`() {
    let value = NSMutableAttributedString(string: "hello ")
    let attachment = NSMutableAttributedString(attachment: NSTextAttachment())
    attachment.addAttribute(
        .discordEmojiToken,
        value: "<:wave:123>",
        range: NSRange(location: 0, length: attachment.length)
    )
    value.append(attachment)
    value.append(NSAttributedString(string: " @Design"))

    #expect(
        RichMessageCopySerializer.string(
            from: value,
            range: NSRange(location: 0, length: value.length)
        ) == "hello <:wave:123> @Design"
    )
}

@MainActor
@Test func `selected custom emoji exposes an attachment overlay rect`() throws {
    let attachment = NSTextAttachment()
    attachment.image = NSImage(size: NSSize(width: 22, height: 22))
    attachment.bounds = NSRect(x: 0, y: -3, width: 22, height: 22)
    let value = NSMutableAttributedString(string: "before ")
    value.append(NSAttributedString(attachment: attachment))
    value.append(NSAttributedString(string: " after"))

    let textView = RichMessageNSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 40))
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.containerSize = NSSize(width: 240, height: 40)
    textView.textStorage?.setAttributedString(value)
    textView.setSelectedRange(NSRange(location: 7, length: 1))
    textView.layoutManager?.ensureLayout(for: try #require(textView.textContainer))

    let rect = try #require(textView.attachmentSelectionRects().first)
    #expect(rect.width >= 22)
    #expect(rect.height >= 22)
}

@MainActor
@Test func `mention popover anchor tracks the exact inline attachment glyph`() throws {
    let token = "<@42>"
    let presentation = MentionPresentation(
        rawToken: token,
        label: "@Maya",
        target: .user(UserID(rawValue: 42))
    )
    let value = NSMutableAttributedString(string: "before ")
    value.append(MentionAttachmentRenderer.attributedString(presentation: presentation))
    value.append(NSAttributedString(string: " after"))

    let window = NSWindow(
        contentRect: CGRect(x: 120, y: 140, width: 420, height: 180),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    let contentView = NSView(frame: window.contentLayoutRect)
    let textView = RichMessageNSTextView(frame: CGRect(x: 36, y: 70, width: 320, height: 44))
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.containerSize = NSSize(width: 320, height: 44)
    textView.textStorage?.setAttributedString(value)
    contentView.addSubview(textView)
    window.contentView = contentView
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }

    let index = 7
    textView.layoutManager?.ensureLayout(for: try #require(textView.textContainer))
    let glyphRect = try #require(textView.mentionAttachmentRect(at: index, rawToken: token))
    let anchor = try #require(textView.mentionPopoverAnchor(at: index, rawToken: token))
    #expect(anchor.sourceView === textView)
    #expect(anchor.sourceRect() == glyphRect)
    #expect(glyphRect.width >= 50)
    #expect(glyphRect.height >= 21)

    let tracker = StablePopoverAnchorTracker()
    let firstSourceRect = try #require(anchor.sourceRect())
    let firstFrame = try #require(tracker.attach(
        to: textView,
        sourceRect: firstSourceRect
    ))
    #expect(firstFrame != contentView.bounds)

    textView.frame.origin.x += 48
    let movedSourceRect = try #require(anchor.sourceRect())
    let movedFrame = try #require(tracker.attach(
        to: textView,
        sourceRect: movedSourceRect
    ))
    #expect(abs(movedFrame.minX - firstFrame.minX - 48) <= 0.5)
    #expect(abs(movedFrame.width - glyphRect.width) <= 0.5)
}

@MainActor
@Test func `selecting a different message clears the previous message selection`() {
    let first = RichMessageNSTextView()
    first.string = "first message"
    first.setSelectedRange(NSRange(location: 0, length: 5))
    first.claimSelectionOwnership()

    let second = RichMessageNSTextView()
    second.string = "second message"
    second.setSelectedRange(NSRange(location: 0, length: 6))
    second.claimSelectionOwnership()

    #expect(first.selectedRange().length == 0)
    #expect(second.selectedRange() == NSRange(location: 0, length: 6))
}

@MainActor
@Test func `reply summary removes markdown and collapses multiline content`() {
    let summary = MessageReplySummary.text(
        content: "# **test**\n[DiscordKit](https://example.com) <:cat_blob:123> <@42>"
    ) { mention in
        mention.id == "42" ? "@Maya" : "@unknown-user"
    }

    #expect(summary == "test DiscordKit :cat_blob: @Maya")
    #expect(MessageReplySummary.text(content: " \n\t ") == "Attachment")
}

@Test func `only supported offline flags select testing mode`() {
    #expect(AppLaunchConfiguration(arguments: ["SakuraCord"]).mode == .normal)
    #expect(AppLaunchConfiguration(arguments: ["SakuraCord", "--offline"]).mode == .offlineTesting)
    let longList = AppLaunchConfiguration(arguments: ["SakuraCord", "--offline-long-server-list"])
    #expect(longList.mode == .offlineTesting)
    #expect(longList.includesLongServerList)
}

@MainActor
@Test func `network disabled normal launch stops signed out without mock data`() async {
    let model = AppModel(launchMode: .normal, discordNetworkDisabledOverride: true)
    #expect(model.sessionState == .restoring)
    await model.start()

    #expect(model.sessionState == .signedOut)
    #expect(model.snapshot == nil)
    #expect(model.visibleChannels.isEmpty)
    #expect(!model.isOfflineTesting)
}

@MainActor
@Test func `offline launch never consults its credential store`() async {
    let credentials = CredentialAccessProbeStore()
    let model = AppModel(launchMode: .offlineTesting, credentialStore: credentials)

    await model.start()

    #expect(model.sessionState == .workspace)
    #expect(await credentials.accessCount == 0)
}

@MainActor
@Test func `interactive sign in keeps login presentation alive until bootstrap finishes`() async {
    let provider = SuspendedBootstrapTestProvider()
    let model = AppModel(
        launchMode: .normal,
        discordNetworkDisabledOverride: false,
        restoresStoredSession: false,
        authenticatedProviderFactory: { _, _ in provider }
    )
    await model.start()
    #expect(model.sessionState == .signedOut)

    let connection = Task {
        await model.connectAuthenticatedAccount(
            CredentialHandle(accountID: "93000"),
            preservesInteractivePresentation: true
        )
    }
    await provider.waitUntilBootstrapStarts()

    // Switching to `.connecting` here destroys DiscordLoginView, whose
    // disappearance cancels the task that is performing this bootstrap.
    #expect(model.sessionState == .signedOut)

    await provider.releaseBootstrap()
    #expect(await connection.value)
    #expect(model.sessionState == .workspace)
    #expect(model.isAuthenticated)
}

private actor CredentialAccessProbeStore: CredentialStore {
    private(set) var accessCount = 0

    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        accessCount += 1
        return CredentialHandle(accountID: accountID)
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        accessCount += 1
        return Data()
    }

    func remove(_ handle: CredentialHandle) async throws {
        accessCount += 1
    }

    func handles() async throws -> [CredentialHandle] {
        accessCount += 1
        return []
    }
}

@MainActor
@Test func `interactive sign in failure stays signed out and exposes bootstrap error`() async {
    let provider = SuspendedBootstrapTestProvider(bootstrapError: "fixture bootstrap stopped")
    let model = AppModel(
        launchMode: .normal,
        discordNetworkDisabledOverride: false,
        restoresStoredSession: false,
        authenticatedProviderFactory: { _, _ in provider }
    )
    await model.start()

    let connection = Task {
        await model.connectAuthenticatedAccount(
            CredentialHandle(accountID: "93000"),
            preservesInteractivePresentation: true
        )
    }
    await provider.waitUntilBootstrapStarts()
    #expect(model.sessionState == .signedOut)

    await provider.releaseBootstrap()
    #expect(await !(connection.value))
    #expect(model.sessionState == .signedOut)
    #expect(model.errorMessage == "fixture bootstrap stopped")
}

@MainActor
@Test func `replying targets the selected message and clears after sending`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let target = try #require(model.messages.first)

    model.reply(to: target)
    #expect(model.replyingTo?.id == target.id)

    model.updateDraft("reply from test")
    await model.send()

    #expect(model.messages.last?.replyTo == target.id)
    #expect(model.messageRows.last?.replyPreview?.messageID == target.id)
    #expect(model.messageRows.last?.replyPreview?.content == target.content)
    #expect(model.replyingTo == nil)
}

@MainActor
@Test func `message grouping matches discord continuation rules`() {
    let author = User(id: UserID(rawValue: 1), username: "one", displayName: "One")
    let other = User(id: UserID(rawValue: 2), username: "two", displayName: "Two")
    let channel = ChannelID(rawValue: 10)
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let messages = [
        Message(id: MessageID(rawValue: 1), channelID: channel, author: author, content: "first", timestamp: base),
        Message(id: MessageID(rawValue: 2), channelID: channel, author: author, content: "six minutes", timestamp: base.addingTimeInterval(6 * 60)),
        Message(id: MessageID(rawValue: 3), channelID: channel, author: author, content: "seven minutes", timestamp: base.addingTimeInterval(13 * 60)),
        Message(id: MessageID(rawValue: 4), channelID: channel, author: other, content: "other author", timestamp: base.addingTimeInterval(13 * 60 + 1)),
        Message(id: MessageID(rawValue: 5), channelID: channel, author: other, content: "reply", timestamp: base.addingTimeInterval(13 * 60 + 2), replyTo: MessageID(rawValue: 1))
    ]

    let rows = MessageGrouping.rows(for: messages)
    #expect(rows.map(\.startsGroup) == [true, false, true, true, true])
}

@MainActor
@Test func `system messages break surrounding author groups`() {
    let author = User(id: UserID(rawValue: 1), username: "nova", displayName: "Nova")
    let start = Date(timeIntervalSince1970: 1_000)
    let messages = [
        Message(
            id: MessageID(rawValue: 1), channelID: ChannelID(rawValue: 1), author: author,
            content: "before", timestamp: start
        ),
        Message(
            id: MessageID(rawValue: 2), channelID: ChannelID(rawValue: 1), author: author,
            content: "", timestamp: start.addingTimeInterval(10), type: .userJoin
        ),
        Message(
            id: MessageID(rawValue: 3), channelID: ChannelID(rawValue: 1), author: author,
            content: "after", timestamp: start.addingTimeInterval(20)
        )
    ]

    #expect(MessageGrouping.rows(for: messages).map(\.startsGroup) == [true, true, true])
}

@MainActor
@Test func `application command responses break surrounding app groups`() {
    let app = User(
        id: UserID(rawValue: 10), username: "verified", displayName: "Verified", isBot: true
    )
    let channel = ChannelID(rawValue: 1)
    let start = Date(timeIntervalSince1970: 1_000)
    let messages = [
        Message(
            id: MessageID(rawValue: 1), channelID: channel, author: app,
            content: "before", timestamp: start
        ),
        Message(
            id: MessageID(rawValue: 2), channelID: channel, author: app,
            content: "result", timestamp: start.addingTimeInterval(1), type: .chatInputCommand
        ),
        Message(
            id: MessageID(rawValue: 3), channelID: channel, author: app,
            content: "after", timestamp: start.addingTimeInterval(2)
        )
    ]

    #expect(MessageGrouping.rows(for: messages).map(\.startsGroup) == [true, true, true])
}

@MainActor
@Test func `member sections use hoisted roles and sort members`() {
    let members = [
        Member(
            user: User(id: UserID(rawValue: 1), username: "zed", displayName: "Zed"),
            roleName: "Moderator",
            status: .online,
            rolePosition: 10,
            isRoleCategory: true
        ),
        Member(
            user: User(id: UserID(rawValue: 2), username: "amy", displayName: "Amy"),
            roleName: "Moderator",
            status: .idle,
            rolePosition: 10,
            isRoleCategory: true
        ),
        Member(
            user: User(id: UserID(rawValue: 3), username: "sam", displayName: "Sam"),
            roleName: "Member",
            status: .online
        ),
        Member(
            user: User(id: UserID(rawValue: 4), username: "off", displayName: "Offline"),
            roleName: "Moderator",
            status: .offline,
            rolePosition: 10,
            isRoleCategory: true
        )
    ]

    let sections = MemberSection.make(from: members)
    #expect(sections.map(\.title) == ["Moderator", "Online", "Offline"])
    #expect(sections[0].members.map(\.user.displayName) == ["Amy", "Zed"])
    #expect(sections[2].members.map(\.user.displayName) == ["Offline"])
}

@MainActor
@Test func `channel groups place voice channels after text channels`() {
    let guildID = GuildID(rawValue: 20)
    let categoryID = ChannelID(rawValue: 21)
    let channels = [
        Channel(id: ChannelID(rawValue: 22), guildID: guildID, name: "Voice first by position", kind: .voice, category: "Chat", categoryID: categoryID, position: 0),
        Channel(id: ChannelID(rawValue: 23), guildID: guildID, name: "general", category: "Chat", categoryID: categoryID, position: 2),
        Channel(id: ChannelID(rawValue: 24), guildID: guildID, name: "announcements", kind: .announcement, category: "Chat", categoryID: categoryID, position: 3),
        Channel(id: ChannelID(rawValue: 25), guildID: guildID, name: "Voice second", kind: .voice, category: "Chat", categoryID: categoryID, position: 1)
    ]

    let group = ChannelGroup.make(from: channels)[0]
    #expect(group.channels.map(\.name) == ["general", "announcements", "Voice first by position", "Voice second"])
}

@MainActor
@Test func `selecting voice channel opens its text chat by default without joining`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let voiceChannel = try #require(model.visibleChannels.first(where: { $0.kind == .voice }))

    model.selectedChannelID = voiceChannel.id

    #expect(model.selectedChannel?.id == voiceChannel.id)
    #expect(model.selectedChannel?.kind == .voice)
    #expect(model.activeVoiceChannel == nil)
    #expect(model.isVoiceChatOpen)
    #expect(await eventuallyOnMain { !model.isLoadingMessages && !model.messages.isEmpty })
}

@MainActor
@Test func `voice channel selection loads once and closed chat can be reopened`() async throws {
    let provider = ChannelLoadTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let voiceChannel = ChannelID(rawValue: 91003)

    model.selectedChannelID = voiceChannel
    #expect(await eventuallyOnMain { !model.isLoadingMessages })
    #expect(await provider.requestCount(for: voiceChannel) == 1)
    #expect(model.activeVoiceChannel == nil)
    #expect(model.isVoiceChatOpen)

    let channel = try #require(model.selectedChannel)
    model.openVoiceChat(for: channel)
    #expect(await provider.requestCount(for: voiceChannel) == 1)
    #expect(model.messages.map(\.channelID) == [voiceChannel])
    #expect(model.activeVoiceChannel == nil)
    #expect(model.isVoiceChatOpen)

    model.openVoiceChat(for: channel)
    try await Task.sleep(for: .milliseconds(30))
    #expect(await provider.requestCount(for: voiceChannel) == 1)

    model.closeVoiceChat()
    #expect(!model.isVoiceChatOpen)
    #expect(model.activeVoiceChannel == nil)

    model.openVoiceChat(for: channel)
    #expect(model.isVoiceChatOpen)
    try await Task.sleep(for: .milliseconds(40))
    #expect(!model.isLoadingMessages)
    #expect(await provider.requestCount(for: voiceChannel) == 2)
    #expect(model.activeVoiceChannel == nil)
}

@MainActor
@Test func `profile role names remove custom emoji markup and collapse whitespace`() {
    #expect(
        ProfileRolePresentation.normalizedName("  Developers   <:sparkle:123456>   💖  ")
            == "Developers 💖"
    )
    #expect(ProfileRolePresentation.normalizedName("<a:dance:987654>") == "")
    #expect(ProfileRolePresentation.collapsedLimit == 5)
}

@MainActor
@Test func `selecting member loads full profile`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let member = try #require(model.members.first)

    model.selectMember(member)
    #expect(await eventuallyOnMain { model.selectedProfile?.id == member.id })

    let profile = try #require(model.selectedProfile)
    #expect(model.isInspectorProfilePresented)
    #expect(profile.id == member.id)
    #expect(!profile.badges.isEmpty)
    #expect(!profile.mutualGuilds.isEmpty)
    #expect(profile.status == member.status)
}

@MainActor
@Test func `message profile does not compete with the member inspector popover`() async throws {
    let model = AppModel(launchMode: .offlineTesting)
    await model.start()
    let member = try #require(model.members.first)
    model.showInspector = false

    model.showProfile(for: member.user)
    #expect(await eventuallyOnMain { model.selectedProfile?.id == member.id })

    #expect(model.selectedMember?.id == member.id)
    #expect(model.selectedProfile?.id == member.id)
    #expect(!model.isInspectorProfilePresented)
    #expect(!model.showInspector)

    model.selectMember(member)
    #expect(model.isInspectorProfilePresented)
}

@MainActor
private func eventuallyOnMain(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    for _ in 0 ..< 200 {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

@MainActor
@Test func `demo emoji preferences and custom emoji assets stay offline`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()

    #expect(model.favoriteEmojiKeys.isEmpty)
    #expect(model.emojiUsageCounts.isEmpty)
    model.recordEmojiUse("native:✨")
    #expect(model.emojiUsageCounts == ["native:✨": 1])

    let guildID = try #require(model.selectedGuildID)
    let emojis = try await provider.emojis(in: guildID)
    #expect(emojis.count == 3)
    #expect(emojis.allSatisfy { $0.imageURL?.isFileURL == true })
    #expect(emojis.allSatisfy { $0.imageURL?.host != "cdn.discordapp.com" })
    #expect(emojis.allSatisfy { emoji in
        emoji.imageURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
    })
    for emoji in emojis {
        ComposerEmojiImageStore.shared.register(emoji)
        #expect(ComposerEmojiImageStore.shared.cachedImage(for: emoji.messageToken) != nil)
    }
    let attributed = ComposerEmojiAttributedText.make(
        emojis.map(\.messageToken).joined(separator: " ")
    )
    var renderedAttachmentCount = 0
    attributed.enumerateAttribute(
        .attachment,
        in: NSRange(location: 0, length: attributed.length)
    ) { value, _, _ in
        guard let attachment = value as? NSTextAttachment else { return }
        #expect(attachment.image?.isValid == true)
        renderedAttachmentCount += 1
    }
    #expect(renderedAttachmentCount == emojis.count)
    let settings = try await provider.emojiUserSettings()
    #expect(settings.favoriteKeys.prefix(3) == [
        "custom:900000000000000201", "white_check_mark", "x"
    ])
    #expect(settings.frequentlyUsedKeys.count == 18)
}

@MainActor
@Test func `channel loads are single flight cached and protected from stale responses`() async throws {
    let provider = ChannelLoadTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)

    await model.start()
    let firstChannel = ChannelID(rawValue: 91001)
    let secondChannel = ChannelID(rawValue: 91002)
    #expect(await provider.requestCount(for: firstChannel) == 1)
    #expect(model.messages.map(\.channelID) == [firstChannel])

    model.selectedChannelID = secondChannel
    try await Task.sleep(for: .milliseconds(5))
    model.selectedChannelID = firstChannel

    // The in-memory page is restored synchronously, before either refresh finishes.
    #expect(model.messages.map(\.channelID) == [firstChannel])
    #expect(!model.isLoadingMessages)
    try await Task.sleep(for: .milliseconds(160))

    #expect(model.selectedChannelID == firstChannel)
    #expect(model.messages.allSatisfy { $0.channelID == firstChannel })
    #expect(await provider.requestCount(for: firstChannel) == 2)
    #expect(await provider.requestCount(for: secondChannel) == 1)
}

@MainActor
@Test func `app model reconciles lazy production reactors without repeated reads`() async throws {
    let provider = ChannelLoadTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()

    let message = try #require(model.messages.first)
    let reaction = try #require(message.reactions.first)
    #expect(reaction.reactors.isEmpty)
    await model.loadReactionReactors(reaction, on: message)

    let loaded = try #require(model.messages.first?.reactions.first)
    #expect(loaded.reactors.map(\.displayName) == ["One", "Two", "Three", "Four", "Five"])
    #expect(await provider.reactorRequestCount() == 1)

    await model.loadReactionReactors(loaded, on: try #require(model.messages.first))
    #expect(await provider.reactorRequestCount() == 1)
}

@MainActor
@Test func `visible reaction preview reads stay within the app request budget`() async {
    let provider = ChannelLoadTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()

    await withTaskGroup(of: Void.self) { group in
        for value in 0 ..< 12 {
            let message = Message(
                id: MessageID(rawValue: UInt64(92000 + value)),
                channelID: ChannelID(rawValue: 91001),
                author: User(
                    id: UserID(rawValue: 91000),
                    username: "tester",
                    displayName: "Tester"
                ),
                content: "reaction \(value)",
                reactions: [Reaction(emoji: "emoji-\(value)", count: 1)]
            )
            group.addTask {
                await model.loadReactionReactors(message.reactions[0], on: message)
            }
        }
    }

    #expect(await provider.reactorRequestCount() == 12)
    #expect(
        await provider.maximumConcurrentReactorRequestCount()
            <= AppModel.maximumConcurrentReactionReactorLoads
    )
}

@MainActor
@Test func `voice server reallocation keeps the call selected and reconnects`() async throws {
    let provider = VoiceMigrationTestProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let voiceChannel = try #require(model.visibleChannels.first)

    await model.joinVoice(voiceChannel)
    #expect(model.activeVoiceChannel?.id == voiceChannel.id)
    #expect(model.voiceSessionState == .connected)

    await provider.emit(.voiceServerChanged(nil))
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.activeVoiceChannel?.id == voiceChannel.id)
    #expect(model.voiceSessionState == .reconnecting)

    await provider.emit(.voiceServerChanged(provider.connectionInfo(token: "replacement")))
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.activeVoiceChannel?.id == voiceChannel.id)
    #expect(model.voiceSessionState == .connected)
}

private actor ChannelLoadTestProvider: ChatProvider {
    private let user = User(id: UserID(rawValue: 91000), username: "tester", displayName: "Tester")
    private let testChannels = [
        Channel(id: ChannelID(rawValue: 91001), guildID: nil, name: "general"),
        Channel(id: ChannelID(rawValue: 91002), guildID: nil, name: "other"),
        Channel(
            id: ChannelID(rawValue: 91003),
            guildID: nil,
            name: "Voice Room",
            kind: .voice
        )
    ]
    private var messageRequests: [ChannelID: Int] = [:]
    private var reactorRequests = 0
    private var activeReactorRequests = 0
    private var maximumActiveReactorRequests = 0

    func bootstrap() async throws -> BootstrapSnapshot {
        BootstrapSnapshot(currentUser: user, guilds: [], channels: testChannels, members: [])
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        testChannels
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        []
    }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus {
        .online
    }

    func updateStatus(_ status: PresenceStatus) async throws {}

    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws -> MessagePage {
        messageRequests[channelID, default: 0] += 1
        // Intentionally ignore cancellation to prove the model's generation guard works.
        let delay: Duration = channelID == testChannels[1].id ? .milliseconds(100) : .milliseconds(20)
        try? await Task.sleep(for: delay)
        let message = Message(
            id: MessageID(rawValue: channelID.rawValue),
            channelID: channelID,
            author: user,
            content: "channel \(channelID)",
            reactions: [Reaction(emoji: "🔥", count: 8)]
        )
        return MessagePage(messages: [message], hasMoreBefore: false)
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {}
    func reactionReactors(
        for emoji: String,
        messageID: MessageID,
        channelID: ChannelID,
        reactionCount: Int
    ) async throws -> [ReactionReactor] {
        reactorRequests += 1
        activeReactorRequests += 1
        maximumActiveReactorRequests = max(
            maximumActiveReactorRequests,
            activeReactorRequests
        )
        defer { activeReactorRequests -= 1 }
        try await Task.sleep(for: .milliseconds(25))
        return (1 ... 5).map {
            ReactionReactor(
                id: UserID(rawValue: UInt64($0)),
                displayName: ["One", "Two", "Three", "Four", "Five"][$0 - 1]
            )
        }
    }
    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { $0.finish() }
    }

    func disconnect() async {}

    func requestCount(for channelID: ChannelID) -> Int {
        messageRequests[channelID, default: 0]
    }

    func reactorRequestCount() -> Int {
        reactorRequests
    }

    func maximumConcurrentReactorRequestCount() -> Int {
        maximumActiveReactorRequests
    }
}

private actor SuspendedBootstrapTestProvider: ChatProvider {
    private let user = User(id: UserID(rawValue: 93000), username: "tester", displayName: "Tester")
    private let channel = Channel(id: ChannelID(rawValue: 93001), guildID: nil, name: "general")
    private var bootstrapStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var bootstrapContinuation: CheckedContinuation<Void, Never>?
    private let bootstrapError: String?

    init(bootstrapError: String? = nil) {
        self.bootstrapError = bootstrapError
    }

    func bootstrap() async throws -> BootstrapSnapshot {
        bootstrapStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { bootstrapContinuation = $0 }
        if let bootstrapError {
            throw ChatProviderError.invalidRequest(bootstrapError)
        }
        return BootstrapSnapshot(currentUser: user, guilds: [], channels: [channel], members: [])
    }

    func waitUntilBootstrapStarts() async {
        if bootstrapStarted {
            return
        }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseBootstrap() {
        bootstrapContinuation?.resume()
        bootstrapContinuation = nil
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        [channel]
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        []
    }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus {
        .online
    }

    func updateStatus(_ status: PresenceStatus) async throws {}
    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws -> MessagePage {
        MessagePage(messages: [], hasMoreBefore: false)
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {}
    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { $0.finish() }
    }

    func disconnect() async {}
}

private actor VoiceMigrationTestProvider: ChatProvider {
    private let guild = Guild(id: GuildID(rawValue: 92000), name: "Voice Test")
    private let user = User(id: UserID(rawValue: 92001), username: "tester", displayName: "Tester")
    private let channel = Channel(
        id: ChannelID(rawValue: 92002),
        guildID: GuildID(rawValue: 92000),
        name: "Lounge",
        kind: .voice
    )
    private var continuation: AsyncStream<ClientEvent>.Continuation?

    func bootstrap() async throws -> BootstrapSnapshot {
        BootstrapSnapshot(currentUser: user, guilds: [guild], channels: [channel], members: [])
    }

    func channels(in guildID: GuildID?) async throws -> [Channel] {
        [channel]
    }

    func members(in guildID: GuildID?) async throws -> [Member] {
        []
    }

    func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        throw ChatProviderError.invalidRequest("Profiles are not part of this test.")
    }

    func currentStatus() async -> PresenceStatus {
        .online
    }

    func updateStatus(_ status: PresenceStatus) async throws {}
    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws -> MessagePage {
        MessagePage(messages: [], hasMoreBefore: false)
    }

    func send(_ draft: SendMessageDraft) async throws -> Message {
        throw ChatProviderError.invalidRequest("Sending is not part of this test.")
    }

    func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws -> Message {
        throw ChatProviderError.invalidRequest("Editing is not part of this test.")
    }

    func delete(messageID: MessageID, channelID: ChannelID) async throws {}
    func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID) async throws {}
    func joinVoice(
        channelID: ChannelID,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool
    ) async throws -> VoiceConnectionInfo {
        connectionInfo(token: "initial")
    }

    func updateVoiceState(
        channelID: ChannelID?,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool,
        selfVideo: Bool
    ) async throws {}
    func eventStream() async -> AsyncStream<ClientEvent> {
        AsyncStream { continuation = $0 }
    }

    func disconnect() async {
        continuation?.finish()
        continuation = nil
    }

    func emit(_ event: ClientEvent) {
        continuation?.yield(event)
    }

    func connectionInfo(token: String) -> VoiceConnectionInfo {
        VoiceConnectionInfo(
            serverID: guild.id.description,
            channelID: channel.id,
            guildID: guild.id,
            userID: user.id,
            sessionID: "session",
            token: token,
            endpoint: "mock.sakuracord.invalid"
        )
    }
}
