import DiscordProtocol
import Foundation
import Observation
import SakuraCordModels

nonisolated enum FriendsSection: Hashable, Sendable, CaseIterable {
    case online, all, pending, addFriend
}

/// The Friends page: section, per-section search, Add Friend form, in-flight
/// relationship actions and their confirmations. Relationship records live
/// in the bootstrap snapshot; presences arrive with their own events.
@Observable
final class FriendsState {
    /// Chosen explicitly; an empty Direct Messages selection also shows Friends.
    var isPresented = false
    /// Nil until chosen; the page then opens on Discord's initial section.
    var selectedSection: FriendsSection?
    var presences: [UserID: UserPresence] = [:]
    var searchTextBySection: [FriendsSection: String] = [:]
    var isSearchFocused = false
    var addFriendText = ""
    var addFriendError: String?
    /// The username a request was just sent to.
    var addFriendSuccess: String?
    var isSendingRequest = false
    var addFriendFocusRequest = 0
    var pendingUserIDs: Set<UserID> = []
    var actionError: String?
    var confirmation: FriendsConfirmation?
    let captcha = HumanCaptchaStore.friends()
    /// Sections whose full relationship read was requested on this connection.
    @ObservationIgnored var loadedSections: Set<FriendsSection> = []

    func reset() {
        captcha.cancel()
        isPresented = false
        selectedSection = nil
        presences = [:]
        searchTextBySection = [:]
        isSearchFocused = false
        resetAddFriendForm()
        pendingUserIDs = []
        actionError = nil
        confirmation = nil
        loadedSections = []
    }

    func resetAddFriendForm() {
        addFriendText = ""
        addFriendError = nil
        addFriendSuccess = nil
        isSendingRequest = false
    }
}

/// A destructive or consequential action awaiting the user's confirmation.
nonisolated enum FriendsConfirmation: Identifiable, Hashable, Sendable {
    case removeFriend(User)
    case block(User)
    case acceptStranger(User)

    var id: String {
        switch self {
        case .removeFriend(let user): "remove-\(user.id)"
        case .block(let user): "block-\(user.id)"
        case .acceptStranger(let user): "stranger-\(user.id)"
        }
    }
}

/// One hydrated relationship row.
nonisolated struct FriendRow: Identifiable, Hashable, Sendable {
    let relationship: Relationship
    let user: User
    let presence: UserPresence

    var id: UserID { user.id }
    /// A private friend nickname replaces the global name, which replaces the username.
    var name: String { relationship.nickname ?? user.displayName }
}

nonisolated struct FriendsListGroup: Identifiable, Hashable, Sendable {
    let title: String
    let rows: [FriendRow]
    var id: String { title }
}

// Official stable633029 FriendsStore (module595623) and the `Ah` section builder.
nonisolated enum FriendsListPolicy {
    static func rows(_ relationships: [Relationship], presences: [UserID: UserPresence]) -> [FriendRow] {
        relationships.compactMap { relationship in
            // Unhydrated identities stay in the snapshot and appear once known.
            guard let user = relationship.user else { return nil }
            return FriendRow(
                relationship: relationship, user: user,
                presence: presences[relationship.id] ?? UserPresence(status: .offline)
            )
        }
        .sorted(by: precedes)
    }

    /// Relationship type, then the lowercased effective name; ties keep a stable identity order.
    static func precedes(_ lhs: FriendRow, _ rhs: FriendRow) -> Bool {
        if lhs.relationship.type.rawValue != rhs.relationship.type.rawValue {
            return lhs.relationship.type.rawValue < rhs.relationship.type.rawValue
        }
        let lhsName = lhs.name.lowercased(), rhsName = rhs.name.lowercased()
        if lhsName != rhsName { return lhsName < rhsName }
        return lhs.user.id.rawValue < rhs.user.id.rawValue
    }

    static func isOnline(_ row: FriendRow) -> Bool {
        row.relationship.type == .friend && row.presence.status.isVisibleOnline
    }

    static func isPending(_ row: FriendRow) -> Bool {
        isVisibleIncomingRequest(row.relationship) || row.relationship.type == .outgoingRequest
    }

    static func isVisibleIncomingRequest(_ relationship: Relationship) -> Bool {
        relationship.type == .incomingRequest && !relationship.isSpamRequest && !relationship.isUserIgnored
    }

    /// Discord matches the untrimmed query as a case-insensitive substring
    /// of the username, friend nickname or global name.
    static func matches(_ row: FriendRow, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let query = query.lowercased()
        return row.user.username.lowercased().contains(query)
            || row.relationship.nickname?.lowercased().contains(query) == true
            || row.user.displayName.lowercased().contains(query)
    }

    static func groups(for section: FriendsSection, rows: [FriendRow], query: String) -> [FriendsListGroup] {
        let matching = rows.filter { matches($0, query: query) }
        switch section {
        case .online:
            let online = matching.filter(isOnline)
            return [FriendsListGroup(title: "Online — \(online.count)", rows: online)]
        case .all:
            let friends = matching.filter { $0.relationship.type == .friend }
            return [FriendsListGroup(title: "All Friends — \(friends.count)", rows: friends)]
        case .pending:
            let received = matching.filter { isVisibleIncomingRequest($0.relationship) }
            let sent = matching.filter { $0.relationship.type == .outgoingRequest }
            return [
                FriendsListGroup(title: "Received — \(received.count)", rows: received),
                FriendsListGroup(title: "Sent — \(sent.count)", rows: sent),
            ].filter { !$0.rows.isEmpty }
        case .addFriend:
            return []
        }
    }

    /// Sections Discord shows: Online with an online friend, All with a
    /// friend, Pending with any raw request; Add Friend always.
    static func visibleSections(_ relationships: [Relationship], presences: [UserID: UserPresence]) -> [FriendsSection] {
        let friends = relationships.filter { $0.type == .friend }
        var sections: [FriendsSection] = []
        if friends.contains(where: { presences[$0.id]?.status.isVisibleOnline == true }) { sections.append(.online) }
        if !friends.isEmpty { sections.append(.all) }
        if relationships.contains(where: { $0.type == .incomingRequest || $0.type == .outgoingRequest }) {
            sections.append(.pending)
        }
        sections.append(.addFriend)
        return sections
    }

    static func initialSection(_ relationships: [Relationship]) -> FriendsSection {
        if relationships.contains(where: { $0.type == .friend }) { return .online }
        if relationships.contains(where: isVisibleIncomingRequest) { return .pending }
        return .addFriend
    }

    /// Incoming requests that count toward the Pending badge.
    static func incomingRequestCount(_ relationships: [Relationship]) -> Int {
        relationships.count(where: isVisibleIncomingRequest)
    }

    enum UsernameInput: Equatable {
        case valid(username: String, discriminator: Int?)
        case invalid
    }

    // Official stable633029 module237309 and module395422 validation.
    static let usernameMaximumLength = 37

    /// Trims, drops one leading `@` from a username without a tag, and
    /// accepts a modern username or a legacy `name#0000` tag.
    static func parseUsername(_ input: String) -> UsernameInput {
        var tag = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tag.contains("#"), tag.hasPrefix("@") { tag.removeFirst() }
        let modern = tag.wholeMatch(of: /[a-zA-Z0-9_\\.]+/) != nil
        let legacy = tag.contains("#") && tag.wholeMatch(of: /(.+?@.+?\..+?|.+?#\d{4})/) != nil
        guard modern || legacy else { return .invalid }
        let parts = tag.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        // JavaScript `parseInt` reads leading digits; anything else is NaN and serializes as null.
        let discriminator = parts.count > 1 ? Int(String(parts[1].prefix { $0.isASCII && $0.isNumber })) : nil
        return .valid(username: String(parts[0]), discriminator: discriminator)
    }
}
