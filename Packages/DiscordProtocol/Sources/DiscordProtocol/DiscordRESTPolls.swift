import Foundation
import SakuraCordModels

public extension DiscordRESTProvider {
    func setPollAnswers(_ answerIDs: [Int], messageID: MessageID, channelID: ChannelID) async throws {
        if !answerIDs.isEmpty { try requireGuildCommunication(in: channelID) }
        guard answerIDs.count <= 10, Set(answerIDs).count == answerIDs.count, answerIDs.allSatisfy({ $0 > 0 }) else {
            throw ChatProviderError.invalidRequest("Choose valid poll answers.")
        }
        if let poll = cachedMessages[messageID]?.poll {
            guard !poll.isClosed(), poll.layoutType == 1 else { throw ChatProviderError.invalidRequest("This poll is closed or unavailable.") }
            guard poll.allowsMultipleAnswers || answerIDs.count <= 1, answerIDs.allSatisfy({ id in poll.answers.contains { $0.id == id } }) else {
                throw ChatProviderError.invalidRequest("Choose valid poll answers.")
            }
        }
        try await requestEmpty("/channels/\(channelID)/polls/\(messageID)/answers/@me", method: "PUT",
                               body: ["answer_ids": .array(answerIDs.map { .string(String($0)) })])
    }

    func pollVoters(messageID: MessageID, channelID: ChannelID, answerID: Int, after: UserID?, limit: Int) async throws -> MessagePeoplePage {
        guard answerID > 0 else { throw ChatProviderError.invalidRequest("Choose a valid poll answer.") }
        let limit = min(100, max(1, limit))
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let after { query.append(URLQueryItem(name: "after", value: after.description)) }
        query.append(URLQueryItem(name: "type", value: "2"))
        struct Response: Decodable { var users: [UserDTO] }
        let response: Response = try await request("/channels/\(channelID)/polls/\(messageID)/answers/\(answerID)", query: query)
        return MessagePeoplePage(users: try response.users.map { try $0.domain() }, hasMore: response.users.count == limit)
    }

    func endPoll(messageID: MessageID, channelID: ChannelID) async throws -> Message {
        if let message = cachedMessages[messageID] {
            guard message.author.id == currentUser?.id, message.poll?.isClosed() == false else {
                throw ChatProviderError.invalidRequest("Only the author can end an active poll.")
            }
        }
        let dto: MessageDTO = try await request("/channels/\(channelID)/polls/\(messageID)/expire", method: "POST")
        var message = try dto.domain()
        // A final Gateway tally can arrive while the expire response is being decoded.
        if let cached = cachedMessages[messageID]?.poll, cached.results?.isFinalized == true {
            message.poll = cached
        }
        cachedMessages[message.id] = message
        continuation?.yield(.messageUpdated(message))
        return message
    }

    internal func handlePollVoteDispatch(name: String, body: JSONValue) {
        let messageID: MessageID
        let channelID: ChannelID
        let operations: [MessagePollUpdate]
        if name == "MESSAGE_POLL_VOTE_ADD_MANY" {
            guard let dto = try? JSONValueDecoder().decode(DiscordPollVoteBatchDTO.self, from: body),
                  let message = MessageID(dto.messageID), let channel = ChannelID(dto.channelID) else { return }
            messageID = message
            channelID = channel
            operations = dto.votes.flatMap { vote in
                vote.users.map { .vote(answerID: vote.answerID, isAddition: true, isCurrentUser: $0 == currentUser?.id.description) }
            }
        } else {
            guard let dto = try? JSONValueDecoder().decode(DiscordPollVoteDTO.self, from: body),
                  let message = MessageID(dto.messageID), let channel = ChannelID(dto.channelID) else { return }
            messageID = message
            channelID = channel
            operations = [.vote(answerID: dto.answerID, isAddition: name == "MESSAGE_POLL_VOTE_ADD", isCurrentUser: dto.userID == currentUser?.id.description)]
        }
        var update = MessageUpdate(messageID: messageID, channelID: channelID)
        update.pollUpdates = operations
        if var message = cachedMessages[messageID] {
            update.apply(to: &message)
            cachedMessages[messageID] = message
            updateForumPostForMessage(message, publishesChange: false)
        } else if let post = cachedForumPosts.values.lazy.compactMap({ $0[channelID] }).first,
                  var message = [post.firstMessage, post.mostRecentMessage].compactMap({ $0 }).first(where: { $0.id == messageID }) {
            update.apply(to: &message)
            updateForumPostForMessage(message, publishesChange: false)
        }
        continuation?.yield(.messagePatched(update))
    }
}
