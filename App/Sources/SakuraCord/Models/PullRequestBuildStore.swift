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
    let isPreview: Bool

    init(isPreview: Bool = false) {
        self.isPreview = isPreview
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
            if isPreview {
                builds = PullRequestBuildFixtures.builds
            } else {
                builds = try await PullRequestBuildClient().fetchBuilds()
            }
            if !pullRequests.contains(where: { $0.pullRequest == selectedPullRequest }) {
                selectedPullRequest = pullRequests.first?.pullRequest
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

nonisolated enum PullRequestBuildFixtures {
    static var builds: [PullRequestBuild] {
        let entries = [
            (312, "Keep your place when switching channels", "8f3ac12", 0, "Restore scroll position after loading history"),
            (308, "Smoother screen sharing at high frame rates", "c4e91a7", 1, "Reduce frame queue latency during screen sharing"),
            (305, "Improve unread badges in server folders", "b71d083", 2, "Update folder badges when channels are marked read"),
            (299, "Add keyboard navigation to the emoji picker", "e925db4", 3, "Move between emoji rows with arrow keys"),
            (312, "Keep your place when switching channels", "a203df8", 5, "Keep the visible message anchored on channel switch"),
            (312, "Keep your place when switching channels", "73eab06", 24, "Save each channel’s last visible message"),
        ]
        return entries.enumerated().map { index, entry in
            let runID = 9000 - index
            let id = PullRequestBuild.id(pullRequest: entry.0, runID: runID, runAttempt: 1)
            return PullRequestBuild(
                id: id, pullRequest: entry.0, title: entry.1, commitSubject: entry.4,
                headSHA: entry.2 + String(repeating: "0", count: 33),
                builtSHA: String(repeating: "a", count: 40), runID: runID, runAttempt: 1,
                configuration: "debug", architecture: "arm64",
                createdAt: .now.addingTimeInterval(-Double(entry.3 + 1) * 3600),
                version: "0.3.0", buildVersion: PullRequestBuild.buildVersion(runID: runID, runAttempt: 1),
                appcastURL: PullRequestBuild.assetURL(id: id, name: "appcast.xml")!,
                archiveURL: PullRequestBuild.assetURL(id: id, name: "SakuraCord.app.zip")!,
                symbolsURL: PullRequestBuild.assetURL(id: id, name: "SakuraCord.dSYM.zip")!,
                sha256: String(repeating: "a", count: 64)
            )
        }
    }
}
