import AppKit
import MessageRendering
@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
@Test func `relative timestamp refresh replaces selectable attachments without losing selection`() throws {
    let source = "before <t:1000000:R> after"
    let view = SelectableMessageTextView(source: source, emojiSize: 22, mentionPresentations: [:])
    let coordinator = view.makeCoordinator()
    let textView = RichMessageNSTextView()
    let before = Date(timeIntervalSince1970: 999_995)
    let after = Date(timeIntervalSince1970: 1_000_120)
    view.render(in: textView, coordinator: coordinator, at: before)
    let range = NSRange(location: 0, length: 3)
    textView.setSelectedRange(range)
    let first = try #require(timestampAttachment(in: textView.attributedString()))
    view.render(in: textView, coordinator: coordinator, at: after)
    let second = try #require(timestampAttachment(in: textView.attributedString()))
    #expect(first !== second)
    #expect(first.presentation.label != second.presentation.label)
    #expect(second.presentation.label == DiscordTimestampToken(seconds: 1_000_000, style: .relative).formatted(relativeTo: after))
    #expect(textView.selectedRange() == range)
    #expect(second.image?.accessibilityDescription == second.presentation.label)
    coordinator.cancelEmojiLoads()
}

@MainActor
private func timestampAttachment(in text: NSAttributedString) -> MentionTextAttachment? {
    var result: MentionTextAttachment?
    text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
        if let attachment = value as? MentionTextAttachment, attachment.presentation.isTimestamp {
            result = attachment
        }
    }
    return result
}

@MainActor
@Test func `timestamp clock coalesces owners and releases detached listeners`() {
    let clock = RelativeTimestampClock()
    let owner = NSObject()
    var calls = 0
    clock.observe(owner) { _ in calls += 100 }
    clock.observe(owner) { _ in calls += 1 }
    clock.pulse(at: Date(timeIntervalSince1970: 100))
    #expect(calls == 1)
    clock.remove(owner)
    clock.pulse(at: Date(timeIntervalSince1970: 200))
    #expect(calls == 1)
}

@MainActor
@Test func `relative timestamp native refresh replaces cached labels and row geometry`() throws {
    let channelID = ChannelID(rawValue: 9_500)
    let author = User(id: UserID(rawValue: 9_501), username: "clock-fixture", displayName: "Clock fixture")
    var messages: [Message] = []
    for index in 0 ..< 30 {
        let id = MessageID(rawValue: UInt64(9_600 + index))
        let content = index == 0 ? "before <t:1000000:R> after" : "stable row \(index)"
        let timestamp = Date(timeIntervalSince1970: Double(index * 600))
        let message = Message(id: id, channelID: channelID, author: author,
                              content: content, timestamp: timestamp)
        messages.append(message)
    }
    let model = AppModel(launchMode: .offlineTesting)
    model.selectedChannelID = channelID
    model.replaceSelectedMessages(with: messages)
    let timeline = NativeMessageTimelineView(
        model: model, conversation: .channel(channelID), beginning: nil,
        firstMessageStartsDayOverride: nil, hasMoreMessages: false,
        isLoadingEarlier: false, bottomContentInset: 0, unreadMessageID: nil,
        highlightedMessageID: nil, scrollRequest: nil, runsPerformanceAutoScroll: false,
        loadEarlier: {}, openReply: { _ in }, onScrollActivityChange: { _ in },
        onScrollStateChange: { _ in }, onUserScrollBegan: {}, onUserScrollEnded: { _ in }
    )
    let coordinator = timeline.makeCoordinator()
    let scrollView = coordinator.makeScrollView()
    defer { coordinator.stopObserving() }
    scrollView.frame = CGRect(x: 0, y: 0, width: 280, height: 200)
    scrollView.tile()
    coordinator.update(parent: timeline, scrollView: scrollView)
    coordinator.reconcileViewportGeometryForTesting()
    let before = Date(timeIntervalSince1970: 999_995)
    let after = Date(timeIntervalSince1970: 1_000_120)
    let index = try #require(coordinator.items.firstIndex { $0.messageID == messages[0].id })
    let item = coordinator.items[index]
    let wrappingWidth = try #require((180 ... 400).first { width in
        let earlier = NativeTimelineRowLayout.make(item: item, width: CGFloat(width), model: model, relativeTo: before)
        let later = NativeTimelineRowLayout.make(item: item, width: CGFloat(width), model: model, relativeTo: after)
        return abs(earlier.height - later.height) >= 0.5
    })
    scrollView.frame.size.width = CGFloat(wrappingWidth)
    scrollView.tile()
    coordinator.reconcileViewportGeometryForTesting()
    coordinator.refreshTimestampLayouts(at: before)
    let oldHeight = coordinator.rowHeights[index]
    coordinator.scroll(toDocumentY: coordinator.rowOrigins[10], scrollView: scrollView)
    let oldAnchor = try #require(coordinator.visibleAnchor())
    let first = try #require(nativeTimestampLabel(in: coordinator.layouts[index].attributedContent))
    // A stale recent-conversation layout must not win over the clock refresh.
    let key = NativeMessageTimelineCoordinator.CachedItemLayoutKey(
        identifier: coordinator.items[index].identifier,
        roundedWidth: Int(coordinator.layoutWidth.rounded()), presentationRevision: coordinator.presentationRevision
    )
    coordinator.cachedItemLayouts[key] = .init(item: coordinator.items[index], layout: coordinator.layouts[index])
    coordinator.refreshTimestampLayouts(at: after)
    let second = try #require(nativeTimestampLabel(in: coordinator.layouts[index].attributedContent))
    #expect(first != second)
    #expect(second == DiscordTimestampToken(seconds: 1_000_000, style: .relative).formatted(relativeTo: after))
    #expect(coordinator.cachedItemLayouts[key] == nil)
    #expect(coordinator.rowHeights[index] == coordinator.layouts[index].height)
    #expect(coordinator.rowHeights[index] != oldHeight)
    let newAnchor = try #require(coordinator.visibleAnchor())
    #expect(newAnchor.messageID == oldAnchor.messageID)
    #expect(abs(newAnchor.offsetFromViewportTop - oldAnchor.offsetFromViewportTop) < 0.5)
    for offset in 1 ..< coordinator.rowOrigins.count {
        #expect(coordinator.rowOrigins[offset] == coordinator.rowOrigins[offset - 1] + coordinator.rowHeights[offset - 1])
    }
}

@MainActor
private func nativeTimestampLabel(in text: NSAttributedString?) -> String? {
    guard let text else { return nil }
    var label: String?
    text.enumerateAttribute(.nativeTimelineMention, in: NSRange(location: 0, length: text.length)) { value, _, _ in
        if let box = value as? NativeTimelineMentionBox, box.presentation.isTimestamp {
            label = box.presentation.label
        }
    }
    return label
}

@Test func `timestamp refresh preserves a token without an explicit format suffix`() {
    let raw = "<t:1000000>"
    let stale = MentionPresentation(rawToken: raw, label: "stale label", target: .unresolved, isTimestamp: true)
    let refreshed = TimestampMentionPresentation.refreshed([raw: stale], source: raw, at: .distantPast)
    #expect(refreshed[raw]?.label == DiscordTimestampToken(rawToken: raw)?.formatted())
    #expect(refreshed[raw]?.rawToken == raw)
    #expect(refreshed.count == 1)
}

@Test func `native timestamp observation includes reply embed and nested component content`() {
    let author = User(id: UserID(rawValue: 9_501), username: "clock-fixture", displayName: "Clock fixture")
    let embed = MessageEmbed(id: "fixture", description: "embed <t:1000000:R>", fields: [
        MessageEmbedField(name: "plain heading", value: "field <t:1000001:R>"),
    ])
    let component = MessageComponent.container(id: "container", accentColor: nil, spoiler: false, children: [
        .textDisplay(id: "text", content: "component <t:1000002:R>"),
    ])
    let message = Message(id: MessageID(rawValue: 9_502), channelID: ChannelID(rawValue: 9_500),
                          author: author, content: "body <t:1000003:R>", embeds: [embed], components: [component])
    let sources = TimestampMentionPresentation.sources(in: message, replyContent: "reply <t:1000004:R>")
    #expect(Set(sources) == ["body <t:1000003:R>", "embed <t:1000000:R>", "field <t:1000001:R>", "component <t:1000002:R>", "reply <t:1000004:R>"])
}
