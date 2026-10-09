import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    func currentUserSearchAliasesByUserID() -> [UserID: [String]] {
        var result: [UserID: [String]] = [:]
        var seenGuildIDs = Set<GuildID>()
        // CONNECTION_OPEN establishes GuildMemberStore's key insertion order.
        // Cached aliases only fill gaps after that live authoritative order;
        // putting the disk cache first changed equal-score nickname ties.
        let orderedGuildIDs = gatewayGuildIDs.filter {
            seenGuildIDs.insert($0).inserted
        } + loadedForwardSearchAliasGuildOrder.filter { seenGuildIDs.insert($0).inserted }
            + cachedMembers.keys.sorted().filter { seenGuildIDs.insert($0).inserted }
            + cachedForwardSearchAliasGuildOrder.filter { seenGuildIDs.insert($0).inserted }
        for guildID in orderedGuildIDs {
            var aliases = cachedForwardSearchAliasesByGuildID[guildID] ?? [:]
            for member in cachedMembers[guildID] ?? [] {
                aliases[member.id] = forwardSearchNickname(from: member)
            }
            for userID in aliases.keys.sorted() {
                guard let alias = aliases[userID],
                      result[userID, default: []].contains(where: {
                          $0.localizedCaseInsensitiveCompare(alias) == .orderedSame
                      }) == false
                else { continue }
                result[userID, default: []].append(alias)
            }
        }
        return result
    }

    func currentQuickSwitcherGuildMemberUserIDs() -> [GuildID: [UserID]] {
        var guildIDs = Set(gatewayGuildIDs)
        guildIDs.formUnion(quickSwitcherGuildMemberUserIDsByGuildID.keys)
        guildIDs.formUnion(cachedMembers.keys)
        let result = Dictionary(uniqueKeysWithValues: guildIDs.map { guildID in
            var remaining = quickSwitcherGuildMemberUserIDsByGuildID[guildID] ?? []
            remaining.formUnion((cachedMembers[guildID] ?? []).map(\.id))
            var ordered: [UserID] = []
            for member in cachedMembers[guildID] ?? [] where remaining.remove(member.id) != nil {
                ordered.append(member.id)
            }
            ordered.append(contentsOf: remaining.sorted())
            return (guildID, ordered)
        })
        return result
    }

    func currentQuickSwitcherGuildMemberAliases() -> [GuildID: [UserID: String]] {
        var guildIDs = Set(gatewayGuildIDs)
        guildIDs.formUnion(cachedMembers.keys)
        return Dictionary(uniqueKeysWithValues: guildIDs.map { guildID in
            var aliases: [UserID: String] = [:]
            for member in cachedMembers[guildID] ?? [] {
                aliases[member.id] = forwardSearchNickname(from: member)
            }
            return (guildID, aliases.filter { !$0.value.isEmpty })
        })
    }

    func currentQuickSwitcherJoinedGuildMemberUserIDs() -> [GuildID: [UserID]] {
        Dictionary(uniqueKeysWithValues: quickSwitcherJoinedMemberIDsByGuildID.map { entry in
            (entry.key, entry.value.sorted())
        })
    }

    func publishUserSearchAliases() {
        continuation?.yield(.userSearchAliasesChanged(currentUserSearchAliasesByUserID()))
        continuation?.yield(.quickSwitcherGuildMemberUserIDsChanged(
            currentQuickSwitcherGuildMemberUserIDs()
        ))
        continuation?.yield(.quickSwitcherJoinedMemberIDsChanged(
            currentQuickSwitcherJoinedGuildMemberUserIDs()
        ))
        continuation?.yield(.quickSwitcherGuildMemberAliasesChanged(
            currentQuickSwitcherGuildMemberAliases()
        ))
    }

    func currentKnownUsers() -> [User] {
        cachedGatewayUserOrder.compactMap { rawUserID -> User? in
            let userID = UserID(rawUserID)
            guard let user = cachedGatewayUsersByID[rawUserID]
                .flatMap({ try? $0.domain() }) ?? userID.flatMap({
                    cachedForwardSearchUsersByID[$0]
                }),
                  !cachedBlockedOrIgnoredUserIDs.contains(user.id)
            else { return nil }
            return user
        }
    }

    func currentQuickSwitcherUsers() -> [User] {
        var seen = Set<UserID>()
        let orderedUserIDs = forwardSearchEligibleUserOrder.filter {
            seen.insert($0).inserted
        }
        // Discord's quick-switcher worker mirrors the live UserStore. It does
        // not index every user record carried by READY_SUPPLEMENTAL, nor does
        // it restore message authors from an app-specific disk cache. READY
        // users and members hydrated into UserStore are marked eligible at
        // their ingestion sites and retain the same insertion order here.
        // UserStore retains blocked/ignored relationships as searchable
        // identities; forwarding continues to exclude them separately.
        // Keeping this distinct from currentKnownUsers() prevents a relaunch
        // with ForwardSearchPeople data from changing quick-switcher results.
        return orderedUserIDs.compactMap { userID in
            cachedGatewayUsersByID[userID.description]
                .flatMap { try? $0.domain() } ?? cachedForwardSearchUsersByID[userID]
        }
    }

    func currentMessageSearchUsers() -> [User] {
        messageSearchUserOrder.compactMap { userID in
            cachedGatewayUsersByID[userID.description].flatMap { try? $0.domain() }
        }
    }

    @discardableResult
    func cacheGatewayUser(
        _ user: UserDTO,
        forwardSearchEligible: Bool = true,
        includeInKnownUserStore: Bool = true,
        messageSearchEligible: Bool? = nil
    ) -> Bool {
        let userID = UserID(user.id)
        let previousGatewayUser = cachedGatewayUsersByID[user.id].flatMap { try? $0.domain() }
        let previous = previousGatewayUser ?? userID.flatMap { cachedForwardSearchUsersByID[$0] }
        let insertedIntoKnownUserStore = includeInKnownUserStore
            && cachedGatewayUserIDs.insert(user.id).inserted
        if insertedIntoKnownUserStore {
            cachedGatewayUserOrder.append(user.id)
        }
        cachedGatewayUsersByID[user.id] = user
        if previousGatewayUser != (try? user.domain()) {
            cachedUserRevisions[user.id, default: 0] &+= 1
            if let userID, cachedRelationships[userID] != nil { scheduleRelationshipUserPublication() }
        }
        let becameForwardSearchEligible = userID.map {
            forwardSearchEligible && forwardSearchEligibleUserIDs.insert($0).inserted
        } ?? false
        if let userID, becameForwardSearchEligible {
            forwardSearchEligibleUserOrder.append(userID)
        }
        let admitsToMessageSearch = messageSearchEligible ?? includeInKnownUserStore
        let becameMessageSearchEligible = userID.map {
            admitsToMessageSearch && messageSearchUserIDs.insert($0).inserted
        } ?? false
        if let userID, becameMessageSearchEligible {
            messageSearchUserOrder.append(userID)
        }
        return becameMessageSearchEligible || becameForwardSearchEligible || insertedIntoKnownUserStore
            || previous != (try? user.domain())
    }

    @discardableResult
    func includeCachedGatewayUserInKnownUserStore(_ rawUserID: String) -> Bool {
        guard cachedGatewayUsersByID[rawUserID] != nil,
              let userID = UserID(rawUserID)
        else { return false }
        let insertedIntoKnownUserStore = cachedGatewayUserIDs.insert(rawUserID).inserted
        if insertedIntoKnownUserStore {
            cachedGatewayUserOrder.append(rawUserID)
        }
        let insertedIntoMessageSearch = messageSearchUserIDs.insert(userID).inserted
        if insertedIntoMessageSearch {
            messageSearchUserOrder.append(userID)
        }
        return insertedIntoKnownUserStore || insertedIntoMessageSearch
    }

    func cacheLiveSearchUsers(_ users: [UserDTO]) {
        cacheSearchUsers(users, persistToMessageCache: false)
    }

    func cacheMessageSearchUsers(_ users: [UserDTO]) {
        cacheSearchUsers(users, persistToMessageCache: true)
    }

    private func cacheSearchUsers(
        _ users: [UserDTO],
        persistToMessageCache: Bool
    ) {
        var changed = false
        for user in users {
            changed = cacheGatewayUser(user) || changed
        }
        let persistentChanged = persistToMessageCache
            ? cacheForwardSearchMessageUsers(users) : false
        if persistentChanged {
            scheduleForwardSearchPeopleCachePersistence()
        }
        if changed || persistentChanged {
            continuation?.yield(.knownUsersChanged(currentKnownUsers()))
            continuation?.yield(
                .quickSwitcherUserIDsChanged(currentQuickSwitcherUsers().map(\.id))
            )
            continuation?.yield(.messageSearchUsersChanged(currentMessageSearchUsers()))
        }
    }
}
