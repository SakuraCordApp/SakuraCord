import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    /// Once Discord answers a post, the message holds its stored files. Discord
    /// rejects a stored file it no longer has (code 50146 once it expires), so
    /// after a rejected post Retry stores the files again. Any other failure
    /// keeps them, so Retry reuses them, as the official resend does, and
    /// discarding the message deletes them.
    func settlePreuploads(of draft: SendMessageDraft, after error: (any Error)? = nil) {
        guard let error else {
            for attachment in draft.attachments { attachmentPreuploads[attachment.id] = nil }
            return
        }
        if case let ChatProviderError.transport(status, _) = error, (400 ..< 500).contains(status), status != 429 {
            for attachment in draft.attachments {
                Task { await discardPreuploadedAttachment(attachment.id) }
            }
        }
    }

    func uploadAttachments(
        _ urls: [URL], channelID: ChannelID,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> [JSONValue] {
        let anonymisesNames = await anonymisesUploadFilenames()
        return try await uploadAttachmentFiles(
            urls.map { AttachmentUploadFile(url: $0, name: anonymisesNames ? UploadFilename.anonymised($0.lastPathComponent) : $0.lastPathComponent) },
            channelID: channelID,
            progress: progress
        )
    }

    func uploadForumAttachments(
        _ attachments: [ForumPostAttachment],
        channelID: ChannelID,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> [JSONValue] {
        let anonymisesNames = await anonymisesUploadFilenames()
        return try await uploadAttachmentFiles(
            attachments.map { Self.forumUploadFile($0.applyingFilenamePrivacy(anonymisesNames)) },
            channelID: channelID,
            progress: progress
        )
    }

    nonisolated static func forumUploadFile(
        _ attachment: ForumPostAttachment
    ) -> AttachmentUploadFile {
        let chosenName = attachment.filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = attachment.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return AttachmentUploadFile(
            url: attachment.url,
            name: chosenName.isEmpty ? attachment.url.lastPathComponent : chosenName,
            description: description.isEmpty ? nil : description,
            isSpoiler: attachment.isSpoiler,
            id: attachment.id
        )
    }

    /// The first-party attachment entry, shared by messages, forum posts and
    /// interactions. A spoiler keeps its filename and is flagged instead.
    nonisolated static func uploadedAttachmentPayload(
        id: Int,
        file: AttachmentUploadFile,
        uploadFilename: String
    ) -> JSONValue {
        var payload: [String: JSONValue] = [
            "id": .string(String(id)),
            "filename": .string(file.name),
            "uploaded_filename": .string(uploadFilename),
            "original_content_type": .string(file.contentType),
        ]
        if let description = file.description {
            payload["description"] = .string(description)
        }
        if file.isSpoiler {
            payload["is_spoiler"] = .bool(true)
        }
        return .object(payload)
    }

    func uploadAttachmentFiles(
        _ files: [AttachmentUploadFile],
        channelID: ChannelID,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> [JSONValue] {
        let isStopped = { (file: AttachmentUploadFile) in
            file.id.map(self.cancelledAttachmentUploads.contains) ?? false
        }
        defer { cancelledAttachmentUploads.subtract(files.compactMap(\.id)) }
        // Files stored as they were attached go as they are. They stay listed
        // until their message is posted, so stopping one still reaches it.
        let preuploads = files.map { $0.id.flatMap { attachmentPreuploads[$0] } }
        // A file stopped while its message waited is never read, since its
        // temporary copy may already be gone; stopping every file sends nothing.
        let pending = files.indices.filter { !isStopped(files[$0]) }
        guard files.isEmpty || !pending.isEmpty else { throw CancellationError() }
        let fresh = pending.filter { preuploads[$0] == nil }
        async let freshNames = storeAttachmentFiles(fresh.map { files[$0] }, channelID: channelID, progress: progress)
        var names = [String?](repeating: nil, count: files.count)
        var failed: [Int] = []
        for index in pending {
            guard let preupload = preuploads[index] else { continue }
            do {
                names[index] = try await withTaskCancellationHandler {
                    try await preupload.value
                } onCancel: {
                    preupload.cancel()
                }
            } catch {
                failed.append(index)
            }
        }
        for (index, name) in zip(fresh, try await freshNames) { names[index] = name }
        // This explicit send stores again a file whose early upload failed,
        // unless it was stopped meanwhile.
        failed.removeAll { isStopped(files[$0]) }
        let retried = try await storeAttachmentFiles(failed.map { files[$0] }, channelID: channelID, progress: progress)
        for (index, name) in zip(failed, retried) { names[index] = name }
        // A file stopped just as storage accepted it stays out of the message too.
        let uploaded = pending.compactMap { index in
            names[index].flatMap { isStopped(files[index]) ? nil : (files[index], $0) }
        }.enumerated().map {
            Self.uploadedAttachmentPayload(id: $0.offset, file: $0.element.0, uploadFilename: $0.element.1)
        }
        // Stopping every file stops the message, as the first-party upload card's cancel does.
        guard files.isEmpty || !uploaded.isEmpty else { throw CancellationError() }
        return uploaded
    }

    /// Reserves and sends every file at once, each with its own reservation,
    /// like the first-party uploader. Returns each file's stored name, or nil
    /// for a file the user stopped.
    func storeAttachmentFiles(
        _ files: [AttachmentUploadFile],
        channelID: ChannelID,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> [String?] {
        guard !files.isEmpty else { return [] }
        let generation = profileEditingGeneration
        let userID = currentUser?.id
        var prepared: [PreparedUploadFile] = []
        defer { prepared.forEach { $0.discard() } }
        for file in files {
            prepared.append(try await prepareUploadFile(file.url))
            try Task.checkCancellation()
            guard profileEditingGeneration == generation, currentUser?.id == userID else { throw ChatProviderError.unauthenticated }
        }
        let files = zip(files, prepared).map { file, prepared in
            var file = file
            file.url = prepared.url
            return file
        }
        let descriptors = try attachmentReservationDescriptors(for: files)
        progress(.reserving(files: files.count))
        let delegates = files.map { file in
            let delegate = AttachmentUploadTaskDelegate { sent, expected in
                progress(.uploading(fileID: file.id, fileName: file.name, completed: sent, total: expected))
            }
            if let id = file.id {
                attachmentUploadDelegates[id] = delegate
                if cancelledAttachmentUploads.contains(id) { delegate.cancel() }
            }
            return delegate
        }
        defer { for id in files.compactMap(\.id) { attachmentUploadDelegates[id] = nil } }
        return try await withThrowingTaskGroup(of: (Int, String?).self) { group in
            for (index, (file, descriptor)) in zip(files, descriptors).enumerated() {
                let delegate = delegates[index]
                group.addTask {
                    do {
                        let slot = try await delegate.reserve { try await self.reserveAttachmentSlot(descriptor, channelID: channelID) }
                        try await self.uploadAttachmentFile(file, to: slot, delegate: delegate, progress: progress)
                        return (index, slot.uploadFilename)
                    } catch where delegate.isCancelled {
                        return (index, nil)
                    }
                }
            }
            var names = [String?](repeating: nil, count: files.count)
            for try await (index, name) in group { names[index] = name }
            return names
        }
    }

    /// Stores a staged file before its message is sent, as the first-party
    /// composer does on attach, so Send has only the message left to post.
    /// Returns whether storage accepted the file.
    public func preuploadAttachment(
        _ attachment: ForumPostAttachment,
        channelID: ChannelID,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async -> Bool {
        let preupload = Task { [self] in
            let file = Self.forumUploadFile(attachment.applyingFilenamePrivacy(await anonymisesUploadFilenames()))
            guard let name = try await storeAttachmentFiles([file], channelID: channelID, progress: progress).first ?? nil
            else { throw CancellationError() }
            return name
        }
        attachmentPreuploads[attachment.id] = preupload
        return (try? await preupload.value) != nil
    }

    /// Drops a staged file's early upload: an unfinished transfer stops and a
    /// stored file is deleted, as the first-party composer does on removal.
    /// A file a message being posted refers to is kept; the post settles it.
    public func discardPreuploadedAttachment(_ attachmentID: UUID) async {
        guard !postingAttachmentUploads.contains(attachmentID),
              let preupload = attachmentPreuploads.removeValue(forKey: attachmentID)
        else { return }
        attachmentUploadDelegates[attachmentID]?.cancel()
        preupload.cancel()
        guard let uploadFilename = try? await preupload.value,
              let path = uploadFilename.addingPercentEncoding(
                  withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
              )
        else { return }
        // One attempt, like the first-party client; an unused stored file expires anyway.
        try? await requestEmpty("/attachments/\(path)", method: "DELETE")
    }

    /// Stops one file of a message send, whether it waits for its turn or is
    /// sending. The message goes without it, or not at all once every one of
    /// its files is stopped. Refused once the message with it is being posted.
    public func cancelAttachmentUpload(_ attachmentID: UUID) async -> Bool {
        guard !postingAttachmentUploads.contains(attachmentID) else { return false }
        cancelledAttachmentUploads.insert(attachmentID)
        attachmentUploadDelegates[attachmentID]?.cancel()
        if attachmentPreuploads[attachmentID] != nil {
            // Its early upload stops or leaves storage without holding up the stop.
            Task { await discardPreuploadedAttachment(attachmentID) }
        }
        return true
    }

    func attachmentReservationDescriptors(
        for files: [AttachmentUploadFile]
    ) throws -> [JSONValue] {
        var descriptors: [JSONValue] = []
        let maximumFileSize = DiscordAttachmentUploadPolicy.maximumFileSize(
            premiumType: currentUser?.premiumType ?? 0
        )
        for (index, file) in files.enumerated() {
            let url = file.url
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard Int64(size) <= maximumFileSize else {
                throw ChatProviderError.invalidRequest(
                    "\(file.name) exceeds the account's Discord upload limit."
                )
            }
            descriptors.append(
                .object([
                    "filename": .string(file.name),
                    "file_size": .number(Double(size)),
                    "id": .string(String(index)),
                    "is_clip": .bool(false),
                    "original_content_type": .string(file.contentType),
                ])
            )
        }
        return descriptors
    }

    func reserveAttachmentSlot(_ descriptor: JSONValue, channelID: ChannelID) async throws -> AttachmentSlotDTO {
        let reservation: AttachmentReservationDTO = try await request(
            "/channels/\(channelID)/attachments",
            method: "POST",
            body: ["files": .array([descriptor])]
        )
        guard let slot = reservation.attachments.first else {
            throw ChatProviderError.invalidRequest("Discord did not reserve the selected attachment.")
        }
        return slot
    }

    func uploadAttachmentFile(
        _ file: AttachmentUploadFile,
        to slot: AttachmentSlotDTO,
        delegate: AttachmentUploadTaskDelegate? = nil,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws {
        if delegate?.isCancelled == true { throw CancellationError() }
        guard let uploadURL = Self.validatedAttachmentUploadURL(from: slot.uploadURL) else {
            throw ChatProviderError.invalidRequest(
                "Discord returned an invalid attachment upload URL.")
        }
        let fileURL = file.url
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { fileURL.stopAccessingSecurityScopedResource() }
        }
        let total = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        progress(.uploading(fileID: file.id, fileName: file.name, completed: 0, total: total))
        let response = try await performStorageUpload(
            fileURL: fileURL, uploadURL: uploadURL, contentType: "application/octet-stream",
            diagnosticTransport: "attachment_storage", diagnosticPath: "/attachments/\(slot.id)",
            delegate: delegate
        )
        guard (200 ..< 300).contains(response.statusCode) else {
            throw apiDiagnostics.coalescing(ChatProviderError.invalidRequest(
                "Discord's attachment storage rejected \(file.name)."), with: response)
        }
        progress(.uploading(fileID: file.id, fileName: file.name, completed: total, total: total))
    }

    func performStorageUpload(
        fileURL: URL,
        uploadURL: URL,
        contentType: String,
        diagnosticTransport: String,
        diagnosticPath path: String,
        delegate: (any URLSessionTaskDelegate)? = nil
    ) async throws -> HTTPURLResponse {
        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "PUT"
        uploadRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        apiDiagnostics.recordHTTPRequest(
            transport: diagnosticTransport, method: "PUT", path: path, body: nil, attempt: 1
        )
        let started = ContinuousClock.now
        let session = restSession
        let generation = restSessionGeneration
        do {
            let (_, rawResponse) = try await session.upload(for: uploadRequest, fromFile: fileURL, delegate: delegate)
            guard let response = rawResponse as? HTTPURLResponse else {
                throw ChatProviderError.invalidRequest(
                    "Discord's attachment storage returned an invalid HTTP response.")
            }
            apiDiagnostics.recordHTTPResponse(
                transport: diagnosticTransport, method: "PUT", path: path, attempt: 1,
                response: response, body: Data(), duration: started.duration(to: .now)
            )
            return response
        } catch {
            apiDiagnostics.recordHTTPFailure(
                transport: diagnosticTransport, method: "PUT", path: path, attempt: 1,
                duration: started.duration(to: .now), error: error
            )
            _ = recoverRESTSessionIfNeeded(after: error, requestGeneration: generation)
            throw error
        }
    }

    nonisolated static func validatedAttachmentUploadURL(
        from value: String
    ) -> URL? {
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }
}
