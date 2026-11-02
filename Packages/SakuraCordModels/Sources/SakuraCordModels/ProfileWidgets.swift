import Foundation

public enum ProfileGameWidgetKind: String, CaseIterable, Codable, Sendable {
    case favorite = "favorite_games"
    case rotation = "current_games"
    case liked = "played_games"
    case wanted = "want_to_play_games"

    public var capacity: Int {
        switch self {
        case .favorite: 1
        case .rotation: 5
        case .liked, .wanted: 20
        }
    }
}

public struct ProfileWidgetGame: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var comment: String?
    /// A fresh game omits comment; hydrated games retain explicit null.
    public var includesComment: Bool
    /// Nil is omitted; an empty array is an explicit empty tag list.
    public var tags: [String]?
    public var includesTags: Bool

    public init(id: String, comment: String? = nil, includesComment: Bool = false, tags: [String]? = nil, includesTags: Bool = false) {
        self.id = id
        self.comment = comment
        self.includesComment = includesComment
        self.tags = tags
        self.includesTags = includesTags || tags != nil
    }
}

public struct ProfileWidgetImage: Codable, Hashable, Sendable {
    public enum Reference: Codable, Hashable, Sendable {
        case pendingUpload(filename: String)
        case saved(fileID: String, width: Int, height: Int, isAnimated: Bool)
    }
    public var reference: Reference
    public var url: URL?

    public init(reference: Reference, url: URL? = nil) { self.reference = reference; self.url = url }
}

public struct ProfileWidgetCover: Codable, Hashable, Sendable {
    public var title: String
    public var subtitle: String
    public var image: ProfileWidgetImage?
    public var includesImage: Bool

    public init(title: String = "", subtitle: String = "", image: ProfileWidgetImage? = nil, includesImage: Bool = false) {
        self.title = title; self.subtitle = subtitle; self.image = image; self.includesImage = includesImage
    }

    public var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && image == nil
    }
}

public struct ProfileWidgetField: Identifiable, Codable, Hashable, Sendable {
    public let id = UUID()
    public var title: String
    public var description: String
    public var image: ProfileWidgetImage?
    public var includesImage: Bool

    public init(title: String = "", description: String = "", image: ProfileWidgetImage? = nil, includesImage: Bool = false) {
        self.title = title; self.description = description; self.image = image; self.includesImage = includesImage
    }

    public var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && image == nil
    }

    private enum CodingKeys: String, CodingKey { case title, description, image, includesImage }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.description == rhs.description && lhs.image == rhs.image && lhs.includesImage == rhs.includesImage
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(title); hasher.combine(description); hasher.combine(image); hasher.combine(includesImage)
    }
}

public enum ProfilePersonalWidgetSection: Codable, Hashable, Sendable {
    case cover(ProfileWidgetCover)
    case fields([ProfileWidgetField])

    public var isEmpty: Bool {
        switch self {
        case let .cover(cover): cover.isEmpty
        case let .fields(fields): fields.allSatisfy(\.isEmpty)
        }
    }
}

public struct ProfilePersonalWidget: Codable, Hashable, Sendable {
    public var header: String
    public var sections: [ProfilePersonalWidgetSection]

    public init(header: String = "", sections: [ProfilePersonalWidgetSection] = []) { self.header = header; self.sections = sections }
}

public struct ProfileWidget: Identifiable, Codable, Hashable, Sendable {
    public enum Content: Codable, Hashable, Sendable {
        case application(id: String)
        case personal(ProfilePersonalWidget)
        case games(ProfileGameWidgetKind, [ProfileWidgetGame])
        /// The provider retains unknown wire data; an editor may not rewrite it.
        case unrecognized(type: String)
    }
    public var serverID: String?
    public var draftID: UUID
    public var updatedAt: String?
    public var content: Content
    public var id: String { serverID ?? draftID.uuidString }

    public var isDiscardable: Bool {
        switch content {
        case let .personal(personal): personal.sections.allSatisfy(\.isEmpty)
        case let .games(_, games): games.isEmpty
        case .application, .unrecognized: false
        }
    }

    public init(serverID: String? = nil, draftID: UUID = UUID(), updatedAt: String? = nil, content: Content) {
        self.serverID = serverID; self.draftID = draftID; self.updatedAt = updatedAt; self.content = content
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.updatedAt == rhs.updatedAt && lhs.content == rhs.content
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id); hasher.combine(updatedAt); hasher.combine(content)
    }
}

public struct ProfileGame: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var iconURL: URL?
    public var coverURL: URL?
    public var isAllowedInDefaultWidgetPicker: Bool
    public var metadata: ProfileGameMetadata?

    public init(id: String, name: String, iconURL: URL? = nil, coverURL: URL? = nil, isAllowedInDefaultWidgetPicker: Bool = true) {
        self.id = id; self.name = name; self.iconURL = iconURL; self.coverURL = coverURL
        self.isAllowedInDefaultWidgetPicker = isAllowedInDefaultWidgetPicker
    }

    /// The game's icon, or its cover when it has no icon.
    public var artworkURL: URL? { iconURL ?? coverURL }
}

public struct ProfileWidgetGameSuggestions: Sendable {
    public var gameIDs: [String]
    public var wantedGameIDs: [String]
    public var fallbackGameIDs: [String]

    public init(gameIDs: [String], wantedGameIDs: [String], fallbackGameIDs: [String]) {
        self.gameIDs = gameIDs; self.wantedGameIDs = wantedGameIDs; self.fallbackGameIDs = fallbackGameIDs
    }
}
