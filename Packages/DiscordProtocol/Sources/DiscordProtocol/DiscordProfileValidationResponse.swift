import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    static func profileValidationError(data: Data, method: String, path: String) -> ProfileValidationError? {
        guard method == "PATCH" else { return nil }
        let fields: Set<String>
        let segments = path.replacingOccurrences(of: "%40", with: "@").split(separator: "/")
        if segments == ["users", "@me"] {
            fields = ["global_name", "avatar", "avatar_description"]
        } else if segments == ["users", "@me", "profile"] {
            fields = ["bio", "pronouns", "banner"]
        } else if segments.count == 4, segments[0] == "guilds", UInt64(segments[1]) != nil,
                  segments[2] == "members", segments[3] == "@me"
        {
            fields = ["nick", "avatar", "avatar_description"]
        } else if segments.count == 4, segments[0] == "guilds", UInt64(segments[1]) != nil,
                  segments[2] == "members", UInt64(segments[3]) != nil
        {
            fields = ["nick"]
        } else if segments.count == 4, segments[0] == "users", segments[1] == "@me",
                  segments[2] == "relationships", UInt64(segments[3]) != nil
        {
            fields = ["nickname"]
        } else if segments.count == 5, segments[0] == "guilds", UInt64(segments[1]) != nil,
                  segments[2] == "members", segments[3] == "@me", segments[4] == "nick"
        {
            fields = ["nick"]
        } else if segments.count == 4, segments[0] == "guilds", UInt64(segments[1]) != nil,
                  segments[2] == "profile", segments[3] == "@me"
        {
            fields = ["bio", "pronouns", "banner"]
        } else if segments.count == 2, segments[0] == "channels", UInt64(segments[1]) != nil {
            // Edit Group's name and icon.
            fields = ["name", "icon"]
        } else { return nil }
        struct FieldError: Decodable {
            struct Message: Decodable { var code: String; var message: String }
            var errors: [Message]
            enum CodingKeys: String, CodingKey { case errors = "_errors" }
        }
        struct Response: Decodable { var code: Int; var errors: [String: FieldError] }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              response.code == 50035, !response.errors.isEmpty,
              Set(response.errors.keys).isSubset(of: fields),
              response.errors.values.allSatisfy({ !$0.errors.isEmpty })
        else { return nil }
        return ProfileValidationError(fields: response.errors.mapValues { $0.errors.map(\.message) })
    }
}
