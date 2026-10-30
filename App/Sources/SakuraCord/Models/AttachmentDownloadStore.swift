import AppKit
import Foundation
import SakuraCordModels
import Synchronization

/// Downloads file attachments in the app, never through a browser, and
/// remembers each file's progress and result for the timeline's file cards.
///
/// Files save to the Default Download Folder setting, or to Downloads, under
/// a Finder-style unique name.
@MainActor
final class AttachmentDownloadStore {
    enum State: Equatable {
        case downloading(fraction: Double)
        /// The saved file, and the security-scoped folder it was saved
        /// into, if not Downloads.
        case finished(URL, folder: URL?)
        case failed
    }

    /// Posted with the store as its object and the attachment ID as
    /// `userInfo[Self.attachmentIDKey]` whenever a file's state changes.
    static let didChange = Notification.Name("AttachmentDownloadStore.didChange")
    static let attachmentIDKey = "attachmentID"

    private(set) var states: [String: State] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Re-signs an expiring Discord attachment link before it is fetched.
    var resolveRemoteURL: (@MainActor (URL) async -> URL)?

    private nonisolated static let session = URLSession(configuration: .ephemeral)

    /// The file card's action: download, cancel the running download, or
    /// show the downloaded file in Finder. A file that has since been moved
    /// or deleted downloads again.
    func activate(_ attachment: Attachment) {
        switch states[attachment.id] {
        case .downloading:
            tasks.removeValue(forKey: attachment.id)?.cancel()
            setState(nil, for: attachment.id)
        case let .finished(url, folder) where Self.fileExists(at: url, in: folder):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        default:
            start(attachment)
        }
    }

    /// Whether activating the file starts a download, rather than cancelling
    /// one or showing the saved file.
    func startsDownload(_ attachment: Attachment) -> Bool {
        switch states[attachment.id] {
        case .downloading: false
        case let .finished(url, folder): !Self.fileExists(at: url, in: folder)
        case .failed, nil: true
        }
    }

    private func start(_ attachment: Attachment) {
        let id = attachment.id
        setState(.downloading(fraction: 0), for: id)
        let resolveRemoteURL = resolveRemoteURL
        let (progress, reportProgress) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
        let progressUpdates = Task { [weak self] in
            for await fraction in progress { self?.updateProgress(fraction, for: id) }
        }
        tasks[id] = Task { [weak self] in
            defer { progressUpdates.cancel() }
            let result: State?
            do {
                let source = await resolveRemoteURL?(attachment.url) ?? attachment.url
                let file = try await Self.download(source) { reportProgress.yield($0) }
                result = try await Self.save(file, filename: attachment.filename, sourceURL: source)
            } catch {
                result = Task.isCancelled ? nil : .failed
            }
            guard let self else { return }
            // A file saved as the user cancelled stays, so the card shows it
            // unless a new download has begun.
            if Task.isCancelled {
                guard case .finished = result, states[id] == nil else { return }
            }
            tasks[id] = nil
            setState(result, for: id)
            if case let .finished(url, _) = result,
               StorageDownloadsSettingsStore.shared.load().revealsCompletedDownloads {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private func updateProgress(_ fraction: Double, for id: String) {
        // A progress tick redraws its row, so whole-percent steps suffice.
        guard case let .downloading(current) = states[id], fraction - current >= 0.01 else { return }
        setState(.downloading(fraction: fraction), for: id)
    }

    private func setState(_ state: State?, for id: String) {
        states[id] = state
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: [Self.attachmentIDKey: id])
    }

    private nonisolated static func download(
        _ url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let (file, response) = try await session.download(
            for: URLRequest(url: url),
            delegate: ProgressObserver(onProgress: progress)
        )
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200 ..< 300).contains(status) {
            try? FileManager.default.removeItem(at: file)
            throw URLError(.badServerResponse)
        }
        return file
    }

    private static func save(_ file: URL, filename: String, sourceURL: URL) async throws -> State {
        let folder = openDownloadFolder()
        defer { folder.scoped?.stopAccessingSecurityScopedResource() }
        let proposed = folder.url.appendingPathComponent(
            MediaViewerFilePolicy.suggestedFilename(title: filename, sourceURL: sourceURL)
        )
        // Moving onto another volume copies the whole file.
        let destination = try await Task.detached(priority: .utility) {
            defer { try? FileManager.default.removeItem(at: file) }
            while true {
                guard let destination = MediaViewerActionService.availableDestination(for: proposed) else {
                    throw MediaViewerActionError.couldNotChooseUniqueFilename
                }
                do {
                    try FileManager.default.moveItem(at: file, to: destination)
                    return destination
                } catch CocoaError.fileWriteFileExists {
                    // Another download of the same name took it first.
                    continue
                }
            }
        }.value
        return .finished(destination, folder: folder.scoped)
    }

    private static func fileExists(at url: URL, in folder: URL?) -> Bool {
        let accessed = folder?.startAccessingSecurityScopedResource() == true
        defer { if accessed { folder?.stopAccessingSecurityScopedResource() } }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// The Default Download Folder with its sandbox access started, which the
    /// caller stops through `scoped`, or Downloads when none is set or it can
    /// no longer be opened.
    private static func openDownloadFolder() -> (url: URL, scoped: URL?) {
        if let folder = try? StorageDownloadsSettingsStore.shared.resolvedDefaultFolder(),
           folder.startAccessingSecurityScopedResource() {
            return (folder, folder)
        }
        // The sandbox exposes Downloads through a container symlink; Finder
        // should select the file at its real location.
        return (URL.downloadsDirectory.resolvingSymlinksInPath(), nil)
    }
}

/// Reports a download task's progress as it is created by the async API.
private final class ProgressObserver: NSObject, URLSessionTaskDelegate, Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private let observation = Mutex<NSKeyValueObservation?>(nil)

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let onProgress = onProgress
        observation.withLock {
            $0 = task.progress.observe(\.fractionCompleted) { progress, _ in
                onProgress(progress.fractionCompleted)
            }
        }
    }
}
