import Foundation
import SakuraCordModels

public extension MockChatProvider {
    func acknowledge(
        channelID: ChannelID,
        messageID: MessageID,
        token: String?
    ) async throws -> ReadAcknowledgementResponse {
        try await acknowledge(
            channelID: channelID,
            messageID: messageID,
            token: token,
            manual: false,
            mentionCount: nil,
            flags: nil,
            lastViewed: nil
        )
    }

    func acknowledge(
        channelID: ChannelID,
        messageID: MessageID,
        token: String?,
        manual: Bool,
        mentionCount: Int?,
        flags: UInt64?,
        lastViewed: Int?
    ) async throws -> ReadAcknowledgementResponse {
        acknowledgementRequests.append(
            AcknowledgementRequest(
                channelID: channelID,
                messageID: messageID,
                token: token,
                manual: manual,
                mentionCount: mentionCount,
                flags: flags,
                lastViewed: lastViewed
            )
        )
        let version = (snapshot.readStates.compactMap(\.version).max() ?? 0) + 1
        let existing = snapshot.readStates.first { $0.channelID == channelID }
        let latestMessageID = snapshot.channels.first { $0.id == channelID }?.lastMessageID
        let acknowledgedMessageID = messageID
        let clearsKnownMessages = latestMessageID.map { messageID >= $0 } ?? true
        let updated = ChannelReadState(
            channelID: channelID,
            lastAcknowledgedMessageID: acknowledgedMessageID,
            mentionCount: mentionCount ?? (clearsKnownMessages ? 0 : existing?.mentionCount ?? 0),
            isManual: manual,
            flags: flags ?? existing?.flags,
            lastViewed: lastViewed ?? existing?.lastViewed,
            version: version
        )
        if let index = snapshot.readStates.firstIndex(where: { $0.channelID == channelID }) {
            snapshot.readStates[index] = updated
        } else {
            snapshot.readStates.append(updated)
        }
        continuation?.yield(.readStateChanged(updated))
        return ReadAcknowledgementResponse(token: "mock-ack-token")
    }

    func updateChannelNotificationLevel(
        guildID: GuildID?,
        channelID: ChannelID,
        level: MessageNotificationLevel
    ) async throws {
        channelNotificationRequests.append(
            ChannelNotificationRequest(
                guildID: guildID,
                channelID: channelID,
                level: level
            )
        )
    }

    func acknowledgeBulk(
        _ readStates: [BulkReadStateAcknowledgement]
    ) async throws {
        bulkAcknowledgementRequests.append(readStates)
        if failsBulkAcknowledgement {
            throw ChatProviderError.transport(status: 500, requestID: nil)
        }
    }

    func failBulkAcknowledgement() {
        failsBulkAcknowledgement = true
    }

    func updateGuildNotificationLevel(
        guildID: GuildID,
        level: MessageNotificationLevel
    ) async throws {
        guildNotificationRequests.append(
            GuildNotificationRequest(guildID: guildID, level: level)
        )
    }

    func updateGuildMute(
        guildID: GuildID,
        isMuted: Bool,
        until: Date?
    ) async throws {
        guildNotificationRequests.append(
            GuildNotificationRequest(
                guildID: guildID,
                isMuted: isMuted,
                muteEndTime: until
            )
        )
    }

    func updateGuildNotificationToggle(
        guildID: GuildID,
        toggle: GuildNotificationToggle,
        isEnabled: Bool
    ) async throws {
        guildNotificationRequests.append(
            GuildNotificationRequest(
                guildID: guildID,
                toggle: toggle,
                isEnabled: isEnabled
            )
        )
    }

    func updateChannelMute(
        guildID: GuildID?,
        channelID: ChannelID,
        isMuted: Bool,
        until: Date?
    ) async throws {
        channelNotificationRequests.append(
            ChannelNotificationRequest(
                guildID: guildID,
                channelID: channelID,
                isMuted: isMuted,
                muteEndTime: until
            )
        )
    }

    func updateDirectMessagePin(channelID: ChannelID, flags: UInt64) async throws {
        var settings = snapshot.notificationSettings.first { $0.guildID == nil }
            ?? GuildNotificationSettings(guildID: nil, messageNotifications: .inherit)
        var override = settings.channelOverrides.first { $0.channelID == channelID }
            ?? ChannelNotificationOverride(channelID: channelID)
        override.flags = flags
        settings.channelOverrides.removeAll { $0.channelID == channelID }
        settings.channelOverrides.append(override)
        snapshot.notificationSettings.removeAll { $0.guildID == nil }
        snapshot.notificationSettings.append(settings)
        continuation?.yield(.notificationSettingsChanged(settings))
    }

    func updateCategoryNotificationLevel(
        guildID: GuildID,
        categoryID: ChannelID,
        level: MessageNotificationLevel
    ) async throws {
        categoryNotificationRequests.append(
            CategoryNotificationRequest(
                guildID: guildID,
                categoryID: categoryID,
                level: level
            )
        )
    }

    func updateCategoryMute(
        guildID: GuildID,
        categoryID: ChannelID,
        isMuted: Bool,
        until: Date?
    ) async throws {
        categoryNotificationRequests.append(
            CategoryNotificationRequest(
                guildID: guildID,
                categoryID: categoryID,
                isMuted: isMuted,
                muteEndTime: until
            )
        )
    }

    func updateCategoryCollapsed(
        guildID: GuildID,
        categoryID: ChannelID,
        isCollapsed: Bool
    ) async throws {
        categoryNotificationRequests.append(
            CategoryNotificationRequest(
                guildID: guildID,
                categoryID: categoryID,
                isCollapsed: isCollapsed
            )
        )
        if categoryCollapsedUpdatesAreSuspended {
            await withCheckedContinuation { continuation in
                categoryCollapsedUpdateWaiters.append(continuation)
            }
        }
    }

    func suspendCategoryCollapsedUpdates() {
        categoryCollapsedUpdatesAreSuspended = true
    }

    func resumeCategoryCollapsedUpdates() {
        categoryCollapsedUpdatesAreSuspended = false
        let waiters = categoryCollapsedUpdateWaiters
        categoryCollapsedUpdateWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func inboxMentions(_ query: InboxMentionQuery, before: MessageID?) async throws -> InboxMentionPage {
        let channels = Dictionary(uniqueKeysWithValues: snapshot.channels.map { ($0.id, $0) })
        let matches = messagesByChannel.values.flatMap { $0 }.filter { message in
            guard !dismissedInboxMentions.contains(message.id),
                  before.map({ message.id < $0 }) ?? true else { return false }
            let guildID = message.guildID ?? channels[message.channelID]?.guildID
            guard query.guildID == nil || guildID == query.guildID else { return false }
            let direct = message.mentionedUsers.contains { $0.id == currentUser.id }
            let everyone = query.includesEveryone && message.mentionsEveryone
            let member = guildID.flatMap { membersByGuild[$0]?.first { $0.id == currentUser.id } }
            let roleIDs = Set(member?.roles.map(\.id) ?? [])
            let role = query.includesRoles && !message.flags.contains(.failedToMentionRoles)
                && !roleIDs.isDisjoint(with: message.mentionedRoleIDs)
            return direct || everyone || role
        }.sorted { $0.id > $1.id }
        let page = Array(matches.prefix(25))
        return InboxMentionPage(messages: page, nextBefore: page.last?.id, hasMore: page.count == 25)
    }

    func dismissInboxMention(_ messageID: MessageID) async throws {
        dismissedInboxMentions.insert(messageID)
        continuation?.yield(.inboxMentionDismissed(messageID))
    }

    func inboxSettings() async -> InboxSettings { inboxSettingsValue }

    func updateInboxTab(_ tab: InboxTab) async throws {
        inboxSettingsValue.tab = tab
        continuation?.yield(.inboxSettingsChanged(inboxSettingsValue))
    }

    func updateInboxCollapsed(_ collapsed: Bool, channelID: ChannelID, guildID: GuildID?) async throws {
        if collapsed {
            inboxSettingsValue.collapsedChannelIDs.insert(channelID)
        } else {
            inboxSettingsValue.collapsedChannelIDs.remove(channelID)
        }
        continuation?.yield(.inboxSettingsChanged(inboxSettingsValue))
    }

    struct AcknowledgementRequest: Equatable, Sendable {
        public var channelID: ChannelID
        public var messageID: MessageID
        public var token: String?
        public var manual: Bool
        public var mentionCount: Int?
        public var flags: UInt64?
        public var lastViewed: Int?
    }

    struct GuildNotificationRequest: Equatable, Sendable {
        public var guildID: GuildID
        public var level: MessageNotificationLevel?
        public var isMuted: Bool?
        public var muteEndTime: Date?
        public var toggle: GuildNotificationToggle?
        public var isEnabled: Bool?
    }

    struct ChannelNotificationRequest: Equatable, Sendable {
        public var guildID: GuildID?
        public var channelID: ChannelID
        public var level: MessageNotificationLevel?
        public var isMuted: Bool?
        public var muteEndTime: Date?
    }

    struct CategoryNotificationRequest: Equatable, Sendable {
        public var guildID: GuildID
        public var categoryID: ChannelID
        public var level: MessageNotificationLevel?
        public var isMuted: Bool?
        public var muteEndTime: Date?
        public var isCollapsed: Bool?
    }
}
