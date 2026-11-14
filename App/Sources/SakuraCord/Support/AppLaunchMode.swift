import DiscordProtocol
import Foundation

nonisolated enum AppLaunchMode: Equatable, Sendable {
    case normal
    case offlineTesting
}

/// Launch arguments that start the app on the offline mock provider.
nonisolated enum OfflineLaunchFlag: String {
    case offline = "--offline"
    case signIn = "--offline-sign-in"
    case longServerList = "--offline-long-server-list"
    case forumPerformance = "--offline-forum-performance"
    case forumPerformanceAutoScroll = "--offline-forum-performance-autoscroll"
    case forumGalleryResize = "--offline-forum-gallery-resize"
    case chatPerformance = "--offline-chat-performance"
    case chatPerformanceAutoScroll = "--offline-chat-performance-autoscroll"
    case chatPerformanceLiveAutoScroll = "--offline-chat-performance-live-autoscroll"
    case chatMediaPerformanceAutoScroll = "--offline-chat-media-performance-autoscroll"
    case chatVoicePerformance = "--offline-chat-voice-performance"
    case chatVoicePerformanceAutoScroll = "--offline-chat-voice-performance-autoscroll"
    case chatFilesPerformance = "--offline-chat-files-performance"
    case chatFilesPerformanceAutoScroll = "--offline-chat-files-performance-autoscroll"
    case chatFilesPerformanceOpen = "--offline-chat-files-performance-open"
    case pinsPerformanceAutoScroll = "--offline-pins-performance-autoscroll"
    case incomingPrivateCall = "--offline-incoming-private-call"
    case friendsPerformance = "--offline-friends-performance"
    case unreadChurn = "--offline-unread-churn"
    case serverRailPerformance = "--offline-server-rail-performance"
}

nonisolated struct AppLaunchConfiguration: Equatable, Sendable {
    /// This process's launch arguments, parsed once.
    static let current = Self(arguments: ProcessInfo.processInfo.arguments)

    let mode: AppLaunchMode
    let includesSignInFixture: Bool
    let includesLongServerList: Bool
    let includesForumPerformanceFixture: Bool
    let includesChatPerformanceFixture: Bool
    let includesChatMediaPerformanceFixture: Bool
    let includesChatVoicePerformanceFixture: Bool
    /// A channel full of uploaded files of every kind.
    let includesChatFilesPerformanceFixture: Bool
    /// Opens that channel repeatedly, timing each open to its first frame.
    let runsChannelOpenBenchmark: Bool
    let includesPinsPerformanceFixture: Bool
    let includesIncomingPrivateCallFixture: Bool
    let runsChatPerformanceAutoScroll: Bool
    let runsForumPerformanceAutoScroll: Bool
    let runsMemberListPerformanceAutoScroll: Bool
    let runsAuthenticatedNavigationBenchmark: Bool
    let runsAuthenticatedAccountSwitchBenchmark: Bool
    let runsHistoryPaginationBenchmark: Bool
    let runsAuthenticatedGestureScrollBenchmark: Bool
    let runsLoadingScrollOverlapBenchmark: Bool
    let runsChatLiveArrivalStress: Bool
    let runsPinsPerformanceAutoScroll: Bool
    /// A 1,000-friend list, presence churn and a scroll and section-switch benchmark.
    let runsFriendsPerformanceBenchmark: Bool
    /// A 150-server rail scrolled, selected and updated with mention badges.
    let runsServerRailPerformanceBenchmark: Bool
    /// Mentions arriving in other servers while main-thread time is measured.
    let runsUnreadChurnBenchmark: Bool
#if SAKURACORD_MOTION_BENCHMARK
    /// Fixture threads opened, closed and widened while every frame is recorded.
    let runsSideChatMotionBenchmark: Bool
#endif

    init(arguments: [String]) {
#if DEBUG
        let runsAuthenticatedAutoScroll =
            arguments.contains(
                "--debug-authenticated-chat-performance-autoscroll"
            )
#else
        let runsAuthenticatedAutoScroll = false
#endif
        #if DEBUG
            runsAuthenticatedNavigationBenchmark = arguments.contains(
                "--debug-authenticated-navigation-performance"
            )
            runsAuthenticatedAccountSwitchBenchmark = arguments.contains(
                "--debug-authenticated-account-switch-performance"
            )
            runsHistoryPaginationBenchmark = arguments.contains(
                "--debug-authenticated-history-pagination-performance"
            )
            runsAuthenticatedGestureScrollBenchmark = arguments.contains(
                "--debug-authenticated-gesture-scroll-performance"
            )
            runsLoadingScrollOverlapBenchmark = arguments.contains(
                "--debug-authenticated-loading-scroll-overlap-performance"
            )
            runsMemberListPerformanceAutoScroll = arguments.contains(
                "--debug-authenticated-member-list-performance-autoscroll"
            )
        #else
            runsAuthenticatedNavigationBenchmark = false
            runsAuthenticatedAccountSwitchBenchmark = false
            runsHistoryPaginationBenchmark = false
            runsAuthenticatedGestureScrollBenchmark = false
            runsLoadingScrollOverlapBenchmark = false
            runsMemberListPerformanceAutoScroll = false
        #endif
        let flags = Set(arguments.compactMap(OfflineLaunchFlag.init(rawValue:)))
        includesSignInFixture = flags.contains(.signIn)
        runsUnreadChurnBenchmark = flags.contains(.unreadChurn)
        includesLongServerList = flags.contains(.longServerList) || runsUnreadChurnBenchmark
        runsForumPerformanceAutoScroll =
            flags.contains(.forumPerformanceAutoScroll)
            || flags.contains(.forumGalleryResize)
        includesForumPerformanceFixture =
            flags.contains(.forumPerformance) || runsForumPerformanceAutoScroll
        includesChatMediaPerformanceFixture = flags.contains(.chatMediaPerformanceAutoScroll)
        includesChatVoicePerformanceFixture =
            flags.contains(.chatVoicePerformance)
            || flags.contains(.chatVoicePerformanceAutoScroll)
        runsChannelOpenBenchmark = flags.contains(.chatFilesPerformanceOpen)
        includesChatFilesPerformanceFixture =
            flags.contains(.chatFilesPerformance)
            || flags.contains(.chatFilesPerformanceAutoScroll)
            || runsChannelOpenBenchmark
        includesPinsPerformanceFixture = flags.contains(.pinsPerformanceAutoScroll)
        includesIncomingPrivateCallFixture = flags.contains(.incomingPrivateCall)
        runsChatPerformanceAutoScroll =
            flags.contains(.chatPerformanceAutoScroll)
            || flags.contains(.chatPerformanceLiveAutoScroll)
            || includesChatMediaPerformanceFixture
            || flags.contains(.chatVoicePerformanceAutoScroll)
            || flags.contains(.chatFilesPerformanceAutoScroll)
            || runsAuthenticatedAutoScroll
        runsChatLiveArrivalStress = flags.contains(.chatPerformanceLiveAutoScroll)
        runsPinsPerformanceAutoScroll = includesPinsPerformanceFixture
        runsFriendsPerformanceBenchmark = flags.contains(.friendsPerformance)
        runsServerRailPerformanceBenchmark = flags.contains(.serverRailPerformance)
#if SAKURACORD_MOTION_BENCHMARK
        let isMotionBenchmarkLaunch = arguments.contains("--offline-side-chat-motion")
        runsSideChatMotionBenchmark = isMotionBenchmarkLaunch
#else
        let isMotionBenchmarkLaunch = false
#endif
        includesChatPerformanceFixture =
            flags.contains(.chatPerformanceAutoScroll)
            || flags.contains(.chatPerformanceLiveAutoScroll)
            || includesChatMediaPerformanceFixture
            || includesChatVoicePerformanceFixture
            || includesChatFilesPerformanceFixture
            || flags.contains(.chatPerformance)
            || includesPinsPerformanceFixture
        mode = isMotionBenchmarkLaunch || !flags.isEmpty ? .offlineTesting : .normal
    }

    /// An authenticated benchmark that scrolls the timeline.
    var preparesTimelineScrollBenchmark: Bool {
        mode == .normal && runsChatPerformanceAutoScroll
    }

    /// An authenticated benchmark that scrolls the member list.
    var preparesMemberListScrollBenchmark: Bool {
        mode == .normal && runsMemberListPerformanceAutoScroll
    }

    /// An authenticated benchmark that needs the window frontmost.
    var activatesAuthenticatedScrollBenchmark: Bool {
        mode == .normal && (
            runsChatPerformanceAutoScroll
                || runsMemberListPerformanceAutoScroll
                || runsAuthenticatedGestureScrollBenchmark
                || runsLoadingScrollOverlapBenchmark
        )
    }

    var mockServerList: MockServerList {
        if runsServerRailPerformanceBenchmark { return .performance }
        return includesLongServerList ? .long : .standard
    }

    var runsAnyReadOnlyPerformanceBenchmark: Bool {
        runsChatPerformanceAutoScroll
            || runsChannelOpenBenchmark
            || runsForumPerformanceAutoScroll
            || runsPinsPerformanceAutoScroll
            || runsFriendsPerformanceBenchmark
            || runsServerRailPerformanceBenchmark
            || runsUnreadChurnBenchmark
            || runsMemberListPerformanceAutoScroll
            || runsAuthenticatedNavigationBenchmark
            || runsAuthenticatedAccountSwitchBenchmark
            || runsHistoryPaginationBenchmark
            || runsAuthenticatedGestureScrollBenchmark
            || runsLoadingScrollOverlapBenchmark
    }
}
