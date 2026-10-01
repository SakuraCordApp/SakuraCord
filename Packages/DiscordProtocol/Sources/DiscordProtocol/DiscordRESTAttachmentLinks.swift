import Foundation

public extension DiscordRESTProvider {
    func refreshAttachmentURL(_ url: URL) async throws -> URL? {
        let response: AttachmentURLRefreshDTO = try await request(
            "/attachments/refresh-urls", method: "POST",
            body: ["attachment_urls": .array([.string(url.absoluteString)])]
        )
        return response.refreshedURLs.first?.refreshed.flatMap(URL.init(string:))
    }
}

private struct AttachmentURLRefreshDTO: Decodable {
    struct RefreshedURL: Decodable {
        var refreshed: String?
    }

    var refreshedURLs: [RefreshedURL]
    enum CodingKeys: String, CodingKey {
        case refreshedURLs = "refreshed_urls"
    }
}
