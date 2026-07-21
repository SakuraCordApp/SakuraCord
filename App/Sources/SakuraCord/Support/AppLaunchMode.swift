import Foundation

nonisolated enum AppLaunchMode: Equatable, Sendable {
    case normal
    case offlineTesting
}

nonisolated struct AppLaunchConfiguration: Equatable, Sendable {
    let mode: AppLaunchMode
    let includesLongServerList: Bool

    init(arguments: [String]) {
        includesLongServerList = arguments.contains("--offline-long-server-list")
        let testingFlags: Set = ["--offline", "--offline-long-server-list"]
        mode = arguments.contains(where: testingFlags.contains) ? .offlineTesting : .normal
    }
}
