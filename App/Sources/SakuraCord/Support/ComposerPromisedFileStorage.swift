import Foundation

struct ComposerPromisedFileBatch {
    let directory: URL
    let urls: [URL]

    func discard(fileManager: FileManager = .default) {
        ComposerPromisedFileStorage.removeDirectory(
            directory,
            fileManager: fileManager
        )
    }
}

/// Files offered to a composer by drop or paste.
enum ComposerIncomingAttachments {
    /// User files that stay in place.
    case external([URL])
    /// App-owned copies that the model adopts and removes when unused.
    case owned(ComposerPromisedFileBatch)
}

enum ComposerPromisedFileStorage {
    static func rootDirectory(fileManager: FileManager = .default) -> URL {
        let applicationIdentifier = Bundle.main.bundleIdentifier
            ?? "dev.sakuracord.SakuraCord"
        return fileManager.temporaryDirectory
            .appendingPathComponent("SakuraCord", isDirectory: true)
            .appendingPathComponent("Promised Attachments", isDirectory: true)
            .appendingPathComponent(applicationIdentifier, isDirectory: true)
    }

    static func removeAbandonedFilesAtStartup(
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: rootDirectory(fileManager: fileManager))
    }

    static func makeReceivingDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = rootDirectory(fileManager: fileManager).appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    /// Writes app-created content, such as pasted data, as a one-file batch.
    static func makeBatch(
        writing data: Data,
        named filename: String,
        fileManager: FileManager = .default
    ) -> ComposerPromisedFileBatch? {
        guard let directory = try? makeReceivingDirectory(fileManager: fileManager) else { return nil }
        let url = directory.appendingPathComponent(filename)
        // The file must stay a direct child of its batch directory.
        guard url.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL else {
            removeDirectory(directory, fileManager: fileManager)
            return nil
        }
        do {
            try data.write(to: url, options: .atomic)
            return ComposerPromisedFileBatch(directory: directory, urls: [url])
        } catch {
            removeDirectory(directory, fileManager: fileManager)
            return nil
        }
    }

    static func isManagedDirectory(
        _ directory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        directory.standardizedFileURL.deletingLastPathComponent()
            == rootDirectory(fileManager: fileManager).standardizedFileURL
    }

    static func contains(_ fileURL: URL, in directory: URL) -> Bool {
        let directoryPath = directory.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        return filePath.hasPrefix(directoryPath + "/")
    }

    static func approvedRegularFile(
        _ fileURL: URL,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard isManagedDirectory(directory, fileManager: fileManager) else { return nil }
        let resolvedRoot = rootDirectory(fileManager: fileManager)
            .resolvingSymlinksInPath().standardizedFileURL
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedDirectory.deletingLastPathComponent() == resolvedRoot else { return nil }

        let standardizedFile = fileURL.standardizedFileURL
        guard let values = try? standardizedFile.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ), values.isRegularFile == true, values.isSymbolicLink != true else {
            return nil
        }
        let resolvedFile = standardizedFile.resolvingSymlinksInPath().standardizedFileURL
        guard contains(resolvedFile, in: resolvedDirectory) else { return nil }
        return resolvedFile
    }

    static func removeDirectory(
        _ directory: URL,
        fileManager: FileManager = .default
    ) {
        guard isManagedDirectory(directory, fileManager: fileManager) else { return }
        try? fileManager.removeItem(at: directory)
    }
}
