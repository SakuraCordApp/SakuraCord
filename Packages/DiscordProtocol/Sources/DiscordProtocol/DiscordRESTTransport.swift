import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    #if DEBUG
        func orderedMemberListIDsForTesting(
            guildID: GuildID, memberListID: String
        ) -> [UserID] {
            orderedMemberListMembers(
                guildID: guildID, memberListID: memberListID
            )?.map(\.id) ?? []
        }

        func memberListGroupsForTesting(
            guildID: GuildID, memberListID: String
        ) -> [GuildMemberListGroup] {
            cachedMemberListGroups[guildID]?[memberListID] ?? []
        }
    #endif

    func finishVoiceNegotiationIfReady() {
        guard let pending = pendingVoiceNegotiation,
              let sessionID = pending.sessionID,
              let token = pending.token,
              let endpoint = pending.endpoint
        else { return }
        voiceNegotiationTimeoutTask?.cancel()
        pendingVoiceNegotiation = nil
        let info = VoiceConnectionInfo(
            serverID: pending.guildID?.description ?? pending.channelID.description,
            channelID: pending.channelID,
            guildID: pending.guildID,
            userID: pending.userID,
            sessionID: sessionID,
            token: token,
            endpoint: endpoint
        )
        activeVoiceConnection = info
        pending.continuation.resume(returning: info)
    }

    func failVoiceNegotiation(id: UUID, error: any Error) {
        guard let pending = pendingVoiceNegotiation, pending.id == id else { return }
        voiceNegotiationTimeoutTask?.cancel()
        pendingVoiceNegotiation = nil
        pending.continuation.resume(throwing: error)
    }

    func decodedMemberListMembers(
        guildID: GuildID,
        memberListID: String,
        restrictingTo changedUserIDs: Set<UserID>? = nil
    ) -> [Member] {
        if changedUserIDs?.isEmpty == true {
            discordPerformanceSignposter.emitEvent(
                "GatewayMemberListDomainDecodeSkipped"
            )
            return []
        }
        let roleCatalogBuild = discordPerformanceSignposter.beginInterval(
            "GatewayMemberListRoleCatalogBuild",
            id: discordPerformanceSignposter.makeSignpostID()
        )
        let guildRoles = cachedGuildRoles[guildID] ?? []
        let guildRoleCatalog = GuildMemberRoleCatalog(guildRoles)
        discordPerformanceSignposter.endInterval(
            "GatewayMemberListRoleCatalogBuild", roleCatalogBuild
        )

        let domainDecode = discordPerformanceSignposter.beginInterval(
            "GatewayMemberListDomainDecode",
            id: discordPerformanceSignposter.makeSignpostID()
        )
        defer {
            discordPerformanceSignposter.endInterval(
                "GatewayMemberListDomainDecode", domainDecode
            )
        }
        var seen = Set<UserID>()
        return (cachedMemberListItems[guildID]?[memberListID] ?? []).enumerated().compactMap { index, item -> Member? in
            guard let memberDTO = item?.member,
                  let userID = UserID(memberDTO.user.id),
                  changedUserIDs?.contains(userID) != false,
                  var member = try? memberDTO.domain(
                      currentUserID: currentUser?.id,
                      currentStatus: presenceStatus,
                      presence: item?.presence,
                      guildRoles: guildRoles,
                      guildRoleCatalog: guildRoleCatalog,
                      guildID: guildID
                  ),
                  seen.insert(member.id).inserted
            else { return nil }
            member.memberListIndex = index
            return member
        }
    }

    func orderedMemberListMembers(
        guildID: GuildID,
        memberListID: String? = nil
    ) -> [Member]? {
        guard let memberListID = memberListID ?? selectedMemberListID[guildID],
              let memberListItems = cachedMemberListItems[guildID]?[memberListID]
        else { return nil }
        let ordering = discordPerformanceSignposter.beginInterval(
            "GatewayMemberListOrdering",
            id: discordPerformanceSignposter.makeSignpostID()
        )
        defer {
            discordPerformanceSignposter.endInterval(
                "GatewayMemberListOrdering", ordering
            )
        }
        var membersByID = Dictionary(
            (cachedMembers[guildID] ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        var seen = Set<UserID>()
        let orderedIDs = memberListItems.enumerated().compactMap { index, item -> (UserID, Int)? in
            guard let rawUserID = item?.member?.user.id,
                  let userID = UserID(rawUserID),
                  seen.insert(userID).inserted
            else { return nil }
            return (userID, index)
        }
        let missingUserIDs = Set(orderedIDs.lazy.map(\.0)).subtracting(
            membersByID.keys
        )
        if !missingUserIDs.isEmpty {
            for member in decodedMemberListMembers(
                guildID: guildID,
                memberListID: memberListID,
                restrictingTo: missingUserIDs
            ) {
                membersByID[member.id] = member
            }
        }
        return orderedIDs.compactMap { userID, index in
            guard var member = membersByID[userID] else { return nil }
            member.memberListIndex = index
            return member
        }
    }

    static func memberListChangedUserIDs(
        in operations: [GuildMemberListUpdateDTO.Operation]
    ) -> Set<UserID> {
        var userIDs = Set<UserID>()
        for operation in operations {
            if let items = operation.items {
                userIDs.formUnion(items.compactMap { item in
                    item.member.flatMap { UserID($0.user.id) }
                })
            }
            if let item = operation.item,
               let userID = item.member.flatMap({ UserID($0.user.id) })
            {
                userIDs.insert(userID)
            }
        }
        return userIDs
    }

    static var memberListOperationApplication:
        (
            inout [GuildMemberListUpdateDTO.Item?],
            GuildMemberListUpdateDTO.Operation
        ) -> Void
    {
        { items, operation in
        for operation in CollectionOfOne(operation) {
            switch operation.op {
            case "SYNC":
                guard let range = operation.range, range.count == 2, let values = operation.items
                else {
                    continue
                }
                let lower = max(0, range[0])
                let upper = max(lower, range[1])
                if items.count <= upper {
                    items.append(contentsOf: repeatElement(nil, count: upper + 1 - items.count))
                }
                for (offset, value) in values.enumerated() where lower + offset <= upper {
                    items[lower + offset] = value
                }
            case "INSERT":
                guard let index = operation.index, let item = operation.item else { continue }
                items.insert(item, at: min(max(0, index), items.count))
            case "UPDATE":
                guard let index = operation.index, index >= 0, let item = operation.item else {
                    continue
                }
                if items.count <= index {
                    items.append(contentsOf: repeatElement(nil, count: index + 1 - items.count))
                }
                items[index] = item
            case "DELETE":
                guard let index = operation.index, items.indices.contains(index) else { continue }
                items.remove(at: index)
            case "INVALIDATE":
                guard let range = operation.range, range.count == 2, !items.isEmpty else {
                    continue
                }
                let lower = max(0, range[0])
                let upper = min(items.count - 1, range[1])
                if lower <= upper {
                    for index in lower ... upper {
                        items[index] = nil
                    }
                }
            default:
                continue
            }
        }
        }
    }

    func applyMemberListOperations(
        _ operations: [GuildMemberListUpdateDTO.Operation],
        guildID: GuildID,
        memberListID: String
    ) {
        var items = cachedMemberListItems[guildID]?[memberListID] ?? []
        for operation in operations {
            Self.memberListOperationApplication(&items, operation)
        }
        cachedMemberListItems[guildID, default: [:]][memberListID] = items
    }

    func selectedMemberListGroups(guildID: GuildID) -> [GuildMemberListGroup] {
        guard let memberListID = selectedMemberListID[guildID] else { return [] }
        return cachedMemberListGroups[guildID]?[memberListID] ?? []
    }

    func request<Response: Decodable>(
        _ path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: [String: JSONValue]? = nil,
        headers: [String: String] = [:]
    ) async throws -> Response {
        let isMessageHistoryRequest = method == "GET"
            && path.hasPrefix("/channels/")
            && path.hasSuffix("/messages")
        let (data, response) = try await perform(
            path, method: method, query: query, body: body, headers: headers
        )
        guard (200 ..< 300).contains(response.statusCode) else {
            if response.statusCode == 401 {
                authorizationValue = nil
                throw ChatProviderError.unauthenticated
            }
            throw ChatProviderError.transport(
                status: response.statusCode,
                requestID: response.value(forHTTPHeaderField: "x-request-id")
            )
        }
        do {
            let decodeName: StaticString = isMessageHistoryRequest
                ? "MessageHistoryResponseDecode"
                : "RESTResponseDecode"
            let decode = discordPerformanceSignposter.beginInterval(
                decodeName,
                id: discordPerformanceSignposter.makeSignpostID()
            )
            defer {
                discordPerformanceSignposter.endInterval(
                    decodeName,
                    decode
                )
            }
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            let route = Self.routeTemplate(method: method, path: path)
            gatewayLogger.error(
                "Discord response decoding failed for \(route, privacy: .public): \(String(reflecting: error), privacy: .public)"
            )
            throw error
        }
    }

    func requestEmpty(
        _ path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: [String: JSONValue]? = nil
    ) async throws {
        let (_, response) = try await perform(
            path, method: method, query: query, body: body, headers: [:])
        guard (200 ..< 300).contains(response.statusCode) else {
            if response.statusCode == 401 {
                authorizationValue = nil
                throw ChatProviderError.unauthenticated
            }
            throw ChatProviderError.transport(
                status: response.statusCode,
                requestID: response.value(forHTTPHeaderField: "x-request-id")
            )
        }
    }

    var requestPerformance:
        @isolated(any) (
            String,
            String,
            [URLQueryItem],
            [String: JSONValue]?,
            [String: String],
            Int?
        ) async throws -> (Data, HTTPURLResponse)
    {
        { [self] path, method, query, body, headers, requestedMaximumAttempts in
        guard !requestSafetyCircuitIsOpen else {
            throw ChatProviderError.invalidRequest(
                "Discord networking was stopped for this session after an authentication or permission response. Restart only after checking the account status."
            )
        }

        let routeKey = Self.rateLimitRouteKey(method: method, path: path)
        let majorParameter = Self.rateLimitMajorParameter(path: path)
        let requestRateLimitKey = "\(routeKey) [\(majorParameter)]"
        let isMessageHistoryRequest = method == "GET"
            && path.hasPrefix("/channels/")
            && path.hasSuffix("/messages")
        let canRetryAsRead = Self.canRetryAsRead(method: method, path: path)
        let maximumAttempts = requestedMaximumAttempts ?? (canRetryAsRead ? 2 : 1)
        for attempt in 0 ..< maximumAttempts {
            let scheduling = isMessageHistoryRequest
                ? discordPerformanceSignposter.beginInterval(
                    "MessageHistoryRequestScheduling",
                    id: discordPerformanceSignposter.makeSignpostID()
                )
                : nil
            guard var components = URLComponents(
                string:
                "https://discord.com/api/v\(DiscordProductionBaseline.august2026.apiVersion)\(path)"
            ) else {
                throw ChatProviderError.invalidRequest("Could not construct the Discord API path.")
            }
            if !query.isEmpty {
                components.queryItems = query
            }
            guard let requestURL = components.url else {
                throw ChatProviderError.invalidRequest(
                    "Could not construct the Discord API query."
                )
            }
            var request = URLRequest(url: requestURL)
            request.httpMethod = method
            request.timeoutInterval = 30
            let token = try await authorizationToken()
            // Credential storage is an actor boundary. A different request may
            // have opened the safety circuit while this one was suspended.
            guard !requestSafetyCircuitIsOpen else {
                throw ChatProviderError.invalidRequest(
                    "Discord networking is stopped for this session.")
            }
            request.setValue(token, forHTTPHeaderField: "Authorization")
            try clientMetadata.apply(to: &request, clientAppState: clientAppState)
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            if let body {
                request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let rateLimitReservation: RESTRateLimitReservation
            do {
                rateLimitReservation = try await reserveRateLimitSlot(
                    routeKey: requestRateLimitKey
                )
            } catch {
                if let scheduling {
                    discordPerformanceSignposter.endInterval(
                        "MessageHistoryRequestScheduling",
                        scheduling
                    )
                }
                throw error
            }
            let requestAttempt = attempt + 1
            apiDiagnostics.recordHTTPRequest(
                method: method,
                path: path,
                query: query,
                body: request.httpBody,
                attempt: requestAttempt
            )
            let requestStarted = ContinuousClock.now
            let data: Data
            let rawResponse: URLResponse
            let requestSession = restSession
            let requestSessionGeneration = restSessionGeneration
            if let scheduling {
                discordPerformanceSignposter.endInterval(
                    "MessageHistoryRequestScheduling",
                    scheduling
                )
            }
            do {
                let networkName: StaticString = isMessageHistoryRequest
                    ? "MessageHistoryNetworkAttempt"
                    : "RESTNetworkAttempt"
                let network = discordPerformanceSignposter.beginInterval(
                    networkName,
                    id: discordPerformanceSignposter.makeSignpostID()
                )
                defer {
                    discordPerformanceSignposter.endInterval(
                        networkName,
                        network
                    )
                }
                (data, rawResponse) = try await requestSession.data(for: request)
            } catch {
                finishRateLimitReservation(rateLimitReservation)
                apiDiagnostics.recordHTTPFailure(
                    method: method,
                    path: path,
                    attempt: requestAttempt,
                    duration: requestStarted.duration(to: .now),
                    error: error
                )
                let canRetryOnCurrentSession = recoverRESTSessionIfNeeded(
                    after: error,
                    requestGeneration: requestSessionGeneration
                )
                if canRetryAsRead,
                   attempt + 1 < maximumAttempts,
                   canRetryOnCurrentSession
                {
                    continue
                }
                throw error
            }
            guard let response = rawResponse as? HTTPURLResponse else {
                finishRateLimitReservation(rateLimitReservation)
                let error = ChatProviderError.invalidRequest(
                    "Discord returned an invalid HTTP response."
                )
                apiDiagnostics.recordHTTPFailure(
                    method: method,
                    path: path,
                    attempt: requestAttempt,
                    duration: requestStarted.duration(to: .now),
                    error: error
                )
                throw error
            }
            apiDiagnostics.recordHTTPResponse(
                method: method,
                path: path,
                attempt: requestAttempt,
                response: response,
                body: data,
                duration: requestStarted.duration(to: .now)
            )
            recordRateLimitState(
                response: response,
                routeKey: requestRateLimitKey,
                majorParameter: majorParameter
            )
            finishRateLimitReservation(rateLimitReservation)

            if response.statusCode == 429 {
                let retryAfter = Self.retryAfter(from: data, response: response)
                let retryDate = Date.now.addingTimeInterval(retryAfter)
                if Self.isGlobalRateLimit(data: data, response: response) {
                    globalRateLimitDate = retryDate
                } else if let bucketKey = rateLimitBucketKeyByRoute[
                    requestRateLimitKey
                ] {
                    var state = rateLimitBuckets[bucketKey]
                        ?? RESTRateLimitBucketState(
                            limit: nil,
                            remaining: nil,
                            resetDate: retryDate,
                            resetInterval: retryAfter
                        )
                    state.remaining = 0
                    state.resetDate = max(state.resetDate, retryDate)
                    state.resetInterval = max(
                        state.resetInterval ?? 0,
                        retryAfter
                    )
                    rateLimitBuckets[bucketKey] = state
                } else {
                    routeRateLimitDates[requestRateLimitKey] = retryDate
                }
                gatewayLogger.error(
                    "Discord returned 429; affected REST traffic paused for \(retryAfter, privacy: .public) seconds"
                )
                if attempt + 1 >= maximumAttempts {
                    return (data, response)
                }
                continue
            }

            let discordCode = Self.discordErrorCode(from: data)
            let route = Self.routeTemplate(method: method, path: path)
            let bucket = response.value(forHTTPHeaderField: "X-RateLimit-Bucket") ?? "none"
            gatewayLogger.debug(
                "Discord REST \(route, privacy: .public) status=\(response.statusCode) bucket=\(bucket, privacy: .public)"
            )
            if Self.isSafetyStop(
                status: response.statusCode,
                discordCode: discordCode,
                method: method,
                data: data
            ) {
                await openSafetyCircuit(
                    status: response.statusCode,
                    discordCode: discordCode,
                    route: route
                )
                if Self.isAuthenticationFailure(
                    status: response.statusCode,
                    discordCode: discordCode
                ) {
                    throw ChatProviderError.unauthenticated
                }
                throw ChatProviderError.invalidRequest(
                    Self.safetyStopMessage(
                        status: response.statusCode,
                        discordCode: discordCode
                    )
                )
            }
            if response.statusCode == 404 {
                if Self.isExpectedResourceNotFound(method: method, path: path) {
                    unexpectedNotFoundCounts[route] = nil
                } else {
                    unexpectedNotFoundCounts[route, default: 0] += 1
                    if unexpectedNotFoundCounts[route, default: 0] >= 2 {
                        await openSafetyCircuit(status: 404, discordCode: discordCode, route: route)
                        throw ChatProviderError.invalidRequest(
                            "Discord networking was stopped after this route repeatedly returned an unexpected not-found response."
                        )
                    }
                }
            } else if (200 ..< 300).contains(response.statusCode) {
                unexpectedNotFoundCounts[route] = nil
            }
            return (data, response)
        }
        throw ChatProviderError.invalidRequest("Discord rate limiting did not recover.")
        }
    }

    func perform(
        _ path: String,
        method: String,
        query: [URLQueryItem],
        body: [String: JSONValue]?,
        headers: [String: String] = [:],
        maximumAttempts requestedMaximumAttempts: Int? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        try await requestPerformance(
            path, method, query, body, headers, requestedMaximumAttempts
        )
    }
    @discardableResult
    func reserveRateLimitSlot(
        routeKey: String
    ) async throws -> RESTRateLimitReservation {
        while true {
            try Task.checkCancellation()
            guard !requestSafetyCircuitIsOpen else {
                throw ChatProviderError.invalidRequest(
                    "Discord networking is stopped for this session."
                )
            }
            let now = Date.now
            let routeDate = routeRateLimitDates[routeKey] ?? .distantPast
            var scheduledDate = max(now, max(globalRateLimitDate, routeDate))
            if let bucketKey = rateLimitBucketKeyByRoute[routeKey],
               var bucket = rateLimitBuckets[bucketKey]
            {
                if bucket.resetDate <= now {
                    bucket.remaining = bucket.limit
                    if let resetInterval = bucket.resetInterval {
                        bucket.resetDate = now.addingTimeInterval(
                            resetInterval
                        )
                    }
                    rateLimitBuckets[bucketKey] = bucket
                }
                if bucket.remaining == 0 {
                    scheduledDate = max(scheduledDate, bucket.resetDate)
                }
            }
            let delay = scheduledDate.timeIntervalSince(now)
            if delay > 0 {
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            if rateLimitBucketKeyByRoute[routeKey] == nil,
               !rateLimitRoutesWithoutBuckets.contains(routeKey)
            {
                if rateLimitDiscoveryTokenByRoute[routeKey] != nil {
                    await waitForRateLimitDiscovery(routeKey: routeKey)
                    try Task.checkCancellation()
                    continue
                }
                let token = UUID()
                rateLimitDiscoveryTokenByRoute[routeKey] = token
                return RESTRateLimitReservation(
                    routeKey: routeKey,
                    discoveryToken: token
                )
            }
            if let bucketKey = rateLimitBucketKeyByRoute[routeKey],
               var bucket = rateLimitBuckets[bucketKey],
               let remaining = bucket.remaining,
               remaining > 0
            {
                // Reserve before leaving the actor so concurrent requests in a
                // learned bucket cannot all consume the same remaining slot.
                bucket.remaining = remaining - 1
                rateLimitBuckets[bucketKey] = bucket
            }
            return RESTRateLimitReservation(
                routeKey: routeKey,
                discoveryToken: nil
            )
        }
    }

    func waitForRateLimitDiscovery(routeKey: String) async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                rateLimitDiscoveryWaitersByRoute[routeKey, default: [:]][waiterID]
                    = continuation
            }
        } onCancel: {
            Task {
                await self.cancelRateLimitDiscoveryWaiter(
                    routeKey: routeKey,
                    waiterID: waiterID
                )
            }
        }
    }

    func cancelRateLimitDiscoveryWaiter(
        routeKey: String,
        waiterID: UUID
    ) {
        guard let waiter = rateLimitDiscoveryWaitersByRoute[routeKey]?
            .removeValue(forKey: waiterID)
        else { return }
        if rateLimitDiscoveryWaitersByRoute[routeKey]?.isEmpty == true {
            rateLimitDiscoveryWaitersByRoute[routeKey] = nil
        }
        waiter.resume()
    }

    func finishRateLimitReservation(
        _ reservation: RESTRateLimitReservation
    ) {
        guard let token = reservation.discoveryToken,
              rateLimitDiscoveryTokenByRoute[reservation.routeKey] == token
        else { return }
        rateLimitDiscoveryTokenByRoute[reservation.routeKey] = nil
        let waiters = rateLimitDiscoveryWaitersByRoute.removeValue(
            forKey: reservation.routeKey
        ) ?? [:]
        for waiter in waiters.values {
            waiter.resume()
        }
    }

    func recordRateLimitState(
        response: HTTPURLResponse,
        routeKey: String,
        majorParameter: String
    ) {
        guard let identifier = response.value(
            forHTTPHeaderField: "X-RateLimit-Bucket"
        ) else {
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
               let reset = response.value(
                forHTTPHeaderField: "X-RateLimit-Reset-After"
               ).flatMap(Double.init)
            {
                routeRateLimitDates[routeKey] = Date.now.addingTimeInterval(
                    max(0, reset)
                )
            } else if response.statusCode != 429 {
                routeRateLimitDates[routeKey] = nil
                if (200 ..< 300).contains(response.statusCode) {
                    // A successful response without a bucket header
                    // establishes that this route does not need further
                    // discovery serialization. Keep failures unknown so only
                    // one request probes the route again.
                    rateLimitRoutesWithoutBuckets.insert(routeKey)
                }
            }
            return
        }
        rateLimitRoutesWithoutBuckets.remove(routeKey)
        let key = RESTRateLimitBucketKey(
            identifier: identifier,
            majorParameter: majorParameter
        )
        rateLimitBucketKeyByRoute[routeKey] = key
        routeRateLimitDates[routeKey] = nil

        let now = Date.now
        let limit = response.value(
            forHTTPHeaderField: "X-RateLimit-Limit"
        ).flatMap(Int.init)
        let remaining = response.value(
            forHTTPHeaderField: "X-RateLimit-Remaining"
        ).flatMap(Int.init)
        let resetAfter = response.value(
            forHTTPHeaderField: "X-RateLimit-Reset-After"
        ).flatMap(Double.init)
        let resetDate = resetAfter.map {
            now.addingTimeInterval(max(0, $0))
        } ?? rateLimitBuckets[key]?.resetDate ?? .distantPast

        if let existing = rateLimitBuckets[key],
           existing.resetDate > now,
           abs(existing.resetDate.timeIntervalSince(resetDate)) < 0.250
        {
            let conservativeRemaining: Int?
            switch (existing.remaining, remaining) {
            case let (.some(current), .some(server)):
                conservativeRemaining = min(current, server)
            case let (.some(current), .none):
                conservativeRemaining = current
            case let (.none, .some(server)):
                conservativeRemaining = server
            case (.none, .none):
                conservativeRemaining = nil
            }
            rateLimitBuckets[key] = RESTRateLimitBucketState(
                limit: limit ?? existing.limit,
                remaining: conservativeRemaining,
                resetDate: max(existing.resetDate, resetDate),
                resetInterval: resetAfter ?? existing.resetInterval
            )
        } else {
            rateLimitBuckets[key] = RESTRateLimitBucketState(
                limit: limit,
                remaining: remaining,
                resetDate: resetDate,
                resetInterval: resetAfter
            )
        }
    }

    /// A cancelled HTTP/3 stream can occasionally leave every subsequent REST
    /// task on the reused URLSession waiting until its request timeout. Rotate
    /// only an app-owned REST session after that timeout. The Gateway uses a
    /// separate production session, so recovery cannot interrupt heartbeats.
    ///
    /// Reads already running on the retired generation may retry once. Writes
    /// never retry because a timeout does not prove that Discord rejected the
    /// mutation before applying it.
    func recoverRESTSessionIfNeeded(
        after error: any Error,
        requestGeneration: Int
    ) -> Bool {
        guard !Task.isCancelled else { return false }
        if requestGeneration != restSessionGeneration {
            return true
        }
        guard let restSessionConfiguration,
              Self.isRESTSessionStall(error)
        else { return false }

        let stalledSession = restSession
        restSession = URLSession(configuration: restSessionConfiguration)
        restSessionGeneration &+= 1
        stalledSession.invalidateAndCancel()
        gatewayLogger.error(
            "Discord REST session timed out; replaced stalled transport generation \(requestGeneration, privacy: .public)"
        )
        return true
    }

    static func isRESTSessionStall(_ error: any Error) -> Bool {
        (error as? URLError)?.code == .timedOut
    }

    static func canRetryAsRead(method: String, path: String) -> Bool {
        method == "GET"
            || (method == "POST" && path == "/users/@me/messages/search/tabs")
    }

    func openSafetyCircuit(status: Int, discordCode: Int?, route: String) async {
        guard !requestSafetyCircuitIsOpen else { return }
        requestSafetyCircuitIsOpen = true
        let authenticationFailure = Self.isAuthenticationFailure(
            status: status,
            discordCode: discordCode
        )
        if authenticationFailure {
            authorizationValue = nil
        }
        gatewayReady = false
        gatewayEventTask?.cancel()
        gatewayEventTask = nil
        await gatewaySession?.stop()
        gatewaySession = nil
        // The provider owns a dedicated URLSession in production. Cancel every
        // outstanding REST/upload/socket task so a request already suspended at
        // the actor boundary cannot continue after a stop signal.
        restSession.getAllTasks { tasks in
            for task in tasks {
                task.cancel()
            }
        }
        continuation?.yield(
            .connectionChanged(
                authenticationFailure ? .authenticationFailed : .disconnected
            ))
        gatewayLogger.fault(
            "Discord network safety circuit opened route=\(route, privacy: .public) HTTP=\(status) code=\(discordCode ?? -1)"
        )
    }

    static func discordErrorCode(from data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (object["code"] as? NSNumber)?.intValue
    }

    static func isSafetyStop(status: Int, discordCode: Int?, method: String, data: Data)
        -> Bool
    {
        if isAuthenticationFailure(status: status, discordCode: discordCode) {
            return true
        }
        // A 403 can be scoped to one channel or lookup (for example 50001/50013).
        // Keep those failures local instead of invalidating a healthy Gateway
        // session; the account-wide codes below still fail closed.
        if let discordCode, [40001, 40002, 40003, 40004, 40012, 40333].contains(discordCode) {
            return true
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["captcha_key"] != nil || object["captcha_sitekey"] != nil
           || object["captcha_service"] != nil
        {
            return true
        }
        // A client-generated mutation reaching HTTP 400 means SakuraCord's
        // contract is malformed. Do not let another user action repeat it.
        return status == 400 && method != "GET"
    }

    static func isAuthenticationFailure(status: Int, discordCode: Int?) -> Bool {
        status == 401 || discordCode == 40001 || discordCode == 50014
    }

    static func isExpectedResourceNotFound(method: String, path: String) -> Bool {
        guard method == "GET" else { return false }
        let segments = path.split(separator: "/")
        return segments.count == 3
            && segments[0] == "users"
            && UInt64(segments[1]) != nil
            && segments[2] == "profile"
    }

    static func safetyStopMessage(status: Int, discordCode: Int?) -> String {
        switch discordCode {
        case 10005:
            "Discord could not resolve the command's application integration. SakuraCord networking has been stopped without retrying."
        case 40002: "Discord requires account verification. SakuraCord networking has been stopped."
        case 40003:
            "Discord reported that direct messages are being opened too quickly. SakuraCord networking has been stopped."
        case 40004:
            "Discord temporarily disabled message sending. SakuraCord networking has been stopped without retrying."
        case 40012: "Discord revoked the connection. SakuraCord networking has been stopped."
        case 40333: "Discord rejected the request metadata. SakuraCord networking has been stopped."
        default:
            "Discord returned a safety-sensitive HTTP \(status) response. SakuraCord networking has been stopped."
        }
    }

    static func routeTemplate(method: String, path: String) -> String {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
            if segment.count >= 15, segment.allSatisfy(\.isNumber) {
                return "{id}"
            }
            return String(segment)
        }
        return "\(method) \(segments.joined(separator: "/"))"
    }

    static func rateLimitRouteKey(method: String, path: String) -> String {
        var segments = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        for index in segments.indices where segments[index] == "webhooks" {
            let tokenIndex = index + 2
            if segments.indices.contains(tokenIndex) {
                segments[tokenIndex] = "{token}"
            }
        }
        return routeTemplate(
            method: method,
            path: segments.joined(separator: "/")
        )
    }

    static func rateLimitMajorParameter(path: String) -> String {
        let segments = path.split(separator: "/").map(String.init)
        for resource in ["channels", "guilds"] {
            guard let index = segments.firstIndex(of: resource),
                  segments.indices.contains(index + 1)
            else { continue }
            return "\(resource):\(segments[index + 1])"
        }
        if let index = segments.firstIndex(of: "webhooks"),
           segments.indices.contains(index + 1)
        {
            var hasher = Hasher()
            hasher.combine(segments[index + 1])
            if segments.indices.contains(index + 2) {
                hasher.combine(segments[index + 2])
            }
            return "webhooks:\(hasher.finalize())"
        }
        return "none"
    }

    func authorizationToken() async throws -> String {
        guard !requestSafetyCircuitIsOpen else {
            throw ChatProviderError.invalidRequest(
                "Discord networking is stopped for this session."
            )
        }
        if let authorizationValue {
            return authorizationValue
        }
        var credential = try await credentialSource.credential()
        defer { credential.resetBytes(in: credential.indices) }
        guard !requestSafetyCircuitIsOpen else {
            throw ChatProviderError.invalidRequest(
                "Discord networking is stopped for this session."
            )
        }
        guard let value = String(data: credential, encoding: .utf8) else {
            throw ChatProviderError.unauthenticated
        }
        authorizationValue = value
        return value
    }

    static func retryAfter(from data: Data, response: HTTPURLResponse) -> TimeInterval {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = object["retry_after"] as? NSNumber
        {
            return max(value.doubleValue, 0.25) + 0.25
        }
        if let value = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) {
            return max(value, 0.25) + 0.25
        }
        return 2
    }

    static func isGlobalRateLimit(data: Data, response: HTTPURLResponse) -> Bool {
        if response.value(forHTTPHeaderField: "X-RateLimit-Global")?.lowercased() == "true" {
            return true
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return (object["global"] as? Bool) == true
    }
}

enum DiscordCredentialSource: Sendable {
    case stored(any CredentialStore, CredentialHandle)
    case pending(PendingDiscordCredential)

    var isPending: Bool {
        if case .pending = self { return true }
        return false
    }

    func credential() async throws -> Data {
        switch self {
        case let .stored(store, handle):
            try await store.credential(for: handle)
        case let .pending(pendingCredential):
            try await pendingCredential.value()
        }
    }
}
