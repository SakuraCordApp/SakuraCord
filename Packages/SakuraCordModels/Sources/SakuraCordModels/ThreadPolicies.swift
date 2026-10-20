import Foundation

/// Thread and forum-post names: Discord accepts 1–100 characters.
public enum ThreadNamePolicy {
    public static let maximumLength = 100
    /// Fallback when a starter message yields no usable text.
    public static let fallbackName = "Thread"

    /// The trimmed name, or nil when it is empty or too long.
    public static func validatedName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1 ... maximumLength).contains(trimmed.count) ? trimmed : nil
    }

    /// The first-party default name for a thread started from `message`: its
    /// first embed title (40 characters), else its poll question (80), else
    /// the first readable line of its content cut at a word boundary within
    /// 40 characters. Lengths are UTF-16 units, as in the official client;
    /// truncation never splits a character.
    public static func defaultName(
        for message: Message,
        channelNames: [ChannelID: String] = [:],
        roleNames: [RoleID: String] = [:]
    ) -> String {
        if let title = message.embeds.first?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty
        {
            return truncated(title, limit: 40)
        }
        if let question = message.poll?.question.trimmingCharacters(in: .whitespacesAndNewlines),
           !question.isEmpty
        {
            return truncated(question, limit: 80)
        }
        var line = readableContent(message, channelNames: channelNames, roleNames: roleNames)
        if let newline = line.unicodeScalars.firstIndex(of: "\n") {
            line = String(line.unicodeScalars[..<newline])
        }
        line = line.replacing("\r", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        line = line.replacing(#/^[ #-]+/#, with: "")
        var tokens: [Substring] = []
        var remainder = Substring(line)
        while let separator = remainder.firstMatch(of: #/(?:\s|[!@#$%^&*()_\-+={}\[\]:";'<>?,.\/])+/#) {
            tokens.append(remainder[..<separator.range.lowerBound])
            tokens.append(remainder[separator.range])
            remainder = remainder[separator.range.upperBound...]
        }
        tokens.append(remainder)
        var name = String(tokens[0])
        for token in tokens.dropFirst() {
            guard name.utf16.count + token.utf16.count <= 40 else { break }
            name += token
        }
        // Submitted names are trimmed; trim here so the suggestion matches.
        let result = truncated(name, limit: 40).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? fallbackName : result
    }

    /// Discord's unparse step: stored mention and emoji tokens become the
    /// text a reader sees, and spoilers stay concealed as `<spoiler>`.
    /// Unknown channels and roles keep their raw token.
    private static func readableContent(
        _ message: Message,
        channelNames: [ChannelID: String],
        roleNames: [RoleID: String]
    ) -> String {
        let usersByID = Dictionary(
            message.mentionedUsers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        return message.content
            .replacing(#/\|\|[\s\S]+?\|\|/#, with: "<spoiler>")
            .replacing(#/<a?:(\w+):\d+>/#) { ":\($0.1):" }
            .replacing(#/<@!?(\d+)>/#) { match in
                UInt64(match.1).flatMap { usersByID[UserID(rawValue: $0)] }
                    .map { "@\($0.username)" } ?? String(match.0)
            }
            .replacing(#/<@&(\d+)>/#) { match in
                UInt64(match.1).flatMap { roleNames[RoleID(rawValue: $0)] }
                    .map { "@\($0)" } ?? String(match.0)
            }
            .replacing(#/<#(\d+)>/#) { match in
                UInt64(match.1).flatMap { channelNames[ChannelID(rawValue: $0)] }
                    .map { "#\($0)" } ?? String(match.0)
            }
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        var result = ""
        for character in text {
            guard result.utf16.count + String(character).utf16.count <= limit else { break }
            result.append(character)
        }
        return result + "..."
    }
}

/// Which threads the current user may create in a parent channel.
public struct ThreadCreationPermissions: Equatable, Sendable {
    public let canCreatePublic: Bool
    public let canCreatePrivate: Bool

    public var canCreateAny: Bool { canCreatePublic || canCreatePrivate }

    public init(canCreatePublic: Bool, canCreatePrivate: Bool) {
        self.canCreatePublic = canCreatePublic
        self.canCreatePrivate = canCreatePrivate
    }
}

/// Thread actions available to the current user. Threads inherit their parent
/// channel's effective permissions; the thread's own state and ownership
/// narrow them. Menus, panes and action execution share these rules, which
/// follow first-party thread-permission module 406704.
public struct ThreadActionPolicy: Equatable, Sendable {
    public var canRead = false
    /// Manage Threads: lock/unlock, pin, delete, and edits regardless of ownership.
    public var canManage = false
    public var canRename = false
    public var canClose = false
    /// The explicit Reopen action.
    public var canReopen = false
    /// The implicit unarchive that precedes edits to an archived thread.
    public var canUnarchive = false
    public var canDelete = false
    public var canChangeMembership = false
    public var canChangeNotifications = false

    public var canLock: Bool { canManage }

    public init() {}

    public init(
        thread: MessageThreadSummary,
        currentUserID: UserID,
        parentPermissions permissions: UInt64,
        parentKind: ChannelKindValue
    ) {
        guard permissions & DiscordPermissionBits.viewChannel != 0 else { return }
        let managesThreads = permissions & DiscordPermissionBits.manageThreads != 0
        let isJoined = thread.notificationSettings != nil
        guard !thread.isPrivate || isJoined || managesThreads else { return }
        canRead = true
        canManage = managesThreads
        let ownsThread = thread.ownerID == currentUserID
        let canSend = permissions & DiscordPermissionBits.sendMessagesInThreads != 0
            && permissions & DiscordPermissionBits.sendMessages != 0
        let canEdit = managesThreads || (!thread.isLocked && ownsThread)
        canClose = canEdit
        canReopen = thread.isLocked ? managesThreads : canSend
        canUnarchive = managesThreads || !thread.isLocked
        // An archived thread is edited only after an unarchive the user may
        // perform by sending; Discord offers no edit for an archived locked thread.
        canRename = canEdit && (!thread.isArchived || (!thread.isLocked && canSend))
        // A regular thread's creator cannot delete it. Forum authors may delete
        // an empty post; deleting only its starter once replies exist is distinct.
        canDelete = managesThreads
            || (parentKind == .forum && ownsThread && thread.messageCount == 0)
        canChangeMembership = isJoined || !thread.isArchived
        canChangeNotifications = isJoined
    }

    /// Threads without a starter message (composer, thread browser). Private
    /// threads exist only in text channels.
    public static func creationPermissions(
        parentKind: ChannelKindValue,
        permissions: UInt64
    ) -> ThreadCreationPermissions {
        guard parentKind == .text || parentKind == .announcement,
              permissions & DiscordPermissionBits.viewChannel != 0
        else { return ThreadCreationPermissions(canCreatePublic: false, canCreatePrivate: false) }
        let publicThreads = DiscordPermissionBits.createPublicThreads
            | DiscordPermissionBits.readMessageHistory
        return ThreadCreationPermissions(
            canCreatePublic: permissions & publicThreads == publicThreads,
            canCreatePrivate: parentKind == .text
                && permissions & DiscordPermissionBits.createPrivateThreads != 0
        )
    }

    /// User-authored message types that can start a thread.
    public static let threadStarterMessageTypes: Set<Int> = [0, 19, 20, 23, 26, 41, 45, 47, 68]

    /// Starting a public thread from a confirmed message posted directly in
    /// `parent`. Messages inside threads or voice-channel chats never qualify,
    /// nor does a message that already has a thread.
    public static func canCreateThread(
        from message: Message,
        in parent: Channel,
        permissions: UInt64
    ) -> Bool {
        guard parent.guildID != nil, message.channelID == parent.id,
              [.text, .announcement, .forum].contains(parent.kind),
              message.outboxState == .confirmed,
              threadStarterMessageTypes.contains(message.type.rawValue),
              !message.flags.contains(.hasThread), !message.flags.contains(.ephemeral),
              message.thread == nil
        else { return false }
        let required = DiscordPermissionBits.viewChannel | (
            parent.kind == .forum
                ? DiscordPermissionBits.sendMessages
                : DiscordPermissionBits.createPublicThreads | DiscordPermissionBits.readMessageHistory
        )
        return permissions & required == required
    }

    /// Reading and searching a text or announcement channel's thread list.
    public static func canBrowseThreads(parentKind: ChannelKindValue, permissions: UInt64) -> Bool {
        let required = DiscordPermissionBits.viewChannel | DiscordPermissionBits.readMessageHistory
        return (parentKind == .text || parentKind == .announcement)
            && permissions & required == required
    }
}
