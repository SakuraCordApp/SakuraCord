import Foundation
import SakuraCordModels
import UniformTypeIdentifiers

/// Where an outbound interaction was invoked. Gateway modal events omit the
/// guild, so the opener's context is retained per nonce.
struct PendingInteractionContext: Sendable {
    var applicationID: String
    var channelID: ChannelID
    var guildID: GuildID?
}

extension DiscordRESTProvider {
    static let maximumRetainedInteractionContexts = 64
    /// Local backstop for autocomplete. Discord normally reports a missed
    /// acknowledgement first; late choices for the same nonce still publish.
    static let autocompleteResponseDeadline: Duration = .seconds(5)

    public func applicationCommandCatalog(for target: ApplicationCommandIndexTarget) async throws
        -> ApplicationCommandCatalog
    {
        if let cached = cachedApplicationCommandCatalogs[target] {
            return resolvingCommandApplicationIdentities(in: cached)
        }
        if let task = applicationCommandCatalogTasks[target] {
            let catalog = try await task.value
            guard !task.isCancelled else { throw CancellationError() }
            return resolvingCommandApplicationIdentities(in: catalog)
        }
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.fetchApplicationCommandCatalog(for: target)
        }
        applicationCommandCatalogTasks[target] = task
        do {
            let catalog = try await task.value
            guard !task.isCancelled else { throw CancellationError() }
            applicationCommandCatalogTasks[target] = nil
            cachedApplicationCommandCatalogs[target] = catalog
            return resolvingCommandApplicationIdentities(in: catalog)
        } catch {
            // Invalidation cancels and removes the old task. It may finish
            // after a replacement has started; never remove that replacement.
            if !task.isCancelled { applicationCommandCatalogTasks[target] = nil }
            throw error
        }
    }

    /// Index entries can carry only bot_id. Reuse the live user cache instead
    /// of inventing a second identity (or making a profile request per app).
    private func resolvingCommandApplicationIdentities(in catalog: ApplicationCommandCatalog) -> ApplicationCommandCatalog {
        var result = catalog
        result.applications = catalog.applications.map { application in
            var application = application
            let botID = application.botID?.description ?? application.bot?.id.description ?? application.id
            if let dto = cachedGatewayUsersByID[botID], let user = try? dto.domain() {
                application.bot = user
            }
            return application
        }
        let applications = Dictionary(result.applications.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        result.commands = catalog.commands.map { command in
            var command = command
            command.application = applications[command.applicationID] ?? command.application
            return command
        }
        return result
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
                guard attempt < 2 else {
                    throw interactionTransportError(data, response)
                }
                let delay = Self.retryAfter(from: data, response: response)
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            guard (200 ..< 300).contains(response.statusCode) else {
                throw interactionTransportError(data, response)
            }
            return try ApplicationCommandIndexDecoder.decode(data, target: target)
        }
        throw ChatProviderError.invalidRequest(
            "Discord's application command index did not become ready.")
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
        let sessionID = try await interactionSessionID()
        // Observed autocomplete requests omit execution attachments and analytics.
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
        rememberAutocompleteOptionType(focused.type, nonce: request.nonce)
        autocompleteTimeoutTasks[request.nonce]?.cancel()
        autocompleteTimeoutTasks[request.nonce] = Task { [weak self] in
            try? await Task.sleep(for: Self.autocompleteResponseDeadline)
            guard !Task.isCancelled else { return }
            await self?.expireAutocomplete(nonce: request.nonce)
        }
        do {
            let (data, response) = try await perform(
                "/interactions", method: "POST", query: [], body: body
            )
            guard response.statusCode == 204 else {
                forgetAutocomplete(nonce: request.nonce)
                throw interactionTransportError(data, response)
            }
        } catch {
            forgetAutocomplete(nonce: request.nonce)
            throw error
        }

    }

    public func executeApplicationCommand(
        _ invocation: ApplicationCommandInvocation,
        progress: @escaping @Sendable (ApplicationCommandProgress) -> Void
    ) async throws {
        try requireGuildCommunication(in: invocation.channelID, guildID: invocation.guildID)
        progress(.preparing)
        var payload = try ApplicationCommandPayloadBuilder.execution(invocation)
        let sessionID = try await interactionSessionID()
        var attachments: [JSONValue] = []
        if !payload.attachmentURLs.isEmpty {
            attachments = try await uploadInteractionAttachments(
                payload.attachmentURLs,
                channelID: invocation.channelID
            ) { state in
                switch state {
                case .reserving(let files): progress(.reserving(files: files))
                case .uploading(_, let fileName, let completed, let total):
                    progress(.uploading(fileName: fileName, completed: completed, total: total))
                default: break
                }
            }
        }
        // The official client always sends the attachment table, empty when unused.
        payload.data["attachments"] = .array(attachments)
        var body: [String: JSONValue] = [
            "type": .number(2),
            "application_id": .string(invocation.command.applicationID),
            "channel_id": .string(invocation.channelID.description),
            "session_id": .string(sessionID),
            "data": .object(payload.data),
            "nonce": .string(invocation.nonce),
            // Context-menu invocations were also observed with this value.
            "analytics_location": .string("slash_ui"),
        ]
        if let guildID = invocation.guildID {
            body["guild_id"] = .string(guildID.description)
        }
        rememberInteractionContext(
            PendingInteractionContext(
                applicationID: invocation.command.applicationID,
                channelID: invocation.channelID,
                guildID: invocation.guildID
            ),
            nonce: invocation.nonce
        )
        progress(.submitting(nonce: invocation.nonce))
        let (data, response) = try await perform(
            "/interactions", method: "POST", query: [], body: body
        )
        guard response.statusCode == 204 else {
            throw interactionTransportError(data, response)
        }
        progress(.awaitingResponse(nonce: invocation.nonce))
    }

    public func submitComponentInteraction(
        _ submission: ComponentInteractionSubmission
    ) async throws {
        let sessionID = try await interactionSessionID()
        var data: [String: JSONValue] = [
            "component_type": .number(Double(submission.kind.componentType)),
            "custom_id": .string(submission.customID),
        ]
        // Buttons carry only component_type and custom_id. Selects repeat the
        // component type as `type` and keep the selection order.
        if submission.kind != .button {
            data["type"] = .number(Double(submission.kind.componentType))
            data["values"] = .array(submission.values.map(JSONValue.string))
        }
        var body: [String: JSONValue] = [
            "type": .number(3),
            "nonce": .string(submission.nonce),
            "channel_id": .string(submission.channelID.description),
            "message_flags": .number(Double(submission.messageFlags.rawValue)),
            "message_id": .string(submission.messageID.description),
            "application_id": .string(submission.applicationID.description),
            "session_id": .string(sessionID),
            "data": .object(data),
        ]
        if let guildID = submission.guildID {
            body["guild_id"] = .string(guildID.description)
        }
        rememberInteractionContext(
            PendingInteractionContext(
                applicationID: submission.applicationID.description,
                channelID: submission.channelID,
                guildID: submission.guildID
            ),
            nonce: submission.nonce
        )
        let (responseData, response) = try await perform(
            "/interactions", method: "POST", query: [], body: body
        )
        guard response.statusCode == 204 else {
            throw interactionTransportError(responseData, response)
        }
    }

    public func submitModal(_ submission: ModalSubmission) async throws {
        let modal = submission.modal
        guard modal.isSubmittable else {
            throw ChatProviderError.invalidRequest(
                "This form contains a field SakuraCord cannot submit yet."
            )
        }
        let sessionID = try await interactionSessionID()
        let plan = ModalSubmissionPayloadBuilder.plan(submission)
        var descriptors: [JSONValue] = []
        if !plan.fileURLs.isEmpty {
            descriptors = try await uploadInteractionAttachments(
                plan.fileURLs, channelID: modal.channelID, progress: { _ in }
            )
        }
        var data: [String: JSONValue] = [
            "id": .string(modal.interactionID),
            "custom_id": .string(modal.customID),
            "components": .array(plan.components),
        ]
        if !descriptors.isEmpty {
            data["attachments"] = .array(descriptors)
        }
        var body: [String: JSONValue] = [
            "type": .number(5),
            "application_id": .string(modal.application.id),
            "channel_id": .string(modal.channelID.description),
            "session_id": .string(sessionID),
            "data": .object(data),
            "nonce": .string(submission.nonce),
        ]
        if let guildID = modal.guildID {
            body["guild_id"] = .string(guildID.description)
        }
        rememberInteractionContext(
            PendingInteractionContext(
                applicationID: modal.application.id,
                channelID: modal.channelID,
                guildID: modal.guildID
            ),
            nonce: submission.nonce
        )
        let (responseData, response) = try await perform(
            "/interactions", method: "POST", query: [], body: body
        )
        if response.statusCode == 400,
           let rejection = ModalSubmissionPayloadBuilder.rejection(
               from: responseData, modal: modal
           )
        {
            throw apiDiagnostics.coalescing(rejection, with: response)
        }
        guard response.statusCode == 204 else {
            throw interactionTransportError(responseData, response)
        }
    }

    public func componentChoices(
        kind: ComponentSelectKind, query: String, guildID: GuildID?, channelID: ChannelID
    ) async throws -> [ComponentSelectOption] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ value: String) -> Bool {
            normalized.isEmpty || value.localizedCaseInsensitiveContains(normalized)
        }
        var choices: [ComponentSelectOption] = []
        if kind == .user || kind == .mentionable {
            let members: [Member]
            if let guildID, !normalized.isEmpty {
                members = try await searchMembers(in: guildID, query: normalized, limit: 25)
            } else {
                members = try await self.members(in: guildID).filter {
                    matches($0.user.displayName) || matches($0.user.username)
                }
            }
            choices += members.prefix(25).map {
                ComponentSelectOption(
                    label: $0.user.displayName, value: $0.id.description,
                    description: "@\($0.user.username)", imageURL: $0.user.avatarURL,
                    imageShape: .circle, entityKind: .user
                )
            }
        }
        if kind == .role || kind == .mentionable, let guildID {
            choices += try await roles(in: guildID)
                .filter { matches($0.name) }
                .sorted { $0.position > $1.position }
                .prefix(25)
                .map {
                    ComponentSelectOption(
                        label: $0.name, value: $0.id.description, imageURL: $0.iconURL,
                        imageShape: .roundedRectangle, entityKind: .role, colorHex: $0.colorHex,
                        unicodeEmoji: $0.unicodeEmoji
                    )
                }
        }
        if kind == .channel {
            choices += try await channels(in: guildID)
                .filter { matches($0.name) }
                .prefix(25)
                .map {
                    ComponentSelectOption(
                        label: $0.name, value: $0.id.description, description: $0.category,
                        entityKind: .channel, channelKind: $0.kind
                    )
                }
        }
        return Array(choices.prefix(25))
    }

    func interactionSessionID() async throws -> String {
        guard let sessionID = await gatewaySession?.snapshot().sessionID else {
            throw ChatProviderError.invalidRequest(
                "Discord Gateway is not ready for application interactions."
            )
        }
        return sessionID
    }

    func rememberInteractionContext(_ context: PendingInteractionContext, nonce: String) {
        if pendingInteractionContexts.updateValue(context, forKey: nonce) == nil {
            pendingInteractionContextOrder.append(nonce)
        }
        while pendingInteractionContextOrder.count > Self.maximumRetainedInteractionContexts {
            pendingInteractionContexts[pendingInteractionContextOrder.removeFirst()] = nil
        }
    }

    func rememberAutocompleteOptionType(_ type: ApplicationCommandOptionType, nonce: String) {
        if autocompleteOptionTypes.updateValue(type, forKey: nonce) == nil {
            autocompleteNonceOrder.append(nonce)
        }
        while autocompleteNonceOrder.count > Self.maximumRetainedInteractionContexts {
            let evicted = autocompleteNonceOrder.removeFirst()
            autocompleteOptionTypes[evicted] = nil
            autocompleteTimeoutTasks.removeValue(forKey: evicted)?.cancel()
        }
    }

    func forgetAutocomplete(nonce: String) {
        autocompleteOptionTypes[nonce] = nil
        autocompleteNonceOrder.removeAll { $0 == nonce }
        autocompleteTimeoutTasks.removeValue(forKey: nonce)?.cancel()
    }

    func expireAutocomplete(nonce: String) {
        guard autocompleteTimeoutTasks.removeValue(forKey: nonce) != nil else { return }
        // Keep the option type: a late response for this nonce still publishes.
        continuation?.yield(
            .interaction(
                .failed(
                    nonce: nonce,
                    failure: InteractionFailure(
                        reasonCode: InteractionFailure.applicationDidNotRespond
                    )
                )
            )
        )
    }

    func interactionTransportError(_ data: Data, _ response: HTTPURLResponse) -> any Error {
        response.statusCode == 401
            ? apiDiagnostics.coalescing(ChatProviderError.unauthenticated, with: response)
            : unexplainedFailure(data, response)
    }

    /// Uploads interaction files through the shared privacy and reservation
    /// path and returns the user-client descriptor table: string index IDs plus
    /// the original content type.
    func uploadInteractionAttachments(
        _ urls: [URL], channelID: ChannelID,
        progress: @escaping @Sendable (MessageSendProgress) -> Void
    ) async throws -> [JSONValue] {
        let descriptors = try await uploadAttachments(urls, channelID: channelID, progress: progress)
        return zip(urls, descriptors).map { url, descriptor in
            guard case var .object(fields) = descriptor else { return descriptor }
            fields["original_content_type"] = .string(
                UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                    ?? "application/octet-stream"
            )
            return .object(fields)
        }
    }
}

/// Projects a submitted form onto the user-client request shape.
enum ModalSubmissionPayloadBuilder {
    struct Plan {
        var components: [JSONValue]
        /// Files in attachment-table order. Each upload control references a
        /// contiguous run of numeric indices into this one table.
        var fileURLs: [URL]
    }

    static func plan(_ submission: ModalSubmission) -> Plan {
        var fileURLs: [URL] = []
        let components = submission.modal.nodes.map {
            project($0, values: submission.values, fileURLs: &fileURLs)
        }
        return Plan(components: components, fileURLs: fileURLs)
    }

    private static func project(
        _ node: ModalNode,
        values: [String: ModalFieldValue],
        fileURLs: inout [URL]
    ) -> JSONValue {
        switch node {
        case let .actionRow(_, children):
            return .object([
                "type": .number(1),
                "components": .array(children.map { project($0, values: values, fileURLs: &fileURLs) }),
            ])
        case let .label(_, _, _, child):
            return .object([
                "type": .number(18),
                "component": project(child, values: values, fileURLs: &fileURLs),
            ])
        case .textDisplay:
            return .object(["type": .number(10)])
        case let .unsupported(_, type):
            return .object(["type": .number(Double(type))])
        case let .control(control):
            return project(control, value: values[control.customID], fileURLs: &fileURLs)
        }
    }

    private static func project(
        _ control: ModalControl,
        value: ModalFieldValue?,
        fileURLs: inout [URL]
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "type": .number(Double(control.componentType)),
            "custom_id": .string(control.customID),
        ]
        switch (control.kind, value) {
        case let (.textInput, .text(text)?):
            object["value"] = text.map(JSONValue.string) ?? .null
        case let (.radioGroup, .radio(choice)?):
            object["value"] = choice.map(JSONValue.string) ?? .null
        case let (.checkbox, .checkbox(isChecked)?):
            object["value"] = .bool(isChecked)
        case let (.checkbox(isInitiallyChecked), _):
            object["value"] = .bool(isInitiallyChecked)
        case let (.select, .values(selected)?), let (.checkboxGroup, .values(selected)?):
            object["values"] = selected.map { .array($0.map(JSONValue.string)) } ?? .null
        case let (.fileUpload, .files(urls)?):
            if let urls {
                let start = fileURLs.count
                fileURLs.append(contentsOf: urls)
                object["values"] = .array((start ..< fileURLs.count).map { .number(Double($0)) })
            } else {
                object["values"] = .null
            }
        case (.textInput, _), (.radioGroup, _):
            object["value"] = .null
        case (.select, _), (.checkboxGroup, _), (.fileUpload, _):
            object["values"] = .null
        }
        return .object(object)
    }

    /// Maps Discord's form-body errors (`errors.data.components.<index>`) back
    /// to the control at that top-level position.
    static func rejection(from data: Data, modal: InteractionModal) -> ModalSubmissionRejection? {
        guard let body = try? JSONDecoder().decode(JSONValue.self, from: data),
              case let .object(root) = body
        else { return nil }
        var fieldMessages: [String: String] = [:]
        if case let .object(errors)? = root["errors"],
           case let .object(dataErrors)? = errors["data"],
           case let .object(components)? = dataErrors["components"]
        {
            for (key, value) in components {
                guard let index = Int(key), modal.nodes.indices.contains(index),
                      let control = modal.nodes[index].controls.first,
                      let message = firstMessage(in: value)
                else { continue }
                fieldMessages[control.customID] = message
            }
        }
        let message: String = if case let .string(message)? = root["message"],
                                 fieldMessages.isEmpty
        {
            message
        } else {
            "Check the highlighted fields and try again."
        }
        return ModalSubmissionRejection(message: message, fieldMessages: fieldMessages)
    }

    private static func firstMessage(in value: JSONValue) -> String? {
        switch value {
        case let .object(object):
            if case let .string(message)? = object["message"] { return message }
            for key in object.keys.sorted() {
                if let message = object[key].flatMap(firstMessage(in:)) { return message }
            }
            return nil
        case let .array(values):
            return values.lazy.compactMap(firstMessage(in:)).first
        default:
            return nil
        }
    }
}
