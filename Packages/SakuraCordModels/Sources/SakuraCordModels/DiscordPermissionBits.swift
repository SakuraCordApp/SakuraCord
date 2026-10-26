/// Discord permission bits used by SakuraCord's permission policies. Values are
/// the documented `permissions` bit positions.
public enum DiscordPermissionBits {
    public static let createInstantInvite: UInt64 = 1 << 0
    public static let administrator: UInt64 = 1 << 3
    public static let addReactions: UInt64 = 1 << 6
    public static let viewChannel: UInt64 = 1 << 10
    public static let sendMessages: UInt64 = 1 << 11
    public static let manageMessages: UInt64 = 1 << 13
    public static let embedLinks: UInt64 = 1 << 14
    public static let attachFiles: UInt64 = 1 << 15
    public static let readMessageHistory: UInt64 = 1 << 16
    public static let useExternalEmojis: UInt64 = 1 << 18
    public static let connect: UInt64 = 1 << 20
    public static let speak: UInt64 = 1 << 21
    public static let changeNickname: UInt64 = 1 << 26
    public static let manageNicknames: UInt64 = 1 << 27
    public static let manageThreads: UInt64 = 1 << 34
    public static let createPublicThreads: UInt64 = 1 << 35
    public static let createPrivateThreads: UInt64 = 1 << 36
    public static let useExternalStickers: UInt64 = 1 << 37
    public static let sendMessagesInThreads: UInt64 = 1 << 38
    public static let useSoundboard: UInt64 = 1 << 42
    public static let sendVoiceMessages: UInt64 = 1 << 46
    public static let useExternalSounds: UInt64 = 1 << 45
    public static let pinMessages: UInt64 = 1 << 51
    public static let bypassSlowmode: UInt64 = 1 << 52
}
