import Foundation
import SakuraCordModels

public extension DiscordRESTProvider {
    func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws
        -> MessagePage
    {
        try await messages(
            in: channelID,
            anchoredAt: before.map(MessageHistoryAnchor.before) ?? .newest,
            limit: limit
        )
    }

    func messages(
        in channelID: ChannelID,
        anchoredAt anchor: MessageHistoryAnchor,
        limit: Int
    ) async throws -> MessagePage {
        try await messages(
            in: channelID,
            anchoredAt: anchor,
            limit: limit,
            resolvesMissingHistoryMembers: true
        )
    }

    func messagesForImmediatePresentation(
        in channelID: ChannelID,
        anchoredAt anchor: MessageHistoryAnchor,
        limit: Int
    ) async throws -> MessagePage {
        try await messages(
            in: channelID,
            anchoredAt: anchor,
            limit: limit,
            resolvesMissingHistoryMembers: false
        )
    }

    private func messages(
        in channelID: ChannelID,
        anchoredAt anchor: MessageHistoryAnchor,
        limit: Int,
        resolvesMissingHistoryMembers: Bool
    ) async throws -> MessagePage {
        var query: [URLQueryItem] = []
        switch anchor {
        case .newest:
            break
        case .before(let messageID):
            query.append(URLQueryItem(name: "before", value: messageID.description))
        case .after(let messageID):
            query.append(URLQueryItem(name: "after", value: messageID.description))
        case .around(let messageID):
            query.append(URLQueryItem(name: "around", value: messageID.description))
        }
        let boundedLimit = min(max(limit, 1), 100)
        query.append(
            URLQueryItem(
                name: "limit",
                value: String(boundedLimit)
            )
        )
        let payload: LossyList<MessageDTO> = try await request(
            "/channels/\(channelID)/messages", query: query
        )
        let postprocess = discordPerformanceSignposter.beginInterval(
            "MessageHistoryPostprocess",
            id: discordPerformanceSignposter.makeSignpostID()
        )
        defer {
            discordPerformanceSignposter.endInterval(
                "MessageHistoryPostprocess",
                postprocess
            )
        }
        cacheMessageSearchUsers(payload.elements.flatMap(\.searchIndexUsers))
        if payload.skippedCount > 0 {
            gatewayLogger.warning(
                "Skipped \(payload.skippedCount) unsupported message payloads in channel \(channelID)"
            )
        }
        var values = payload.elements.compactMap { try? $0.domain() }.sorted {
            $0.timestamp < $1.timestamp
        }
        let hydration = discordPerformanceSignposter.beginInterval(
            "MessageHistoryMemberHydration",
            id: discordPerformanceSignposter.makeSignpostID()
        )
        let memberHydration = await hydrateHistoryMembers(
            &values,
            channelID: channelID,
            resolvesMissingMembers: resolvesMissingHistoryMembers
        )
        discordPerformanceSignposter.endInterval(
            "MessageHistoryMemberHydration",
            hydration
        )
        cacheForwardSearchMessageAliases(values)
        for index in values.indices {
            attachKnownThread(to: &values[index])
            if let existing = cachedMessages[values[index].id] {
                values[index].guildMember = MessageGuildMember.merging(
                    incoming: values[index].guildMember,
                    existing: existing.guildMember
                )
            }
            cachedMessages[values[index].id] = values[index]
        }
        if case .newest = anchor, let latest = values.last {
            recordLoadedThreadLatestMessage(latest)
        }
        let firstID = values.first?.id
        let lastID = values.last?.id
        // A full page means Discord may hold more history beyond it, even
        // when some returned messages could not be decoded. Pagination
        // continues from the decoded edge, so a page with nothing decodable
        // cannot advance and ends there.
        let returnedFullPage = payload.elements.count + payload.skippedCount == boundedLimit
            && !values.isEmpty
        let hasMoreBefore: Bool
        let hasMoreAfter: Bool
        switch anchor {
        case .newest:
            hasMoreBefore = returnedFullPage
            hasMoreAfter = false
        case .before:
            hasMoreBefore = returnedFullPage
            hasMoreAfter = true
        case .after:
            hasMoreBefore = false
            hasMoreAfter = returnedFullPage
        case .around(let messageID):
            hasMoreBefore = firstID.map { $0 < messageID } ?? false
            hasMoreAfter = lastID.map { $0 > messageID } ?? false
        }
        return MessagePage(
            messages: values,
            hasMoreBefore: hasMoreBefore,
            hasMoreAfter: hasMoreAfter,
            resolvedMembers: memberHydration.members,
            hasCompleteMemberResolution: memberHydration.isComplete
        )
    }

    internal func hydrateHistoryMembers(
        _ values: inout [Message],
        channelID: ChannelID,
        resolvesMissingMembers: Bool = true
    ) async -> (members: [Member], isComplete: Bool) {
        let thread = cachedJoinedThreads[channelID]
            ?? cachedForumPosts.values.lazy.compactMap { $0[channelID]?.thread }.first
        let parentID = thread?.parentID ?? channelID
        let guildID = thread?.guildID ?? cachedChannels.values.lazy.flatMap(\.self).first(where: {
            $0.id == parentID
        })?.guildID ?? values.first?.guildID
        if let guildID {
            for index in values.indices where values[index].guildID == nil {
                values[index].guildID = guildID
            }

            let requested = requestedHistoryMemberIDs[guildID] ?? []
            let resolving = resolvingHistoryMemberIDs[guildID] ?? []
            var membersByID = cachedMemberIndex(guildID: guildID)
            let requiredUserIDs = Set(
                DiscordMessageMemberHydration.userIDs(in: values)
            )
            let missing = DiscordMessageMemberHydration.missingUserIDs(
                in: values,
                cached: Set(membersByID.keys),
                requested: requested
            )
            let hasPendingResolution = !requiredUserIDs.isDisjoint(with: resolving)
            var isComplete = missing.isEmpty && !hasPendingResolution
            if resolvesMissingMembers, !missing.isEmpty {
                requestedHistoryMemberIDs[guildID, default: []].formUnion(missing)
                resolvingHistoryMemberIDs[guildID, default: []].formUnion(missing)
                do {
                    try await requestMembersByID(missing, guildID: guildID)
                    isComplete = !hasPendingResolution
                    resolvingHistoryMemberIDs[guildID]?.subtract(missing)
                    if resolvingHistoryMemberIDs[guildID]?.isEmpty == true {
                        resolvingHistoryMemberIDs[guildID] = nil
                    }
                } catch {
                    isComplete = false
                    requestedHistoryMemberIDs[guildID]?.subtract(missing)
                    if requestedHistoryMemberIDs[guildID]?.isEmpty == true {
                        requestedHistoryMemberIDs[guildID] = nil
                    }
                    resolvingHistoryMemberIDs[guildID]?.subtract(missing)
                    if resolvingHistoryMemberIDs[guildID]?.isEmpty == true {
                        resolvingHistoryMemberIDs[guildID] = nil
                    }
                    gatewayLogger.warning(
                        "History member lookup failed; count=\(missing.count), error=\(error.localizedDescription, privacy: .public)"
                    )
                }
            }

            if !missing.isEmpty {
                membersByID = cachedMemberIndex(guildID: guildID)
            }
            for index in values.indices {
                DiscordMessageMemberHydration.hydrate(
                    message: &values[index],
                    membersByID: membersByID
                )
            }
            return (
                DiscordMessageMemberHydration.userIDs(in: values).compactMap {
                    membersByID[$0]
                },
                isComplete
            )
        }
        return ([], true)
    }

}
