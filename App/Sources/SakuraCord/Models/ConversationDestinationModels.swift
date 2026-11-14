import OSLog
import SakuraCordModels
import SwiftUI

nonisolated enum ForwardPickerLayoutMetrics {
    static var width: CGFloat { InterfaceScale.metric(480) }
    static var height: CGFloat { InterfaceScale.metric(679) }
    static var iconSize: CGFloat { InterfaceScale.metric(32) }
}

nonisolated enum ConversationDestinationID: Hashable {
    case channel(ChannelID)
    case user(UserID)

    var accessibilityIdentifier: String {
        switch self {
        case .channel(let channelID): "forward-destination-channel-\(channelID)"
        case .user(let userID): "forward-destination-user-\(userID)"
        }
    }
}

nonisolated struct ConversationDestination: Identifiable, Equatable {
    // A destination appears in both the ordered corpus and search records.
    // Share its immutable payload instead of copying the largest enum case
    // into every slot in both indexes.
    indirect enum Kind: Equatable {
        case channel(Channel)
        case thread(MessageThreadSummary, parent: Channel?)
        case user(User, directMessage: Channel?)
    }

    let kind: Kind
    let guild: Guild?
    var titleOverride: String?
    var detailOverride: String?
    var unavailableReason: String?

    var id: ConversationDestinationID {
        switch kind {
        case .channel(let channel): .channel(channel.id)
        case .thread(let thread, _): .channel(thread.id)
        case .user(let user, _): .user(user.id)
        }
    }

    var resolvedChannelID: ChannelID? {
        switch kind {
        case .channel(let channel): channel.id
        case .thread(let thread, _): thread.id
        case .user(_, let directMessage): directMessage?.id
        }
    }

    var userID: UserID? {
        guard case .user(let user, _) = kind else { return nil }
        return user.id
    }

    var title: String {
        if let titleOverride { return titleOverride }
        return switch kind {
        case .channel(let channel): channel.name
        case .thread(let thread, _): thread.name
        case .user(let user, _): user.displayName
        }
    }

    var detail: String {
        if let detailOverride { return detailOverride }
        return switch kind {
        case .channel(let channel):
            channel.kind == .groupDirectMessage ? "" : guild?.name ?? "Channel"
        case .thread(_, let parent): parent?.name ?? guild?.name ?? "Thread"
        case .user(let user, _): user.tag
        }
    }

    var avatarURL: URL? {
        switch kind {
        case .channel(let channel):
            channel.kind == .groupDirectMessage ? channel.iconURL : guild?.iconURL
        case .thread: guild?.iconURL
        case .user(let user, _): user.avatarURL
        }
    }
}

nonisolated enum ConversationDestinationPermissionPolicy {
    static func canSearchChannel(
        _ channel: Channel,
        permissions: UInt64?
    ) -> Bool {
        guard AppModel.supportsForwardSearchCandidate(channel.kind) else {
            return false
        }
        guard channel.kind != .groupDirectMessage else { return true }
        guard let permissions else {
            // Discord's queryChannels path requires the resolved vocal
            // `accessPermissions` value to contain CONNECT before the row can
            // enter either raw channel category. Do not turn missing guild
            // role/member state into connect access.
            if channel.kind == .voice { return false }
            return channel.permissionOverwrites?.isEmpty != false
        }
        var required = DiscordPermissionBits.viewChannel
        if channel.kind == .voice {
            required |= DiscordPermissionBits.connect
        }
        return permissions & required == required
    }

    static func canUseChannel(
        _ channel: Channel,
        permissions: UInt64?
    ) -> Bool {
        guard AppModel.supportsForwardDestination(channel.kind) else {
            return false
        }
        guard channel.kind != .groupDirectMessage else {
            return !channel.isOfficialSystemDirectMessage
        }
        guard canSearchChannel(channel, permissions: permissions) else {
            return false
        }
        guard let permissions else {
            return channel.permissionOverwrites?.isEmpty != false
        }
        let required = DiscordPermissionBits.viewChannel
            | DiscordPermissionBits.sendMessages
        return permissions & required == required
    }

    static func canSearchThread(
        parent: Channel,
        permissions: UInt64?
    ) -> Bool {
        guard parent.kind == .text
            || parent.kind == .announcement
            || parent.kind == .forum
        else { return false }
        guard let permissions else {
            return parent.permissionOverwrites?.isEmpty != false
        }
        return permissions & DiscordPermissionBits.viewChannel != 0
    }

    static func canUseThread(
        parent: Channel,
        permissions: UInt64?
    ) -> Bool {
        guard parent.kind == .text
            || parent.kind == .announcement
            || parent.kind == .forum
        else { return false }
        guard let permissions else {
            return parent.permissionOverwrites?.isEmpty != false
        }
        let required = DiscordPermissionBits.viewChannel
            | DiscordPermissionBits.sendMessages
        return permissions & required == required
    }
}
