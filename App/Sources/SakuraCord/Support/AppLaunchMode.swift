import Foundation

nonisolated enum AppLaunchMode: Equatable, Sendable {
    case normal
    case offlineTesting
}

nonisolated struct AppLaunchConfiguration: Equatable, Sendable {
    let mode: AppLaunchMode
    let includesLongServerList: Bool
    let includesForumPerformanceFixture: Bool

    init(arguments: [String]) {
        includesLongServerList = arguments.contains("--offline-long-server-list")
        includesForumPerformanceFixture = arguments.contains("--offline-forum-performance")
        let testingFlags: Set = [
            "--offline", "--offline-long-server-list", "--offline-forum-performance",
        ]
        mode = arguments.contains(where: testingFlags.contains) ? .offlineTesting : .normal
    }
}
