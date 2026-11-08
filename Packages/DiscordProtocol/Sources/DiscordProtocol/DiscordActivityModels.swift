import Foundation

public enum ActivityType: Int, Codable, CaseIterable, Hashable, Sendable {
    case playing = 0
    case streaming = 1
    case listening = 2
    case watching = 3
    case custom = 4
    case competing = 5
}

public struct ActivityTimestamps: Codable, Hashable, Sendable {
    public var start: Int64?
    public var end: Int64?

    public init(start: Int64? = nil, end: Int64? = nil) {
        self.start = start
        self.end = end
    }
}

public struct ActivityAssets: Codable, Hashable, Sendable {
    public var largeImage: String?
    public var largeText: String?
    public var smallImage: String?
    public var smallText: String?

    enum CodingKeys: String, CodingKey {
        case largeImage = "large_image"
        case largeText = "large_text"
        case smallImage = "small_image"
        case smallText = "small_text"
    }

    public init(
        largeImage: String? = nil,
        largeText: String? = nil,
        smallImage: String? = nil,
        smallText: String? = nil
    ) {
        self.largeImage = largeImage
        self.largeText = largeText
        self.smallImage = smallImage
        self.smallText = smallText
    }
}

public struct ActivityParty: Codable, Hashable, Sendable {
    public var id: String?
    public var currentSize: Int?
    public var maxSize: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case size
    }

    public init(id: String? = nil, currentSize: Int? = nil, maxSize: Int? = nil) {
        self.id = id
        self.currentSize = currentSize
        self.maxSize = maxSize
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
        if let size = try container.decodeIfPresent([Int].self, forKey: .size) {
            self.currentSize = size.indices.contains(0) ? size[0] : nil
            self.maxSize = size.indices.contains(1) ? size[1] : nil
        } else {
            self.currentSize = nil
            self.maxSize = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        if let currentSize, let maxSize {
            try container.encode([currentSize, maxSize], forKey: .size)
        }
    }
}

public struct ActivitySecrets: Codable, Hashable, Sendable {
    public var join: String?
    public var spectate: String?
    public var match: String?

    public init(join: String? = nil, spectate: String? = nil, match: String? = nil) {
        self.join = join
        self.spectate = spectate
        self.match = match
    }
}

public struct ActivityButton: Codable, Hashable, Sendable {
    public var label: String
    public var url: String

    public init(label: String, url: String) {
        self.label = label
        self.url = url
    }
}

public struct OutgoingActivityPayload: Codable, Hashable, Sendable {
    public var name: String
    public var type: ActivityType
    public var url: String?
    public var details: String?
    public var state: String?
    public var timestamps: ActivityTimestamps?
    public var assets: ActivityAssets?
    public var party: ActivityParty?
    public var secrets: ActivitySecrets?
    public var instance: Bool?
    public var flags: Int?
    public var buttons: [ActivityButton]?
    public var applicationId: String?

    enum CodingKeys: String, CodingKey {
        case name, type, url, details, state, timestamps, assets, party, secrets, instance, flags, buttons
        case applicationId = "application_id"
    }

    public init(
        name: String,
        type: ActivityType = .playing,
        url: String? = nil,
        details: String? = nil,
        state: String? = nil,
        timestamps: ActivityTimestamps? = nil,
        assets: ActivityAssets? = nil,
        party: ActivityParty? = nil,
        secrets: ActivitySecrets? = nil,
        instance: Bool? = nil,
        flags: Int? = nil,
        buttons: [ActivityButton]? = nil,
        applicationId: String? = nil
    ) {
        self.name = name
        self.type = type
        self.url = url
        self.details = details
        self.state = state
        self.timestamps = timestamps
        self.assets = assets
        self.party = party
        self.secrets = secrets
        self.instance = instance
        self.flags = flags
        self.buttons = buttons
        self.applicationId = applicationId
    }

    public var priorityRank: Int {
        switch type {
        case .playing: return 1
        case .competing: return 2
        case .streaming: return 3
        case .watching: return 4
        case .listening: return 5
        case .custom: return 6
        }
    }

    public var gatewayDictionary: [String: Any] {
        var dict: [String: Any] = [
            "name": name,
            "type": type.rawValue,
        ]
        if let url, !url.isEmpty { dict["url"] = url }
        if let details, !details.isEmpty { dict["details"] = details }
        if let state, !state.isEmpty { dict["state"] = state }
        if let timestamps {
            var ts: [String: Any] = [:]
            if let start = timestamps.start { ts["start"] = start }
            if let end = timestamps.end { ts["end"] = end }
            if !ts.isEmpty { dict["timestamps"] = ts }
        }
        if let assets {
            var ast: [String: Any] = [:]
            if let largeImage = assets.largeImage, !largeImage.isEmpty { ast["large_image"] = largeImage }
            if let largeText = assets.largeText, !largeText.isEmpty { ast["large_text"] = largeText }
            if let smallImage = assets.smallImage, !smallImage.isEmpty { ast["small_image"] = smallImage }
            if let smallText = assets.smallText, !smallText.isEmpty { ast["small_text"] = smallText }
            if !ast.isEmpty { dict["assets"] = ast }
        }
        if let party {
            var prt: [String: Any] = [:]
            if let id = party.id, !id.isEmpty { prt["id"] = id }
            if let currentSize = party.currentSize, let maxSize = party.maxSize {
                prt["size"] = [currentSize, maxSize]
            }
            if !prt.isEmpty { dict["party"] = prt }
        }
        if let secrets {
            var sec: [String: Any] = [:]
            if let join = secrets.join, !join.isEmpty { sec["join"] = join }
            if let spectate = secrets.spectate, !spectate.isEmpty { sec["spectate"] = spectate }
            if let match = secrets.match, !match.isEmpty { sec["match"] = match }
            if !sec.isEmpty { dict["secrets"] = sec }
        }
        if let instance { dict["instance"] = instance }
        if let flags { dict["flags"] = flags }
        if let buttons, !buttons.isEmpty {
            dict["buttons"] = buttons.map { ["label": $0.label, "url": $0.url] }
        }
        if let applicationId, !applicationId.isEmpty {
            dict["application_id"] = applicationId
        }
        return dict
    }
}
