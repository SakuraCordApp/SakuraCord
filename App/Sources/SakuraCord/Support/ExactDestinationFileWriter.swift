import Foundation

nonisolated enum ExactDestinationFileWriter {
    static func write(
        _ data: Data,
        to destination: URL,
        stagingRootURL: URL? = nil
    ) async throws {
        try await write(
            to: destination,
            stagingRootURL: stagingRootURL
        ) { stagedURL in
            try await Task.detached(priority: .utility) {
                try data.write(to: stagedURL)
            }.value
        }
    }

    static func write(
        to destination: URL,
        stagingRootURL: URL? = nil,
        prepareStagedFile: @Sendable (URL) async throws -> Void
    ) async throws {
        let accessed = destination.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                destination.stopAccessingSecurityScopedResource()
            }
        }

        let stagingDirectory = try makeStagingDirectory(rootURL: stagingRootURL)
        let stagedURL = stagingDirectory.appendingPathComponent("payload")
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        try await prepareStagedFile(stagedURL)
        try await replaceDestination(destination, with: stagedURL)
    }

    static func rootDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("SakuraCord", isDirectory: true)
            .appendingPathComponent("Exact Destination Writes", isDirectory: true)
    }

    private static func makeStagingDirectory(
        rootURL: URL?,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = (rootURL ?? rootDirectory(fileManager: fileManager))
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private static func replaceDestination(
        _ destination: URL,
        with stagedURL: URL
    ) async throws {
        try await Task.detached(priority: .utility) {
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var operationError: (any Error)?
            coordinator.coordinate(
                writingItemAt: destination,
                options: .forReplacing,
                error: &coordinationError
            ) { coordinatedDestination in
                do {
                    let fileManager = FileManager.default
                    if fileManager.fileExists(
                        atPath: coordinatedDestination.path
                    ) {
                        _ = try fileManager.replaceItemAt(
                            coordinatedDestination,
                            withItemAt: stagedURL
                        )
                    } else {
                        try fileManager.moveItem(
                            at: stagedURL,
                            to: coordinatedDestination
                        )
                    }
                } catch {
                    operationError = error
                }
            }
            if let operationError { throw operationError }
            if let coordinationError { throw coordinationError }
        }.value
    }
}
