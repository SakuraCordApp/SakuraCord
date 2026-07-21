import Foundation
import Observation
import SakuraCordModels

@MainActor
@Observable
final class TypingStateModel {
    private struct Key: Hashable {
        var channelID: ChannelID
        var userID: UserID
    }

    private struct Entry {
        var user: User
        var generation: UInt64
    }

    private(set) var revision: UInt64 = 0
    @ObservationIgnored private var entries: [Key: Entry] = [:]
    @ObservationIgnored private var expiryTasks: [Key: Task<Void, Never>] = [:]
    @ObservationIgnored private let expiry: Duration

    init(expiry: Duration = .seconds(10)) {
        self.expiry = expiry
    }

    func receive(channelID: ChannelID, user: User, currentUserID: UserID?) {
        guard user.id != currentUserID else { return }
        let key = Key(channelID: channelID, userID: user.id)
        let generation = (entries[key]?.generation ?? 0) &+ 1
        entries[key] = Entry(user: user, generation: generation)
        expiryTasks[key]?.cancel()
        let expiry = expiry
        expiryTasks[key] = Task { [weak self] in
            do { try await Task.sleep(for: expiry) }
            catch { return }
            self?.expire(key, generation: generation)
        }
        revision &+= 1
    }

    func clear(userID: UserID, in channelID: ChannelID) {
        let key = Key(channelID: channelID, userID: userID)
        guard entries.removeValue(forKey: key) != nil else { return }
        expiryTasks.removeValue(forKey: key)?.cancel()
        revision &+= 1
    }

    func clear(channelID: ChannelID) {
        let keys = entries.keys.filter { $0.channelID == channelID }
        guard !keys.isEmpty else { return }
        for key in keys {
            entries[key] = nil
            expiryTasks.removeValue(forKey: key)?.cancel()
        }
        revision &+= 1
    }

    func clearAll() {
        guard !entries.isEmpty || !expiryTasks.isEmpty else { return }
        for task in expiryTasks.values {
            task.cancel()
        }
        expiryTasks.removeAll()
        entries.removeAll()
        revision &+= 1
    }

    func users(in channelID: ChannelID) -> [User] {
        _ = revision
        return entries
            .filter { $0.key.channelID == channelID }
            .map(\.value.user)
            .sorted {
                let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
    }

    func presentation(in channelID: ChannelID) -> String? {
        let users = users(in: channelID)
        switch users.count {
        case 0: return nil
        case 1: return "\(users[0].displayName) is typing…"
        case 2: return "\(users[0].displayName) and \(users[1].displayName) are typing…"
        default:
            return "\(users[0].displayName), \(users[1].displayName), and \(users.count - 2) other\(users.count == 3 ? "" : "s") are typing…"
        }
    }

    #if DEBUG
        func expiryGenerationForTesting(channelID: ChannelID, userID: UserID) -> UInt64? {
            entries[Key(channelID: channelID, userID: userID)]?.generation
        }

        func applyExpiryForTesting(channelID: ChannelID, userID: UserID, generation: UInt64) {
            expire(Key(channelID: channelID, userID: userID), generation: generation)
        }
    #endif

    private func expire(_ key: Key, generation: UInt64) {
        guard entries[key]?.generation == generation else { return }
        entries[key] = nil
        expiryTasks[key] = nil
        revision &+= 1
    }
}
