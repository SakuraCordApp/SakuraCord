import Foundation

/// The current account's application to an apply-to-join server.
public struct GuildJoinRequest: Equatable, Sendable, Identifiable {
    public enum Status: Equatable, Sendable {
        /// Opened but not submitted. Discord keeps it until the form is submitted or withdrawn.
        case started
        case submitted
        case rejected
        case approved
        case unknown(String)

        public init(_ value: String) {
            switch value {
            case "STARTED": self = .started
            case "SUBMITTED": self = .submitted
            case "REJECTED": self = .rejected
            case "APPROVED": self = .approved
            default: self = .unknown(value)
            }
        }
    }

    public var id: JoinRequestID
    public var guildID: GuildID
    public var status: Status
    public var rejectionReason: String?
    public var interviewChannelID: ChannelID?
    /// An approval the applicant already acknowledged.
    public var isAcknowledged: Bool

    /// Submitted and awaiting review, or rejected; the applicant's status page describes it.
    public var isOpen: Bool { status == .submitted || status == .rejected }

    public init(id: JoinRequestID, guildID: GuildID, status: Status, rejectionReason: String? = nil,
                interviewChannelID: ChannelID? = nil, isAcknowledged: Bool = false) {
        self.id = id
        self.guildID = guildID
        self.status = status
        self.rejectionReason = rejectionReason
        self.interviewChannelID = interviewChannelID
        self.isAcknowledged = isAcknowledged
    }
}

/// A server's join application, as Discord presents it to an applicant.
public struct GuildJoinApplicationForm: Equatable, Sendable {
    public var guildID: GuildID
    /// Absent when Discord omits the server, as it does for an existing member.
    public var guildName: String?
    public var iconURL: URL?
    public var description: String?
    public var memberCount: Int?
    public var onlineCount: Int?
    public var fields: [GuildJoinApplicationField]

    public init(guildID: GuildID, guildName: String?, iconURL: URL? = nil, description: String? = nil,
                memberCount: Int? = nil, onlineCount: Int? = nil, fields: [GuildJoinApplicationField]) {
        self.guildID = guildID
        self.guildName = guildName
        self.iconURL = iconURL
        self.description = description
        self.memberCount = memberCount
        self.onlineCount = onlineCount
        self.fields = fields
    }
}

public struct GuildJoinApplicationField: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case shortAnswer
        case paragraph
        /// Choices are answered by their index.
        case multipleChoice([String])
        /// Rules the applicant must agree to.
        case terms([String])
        /// A field type this client cannot answer, such as Discord's verification step.
        case unsupported(String)
    }

    public var kind: Kind
    public var label: String
    public var description: String?
    public var placeholder: String?
    public var isRequired: Bool
    public var answer: GuildJoinApplicationAnswer?

    public init(kind: Kind, label: String, description: String? = nil, placeholder: String? = nil, isRequired: Bool,
                answer: GuildJoinApplicationAnswer? = nil) {
        self.kind = kind
        self.label = label
        self.description = description
        self.placeholder = placeholder
        self.isRequired = isRequired
        self.answer = answer
    }

    /// The first-party form's input limits, in UTF-16 code units like its text inputs' `maxLength`.
    public var characterLimit: Int? {
        switch kind {
        case .shortAnswer: 150
        case .paragraph: 1000
        default: nil
        }
    }

    /// Like the first-party inputs' `maxLength`, an edit that would pass the limit keeps the existing text and drops
    /// what does not fit of the inserted text. It compares and drops whole Unicode scalars, so existing text is never
    /// mistaken for a canonically equal paste and a surrogate pair is never split.
    public func limited(_ text: String, replacing previous: String) -> String {
        guard let characterLimit, text.utf16.count > characterLimit else { return text }
        let new = Array(text.unicodeScalars), old = Array(previous.unicodeScalars)
        var prefix = 0
        while prefix < min(new.count, old.count), new[prefix] == old[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(new.count, old.count) - prefix, new[new.count - 1 - suffix] == old[old.count - 1 - suffix] {
            suffix += 1
        }
        var room = characterLimit - new[..<prefix].utf16Count - new[(new.count - suffix)...].utf16Count
        let inserted = new[prefix ..< new.count - suffix].prefix { scalar in
            room -= scalar.utf16.count
            return room >= 0
        }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: new[..<prefix])
        result.append(contentsOf: inserted)
        result.append(contentsOf: new[(new.count - suffix)...])
        return String(result)
    }

    public var isSatisfied: Bool {
        switch (kind, answer) {
        case (.unsupported, _): return false
        case (_, nil): return !isRequired
        case (.shortAnswer, .text(let text)?), (.paragraph, .text(let text)?):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (!isRequired || !trimmed.isEmpty) && text.utf16.count <= characterLimit ?? .max
        case (.multipleChoice(let choices), .choice(let index)?): return choices.indices.contains(index)
        case (.terms, .agreed(let agreed)?): return agreed || !isRequired
        default: return false
        }
    }
}

public enum GuildJoinApplicationAnswer: Equatable, Sendable {
    case text(String)
    case choice(Int)
    case agreed(Bool)
}

/// A server the account applied to. It is not in the account's server list until approved.
public struct GuildJoinRequestGuild: Equatable, Sendable {
    public var id: GuildID
    public var name: String
    public var iconURL: URL?

    public init(id: GuildID, name: String, iconURL: URL? = nil) {
        self.id = id
        self.name = name
        self.iconURL = iconURL
    }
}

private extension ArraySlice<Unicode.Scalar> {
    var utf16Count: Int { reduce(0) { $0 + $1.utf16.count } }
}
