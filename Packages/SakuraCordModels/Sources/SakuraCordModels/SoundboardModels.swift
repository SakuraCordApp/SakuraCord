import Foundation

public struct SoundboardSound: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var volume: Double
    public var emojiID: String?
    public var emojiName: String?
    public var guildID: GuildID?
    public var userID: UserID?
    public var isAvailable: Bool

    public init(
        id: String,
        name: String,
        volume: Double = 1,
        emojiID: String? = nil,
        emojiName: String? = nil,
        guildID: GuildID? = nil,
        userID: UserID? = nil,
        isAvailable: Bool = true
    ) {
        self.id = id
        self.name = name
        self.volume = volume
        self.emojiID = emojiID
        self.emojiName = emojiName
        self.guildID = guildID
        self.userID = userID
        self.isAvailable = isAvailable
    }

    public var mediaURL: URL? {
        guard id.allSatisfy(\.isNumber) else { return nil }
        return URL(string: "https://cdn.discordapp.com/soundboard-sounds/\(id)")
    }
}

public struct SoundboardUserSettings: Equatable, Sendable {
    public var favoriteSoundIDs: [String]
    public var frequentlyUsedSoundIDs: [String]
    public var usageScores: [String: Int]

    public init(
        favoriteSoundIDs: [String] = [],
        frequentlyUsedSoundIDs: [String] = [],
        usageScores: [String: Int] = [:]
    ) {
        self.favoriteSoundIDs = favoriteSoundIDs
        self.frequentlyUsedSoundIDs = frequentlyUsedSoundIDs
        self.usageScores = usageScores
    }
}

public struct VoiceChannelEffect: Equatable, Sendable {
    public var channelID: ChannelID
    public var guildID: GuildID?
    public var userID: UserID
    public var soundID: String?
    public var soundVolume: Double

    public init(
        channelID: ChannelID,
        guildID: GuildID?,
        userID: UserID,
        soundID: String?,
        soundVolume: Double = 1
    ) {
        self.channelID = channelID
        self.guildID = guildID
        self.userID = userID
        self.soundID = soundID
        self.soundVolume = soundVolume
    }
}
