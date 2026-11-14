import Foundation
import SakuraCordModels
import Testing
import Synchronization
@testable import DiscordProtocol

struct PollContractTests {
    @Test(arguments: [false, true])
    func `poll expiry fails once without stopping subsequent requests`(ending: Bool) async throws {
        let capture = PollRequestCapture()
        let provider = makeProvider(accountID: capture.id)
        await #expect(throws: ChatProviderError.self) {
            if ending {
                _ = try await provider.endPoll(messageID: .init(rawValue: 998), channelID: .init(rawValue: 200))
            } else {
                try await provider.setPollAnswers([1], messageID: .init(rawValue: 998), channelID: .init(rawValue: 200))
            }
        }
        #expect(capture.requests.count == 1)
        #expect(await !provider.requestSafetyCircuitIsOpen)
        try await provider.setPollAnswers([1], messageID: .init(rawValue: 300), channelID: .init(rawValue: 200))
        #expect(capture.requests.count == 2)
        await provider.disconnect()
    }

    @Test func `poll creation and voting match fresh official desktop captures`() async throws {
        let capture = PollRequestCapture()
        let provider = makeProvider(accountID: capture.id)
        let draft = PollDraft(question: "A question 🌸", answers: [
            .init(id: 1, text: "Україна", emoji: .init(rawToken: "✅")),
            .init(id: 2, text: "日本語", emoji: .init(rawToken: "<:flower:55>")),
        ], durationHours: 1, allowsMultipleAnswers: true)
        let message = try await provider.send(SendMessageDraft(channelID: .init(rawValue: 200), content: "", poll: draft))
        #expect(message.poll?.question == "A question 🌸")
        let request = try #require(capture.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v9/channels/200/messages")
        #expect(request.context == Data(#"{"location":"poll_creation"}"#.utf8).base64EncodedString())
        #expect(Set(request.body.keys) == ["content", "nonce", "tts", "flags", "mobile_network_type", "poll"])
        let poll = try #require(request.body["poll"] as? [String: Any])
        #expect(poll["duration"] as? Int == 1)
        #expect(poll["allow_multiselect"] as? Bool == true)
        let answers = try #require(poll["answers"] as? [[String: [String: Any]]])
        #expect((answers[0]["poll_media"]?["emoji"] as? [String: String]) == ["name": "✅"])
        #expect((answers[1]["poll_media"]?["emoji"] as? [String: String]) == ["id": "55", "name": ""])
        try await provider.setPollAnswers([1, 2], messageID: .init(rawValue: 300), channelID: .init(rawValue: 200))
        try await provider.setPollAnswers([], messageID: .init(rawValue: 300), channelID: .init(rawValue: 200))
        #expect(capture.requests[1].method == "PUT")
        #expect(capture.requests[1].path == "/api/v9/channels/200/polls/300/answers/@me")
        #expect(capture.requests[1].body["answer_ids"] as? [String] == ["1", "2"])
        #expect(capture.requests[2].body["answer_ids"] as? [String] == [])
        await provider.disconnect()
    }

    @Test func `voter pagination and ending use captured routes without mutation retries`() async throws {
        let capture = PollRequestCapture()
        let provider = makeProvider(accountID: capture.id)
        let voters = try await provider.pollVoters(messageID: .init(rawValue: 300), channelID: .init(rawValue: 200),
                                                    answerID: 2, after: .init(rawValue: 9), limit: 100)
        #expect(voters.users.first?.username == "tester")
        #expect(!voters.hasMore)
        #expect(capture.requests[0].path == "/api/v9/channels/200/polls/300/answers/2")
        #expect(capture.requests[0].query == ["limit": "100", "type": "2", "after": "9"])
        _ = try await provider.endPoll(messageID: .init(rawValue: 300), channelID: .init(rawValue: 200))
        #expect(capture.requests[1].method == "POST")
        #expect(capture.requests[1].path.hasSuffix("/polls/300/expire"))
        #expect(capture.requests[1].body.isEmpty)
        let previousCount = capture.requests.count
        await #expect(throws: ChatProviderError.self) {
            try await provider.setPollAnswers([1], messageID: .init(rawValue: 999), channelID: .init(rawValue: 200))
        }
        #expect(capture.requests.count == previousCount + 1)
        await provider.disconnect()
    }

    @Test func `sparse finalization preserves personal vote and survives ordered coalescing`() throws {
        var message = try JSONDecoder().decode(MessageDTO.self, from: Data(PollURLProtocol.message.utf8)).domain()
        var delta = MessageUpdate(messageID: message.id, channelID: message.channelID)
        delta.pollUpdates = [.vote(answerID: 2, isAddition: true, isCurrentUser: true)]
        delta.apply(to: &message)
        #expect(message.poll?.selectedAnswerIDs == [2])
        #expect(message.poll?.totalVotes == 1)
        let sparse = #"""
        {
          "id": "300",
          "channel_id": "200",
          "poll": {
            "question": {
              "text": "A question 🌸"
            },
            "answers": [
              {
                "answer_id": 1,
                "poll_media": {
                  "text": "One"
                }
              },
              {
                "answer_id": 2,
                "poll_media": {
                  "text": "Two"
                }
              }
            ],
            "expiry": "2026-09-19T00:00:00Z",
            "allow_multiselect": true,
            "layout_type": 1
          }
        }
        """#
        let end = try #require(JSONDecoder().decode(MessageUpdateDTO.self, from: Data(sparse.utf8)).domain(guildID: nil))
        var ordered = delta
        ordered.merge(end)
        var coalesced = try JSONDecoder().decode(MessageDTO.self, from: Data(PollURLProtocol.message.utf8)).domain()
        ordered.apply(to: &coalesced)
        end.apply(to: &message)
        #expect(coalesced.poll == message.poll)
        #expect(message.poll?.totalVotes == 1)
        #expect(message.poll?.isClosed() == true)
        var final = try #require(message.poll)
        final.results = PollResults(isFinalized: true, answerCounts: [.init(id: 1, count: 0), .init(id: 2, count: 1)])
        var update = MessageUpdate(messageID: message.id, channelID: message.channelID)
        update.pollUpdates = [.snapshot(final, preservingSelection: true)]
        update.apply(to: &message)
        #expect(message.poll?.selectedAnswerIDs == [2])
        end.apply(to: &message)
        #expect(message.poll?.results?.isFinalized == true)
        #expect(message.poll?.totalVotes == 1)
        let roundtrip = try JSONDecoder().decode(Message.self, from: JSONEncoder().encode(message))
        #expect(roundtrip.poll == message.poll)
    }

    @Test func `unknown results and partial multi choice changes retain valid tallies`() throws {
        var poll = MessagePoll(question: "Test", answers: [.init(id: 1, text: "One"), .init(id: 2, text: "Two")], expiry: nil, allowsMultipleAnswers: true)
        #expect(poll.results == nil)
        poll.applyVote(answerID: 1, isAddition: true, isCurrentUser: false)
        #expect(poll.results == nil)
        poll.results = PollResults()
        poll.applyVote(answerID: 1, isAddition: true, isCurrentUser: true)
        poll.applyVote(answerID: 1, isAddition: true, isCurrentUser: true)
        #expect(poll.count(for: 1) == 1)
        poll.applyVote(answerID: 2, isAddition: true, isCurrentUser: true)
        poll.applyVote(answerID: 1, isAddition: false, isCurrentUser: true)
        poll.applyVote(answerID: 1, isAddition: false, isCurrentUser: false)
        poll.applyVote(answerID: 99, isAddition: true, isCurrentUser: false)
        #expect(poll.count(for: 1) == 0)
        #expect(poll.totalVotes == 1)
        #expect(poll.selectedAnswerIDs == [2])
    }

    @Test func `gateway vote batches and individual changes reconcile the same cached poll`() async throws {
        let provider = makeProvider()
        let message = try JSONDecoder().decode(MessageDTO.self, from: Data(PollURLProtocol.message.utf8)).domain()
        await provider.seedPrivateChannelsForTesting([], currentUser: message.author)
        await provider.seedMessageForTesting(message)
        await provider.receiveGatewayDispatchForTesting(name: "MESSAGE_POLL_VOTE_ADD_MANY", data: .object([
            "channel_id": .string("200"), "message_id": .string("300"),
            "votes": .array([
                .object(["answer_id": .number(1), "users": .array([.string("1"), .string("2")])]),
                .object(["answer_id": .number(2), "users": .array([.string("1")])]),
            ]),
        ]))
        var poll = await provider.cachedMessageForTesting(messageID: message.id)?.poll
        #expect(poll?.totalVotes == 3)
        #expect(poll?.selectedAnswerIDs == [1, 2])
        await provider.receiveGatewayDispatchForTesting(name: "MESSAGE_POLL_VOTE_REMOVE", data: .object([
            "channel_id": .string("200"), "message_id": .string("300"),
            "answer_id": .number(1), "user_id": .string("1"),
        ]))
        poll = await provider.cachedMessageForTesting(messageID: message.id)?.poll
        #expect(poll?.count(for: 1) == 1)
        #expect(poll?.selectedAnswerIDs == [2])
        await provider.disconnect()
    }

    @Test func `creation limits use UTF16 and omit empty answer rows without allowing emoji only answers`() {
        var draft = PollDraft(question: String(repeating: "🌸", count: 150), answers: [
            .init(id: 1, text: " One "), .init(id: 2, text: "Two"), .init(id: 3, text: " "),
        ])
        #expect(draft.validationError == nil)
        #expect(draft.preview().answers.map(\.text) == ["One", "Two"])
        draft.question += "a"
        #expect(draft.validationError != nil)
        draft.question = "Test"
        draft.answers[2].emoji = .init(rawToken: "✅")
        #expect(draft.validationError != nil)
        draft.answers.removeLast()
        draft.answers[1].text = String(repeating: "a", count: 55)
        #expect(draft.validationError == nil)
        draft.answers[1].text += "b"
        #expect(draft.validationError != nil)
        draft.answers = [.init(id: 1, text: "Only")]
        #expect(draft.validationError == nil)
        draft.answers[0].text = " "
        #expect(draft.validationError != nil)
    }

    private func makeProvider(accountID: String = UUID().uuidString) -> DiscordRESTProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PollURLProtocol.self]
        return DiscordRESTProvider(credentials: PollCredentialStore(), handle: CredentialHandle(accountID: accountID), session: URLSession(configuration: configuration))
    }
}

private actor PollCredentialStore: CredentialStore {
    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle { .init(accountID: accountID) }
    func credential(for handle: CredentialHandle) async throws -> Data { Data(handle.accountID.utf8) }
    func remove(_ handle: CredentialHandle) async throws {}
    func handles() async throws -> [CredentialHandle] { [] }
}

/// Every test owns its recorder; the stateless URL protocol only publishes the
/// materialized request. Unique synthetic credentials isolate concurrent tests.
private final class PollRequestCapture {
    let id = UUID().uuidString
    private let storage: Storage
    private let observer: any NSObjectProtocol

    private final class Storage: Sendable {
        let requests = Mutex<[URLRequest]>([])
    }

    struct Capture {
        let method: String
        let path: String
        let context: String?
        let body: [String: Any]
        let query: [String: String]
    }

    init() {
        let storage = Storage()
        self.storage = storage
        let id = id
        observer = NotificationCenter.default.addObserver(forName: PollURLProtocol.capturedRequest, object: nil, queue: nil) { notification in
            guard let request = notification.object as? URLRequest, request.value(forHTTPHeaderField: "Authorization") == id else { return }
            storage.requests.withLock { $0.append(request) }
        }
    }

    deinit { NotificationCenter.default.removeObserver(observer) }

    var requests: [Capture] {
        storage.requests.withLock { $0 }.map { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            return Capture(method: request.httpMethod ?? "", path: components.path,
                           context: request.value(forHTTPHeaderField: "X-Context-Properties"),
                           body: (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:],
                           query: Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }))
        }
    }
}

private final class PollURLProtocol: URLProtocol, @unchecked Sendable {
    static let capturedRequest = Notification.Name("PollContractCapturedRequest")
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let data = request.bodyData ?? Data()
        var captured = request
        captured.httpBody = data
        NotificationCenter.default.post(name: Self.capturedRequest, object: captured)
        let status = components.path.contains("/polls/998/") ? 400 : components.path.contains("/polls/999/") ? 429 : request.httpMethod == "PUT" ? 204 : 200
        let body: String
        switch status {
        case 400: body = #"{"code":520001,"message":"Poll expired"}"#
        case 429: body = #"{"retry_after":0.01,"global":false}"#
        default: body = request.httpMethod == "GET" ? #"{"users":[{"id":"10","username":"tester"}]}"# : Self.message
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if status != 204 { client?.urlProtocol(self, didLoad: Data(body.utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static let message = #"""
        {
          "id": "300",
          "channel_id": "200",
          "author": {
            "id": "1",
            "username": "tester"
          },
          "content": "",
          "timestamp": "2026-09-19T00:00:00Z",
          "poll": {
            "question": {
              "text": "A question 🌸"
            },
            "answers": [
              {
                "answer_id": 1,
                "poll_media": {
                  "text": "One"
                }
              },
              {
                "answer_id": 2,
                "poll_media": {
                  "text": "Two"
                }
              }
            ],
            "expiry": "2030-09-19T00:00:00Z",
            "allow_multiselect": true,
            "layout_type": 1,
            "results": {
              "answer_counts": [],
              "is_finalized": false
            }
          }
        }
        """#
}
