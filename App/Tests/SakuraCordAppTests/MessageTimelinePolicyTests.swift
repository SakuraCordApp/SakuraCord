import AppKit
@testable import SakuraCord
import SakuraCordModels
import SwiftUI
import Testing

@Test func `skeleton shimmer phase wraps without changing layout`() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let midpoint = Date(
        timeIntervalSinceReferenceDate: SkeletonShimmerStyle.duration / 2
    )
    let wrapped = Date(
        timeIntervalSinceReferenceDate: SkeletonShimmerStyle.duration
    )

    #expect(SkeletonShimmerStyle.phase(at: start) == 0)
    #expect(abs(SkeletonShimmerStyle.phase(at: midpoint) - 0.5) < 0.000_001)
    #expect(abs(SkeletonShimmerStyle.phase(at: wrapped)) < 0.000_001)
}

@MainActor
@Test func `shared conversation skeleton is only visible without presentable messages`() {
    #expect(MessageTimelineLoadingPolicy.showsInitialPlaceholder(isLoading: true, messageCount: 0))
    #expect(!MessageTimelineLoadingPolicy.showsInitialPlaceholder(isLoading: true, messageCount: 1))
    #expect(!MessageTimelineLoadingPolicy.showsInitialPlaceholder(isLoading: false, messageCount: 0))
}

@MainActor
@Test func `shared conversation skeleton covers the top scroll edge safe area`() throws {
    let host = MessageTimelineSkeletonSafeAreaHost(
        rootView: MessageTimelineLoadingSkeleton()
    )
    host.frame = CGRect(x: 0, y: 0, width: 480, height: 360)
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(
        host.bitmapImageRepForCachingDisplay(in: host.bounds)
    )
    host.cacheDisplay(in: host.bounds, to: bitmap)

    #expect(bitmap.colorAt(x: 240, y: 1)?.alphaComponent == 1)
    #expect(bitmap.colorAt(x: 240, y: 358)?.alphaComponent == 1)
}

@MainActor
@Test func `cached refreshes and earlier pages expose the leading loading indicator`() {
    #expect(
        MessageTimelineLoadingPolicy.showsEarlierIndicator(
            isLoadingInitialPage: true,
            messageCount: 100,
            isLoadingEarlierPage: false
        )
    )
    #expect(
        MessageTimelineLoadingPolicy.showsEarlierIndicator(
            isLoadingInitialPage: false,
            messageCount: 100,
            isLoadingEarlierPage: true
        )
    )
    #expect(
        !MessageTimelineLoadingPolicy.showsEarlierIndicator(
            isLoadingInitialPage: true,
            messageCount: 0,
            isLoadingEarlierPage: false
        )
    )
}

@MainActor
@Test func `passive content growth keeps following new messages`() {
    var policy = MessageTimelineScrollPolicy()

    policy.updateGeometry(isNearBottom: false)

    #expect(!policy.isNearBottom)
    #expect(policy.followsNewMessages)
}

@MainActor
@Test func `user scroll intent controls automatic new message following`() {
    var policy = MessageTimelineScrollPolicy()

    policy.userScrollBegan()
    #expect(!policy.followsNewMessages)

    policy.updateGeometry(isNearBottom: false)
    policy.userScrollEnded(isNearBottom: false)
    policy.updateGeometry(isNearBottom: true)
    #expect(!policy.followsNewMessages)

    policy.userScrollEnded(isNearBottom: true)
    #expect(policy.isNearBottom)
    #expect(policy.followsNewMessages)
}

@MainActor
@Test func `channel changes wait for an established position and explicit bottom jumps follow`() {
    var policy = MessageTimelineScrollPolicy()
    policy.didBeginChannel()
    #expect(!policy.isNearBottom)
    #expect(!policy.followsNewMessages)

    policy.didRequestBottom()
    #expect(policy.isNearBottom)
    #expect(policy.followsNewMessages)
}

@MainActor
@Test func `initial conversation position uses exact unread boundary with context`() {
    let unreadID = MessageID(rawValue: 42)

    #expect(
        TimelineInitialPositionPolicy.target(
            firstUnreadMessageID: unreadID,
            hasExactUnreadBoundary: true,
            prefersNewest: false
        )
        == .message(
            unreadID,
            anchor: TimelineInitialPositionPolicy.unreadViewportAnchor
        )
    )
    #expect(TimelineInitialPositionPolicy.unreadViewportAnchor.y == 0.28)
}

@MainActor
private final class MessageTimelineSkeletonSafeAreaHost<Content: View>:
    NSHostingView<Content>
{
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 40, left: 0, bottom: 0, right: 0)
    }
}

@MainActor
@Test func `initial conversation position uses the oldest loaded unread when boundary is unresolved`() {
    #expect(
        TimelineInitialPositionPolicy.target(
            firstUnreadMessageID: nil,
            hasExactUnreadBoundary: false,
            prefersNewest: false
        ) == .bottom
    )
    #expect(
        TimelineInitialPositionPolicy.target(
            firstUnreadMessageID: MessageID(rawValue: 42),
            hasExactUnreadBoundary: false,
            prefersNewest: false
        )
        == .message(
            MessageID(rawValue: 42),
            anchor:
                TimelineInitialPositionPolicy
                .unresolvedUnreadViewportAnchor
        )
    )
    #expect(
        TimelineInitialPositionPolicy.unresolvedUnreadViewportAnchor
            == .top
    )
    #expect(
        TimelineInitialPositionPolicy.target(
            firstUnreadMessageID: MessageID(rawValue: 42),
            hasExactUnreadBoundary: true,
            prefersNewest: true
        ) == .bottom
    )
}

@MainActor
@Test func `initial conversation position waits for a completed initial load`() {
    #expect(
        TimelineInitialPositionPolicy.targetWhenReady(
            hasCompletedInitialLoad: false,
            firstUnreadMessageID: MessageID(rawValue: 42),
            hasExactUnreadBoundary: true,
            prefersNewest: false
        ) == nil
    )
    #expect(
        TimelineInitialPositionPolicy.targetWhenReady(
            hasCompletedInitialLoad: true,
            firstUnreadMessageID: nil,
            hasExactUnreadBoundary: false,
            prefersNewest: false
        ) == .bottom
    )
    #expect(
        TimelineInitialPositionPolicy.targetWhenReady(
            hasCompletedInitialLoad: true,
            firstUnreadMessageID: MessageID(rawValue: 101),
            hasExactUnreadBoundary: false,
            prefersNewest: false
        )
        == .message(
            MessageID(rawValue: 101),
            anchor:
                TimelineInitialPositionPolicy
                .unresolvedUnreadViewportAnchor
        )
    )
}

@Test func `underfilled unread history loads without user scroll intent`() {
    #expect(
        TimelineHistoryLoadingPolicy.shouldLoad(
            isNearBoundary: true,
            contentFitsViewport: true,
            allowsAutomaticLoading: true,
            hasMoreMessages: true,
            isLoading: false,
            requiresUserScrollIntent: true,
            hasUserScrollIntent: false
        )
    )
}

@Test func `filled unresolved unread history requires user scroll intent before loading`() {
    #expect(
        !TimelineHistoryLoadingPolicy.shouldLoad(
            isNearBoundary: true,
            contentFitsViewport: false,
            allowsAutomaticLoading: true,
            hasMoreMessages: true,
            isLoading: false,
            requiresUserScrollIntent: true,
            hasUserScrollIntent: false
        )
    )
    #expect(
        TimelineHistoryLoadingPolicy.shouldLoad(
            isNearBoundary: true,
            contentFitsViewport: false,
            allowsAutomaticLoading: true,
            hasMoreMessages: true,
            isLoading: false,
            requiresUserScrollIntent: true,
            hasUserScrollIntent: true
        )
    )
    #expect(
        TimelineHistoryLoadingPolicy.shouldLoad(
            isNearBoundary: true,
            contentFitsViewport: false,
            allowsAutomaticLoading: true,
            hasMoreMessages: true,
            isLoading: false,
            requiresUserScrollIntent: false,
            hasUserScrollIntent: false
        )
    )
    #expect(
        !TimelineHistoryLoadingPolicy.shouldLoad(
            isNearBoundary: true,
            contentFitsViewport: true,
            allowsAutomaticLoading: true,
            hasMoreMessages: true,
            isLoading: true,
            requiresUserScrollIntent: true,
            hasUserScrollIntent: true
        )
    )
}

@Test func `earlier history intent survives an active gesture or requested skeleton viewport`() {
    #expect(
        TimelineHistoryScrollIntentPolicy.shouldRetain(
            hasIntent: true,
            isGestureActive: true,
            isInProvisionalHistory: false
        )
    )
    #expect(
        TimelineHistoryScrollIntentPolicy.shouldRetain(
            hasIntent: true,
            isGestureActive: false,
            isInProvisionalHistory: true
        )
    )
    #expect(
        !TimelineHistoryScrollIntentPolicy.shouldRetain(
            hasIntent: true,
            isGestureActive: false,
            isInProvisionalHistory: false
        )
    )
}

@Test func `later history loads only at the loaded window boundary`() {
    #expect(
        TimelineHistoryLoadingPolicy.shouldLoad(
            isNearBoundary: true,
            contentFitsViewport: false,
            allowsAutomaticLoading: true,
            hasMoreMessages: true,
            isLoading: false,
            requiresUserScrollIntent: false,
            hasUserScrollIntent: false
        )
    )
    #expect(
        !TimelineHistoryLoadingPolicy.shouldLoad(
            isNearBoundary: false,
            contentFitsViewport: false,
            allowsAutomaticLoading: true,
            hasMoreMessages: true,
            isLoading: false,
            requiresUserScrollIntent: false,
            hasUserScrollIntent: false
        )
    )
    #expect(
        !TimelineHistoryLoadingPolicy.shouldLoad(
            isNearBoundary: true,
            contentFitsViewport: false,
            allowsAutomaticLoading: true,
            hasMoreMessages: true,
            isLoading: true,
            requiresUserScrollIntent: false,
            hasUserScrollIntent: false
        )
    )
}

@Test func `unresolved unread boundaries do not draw a misleading divider`() {
    let unreadID = MessageID(rawValue: 42)
    #expect(
        TimelineUnreadBoundaryPolicy.displayedMessageID(
            firstUnreadMessageID: unreadID,
            isLowerBound: false
        ) == unreadID
    )
    #expect(
        TimelineUnreadBoundaryPolicy.displayedMessageID(
            firstUnreadMessageID: unreadID,
            isLowerBound: true
        ) == nil
    )
}
