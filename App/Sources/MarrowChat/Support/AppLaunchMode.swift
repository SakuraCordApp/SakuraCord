import Foundation

nonisolated enum AppLaunchMode: Equatable, Sendable {
    case normal
    case offlineTesting
}

nonisolated struct AppLaunchConfiguration: Equatable, Sendable {
    let mode: AppLaunchMode
    let includesLongServerList: Bool
    let includesForumPerformanceFixture: Bool
    let includesChatPerformanceFixture: Bool
    let includesChatMediaPerformanceFixture: Bool
    let includesIncomingPrivateCallFixture: Bool
    let runsChatPerformanceAutoScroll: Bool
    let runsMemberListPerformanceAutoScroll: Bool
    let runsAuthenticatedNavigationBenchmark: Bool
    let runsAuthenticatedAccountSwitchBenchmark: Bool
    let runsHistoryPaginationBenchmark: Bool
    let runsAuthenticatedGestureScrollBenchmark: Bool
    let runsLoadingScrollOverlapBenchmark: Bool
    let runsChatLiveArrivalStress: Bool

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
        includesLongServerList = arguments.contains("--offline-long-server-list")
        includesForumPerformanceFixture = arguments.contains("--offline-forum-performance")
        includesChatMediaPerformanceFixture =
            arguments.contains("--offline-chat-media-performance-autoscroll")
        includesIncomingPrivateCallFixture =
            arguments.contains("--offline-incoming-private-call")
        runsChatPerformanceAutoScroll =
            arguments.contains("--offline-chat-performance-autoscroll")
            || arguments.contains("--offline-chat-performance-live-autoscroll")
            || includesChatMediaPerformanceFixture
            || runsAuthenticatedAutoScroll
        runsChatLiveArrivalStress =
            arguments.contains("--offline-chat-performance-live-autoscroll")
        includesChatPerformanceFixture =
            arguments.contains("--offline-chat-performance-autoscroll")
            || arguments.contains("--offline-chat-performance-live-autoscroll")
            || includesChatMediaPerformanceFixture
            || arguments.contains("--offline-chat-performance")
        let testingFlags: Set = [
            "--offline", "--offline-long-server-list", "--offline-forum-performance",
            "--offline-chat-performance", "--offline-chat-performance-autoscroll",
            "--offline-chat-performance-live-autoscroll",
            "--offline-chat-media-performance-autoscroll",
            "--offline-incoming-private-call",
        ]
        mode = arguments.contains(where: testingFlags.contains) ? .offlineTesting : .normal
    }

    var runsAnyReadOnlyPerformanceBenchmark: Bool {
        runsChatPerformanceAutoScroll
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
