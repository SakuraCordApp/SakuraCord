import Foundation
import Observation

@Observable
@MainActor
final class PullRequestBuildStore {
    private(set) var builds: [PullRequestBuild] = []
    private(set) var isLoading = false
    private(set) var error: String?
    var search = ""
    var selectedPullRequest: Int?
    var selectedBuildID: String?
    private let fetchBuilds: @MainActor () async throws -> [PullRequestBuild]

    init(fetchBuilds: @escaping @MainActor () async throws -> [PullRequestBuild] = { try await PullRequestBuildClient().fetchBuilds() }) {
        self.fetchBuilds = fetchBuilds
    }

    var pullRequests: [PullRequestBuild] {
        var seen: Set<Int> = []
        return matchingBuilds.filter { seen.insert($0.pullRequest).inserted }
    }

    private var matchingBuilds: [PullRequestBuild] {
        builds.filter { build in
            search.isEmpty || "\(build.pullRequest) \(build.title) \(build.commitSubject) \(build.headSHA)".localizedCaseInsensitiveContains(search)
        }
    }

    var selectedBuilds: [PullRequestBuild] {
        matchingBuilds.filter { $0.pullRequest == selectedPullRequest }
    }

    var selectedBuild: PullRequestBuild? {
        selectedBuilds.first { $0.id == selectedBuildID } ?? selectedBuilds.first
    }

    var latestBuildID: String? {
        builds.first { $0.pullRequest == selectedPullRequest }?.id
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            builds = try await fetchBuilds()
            if !pullRequests.contains(where: { $0.pullRequest == selectedPullRequest }) {
                selectedPullRequest = pullRequests.first?.pullRequest
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
