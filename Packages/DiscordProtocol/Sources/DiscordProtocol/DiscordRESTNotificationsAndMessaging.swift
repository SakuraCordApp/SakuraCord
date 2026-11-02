import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    public func updateDirectMessagePin(
        channelID: ChannelID,
        flags: UInt64
    ) async throws {
        try await updateChannelNotificationSettings(
            guildID: nil,
            channelID: channelID,
            override: ["flags": .number(Double(flags))]
        )
    }

    func updateGuildNotificationSettings(
        guildID: GuildID,
        settings: [String: JSONValue]
    ) async throws {
        // The current first-party client sends one partial guild entry through
        // the bulk user-guild settings route and reconciles the accepted value
        // through USER_GUILD_SETTINGS_UPDATE.
        try await requestEmpty(
            "/users/@me/guilds/settings",
            method: "PATCH",
            body: [
                "guilds": .object([
                    guildID.description: .object(settings),
                ])
            ]
        )
    }

    public func updateChannelMute(
        guildID: GuildID?,
        channelID: ChannelID,
        isMuted: Bool,
        until: Date?
    ) async throws {
        var override: [String: JSONValue] = [
            "muted": .bool(isMuted)
        ]
        if isMuted {
            let muteConfiguration: JSONValue
            if let until {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                muteConfiguration = .object([
                    "end_time": .string(formatter.string(from: until)),
                ])
            } else {
                muteConfiguration = .null
            }
            override["mute_config"] = muteConfiguration
        } else {
            override["mute_config"] = .null
        }
        try await updateChannelNotificationSettings(
            guildID: guildID,
            channelID: channelID,
            override: override
        )
    }

    func updateChannelNotificationSettings(
        guildID: GuildID?,
        channelID: ChannelID,
        override: [String: JSONValue]
    ) async throws {
        // Discord's current client PATCHes a partial channel override keyed by
        // channel ID. Keep this as a single, centrally scheduled mutation and
        // rely on USER_GUILD_SETTINGS_UPDATE for authoritative reconciliation.
        try await requestEmpty(
            "/users/@me/guilds/\(guildID?.description ?? "@me")/settings",
            method: "PATCH",
            body: [
                "channel_overrides": .object([
                    channelID.description: .object(override)
                ])
            ]
        )
    }

    public func updateCategoryNotificationLevel(
        guildID: GuildID,
        categoryID: ChannelID,
        level: MessageNotificationLevel
    ) async throws {
        try await updateCategoryNotificationSettings(
            guildID: guildID,
            categoryID: categoryID,
            override: [
                "message_notifications": .number(Double(level.rawValue))
            ]
        )
    }

    public func updateCategoryMute(
        guildID: GuildID,
        categoryID: ChannelID,
        isMuted: Bool,
        until: Date?
    ) async throws {
        var override: [String: JSONValue] = [
            "muted": .bool(isMuted),
            "mute_config": .null,
        ]
        if isMuted, let until {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            override["mute_config"] = .object([
                "end_time": .string(formatter.string(from: until)),
            ])
        }
        try await updateCategoryNotificationSettings(
            guildID: guildID,
            categoryID: categoryID,
            override: override
        )
    }

    public func updateCategoryCollapsed(
        guildID: GuildID,
        categoryID: ChannelID,
        isCollapsed: Bool
    ) async throws {
        try await updateCategoryNotificationSettings(
            guildID: guildID,
            categoryID: categoryID,
            override: ["collapsed": .bool(isCollapsed)]
        )
    }

    func updateCategoryNotificationSettings(
        guildID: GuildID,
        categoryID: ChannelID,
        override: [String: JSONValue]
    ) async throws {
        // Category overrides and their collapsed state use the current bulk
        // user-guild settings route, scoped to exactly one guild/category.
        try await updateGuildNotificationSettings(
            guildID: guildID,
            settings: [
                "channel_overrides": .object([
                    categoryID.description: .object(override)
                ])
            ]
        )
    }

    public func supports(_ capability: ChatCapability) async -> Bool {
        switch capability {
        case .slashCommands, .components, .modals, .remoteComponentChoices, .forums, .gifs,
             .messageForwarding, .soundboard, .stickers, .stickerSending:
            true
        }
    }

    public func send(_ draft: SendMessageDraft) async throws -> Message {
        try await send(draft, progress: { _ in })
    }

    public func ensurePrivateChannel(for userID: UserID) async throws -> Channel {
        if let existing = (cachedChannels[nil] ?? []).first(where: {
            $0.kind == .directMessage && $0.recipients.contains { $0.id == userID }
        }) {
            return existing
        }
        if let task = privateChannelTasks[userID] {
            return try await task.value
        }
        let task = Task { [self] in
            try await createPrivateChannel(for: userID)
        }
        privateChannelTasks[userID] = task
        defer { privateChannelTasks[userID] = nil }
        return try await task.value
    }

    private func createPrivateChannel(for userID: UserID) async throws -> Channel {
        let dto: ChannelDTO = try await request(
            "/users/@me/channels",
            method: "POST",
            body: ["recipients": .array([.string(userID.description)])]
        )
        let channel = try privateChannel(from: dto)
        upsertPrivateChannel(channel)
        continuation?.yield(.channelsChanged(
            guildID: nil,
            channels: cachedChannels[nil] ?? []
        ))
        return channel
    }

    public func forward(_ draft: ForwardMessageDraft) async throws -> Message {
        let key = "forward:\(draft.destinationChannelID):\(draft.nonce)"
        if let task = messageSendTasks[key] {
            return try await task.value
        }
        let task = Task { [self] in
            try await performForward(draft)
        }
        messageSendTasks[key] = task
        defer { messageSendTasks[key] = nil }
        return try await task.value
    }

    func performForward(_ draft: ForwardMessageDraft) async throws -> Message {
        try requireGuildCommunication(in: draft.destinationChannelID)
        let isKnownChannel = cachedChannels.values.lazy.flatMap(\.self).contains(where: {
            $0.id == draft.destinationChannelID
        })
        let isKnownThread = cachedForumPosts.values.contains { posts in
            posts[draft.destinationChannelID] != nil
        }
        guard isKnownChannel || isKnownThread else {
            throw ChatProviderError.channelNotFound
        }
        var reference: [String: JSONValue] = [
            "type": .number(1),
            "message_id": .string(draft.sourceMessageID.description),
            "channel_id": .string(draft.sourceChannelID.description),
        ]
        if let sourceGuildID = draft.sourceGuildID {
            reference["guild_id"] = .string(sourceGuildID.description)
        }
        let body: [String: JSONValue] = [
            "content": .string(""),
            "nonce": .string(draft.nonce),
            "tts": .bool(false),
            "flags": .number(0),
            "mobile_network_type": .string("unknown"),
            "message_reference": .object(reference),
        ]
        let dto: MessageDTO = try await request(
            "/channels/\(draft.destinationChannelID)/messages",
            method: "POST",
            body: body,
            headers: ["X-Context-Properties": DiscordClientMetadata.forwardingContextHeader]
        )
        var message = try dto.domain()
        message.nonce = draft.nonce
        cachedMessages[message.id] = message
        continuation?.yield(.messageCreated(message))
        return message
    }

    public func send(
        _ draft: SendMessageDraft, progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> Message {
        guard draft.attachmentURLs.count <= SendMessageDraft.maximumAttachmentCount else {
            throw ChatProviderError.invalidRequest(
                "A message can include at most \(SendMessageDraft.maximumAttachmentCount) attachments."
            )
        }
        let key = "\(draft.channelID):\(draft.nonce)"
        if let task = messageSendTasks[key] {
            let message = try await task.value
            progress(.completed(messageID: message.id))
            return message
        }
        let task = Task { [self] in
            try await performSend(draft, progress: progress)
        }
        messageSendTasks[key] = task
        // Cleared in the job that answers the caller, so no stop is accepted
        // between the post finishing and the caller learning of it.
        defer {
            messageSendTasks[key] = nil
            postingAttachmentUploads.subtract(draft.attachments.map(\.id))
        }
        let message: Message
        do {
            message = try await task.value
        } catch {
            // Discord rejects a stored file it no longer has (code 50146 once it
            // expires), so after a rejected post Retry stores the files again.
            if case let ChatProviderError.transport(status, _) = error, (400 ..< 500).contains(status), status != 429 {
                for attachment in draft.attachments {
                    Task { await discardPreuploadedAttachment(attachment.id) }
                }
            }
            throw error
        }
        // The message now holds its files. Any other failed send keeps them,
        // so Retry reuses them, as the official resend does, and discarding
        // the message deletes them.
        for attachment in draft.attachments { attachmentPreuploads[attachment.id] = nil }
        return message
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
        let original = chosenName.isEmpty ? attachment.url.lastPathComponent : chosenName
        let name =
            attachment.isSpoiler && !original.hasPrefix("SPOILER_")
                ? "SPOILER_\(original)" : original
        let description = attachment.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return AttachmentUploadFile(
            url: attachment.url,
            name: name,
            description: description.isEmpty ? nil : description,
            id: attachment.id
        )
    }

    nonisolated static func uploadedAttachmentPayload(
        id: Int,
        file: AttachmentUploadFile,
        uploadFilename: String
    ) -> JSONValue {
        var payload: [String: JSONValue] = [
            "id": .string(String(id)),
            "filename": .string(file.name),
            "uploaded_filename": .string(uploadFilename),
        ]
        if let description = file.description {
            payload["description"] = .string(description)
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

    /// Reserves storage for the files together, then sends every file at once,
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
        let files = zip(files, prepared).map {
            AttachmentUploadFile(url: $1.url, name: $0.name, description: $0.description, id: $0.id)
        }
        let descriptors = try attachmentReservationDescriptors(for: files)
        let reservation = try await reserveAttachmentSlots(
            descriptors: descriptors,
            channelID: channelID,
            fileCount: files.count,
            progress: progress
        )
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
            for (index, (file, slot)) in zip(files, reservation.attachments).enumerated() {
                let delegate = delegates[index]
                group.addTask {
                    do {
                        try await self.uploadAttachmentFile(file, to: slot, delegate: delegate, progress: progress)
                    } catch where delegate.isCancelled {
                        return (index, nil)
                    }
                    return (index, slot.uploadFilename)
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
    public func discardPreuploadedAttachment(_ attachmentID: UUID) async {
        guard let preupload = attachmentPreuploads.removeValue(forKey: attachmentID) else { return }
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
                ])
            )
        }
        return descriptors
    }

    func reserveAttachmentSlots(
        descriptors: [JSONValue],
        channelID: ChannelID,
        fileCount: Int,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> AttachmentReservationDTO {
        progress(.reserving(files: fileCount))
        let reservation: AttachmentReservationDTO = try await request(
            "/channels/\(channelID)/attachments",
            method: "POST",
            body: ["files": .array(descriptors)]
        )
        guard reservation.attachments.count == fileCount else {
            throw ChatProviderError.invalidRequest(
                "Discord did not reserve every selected attachment.")
        }
        return reservation
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
    public func edit(_ message: Message, content: String) async throws -> Message {
        try requireGuildCommunication(in: message.channelID)
        var body: [String: JSONValue] = ["content": .string(content)]
        body["allowed_mentions"] = message.editAllowedMentionsPayload
        let dto: MessageDTO = try await request(
            "/channels/\(message.channelID)/messages/\(message.id)", method: "PATCH", body: body
        )
        let updated = try dto.domain()
        cachedMessages[updated.id] = updated
        continuation?.yield(.messageUpdated(updated))
        return updated
    }

    public func delete(messageID: MessageID, channelID: ChannelID) async throws {
        try await requestEmpty("/channels/\(channelID)/messages/\(messageID)", method: "DELETE")
        cachedMessages[messageID] = nil
        continuation?.yield(.messageDeleted(channelID: channelID, messageID: messageID))
    }

    private func messageForReaction(_ messageID: MessageID, channelID: ChannelID) async throws -> Message {
        if let message = cachedMessages[messageID] { return message }
        // A visible message can outlive the provider's bounded working set.
        let page = try await messages(in: channelID, anchoredAt: .around(messageID), limit: 1)
        guard let message = page.messages.first(where: { $0.id == messageID }) else {
            throw ChatProviderError.messageNotFound
        }
        return message
    }

    public func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID)
        async throws
    {
        let message = try await messageForReaction(messageID, channelID: channelID)
        let apiEmoji = Self.reactionAPIValue(emoji)
        let existing = message.reactions.firstIndex { Self.reactionAPIValue($0.emoji) == apiEmoji }
        let reacted = existing.map { message.reactions[$0].didCurrentUserReact } ?? false
        try await setReaction(
            emoji,
            reacted: !reacted,
            messageID: messageID,
            channelID: channelID
        )
    }

    public func setReaction(
        _ emoji: String,
        reacted: Bool,
        messageID: MessageID,
        channelID: ChannelID
    ) async throws {
        try requireGuildCommunication(in: channelID)
        let message = try await messageForReaction(messageID, channelID: channelID)
        let apiEmoji = Self.reactionAPIValue(emoji)
        let currentReaction = message.reactions.first {
            Self.reactionAPIValue($0.emoji) == apiEmoji
        }
        guard (currentReaction?.didCurrentUserReact ?? false) != reacted else { return }
        let encoded =
            apiEmoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? apiEmoji
        let method = reacted ? "PUT" : "DELETE"
        let (data, response) = try await perform(
            "/channels/\(channelID)/messages/\(messageID)/reactions/\(encoded)/@me",
            method: method, query: [], body: nil
        )
        if response.statusCode == 429 {
            throw apiDiagnostics.coalescing(ChatProviderError.rateLimited(
                retryAfter: Self.retryAfter(from: data, response: response),
                requestID: response.value(forHTTPHeaderField: "x-request-id")
            ), with: response)
        }
        try validateEmptyResponse(data, response)
        invalidateReactionReactors(channelID: channelID, messageID: messageID, reactionID: Reaction(emoji: emoji, count: 0).id)
        guard let currentUserID = currentUser?.id,
              var updated = cachedMessages[messageID]
        else { return }
        let reactionUpdate: MessageReactionUpdate =
            reacted
            ? .add(
                channelID: channelID,
                messageID: messageID,
                userID: currentUserID,
                emoji: emoji,
                kind: .normal
            )
            : .remove(
                channelID: channelID,
                messageID: messageID,
                userID: currentUserID,
                emoji: emoji,
                kind: .normal
            )
        guard updated.applyReactionUpdate(reactionUpdate, currentUserID: currentUserID) else {
            return
        }
        cachedMessages[messageID] = updated
        continuation?.yield(.messageUpdated(updated))
        updateForumPostForMessage(updated)
    }

    public func reactionReactors(
        for emoji: String,
        messageID: MessageID,
        channelID: ChannelID,
        reactionCount: Int
    ) async throws -> [ReactionReactor] {
        guard reactionCount > 0 else { return [] }
        let apiEmoji = Self.reactionAPIValue(emoji)
        let key = ReactionReactorCacheKey(
            channelID: channelID,
            messageID: messageID,
            emojiIdentity: Reaction(emoji: emoji, count: reactionCount).id,
            reactionCount: reactionCount
        )
        if let cached = cachedReactionReactors[key] {
            return cached
        }
        if let task = reactionReactorTasks[key], let loadID = reactionReactorTaskIDs[key] {
            let reactors = try await task.value
            if let cached = cachedReactionReactors[key] { return cached }
            guard reactionReactorTaskIDs[key] == loadID else { throw CancellationError() }
            return reactors
        }
        guard reactionReactorTasks.count < Self.maximumConcurrentReactionReactorReads else {
            throw ChatProviderError.invalidRequest(
                "Too many reaction details are already loading. Hover this reaction again shortly."
            )
        }

        let encoded =
            apiEmoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? apiEmoji
        let loadID = UUID()
        reactionReactorTaskIDs[key] = loadID
        let task = Task { [self] in
            do {
                let users: [UserDTO] = try await request(
                "/channels/\(channelID)/messages/\(messageID)/reactions/\(encoded)",
                query: [
                    URLQueryItem(name: "type", value: "0"),
                    URLQueryItem(
                        name: "limit",
                        value: String(Self.reactionReactorFetchLimit)
                    ),
                ]
            )
                #if DEBUG
                    await reactorResponseReceivedForTesting?()
                #endif
                try Task.checkCancellation()
                guard reactionReactorTaskIDs[key] == loadID else { throw CancellationError() }
                return try users.map { ReactionReactor(user: try $0.domain()) }
            } catch {
                // URLSession may report cancellation as URLError.cancelled.
                // Invalidated reads must not become a preview failure cooldown.
                try Task.checkCancellation()
                throw error
            }
        }
        reactionReactorTasks[key] = task
        do {
            let reactors = try await task.value
            guard reactionReactorTaskIDs[key] == loadID else { throw CancellationError() }
            reactionReactorTasks[key] = nil
            reactionReactorTaskIDs[key] = nil
            cacheReactionReactors(reactors, for: key)
            return reactors
        } catch {
            if reactionReactorTaskIDs[key] == loadID {
                reactionReactorTasks[key] = nil
                reactionReactorTaskIDs[key] = nil
            }
            throw error
        }
    }

    func invalidateReactionReactors(channelID: ChannelID, messageID: MessageID, reactionID: String? = nil) {
        func matches(_ key: ReactionReactorCacheKey) -> Bool {
            key.channelID == channelID && key.messageID == messageID
                && (reactionID == nil || key.emojiIdentity == reactionID)
        }
        for key in reactionReactorTasks.keys
        where matches(key) {
            reactionReactorTasks.removeValue(forKey: key)?.cancel()
            reactionReactorTaskIDs[key] = nil
        }
        cachedReactionReactors = cachedReactionReactors.filter { !matches($0.key) }
        reactionReactorCacheOrder.removeAll { matches($0) }
    }

    func cacheReactionReactors(
        _ reactors: [ReactionReactor],
        for key: ReactionReactorCacheKey
    ) {
        cachedReactionReactors[key] = reactors
        reactionReactorCacheOrder.removeAll { $0 == key }
        reactionReactorCacheOrder.append(key)
        while reactionReactorCacheOrder.count > Self.maximumReactionReactorCacheEntries {
            let evicted = reactionReactorCacheOrder.removeFirst()
            cachedReactionReactors[evicted] = nil
        }
    }

    static func reactionAPIValue(_ emoji: String) -> String {
        guard emoji.hasPrefix("<"), emoji.hasSuffix(">") else { return emoji }
        let value = emoji.dropFirst().dropLast()
        let withoutAnimationPrefix = value.hasPrefix("a:") ? value.dropFirst(2) : value.dropFirst(1)
        return String(withoutAnimationPrefix)
    }

}
