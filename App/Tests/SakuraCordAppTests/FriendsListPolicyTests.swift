@testable import SakuraCord
import SakuraCordModels
import Testing

struct FriendsListPolicyTests {
    @Test func `sections, ordering and search follow Discord's Friends projection`() {
        func user(_ id: UInt64, _ username: String, _ name: String) -> User {
            User(id: UserID(rawValue: id), username: username, displayName: name)
        }
        let relationships = [
            Relationship(id: .init(rawValue: 1), type: .friend, user: user(1, "zed", "Zed"), nickname: "Alpha"),
            Relationship(id: .init(rawValue: 2), type: .friend, user: user(2, "bea", "beta")),
            Relationship(id: .init(rawValue: 3), type: .friend, user: user(3, "cy", "Cy")),
            Relationship(id: .init(rawValue: 4), type: .incomingRequest, user: user(4, "spam", "Spam"), isSpamRequest: true),
            Relationship(id: .init(rawValue: 5), type: .incomingRequest, user: user(5, "in", "In")),
            Relationship(id: .init(rawValue: 6), type: .outgoingRequest, user: user(6, "out", "Out")),
            Relationship(id: .init(rawValue: 7), type: .blocked, user: user(7, "blk", "Blocked")),
            Relationship(id: .init(rawValue: 8), type: .friend),
        ]
        let presences: [UserID: UserPresence] = [
            .init(rawValue: 2): .init(status: .dnd), .init(rawValue: 3): .init(status: .idle),
        ]
        let rows = FriendsListPolicy.rows(relationships, presences: presences)
        // Online includes idle and DND; All intermixes offline alphabetically by nickname, then global name.
        #expect(FriendsListPolicy.groups(for: .online, rows: rows, query: "").first?.rows.map(\.name) == ["beta", "Cy"])
        #expect(FriendsListPolicy.groups(for: .all, rows: rows, query: "").first?.rows.map(\.name) == ["Alpha", "beta", "Cy"])
        #expect(FriendsListPolicy.groups(for: .pending, rows: rows, query: "").map(\.title) == ["Received — 1", "Sent — 1"])
        #expect(FriendsListPolicy.incomingRequestCount(relationships) == 1)
        #expect(FriendsListPolicy.visibleSections(relationships, presences: presences) == [.online, .all, .pending, .addFriend])
        #expect(FriendsListPolicy.initialSection(relationships) == .online)
        // Search spans username, nickname and global name, case-insensitively.
        #expect(FriendsListPolicy.groups(for: .all, rows: rows, query: "ZE").first?.rows.map(\.name) == ["Alpha"])
        #expect(FriendsListPolicy.groups(for: .all, rows: rows, query: "alp").first?.rows.map(\.name) == ["Alpha"])
    }

    @Test func `Add Friend input is parsed like Discord's request helper`() {
        #expect(FriendsListPolicy.parseUsername("  @example.name ") == .valid(username: "example.name", discriminator: nil))
        #expect(FriendsListPolicy.parseUsername("legacy#0042") == .valid(username: "legacy", discriminator: 42))
        #expect(FriendsListPolicy.parseUsername("two words") == .invalid)
        #expect(FriendsListPolicy.parseUsername("@@double") == .invalid)
        #expect(FriendsListPolicy.parseUsername("bad#12") == .invalid)
    }
}
