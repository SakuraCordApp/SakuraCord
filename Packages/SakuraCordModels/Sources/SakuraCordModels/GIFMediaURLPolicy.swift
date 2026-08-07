import Foundation

public enum GIFMediaURLPolicy {
    public static func approved(_ url: URL?) -> URL? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.port == nil || components.port == 443,
              components.user == nil,
              components.password == nil,
              components.host != nil
        else { return nil }
        return url
    }

    public static func isApproved(_ url: URL) -> Bool {
        approved(url) != nil
    }
}
