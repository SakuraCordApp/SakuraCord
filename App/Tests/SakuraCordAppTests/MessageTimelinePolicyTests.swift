@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
@Test func `shared conversation skeleton is only visible without presentable messages`() {
    #expect(MessageTimelineLoadingPolicy.showsInitialPlaceholder(isLoading: true, messageCount: 0))
    #expect(!MessageTimelineLoadingPolicy.showsInitialPlaceholder(isLoading: true, messageCount: 1))
    #expect(!MessageTimelineLoadingPolicy.showsInitialPlaceholder(isLoading: false, messageCount: 0))
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
@Test func `initial unread positioning resolves from actual viewport geometry`() {
    let channelID = ChannelID(rawValue: 42)
    var tracker = TimelineInitialPositionTracker()

    tracker.begin(channelID: channelID)

    #expect(
        tracker.resolve(channelID: channelID, actualIsAtNewest: true) == true
    )
    #expect(
        tracker.resolve(channelID: channelID, actualIsAtNewest: false) == nil
    )
}

@MainActor
@Test func `initial position tracker rejects stale channel geometry`() {
    let channelID = ChannelID(rawValue: 42)
    let staleChannelID = ChannelID(rawValue: 41)
    var tracker = TimelineInitialPositionTracker()

    tracker.begin(channelID: channelID)

    #expect(
        tracker.resolve(channelID: staleChannelID, actualIsAtNewest: true) == nil
    )
    #expect(
        tracker.resolve(channelID: channelID, actualIsAtNewest: false) == false
    )
}
