import Foundation

public enum ChannelKindValue: String, Codable, Hashable, Sendable {
    case text, announcement, forum, voice, directMessage, groupDirectMessage, unknown
}

public struct ForumTag: Identifiable, Codable, Hashable, Sendable {
    public let id: ForumTagID
    public var name: String
    public var isModerated: Bool
    public var emojiID: String?
    public var emojiName: String?

    public init(
        id: ForumTagID,
        name: String,
        isModerated: Bool = false,
        emojiID: String? = nil,
        emojiName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isModerated = isModerated
        self.emojiID = emojiID
        self.emojiName = emojiName
    }
}

public struct ForumDefaultReaction: Codable, Hashable, Sendable {
    public var emojiID: String?
    public var emojiName: String?

    public init(emojiID: String? = nil, emojiName: String? = nil) {
        self.emojiID = emojiID
        self.emojiName = emojiName
    }
}

public enum ForumSortOrder: Int, Codable, CaseIterable, Hashable, Sendable {
    case latestActivity = 0
    case creationDate = 1
}

public enum ForumLayout: Int, Codable, CaseIterable, Hashable, Sendable {
    case defaultLayout = 0
    case list = 1
    case gallery = 2
}

public enum ForumTagMatch: String, Codable, CaseIterable, Hashable, Sendable {
    case matchSome = "match_some"
    case matchAll = "match_all"
}

public struct ChannelPermissionOverwrite: Codable, Hashable, Sendable {
    public var id: String
    public var type: Int
    public var allow: UInt64
    public var deny: UInt64

    public init(id: String, type: Int, allow: UInt64 = 0, deny: UInt64 = 0) {
        self.id = id
        self.type = type
        self.allow = allow
        self.deny = deny
    }
}

public struct Channel: Identifiable, Codable, Hashable, Sendable {
    public let id: ChannelID
    public var guildID: GuildID?
    public var name: String
    public var hasExplicitName: Bool
    public var iconURL: URL?
    public var ownerID: UserID?
    public var topic: String?
    public var kind: ChannelKindValue
    public var category: String?
    public var categoryID: ChannelID?
    public var position: Int
    public var categoryPosition: Int
    public var unreadCount: Int
    public var mentionCount: Int
    public var isMuted: Bool
    public var isAgeRestricted: Bool
    public var recipients: [User]
    public var blockedUserWarningDismissed: Bool
    public var permissionOverwrites: [ChannelPermissionOverwrite]?
    public var memberListID: String?
    public var lastMessageID: MessageID?
    public var lastPinTimestamp: Date?
    public var flags: UInt64
    public var availableTags: [ForumTag]
    public var defaultReaction: ForumDefaultReaction?
    public var defaultSortOrder: ForumSortOrder?
    public var defaultForumLayout: ForumLayout
    public var defaultTagMatch: ForumTagMatch
    public var defaultAutoArchiveDuration: Int?
    public var defaultThreadRateLimitPerUser: Int?
    public var rateLimitPerUser: Int
    public var voiceStatus: String?
    public var voiceStartTime: Date?

    public init(
        id: ChannelID,
        guildID: GuildID?,
        name: String,
        hasExplicitName: Bool = true,
        iconURL: URL? = nil,
        ownerID: UserID? = nil,
        topic: String? = nil,
        kind: ChannelKindValue = .text,
        category: String? = nil,
        categoryID: ChannelID? = nil,
        position: Int = 0,
        categoryPosition: Int = 0,
        unreadCount: Int = 0,
        mentionCount: Int = 0,
        isMuted: Bool = false,
        isAgeRestricted: Bool = false,
        recipients: [User] = [],
        blockedUserWarningDismissed: Bool = false,
        permissionOverwrites: [ChannelPermissionOverwrite]? = nil,
        memberListID: String? = nil,
        lastMessageID: MessageID? = nil,
        lastPinTimestamp: Date? = nil,
        flags: UInt64 = 0,
        availableTags: [ForumTag] = [],
        defaultReaction: ForumDefaultReaction? = nil,
        defaultSortOrder: ForumSortOrder? = nil,
        defaultForumLayout: ForumLayout = .defaultLayout,
        defaultTagMatch: ForumTagMatch = .matchSome,
        defaultAutoArchiveDuration: Int? = nil,
        defaultThreadRateLimitPerUser: Int? = nil,
        rateLimitPerUser: Int = 0,
        voiceStatus: String? = nil,
        voiceStartTime: Date? = nil
    ) {
        self.id = id
        self.guildID = guildID
        self.name = name
        self.hasExplicitName = hasExplicitName
        self.iconURL = iconURL
        self.ownerID = ownerID
        self.topic = topic
        self.kind = kind
        self.category = category
        self.categoryID = categoryID
        self.position = position
        self.categoryPosition = categoryPosition
        self.unreadCount = unreadCount
        self.mentionCount = mentionCount
        self.isMuted = isMuted
        self.isAgeRestricted = isAgeRestricted
        self.recipients = recipients
        self.blockedUserWarningDismissed = blockedUserWarningDismissed
        self.permissionOverwrites = permissionOverwrites
        self.memberListID = memberListID
        self.lastMessageID = lastMessageID
        self.lastPinTimestamp = lastPinTimestamp
        self.flags = flags
        self.availableTags = availableTags
        self.defaultReaction = defaultReaction
        self.defaultSortOrder = defaultSortOrder
        self.defaultForumLayout = defaultForumLayout
        self.defaultTagMatch = defaultTagMatch
        self.defaultAutoArchiveDuration = defaultAutoArchiveDuration
        self.defaultThreadRateLimitPerUser = defaultThreadRateLimitPerUser
        self.rateLimitPerUser = rateLimitPerUser
        self.voiceStatus = voiceStatus
        self.voiceStartTime = voiceStartTime
    }

    public var requiresForumTag: Bool {
        flags & (1 << 4) != 0
    }

    public var isOfficialSystemDirectMessage: Bool {
        kind == .directMessage && recipients.contains(where: \.isSystem)
    }

    private enum CodingKeys: String, CodingKey {
        case id, guildID, name, hasExplicitName, iconURL, ownerID, topic, kind, category, categoryID, position, categoryPosition
        case isAgeRestricted, blockedUserWarningDismissed
        case unreadCount, mentionCount, isMuted, recipients, permissionOverwrites, memberListID, lastMessageID, lastPinTimestamp
        case flags, availableTags, defaultReaction, defaultSortOrder, defaultForumLayout
        case defaultTagMatch, defaultAutoArchiveDuration, defaultThreadRateLimitPerUser
        case rateLimitPerUser
        case voiceStatus, voiceStartTime
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(ChannelID.self, forKey: .id)
        guildID = try values.decodeIfPresent(GuildID.self, forKey: .guildID)
        name = try values.decode(String.self, forKey: .name)
        hasExplicitName = try values.decodeIfPresent(Bool.self, forKey: .hasExplicitName) ?? true
        iconURL = try values.decodeIfPresent(URL.self, forKey: .iconURL)
        ownerID = try values.decodeIfPresent(UserID.self, forKey: .ownerID)
        topic = try values.decodeIfPresent(String.self, forKey: .topic)
        kind = try values.decodeIfPresent(ChannelKindValue.self, forKey: .kind) ?? .text
        category = try values.decodeIfPresent(String.self, forKey: .category)
        categoryID = try values.decodeIfPresent(ChannelID.self, forKey: .categoryID)
        position = try values.decodeIfPresent(Int.self, forKey: .position) ?? 0
        categoryPosition = try values.decodeIfPresent(Int.self, forKey: .categoryPosition) ?? 0
        unreadCount = try values.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
        mentionCount = try values.decodeIfPresent(Int.self, forKey: .mentionCount) ?? 0
        isMuted = try values.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isAgeRestricted = try values.decodeIfPresent(Bool.self, forKey: .isAgeRestricted) ?? false
        recipients = try values.decodeIfPresent([User].self, forKey: .recipients) ?? []
        blockedUserWarningDismissed = try values.decodeIfPresent(Bool.self, forKey: .blockedUserWarningDismissed) ?? false
        permissionOverwrites = try values.decodeIfPresent(
            [ChannelPermissionOverwrite].self, forKey: .permissionOverwrites
        )
        memberListID = try values.decodeIfPresent(String.self, forKey: .memberListID)
        lastMessageID = try values.decodeIfPresent(MessageID.self, forKey: .lastMessageID)
        lastPinTimestamp = try values.decodeIfPresent(Date.self, forKey: .lastPinTimestamp)
        flags = try values.decodeIfPresent(UInt64.self, forKey: .flags) ?? 0
        availableTags = try values.decodeIfPresent([ForumTag].self, forKey: .availableTags) ?? []
        defaultReaction = try values.decodeIfPresent(
            ForumDefaultReaction.self, forKey: .defaultReaction
        )
        defaultSortOrder = try values.decodeIfPresent(
            ForumSortOrder.self, forKey: .defaultSortOrder)
        defaultForumLayout =
            try values.decodeIfPresent(
                ForumLayout.self, forKey: .defaultForumLayout
            ) ?? .defaultLayout
        defaultTagMatch =
            try values.decodeIfPresent(
                ForumTagMatch.self, forKey: .defaultTagMatch
            ) ?? .matchSome
        defaultAutoArchiveDuration = try values.decodeIfPresent(
            Int.self, forKey: .defaultAutoArchiveDuration
        )
        defaultThreadRateLimitPerUser = try values.decodeIfPresent(
            Int.self, forKey: .defaultThreadRateLimitPerUser
        )
        rateLimitPerUser = try values.decodeIfPresent(Int.self, forKey: .rateLimitPerUser) ?? 0
        voiceStatus = try values.decodeIfPresent(String.self, forKey: .voiceStatus)
        voiceStartTime = try values.decodeIfPresent(Date.self, forKey: .voiceStartTime)
    }
}

public struct ForumPost: Identifiable, Codable, Hashable, Sendable {
    private final class StoredMessage: Codable, Hashable, Sendable {
        let value: Message

        init(_ value: Message) { self.value = value }
        init(from decoder: any Decoder) throws { value = try Message(from: decoder) }
        func encode(to encoder: any Encoder) throws { try value.encode(to: encoder) }
        static func == (lhs: StoredMessage, rhs: StoredMessage) -> Bool { lhs.value == rhs.value }
        func hash(into hasher: inout Hasher) { value.hash(into: &hasher) }
    }

    public var id: ChannelID { thread.id }
    public var thread: MessageThreadSummary
    public var owner: User?
    private var storedFirstMessage: StoredMessage?
    private var storedMostRecentMessage: StoredMessage?
    public var isUnread: Bool
    /// Whether Discord has answered for the starter, so a missing
    /// `firstMessage` means it was deleted rather than not yet loaded.
    public var isFirstMessageLoaded = false

    // Most bootstrap thread entries have no messages. Immutable boxes keep
    // absent messages compact and preserve independent mutation after a copy.
    public var firstMessage: Message? {
        get { storedFirstMessage?.value }
        set { storedFirstMessage = newValue.map(StoredMessage.init) }
    }

    public var mostRecentMessage: Message? {
        get { storedMostRecentMessage?.value }
        set { storedMostRecentMessage = newValue.map(StoredMessage.init) }
    }

    private enum CodingKeys: String, CodingKey {
        case thread, owner, isUnread
        case storedFirstMessage = "firstMessage"
        case storedMostRecentMessage = "mostRecentMessage"
    }

    public init(
        thread: MessageThreadSummary,
        owner: User? = nil,
        firstMessage: Message? = nil,
        mostRecentMessage: Message? = nil,
        isUnread: Bool = false
    ) {
        self.thread = thread
        self.owner = owner
        storedFirstMessage = firstMessage.map(StoredMessage.init)
        storedMostRecentMessage = mostRecentMessage.map(StoredMessage.init)
        self.isUnread = isUnread
    }

    public var replyCount: Int {
        max(0, thread.messageCount - 1)
    }

    public var reactionCount: Int {
        firstMessage?.reactions.reduce(0) { $0 + $1.count } ?? 0
    }

    public var createdAt: Date {
        thread.createdAt ?? thread.id.createdAt
    }

    public var lastActivityAt: Date {
        mostRecentMessage?.timestamp
            ?? thread.lastMessageID?.createdAt
            ?? thread.archiveTimestamp
            ?? createdAt
    }
}

public enum ForumPostScope: Hashable, Sendable {
    case active
    case search(String)
}

public struct ForumPostQuery: Hashable, Sendable {
    public var scope: ForumPostScope
    public var sortOrder: ForumSortOrder
    public var selectedTagIDs: Set<ForumTagID>
    public var tagMatch: ForumTagMatch
    /// Await the server page and propagate failures instead of presenting a partial cache.
    public var requiresFreshPage: Bool
    public var offset: Int
    public var limit: Int

    public init(
        scope: ForumPostScope = .active,
        sortOrder: ForumSortOrder = .latestActivity,
        selectedTagIDs: Set<ForumTagID> = [],
        tagMatch: ForumTagMatch = .matchSome,
        offset: Int = 0,
        limit: Int = 10,
        requiresFreshPage: Bool = false
    ) {
        self.scope = scope
        self.sortOrder = sortOrder
        self.selectedTagIDs = selectedTagIDs
        self.tagMatch = tagMatch
        self.requiresFreshPage = requiresFreshPage
        self.offset = max(0, offset)
        self.limit = max(1, limit)
    }
}

public enum ForumPostQueryPolicy {
    public static func matchesTags(
        _ post: ForumPost,
        selectedTagIDs: Set<ForumTagID>,
        tagMatch: ForumTagMatch
    ) -> Bool {
        guard !selectedTagIDs.isEmpty else { return true }
        let appliedTagIDs = Set(post.thread.appliedTagIDs)
        return switch tagMatch {
        case .matchSome:
            !appliedTagIDs.isDisjoint(with: selectedTagIDs)
        case .matchAll:
            appliedTagIDs.isSuperset(of: selectedTagIDs)
        }
    }

    public static func areInDisplayOrder(
        _ lhs: ForumPost,
        _ rhs: ForumPost,
        sortOrder: ForumSortOrder
    ) -> Bool {
        if lhs.thread.isPinned != rhs.thread.isPinned {
            return lhs.thread.isPinned
        }
        let lhsDate = sortOrder == .latestActivity ? lhs.lastActivityAt : lhs.createdAt
        let rhsDate = sortOrder == .latestActivity ? rhs.lastActivityAt : rhs.createdAt
        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }
        return lhs.id > rhs.id
    }

    public static func filteredAndSorted(
        _ posts: [ForumPost],
        selectedTagIDs: Set<ForumTagID>,
        tagMatch: ForumTagMatch,
        sortOrder: ForumSortOrder
    ) -> [ForumPost] {
        posts
            .filter {
                matchesTags(
                    $0,
                    selectedTagIDs: selectedTagIDs,
                    tagMatch: tagMatch
                )
            }
            .sorted {
                areInDisplayOrder($0, $1, sortOrder: sortOrder)
            }
    }
}

public struct ForumPostPage: Equatable, Sendable {
    public var posts: [ForumPost]
    public var hasMore: Bool
    public var nextOffset: Int?
    /// Discord's `total_results` for the query, when reported.
    public var totalResults: Int?
    /// Records Discord returned archived that were deleted or reopened before
    /// the page was delivered. They no longer occupy Discord's offsets.
    public var departedCount: Int

    public init(
        posts: [ForumPost], hasMore: Bool, nextOffset: Int?, totalResults: Int? = nil, departedCount: Int = 0
    ) {
        self.posts = posts
        self.hasMore = hasMore
        self.nextOffset = nextOffset
        self.totalResults = totalResults
        self.departedCount = departedCount
    }
}

/// One thread-browser request for a text or announcement channel. Active
/// threads come from local state; Discord serves archived pages and name search.
public struct ThreadBrowserQuery: Hashable, Sendable {
    public enum Scope: Hashable, Sendable {
        /// Archived threads, newest activity first, from a raw-record offset.
        case archived(offset: Int)
        /// Active and archived threads whose names match, as one page.
        case search(String)
    }

    public static let pageSize = 25

    public var scope: Scope
    public var selectedTagIDs: Set<ForumTagID>
    public var tagMatch: ForumTagMatch

    public init(
        scope: Scope = .archived(offset: 0),
        selectedTagIDs: Set<ForumTagID> = [],
        tagMatch: ForumTagMatch = .matchSome
    ) {
        self.scope = scope
        self.selectedTagIDs = selectedTagIDs
        self.tagMatch = tagMatch
    }
}

/// The surface that joins or leaves a thread, reported as Discord's
/// `location` analytics value.
public enum ThreadMembershipLocation: String, Hashable, Sendable {
    /// Channel-list and forum-card context menus.
    case contextMenu = "Context Menu"
    /// The side-pane thread menu.
    case sidePaneMenu = "Sidebar Overflow"
    /// The full-view thread menu.
    case fullViewMenu = "Toolbar Overflow"
    /// The forum post header Follow toggle.
    case forumToolbar = "Forum Toolbar"
    /// Mark Unread in a thread the account has not joined.
    case markUnread = "Mark Unread"
}

public struct ForumPostAttachment: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var url: URL
    public var filename: String
    public var description: String
    public var isSpoiler: Bool
    private var filenameBeforeAnonymising: String?
    private var hasChosenFilenamePrivacy = false

    public var isFilenameAnonymised: Bool { filenameBeforeAnonymising != nil }

    public mutating func setFilenameAnonymised(_ enabled: Bool) {
        hasChosenFilenamePrivacy = true
        if enabled {
            guard filenameBeforeAnonymising == nil else { return }
            filenameBeforeAnonymising = filename
            filename = UploadFilename.anonymised(filename)
        } else if let original = filenameBeforeAnonymising {
            filename = original
            filenameBeforeAnonymising = nil
        }
    }

    public func applyingFilenamePrivacy(_ enabled: Bool) -> Self {
        guard enabled, !hasChosenFilenamePrivacy else { return self }
        var attachment = self
        attachment.setFilenameAnonymised(true)
        return attachment
    }

    public mutating func rename(_ name: String) {
        setFilenameAnonymised(false)
        filename = name
    }

    public init(
        id: UUID = UUID(),
        url: URL,
        filename: String? = nil,
        description: String = "",
        isSpoiler: Bool = false
    ) {
        self.id = id
        self.url = url
        self.filename = filename ?? url.lastPathComponent
        self.description = description
        self.isSpoiler = isSpoiler
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.url == rhs.url
            && lhs.filename == rhs.filename
            && lhs.description == rhs.description
            && lhs.isSpoiler == rhs.isSpoiler
            && lhs.filenameBeforeAnonymising == rhs.filenameBeforeAnonymising
            && lhs.hasChosenFilenamePrivacy == rhs.hasChosenFilenamePrivacy
    }
}

public struct CreateForumPostDraft: Equatable, Sendable {
    public var channelID: ChannelID
    public var title: String
    public var content: String
    public var attachments: [ForumPostAttachment]
    public var appliedTagIDs: [ForumTagID]
    public var autoArchiveDuration: Int

    public init(
        channelID: ChannelID,
        title: String,
        content: String,
        attachments: [ForumPostAttachment] = [],
        appliedTagIDs: [ForumTagID] = [],
        autoArchiveDuration: Int = 4_320
    ) {
        self.channelID = channelID
        self.title = title
        self.content = content
        self.attachments = attachments
        self.appliedTagIDs = appliedTagIDs
        self.autoArchiveDuration = autoArchiveDuration
    }
}

/// A thread started in a text or announcement channel, either on its own or
/// from an existing message there. Its first message is sent separately once
/// Discord creates it.
public struct CreateThreadDraft: Equatable, Sendable {
    public var channelID: ChannelID
    public var name: String
    public var isPrivate: Bool
    public var autoArchiveDuration: Int
    /// The parent-channel message the thread starts from. The thread takes
    /// the message's ID; message threads are always public.
    public var starterMessageID: MessageID?
    /// Reported as the request location: the Threads browser's create button
    /// differs from the composer's Plus Button.
    public var isFromThreadBrowser: Bool

    public init(
        channelID: ChannelID,
        name: String,
        isPrivate: Bool = false,
        autoArchiveDuration: Int = 4_320,
        starterMessageID: MessageID? = nil,
        isFromThreadBrowser: Bool = false
    ) {
        self.channelID = channelID
        self.name = name
        self.isPrivate = isPrivate
        self.autoArchiveDuration = autoArchiveDuration
        self.starterMessageID = starterMessageID
        self.isFromThreadBrowser = isFromThreadBrowser
    }

    /// Starting from `message` with the parent's default inactivity period.
    /// A blank name uses the first-party default derived from the message.
    public static func startingFrom(
        _ message: Message,
        in parent: Channel,
        name: String = ""
    ) -> Self {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            channelID: parent.id,
            name: trimmed.isEmpty ? ThreadNamePolicy.defaultName(for: message) : trimmed,
            autoArchiveDuration: parent.defaultAutoArchiveDuration ?? 4_320,
            starterMessageID: message.id
        )
    }
}

/// One thread or forum-post change. Changes other than archiving first
/// unarchive an archived thread, which stays open afterwards.
public enum ForumPostMutation: Equatable, Sendable {
    /// Renames the thread; see `ThreadNamePolicy`.
    case name(String)
    case tags([ForumTagID])
    case archived(Bool)
    case locked(Bool)
    case pinned(Bool)
}
