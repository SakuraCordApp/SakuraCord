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
        /// When this user started typing; refreshes keep their place.
        var arrival: UInt64
    }

    @ObservationIgnored private var entries: [Key: Entry] = [:]
    @ObservationIgnored private var expiryTasks: [Key: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextArrival: UInt64 = 0
    @ObservationIgnored private let expiry: Duration = .seconds(10)

    private subscript(channelID: ChannelID) -> [Entry] {
        access(keyPath: \.[channelID])
        return entries.filter { $0.key.channelID == channelID }.map(\.value)
    }

    func receive(channelID: ChannelID, user: User, currentUserID: UserID?) {
        guard user.id != currentUserID else { return }
        let key = Key(channelID: channelID, userID: user.id)
        let generation = (entries[key]?.generation ?? 0) &+ 1
        let arrival = entries[key]?.arrival ?? {
            nextArrival &+= 1
            return nextArrival
        }()
        withMutation(keyPath: \.[channelID]) {
            entries[key] = Entry(user: user, generation: generation, arrival: arrival)
        }
        expiryTasks[key]?.cancel()
        let expiry = expiry
        expiryTasks[key] = Task { [weak self] in
            do { try await Task.sleep(for: expiry) } catch { return }
            self?.expire(key, generation: generation)
        }
    }

    func clear(userID: UserID, in channelID: ChannelID) {
        let key = Key(channelID: channelID, userID: userID)
        guard entries[key] != nil else { return }
        withMutation(keyPath: \.[channelID]) {
            entries[key] = nil
        }
        expiryTasks.removeValue(forKey: key)?.cancel()
    }

    func clear(channelID: ChannelID) {
        let keys = entries.keys.filter { $0.channelID == channelID }
        guard !keys.isEmpty else { return }
        withMutation(keyPath: \.[channelID]) {
            for key in keys {
                entries[key] = nil
                expiryTasks.removeValue(forKey: key)?.cancel()
            }
        }
    }

    func clearAll() {
        for channelID in Set(entries.keys.map(\.channelID)) {
            clear(channelID: channelID)
        }
    }

    func users(in channelID: ChannelID) -> [User] {
        self[channelID]
            .map(\.user)
            .sorted {
                let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
    }

    /// The channel's typists, most recent to start first.
    func usersNewestFirst(in channelID: ChannelID) -> [User] {
        self[channelID]
            .sorted { $0.arrival > $1.arrival }
            .map(\.user)
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

    private func expire(_ key: Key, generation: UInt64) {
        guard entries[key]?.generation == generation else { return }
        clear(userID: key.userID, in: key.channelID)
    }
}
