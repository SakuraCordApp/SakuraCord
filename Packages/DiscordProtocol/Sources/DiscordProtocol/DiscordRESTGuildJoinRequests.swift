import Foundation
import SakuraCordModels

/// Apply-to-join servers, from the applicant's side; see docs/protocol/GUILDS.md, Join applications.
public extension DiscordRESTProvider {
    func guildJoinApplicationForm(_ guildID: GuildID, inviteCode: String?) async throws -> GuildJoinApplicationForm {
        var query = [URLQueryItem(name: "with_guild", value: "true")]
        if let inviteCode { query.append(URLQueryItem(name: "invite_code", value: inviteCode)) }
        let (data, response) = try await perform("/guilds/\(guildID)/member-verification", method: "GET", query: query, body: nil)
        try checkJoinRequestResponse(data, response)
        let form = try JSONDecoder().decode(MemberVerificationFormDTO.self, from: data)
        guard form.guild.map({ $0.id == guildID.description }) ?? true else {
            throw ServerInviteError.failed("Discord returned the application for a different server. Try again.")
        }
        let domain = try form.domain(guildID: guildID)
        // Submission echoes each field exactly as Discord sent it, plus the answer.
        cachedJoinApplicationForms[guildID] = .init(version: form.version, fields: form.formFields,
                                                     questions: domain.fields.map(\.question))
        return domain
    }

    /// `fields` are the loaded form's fields with their answers, in the same order.
    func submitGuildJoinApplication(_ guildID: GuildID, fields: [GuildJoinApplicationField]) async throws {
        // A later read of the form, such as the status page's, may hold questions the editor never showed.
        guard let cached = cachedJoinApplicationForms[guildID], cached.questions == fields.map(\.question) else {
            throw ServerInviteError.failed("This application changed. Reopen it and try again.")
        }
        let answered: [JSONValue] = zip(cached.fields, fields).map { wire, field in
            guard case var .object(object) = wire, let answer = field.answer else { return wire }
            object["response"] = switch answer {
            case .text(let text): .string(text)
            case .choice(let index): .number(Double(index))
            case .agreed(let agreed): .bool(agreed)
            }
            return .object(object)
        }
        let startedFrom = cachedGuildJoinRequests[guildID]?.id
        let (data, response) = try await perform(
            "/guilds/\(guildID)/requests/@me", method: "PUT", query: [],
            body: ["version": .string(cached.version), "form_fields": .array(answered)], maximumAttempts: 1
        )
        try checkJoinRequestResponse(data, response)
        try applyJoinRequestResponse(data, startedFrom: startedFrom)
    }

    /// Starts a new application after a rejection.
    func reapplyToGuild(_ guildID: GuildID) async throws {
        let startedFrom = cachedGuildJoinRequests[guildID]?.id
        let (data, response) = try await perform("/guilds/\(guildID)/requests/@me", method: "POST", query: [], body: nil,
                                                 maximumAttempts: 1)
        try checkJoinRequestResponse(data, response)
        try applyJoinRequestResponse(data, startedFrom: startedFrom)
    }

    func withdrawGuildJoinRequest(_ guildID: GuildID) async throws {
        let startedFrom = cachedGuildJoinRequests[guildID]?.id
        let (data, response) = try await perform("/guilds/\(guildID)/requests/@me", method: "DELETE", query: [], body: nil,
                                                 maximumAttempts: 1)
        try checkJoinRequestResponse(data, response)
        // GUILD_JOIN_REQUEST_DELETE normally arrives first; a lost event must not leave the request shown.
        // A newer application made elsewhere meanwhile is not the one withdrawn.
        guard let startedFrom, cachedGuildJoinRequests[guildID]?.id == startedFrom else { return }
        cachedGuildJoinRequests[guildID] = nil
        publishGuildJoinRequests()
    }

    /// Records that the applicant saw an approval, so Discord stops reporting it.
    func acknowledgeGuildJoinRequest(_ request: GuildJoinRequest) async throws {
        let (data, response) = try await perform("/guilds/\(request.guildID)/requests/\(request.id)/ack", method: "POST",
                                                 query: [], body: nil, maximumAttempts: 1)
        try checkJoinRequestResponse(data, response)
        if cachedGuildJoinRequests[request.guildID]?.id == request.id {
            cachedGuildJoinRequests[request.guildID]?.isAcknowledged = true
            publishGuildJoinRequests()
        }
    }

    /// Name and icon of the servers the account has applied to, which are not in its guild list.
    func guildJoinRequestGuilds() async throws -> [GuildJoinRequestGuild] {
        let (data, response) = try await perform("/users/@me/join-request-guilds", method: "GET", query: [], body: nil)
        try checkJoinRequestResponse(data, response)
        return try JSONDecoder().decode([PartialGuildDTO].self, from: data).compactMap { $0.domain() }
    }

    /// The submitted answers of one of the account's applications.
    func guildJoinRequestAnswers(_ requestID: JoinRequestID) async throws -> [GuildJoinApplicationField] {
        let (data, response) = try await perform("/join-requests/\(requestID)", method: "GET", query: [], body: nil)
        try checkJoinRequestResponse(data, response)
        struct Request: Decodable {
            var formResponses: [MemberVerificationFieldDTO]?
            enum CodingKeys: String, CodingKey { case formResponses = "form_responses" }
        }
        return try JSONDecoder().decode(Request.self, from: data).formResponses?.map { $0.domain() } ?? []
    }
}

extension DiscordRESTProvider {
    func handleGuildJoinRequestDispatch(name: String, body: JSONValue) {
        guard let currentUserID = currentUser?.id.description else { return }
        if name == "GUILD_JOIN_REQUEST_DELETE" {
            guard let deleted = try? JSONValueDecoder().decode(GuildJoinRequestDeleteDTO.self, from: body),
                  deleted.userId == currentUserID, let guildID = GuildID(deleted.guildId),
                  cachedGuildJoinRequests[guildID]?.id.description == deleted.id else { return }
            cachedGuildJoinRequests[guildID] = nil
        } else {
            // Moderators also receive other people's requests; the official applicant store ignores them.
            guard let event = try? JSONValueDecoder().decode(GuildJoinRequestEventDTO.self, from: body),
                  event.request.userId == currentUserID, let request = event.request.domain() else { return }
            cachedGuildJoinRequests[request.guildID] = request
        }
        publishGuildJoinRequests()
    }

    func applyReadyGuildJoinRequests(_ body: JSONValue) {
        let requests = (try? JSONValueDecoder().decode(GuildJoinRequestsReadyDTO.self, from: body))?.guildJoinRequests ?? []
        cachedGuildJoinRequests = Dictionary(requests.compactMap { $0.domain() }.map { ($0.guildID, $0) }) { $1 }
        publishGuildJoinRequests()
    }

    func publishGuildJoinRequests() {
        continuation?.yield(.guildJoinRequestsChanged(Array(cachedGuildJoinRequests.values)))
    }

    /// The Gateway event usually precedes the response, and a review, withdrawal or another client's application
    /// can follow it before the response arrives. The reply therefore applies only while the cached request is
    /// still the one the write started from, and a submission only while that request is still STARTED.
    private func applyJoinRequestResponse(_ data: Data, startedFrom: JoinRequestID?) throws {
        guard let request = try JSONDecoder().decode(GuildJoinRequestDTO.self, from: data).domain() else { return }
        let cached = cachedGuildJoinRequests[request.guildID]
        guard cached?.id == startedFrom, cached?.id != request.id || cached?.status == .started else { return }
        cachedGuildJoinRequests[request.guildID] = request
        publishGuildJoinRequests()
    }

    private func checkJoinRequestResponse(_ data: Data, _ response: HTTPURLResponse) throws {
        guard !(200 ..< 300).contains(response.statusCode) else { return }
        switch (response.statusCode, Self.discordErrorCode(from: data)) {
        case (_, 150_023): throw ServerInviteError.failed("You’re not eligible to join this server.")
        case (429, _): throw ServerInviteError.failed("You’re sending applications too quickly. Wait a moment, then try again.")
        case (403, _): throw ServerInviteError.failed("You don’t have permission to join this server.")
        default: try checkInviteResponse(data, response)
        }
    }
}

private struct MemberVerificationFormDTO: Decodable {
    var version: String
    var formFields: [JSONValue]
    var guild: Guild?
    var profile: Profile?

    struct Guild: Decodable {
        var id: String
        var name: String
        var icon: String?
        var description: String?
        var approximateMemberCount: Int?
        var approximatePresenceCount: Int?
        enum CodingKeys: String, CodingKey {
            case id, name, icon, description
            case approximateMemberCount = "approximate_member_count"
            case approximatePresenceCount = "approximate_presence_count"
        }
    }

    struct Profile: Decodable {
        var name: String?
        var iconHash: String?
        var description: String?
        enum CodingKeys: String, CodingKey { case name, description, iconHash = "icon_hash" }
    }

    enum CodingKeys: String, CodingKey { case version, guild, profile, formFields = "form_fields" }

    func domain(guildID: GuildID) throws -> GuildJoinApplicationForm {
        let fields = try formFields.map { try JSONValueDecoder().decode(MemberVerificationFieldDTO.self, from: $0).domain() }
        let icon = profile?.iconHash ?? guild?.icon
        return GuildJoinApplicationForm(
            guildID: guildID, guildName: profile?.name ?? guild?.name,
            iconURL: icon.flatMap { URL(string: "https://cdn.discordapp.com/icons/\(guildID)/\($0).webp?size=128") },
            description: profile?.description ?? guild?.description,
            memberCount: guild?.approximateMemberCount, onlineCount: guild?.approximatePresenceCount, fields: fields
        )
    }
}

private struct MemberVerificationFieldDTO: Decodable {
    var fieldType: String
    var label: String
    var description: String?
    var placeholder: String?
    var required: Bool?
    var choices: [String]?
    var values: [String]?
    var response: JSONValue?

    enum CodingKeys: String, CodingKey {
        case label, description, placeholder, required, choices, values, response
        case fieldType = "field_type"
    }

    func domain() -> GuildJoinApplicationField {
        let kind: GuildJoinApplicationField.Kind = switch fieldType {
        case "TEXT_INPUT": .shortAnswer
        case "PARAGRAPH": .paragraph
        case "MULTIPLE_CHOICE": .multipleChoice(choices ?? [])
        case "TERMS": .terms(values ?? [])
        default: .unsupported(fieldType)
        }
        let answer: GuildJoinApplicationAnswer? = switch response {
        case .string(let text)?: .text(text)
        case .number(let index)?: .choice(Int(index))
        case .bool(let agreed)?: .agreed(agreed)
        default: nil
        }
        return GuildJoinApplicationField(kind: kind, label: label, description: description, placeholder: placeholder,
                                         isRequired: required ?? false, answer: answer)
    }
}

private struct GuildJoinRequestDTO: Decodable {
    var id: String
    var guildId: String
    var userId: String
    var applicationStatus: String
    var rejectionReason: String?
    var interviewChannelId: String?
    var lastSeen: String?

    enum CodingKeys: String, CodingKey {
        case id
        case guildId = "guild_id"
        case userId = "user_id"
        case applicationStatus = "application_status"
        case rejectionReason = "rejection_reason"
        case interviewChannelId = "interview_channel_id"
        case lastSeen = "last_seen"
    }

    func domain() -> GuildJoinRequest? {
        guard let id = JoinRequestID(id), let guildID = GuildID(guildId) else { return nil }
        return GuildJoinRequest(id: id, guildID: guildID, status: .init(applicationStatus), rejectionReason: rejectionReason,
                                interviewChannelID: interviewChannelId.flatMap(ChannelID.init), isAcknowledged: lastSeen != nil)
    }
}

private struct GuildJoinRequestEventDTO: Decodable {
    var request: GuildJoinRequestDTO
}

private struct GuildJoinRequestDeleteDTO: Decodable {
    var id: String
    var guildId: String
    var userId: String
    enum CodingKeys: String, CodingKey { case id, guildId = "guild_id", userId = "user_id" }
}

private struct GuildJoinRequestsReadyDTO: Decodable {
    var guildJoinRequests: [GuildJoinRequestDTO]?
    enum CodingKeys: String, CodingKey { case guildJoinRequests = "guild_join_requests" }
}

private struct PartialGuildDTO: Decodable {
    var id: String
    var name: String
    var icon: String?

    func domain() -> GuildJoinRequestGuild? {
        guard let guildID = GuildID(id) else { return nil }
        return GuildJoinRequestGuild(id: guildID, name: name,
            iconURL: icon.flatMap { URL(string: "https://cdn.discordapp.com/icons/\(guildID)/\($0).webp?size=128") })
    }
}

/// An application form as Discord sent it, and the questions it asks.
struct LoadedJoinApplicationForm {
    var version: String
    var fields: [JSONValue]
    var questions: [GuildJoinApplicationField]
}

private extension GuildJoinApplicationField {
    var question: Self {
        var question = self
        question.answer = nil
        return question
    }
}
