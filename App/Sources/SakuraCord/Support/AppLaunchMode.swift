import Foundation

nonisolated enum AppLaunchMode: Equatable, Sendable {
    case normal
    case offlineTesting
}

nonisolated struct AppLaunchConfiguration: Equatable, Sendable {
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
        includesSignInFixture = arguments.contains("--offline-sign-in")
        includesLongServerList = arguments.contains("--offline-long-server-list")
        runsForumPerformanceAutoScroll =
            arguments.contains("--offline-forum-performance-autoscroll")
        includesForumPerformanceFixture =
            arguments.contains("--offline-forum-performance") || runsForumPerformanceAutoScroll
        includesChatMediaPerformanceFixture =
            arguments.contains("--offline-chat-media-performance-autoscroll")
        includesChatVoicePerformanceFixture =
            arguments.contains("--offline-chat-voice-performance")
            || arguments.contains("--offline-chat-voice-performance-autoscroll")
        runsChannelOpenBenchmark = arguments.contains("--offline-chat-files-performance-open")
        includesChatFilesPerformanceFixture =
            arguments.contains("--offline-chat-files-performance")
            || arguments.contains("--offline-chat-files-performance-autoscroll")
            || runsChannelOpenBenchmark
        includesPinsPerformanceFixture =
            arguments.contains("--offline-pins-performance-autoscroll")
        includesIncomingPrivateCallFixture =
            arguments.contains("--offline-incoming-private-call")
        runsChatPerformanceAutoScroll =
            arguments.contains("--offline-chat-performance-autoscroll")
            || arguments.contains("--offline-chat-performance-live-autoscroll")
            || includesChatMediaPerformanceFixture
            || arguments.contains("--offline-chat-voice-performance-autoscroll")
            || arguments.contains("--offline-chat-files-performance-autoscroll")
            || runsAuthenticatedAutoScroll
        runsChatLiveArrivalStress =
            arguments.contains("--offline-chat-performance-live-autoscroll")
        runsPinsPerformanceAutoScroll = includesPinsPerformanceFixture
        runsFriendsPerformanceBenchmark = arguments.contains("--offline-friends-performance")
#if SAKURACORD_MOTION_BENCHMARK
        let isMotionBenchmarkLaunch = arguments.contains("--offline-side-chat-motion")
        runsSideChatMotionBenchmark = isMotionBenchmarkLaunch
#else
        let isMotionBenchmarkLaunch = false
#endif
        includesChatPerformanceFixture =
            arguments.contains("--offline-chat-performance-autoscroll")
            || arguments.contains("--offline-chat-performance-live-autoscroll")
            || includesChatMediaPerformanceFixture
            || includesChatVoicePerformanceFixture
            || includesChatFilesPerformanceFixture
            || arguments.contains("--offline-chat-performance")
            || includesPinsPerformanceFixture
        let testingFlags: Set = [
            "--offline", "--offline-sign-in", "--offline-long-server-list", "--offline-forum-performance",
            "--offline-forum-performance-autoscroll",
            "--offline-chat-performance", "--offline-chat-performance-autoscroll",
            "--offline-chat-performance-live-autoscroll",
            "--offline-chat-media-performance-autoscroll",
            "--offline-chat-voice-performance", "--offline-chat-voice-performance-autoscroll",
            "--offline-chat-files-performance", "--offline-chat-files-performance-autoscroll",
            "--offline-chat-files-performance-open",
            "--offline-pins-performance-autoscroll",
            "--offline-incoming-private-call", "--offline-friends-performance",
        ]
        mode = isMotionBenchmarkLaunch || arguments.contains(where: testingFlags.contains) ? .offlineTesting : .normal
    }

    var runsAnyReadOnlyPerformanceBenchmark: Bool {
        runsChatPerformanceAutoScroll
            || runsChannelOpenBenchmark
            || runsForumPerformanceAutoScroll
            || runsPinsPerformanceAutoScroll
            || runsFriendsPerformanceBenchmark
            || runsMemberListPerformanceAutoScroll
            || runsAuthenticatedNavigationBenchmark
            || runsAuthenticatedAccountSwitchBenchmark
            || runsHistoryPaginationBenchmark
            || runsAuthenticatedGestureScrollBenchmark
            || runsLoadingScrollOverlapBenchmark
    }
}

@MainActor
final class NativeTimelinePerformanceBenchmarkGate {
    static let shared = NativeTimelinePerformanceBenchmarkGate()

    private var didStart = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func begin() {
        guard !didStart else { return }
        didStart = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for continuation in pending {
            continuation.resume()
        }
    }
}
