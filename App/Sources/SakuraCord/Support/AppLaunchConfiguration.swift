import Foundation

/// Launch arguments that run a benchmark against the signed-in account,
/// which for every benchmark but the account-scale ones is the local Discord
/// simulator running the matching scenario. `script/build_and_run.sh`
/// starts both; docs/DEVELOPMENT.md lists them.
nonisolated enum BenchmarkLaunchFlag: String {
    /// Scrolls the simulator scenario's `#general`, or on a real account
    /// the first conversation with more history.
    case chatAutoScroll = "--benchmark-chat-autoscroll"
    /// The same scroll while the simulator streams reactions, arrivals,
    /// edits and deletions into the channel.
    case chatLiveAutoScroll = "--benchmark-chat-live-autoscroll"
    case chatLiveReactionsOnly = "--benchmark-chat-live-reactions-only"
    case chatLiveMutationsOnly = "--benchmark-chat-live-mutations-only"
    case chatLiveArrivalsOnly = "--benchmark-chat-live-arrivals-only"
    /// Measures live updates on a still timeline instead of a scrolling one.
    case chatIdle = "--benchmark-chat-idle"
    case channelOpen = "--benchmark-channel-open"
    case pinsAutoScroll = "--benchmark-pins-autoscroll"
    case forumAutoScroll = "--benchmark-forum-autoscroll"
    case forumGalleryResize = "--benchmark-forum-gallery-resize"
    case friends = "--benchmark-friends"
    case serverRail = "--benchmark-server-rail"
    case unreadChurn = "--benchmark-unread-churn"
    case memberListAutoScroll = "--benchmark-member-list-autoscroll"
    case navigation = "--benchmark-navigation"
    case accountSwitch = "--benchmark-account-switch"
    case historyPagination = "--benchmark-history-pagination"
    case gestureScroll = "--benchmark-gesture-scroll"
    case loadingScrollOverlap = "--benchmark-loading-scroll-overlap"
#if SAKURACORD_MOTION_BENCHMARK && DEBUG
    case sideChatMotion = "--benchmark-side-chat-motion"
#endif

    /// Flags that only adjust the live chat benchmark another flag starts.
    static let modifiers: Set<Self> = [
        .chatLiveReactionsOnly, .chatLiveMutationsOnly, .chatLiveArrivalsOnly, .chatIdle,
    ]
}

nonisolated struct AppLaunchConfiguration: Equatable, Sendable {
    /// This process's launch arguments, parsed once.
    static let current = Self(arguments: ProcessInfo.processInfo.arguments)

    /// The benchmarks this launch runs. Release builds run none.
    let benchmarks: Set<BenchmarkLaunchFlag>
    /// The gesture-scroll and loading-overlap flags as given, in any build;
    /// the benchmarks themselves run only in debug builds.
    let requestsGestureScrollBenchmark: Bool
    let requestsLoadingScrollOverlapBenchmark: Bool
    /// Animated media logs its decoding cost, in any build.
    let reportsAnimatedMediaPerformance: Bool
#if SAKURACORD_MOTION_BENCHMARK && DEBUG
    /// Threads opened, closed and widened while every frame is recorded;
    /// set when the launch runs that benchmark.
    let sideChatMotionOptions: SideChatMotionBenchmark.Options?
#endif

    init(arguments: [String]) {
        let requested = Set(arguments.compactMap(BenchmarkLaunchFlag.init(rawValue:)))
        requestsGestureScrollBenchmark = requested.contains(.gestureScroll)
        requestsLoadingScrollOverlapBenchmark = requested.contains(.loadingScrollOverlap)
        reportsAnimatedMediaPerformance = requestsGestureScrollBenchmark
            || requested.contains { $0.rawValue.hasPrefix("--benchmark-chat-") }
#if DEBUG
        benchmarks = requested
#else
        benchmarks = []
#endif
#if SAKURACORD_MOTION_BENCHMARK && DEBUG
        sideChatMotionOptions = benchmarks.contains(.sideChatMotion)
            ? SideChatMotionBenchmark.Options(arguments: arguments)
            : nil
#endif
    }

    var runsChatPerformanceAutoScroll: Bool {
        !benchmarks.isDisjoint(with: [.chatAutoScroll, .chatLiveAutoScroll])
    }

    var runsChatLiveStress: Bool { benchmarks.contains(.chatLiveAutoScroll) }

    /// Which of the live stress's reactions, arrivals and mutations run:
    /// reactions only on request, the others unless one kind runs alone.
    var liveStressRunsReactions: Bool { benchmarks.contains(.chatLiveReactionsOnly) }
    var liveStressRunsArrivals: Bool {
        benchmarks.isDisjoint(with: [.chatLiveReactionsOnly, .chatLiveMutationsOnly])
    }
    var liveStressRunsMutations: Bool {
        benchmarks.isDisjoint(with: [.chatLiveReactionsOnly, .chatLiveArrivalsOnly])
    }

    var isChatPerformanceIdle: Bool { benchmarks.contains(.chatIdle) }
    var runsChannelOpenBenchmark: Bool { benchmarks.contains(.channelOpen) }
    var runsPinsPerformanceAutoScroll: Bool { benchmarks.contains(.pinsAutoScroll) }
    var runsForumPerformanceAutoScroll: Bool {
        !benchmarks.isDisjoint(with: [.forumAutoScroll, .forumGalleryResize])
    }
    var runsForumGalleryResize: Bool { benchmarks.contains(.forumGalleryResize) }
    var runsFriendsPerformanceBenchmark: Bool { benchmarks.contains(.friends) }
    var runsServerRailPerformanceBenchmark: Bool { benchmarks.contains(.serverRail) }
    var runsUnreadChurnBenchmark: Bool { benchmarks.contains(.unreadChurn) }
    var runsMemberListPerformanceAutoScroll: Bool { benchmarks.contains(.memberListAutoScroll) }
    var runsNavigationBenchmark: Bool { benchmarks.contains(.navigation) }
    var runsAccountSwitchBenchmark: Bool { benchmarks.contains(.accountSwitch) }
    var runsHistoryPaginationBenchmark: Bool { benchmarks.contains(.historyPagination) }
    var runsGestureScrollBenchmark: Bool { benchmarks.contains(.gestureScroll) }
    var runsLoadingScrollOverlapBenchmark: Bool { benchmarks.contains(.loadingScrollOverlap) }

    /// Benchmarks are read-only: the account sends no acknowledgements,
    /// notifications or other writes while one runs.
    var runsAnyReadOnlyPerformanceBenchmark: Bool {
        !benchmarks.subtracting(BenchmarkLaunchFlag.modifiers).isEmpty
    }
}
