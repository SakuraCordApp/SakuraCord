import Foundation

private struct RefreshedAttachmentURLs: Decodable {
    struct Entry: Decodable {
        let original: String
        let refreshed: String
    }

    let refreshedURLs: [Entry]

    enum CodingKeys: String, CodingKey {
        case refreshedURLs = "refreshed_urls"
    }
}

public extension DiscordRESTProvider {
    func refreshedAttachmentURL(_ url: URL) async throws -> URL? {
        guard Self.isDiscordAttachmentURL(url) else { return nil }
        let response: RefreshedAttachmentURLs = try await request(
            "/attachments/refresh-urls",
            method: "POST",
            body: ["attachment_urls": .array([.string(url.absoluteString)])]
        )
        guard let refreshed = response.refreshedURLs.first(where: {
            $0.original == url.absoluteString
        }).flatMap({ URL(string: $0.refreshed) }),
              Self.isDiscordAttachmentURL(refreshed),
              refreshed.path == url.path
        else { return nil }
        return refreshed
    }

    private static func isDiscordAttachmentURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.user == nil
            && url.password == nil
            && url.port == nil
            && ["cdn.discordapp.com", "media.discordapp.net"].contains(
                url.host?.lowercased() ?? ""
            )
            && (url.path.hasPrefix("/attachments/")
                || url.path.hasPrefix("/ephemeral-attachments/"))
    }
}
