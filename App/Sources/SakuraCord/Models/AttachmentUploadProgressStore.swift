import Foundation
import SakuraCordModels

/// Per-file progress of attachment sends, kept out of observation so a byte
/// update repaints only its timeline row.
///
/// Like the first-party composer, a staged file starts uploading as soon as it
/// is attached, and its progress carries over once its message is sent. A
/// send's entry lives from admission until it is confirmed or discarded. A
/// failed send keeps it only when a file never reached storage, which is what
/// marks that message's files as a failed upload.
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

    /// A staged file's upload before its message is sent.
    private enum Preupload: Equatable {
        case sending(Double)
        /// Storage accepted it, so its message posts it as it is.
        case stored
    }

    private var uploads: [String: Upload] = [:]
    /// By draft attachment ID.
    private var preuploads: [UUID: Preupload] = [:]

    /// Whether this local send's files show their upload state.
    func tracks(nonce: String?) -> Bool {
        nonce.map { uploads[$0] != nil } ?? false
    }

    /// A staged file's upload, until storage accepts it or it fails.
    func preuploadFraction(_ attachmentID: UUID) -> Double? {
        guard case let .sending(fraction) = preuploads[attachmentID] else { return nil }
        return fraction
    }

    func fraction(nonce: String?, attachmentID: String) -> Double {
        guard let upload = nonce.flatMap({ uploads[$0] }) else { return 0 }
        return upload.isUploaded ? 1 : upload.fractions[attachmentID] ?? 0
    }

    /// A file still on its way to storage, which shows its upload ring and
    /// can be stopped. Once storage has every file, the message itself is
    /// being posted.
    func isUploading(nonce: String?, attachmentID: String) -> Bool {
        guard let nonce, let upload = uploads[nonce], let fraction = upload.fractions[attachmentID] else { return false }
        return !upload.isUploaded && fraction < 1
    }

    func beginPreupload(_ attachmentID: UUID) {
        preuploads[attachmentID] = .sending(0)
        notify(attachmentID: attachmentID)
    }

    /// A file whose message was already sent keeps that message's progress,
    /// restarting it if the early upload failed.
    func endPreupload(_ attachmentID: UUID, stored: Bool) {
        defer { notify(attachmentID: attachmentID) }
        if stored {
            if case .sending = preuploads[attachmentID] { preuploads[attachmentID] = .stored }
            return
        }
        preuploads[attachmentID] = nil
        // A sent file whose early upload failed is stored again from the start.
        let id = attachmentID.uuidString
        if let nonce = nonce(sending: id) {
            uploads[nonce]?.fractions[id] = 0
            notify(nonce: nonce, endsCancellation: false)
        }
    }

    /// Drops a file removed before it was sent.
    func forgetPreupload(_ attachmentID: UUID) {
        preuploads[attachmentID] = nil
    }

    /// A send whose files are all stored already posts at once, without upload cards.
    func begin(_ draft: SendMessageDraft) {
        guard draft.voiceMessage == nil, !draft.attachments.isEmpty else { return }
        let ids = draft.attachments.map(\.id)
        defer { for id in ids { preuploads[id] = nil } }
        guard ids.contains(where: { preuploads[$0] != .stored }) else { return }
        uploads[draft.nonce] = Upload(fractions: Dictionary(uniqueKeysWithValues: ids.map { id in
            let fraction: Double = switch preuploads[id] {
            case .stored: 1
            case let .sending(sent): sent
            case nil: 0
            }
            return (id.uuidString, fraction)
        }))
    }

    /// Progress leaves the message unchanged, so only these updates notify;
    /// every other change to a sent file accompanies a change to its message.
    /// A staged file's upload reports without a nonce, also once it is sent.
    func apply(_ progress: MessageSendProgress, nonce: String? = nil) {
        switch progress {
        case let .uploading(fileID?, _, completed, total):
            guard total > 0 else { return }
            let fraction = min(1, Double(completed) / Double(total))
            // Progress arrives on separate hops, so an older report can land late.
            if case let .sending(current) = preuploads[fileID] {
                preuploads[fileID] = .sending(max(current, fraction))
                notify(attachmentID: fileID)
                return
            }
            let id = fileID.uuidString
            guard let nonce = nonce ?? self.nonce(sending: id),
                  let current = uploads[nonce]?.fractions[id], fraction > current
            else { return }
            uploads[nonce]?.fractions[id] = fraction
            notify(nonce: nonce, endsCancellation: false)
        case .submitting:
            guard let nonce, uploads[nonce] != nil else { return }
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
        preuploads.removeAll()
    }

    private func nonce(sending attachmentID: String) -> String? {
        uploads.first { $0.value.fractions[attachmentID] != nil }?.key
    }

    private func notify(nonce: String, endsCancellation: Bool) {
        NotificationCenter.default.post(
            name: Self.didChange,
            object: self,
            userInfo: [Self.nonceKey: nonce, Self.endsCancellationKey: endsCancellation]
        )
    }

    /// A staged file's upload, for its composer tile.
    private func notify(attachmentID: UUID) {
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: [Self.attachmentIDKey: attachmentID])
    }

    static let nonceKey = "nonce"
    static let attachmentIDKey = "attachmentID"
    /// Set when the send's files can no longer be stopped.
    static let endsCancellationKey = "endsCancellation"
}
