import Foundation
import SakuraCordModels

/// Per-file progress of the outbox's attachment sends, kept out of
/// observation so a byte update repaints only its timeline row.
///
/// A send's entry lives from admission until it is confirmed or discarded.
/// A failed send keeps it only when a file never reached storage, which is
/// what marks that message's files as a failed upload.
@MainActor
final class AttachmentUploadProgressStore {
    static let didChange = Notification.Name("AttachmentUploadProgressStore.didChange")

    private struct Upload {
        /// Keyed by the draft attachment's ID, which the optimistic row's
        /// attachments share.
        var fractions: [String: Double]
        /// Storage accepted every file. Sent bytes alone do not prove that.
        var isUploaded = false
    }

    private var uploads: [String: Upload] = [:]

    /// Whether the row of this local send shows upload cards.
    func tracks(nonce: String?) -> Bool {
        nonce.map { uploads[$0] != nil } ?? false
    }

    func fraction(nonce: String?, attachmentID: String) -> Double {
        guard let upload = nonce.flatMap({ uploads[$0] }) else { return 0 }
        return upload.isUploaded ? 1 : upload.fractions[attachmentID] ?? 0
    }

    /// Once storage has every file, the message itself is being posted.
    func canCancel(nonce: String?, attachmentID: String) -> Bool {
        guard let nonce, let upload = uploads[nonce], upload.fractions[attachmentID] != nil else { return false }
        return !upload.isUploaded
    }

    func begin(_ draft: SendMessageDraft) {
        guard draft.voiceMessage == nil, !draft.attachments.isEmpty else { return }
        uploads[draft.nonce] = Upload(fractions: Dictionary(
            uniqueKeysWithValues: draft.attachments.map { ($0.id.uuidString, 0) }
        ))
    }

    /// Progress leaves the message unchanged, so only these updates notify;
    /// every other change here accompanies a change to the message itself.
    func apply(_ progress: MessageSendProgress, nonce: String) {
        guard uploads[nonce] != nil else { return }
        switch progress {
        case let .uploading(fileID?, _, completed, total):
            let id = fileID.uuidString
            // Progress arrives on separate hops, so an older report can land late.
            guard total > 0, let current = uploads[nonce]?.fractions[id] else { return }
            let fraction = min(1, Double(completed) / Double(total))
            guard fraction > current else { return }
            uploads[nonce]?.fractions[id] = fraction
            notify(nonce: nonce, endsCancellation: false)
        case .submitting:
            uploads[nonce]?.isUploaded = true
            notify(nonce: nonce, endsCancellation: true)
        default:
            return
        }
    }

    /// Keeps the entry only when a file never reached storage.
    func fail(nonce: String) {
        if uploads[nonce]?.isUploaded == true { uploads[nonce] = nil }
    }

    func remove(attachmentID: String, nonce: String) {
        uploads[nonce]?.fractions[attachmentID] = nil
    }

    func finish(nonce: String) {
        uploads[nonce] = nil
    }

    func reset() {
        uploads.removeAll()
    }

    private func notify(nonce: String, endsCancellation: Bool) {
        NotificationCenter.default.post(
            name: Self.didChange,
            object: self,
            userInfo: [Self.nonceKey: nonce, Self.endsCancellationKey: endsCancellation]
        )
    }

    static let nonceKey = "nonce"
    /// Set when the send's files can no longer be stopped.
    static let endsCancellationKey = "endsCancellation"
}
