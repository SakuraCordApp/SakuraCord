import Foundation

nonisolated struct PullRequestBuildClient: Sendable {
    static let catalogURL = PullRequestBuild.assetURL(id: "pr-builds", name: "catalog.json")!

    func fetchBuilds() async throws -> [PullRequestBuild] {
        var request = URLRequest(url: Self.catalogURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw PullRequestBuildError.invalidCatalog
        }
        guard response.statusCode != 404 else { throw PullRequestBuildError.unavailable }
        guard response.statusCode == 200 else { throw PullRequestBuildError.http(response.statusCode) }
        return try Self.decode(data)
    }

    static func decode(_ data: Data) throws -> [PullRequestBuild] {
        guard data.count <= 8_000_000 else { throw PullRequestBuildError.invalidCatalog }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
                throw PullRequestBuildError.invalidCatalog
            }
            return date
        }
        let catalog = try decoder.decode(Catalog.self, from: data)
        guard catalog.schemaVersion == 1, catalog.builds.count <= 10_000,
              Set(catalog.builds.map(\.id)).count == catalog.builds.count
        else { throw PullRequestBuildError.invalidCatalog }
        try catalog.builds.forEach { try $0.validate() }
        return catalog.builds.sorted {
            $0.runID != $1.runID ? $0.runID > $1.runID : $0.runAttempt > $1.runAttempt
        }
    }

    private struct Catalog: Decodable {
        let schemaVersion: Int
        let builds: [PullRequestBuild]
    }
}
