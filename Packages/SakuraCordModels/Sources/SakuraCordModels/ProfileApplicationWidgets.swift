import Foundation

public enum ProfileWidgetValue: Codable, Hashable, Sendable {
    case text(String)
    case number(Double)
    case image(url: URL, width: Double, height: Double)
}

public indirect enum ProfileWidgetFieldSource: Codable, Hashable, Sendable {
    case literal(ProfileWidgetValue)
    case data(key: String, fallback: ProfileWidgetConfiguredField?)
    case unavailable
}

public struct ProfileWidgetConfiguredField: Codable, Hashable, Sendable {
    public var presentation: String
    public var source: ProfileWidgetFieldSource

    public init(presentation: String, source: ProfileWidgetFieldSource) {
        self.presentation = presentation; self.source = source
    }

    public func resolve(data: [String: ProfileWidgetValue]) -> ProfileWidgetValue? {
        switch source {
        case let .literal(value): return matching(value)
        case let .data(key, fallback):
            guard let value = data[key], let matched = matching(value) else { return fallback?.resolve(data: data) }
            if key == "playtime_hours", presentation == "duration", case let .number(hours) = matched {
                return .number(floor(hours * 3_600_000))
            }
            return matched
        case .unavailable: return nil
        }
    }

    private func matching(_ value: ProfileWidgetValue) -> ProfileWidgetValue? {
        switch (presentation, value) {
        case ("text", .text), ("number", .number), ("duration", .number), ("image", .image): value
        default: nil
        }
    }
}

public struct ProfileWidgetSurface: Codable, Hashable, Sendable {
    public var layout: String
    public var components: [String: [String: ProfileWidgetConfiguredField]]

    public init(layout: String, components: [String: [String: ProfileWidgetConfiguredField]]) {
        self.layout = layout; self.components = components
    }
}

public struct ProfileApplicationWidget: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var applicationID: String
    public var name: String
    public var applicationName: String
    public var applicationIconURL: URL?
    public var connectionURL: URL?
    public var connectionApplicationID: String?
    public var isPublished: Bool
    public var surfaces: [String: ProfileWidgetSurface]

    public init(id: String, applicationID: String, name: String, applicationName: String,
                applicationIconURL: URL? = nil, connectionURL: URL? = nil,
                isPublished: Bool, surfaces: [String: ProfileWidgetSurface], connectionApplicationID: String? = nil) {
        self.id = id; self.applicationID = applicationID; self.name = name; self.applicationName = applicationName
        self.applicationIconURL = applicationIconURL; self.connectionURL = connectionURL
        self.isPublished = isPublished; self.surfaces = surfaces
        self.connectionApplicationID = connectionApplicationID
    }
}

public struct ProfileWidgetApplicationIdentity: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var data: [String: ProfileWidgetValue]

    public init(applicationID: String, data: [String: ProfileWidgetValue]) { id = applicationID; self.data = data }
}

public enum ProfileWidgetConnection: Codable, Hashable, Sendable {
    case unlinked
    case linked(sharesProfileData: Bool)
}

public struct ProfileWidgetResources: Codable, Hashable, Sendable {
    public var applications: [ProfileApplicationWidget]
    public var identities: [ProfileWidgetApplicationIdentity]
    public var games: [ProfileGame]
    public var errorMessage: String?
    public var connections: [String: ProfileWidgetConnection]?

    public init(applications: [ProfileApplicationWidget] = [], identities: [ProfileWidgetApplicationIdentity] = [],
                games: [ProfileGame] = [], errorMessage: String? = nil) {
        self.applications = applications; self.identities = identities; self.games = games; self.errorMessage = errorMessage
    }
}
