import AppKit
import Foundation
import SakuraCordModels
import Security

/// Preserves a launchable app outside the bundle Sparkle will replace. Recovery
/// never depends on code in the subsequently installed preview being runnable.
@MainActor
final class PRBuildRecovery {
    private static let bookmarkKey = "updates.pullRequestRecoveryFolder"
    private let defaults: UserDefaults
    private let sourceBundleURL: URL

    init(defaults: UserDefaults = .standard, sourceBundleURL: URL = Bundle.main.bundleURL) {
        self.defaults = defaults
        self.sourceBundleURL = sourceBundleURL
    }

    func prepareRecovery() async throws -> URL {
        if SakuraCordStorageProfile.current.previewIdentifier != nil {
            return try await retainedRecoveryURL()
        }

        let panel = NSOpenPanel()
        panel.title = "Save a Recovery Copy"
        panel.message = "Choose where to keep your current SakuraCord app. You can open this copy from Finder if a pull request build cannot launch."
        panel.prompt = "Save Recovery Copy"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let destination = panel.url else {
            throw CocoaError(.userCancelled)
        }

        let accessing = destination.startAccessingSecurityScopedResource()
        defer { if accessing { destination.stopAccessingSecurityScopedResource() } }
        let source = sourceBundleURL
        let folder = destination.appending(
            path: "SakuraCord Recovery \(Date.now.formatted(.iso8601).replacingOccurrences(of: ":", with: "-"))-\(UUID().uuidString.prefix(8))",
            directoryHint: .isDirectory
        )
        let recoveryURL = try await Task.detached(priority: .userInitiated) {
            try Self.createRecoveryCopy(from: source, in: folder)
        }.value
        let bookmark = try folder.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        return recoveryURL
    }

    func retainedRecoveryURL() async throws -> URL {
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey) else {
            throw RecoveryError.missingRecovery
        }
        var stale = false
        let folder = try URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let app = folder.appending(path: "SakuraCord.app", directoryHint: .isDirectory)
        try await Task.detached(priority: .userInitiated) {
            try Self.verifyRecoveryApp(app)
        }.value
        if stale {
            defaults.set(
                try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil),
                forKey: Self.bookmarkKey
            )
        }
        return app
    }

    nonisolated private static func createRecoveryCopy(from source: URL, in folder: URL) throws -> URL {
        let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
        let destinationPath = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard destinationPath != sourcePath, !destinationPath.hasPrefix(sourcePath + "/") else {
            throw RecoveryError.invalidDestination
        }
        try verifyRecoveryApp(source)
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        let destination = folder.appending(path: "SakuraCord.app", directoryHint: .isDirectory)
        do {
            try manager.copyItem(at: source, to: destination)
            try verifyRecoveryApp(destination)
            let instructions = """
            SakuraCord recovery copy

            This is the Regular or Nightly app saved before trying a pull request build.
            If the experimental app cannot open, quit it and open SakuraCord.app in this folder.
            To restore your usual installation, quit SakuraCord and use Finder to copy this app
            back to the location of your installed SakuraCord.app, replacing the experimental app.

            Pull request builds keep their settings and drafts in a separate profile.
            This recovery app uses your original settings and drafts.
            Keep this folder until you have successfully returned to Regular or Nightly.
            """
            try instructions.write(to: folder.appending(path: "Recovery Instructions.txt"), atomically: true, encoding: .utf8)
            return destination
        } catch {
            // Only this invocation's newly created, incomplete copy is removed.
            try? manager.removeItem(at: folder)
            throw error
        }
    }

    nonisolated private static func verifyRecoveryApp(_ url: URL) throws {
        guard let bundle = Bundle(url: url),
              bundle.bundleIdentifier == "dev.sakuracord.SakuraCord",
              bundle.object(forInfoDictionaryKey: "SakuraCordPullRequestBuildID") == nil,
              let executable = bundle.executableURL
        else { throw RecoveryError.invalidRecovery }
        // X_OK checks this sandboxed process's execution permission, not whether
        // Finder can launch the saved app. Inspect the preserved file mode;
        // strict signature validation below authenticates its executable bytes.
        let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.uint16Value & 0o111 != 0 else {
            throw RecoveryError.inaccessibleExecutable
        }
        var code: SecStaticCode?
        let creationStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard creationStatus == errSecSuccess, let code else {
            throw RecoveryError.signatureVerificationFailed(creationStatus)
        }
        let validationStatus = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), nil)
        guard validationStatus == errSecSuccess else {
            throw RecoveryError.signatureVerificationFailed(validationStatus)
        }
    }
}

private nonisolated enum RecoveryError: LocalizedError {
    case missingRecovery
    case invalidRecovery
    case invalidDestination
    case inaccessibleExecutable
    case signatureVerificationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingRecovery:
            "The saved recovery app is unavailable. Return to a Regular or Nightly installation before switching to another pull request build."
        case .invalidDestination:
            "Choose a recovery folder outside SakuraCord.app."
        case .invalidRecovery:
            "The recovery app is missing, modified, or is itself a pull request build. Save an intact Regular or Nightly app before continuing."
        case .inaccessibleExecutable:
            "SakuraCord cannot access the recovery app’s executable."
        case let .signatureVerificationFailed(status):
            "The recovery app’s signature could not be verified: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))."
        }
    }
}
