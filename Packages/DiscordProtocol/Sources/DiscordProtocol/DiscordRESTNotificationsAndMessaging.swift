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
        capability == .slashCommands || capability == .forums || capability == .gifs
            || capability == .messageForwarding || capability == .soundboard
            || capability == .stickers || capability == .stickerSending
    }

    public func applicationCommandCatalog(for target: ApplicationCommandIndexTarget) async throws
        -> ApplicationCommandCatalog
    {
        if let cached = cachedApplicationCommandCatalogs[target] {
            return cached
        }
        if let task = applicationCommandCatalogTasks[target] {
            return try await task.value
        }
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.fetchApplicationCommandCatalog(for: target)
        }
        applicationCommandCatalogTasks[target] = task
        do {
            let catalog = try await task.value
            applicationCommandCatalogTasks[target] = nil
            cachedApplicationCommandCatalogs[target] = catalog
            return catalog
        } catch {
            applicationCommandCatalogTasks[target] = nil
            throw error
        }
    }

    public func requestApplicationCommandAutocomplete(
        _ request: ApplicationCommandAutocompleteRequest
    ) async throws {
        let payload = try ApplicationCommandPayloadBuilder.autocomplete(request)
        guard
            let focused = request.invocation.command.options.first(where: {
                $0.id == request.focusedOptionID
            })
        else {
            throw ChatProviderError.invalidRequest(
                "The focused autocomplete option is unavailable.")
        }
        guard let sessionID = await gatewaySession?.snapshot().sessionID else {
            throw ChatProviderError.invalidRequest(
                "Discord Gateway is not ready for command autocomplete."
            )
        }
        var body: [String: JSONValue] = [
            "type": .number(4),
            "application_id": .string(request.invocation.command.applicationID),
            "channel_id": .string(request.invocation.channelID.description),
            "session_id": .string(sessionID),
            "data": .object(payload.data),
            "nonce": .string(request.nonce),
        ]
        if let guildID = request.invocation.guildID {
            body["guild_id"] = .string(guildID.description)
        }
        pendingAutocompleteTypes[request.nonce] = focused.type
        autocompleteTimeoutTasks[request.nonce]?.cancel()
        do {
            let (_, response) = try await perform(
                "/interactions", method: "POST", query: [], body: body
            )
            guard response.statusCode == 204 else {
                pendingAutocompleteTypes[request.nonce] = nil
                throw apiDiagnostics.coalescing(interactionTransportError(response), with: response)
            }
        } catch {
            pendingAutocompleteTypes[request.nonce] = nil
            throw error
        }
        autocompleteTimeoutTasks[request.nonce] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.expireAutocomplete(nonce: request.nonce)
        }
    }

    public func executeApplicationCommand(
        _ invocation: ApplicationCommandInvocation,
        progress: @escaping @Sendable (ApplicationCommandProgress) -> Void
    ) async throws {
        progress(.preparing)
        var payload = try ApplicationCommandPayloadBuilder.execution(invocation)
        guard let sessionID = await gatewaySession?.snapshot().sessionID else {
            throw ChatProviderError.invalidRequest(
                "Discord Gateway is not ready for application commands.")
        }
        if !payload.attachmentURLs.isEmpty {
            let descriptors = try await uploadAttachments(
                payload.attachmentURLs,
                channelID: invocation.channelID
            ) { state in
                switch state {
                case .reserving(let files): progress(.reserving(files: files))
                case .uploading(let fileName, let completed, let total):
                    progress(.uploading(fileName: fileName, completed: completed, total: total))
                default: break
                }
            }
            payload.data["attachments"] = .array(descriptors)
        }
        var body: [String: JSONValue] = [
            "type": .number(2),
            "application_id": .string(invocation.command.applicationID),
            "channel_id": .string(invocation.channelID.description),
            "session_id": .string(sessionID),
            "data": .object(payload.data),
            "nonce": .string(invocation.nonce),
            "analytics_location": .string("slash_ui"),
        ]
        if let guildID = invocation.guildID {
            body["guild_id"] = .string(guildID.description)
        }
        progress(.submitting(nonce: invocation.nonce))
        let (_, response) = try await perform(
            "/interactions", method: "POST", query: [], body: body
        )
        guard response.statusCode == 204 else {
            throw apiDiagnostics.coalescing(interactionTransportError(response), with: response)
        }
        progress(.awaitingResponse(nonce: invocation.nonce))
    }

    public func submitModal(_ submission: ModalSubmission, nonce: String) async throws {
        guard let context = pendingModalContexts[nonce] else {
            throw ChatProviderError.invalidRequest("The interaction form is no longer active.")
        }
        guard let sessionID = await gatewaySession?.snapshot().sessionID else {
            throw ChatProviderError.invalidRequest(
                "Discord Gateway is not ready for interaction forms.")
        }
        let orderedFileKeys = submission.fileURLs.keys.sorted()
        var attachmentIDsByCustomID: [String: [String]] = [:]
        var allFiles: [URL] = []
        for key in orderedFileKeys {
            let urls = submission.fileURLs[key] ?? []
            attachmentIDsByCustomID[key] = (allFiles.count ..< allFiles.count + urls.count).map(
                String.init)
            allFiles.append(contentsOf: urls)
        }
        var descriptors: [JSONValue] = []
        if !allFiles.isEmpty {
            guard let channelID = ChannelID(context.channelID) else {
                throw ChatProviderError.invalidRequest("The interaction form has no valid channel.")
            }
            descriptors = try await uploadAttachments(
                allFiles, channelID: channelID, progress: { _ in }
            )
        }
        var data: [String: JSONValue] = [
            "custom_id": .string(submission.customID),
            "components": .array(
                context.modal.controls.map {
                    modalResponse(
                        $0, values: submission.values, attachmentIDs: attachmentIDsByCustomID)
                }),
        ]
        if !descriptors.isEmpty {
            data["resolved"] = .object([
                "attachments": .object(
                    Dictionary(
                        uniqueKeysWithValues: descriptors.enumerated().map {
                            (String($0.offset), $0.element)
                        })
                )
            ])
        }
        var body: [String: JSONValue] = [
            "type": .number(5),
            "application_id": .string(context.applicationID),
            "channel_id": .string(context.channelID),
            "session_id": .string(sessionID),
            "data": .object(data),
            "nonce": .string(nonce),
        ]
        if let guildID = context.guildID { body["guild_id"] = .string(guildID) }
        let (_, response) = try await perform(
            "/interactions", method: "POST", query: [], body: body
        )
        guard response.statusCode == 204 else { throw apiDiagnostics.coalescing(interactionTransportError(response), with: response) }
        pendingModalContexts[nonce] = nil
    }

    func fetchApplicationCommandCatalog(for target: ApplicationCommandIndexTarget)
        async throws
        -> ApplicationCommandCatalog
    {
        let path: String =
            switch target {
            case .guild(let id): "/guilds/\(id)/application-command-index"
            case .channel(let id): "/channels/\(id)/application-command-index"
            case .user: "/users/@me/application-command-index"
            case .application(let id): "/applications/\(id)/application-command-index"
            }
        for attempt in 0 ..< 3 {
            let (data, response) = try await perform(
                path, method: "GET", query: [], body: nil, maximumAttempts: 1
            )
            if response.statusCode == 202 {
                guard attempt < 2 else {
                    throw ChatProviderError.transport(
                        status: 202,
                        requestID: response.value(forHTTPHeaderField: "x-request-id")
                    )
                }
                try await Task.sleep(for: .seconds(5))
                continue
            }
            if response.statusCode == 429 {
                guard attempt < 2 else { throw apiDiagnostics.coalescing(interactionTransportError(response), with: response) }
                let delay = Self.retryAfter(from: data, response: response)
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            guard (200 ..< 300).contains(response.statusCode) else {
                throw apiDiagnostics.coalescing(interactionTransportError(response), with: response)
            }
            return try ApplicationCommandIndexDecoder.decode(data, target: target)
        }
        throw ChatProviderError.invalidRequest(
            "Discord's application command index did not become ready.")
    }

    func expireAutocomplete(nonce: String) {
        guard pendingAutocompleteTypes.removeValue(forKey: nonce) != nil else { return }
        autocompleteTimeoutTasks[nonce] = nil
        continuation?.yield(
            .interaction(.failed(nonce: nonce, message: "Command autocomplete timed out."))
        )
    }

    func interactionTransportError(_ response: HTTPURLResponse) -> ChatProviderError {
        if response.statusCode == 401 {
            return .unauthenticated
        }
        return .transport(
            status: response.statusCode,
            requestID: response.value(forHTTPHeaderField: "x-request-id")
        )
    }

    func modalResponse(
        _ control: ModalControl,
        values: [String: [String]],
        attachmentIDs: [String: [String]]
    ) -> JSONValue {
        switch control {
        case .label(_, _, _, let child):
            return .object([
                "type": .number(18),
                "component": modalResponse(
                    child, values: values, attachmentIDs: attachmentIDs
                ),
            ])
        case .textInput(_, let customID, _, _, _, _, _, _, _):
            return .object([
                "type": .number(4), "custom_id": .string(customID),
                "value": .string(values[customID]?.first ?? ""),
            ])
        case .select(_, let customID, let kind, _, _, _, _):
            return .object([
                "type": .number(Double(kind.rawValue)), "custom_id": .string(customID),
                "values": .array((values[customID] ?? []).map(JSONValue.string)),
            ])
        case .fileUpload(_, let customID, _, _, _):
            return .object([
                "type": .number(19), "custom_id": .string(customID),
                "values": .array((attachmentIDs[customID] ?? []).map(JSONValue.string)),
            ])
        case .radioGroup(_, let customID, _, _):
            return .object([
                "type": .number(21), "custom_id": .string(customID),
                "value": values[customID]?.first.map(JSONValue.string) ?? .null,
            ])
        case .checkboxGroup(_, let customID, _, _, _):
            return .object([
                "type": .number(22), "custom_id": .string(customID),
                "values": .array((values[customID] ?? []).map(JSONValue.string)),
            ])
        case .checkbox(_, let customID, _, _):
            return .object([
                "type": .number(23), "custom_id": .string(customID),
                "value": .bool(values[customID]?.first == "true"),
            ])
        case .unsupported(_, let type):
            return .object(["type": .number(Double(type))])
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
        let channel = try dto.domain(
            guildID: nil,
            knownUsersByID: cachedGatewayUsersByID
        )
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
        do {
            let message = try await task.value
            messageSendTasks[key] = nil
            return message
        } catch {
            messageSendTasks[key] = nil
            throw error
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
        let original = chosenName.isEmpty ? attachment.url.lastPathComponent : chosenName
        let name =
            attachment.isSpoiler && !original.hasPrefix("SPOILER_")
                ? "SPOILER_\(original)" : original
        let description = attachment.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return AttachmentUploadFile(
            url: attachment.url,
            name: name,
            description: description.isEmpty ? nil : description
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
        let generation = profileEditingGeneration
        let userID = currentUser?.id
        var prepared: [PreparedUploadFile] = []
        defer { prepared.forEach { $0.discard() } }
        for file in files {
            prepared.append(try await prepareUploadFile(file.url))
            try Task.checkCancellation()
            guard profileEditingGeneration == generation, currentUser?.id == userID else { throw ChatProviderError.unauthenticated }
        }
        let files = zip(files, prepared).map { AttachmentUploadFile(url: $1.url, name: $0.name, description: $0.description) }
        let descriptors = try attachmentReservationDescriptors(for: files)
        let reservation = try await reserveAttachmentSlots(
            descriptors: descriptors,
            channelID: channelID,
            fileCount: files.count,
            progress: progress
        )
        var uploaded: [JSONValue] = []
        for (file, slot) in zip(files, reservation.attachments) {
            try await uploadAttachmentFile(file, to: slot, progress: progress)
            uploaded.append(
                Self.uploadedAttachmentPayload(
                    id: slot.id,
                    file: file,
                    uploadFilename: slot.uploadFilename
                )
            )
        }
        return uploaded
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
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws {
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
        progress(.uploading(fileName: file.name, completed: 0, total: total))
        let response = try await performStorageUpload(
            fileURL: fileURL, uploadURL: uploadURL, contentType: "application/octet-stream",
            diagnosticTransport: "attachment_storage", diagnosticPath: "/attachments/\(slot.id)"
        )
        guard (200 ..< 300).contains(response.statusCode) else {
            throw apiDiagnostics.coalescing(ChatProviderError.invalidRequest(
                "Discord's attachment storage rejected \(file.name)."), with: response)
        }
        progress(.uploading(fileName: file.name, completed: total, total: total))
    }

    func performStorageUpload(
        fileURL: URL,
        uploadURL: URL,
        contentType: String,
        diagnosticTransport: String,
        diagnosticPath path: String
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
            let (_, rawResponse) = try await session.upload(for: uploadRequest, fromFile: fileURL)
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
    public func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws
        -> Message
    {
        let dto: MessageDTO = try await request(
            "/channels/\(channelID)/messages/\(messageID)", method: "PATCH",
            body: ["content": .string(content)]
        )
        let message = try dto.domain()
        cachedMessages[message.id] = message
        continuation?.yield(.messageUpdated(message))
        return message
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
        let message = try await messageForReaction(messageID, channelID: channelID)
        let apiEmoji = Self.reactionAPIValue(emoji)
        let currentReaction = message.reactions.first {
            Self.reactionAPIValue($0.emoji) == apiEmoji
        }
        guard (currentReaction?.didCurrentUserReact ?? false) != reacted else { return }
        let encoded =
            apiEmoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? apiEmoji
        let method = reacted ? "PUT" : "DELETE"
        try await requestEmpty(
            "/channels/\(channelID)/messages/\(messageID)/reactions/\(encoded)/@me", method: method
        )
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
        if let task = reactionReactorTasks[key] {
            return try await task.value
        }
        guard reactionReactorTasks.count < Self.maximumConcurrentReactionReactorReads else {
            throw ChatProviderError.invalidRequest(
                "Too many reaction details are already loading. Hover this reaction again shortly."
            )
        }

        let encoded =
            apiEmoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? apiEmoji
        let task = Task { [self] in
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
            return try users.map { ReactionReactor(user: try $0.domain()) }
        }
        reactionReactorTasks[key] = task
        do {
            let reactors = try await task.value
            reactionReactorTasks[key] = nil
            cacheReactionReactors(reactors, for: key)
            return reactors
        } catch {
            reactionReactorTasks[key] = nil
            throw error
        }
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
