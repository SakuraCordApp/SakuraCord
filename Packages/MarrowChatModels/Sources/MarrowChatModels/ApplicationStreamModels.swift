import Foundation

public enum ApplicationStreamType: String, Codable, Equatable, Sendable {
    case guild
    case call
}

/// Discord's stable identity for a screen-sharing stream.
///
/// Guild streams use `guild:<guild id>:<channel id>:<owner id>` while
/// private-call streams use `call:<channel id>:<owner id>`.
public struct ApplicationStreamKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public var type: ApplicationStreamType
    public var guildID: GuildID?
    public var channelID: ChannelID
    public var ownerID: UserID

    public init(
        type: ApplicationStreamType,
        guildID: GuildID?,
        channelID: ChannelID,
        ownerID: UserID
    ) {
        self.type = type
        self.guildID = guildID
        self.channelID = channelID
        self.ownerID = ownerID
    }

    public init?(rawValue: String) {
        let components = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        switch components.first {
        case "guild" where components.count == 4:
            guard let guildID = GuildID(String(components[1])),
                  let channelID = ChannelID(String(components[2])),
                  let ownerID = UserID(String(components[3]))
            else { return nil }
            self.init(
                type: .guild,
                guildID: guildID,
                channelID: channelID,
                ownerID: ownerID
            )
        case "call" where components.count == 3:
            guard let channelID = ChannelID(String(components[1])),
                  let ownerID = UserID(String(components[2]))
            else { return nil }
            self.init(
                type: .call,
                guildID: nil,
                channelID: channelID,
                ownerID: ownerID
            )
        default:
            return nil
        }
    }

    public var rawValue: String {
        switch type {
        case .guild:
            guard let guildID else { return "guild::\(channelID):\(ownerID)" }
            return "guild:\(guildID):\(channelID):\(ownerID)"
        case .call:
            return "call:\(channelID):\(ownerID)"
        }
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let key = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid Discord application stream key."
            )
        }
        self = key
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ApplicationStream: Equatable, Sendable, Identifiable {
    public var key: ApplicationStreamKey
    public var region: String?
    public var viewerIDs: [UserID]
    public var rtcServerID: String?
    public var rtcChannelID: ChannelID?
    public var isPaused: Bool

    public var id: ApplicationStreamKey { key }

    public init(
        key: ApplicationStreamKey,
        region: String? = nil,
        viewerIDs: [UserID] = [],
        rtcServerID: String? = nil,
        rtcChannelID: ChannelID? = nil,
        isPaused: Bool = false
    ) {
        self.key = key
        self.region = region
        self.viewerIDs = viewerIDs
        self.rtcServerID = rtcServerID
        self.rtcChannelID = rtcChannelID
        self.isPaused = isPaused
    }
}

public struct ApplicationStreamConnectionInfo: Equatable, Sendable {
    public var stream: ApplicationStream
    public var voice: VoiceConnectionInfo

    public init(stream: ApplicationStream, voice: VoiceConnectionInfo) {
        self.stream = stream
        self.voice = voice
    }
}
