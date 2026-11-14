@testable import SakuraCord
import Foundation
import SakuraCordModels
import Testing

@Test func `external attachment uploader defaults to a cookie free ephemeral session`() {
    let uploader = CatboxAttachmentUploader()
    let configuration = uploader.session.configuration

    #expect(configuration.identifier == nil)
    #expect(configuration.httpCookieStorage == nil)
    #expect(!configuration.httpShouldSetCookies)
}

@Test func `external attachment uploader preserves injected sessions`() {
    let session = URLSession(configuration: .ephemeral)

    #expect(CatboxAttachmentUploader(session: session).session === session)
}

@Test(arguments: ["private-report.txt", "SPOILER_private-photo.PNG", "private-notes"])
func `anonymised multipart uploads omit original names and preserve source files`(filename: String) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent(filename)
    let bytes = Data("attachment contents".utf8)
    try bytes.write(to: source)
    let body = try CatboxAttachmentUploader.makeMultipartFile(
        sourceURL: source, service: .catbox, boundary: "test-boundary", anonymisesFileNames: true
    )
    defer { try? FileManager.default.removeItem(at: body.deletingLastPathComponent()) }
    let multipart = try String(contentsOf: body, encoding: .utf8)
    #expect(!multipart.contains(filename))
    let uploadedName = try #require(multipart.components(separatedBy: "filename=\"").last?.components(separatedBy: "\"").first)
    #expect((uploadedName as NSString).pathExtension == source.pathExtension)
    #expect(uploadedName.hasPrefix(UploadFilename.spoilerPrefix) == filename.hasPrefix(UploadFilename.spoilerPrefix))
    let stem = (uploadedName as NSString).deletingPathExtension.replacingOccurrences(of: UploadFilename.spoilerPrefix, with: "")
    #expect(UUID(uuidString: stem) != nil)
    #expect(multipart.contains("attachment contents"))
    #expect(try Data(contentsOf: source) == bytes)
}
