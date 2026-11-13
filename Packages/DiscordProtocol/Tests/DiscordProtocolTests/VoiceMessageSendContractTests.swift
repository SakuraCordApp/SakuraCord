@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Synchronization
import Testing

struct VoiceMessageSendContractTests {
    @Test func `voice message reserves, uploads, and posts Discord's recorder contract`() async throws {
        let fixture = VoiceMessageSendFixture()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = directory.appending(path: "recording.ogg")
        let bytes = Data("OggS voice bytes".utf8)
        try bytes.write(to: recording)
        let metadata = VoiceMessageMetadata(durationSeconds: 8, waveform: "AAEC")
        let draft = SendMessageDraft(
            channelID: ChannelID(rawValue: 200),
            content: "",
            attachments: [ForumPostAttachment(url: recording, filename: "recording.ogg")],
            voiceMessage: metadata
        )

        let message = try await fixture.provider().send(draft)

        let requests = fixture.requests
        #expect(requests.map(\.method) == ["POST", "PUT", "POST"])
        let reservation = try #require(requests.first?.json?["files"] as? [[String: Any]])
        #expect(reservation.count == 1)
        #expect(reservation.first?["filename"] as? String == "0recording.ogg")
        #expect(reservation.first?["original_content_type"] as? String == "audio/ogg")
        #expect(reservation.first?["file_size"] as? Int == bytes.count)

        #expect(requests[1].path == "/voice")
        #expect(requests[1].contentType == "application/octet-stream")
        #expect(requests[1].body == bytes)

        let body = try #require(requests[2].json)
        #expect(body["flags"] as? Int == 8192)
        #expect(body["content"] as? String == "")
        #expect(requests[2].context == #"{"location":"voice_message"}"#)
        let attachment = try #require((body["attachments"] as? [[String: Any]])?.first)
        #expect(attachment["filename"] as? String == "0recording.ogg")
        #expect(attachment["original_content_type"] as? String == "audio/ogg")
        #expect(attachment["uploaded_filename"] as? String == "slot/voice-message.ogg")
        #expect(attachment["duration_secs"] as? Double == 8)
        #expect(attachment["waveform"] as? String == "AAEC")
        #expect(attachment["content_type"] == nil)

        #expect(message.flags.contains(.voiceMessage))
        #expect(message.attachments.first?.durationSeconds == 8.020000457763672)
        #expect(message.attachments.first?.waveform == "AAEC")
    }

    @Test func `voice message refuses accompanying text`() async throws {
        let fixture = VoiceMessageSendFixture()
        let draft = SendMessageDraft(
            channelID: ChannelID(rawValue: 200),
            content: "caption",
            attachmentURLs: [URL(filePath: "/tmp/voice-message.ogg")],
            voiceMessage: VoiceMessageMetadata(durationSeconds: 1, waveform: "AA==")
        )
        await #expect(throws: ChatProviderError.self) {
            try await fixture.provider().send(draft)
        }
        #expect(fixture.requests.isEmpty)
    }
}

/// Owns one test's requests. The URL protocol routes each request here by the
/// session's fixture header, so concurrent tests never share state.
private final class VoiceMessageSendFixture {
    struct Request: Sendable {
        let method: String
        let path: String
        let contentType: String?
        let context: String?
        let body: Data

        var json: [String: Any]? {
            try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
    }

    private final class Storage: Sendable {
        let requests = Mutex<[Request]>([])
    }

    private let storage = Storage()
    let id = UUID().uuidString
    private var observer: NSObjectProtocol?

    init() {
        let id = id
        observer = NotificationCenter.default.addObserver(
            forName: VoiceMessageSendURLProtocol.received, object: nil, queue: nil
        ) { [storage] note in
            guard let exchange = note.object as? VoiceMessageSendURLProtocol.Exchange,
                  exchange.fixtureID == id
            else { return }
            storage.requests.withLock { $0.append(exchange.request) }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var requests: [Request] { storage.requests.withLock { $0 } }

    func provider() -> DiscordRESTProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceMessageSendURLProtocol.self]
        configuration.httpAdditionalHeaders = [VoiceMessageSendURLProtocol.fixtureHeader: id]
        return DiscordRESTProvider(
            credentials: TestCredentialStore(), handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration)
        )
    }
}

private final class VoiceMessageSendURLProtocol: URLProtocol, @unchecked Sendable {
    static let received = Notification.Name("VoiceMessageSendContract.request")
    static let fixtureHeader = "X-Voice-Message-Send-Test"

    final class Exchange: Sendable {
        let fixtureID: String?
        let request: VoiceMessageSendFixture.Request

        init(fixtureID: String?, request: VoiceMessageSendFixture.Request) {
            self.fixtureID = fixtureID
            self.request = request
        }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let method = request.httpMethod ?? "GET"
        let body = Self.requestBody(request) ?? Data()
        NotificationCenter.default.post(
            name: Self.received,
            object: Exchange(
                fixtureID: request.value(forHTTPHeaderField: Self.fixtureHeader),
                request: .init(
                    method: method,
                    path: url.path,
                    contentType: request.value(forHTTPHeaderField: "Content-Type"),
                    context: request.value(forHTTPHeaderField: "X-Context-Properties")
                        .flatMap { Data(base64Encoded: $0) }.flatMap { String(bytes: $0, encoding: .utf8) },
                    body: body
                )
            )
        )
        let data: Data = if method == "PUT" {
            Data()
        } else if url.path.hasSuffix("/attachments") {
            Data(#"{"attachments":[{"id":0,"upload_url":"https://upload.example/voice","upload_filename":"slot/voice-message.ogg"}]}"#.utf8)
        } else {
            Data("""
            {"id":"50","channel_id":"200","author":{"id":"1","username":"tester","global_name":"Tester","avatar":null},
            "content":"","timestamp":"2026-10-09T12:00:00.000Z","edited_timestamp":null,"type":0,"flags":8192,
            "attachments":[{"id":"60","filename":"voice-message.ogg","size":16,"content_type":"audio/ogg",
            "url":"https://cdn.discordapp.com/attachments/200/60/voice-message.ogg",
            "proxy_url":"https://media.discordapp.net/attachments/200/60/voice-message.ogg",
            "duration_secs":8.020000457763672,"waveform":"AAEC"}],"reactions":[]}
            """.utf8)
        }
        guard let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
