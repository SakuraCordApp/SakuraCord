@testable import SakuraCord
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
@Test func `channel changes and explicit bottom jumps resume following`() {
    var policy = MessageTimelineScrollPolicy()
    policy.didNavigateAwayFromBottom()
    #expect(!policy.isNearBottom)
    #expect(!policy.followsNewMessages)

    policy.didChangeChannel()
    #expect(policy.isNearBottom)
    #expect(policy.followsNewMessages)

    policy.userScrollEnded(isNearBottom: false)
    policy.didRequestBottom()
    #expect(policy.isNearBottom)
    #expect(policy.followsNewMessages)
}
