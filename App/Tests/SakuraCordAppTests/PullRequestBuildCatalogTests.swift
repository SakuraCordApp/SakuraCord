import Foundation
import Testing
@testable import SakuraCord

@Test("PR catalog decoding preserves immutable build identity and accepts published asset paths")
func pullRequestCatalogDecodesPublishedBuilds() throws {
    let builds = PullRequestBuildFixtures.builds
    var payload = try #require(JSONSerialization.jsonObject(with: catalogData(builds)) as? [String: Any])
    var entries = try #require(payload["builds"] as? [[String: Any]])
    // An older CI run retried later must not outrank the newest PR revision.
    entries[entries.count - 1]["createdAt"] = "2099-01-01T00:00:00Z"
    payload["builds"] = entries.reversed().map { $0 }
    let decoded = try PullRequestBuildClient.decode(JSONSerialization.data(withJSONObject: payload))
    #expect(decoded.map(\.id) == builds.map(\.id))
    #expect(decoded.first?.archiveURL == builds.first?.archiveURL)
    #expect(decoded.first?.commitSubject == builds.first?.commitSubject)
}

@Test("catalog rejects mismatched PR identity and cross-build or external assets", arguments: ["pullRequest", "appcastURL", "archiveURL", "symbolsURL"])
func pullRequestCatalogRejectsSubstitutedBuilds(_ field: String) throws {
    let builds = Array(PullRequestBuildFixtures.builds.prefix(2))
    var payload = try #require(JSONSerialization.jsonObject(with: catalogData(builds)) as? [String: Any])
    var entries = try #require(payload["builds"] as? [[String: Any]])
    switch field {
    case "pullRequest": entries[0][field] = builds[0].pullRequest + 1
    case "appcastURL": entries[0][field] = builds[1].appcastURL.absoluteString
    case "archiveURL": entries[0][field] = "https://example.com/SakuraCord.app.zip"
    default: entries[0][field] = builds[1].symbolsURL.absoluteString
    }
    payload["builds"] = entries
    let data = try JSONSerialization.data(withJSONObject: payload)
    #expect(throws: PullRequestBuildError.self) { try PullRequestBuildClient.decode(data) }
}

@Test("catalog rejects duplicate immutable build identities")
func pullRequestCatalogRejectsDuplicateBuilds() throws {
    let build = try #require(PullRequestBuildFixtures.builds.first)
    let data = try catalogData([build, build])
    #expect(throws: PullRequestBuildError.self) { try PullRequestBuildClient.decode(data) }
}

private func catalogData(_ builds: [PullRequestBuild]) throws -> Data {
    struct Catalog: Encodable {
        let schemaVersion = 1
        let builds: [PullRequestBuild]
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(Catalog(builds: builds))
}

@MainActor
@Test("historical commit searches select only matching install targets, including after refresh")
func historicalBuildSearchSelectsMatchingTarget() async throws {
    let store = PullRequestBuildStore(fetchBuilds: { PullRequestBuildFixtures.builds })
    await store.load()
    let historical = try #require(store.builds.first { $0.shortCommit == "a203df8" })
    store.selectedBuildID = store.selectedBuild?.id
    for query in [historical.shortCommit, historical.commitSubject] {
        store.search = query
        #expect(store.selectedBuild?.id == historical.id)
        #expect(store.selectedBuilds.map(\.id) == [historical.id])
        #expect(store.latestBuildID != historical.id)
        await store.load()
        #expect(store.selectedBuild?.id == historical.id)
    }
    store.search = "no matching commit"
    await store.load()
    #expect(store.selectedPullRequest == nil)
    #expect(store.selectedBuild == nil)
}

private nonisolated enum PullRequestBuildFixtures {
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
