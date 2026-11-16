@testable import SakuraCord
import DiscordProtocol
import Foundation
import ImageIO
import SakuraCordModels
import Synchronization
import Testing
import UniformTypeIdentifiers

@Suite(.serialized)
struct UploadPrivacyPreparationTests {
    @MainActor
    @Test func selectionChecksPreparedTIFFSizeWithoutExpandingLosslessPixels() async throws {
        let store = PrivacySafetySettingsStore(preferences: SettingsPreferenceStore(defaults: InMemoryPreferences()))
        let privacy = UploadPrivacyPreparation(store: store) { _ in
            Issue.record("The TIFF should be sanitized without requiring original-file consent")
            return false
        }
        let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider(),
                             attachmentSettingsStore: AttachmentSettingsStore(preferences: SettingsPreferenceStore(defaults: InMemoryPreferences())),
                             privacySafetySettingsStore: store, uploadPrivacyPreparation: privacy)
        await model.start()
        model.snapshot?.currentUser.premiumType = 0
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("compressed.tiff")
        let context = try #require(CGContext(data: nil, width: 3500, height: 3000, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for x in 0 ..< 3500 {
            context.setFillColor(CGColor(red: Double(x % 251) / 250, green: Double(x % 149) / 148, blue: Double(x % 97) / 96, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: 3000))
        }
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: source)
        #expect(original.count < model.discordAttachmentLimit)
        let prepared = try await privacy.prepare(source)
        defer { prepared.discard() }
        #expect(try Data(contentsOf: prepared.url).count < model.discordAttachmentLimit)
        #expect(try Data(contentsOf: source) == original)

        // TIFF readers ignore trailing bytes; preparation drops them. The original
        // now exceeds the limit, while the actual upload still fits without compaction.
        let file = try FileHandle(forWritingTo: source)
        try file.truncate(atOffset: UInt64(model.discordAttachmentLimit + 1))
        try file.close()
        #expect(await model.addComposerAttachments([source], to: .channel))
        #expect(model.channelComposerAttachments.map(\.url) == [source])
        #expect(model.oversizedAttachmentPrompt == nil)
        #expect(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) == model.discordAttachmentLimit + 1)
    }

    @MainActor
    @Test(arguments: [true, false])
    func selectionWarningAllowsOnlyTheApprovedBytes(accept: Bool) async throws {
        let store = PrivacySafetySettingsStore(preferences: SettingsPreferenceStore(defaults: InMemoryPreferences()))
        var warnings = 0
        let privacy = UploadPrivacyPreparation(store: store) { _ in
            warnings += 1
            return accept && warnings == 1
        }
        let model = AppModel(launchMode: .offlineTesting, provider: MockChatProvider(),
                             privacySafetySettingsStore: store, uploadPrivacyPreparation: privacy)
        await model.start()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("drawing.svg")
        let original = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><metadata>Private location</metadata></svg>".utf8)
        try original.write(to: source)
        #expect(await model.addComposerAttachments([source], to: .channel))
        #expect(warnings == 1)
        #expect(model.channelComposerAttachments.count == (accept ? 1 : 0))
        #expect(store.load().removesMediaMetadata)
        if accept {
            let prepared = try await privacy.prepare(source)
            defer { prepared.discard() }
            #expect(warnings == 1)
            #expect(prepared.url != source)
            #expect(try Data(contentsOf: prepared.url) == original)
            try Data("changed private bytes".utf8).write(to: source)
            #expect(try Data(contentsOf: prepared.url) == original)
            await #expect(throws: CancellationError.self) { try await privacy.prepare(source) }
            #expect(warnings == 2)
        }
    }

    @MainActor
    @Test(arguments: [true, false])
    func externalUploadsRespectLivePrivacySetting(enabled: Bool) async throws {
        ExternalPrivacyURLProtocol.body.withLock { $0 = Data() }
        let preferences = SettingsPreferenceStore(defaults: InMemoryPreferences())
        let store = PrivacySafetySettingsStore(preferences: preferences)
        let privacy = UploadPrivacyPreparation(store: store)
        let prepare: @Sendable (URL) async throws -> PreparedUploadFile = { try await privacy.prepare($0) }
        var settings = store.load()
        settings.removesMediaMetadata = enabled
        store.save(settings)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("photo.jpg")
        let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Private Camera Owner"]
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: source)
        #expect(original.range(of: Data("Private Camera Owner".utf8)) != nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExternalPrivacyURLProtocol.self]
        let uploader = CatboxAttachmentUploader(session: URLSession(configuration: configuration), prepareUploadFile: prepare)
        _ = try await uploader.upload(fileURL: source, using: .catbox)
        let body = ExternalPrivacyURLProtocol.body.withLock { $0 }
        #expect(!body.isEmpty)
        #expect((body.range(of: Data("Private Camera Owner".utf8)) == nil) == enabled)
        if !enabled { #expect(body.range(of: original) != nil) }
        #expect(try Data(contentsOf: source) == original)

        let reports = IssueReportStore()
        await reports.addAttachments([source], using: privacy)
        let reportUpload = try #require(reports.draft.attachments.first?.upload.data)
        #expect((reportUpload.range(of: Data("Private Camera Owner".utf8)) == nil) == enabled)
        #expect(try Data(contentsOf: source) == original)
    }
}

private final class ExternalPrivacyURLProtocol: URLProtocol, @unchecked Sendable {
    static let body = Mutex(Data())
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        Self.body.withLock { $0 = data }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("https://files.catbox.moe/fixture.jpg".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
