import Foundation
import Synchronization

/// Reports one storage PUT's sent bytes and lets that file alone be stopped,
/// independently of the other files of the same message.
nonisolated final class AttachmentUploadTaskDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private struct State {
        var task: URLSessionTask?
        var isCancelled = false
        var reportedPercent = -1
    }

    private let state = Mutex(State())
    private let report: @Sendable (_ sent: Int64, _ expected: Int64) -> Void

    init(report: @escaping @Sendable (_ sent: Int64, _ expected: Int64) -> Void) {
        self.report = report
    }

    var isCancelled: Bool {
        state.withLock(\.isCancelled)
    }

    func cancel() {
        state.withLock {
            $0.isCancelled = true
            return $0.task
        }?.cancel()
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let isCancelled = state.withLock {
            $0.task = task
            return $0.isCancelled
        }
        if isCancelled { task.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        // Whole percents keep a large file from flooding the timeline with redraws.
        let percent = Int(totalBytesSent * 100 / totalBytesExpectedToSend)
        let advanced = state.withLock {
            guard percent > $0.reportedPercent else { return false }
            $0.reportedPercent = percent
            return true
        }
        if advanced { report(totalBytesSent, totalBytesExpectedToSend) }
    }
}
