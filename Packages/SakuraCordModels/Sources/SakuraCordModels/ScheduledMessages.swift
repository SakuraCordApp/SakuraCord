import Foundation

public enum ScheduledMessageKind: Sendable {}
public typealias ScheduledMessageID = Snowflake<ScheduledMessageKind>

/// A message Discord holds to send later on the account's behalf.
public struct ScheduledMessage: Identifiable, Equatable, Sendable {
    /// Discord's delivery state; anything but `scheduled` will not be sent.
    public enum State: Int, Sendable {
        case scheduled = 0
        case disabled = 1
        case userNotFound = 2
        case userCannotSchedule = 3
        case channelNotFound = 4
        case sendFailed = 5
    }

    public var id: ScheduledMessageID
    public var channelID: ChannelID
    public var sendAt: Date
    public var content: String
    public var flags: MessageFlags
    public var replyTo: MessageID?
    public var state: State
    public var attachmentCount: Int
    /// The message as it will be posted, with its author, stickers and link embeds.
    public var preview: Message?

    public init(
        id: ScheduledMessageID, channelID: ChannelID, sendAt: Date, content: String,
        flags: MessageFlags = [], replyTo: MessageID? = nil, state: State = .scheduled, attachmentCount: Int = 0,
        preview: Message? = nil
    ) {
        self.id = id
        self.channelID = channelID
        self.sendAt = sendAt
        self.content = content
        self.flags = flags
        self.replyTo = replyTo
        self.state = state
        self.attachmentCount = attachmentCount
        self.preview = preview
    }
}

/// The official client's scheduling rules (web build 670026).
public enum ScheduledMessagePolicy {
    /// How many full Nitro (premium type 2) may hold at once.
    public static let nitroLimit = 25

    /// Every plan but full Nitro schedules one at a time.
    public static func limit(premiumType: Int) -> Int {
        premiumType == 2 ? nitroLimit : 1
    }

    /// Discord refuses a time less than ten minutes away.
    public static func earliestSendDate(now: Date = .now) -> Date {
        now.addingTimeInterval(600)
    }

    /// Eight days ahead; an existing message also stays within 30 days of its creation.
    public static func latestSendDate(for id: ScheduledMessageID? = nil, now: Date = .now) -> Date {
        let latest = now.addingTimeInterval(691_200)
        guard let id else { return latest }
        return min(latest, id.createdAt.addingTimeInterval(2_592_000))
    }
}
