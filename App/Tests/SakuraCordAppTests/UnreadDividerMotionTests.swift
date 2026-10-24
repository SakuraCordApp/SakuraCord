@testable import SakuraCord
import AppKit
import SakuraCordModels
import Testing

@MainActor @Test(arguments: [
    (false, true, true, false, true),
    (true, true, true, false, false),
    (false, false, true, false, false),
    (false, true, false, false, false),
    (false, true, true, true, false),
])
func `the divider animates only for a live change in a settled conversation`(
    conversationChanged: Bool,
    hadInitialPosition: Bool,
    hadMessages: Bool,
    isJumping: Bool,
    animates: Bool
) {
    #expect(
        NativeTimelineUnreadDividerMotion.animates(
            conversationChanged: conversationChanged,
            hadInitialPosition: hadInitialPosition,
            hadMessages: hadMessages,
            isJumpingToUnreadBoundary: isJumping
        ) == animates
    )
}

/// A timeline in a window, so a divider that is allowed to move has somewhere
/// to start.
@MainActor
private struct UnreadDividerMotionHarness {
    let model = AppModel(launchMode: .offlineTesting)
    let channelID = ChannelID(rawValue: 99_500)
    let coordinator: NativeMessageTimelineView.Coordinator
    let scrollView: NSScrollView
    let window: NSWindow
    let messages: [Message]

    /// `startsGroup` puts the unread message at the start of its own group.
    /// Otherwise it continues the group above, so a divider above it also
    /// gives it an author header on builds that break a group at the divider.
    init(reducesMotion: Bool = false, startsGroup: Bool = true) {
        let readers = [
            User(id: UserID(rawValue: 99_501), username: "reader", displayName: "Reader"),
            User(id: UserID(rawValue: 99_502), username: "writer", displayName: "Writer"),
        ]
        let channelID = channelID
        messages = (0 ..< 6).map {
            Message(
                id: MessageID(rawValue: UInt64(200_000 + $0)),
                channelID: channelID, author: readers[$0 < 4 || !startsGroup ? 0 : 1],
                content: "Message \($0)"
            )
        }
        model.replaceSelectedMessages(with: messages)
        coordinator = Self.timeline(model: model, channelID: channelID, unread: nil, target: nil)
            .makeCoordinator()
        scrollView = coordinator.makeScrollView()
        scrollView.frame = CGRect(x: 0, y: 0, width: 820, height: 700)
        window = NSWindow(
            contentRect: scrollView.frame, styleMask: .borderless, backing: .buffered, defer: false
        )
        window.contentView = scrollView
        scrollView.layoutSubtreeIfNeeded()
        coordinator.canvas?.unreadDividerReducesMotionOverride = reducesMotion
    }

    static func timeline(
        model: AppModel,
        channelID: ChannelID,
        unread: MessageID?,
        target: MessageTimelineScrollRequest.Target?,
        scrollRequest: MessageTimelineScrollRequest? = nil
    ) -> NativeMessageTimelineView {
        NativeMessageTimelineView(
            model: model, conversation: .channel(channelID), beginning: nil,
            firstMessageStartsDayOverride: nil, hasMoreMessages: false,
            isLoadingEarlier: false, bottomContentInset: 0,
            unreadMessageID: unread, highlightedMessageID: nil,
            initialScrollTarget: target, scrollRequest: scrollRequest,
            runsPerformanceAutoScroll: false, loadEarlier: {}, openReply: { _ in },
            onScrollActivityChange: { _ in }, onScrollStateChange: { _ in },
            onUserScrollBegan: {}, onUserScrollEnded: { _ in }
        )
    }

    func show(
        unread: MessageID?,
        target: MessageTimelineScrollRequest.Target? = .bottom,
        scrollRequest: MessageTimelineScrollRequest? = nil
    ) {
        coordinator.update(
            parent: Self.timeline(
                model: model, channelID: channelID, unread: unread, target: target,
                scrollRequest: scrollRequest
            ),
            scrollView: scrollView
        )
        coordinator.reconcileViewportGeometryForTesting()
    }

    var dividerIsMoving: Bool {
        guard let canvas = coordinator.canvas else { return false }
        return !canvas.unreadDividerFades.isEmpty || canvas.unreadDividerGap != nil
    }

    var gapIsOpening: Bool { coordinator.canvas?.unreadDividerGap != nil }

    var unread: MessageID { messages[4].id }
}

@MainActor @Test
func `a divider that arrives with the first placement of a conversation is simply there`() {
    let harness = UnreadDividerMotionHarness()
    harness.show(unread: nil, target: nil)
    #expect(!harness.coordinator.hasAppliedInitialPositionForTesting)

    // The history, its placement and the divider all land in one update.
    harness.show(unread: harness.unread)
    #expect(harness.coordinator.hasAppliedInitialPositionForTesting)
    #expect(!harness.dividerIsMoving)
    harness.coordinator.stopObserving()
}

@MainActor @Test
func `a divider that arrives before the first placement is simply there`() {
    let harness = UnreadDividerMotionHarness()
    harness.show(unread: nil, target: nil)
    harness.show(unread: harness.unread, target: nil)
    #expect(!harness.coordinator.hasAppliedInitialPositionForTesting)
    #expect(!harness.dividerIsMoving)
    harness.coordinator.stopObserving()
}

@MainActor @Test
func `a divider that arrives while the reader is looking at a settled conversation animates`() {
    let harness = UnreadDividerMotionHarness()
    harness.show(unread: nil)
    #expect(harness.coordinator.hasAppliedInitialPositionForTesting)

    harness.show(unread: harness.unread)
    #expect(harness.dividerIsMoving)

    // Acknowledging it animates out the same way.
    harness.coordinator.canvas?.finishUnreadDividerFades()
    #expect(!harness.dividerIsMoving)
    harness.show(unread: nil)
    #expect(harness.dividerIsMoving)
    harness.coordinator.stopObserving()
}

@MainActor @Test(arguments: [true, false])
func `a live divider opens and closes its gap whether or not its row also gains a header`(
    startsGroup: Bool
) {
    let harness = UnreadDividerMotionHarness(startsGroup: startsGroup)
    harness.show(unread: nil)

    harness.show(unread: harness.unread)
    #expect(harness.dividerIsMoving)
    #expect(harness.gapIsOpening)

    harness.coordinator.canvas?.finishUnreadDividerFades()
    #expect(!harness.dividerIsMoving)
    harness.show(unread: nil)
    #expect(harness.dividerIsMoving)
    #expect(harness.gapIsOpening)
    harness.coordinator.stopObserving()
}

@MainActor @Test
func `with Reduce Motion a live divider fades in without a gap and disappears at once`() {
    let harness = UnreadDividerMotionHarness(reducesMotion: true)
    harness.show(unread: nil)

    harness.show(unread: harness.unread)
    #expect(harness.dividerIsMoving)
    #expect(!harness.gapIsOpening)

    harness.coordinator.canvas?.finishUnreadDividerFades()
    harness.show(unread: nil)
    #expect(!harness.dividerIsMoving)
    harness.coordinator.stopObserving()
}

@MainActor @Test
func `a divider that arrives with the history of a retried first load is simply there`() {
    let harness = UnreadDividerMotionHarness()
    // The first load failed, so the empty timeline already holds its position.
    harness.model.replaceSelectedMessages(with: [])
    harness.show(unread: nil)
    #expect(harness.coordinator.hasAppliedInitialPositionForTesting)

    harness.model.replaceSelectedMessages(with: harness.messages)
    harness.show(unread: harness.unread)
    #expect(!harness.dividerIsMoving)
    harness.coordinator.stopObserving()
}

@MainActor @Test
func `jumping to the unread boundary settles a divider that is still moving`() {
    let harness = UnreadDividerMotionHarness()
    harness.show(unread: nil)
    harness.show(unread: harness.unread)
    #expect(harness.dividerIsMoving)

    harness.model.messageNavigationRequest = MessageNavigationRequest(
        requestID: 1, channelID: harness.channelID, messageID: harness.unread,
        glides: true, isUnreadBoundary: true
    )
    harness.show(unread: harness.unread)
    #expect(!harness.dividerIsMoving)
    harness.coordinator.stopObserving()
}

@MainActor @Test
func `a divider that arrives with an unread jump already turned into a scroll request is simply there`() {
    let harness = UnreadDividerMotionHarness()
    harness.show(unread: nil)

    // The view has already cleared the model's request by now.
    let jump = MessageTimelineScrollRequest(
        target: .message(harness.unread, anchor: TimelineInitialPositionPolicy.unreadViewportAnchor),
        isAnimated: true
    )
    harness.show(unread: harness.unread, scrollRequest: jump)
    #expect(!harness.dividerIsMoving)
    harness.coordinator.stopObserving()
}

@MainActor @Test
func `a divider that arrives with a jump to the unread boundary is simply there`() {
    let harness = UnreadDividerMotionHarness()
    harness.show(unread: nil)
    harness.model.messageNavigationRequest = MessageNavigationRequest(
        requestID: 1, channelID: harness.channelID, messageID: harness.unread,
        glides: true, isUnreadBoundary: true
    )

    harness.show(unread: harness.unread)
    #expect(!harness.dividerIsMoving)
    harness.coordinator.stopObserving()
}
