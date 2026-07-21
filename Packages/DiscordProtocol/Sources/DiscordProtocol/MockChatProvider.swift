import Foundation
import SakuraCordModels
import UniformTypeIdentifiers

public actor MockChatProvider: ChatProvider {
    private let currentUser: User
    private var snapshot: BootstrapSnapshot
    private var membersByGuild: [GuildID: [Member]]
    private var emojisByGuild: [GuildID: [DiscordEmoji]]
    private var messagesByChannel: [ChannelID: [Message]]
    private var profilesByUser: [UserID: UserProfile]
    private var continuation: AsyncStream<ClientEvent>.Continuation?
    private var nextMessageID: UInt64
    public private(set) var typingRequests: [ChannelID] = []

    public init(includesLongServerList: Bool = false) {
        let fixture = MockChatFixture.make(includesLongServerList: includesLongServerList)
        currentUser = fixture.currentUser
        nextMessageID = UInt64(ClientNonce.make()) ?? 9000
        snapshot = fixture.snapshot
        membersByGuild = fixture.membersByGuild
        emojisByGuild = fixture.emojisByGuild
        messagesByChannel = fixture.messagesByChannel
        profilesByUser = fixture.profilesByUser
    }

    public func bootstrap() async throws -> BootstrapSnapshot {
        continuation?.yield(.connectionChanged(.connecting))
        try await Task.sleep(for: .milliseconds(180))
        continuation?.yield(.connectionChanged(.ready))
        return snapshot
    }

    public func channels(in guildID: GuildID?) async throws -> [Channel] {
        snapshot.channels.filter { $0.guildID == guildID }
    }

    public func members(in guildID: GuildID?) async throws -> [Member] {
        guard let guildID else { return [Member(user: currentUser, roleName: "You", status: .online)] }
        return membersByGuild[guildID] ?? []
    }

    public func emojis(in guildID: GuildID) async throws -> [DiscordEmoji] {
        emojisByGuild[guildID] ?? []
    }

    public func emojiUserSettings() async throws -> EmojiUserSettings {
        EmojiUserSettings(
            favoriteKeys: [
                "custom:900000000000000201", "white_check_mark", "x", "neutral_face",
                "broken_heart", "hot_face",
                "smiling_face_with_3_hearts", "cry", "fire", "thumbsup", "sob"
            ],
            frequentlyUsedKeys: [
                "custom:900000000000000202", "broken_heart", "white_check_mark", "neutral_face",
                "sob", "pray", "fire",
                "cry", "wilted_flower", "person_shrugging", "white_heart", "thumbsup", "x",
                "unamused", "hot_face", "pleading_face", "smiley_cat", "eyes"
            ],
            usageScores: [:]
        )
    }

    public func profile(for userID: UserID, in guildID: GuildID?) async throws -> UserProfile {
        guard let profile = profilesByUser[userID] else {
            throw ChatProviderError.invalidRequest("That demo profile is unavailable.")
        }
        return profile
    }

    public func currentStatus() async -> PresenceStatus {
        .online
    }

    public func updateStatus(_ status: PresenceStatus) async throws {
        for guildID in Array(membersByGuild.keys) {
            membersByGuild[guildID] = membersByGuild[guildID]?.map { member in
                guard member.user.id == snapshot.currentUser.id else { return member }
                var updatedMember = member
                updatedMember.status = status
                return updatedMember
            }
        }
        snapshot.members =
            membersByGuild[snapshot.guilds.first?.id ?? GuildID(rawValue: 0)] ?? snapshot.members
        if var profile = profilesByUser[currentUser.id] {
            profile.status = status
            profilesByUser[currentUser.id] = profile
        }
        continuation?.yield(.snapshotChanged(snapshot))
    }

    public func messages(in channelID: ChannelID, before: MessageID?, limit: Int) async throws
        -> MessagePage
    {
        guard snapshot.channels.contains(where: { $0.id == channelID })
            || messagesByChannel[channelID] != nil
        else {
            throw ChatProviderError.channelNotFound
        }
        var messages = messagesByChannel[channelID] ?? []
        if let before {
            messages = messages.filter { $0.id < before }
        }
        let page = Array(messages.suffix(max(1, limit)))
        return MessagePage(messages: page, hasMoreBefore: messages.count > page.count)
    }

    public func sendTyping(in channelID: ChannelID) async throws {
        guard let channel = snapshot.channels.first(where: { $0.id == channelID }) else {
            throw ChatProviderError.channelNotFound
        }
        guard channel.kind != .voice, channel.kind != .forum, channel.kind != .unknown else {
            throw ChatProviderError.invalidRequest("Typing is unavailable in this demo channel.")
        }
        typingRequests.append(channelID)
    }

    public func send(_ draft: SendMessageDraft) async throws -> Message {
        guard
            !draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.attachmentURLs.isEmpty || !draft.stickerIDs.isEmpty
        else {
            throw ChatProviderError.invalidRequest("A message needs text or an attachment.")
        }
        nextMessageID += 1
        let attachments = try draft.attachmentURLs.enumerated().map { index, url in
            try Self.stageAttachment(url, messageID: nextMessageID, index: index)
        }
        let replyPreview = draft.replyTo.flatMap { messageID in
            messagesByChannel[draft.channelID]?.first(where: { $0.id == messageID }).map {
                MessageReplyPreview(messageID: $0.id, author: $0.author, content: $0.content)
            }
        }
        let message = Message(
            id: MessageID(rawValue: nextMessageID), channelID: draft.channelID, author: currentUser,
            content: draft.content, replyTo: draft.replyTo, replyPreview: replyPreview,
            attachments: attachments,
            nonce: draft.nonce,
            stickers: draft.stickerIDs.map { MessageSticker(id: $0, name: "Demo sticker", format: .png) }
        )
        messagesByChannel[draft.channelID, default: []].append(message)
        continuation?.yield(.messageCreated(message))
        return message
    }

    public func supports(_ capability: ChatCapability) async -> Bool {
        capability == .gifs || capability == .stickers || capability == .stickerSending
            || capability == .components || capability == .modals || capability == .slashCommands
    }

    public func applicationCommandCatalog(for target: ApplicationCommandIndexTarget) async throws
        -> ApplicationCommandCatalog
    {
        MockApplicationCommands.catalog(
            target: target,
            guildID: {
                if case let .guild(id) = target { return id }
                return nil
            }(),
            currentUser: currentUser
        )
    }

    public func requestApplicationCommandAutocomplete(
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

    public func executeApplicationCommand(
        _ invocation: ApplicationCommandInvocation,
        progress: @escaping @Sendable (ApplicationCommandProgress) -> Void
    ) async throws {
        let payload = try ApplicationCommandPayloadBuilder.execution(invocation)
        progress(.preparing)
        if !payload.attachmentURLs.isEmpty {
            progress(.reserving(files: payload.attachmentURLs.count))
            for url in payload.attachmentURLs {
                let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?
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
        let responseMode = invocation.command.name == "response"
            ? invocation.command.subcommandPath.last?.name
            : nil
        if responseMode == "failure" {
            continuation?.yield(
                .interaction(
                    .failed(
                        nonce: invocation.nonce,
                        message: "Synthetic interaction failure. No retry was attempted."
                    )
                )
            )
            return
        }
        let application = invocation.command.application
        let author = application.bot ?? User(
            id: UserID("900000000000000101")!, username: "verified",
            displayName: application.name, isBot: true
        )
        var message = Message(
            id: MessageID(rawValue: nextMessageID),
            channelID: invocation.channelID,
            author: author,
            content: responseMode == "deferred"
                ? "The offline app is working…"
                : "Offline command **/\(invocation.command.displayName)** completed successfully.",
            nonce: invocation.nonce,
            type: .chatInputCommand,
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
                            content: "### Verified\nThis response is a deterministic Components V2 fixture."
                        ),
                        .separator(id: "offline-command-separator", divider: true, spacing: 1),
                        .textDisplay(
                            id: "offline-command-state",
                            content: "No Discord request was made."
                        )
                    ]
                )
            ],
            mentionedUsers: [currentUser]
        )
        messagesByChannel[invocation.channelID, default: []].append(message)
        continuation?.yield(.messageCreated(message))
        continuation?.yield(.interaction(.succeeded(nonce: invocation.nonce)))
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

    public func submitComponentInteraction(_ submission: ComponentInteractionSubmission) async throws {
        if submission.customID == "offline-modal" {
            let modal = InteractionModal(
                customID: "offline-feedback", title: "Offline feedback",
                controls: [
                    .label(
                        id: "label", label: "Feedback",
                        description: "This synthetic modal never contacts Discord.",
                        child: .textInput(
                            id: "text", customID: "feedback", style: 2, label: nil, value: nil,
                            placeholder: "What should improve?", required: true, minLength: 3, maxLength: 500
                        )
                    ),
                    .checkbox(
                        id: "checkbox", customID: "follow-up", label: "Allow a fictional follow-up",
                        value: false
                    )
                ]
            )
            continuation?.yield(.interaction(.presentModal(nonce: submission.nonce, modal: modal)))
        } else {
            continuation?.yield(.interaction(.succeeded(nonce: submission.nonce)))
        }
    }

    public func submitModal(_ submission: ModalSubmission, nonce: String) async throws {
        continuation?.yield(.interaction(.succeeded(nonce: nonce)))
    }

    public func trendingGIFs() async throws -> [GIFSearchResult] {
        try Self.demoGIFs(query: "Trending")
    }

    public func searchGIFs(query: String) async throws -> [GIFSearchResult] {
        try Self.demoGIFs(query: query.isEmpty ? "GIF" : query)
    }

    public func stickers(in guildID: GuildID) async throws -> [MessageSticker] {
        try [
            MessageSticker(
                id: "demo-wave", name: "Wave", description: "Offline demo sticker", tags: "wave,hello",
                format: .png, guildID: guildID, assetURL: Self.demoGIFs(query: "Sticker").first?.url
            )
        ]
    }

    private static func demoGIFs(query: String) throws -> [GIFSearchResult] {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "SakuraCordDemoMedia", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "demo.gif")
        if !FileManager.default.fileExists(atPath: url.path) {
            let data = Data(
                base64Encoded: "R0lGODlhAQABAPAAAP///wAAACH5BAAAAAAALAAAAAABAAEAAAICRAEAOw=="
            )!
            try data.write(to: url, options: .atomic)
        }
        return [
            GIFSearchResult(
                id: "demo-gif", title: "\(query) demo", url: url, previewURL: url, width: 1, height: 1
            )
        ]
    }

    private static func stageAttachment(_ sourceURL: URL, messageID: UInt64, index: Int) throws
        -> Attachment
    {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SakuraCordDemoAttachments", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileExtension = sourceURL.pathExtension
        let filename =
            sourceURL.lastPathComponent.isEmpty ? "attachment-\(index)" : sourceURL.lastPathComponent
        let destination = directory.appending(
            path: "\(messageID)-\(index)\(fileExtension.isEmpty ? "" : ".\(fileExtension)")"
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        let mediaType = UTType(filenameExtension: fileExtension)?.preferredMIMEType
        return Attachment(
            id: "\(messageID)-\(index)",
            filename: filename,
            url: destination,
            mediaType: mediaType,
            size: values.fileSize ?? 0
        )
    }

    public func edit(messageID: MessageID, channelID: ChannelID, content: String) async throws
        -> Message
    {
        guard let index = messagesByChannel[channelID]?.firstIndex(where: { $0.id == messageID }) else {
            throw ChatProviderError.messageNotFound
        }
        messagesByChannel[channelID]![index].content = content
        messagesByChannel[channelID]![index].editedTimestamp = .now
        let message = messagesByChannel[channelID]![index]
        continuation?.yield(.messageUpdated(message))
        return message
    }

    public func delete(messageID: MessageID, channelID: ChannelID) async throws {
        guard let index = messagesByChannel[channelID]?.firstIndex(where: { $0.id == messageID }) else {
            throw ChatProviderError.messageNotFound
        }
        messagesByChannel[channelID]!.remove(at: index)
        continuation?.yield(.messageDeleted(channelID: channelID, messageID: messageID))
    }

    public func toggleReaction(_ emoji: String, messageID: MessageID, channelID: ChannelID)
        async throws
    {
        guard let index = messagesByChannel[channelID]?.firstIndex(where: { $0.id == messageID }) else {
            throw ChatProviderError.messageNotFound
        }
        var message = messagesByChannel[channelID]![index]
        if let reactionIndex = message.reactions.firstIndex(where: { $0.emoji == emoji }) {
            let active = message.reactions[reactionIndex].didCurrentUserReact
            message.reactions[reactionIndex].didCurrentUserReact.toggle()
            message.reactions[reactionIndex].count += active ? -1 : 1
            if active {
                message.reactions[reactionIndex].reactors.removeAll { $0.id == snapshot.currentUser.id }
            } else if !message.reactions[reactionIndex].reactors.contains(where: {
                $0.id == snapshot.currentUser.id
            }) {
                message.reactions[reactionIndex].reactors.append(
                    ReactionReactor(user: snapshot.currentUser)
                )
            }
            if message.reactions[reactionIndex].count == 0 {
                message.reactions.remove(at: reactionIndex)
            }
        } else {
            message.reactions.append(
                Reaction(
                    emoji: emoji,
                    count: 1,
                    didCurrentUserReact: true,
                    reactors: [ReactionReactor(user: snapshot.currentUser)]
                )
            )
        }
        messagesByChannel[channelID]![index] = message
        continuation?.yield(.messageUpdated(message))
    }

    public func reactionReactors(
        for emoji: String,
        messageID: MessageID,
        channelID: ChannelID,
        reactionCount: Int
    ) async throws -> [ReactionReactor] {
        guard let message = messagesByChannel[channelID]?.first(where: { $0.id == messageID }),
              let reaction = message.reactions.first(where: { $0.id == Reaction(
                  emoji: emoji,
                  count: reactionCount
              ).id })
        else {
            throw ChatProviderError.messageNotFound
        }
        return Array(reaction.reactors.prefix(5))
    }

    public func joinVoice(
        channelID: ChannelID,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool
    ) async throws -> VoiceConnectionInfo {
        guard snapshot.channels.contains(where: { $0.id == channelID && $0.kind == .voice }) else {
            throw ChatProviderError.invalidRequest("That demo voice channel is unavailable.")
        }
        let state = VoiceParticipantState(
            userID: currentUser.id,
            channelID: channelID,
            guildID: guildID,
            sessionID: "demo-session",
            isSelfMuted: selfMute,
            isSelfDeafened: selfDeaf
        )
        continuation?.yield(.voiceStateChanged(state))
        return VoiceConnectionInfo(
            serverID: guildID?.description ?? channelID.description,
            channelID: channelID,
            guildID: guildID,
            userID: currentUser.id,
            sessionID: state.sessionID,
            token: "demo-token",
            endpoint: "mock.sakuracord.invalid"
        )
    }

    public func updateVoiceState(
        channelID: ChannelID?,
        guildID: GuildID?,
        selfMute: Bool,
        selfDeaf: Bool,
        selfVideo: Bool
    ) async throws {
        continuation?.yield(
            .voiceStateChanged(
                VoiceParticipantState(
            userID: currentUser.id,
            channelID: channelID,
            guildID: guildID,
            sessionID: "demo-session",
            isSelfMuted: selfMute,
            isSelfDeafened: selfDeaf,
            isVideoEnabled: selfVideo
                )
            )
        )
    }

    public func eventStream() async -> AsyncStream<ClientEvent> {
        let stream = AsyncStream<ClientEvent>.makeStream(bufferingPolicy: .bufferingNewest(500))
        continuation = stream.continuation
        return stream.stream
    }

    public func disconnect() async {
        continuation?.yield(.connectionChanged(.disconnected))
        continuation?.finish()
        continuation = nil
    }
}
