import DiscordProtocol
import Foundation
@testable import SakuraCord
import Testing

@MainActor
@Test func `failed promised file batch removes its receiving directory`() throws {
    let directory = try ComposerPromisedFileDropView.makeReceivingDirectory()
    let partialFile = directory.appendingPathComponent("partial.bin")
    try Data("partial".utf8).write(to: partialFile)
    var completedBatch: ComposerPromisedFileBatch?
    let collector = ComposerPromisedFileCollector(
        expectedCount: 1,
        directory: directory
    ) {
        completedBatch = $0
    }

    collector.receive(
        url: partialFile,
        error: CocoaError(.fileReadUnknown)
    )

    #expect(completedBatch?.urls.isEmpty == true)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}

@MainActor
@Test func `removing a promised attachment releases only its owned batch`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let directory = try ComposerPromisedFileDropView.makeReceivingDirectory()
    let promisedFile = directory.appendingPathComponent("promised.bin")
    try Data("promised".utf8).write(to: promisedFile)
    let batch = ComposerPromisedFileBatch(
        directory: directory,
        urls: [promisedFile]
    )
    let ordinaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sakuracord-user-file-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: ordinaryDirectory,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: ordinaryDirectory) }
    let ordinaryFile = ordinaryDirectory.appendingPathComponent("ordinary.bin")
    try Data("ordinary".utf8).write(to: ordinaryFile)

    #expect(model.addPromisedComposerAttachments(batch, to: .channel))
    #expect(model.addComposerAttachments([ordinaryFile], to: .channel))
    let promisedAttachment = try #require(
        model.channelComposerAttachments.first { $0.url == promisedFile }
    )
    let ordinaryAttachment = try #require(
        model.channelComposerAttachments.first { $0.url == ordinaryFile }
    )

    model.removeComposerAttachment(promisedAttachment.id, from: .channel)
    model.removeComposerAttachment(ordinaryAttachment.id, from: .channel)

    #expect(!FileManager.default.fileExists(atPath: directory.path))
    #expect(FileManager.default.fileExists(atPath: ordinaryFile.path))
}

@MainActor
@Test func `promised file symlink outside managed directory is rejected safely`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let directory = try ComposerPromisedFileDropView.makeReceivingDirectory()
    let outsideDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sakuracord-promised-target-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: outsideDirectory) }
    let target = outsideDirectory.appendingPathComponent("target.bin")
    try Data("must-survive".utf8).write(to: target)
    let symlink = directory.appendingPathComponent("promised.bin")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
    let batch = ComposerPromisedFileBatch(directory: directory, urls: [symlink])

    #expect(model.addPromisedComposerAttachments(batch, to: .channel) == false)

    #expect(!FileManager.default.fileExists(atPath: directory.path))
    #expect(FileManager.default.fileExists(atPath: target.path))
    #expect(try Data(contentsOf: target) == Data("must-survive".utf8))
}
