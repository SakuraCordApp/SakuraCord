import Foundation
import SakuraCordModels

public extension MockChatProvider {
    func applicationCommandCatalog(for target: ApplicationCommandIndexTarget) async throws
        -> ApplicationCommandCatalog
    {
        MockApplicationCommands.catalog(
            target: target,
            guildID: {
                if case .guild(let id) = target { return id }
                return nil
            }(),
            currentUser: currentUser
        )
    }

    /// Every offline command response reads as its invoker inspecting themselves.
    func messageInteractionData(channelID: ChannelID, messageID: MessageID) async throws -> MessageInteractionData {
        try await Task.sleep(for: .milliseconds(250))
        guard let metadata = messagesByChannel[channelID]?.first(where: { $0.id == messageID })?.interactionMetadata,
              let name = metadata.displayName
        else { throw ChatProviderError.invalidRequest("Command details are unavailable.") }
        return MessageInteractionData(commandName: name, options: [
            .init(name: "user", type: .user, value: metadata.user?.id.description),
            .init(name: "detail", type: .string, value: "full"),
        ])
    }

    func requestApplicationCommandAutocomplete(
        _ request: ApplicationCommandAutocompleteRequest
    ) async throws {
        _ = try ApplicationCommandPayloadBuilder.autocomplete(request)
        try await Task.sleep(for: .milliseconds(90))
        continuation?.yield(
            .applicationCommandAutocomplete(
                ApplicationCommandAutocompleteResult(
                    nonce: request.nonce,
                    choices: MockApplicationCommands.autocomplete(query: request.query)
                )
            )
        )
    }

    func executeApplicationCommand(
        _ invocation: ApplicationCommandInvocation,
        progress: @escaping @Sendable (ApplicationCommandProgress) -> Void
    ) async throws {
        let payload = try ApplicationCommandPayloadBuilder.execution(invocation)
        progress(.preparing)
        let interactionID = String(nextMessageID + 1)
        if !payload.attachmentURLs.isEmpty {
            progress(.reserving(files: payload.attachmentURLs.count))
            for url in payload.attachmentURLs {
                let size =
                    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size])
                            as? NSNumber)?
                        .int64Value ?? 0
                progress(.uploading(fileName: url.lastPathComponent, completed: size, total: size))
            }
        }
        progress(.submitting(nonce: invocation.nonce))
        try await Task.sleep(for: .milliseconds(120))
        nextMessageID += 1
        continuation?.yield(
            .interaction(
                .created(nonce: invocation.nonce, interactionID: String(nextMessageID))
            )
        )
        progress(.awaitingResponse(nonce: invocation.nonce))
        if invocation.command.name == "form" {
            let layout = invocation.values.first.flatMap { value -> String? in
                if case let .string(layout) = value.argument { return layout }
                return nil
            } ?? "modern"
            continuation?.yield(
                .interaction(
                    .presentModal(
                        Self.offlineForm(
                            layout: layout,
                            interactionID: interactionID,
                            nonce: invocation.nonce,
                            application: invocation.command.application,
                            channelID: invocation.channelID,
                            guildID: invocation.guildID
                        )
                    )
                )
            )
            continuation?.yield(
                .interaction(.succeeded(nonce: invocation.nonce, interactionID: interactionID))
            )
            return
        }
        let responseMode =
            invocation.command.name == "response"
                ? invocation.command.subcommandPath.last?.name
                : nil
        if responseMode == "failure" {
            continuation?.yield(
                .interaction(
                    .failed(
                        nonce: invocation.nonce,
                        failure: InteractionFailure(
                            reasonCode: InteractionFailure.applicationDidNotRespond
                        )
                    )
                )
            )
            return
        }
        let application = invocation.command.application
        let author =
            application.bot
                ?? User(
                    id: UserID(rawValue: 900_000_000_000_000_101), username: "verified",
                    displayName: application.name, isBot: true
                )
        let message = commandResponseMessage(
            for: invocation,
            responseMode: responseMode,
            application: application,
            author: author
        )
        messagesByChannel[invocation.channelID, default: []].append(message)
        continuation?.yield(.messageCreated(message))
        continuation?.yield(
            .interaction(.succeeded(nonce: invocation.nonce, interactionID: interactionID))
        )
        try await completeCommandResponse(
            message,
            invocation: invocation,
            responseMode: responseMode,
            application: application,
            author: author
        )
    }

    private func commandResponseMessage(
        for invocation: ApplicationCommandInvocation,
        responseMode: String?,
        application: ApplicationCommandApplication,
        author: User
    ) -> Message {
        Message(
            id: MessageID(rawValue: nextMessageID),
            channelID: invocation.channelID,
            author: author,
            content: responseMode == "deferred"
                ? "The offline app is working…"
                : invocation.targetID.map {
                    "Offline **\(invocation.command.displayName)** inspected `\($0)`."
                } ?? "Offline command **/\(invocation.command.displayName)** completed successfully.",
            nonce: invocation.nonce,
            type: invocation.command.type == .chatInput ? .chatInputCommand : .contextMenuCommand,
            flags: responseMode == "ephemeral"
                ? .ephemeral
                : (responseMode == "deferred" ? .loading : []),
            applicationID: ApplicationID(MockApplicationCommands.applicationID),
            application: application,
            interactionMetadata: MessageInteractionMetadata(
                id: String(nextMessageID), type: 2,
                name: invocation.command.displayName,
                user: currentUser,
                applicationID: invocation.command.applicationID
            ),
            guildID: invocation.guildID,
            components: [
                .container(
                    id: "offline-command-container", accentColor: 0x57F287, spoiler: false,
                    children: [
                        .textDisplay(
                            id: "offline-command-text",
                            content:
                            "### Verified\nThis response is a deterministic Components V2 fixture."
                        ),
                        .separator(id: "offline-command-separator", divider: true, spacing: 1),
                        .textDisplay(
                            id: "offline-command-state",
                            content: "No Discord request was made."
                        ),
                    ]
                )
            ],
            mentionedUsers: [currentUser]
        )
    }

    private func completeCommandResponse(
        _ initialMessage: Message,
        invocation: ApplicationCommandInvocation,
        responseMode: String?,
        application: ApplicationCommandApplication,
        author: User
    ) async throws {
        var message = initialMessage
        if responseMode == "deferred" {
            try await Task.sleep(for: .milliseconds(120))
            message.content = "The deferred offline response completed successfully."
            message.flags.remove(.loading)
            message.editedTimestamp = .now
            if let index = messagesByChannel[invocation.channelID]?.firstIndex(where: {
                $0.id == message.id
            }) {
                messagesByChannel[invocation.channelID]?[index] = message
            }
            continuation?.yield(.messageUpdated(message))
        } else if responseMode == "followup" {
            nextMessageID += 1
            let followup = Message(
                id: MessageID(rawValue: nextMessageID),
                channelID: invocation.channelID,
                author: author,
                content: "This is the synthetic follow-up response.",
                applicationID: ApplicationID(MockApplicationCommands.applicationID),
                application: application,
                guildID: invocation.guildID
            )
            messagesByChannel[invocation.channelID, default: []].append(followup)
            continuation?.yield(.messageCreated(followup))
        }
    }

    func submitComponentInteraction(_ submission: ComponentInteractionSubmission)
        async throws
    {
        nextMessageID += 1
        let interactionID = String(nextMessageID)
        continuation?.yield(
            .interaction(.created(nonce: submission.nonce, interactionID: interactionID))
        )
        try await Task.sleep(for: .milliseconds(150))
        if submission.customID == "offline-modal" {
            continuation?.yield(
                .interaction(
                    .presentModal(
                        Self.offlineForm(
                            layout: "modern",
                            interactionID: interactionID,
                            nonce: submission.nonce,
                            application: ApplicationCommandApplication(
                                id: submission.applicationID.description, name: "Verified"
                            ),
                            channelID: submission.channelID,
                            guildID: submission.guildID
                        )
                    )
                )
            )
        }
        continuation?.yield(
            .interaction(.succeeded(nonce: submission.nonce, interactionID: interactionID))
        )
    }

    func submitModal(_ submission: ModalSubmission) async throws {
        let plan = ModalSubmissionPayloadBuilder.plan(submission)
        try await Task.sleep(for: .milliseconds(150))
        nextMessageID += 1
        let interactionID = String(nextMessageID)
        continuation?.yield(
            .interaction(.created(nonce: submission.nonce, interactionID: interactionID))
        )
        let summary = submission.modal.controls.map { control -> String in
            let value: String = switch submission.values[control.customID] {
            case let .text(text)?: text.map { "“\($0)”" } ?? "untouched"
            case let .radio(choice)?: choice ?? "untouched"
            case let .values(values)?: values.map { $0.joined(separator: ", ") } ?? "untouched"
            case let .checkbox(isChecked)?: isChecked ? "checked" : "unchecked"
            case let .files(urls)?: urls.map { $0.map(\.lastPathComponent).joined(separator: ", ") } ?? "untouched"
            case nil: "untouched"
            }
            return "- `\(control.customID)`: \(value)"
        }.joined(separator: "\n")
        let application = submission.modal.application
        let message = Message(
            id: MessageID(rawValue: nextMessageID),
            channelID: submission.modal.channelID,
            author: application.bot ?? User(
                id: UserID(rawValue: 900_000_000_000_000_101), username: "verified",
                displayName: application.name, isBot: true
            ),
            content: "**\(submission.modal.title)** submitted with \(plan.fileURLs.count) file(s):\n\(summary)",
            nonce: submission.nonce,
            type: .reply,
            flags: .ephemeral,
            applicationID: ApplicationID(application.id),
            application: application,
            interactionMetadata: MessageInteractionMetadata(
                id: interactionID, type: 5, user: currentUser, applicationID: application.id
            ),
            guildID: submission.modal.guildID
        )
        messagesByChannel[submission.modal.channelID, default: []].append(message)
        continuation?.yield(.messageCreated(message))
        continuation?.yield(
            .interaction(.succeeded(nonce: submission.nonce, interactionID: interactionID))
        )
    }

    static func offlineForm(
        layout: String,
        interactionID: String,
        nonce: String,
        application: ApplicationCommandApplication,
        channelID: ChannelID,
        guildID: GuildID?
    ) -> InteractionModal {
        let choices = [
            ComponentSelectOption(label: "Alpha", value: "alpha", description: "First choice"),
            ComponentSelectOption(label: "Sakura 🌸", value: "sakura", isDefault: true),
            ComponentSelectOption(label: "Gamma", value: "gamma"),
        ]
        func control(
            _ id: String, _ customID: String, _ kind: ModalControl.Kind, required: Bool = false,
            label: String? = nil
        ) -> ModalNode {
            .control(ModalControl(
                id: id, customID: customID, kind: kind, isRequired: required, label: label
            ))
        }
        let nodes: [ModalNode]
        if layout == "legacy" {
            nodes = [
                .actionRow(id: "1", children: [control(
                    "2", "title",
                    .textInput(style: .short, placeholder: "A short title", minLength: 0, maxLength: 256, initialValue: nil),
                    required: true, label: "Title"
                )]),
                .actionRow(id: "3", children: [control(
                    "4", "description",
                    .textInput(style: .paragraph, placeholder: nil, minLength: 0, maxLength: 4000, initialValue: nil),
                    label: "Description"
                )]),
            ]
        } else {
            nodes = [
                .textDisplay(id: "1", content: "Synthetic inputs only. **Nothing** leaves this Mac."),
                .label(id: "2", label: "Short text", description: "Between 3 and 12 characters", child: control(
                    "3", "short",
                    .textInput(style: .short, placeholder: "3–12 characters", minLength: 3, maxLength: 12, initialValue: nil),
                    required: true
                )),
                .label(id: "4", label: "Paragraph", description: nil, child: control(
                    "5", "paragraph",
                    .textInput(style: .paragraph, placeholder: "Optional multiline text", minLength: 0, maxLength: 100, initialValue: nil)
                )),
                .label(id: "6", label: "Prefilled", description: nil, child: control(
                    "7", "prefilled",
                    .textInput(style: .short, placeholder: nil, minLength: 0, maxLength: 4000, initialValue: "seed 🌸")
                )),
                .label(id: "8", label: "String choices", description: nil, child: control(
                    "9", "strings",
                    .select(kind: .string, placeholder: "Choose values", options: choices, minValues: 1, maxValues: 2, channelTypes: [], defaultValues: []),
                    required: true
                )),
                .label(id: "10", label: "Users", description: nil, child: control(
                    "11", "users",
                    .select(kind: .user, placeholder: "Choose members", options: [], minValues: 0, maxValues: 2, channelTypes: [], defaultValues: [])
                )),
                .label(id: "12", label: "Text channel", description: nil, child: control(
                    "13", "channels",
                    .select(
                        kind: .channel, placeholder: "Choose a channel", options: [], minValues: 1, maxValues: 1,
                        channelTypes: [0], defaultValues: [ComponentDefaultValue(id: channelID.description, kind: .channel)]
                    ),
                    required: true
                )),
                .label(id: "14", label: "Radio", description: nil, child: control(
                    "15", "radio", .radioGroup(options: choices), required: true
                )),
                .label(id: "16", label: "Pick up to two", description: nil, child: control(
                    "17", "checks", .checkboxGroup(options: choices.map { var option = $0; option.isDefault = false; return option }, minValues: 0, maxValues: 2)
                )),
                .label(id: "18", label: "Single checkbox", description: nil, child: control(
                    "19", "check", .checkbox(isInitiallyChecked: false)
                )),
                .label(id: "20", label: "Files", description: "Up to two text files", child: control(
                    "21", "files", .fileUpload(minValues: 0, maxValues: 2, fileTypes: [".txt", ".json"])
                )),
            ]
        }
        return InteractionModal(
            interactionID: interactionID,
            openingNonce: nonce,
            application: application,
            channelID: channelID,
            guildID: guildID,
            customID: "offline-form:\(layout)",
            title: layout == "legacy" ? "Create Embed Message" : "Offline form",
            nodes: nodes
        )
    }

    func componentChoices(
        kind: ComponentSelectKind,
        query: String,
        guildID: GuildID?,
        channelID _: ChannelID
    ) async throws -> [ComponentSelectOption] {
        let members = try await members(in: guildID)
        let roles = Dictionary(
            members.flatMap(\.roles).map { ($0.id, $0) },
            uniquingKeysWith: { existing, _ in existing }
        ).values
        let choices: [ComponentSelectOption]
        switch kind {
        case .string:
            choices = []
        case .user:
            choices = members.map(Self.componentChoice)
        case .role:
            choices = roles.map(Self.componentChoice)
        case .mentionable:
            choices =
                members.map(Self.componentChoice)
                + roles.map(Self.componentChoice)
        case .channel:
            choices = try await channels(in: guildID).map {
                ComponentSelectOption(
                    label: "#\($0.name)",
                    value: String($0.id.rawValue),
                    imageURL: $0.iconURL,
                    imageShape: .roundedRectangle
                )
            }
        }
        let normalizedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return choices
            .filter {
                normalizedQuery.isEmpty
                    || $0.label.localizedCaseInsensitiveContains(
                        normalizedQuery
                    )
                    || $0.description?.localizedCaseInsensitiveContains(
                        normalizedQuery
                    ) == true
            }
            .sorted {
                let comparison = $0.label.localizedCaseInsensitiveCompare(
                    $1.label
                )
                return comparison == .orderedSame
                    ? $0.value < $1.value
                    : comparison == .orderedAscending
            }
            .prefix(25)
            .map(\.self)
    }

    private static func componentChoice(
        for member: Member
    ) -> ComponentSelectOption {
        ComponentSelectOption(
            label: member.user.displayName,
            value: String(member.id.rawValue),
            description: "@\(member.user.username)",
            imageURL: member.user.avatarURL
        )
    }

    private static func componentChoice(
        for role: GuildRole
    ) -> ComponentSelectOption {
        ComponentSelectOption(
            label: "@\(role.name)",
            value: String(role.id.rawValue),
            imageURL: role.iconURL,
            imageShape: .roundedRectangle
        )
    }
}
