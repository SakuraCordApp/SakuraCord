@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Synchronization
import Testing

@Suite(.serialized)
struct UploadPrivacyContractTests {
    @Test(arguments: [false, true])
    func preparesBeforeReservationAndNeverUploadsAfterPrivacyFailure(fails: Bool) async throws {
        UploadPrivacyURLProtocol.bodies.withLock { $0 = [] }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let temporary = directory.appendingPathComponent("prepared")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("photo.jpg")
        try Data("private original bytes".utf8).write(to: original)
        let prepared = temporary.appendingPathComponent("photo.jpg")
        let cleanBytes = Data("clean copy".utf8)
        try cleanBytes.write(to: prepared)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UploadPrivacyURLProtocol.self]
        let provider = DiscordRESTProvider(
            credentials: TestCredentialStore(), handle: CredentialHandle(accountID: "1"),
            session: URLSession(configuration: configuration),
            prepareUploadFile: { _ in
                if fails { throw CocoaError(.fileReadCorruptFile) }
                return PreparedUploadFile(url: prepared, temporaryDirectory: temporary)
            }
        )
        if fails {
            await #expect(throws: CocoaError.self) {
                try await provider.uploadAttachmentFiles(
                    [AttachmentUploadFile(url: original, name: "SPOILER_photo.jpg", description: "alt text")],
                    channelID: ChannelID(rawValue: 200), progress: { _ in }
                )
            }
            #expect(UploadPrivacyURLProtocol.bodies.withLock { $0.isEmpty })
        } else {
            let result = try await provider.uploadAttachmentFiles(
                [AttachmentUploadFile(url: original, name: "SPOILER_photo.jpg", description: "alt text")], channelID: ChannelID(rawValue: 200), progress: { _ in }
            )
            let bodies = UploadPrivacyURLProtocol.bodies.withLock { $0 }
            #expect(bodies.count == 2)
            let reservationBody = try #require(bodies.first)
            let reservation = try #require(JSONSerialization.jsonObject(with: reservationBody) as? [String: Any])
            let descriptor = try #require((reservation["files"] as? [[String: Any]])?.first)
            #expect(descriptor["file_size"] as? Int == cleanBytes.count)
            #expect(bodies.last == cleanBytes)
            guard case let .object(payload) = result.first else { Issue.record("Missing uploaded attachment"); return }
            #expect(payload["filename"] == .string("SPOILER_photo.jpg"))
            #expect(payload["description"] == .string("alt text"))
            #expect(!FileManager.default.fileExists(atPath: temporary.path))
        }
        #expect(try Data(contentsOf: original) == Data("private original bytes".utf8))
    }
}

private final class UploadPrivacyURLProtocol: URLProtocol, @unchecked Sendable {
    static let bodies = Mutex<[Data]>([])
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = request.bodyData ?? Data()
        Self.bodies.withLock { $0.append(body) }
        let data = request.httpMethod == "POST"
            ? Data(#"{"attachments":[{"id":0,"upload_url":"https://upload.example/test","upload_filename":"clean-upload"}]}"#.utf8)
            : Data()
        respond(status: 200, body: data, headers: nil)
    }
    override func stopLoading() {}
}
