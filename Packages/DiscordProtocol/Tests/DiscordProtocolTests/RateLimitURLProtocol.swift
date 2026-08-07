import Foundation

final class RateLimitURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var totalRequestCount = 0
    nonisolated(unsafe) static var guildListAttempts = 0
    nonisolated(unsafe) static var guildListJSON =
        #"[{"id":"100","name":"Guild","icon":null,"owner":false,"permissions":"1024"}]"#
    nonisolated(unsafe) static var currentUserRequests = 0
    nonisolated(unsafe) static var apexInstallationRequests = 0
    nonisolated(unsafe) static var apexInstallationQuery: [String: String] = [:]
    nonisolated(unsafe) static var apexInstallationMethod: String?
    nonisolated(unsafe) static var apexInstallationHost: String?
    nonisolated(unsafe) static var apexInstallationReferer: String?
    nonisolated(unsafe) static var apexInstallationAuthorization: String?
    nonisolated(unsafe) static var apexInstallationHeader: String?
    nonisolated(unsafe) static var apexInstallationFingerprint: String?
    nonisolated(unsafe) static var apexInstallationSuperProperties: String?
    nonisolated(unsafe) static var apexInstallationHadBody = false
    nonisolated(unsafe) static var apexOmitsInstallation = false
    nonisolated(unsafe) static var loginExperimentsRequests = 0
    nonisolated(unsafe) static var loginExperimentsQuery: [String: String] = [:]
    nonisolated(unsafe) static var loginExperimentsMethod: String?
    nonisolated(unsafe) static var loginExperimentsHost: String?
    nonisolated(unsafe) static var loginExperimentsReferer: String?
    nonisolated(unsafe) static var loginExperimentsContext: String?
    nonisolated(unsafe) static var loginExperimentsAuthorization: String?
    nonisolated(unsafe) static var loginExperimentsInstallationHeader: String?
    nonisolated(unsafe) static var loginExperimentsFingerprint: String?
    nonisolated(unsafe) static var loginExperimentsSuperProperties: String?
    nonisolated(unsafe) static var loginExperimentsHadBody = false
    nonisolated(unsafe) static var privateChannelListRequests = 0
    nonisolated(unsafe) static var guildChannelRequests = 0
    nonisolated(unsafe) static var guildRoleRequests = 0
    nonisolated(unsafe) static var guildEmojiRequests = 0
    nonisolated(unsafe) static var emojiSettingsRequests = 0
    nonisolated(unsafe) static var sentNonce: String?
    nonisolated(unsafe) static var sentEnforceNonce = false
    nonisolated(unsafe) static var uploadHadAuthorization = false
    nonisolated(unsafe) static var sentUploadedFilename: String?
    nonisolated(unsafe) static var typingRequestCount = 0
    nonisolated(unsafe) static var typingMethod: String?
    nonisolated(unsafe) static var typingHadBody = false
    nonisolated(unsafe) static var typingSuperProperties: String?
    nonisolated(unsafe) static var messageRequestCount = 0
    nonisolated(unsafe) static var messageMethod: String?
    nonisolated(unsafe) static var messagePath: String?
    nonisolated(unsafe) static var sentMessageBody: [String: Any]?
    nonisolated(unsafe) static var messageContextProperties: String?
    nonisolated(unsafe) static var messageSuperProperties: String?
    nonisolated(unsafe) static var messageUserAgent: String?
    nonisolated(unsafe) static var restrictMessageSend = false
    nonisolated(unsafe) static var forbidMemberSearch = false
    nonisolated(unsafe) static var unauthorizeMemberSearch = false
    nonisolated(unsafe) static var unavailableProfileRequestCount = 0
    nonisolated(unsafe) static var settingsRequestCount = 0
    nonisolated(unsafe) static var settingsMethod: String?
    nonisolated(unsafe) static var guildCommandIndexRequests = 0
    nonisolated(unsafe) static var channelCommandIndexRequests = 0
    nonisolated(unsafe) static var userCommandIndexRequests = 0
    nonisolated(unsafe) static var memberSearchQuery: String?
    nonisolated(unsafe) static var memberSearchLimit: String?
    nonisolated(unsafe) static var memberSearchRequestCount = 0
    nonisolated(unsafe) static var interactionRequestCount = 0
    nonisolated(unsafe) static var interactionBodies: [[String: Any]] = []
    nonisolated(unsafe) static var ackRequestCount = 0
    nonisolated(unsafe) static var ackMethod: String?
    nonisolated(unsafe) static var ackPath: String?
    nonisolated(unsafe) static var ackBody: [String: Any]?
    nonisolated(unsafe) static var ackStatus = 200
    nonisolated(unsafe) static var bulkAckRequestCount = 0
    nonisolated(unsafe) static var bulkAckMethods: [String] = []
    nonisolated(unsafe) static var bulkAckBodies: [[String: Any]] = []
    nonisolated(unsafe) static var bulkAckStatuses: [Int] = []
    nonisolated(unsafe) static var guildNotificationRequestCount = 0
    nonisolated(unsafe) static var guildNotificationMethod: String?
    nonisolated(unsafe) static var guildNotificationBody: [String: Any]?
    nonisolated(unsafe) static var guildNotificationStatus = 200
    nonisolated(unsafe) static var channelNotificationRequestCount = 0
    nonisolated(unsafe) static var channelNotificationMethod: String?
    nonisolated(unsafe) static var channelNotificationPath: String?
    nonisolated(unsafe) static var channelNotificationBody: [String: Any]?
    nonisolated(unsafe) static var channelNotificationStatus = 200
    nonisolated(unsafe) static var threadMemberMethods: [String] = []
    nonisolated(unsafe) static var threadMemberPaths: [String] = []
    nonisolated(unsafe) static var threadMemberBodies: [[String: Any]] = []
    nonisolated(unsafe) static var threadMemberJoinLocation: String?
    nonisolated(unsafe) static var threadMemberStatus = 204
    nonisolated(unsafe) static var reactionMethods: [String] = []

    static func reset() {
        totalRequestCount = 0
        guildListAttempts = 0
        guildListJSON =
            #"[{"id":"100","name":"Guild","icon":null,"owner":false,"permissions":"1024"}]"#
        currentUserRequests = 0
        apexInstallationRequests = 0
        apexInstallationQuery = [:]
        apexInstallationMethod = nil
        apexInstallationHost = nil
        apexInstallationReferer = nil
        apexInstallationAuthorization = nil
        apexInstallationHeader = nil
        apexInstallationFingerprint = nil
        apexInstallationSuperProperties = nil
        apexInstallationHadBody = false
        apexOmitsInstallation = false
        loginExperimentsRequests = 0
        loginExperimentsQuery = [:]
        loginExperimentsMethod = nil
        loginExperimentsHost = nil
        loginExperimentsReferer = nil
        loginExperimentsContext = nil
        loginExperimentsAuthorization = nil
        loginExperimentsInstallationHeader = nil
        loginExperimentsFingerprint = nil
        loginExperimentsSuperProperties = nil
        loginExperimentsHadBody = false
        privateChannelListRequests = 0
        guildChannelRequests = 0
        guildRoleRequests = 0
        guildEmojiRequests = 0
        emojiSettingsRequests = 0
        sentNonce = nil
        sentEnforceNonce = false
        uploadHadAuthorization = false
        sentUploadedFilename = nil
        typingRequestCount = 0
        typingMethod = nil
        typingHadBody = false
        typingSuperProperties = nil
        messageRequestCount = 0
        messageMethod = nil
        messagePath = nil
        sentMessageBody = nil
        messageContextProperties = nil
        messageSuperProperties = nil
        messageUserAgent = nil
        restrictMessageSend = false
        forbidMemberSearch = false
        unauthorizeMemberSearch = false
        unavailableProfileRequestCount = 0
        settingsRequestCount = 0
        settingsMethod = nil
        guildCommandIndexRequests = 0
        channelCommandIndexRequests = 0
        userCommandIndexRequests = 0
        interactionRequestCount = 0
        interactionBodies = []
        memberSearchQuery = nil
        memberSearchLimit = nil
        memberSearchRequestCount = 0
        ackRequestCount = 0
        ackMethod = nil
        ackPath = nil
        ackBody = nil
        ackStatus = 200
        bulkAckRequestCount = 0
        bulkAckMethods = []
        bulkAckBodies = []
        bulkAckStatuses = []
        guildNotificationRequestCount = 0
        guildNotificationMethod = nil
        guildNotificationBody = nil
        guildNotificationStatus = 200
        channelNotificationRequestCount = 0
        channelNotificationMethod = nil
        channelNotificationPath = nil
        channelNotificationBody = nil
        channelNotificationStatus = 200
        threadMemberMethods = []
        threadMemberPaths = []
        threadMemberBodies = []
        threadMemberJoinLocation = nil
        threadMemberStatus = 204
        reactionMethods = []
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    private struct StubResponse {
        let status: Int
        let json: String
    }

    private struct StubResponseBuilder {
        let request: URLRequest

        var response: StubResponse {
        let path = request.url?.path ?? ""
        let status: Int
        let json: String
        switch path {
        case "/api/v9/apex/experiments":
            RateLimitURLProtocol.apexInstallationRequests += 1
            RateLimitURLProtocol.apexInstallationQuery = Dictionary(
                uniqueKeysWithValues: (URLComponents(
                    url: request.url!,
                    resolvingAgainstBaseURL: false
                )?.queryItems ?? []).compactMap { item in
                    item.value.map { (item.name, $0) }
                }
            )
            RateLimitURLProtocol.apexInstallationAuthorization = request.value(
                forHTTPHeaderField: "Authorization"
            )
            RateLimitURLProtocol.apexInstallationMethod = request.httpMethod
            RateLimitURLProtocol.apexInstallationHost = request.url?.host
            RateLimitURLProtocol.apexInstallationReferer = request.value(
                forHTTPHeaderField: "Referer"
            )
            RateLimitURLProtocol.apexInstallationHeader = request.value(
                forHTTPHeaderField: "X-Installation-ID"
            )
            RateLimitURLProtocol.apexInstallationFingerprint = request.value(
                forHTTPHeaderField: "X-Fingerprint"
            )
            RateLimitURLProtocol.apexInstallationSuperProperties = request.value(
                forHTTPHeaderField: "X-Super-Properties"
            )
            RateLimitURLProtocol.apexInstallationHadBody = request.httpBody?.isEmpty == false
            status = 200
            json = RateLimitURLProtocol.apexOmitsInstallation
                ? #"{"assignments":{}}"#
                : #"{"installation":"server-issued-installation","assignments":{}}"#
        case "/api/v9/experiments":
            RateLimitURLProtocol.loginExperimentsRequests += 1
            RateLimitURLProtocol.loginExperimentsQuery = Dictionary(
                uniqueKeysWithValues: (URLComponents(
                    url: request.url!,
                    resolvingAgainstBaseURL: false
                )?.queryItems ?? []).compactMap { item in
                    item.value.map { (item.name, $0) }
                }
            )
            RateLimitURLProtocol.loginExperimentsMethod = request.httpMethod
            RateLimitURLProtocol.loginExperimentsHost = request.url?.host
            RateLimitURLProtocol.loginExperimentsReferer = request.value(
                forHTTPHeaderField: "Referer"
            )
            RateLimitURLProtocol.loginExperimentsContext = request.value(
                forHTTPHeaderField: "X-Context-Properties"
            )
            RateLimitURLProtocol.loginExperimentsAuthorization = request.value(
                forHTTPHeaderField: "Authorization"
            )
            RateLimitURLProtocol.loginExperimentsInstallationHeader = request.value(
                forHTTPHeaderField: "X-Installation-ID"
            )
            RateLimitURLProtocol.loginExperimentsFingerprint = request.value(
                forHTTPHeaderField: "X-Fingerprint"
            )
            RateLimitURLProtocol.loginExperimentsSuperProperties = request.value(
                forHTTPHeaderField: "X-Super-Properties"
            )
            RateLimitURLProtocol.loginExperimentsHadBody = request.httpBody?.isEmpty == false
            status = 200
            json = #"{"fingerprint":"server-issued-fingerprint","installation":"fallback-installation","assignments":[],"guild_experiments":[]}"#
        case "/api/v9/users/@me":
            RateLimitURLProtocol.currentUserRequests += 1
            status = 200
            json = #"{"id":"1","username":"tester","global_name":"Tester","avatar":null}"#
        case "/api/v9/users/@me/guilds":
            RateLimitURLProtocol.guildListAttempts += 1
            if RateLimitURLProtocol.guildListAttempts == 1 {
                status = 429
                json = #"{"retry_after":0.01,"global":false}"#
            } else {
                status = 200
                json = RateLimitURLProtocol.guildListJSON
            }
        case "/api/v9/users/@me/channels":
            RateLimitURLProtocol.privateChannelListRequests += 1
            status = 200
            json = "[]"
        case "/api/v9/users/@me/settings-proto/1":
            RateLimitURLProtocol.settingsRequestCount += 1
            RateLimitURLProtocol.settingsMethod = request.httpMethod
            status = 200
            json = #"{"settings":"\#(RateLimitURLProtocol.guildFolderSettingsProto().base64EncodedString())"}"#
        case "/api/v9/guilds/100/channels":
            RateLimitURLProtocol.guildChannelRequests += 1
            status = 200
            json = #"""
            [{"id":"199","guild_id":"100","name":"CHAT","type":4,"position":1,"permission_overwrites":[]},
            {"id":"200","guild_id":"100","name":"general","topic":null,"type":0,"parent_id":"199",
            "position":2,"permission_overwrites":[]}]
            """#
        case "/api/v9/guilds/100/roles":
            RateLimitURLProtocol.guildRoleRequests += 1
            status = 200
            json = #"""
            [{"id":"100","name":"@everyone","position":0,"hoist":false,"color":0,"permissions":"1024"},
            {"id":"101","name":"Design","position":2,"hoist":true,"color":5793266,"permissions":"0"}]
            """#
        case "/api/v9/guilds/987654321012345678/emojis":
            RateLimitURLProtocol.guildEmojiRequests += 1
            status = 200
            json = "[]"
        case "/api/v9/users/@me/settings-proto/2":
            RateLimitURLProtocol.emojiSettingsRequests += 1
            status = 200
            json = #"{"settings":""}"#
        case "/api/v9/guilds/100/members/search":
            RateLimitURLProtocol.memberSearchRequestCount += 1
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            RateLimitURLProtocol.memberSearchQuery = items?.first(where: { $0.name == "query" })?.value
            RateLimitURLProtocol.memberSearchLimit = items?.first(where: { $0.name == "limit" })?.value
            if RateLimitURLProtocol.unauthorizeMemberSearch {
                status = 401
                json = #"{"code":40001,"message":"Unauthorized"}"#
            } else if RateLimitURLProtocol.forbidMemberSearch {
                status = 403
                json = #"{"code":50001,"message":"Missing Access"}"#
            } else {
                status = 200
                json = #"[{"member":{"user":{"id":"2","username":"maya","global_name":"Maya","avatar":null},"nick":"Maya","roles":["101"]}}]"#
            }
        case "/api/v9/users/111111111111111111/profile",
             "/api/v9/users/222222222222222222/profile":
            RateLimitURLProtocol.unavailableProfileRequestCount += 1
            status = 404
            json = #"{"message":"Unknown User","code":10013}"#
        case "/api/v9/guilds/100/application-command-index":
            RateLimitURLProtocol.guildCommandIndexRequests += 1
            status = 200
            json = RateLimitURLProtocol.commandIndexJSON(guildID: "100")
        case "/api/v9/channels/200/application-command-index":
            RateLimitURLProtocol.channelCommandIndexRequests += 1
            status = 200
            json = RateLimitURLProtocol.commandIndexJSON(guildID: nil)
        case "/api/v9/users/@me/application-command-index":
            RateLimitURLProtocol.userCommandIndexRequests += 1
            status = 200
            json = RateLimitURLProtocol.commandIndexJSON(guildID: nil)
        case "/api/v9/interactions":
            RateLimitURLProtocol.interactionRequestCount += 1
            if let body = RateLimitURLProtocol.requestBody(request),
               let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            {
                RateLimitURLProtocol.interactionBodies.append(object)
            }
            status = 204
            json = ""
        case "/api/v9/channels/200/attachments":
            status = 200
            json = #"{"attachments":[{"id":0,"upload_url":"https://upload.example/test","upload_filename":"discord-upload-token"}]}"#
        case "/api/v9/channels/200/typing":
            RateLimitURLProtocol.typingRequestCount += 1
            RateLimitURLProtocol.typingMethod = request.httpMethod
            RateLimitURLProtocol.typingHadBody = RateLimitURLProtocol.requestBody(request)?.isEmpty == false
            RateLimitURLProtocol.typingSuperProperties = request.value(forHTTPHeaderField: "X-Super-Properties")
            status = 204
            json = ""
        case "/api/v9/channels/200/messages/332/ack",
             "/api/v9/channels/200/messages/333/ack",
             "/api/v9/channels/200/messages/334/ack",
             "/api/v9/channels/200/messages/335/ack":
            RateLimitURLProtocol.ackRequestCount += 1
            RateLimitURLProtocol.ackMethod = request.httpMethod
            RateLimitURLProtocol.ackPath = path
            RateLimitURLProtocol.ackBody = RateLimitURLProtocol.requestBody(request).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            status = RateLimitURLProtocol.ackStatus
            json =
                status == 200
                ? #"{"token":"next-token"}"#
                : #"{"retry_after":0.01,"global":false}"#
        case "/api/v9/read-states/ack-bulk":
            RateLimitURLProtocol.bulkAckRequestCount += 1
            RateLimitURLProtocol.bulkAckMethods.append(request.httpMethod ?? "")
            if let body = RateLimitURLProtocol.requestBody(request),
               let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            {
                RateLimitURLProtocol.bulkAckBodies.append(object)
            }
            let requestIndex = RateLimitURLProtocol.bulkAckRequestCount - 1
            status = RateLimitURLProtocol.bulkAckStatuses.indices.contains(requestIndex)
                ? RateLimitURLProtocol.bulkAckStatuses[requestIndex] : 204
            json = status == 204 ? "" : #"{"message":"Synthetic rejection"}"#
        case "/api/v9/users/@me/guilds/settings":
            RateLimitURLProtocol.guildNotificationRequestCount += 1
            RateLimitURLProtocol.guildNotificationMethod = request.httpMethod
            RateLimitURLProtocol.guildNotificationBody =
                RateLimitURLProtocol.requestBody(request).flatMap {
                    try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                }
            status = RateLimitURLProtocol.guildNotificationStatus
            json =
                status == 200
                ? #"[{"guild_id":"100"}]"#
                : #"{"retry_after":0.01,"global":false}"#
        case "/api/v9/users/@me/guilds/100/settings",
             "/api/v9/users/@me/guilds/@me/settings":
            RateLimitURLProtocol.channelNotificationRequestCount += 1
            RateLimitURLProtocol.channelNotificationMethod = request.httpMethod
            RateLimitURLProtocol.channelNotificationPath = path
            RateLimitURLProtocol.channelNotificationBody = RateLimitURLProtocol.requestBody(request).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            status = RateLimitURLProtocol.channelNotificationStatus
            json =
                status == 200
                ? #"{"channel_overrides":[]}"#
                : #"{"retry_after":0.01,"global":false}"#
        case "/api/v9/channels/500/thread-members/@me/settings",
             "/api/v9/channels/501/thread-members/@me",
             "/api/v9/channels/501/thread-members/@me/settings":
            RateLimitURLProtocol.threadMemberMethods.append(request.httpMethod ?? "")
            RateLimitURLProtocol.threadMemberPaths.append(path)
            if let body = RateLimitURLProtocol.requestBody(request),
               let object =
               try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            {
                RateLimitURLProtocol.threadMemberBodies.append(object)
            } else {
                RateLimitURLProtocol.threadMemberBodies.append([:])
            }
            if path.hasSuffix("/thread-members/@me") {
                let items = URLComponents(
                    url: request.url!,
                    resolvingAgainstBaseURL: false
                )?.queryItems
                RateLimitURLProtocol.threadMemberJoinLocation =
                    items?.first(where: { $0.name == "location" })?.value
            }
            status = RateLimitURLProtocol.threadMemberStatus
            json =
                status == 204
                ? ""
                : #"{"retry_after":0.01,"global":false}"#
        case let path
            where path.hasPrefix("/api/v9/channels/200/messages/300/reactions/")
                && path.hasSuffix("/@me"):
            RateLimitURLProtocol.reactionMethods.append(request.httpMethod ?? "")
            status = 204
            json = ""
        case "/test":
            RateLimitURLProtocol.uploadHadAuthorization = request.value(forHTTPHeaderField: "Authorization") != nil
            status = 200
            json = "{}"
        case "/api/v9/channels/200/messages":
            RateLimitURLProtocol.messageMethod = request.httpMethod
            RateLimitURLProtocol.messagePath = path
            RateLimitURLProtocol.messageContextProperties = request.value(forHTTPHeaderField: "X-Context-Properties")
            RateLimitURLProtocol.messageSuperProperties = request.value(forHTTPHeaderField: "X-Super-Properties")
            RateLimitURLProtocol.messageUserAgent = request.value(forHTTPHeaderField: "User-Agent")
            if request.httpMethod == "GET" {
                status = 200
                json = #"""
                [{
                  "id":"350",
                  "channel_id":"200",
                  "author":{
                    "id":"4",
                    "username":"history-author",
                    "global_name":"History Author",
                    "avatar":null
                  },
                  "content":"history",
                  "timestamp":"2026-07-11T19:00:00.000Z",
                  "edited_timestamp":null,
                  "attachments":[],
                  "reactions":[],
                  "mentions":[]
                }]
                """#
                break
            }
            RateLimitURLProtocol.messageRequestCount += 1
            let body = RateLimitURLProtocol.requestBody(request).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            RateLimitURLProtocol.sentMessageBody = body
            RateLimitURLProtocol.sentNonce = body?["nonce"] as? String
            RateLimitURLProtocol.sentEnforceNonce = body?["enforce_nonce"] as? Bool == true
            RateLimitURLProtocol.sentUploadedFilename = ((body?["attachments"] as? [[String: Any]])?.first)?["uploaded_filename"] as? String
            if RateLimitURLProtocol.restrictMessageSend {
                status = 400
                json = #"{"code":40004,"message":"Send messages has been temporarily disabled."}"#
            } else if (body?["message_reference"] as? [String: Any])?["message_id"] != nil {
                status = 200
                json = #"""
                {"id":"301","channel_id":"200",
                "author":{"id":"1","username":"tester","global_name":"Tester","avatar":null},
                "content":"reply","timestamp":"2026-07-11T20:01:00.000Z","edited_timestamp":null,
                "message_reference":{"message_id":"299"},
                "referenced_message":{"id":"299","author":{"id":"2","username":"original",
                "global_name":"Original Author","avatar":null},"content":"original message"},
                "attachments":[],"reactions":[]}
                """#
            } else {
                status = 200
                let content = (body?["content"] as? String) ?? ""
                let encodedContent: String
                do {
                    let data = try JSONSerialization.data(
                        withJSONObject: content,
                        options: [.fragmentsAllowed]
                    )
                    guard let text = String(data: data, encoding: .utf8) else {
                        preconditionFailure("JSONSerialization returned non-UTF-8 data")
                    }
                    encodedContent = text
                } catch {
                    preconditionFailure("Unable to encode test message content: \(error)")
                }
                json = #"""
                {"id":"300","channel_id":"200",
                "author":{"id":"1","username":"tester","global_name":"Tester","avatar":null},
                "content":\#(encodedContent),"timestamp":"2026-07-11T20:00:00.000Z",
                "edited_timestamp":null,"attachments":[],"reactions":[]}
                """#
            }
        default:
            status = 404
            json = "{}"
        }
            return StubResponse(status: status, json: json)
        }
    }

    override func startLoading() {
        Self.totalRequestCount += 1
        let stub = StubResponseBuilder(request: request).response
        let status = stub.status
        let json = stub.json
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func guildFolderSettingsProto(guildIDs orderedGuildIDs: [UInt64] = [100]) -> Data {
        func field(_ number: Int, payload: [UInt8]) -> [UInt8] {
            encodeProtoVarint(UInt64(number << 3 | 2)) + encodeProtoVarint(UInt64(payload.count)) + payload
        }
        let fixedGuildIDs = orderedGuildIDs.flatMap { guildID in
            (0 ..< 8).map {
                UInt8(truncatingIfNeeded: guildID >> UInt64($0 * 8))
            }
        }
        let guildIDs = field(1, payload: fixedGuildIDs)
        let folderID = field(2, payload: encodeProtoVarint(1 << 3) + encodeProtoVarint(42))
        let name = field(3, payload: field(1, payload: Array("Work".utf8)))
        let color = field(4, payload: encodeProtoVarint(1 << 3) + encodeProtoVarint(0x58_65_F2))
        return Data(field(14, payload: field(1, payload: guildIDs + folderID + name + color)))
    }

    private static func commandIndexJSON(guildID: String?) -> String {
        let guild = guildID.map { ",\"guild_id\":\"\($0)\"" } ?? ""
        return "{\"version\":\"903\",\"applications\":[{\"id\":\"900\",\"name\":\"Utility\"}],"
            + "\"application_commands\":[{\"id\":\"901\",\"application_id\":\"900\"\(guild),"
            + "\"version\":\"902\",\"type\":1,\"name\":\"search\",\"description\":\"Search\","
            + "\"contexts\":[0,1,2],\"options\":[{\"type\":3,\"name\":\"query\","
            + "\"description\":\"Query\",\"required\":true,\"autocomplete\":true}]}]}"
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let data = request.httpBody {
            return data
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
