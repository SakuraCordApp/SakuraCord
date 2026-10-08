import Foundation
import SakuraCordModels

/// A large synthetic friends list for offline performance measurement.
public extension MockChatProvider {
    internal static func performanceRelationships(friendCount: Int) -> (
        relationships: [Relationship], presences: [UserID: UserPresence]
    ) {
        let syllables = ["ka", "ri", "no", "sa", "mi", "to", "lu", "ve", "zo", "an", "el", "or", "yu", "pa", "qi"]
        let statuses: [PresenceStatus] = [.online, .idle, .dnd, .offline, .offline]
        let avatars = ["avatar-maya", "avatar-theo", "avatar-juniper", "avatar-rowan", "avatar-nova", nil]
        var relationships: [Relationship] = []
        var presences: [UserID: UserPresence] = [:]
        let pendingCount = max(friendCount / 10, 1)
        for index in 0 ..< friendCount + pendingCount * 2 {
            let id = UserID(rawValue: 10_000_000 + UInt64(index))
            let name = (0 ..< 2 + index % 3).map { syllables[(index * 7 + $0 * 5) % syllables.count] }.joined()
            let user = User(
                id: id, username: "\(name).\(index)", displayName: name.capitalized + (index.isMultiple(of: 11) ? " ✿" : ""),
                avatarURL: avatars[index % avatars.count].flatMap(MockChatFixture.demoAsset)
            )
            let type: RelationshipType = index < friendCount ? .friend
                : index < friendCount + pendingCount ? .incomingRequest : .outgoingRequest
            relationships.append(Relationship(
                id: id, type: type, user: user, nickname: index.isMultiple(of: 17) ? "Nick \(name)" : nil,
                since: type == .friend ? Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 3_600) : nil,
                note: type != .friend && index.isMultiple(of: 2) ? "Hello! We met in the Sakura community 🌸" : nil
            ))
            let status = statuses[index % statuses.count]
            presences[id] = UserPresence(
                status: status,
                customStatus: status != .offline && index.isMultiple(of: 3) ? "Working on build \(index) 🌸" : nil,
                activityText: status != .offline && index.isMultiple(of: 4) ? "Playing Fixture Quest \(index % 9)" : nil,
                isListeningToMusic: false,
                isMobileOnly: index.isMultiple(of: 7)
            )
        }
        return (relationships, presences)
    }

    /// Emits partial presence updates at a steady rate, as a busy account does.
    func startRelationshipPresenceChurn(updatesPerSecond: Int) {
        presenceChurnTask?.cancel()
        let friends = snapshot.relationships.filter { $0.type == .friend }.map(\.id)
        guard !friends.isEmpty, updatesPerSecond > 0 else { return }
        presenceChurnTask = Task { [weak self] in
            var step = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1_000 / updatesPerSecond))
                guard let self else { return }
                step += 1
                let id = friends[(step * 37) % friends.count]
                let status: PresenceStatus = [.online, .idle, .dnd, .offline][step % 4]
                await self.emit(.relationshipPresencesChanged(
                    [id: UserPresence(status: status, customStatus: step.isMultiple(of: 2) ? "Update \(step)" : nil)],
                    isComplete: false
                ))
            }
        }
    }

    func stopRelationshipPresenceChurn() {
        presenceChurnTask?.cancel()
        presenceChurnTask = nil
    }
}
