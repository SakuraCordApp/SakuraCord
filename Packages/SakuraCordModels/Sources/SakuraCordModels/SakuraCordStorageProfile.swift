import Foundation

/// A PR track's durable state survives its updates, separate from other PRs and
/// the regular installation. Invalid metadata still selects isolated storage.
public struct SakuraCordStorageProfile: Equatable, Sendable {
    public static let current = SakuraCordStorageProfile(infoDictionary: Bundle.main.infoDictionary ?? [:])
    public let previewIdentifier: String?

    public init(infoDictionary: [String: Any]) {
        guard let value = infoDictionary["SakuraCordPullRequestBuildID"] else {
            previewIdentifier = nil
            return
        }
        let identifier = value as? String ?? ""
        previewIdentifier = identifier.range(
            of: #"^pr-[1-9][0-9]*-run-[1-9][0-9]*-attempt-[1-9][0-9]*\z"#,
            options: .regularExpression
        ) != nil ? identifier : "unrecognized-preview"
    }

    public var storageIdentifier: String? {
        previewIdentifier.map { identifier in
            identifier == "unrecognized-preview" ? identifier : identifier.split(separator: "-").prefix(2).joined(separator: "-")
        }
    }
}
