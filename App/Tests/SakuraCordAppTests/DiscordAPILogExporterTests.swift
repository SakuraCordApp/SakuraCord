@testable import SakuraCord
import AppKit
import Testing

@MainActor
struct DiscordAPILogExporterTests {
    @Test func `exact destination writer replaces the selected file and removes staging`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sakuracord-exact-writer-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagingRoot = directory.appendingPathComponent(
            "staging",
            isDirectory: true
        )
        let destination = directory.appendingPathComponent("export.jsonl")
        try FileManager.default.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("old".utf8).write(to: destination)
        let expected = Data("{\"format\":\"test\"}\n".utf8)

        try await ExactDestinationFileWriter.write(
            expected,
            to: destination,
            stagingRootURL: stagingRoot
        )

        #expect(try Data(contentsOf: destination) == expected)
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: stagingRoot.path
            ).isEmpty
        )
    }

    @Test func `exact destination writer cleans partial staging after preparation failure`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sakuracord-exact-writer-failure-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagingRoot = directory.appendingPathComponent(
            "staging",
            isDirectory: true
        )
        let destination = directory.appendingPathComponent("export.jsonl")
        try FileManager.default.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data("original".utf8)
        try original.write(to: destination)

        await #expect(throws: ExactDestinationWriterTestError.self) {
            try await ExactDestinationFileWriter.write(
                to: destination,
                stagingRootURL: stagingRoot
            ) { stagedURL in
                try Data("partial".utf8).write(to: stagedURL)
                throw ExactDestinationWriterTestError()
            }
        }

        #expect(try Data(contentsOf: destination) == original)
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: stagingRoot.path
            ).isEmpty
        )
    }

    @Test func `API log export writes owner-only file permissions`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sakuracord-api-export-permissions-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
        let destination = directory.appendingPathComponent("export.jsonl")
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try await DiscordAPILogExporter.write(
            Data("{\"format\":\"sanitized\"}\n".utf8),
            to: destination,
            stagingRootURL: stagingRoot
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func `API log exporter attaches its save panel to the active settings window`() async {
        let panel = NSObject()
        let window = NSObject()
        var usedSheet = false
        var usedApplicationModal = false

        let response = await DiscordAPILogExporter.present(
            panel,
            attachedTo: window,
            beginSheet: { receivedPanel, receivedWindow, completion in
                usedSheet = receivedPanel === panel && receivedWindow === window
                completion(.cancel)
            },
            beginApplicationModal: { _, completion in
                usedApplicationModal = true
                completion(.cancel)
            }
        )

        #expect(response == .cancel)
        #expect(usedSheet)
        #expect(!usedApplicationModal)
    }

    @Test func `API log exporter falls back when no presentation window exists`() async {
        let panel = NSObject()
        let window: NSObject? = nil
        var usedSheet = false
        var usedApplicationModal = false

        let response = await DiscordAPILogExporter.present(
            panel,
            attachedTo: window,
            beginSheet: { _, _, completion in
                usedSheet = true
                completion(.cancel)
            },
            beginApplicationModal: { receivedPanel, completion in
                usedApplicationModal = receivedPanel === panel
                completion(.cancel)
            }
        )

        #expect(response == .cancel)
        #expect(!usedSheet)
        #expect(usedApplicationModal)
    }
}

private struct ExactDestinationWriterTestError: Error {}
