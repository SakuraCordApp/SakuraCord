@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Synchronization
import Testing

/// A file the user stops must never reach the message, stopping every file
/// must not post the message at all, and a file already in the message being
/// posted must not be reported as stopped.
struct UploadCancellationContractTests {
    @Test(arguments: [false, true])
    func stoppedFilesLeaveTheMessage(stopsEveryFile: Bool) async throws {
        let fixture = HeldStorageFixture()
        let directory = try fixture.directory(containing: ["kept.bin", "stopped.bin"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ["kept.bin", "stopped.bin"].map {
            AttachmentUploadFile(url: directory.appending(path: $0), name: $0, id: UUID())
        }
        let provider = fixture.provider(holdsEveryUpload: stopsEveryFile)
        let upload = Task {
            try await provider.uploadAttachmentFiles(files, channelID: ChannelID(rawValue: 200), progress: { _ in })
        }
        let expectedHeld = stopsEveryFile ? 2 : 1
        #expect(await eventually { fixture.events.held == expectedHeld })
        for file in stopsEveryFile ? files : [files[1]] {
            #expect(await provider.cancelAttachmentUpload(try #require(file.id)))
        }
        if stopsEveryFile {
            await #expect(throws: CancellationError.self) { try await upload.value }
        } else {
            let uploaded = try await upload.value
            #expect(uploaded.count == 1)
            guard case let .object(payload) = uploaded.first else { Issue.record("Missing kept attachment"); return }
            #expect(payload["filename"] == .string("kept.bin"))
            #expect(payload["uploaded_filename"] == .string("kept-upload"))
        }
        // URLSession stops the protocol after it completes the cancelled task.
        #expect(await eventually { fixture.events.stopped == expectedHeld })
    }

    /// A file stopped while its message waits for its turn may already be
    /// deleted, so the send must neither read nor reserve it.
    @Test func fileStoppedBeforeItsTurnIsNeverRead() async throws {
        let fixture = HeldStorageFixture()
        let directory = try fixture.directory(containing: ["kept.bin"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ["kept.bin", "stopped.bin"].map {
            AttachmentUploadFile(url: directory.appending(path: $0), name: $0, id: UUID())
        }
        let provider = fixture.provider(holdsEveryUpload: false)
        #expect(await provider.cancelAttachmentUpload(try #require(files[1].id)))
        let uploaded = try await provider.uploadAttachmentFiles(files, channelID: ChannelID(rawValue: 200), progress: { _ in })
        #expect(fixture.events.reservedNames == ["kept.bin"])
        guard case let .object(payload) = uploaded.first, uploaded.count == 1 else { Issue.record("Missing kept attachment"); return }
        #expect(payload["uploaded_filename"] == .string("kept-upload"))
    }

    /// Storage can accept the last file before the user's stop arrives; the
    /// message then goes with it, so the stop must be refused.
    @Test func fileInAMessageBeingPostedCannotBeStopped() async throws {
        let fixture = HeldStorageFixture()
        let directory = try fixture.directory(containing: ["first.bin", "second.bin"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let attachments = ["first.bin", "second.bin"].map {
            ForumPostAttachment(url: directory.appending(path: $0), filename: $0)
        }
        let provider = fixture.provider(holdsEveryUpload: false)
        let send = Task {
            try await provider.send(SendMessageDraft(channelID: ChannelID(rawValue: 200), content: "", attachments: attachments))
        }
        #expect(await eventually { fixture.events.postedNames != nil })
        #expect(await provider.cancelAttachmentUpload(attachments[1].id) == false)
        #expect(fixture.events.postedNames == ["first.bin", "second.bin"])
        fixture.session?.invalidateAndCancel()
        _ = await send.result
    }

    /// A file stored as it was attached posts as it is rather than uploading
    /// twice, and one removed from the draft is deleted from storage.
    @Test func filesStoredOnAttachPostWithoutUploadingAgain() async throws {
        let fixture = HeldStorageFixture()
        let directory = try fixture.directory(containing: ["kept.bin", "removed.bin"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let attachments = ["kept.bin", "removed.bin"].map {
            ForumPostAttachment(url: directory.appending(path: $0), filename: $0)
        }
        let provider = fixture.provider(holdsEveryUpload: false)
        let channelID = ChannelID(rawValue: 200)
        for attachment in attachments {
            #expect(await provider.preuploadAttachment(attachment, channelID: channelID, progress: { _ in }))
        }
        await provider.discardPreuploadedAttachment(attachments[1].id)
        #expect(fixture.events.requests.last == "DELETE /api/v9/attachments/removed-upload")
        let requestCount = fixture.events.requests.count
        let uploaded = try await provider.uploadForumAttachments([attachments[0]], channelID: channelID, progress: { _ in })
        #expect(fixture.events.requests.count == requestCount)
        guard case let .object(payload) = uploaded.first, uploaded.count == 1 else { Issue.record("Missing kept attachment"); return }
        #expect(payload["uploaded_filename"] == .string("kept-upload"))
    }
}

/// Owns one test's storage traffic. The URL protocol routes each request here
/// by the session's fixture header, so concurrent tests never share state.
private final class HeldStorageFixture {
    struct Events: Sendable {
        var held = 0
        var stopped = 0
        var reservedNames: [String] = []
        var postedNames: [String]?
        var requests: [String] = []
    }

    private final class Storage: Sendable {
        let events = Mutex(Events())
    }

    private let storage = Storage()
    let id = UUID().uuidString
    private var observer: NSObjectProtocol?
    private(set) var session: URLSession?

    init() {
        let id = id
        observer = NotificationCenter.default.addObserver(
            forName: HeldStorageURLProtocol.received, object: nil, queue: nil
        ) { [storage] note in
            guard let exchange = note.object as? HeldStorageURLProtocol.Exchange, exchange.fixtureID == id else { return }
            storage.events.withLock { events in
                switch exchange.event {
                case .held: events.held += 1
                case .stopped: events.stopped += 1
                case let .reserved(names): events.reservedNames = names
                case let .posted(names): events.postedNames = names
                case let .requested(request): events.requests.append(request)
                }
            }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var events: Events { storage.events.withLock { $0 } }

    func directory(containing names: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in names { try Data(name.utf8).write(to: directory.appending(path: name)) }
        return directory
    }

    func provider(holdsEveryUpload: Bool) -> DiscordRESTProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldStorageURLProtocol.self]
        configuration.httpAdditionalHeaders = [
            HeldStorageURLProtocol.fixtureHeader: id,
            HeldStorageURLProtocol.holdsEveryUploadHeader: holdsEveryUpload ? "1" : "0",
        ]
        let session = URLSession(configuration: configuration)
        self.session = session
        return DiscordRESTProvider(credentials: TestCredentialStore(), handle: CredentialHandle(accountID: "1"), session: session)
    }
}

/// Answers the reservation, completes the kept files' storage PUTs, and holds
/// the others, and the message itself, open until their transfer is cancelled.
private final class HeldStorageURLProtocol: URLProtocol, @unchecked Sendable {
    static let received = Notification.Name("UploadCancellationContract.request")
    static let fixtureHeader = "X-Upload-Cancellation-Test"
    static let holdsEveryUploadHeader = "X-Upload-Cancellation-Holds-Every-Upload"

    enum Event: Sendable {
        case held, stopped
        case reserved([String])
        case posted([String])
        case requested(String)
    }

    final class Exchange: Sendable {
        let fixtureID: String?
        let event: Event

        init(fixtureID: String?, event: Event) {
            self.fixtureID = fixtureID
            self.event = event
        }
    }

    private var isHeld = false

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        report(.requested("\(request.httpMethod ?? "GET") \(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path)"))
        if request.httpMethod == "PUT",
           url.lastPathComponent == "stopped" || request.value(forHTTPHeaderField: Self.holdsEveryUploadHeader) == "1"
        {
            return hold()
        }
        var data = Data()
        if request.httpMethod == "POST" {
            let body = Self.requestBody(request)
            if url.path.hasSuffix("/messages") {
                let attachments = body?["attachments"] as? [[String: Any]]
                report(.posted(attachments?.compactMap { $0["filename"] as? String } ?? []))
                return hold()
            }
            let names = (body?["files"] as? [[String: Any]])?.compactMap { $0["filename"] as? String } ?? []
            report(.reserved(names))
            let slots = names.enumerated().map { index, name in
                let stem = (name as NSString).deletingPathExtension
                return ["id": index, "upload_url": "https://upload.example/\(stem)", "upload_filename": "\(stem)-upload"] as [String: Any]
            }
            data = (try? JSONSerialization.data(withJSONObject: ["attachments": slots])) ?? Data()
        }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        if isHeld { report(.stopped) }
    }

    private func hold() {
        isHeld = true
        report(.held)
    }

    private func report(_ event: Event) {
        NotificationCenter.default.post(
            name: Self.received,
            object: Exchange(fixtureID: request.value(forHTTPHeaderField: Self.fixtureHeader), event: event)
        )
    }

    private static func requestBody(_ request: URLRequest) -> [String: Any]? {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}
