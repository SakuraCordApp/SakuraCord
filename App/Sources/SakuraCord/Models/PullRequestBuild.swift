import Foundation

nonisolated struct PullRequestBuild: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let pullRequest: Int
    let title: String
    let commitSubject: String
    let headSHA: String
    let builtSHA: String
    let runID: Int
    let runAttempt: Int
    let configuration: String
    let architecture: String
    let createdAt: Date
    let version: String
    let buildVersion: String
    let appcastURL: URL
    let archiveURL: URL
    let symbolsURL: URL
    let sha256: String

    var shortCommit: String { String(headSHA.prefix(7)) }
    var pullRequestURL: URL {
        URL(string: "https://github.com/SakuraCordApp/SakuraCord/pull/\(pullRequest)")!
    }
    var runURL: URL {
        URL(string: "https://github.com/SakuraCordApp/SakuraCord/actions/runs/\(runID)/attempts/\(runAttempt)")!
    }

    func validate() throws {
        guard pullRequest > 0, runID > 0, runID <= 9_999_999_999_999,
              (1 ... 999).contains(runAttempt),
              id == Self.id(pullRequest: pullRequest, runID: runID, runAttempt: runAttempt),
              !title.isEmpty, title.count <= 500,
              !commitSubject.isEmpty, commitSubject.count <= 500,
              Self.isHex(headSHA, count: 40), Self.isHex(builtSHA, count: 40),
              Self.isHex(sha256, count: 64),
              buildVersion == Self.buildVersion(runID: runID, runAttempt: runAttempt),
              ["debug", "release"].contains(configuration),
              ["arm64", "universal"].contains(architecture),
              appcastURL == Self.assetURL(id: id, name: "appcast.xml"),
              archiveURL == Self.assetURL(id: id, name: "SakuraCord.app.zip"),
              symbolsURL == Self.assetURL(id: id, name: "SakuraCord.dSYM.zip")
        else { throw PullRequestBuildError.invalidCatalog }
    }

    static func id(pullRequest: Int, runID: Int, runAttempt: Int) -> String {
        "pr-\(pullRequest)-run-\(runID)-attempt-\(runAttempt)"
    }

    struct IDComponents {
        let pullRequest: String
        let run: String
        let attempt: String
    }

    /// The parts of a build ID as written, or nil when it is not a PR build ID.
    static func idComponents(_ id: String) -> IDComponents? {
        guard let match = id.wholeMatch(of: /pr-(\d+)-run-(\d+)-attempt-(\d+)/) else { return nil }
        return IDComponents(pullRequest: String(match.1), run: String(match.2), attempt: String(match.3))
    }

    static func buildVersion(runID: Int, runAttempt: Int) -> String {
        String(4_000_000_000_000_000_000 + runID * 1000 + runAttempt)
    }

    static func assetURL(id: String, name: String) -> URL? {
        URL(string: "https://github.com/SakuraCordApp/Builds/releases/download/\(id)/\(name)")
    }

    /// The pull request number in a build ID such as `pr-12-run-…`.
    static func pullRequestNumber(fromID id: String) -> Int? {
        id.split(separator: "-").dropFirst().first.flatMap { Int($0) }
    }

    private static func isHex(_ value: String, count: Int) -> Bool {
        value.count == count && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0)
        }
    }
}

nonisolated enum PullRequestBuildError: LocalizedError {
    case invalidCatalog
    case unavailable
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidCatalog: "The build catalog could not be verified. Try refreshing it."
        case .unavailable: "No PR builds have been published yet."
        case let .http(status): "The build server returned HTTP \(status). Try again shortly."
        }
    }
}
