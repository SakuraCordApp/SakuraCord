import Foundation
import SakuraCordModels

public extension MockChatProvider {
    func editGroupDirectMessage(_ channelID: ChannelID, changes: GroupDirectMessageChanges) async throws -> Channel {
        guard let index = snapshot.channels.firstIndex(where: { $0.id == channelID && $0.kind == .groupDirectMessage }) else {
            throw ChatProviderError.invalidRequest("That demo group is unavailable.")
        }
        var channel = snapshot.channels[index]
        switch changes.name {
        case .unchanged: break
        case .clear:
            let nicknames = snapshot.relationshipNicknamesByUserID
            channel.hasExplicitName = false
            channel.name = channel.recipients.map { nicknames[$0.id] ?? $0.displayName }.joined(separator: ", ")
        case let .set(name):
            channel.hasExplicitName = true
            channel.name = name
        }
        if changes.icon.isChanged {
            if let previous = channel.iconURL, previous.isFileURL, previous.lastPathComponent.hasPrefix("demo-group-icon-") {
                try? FileManager.default.removeItem(at: previous)
            }
            channel.iconURL = nil
        }
        if case let .set(upload) = changes.icon {
            // The demo has no CDN; a temporary file stands in for the icon URL.
            let url = FileManager.default.temporaryDirectory.appending(path: "demo-group-icon-\(UUID().uuidString)")
            try upload.data.write(to: url, options: .atomic)
            channel.iconURL = url
        }
        snapshot.channels[index] = channel
        continuation?.yield(.channelsChanged(guildID: nil, channels: snapshot.channels.filter { $0.guildID == nil }))
        return channel
    }

    func leaveGroupDirectMessage(_ channelID: ChannelID, silently: Bool) async throws {
        guard snapshot.channels.contains(where: { $0.id == channelID && $0.kind == .groupDirectMessage }) else {
            throw ChatProviderError.invalidRequest("That demo group is unavailable.")
        }
        groupLeaveRequests.append((channelID, silently))
        snapshot.channels.removeAll { $0.id == channelID }
        continuation?.yield(.channelsChanged(guildID: nil, channels: snapshot.channels.filter { $0.guildID == nil }))
    }
}
