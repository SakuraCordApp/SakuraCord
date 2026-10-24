import AppKit
@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
@Test(arguments: [false, true], [false, true])
func `timeline layout preparation commits a complete update or discards superseded work`(
    replacesDuringPreparation: Bool,
    changesPresentation: Bool
) async throws {
    let model = AppModel(launchMode: .offlineTesting)
    let channelID = ChannelID(rawValue: 99_400)
    let author = User(id: UserID(rawValue: 99_401), username: "history", displayName: "History")
    let messages = (0 ..< 84).map {
        Message(
            id: MessageID(rawValue: UInt64(100_000 + $0)),
            channelID: channelID, author: author,
            content: "History message \($0)"
        )
    }
    let original = changesPresentation ? messages : Array(messages.suffix(20))
    model.replaceSelectedMessages(with: original)
    let timeline = NativeMessageTimelineView(
        model: model, conversation: .channel(channelID), beginning: nil,
        firstMessageStartsDayOverride: nil, hasMoreMessages: false,
        isLoadingEarlier: false, bottomContentInset: 0,
        unreadMessageID: nil, highlightedMessageID: nil,
        initialScrollTarget: .bottom, scrollRequest: nil,
        runsPerformanceAutoScroll: false, loadEarlier: {}, openReply: { _ in },
        onScrollActivityChange: { _ in }, onScrollStateChange: { _ in },
        onUserScrollBegan: {}, onUserScrollEnded: { _ in }
    )
    let coordinator = timeline.makeCoordinator()
    // Keep the viewport fixed while preparation yields. The coordinator enables
    // the vertical scroller even without a document view; a default legacy
    // scroller can then shrink the clip width during the await. Match production's
    // overlay scrollers so that AppKit tiling cannot invalidate this fixture.
    let viewport = CGRect(x: 0, y: 0, width: 820, height: 300)
    let scrollView = NSScrollView(frame: viewport)
    scrollView.scrollerStyle = .overlay
    let canvas = NativeTimelineCanvasView(frame: viewport)
    coordinator.canvas = canvas
    defer { withExtendedLifetime(canvas) { coordinator.stopObserving() } }
    coordinator.update(parent: timeline, scrollView: scrollView)
    canvas.suppressesHoverPresentation = true

    if changesPresentation {
        model.invalidateTimelinePresentation()
    } else {
        model.replaceSelectedMessages(with: messages)
    }
    coordinator.update(parent: timeline, scrollView: scrollView)
    let preparation = try #require(coordinator.layoutPreparationTask)
    let preparedState = try #require(coordinator.layoutPreparation)
    // Service pending scroller layout before the preparation task runs.
    scrollView.tile()
    #expect(scrollView.contentView.bounds.width.rounded() == preparedState.width)
    #expect(coordinator.messageIDs == original.map(\.id))

    if replacesDuringPreparation {
        let replacement = Array(original.suffix(5))
        model.replaceSelectedMessages(with: replacement)
        coordinator.update(parent: timeline, scrollView: scrollView)
        await preparation.value
        #expect(coordinator.layoutPreparationTask == nil)
        #expect(coordinator.messageIDs == replacement.map(\.id))
    } else {
        canvas.suppressesHoverPresentation = false
        await preparation.value
        #expect(coordinator.layoutPreparationTask == nil)
        #expect(coordinator.messageIDs == messages.map(\.id))
        #expect(preparedState.isComplete)
        #expect(coordinator.recentLayoutCacheHits == (changesPresentation ? coordinator.items.count : 64))
        #expect(coordinator.items.count == coordinator.layouts.count)
        #expect(coordinator.layouts.count == coordinator.rowHeights.count)
    }
}

@MainActor
@Test(arguments: [false, true])
func `timeline server tags own their activation and reject stale identity layouts`(
    missingGuildID: Bool
) throws {
    let model = AppModel(launchMode: .offlineTesting)
    let channelID = ChannelID(rawValue: 99_410)
    let guildID = GuildID(rawValue: 99_411)
    let tagGuildID = GuildID(rawValue: 99_412)
    let author = User(
        id: UserID(rawValue: 99_413), username: "tag.fixture", displayName: "Tag Fixture",
        primaryGuild: PrimaryGuildIdentity(guildID: missingGuildID ? nil : tagGuildID, tag: "TAG")
    )
    model.membersByGuildID[guildID] = [author.id: Member(user: author, roleName: "Member", status: .online)]
    let message = Message(
        id: MessageID(rawValue: 99_414), channelID: channelID, author: author,
        content: "Tag activation", guildID: guildID
    )
    let item = NativeMessageTimelineItem.message(
        MessageRowPresentation(message: message, startsGroup: true, startsDay: false,
                               replyPreview: nil, isReplyAvailable: false),
        isUnreadBoundary: false, isHighlighted: false
    )
    let timeline = NativeMessageTimelineView(
        model: model, conversation: .channel(channelID), beginning: nil,
        firstMessageStartsDayOverride: nil, hasMoreMessages: false,
        isLoadingEarlier: false, bottomContentInset: 0,
        unreadMessageID: nil, highlightedMessageID: nil,
        initialScrollTarget: .bottom, scrollRequest: nil,
        runsPerformanceAutoScroll: false, loadEarlier: {}, openReply: { _ in },
        onScrollActivityChange: { _ in }, onScrollStateChange: { _ in },
        onUserScrollBegan: {}, onUserScrollEnded: { _ in }
    )
    let coordinator = timeline.makeCoordinator()
    defer { coordinator.stopObserving() }
    coordinator.layoutWidth = 560
    coordinator.presentationRevision = timeline.presentationRevision
    let layout = NativeTimelineRowLayout.make(item: item, width: 560, source: model)
    coordinator.cacheItemLayout(item, layout: layout)
    #expect(coordinator.cachedItemLayout(for: item, width: 560, presentationRevision: timeline.presentationRevision) != nil)

    let canvas = NativeTimelineCanvasView(frame: CGRect(x: 0, y: 0, width: 560, height: layout.height))
    canvas.storage.items = [item]
    canvas.storage.layouts = [layout]
    canvas.storage.rowOrigins = [0]
    canvas.storage.contentHeight = layout.height
    let tagFrame = try #require(layout.serverTagRegion?.frame)
    let authorFrame = try #require(layout.authorFrame)
    #expect(canvas.pointerActivationTarget(at: CGPoint(x: authorFrame.midX, y: authorFrame.midY)) == .authorProfile(message.id))
    let tagActivation = canvas.pointerActivationTarget(at: CGPoint(x: tagFrame.midX, y: tagFrame.midY))
    #expect(tagActivation == (missingGuildID ? nil : .serverTag(message.id, tagGuildID)))

    // A member update may leave the immutable message and presentation revision
    // unchanged while replacing the author's server identity.
    var updatedAuthor = author
    updatedAuthor.primaryGuild = PrimaryGuildIdentity(guildID: GuildID(rawValue: 99_415), tag: "NEW")
    model.membersByGuildID[guildID]?[author.id]?.user = updatedAuthor
    #expect(coordinator.cachedItemLayout(for: item, width: 560, presentationRevision: timeline.presentationRevision) == nil)
}
