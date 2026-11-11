import Foundation
import SakuraCordModels

public extension DiscordRESTProvider {
    func inboxMentions(_ filter: InboxMentionQuery, before: MessageID?) async throws -> InboxMentionPage {
        let generation = profileEditingGeneration
        var query = [URLQueryItem(name: "limit", value: "25")]
        if let before { query.append(URLQueryItem(name: "before", value: before.description)) }
        if let guildID = filter.guildID { query.append(URLQueryItem(name: "guild_id", value: guildID.description)) }
        query.append(URLQueryItem(name: "roles", value: String(filter.includesRoles)))
        query.append(URLQueryItem(name: "everyone", value: String(filter.includesEveryone)))
        let payload: [InboxMentionDTO] = try await request("/users/@me/mentions", query: query)
        guard generation == profileEditingGeneration else { throw CancellationError() }
        let channelGuildIDs = Dictionary(cachedChannels.values.flatMap { $0 }.compactMap { channel in
            channel.guildID.map { (channel.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        var threads: [ChannelID: MessageThreadSummary] = [:]
        for channelID in Set(payload.compactMap { $0.message?.channelID }.compactMap(ChannelID.init)) where channelGuildIDs[channelID] == nil {
            if let known = cachedJoinedThreads[channelID] {
                threads[channelID] = known
            } else if let post = try? await forumPost(threadID: channelID) {
                threads[channelID] = post.thread
            }
        }
        guard generation == profileEditingGeneration else { throw CancellationError() }
        let messages = payload.compactMap { $0.message }.compactMap { try? $0.domain() }.map { source in
            var message = source
            message.guildID = message.guildID ?? channelGuildIDs[message.channelID] ?? threads[message.channelID]?.guildID
            return message
        }
        for message in messages { cachedMessages[message.id] = message }
        cacheMessageSearchUsers(payload.compactMap(\.message).flatMap(\.searchIndexUsers))
        cacheForwardSearchMessageAliases(messages)
        return InboxMentionPage(
            messages: messages,
            nextBefore: payload.last?.id,
            hasMore: payload.count >= 25, threads: Array(threads.values)
        )
    }

    func dismissInboxMention(_ messageID: MessageID) async throws {
        let generation = profileEditingGeneration
        try await requestEmpty("/users/@me/mentions/\(messageID)", method: "DELETE")
        guard generation == profileEditingGeneration else { throw CancellationError() }
        continuation?.yield(.inboxMentionDismissed(messageID))
    }

    func inboxSettings() async -> InboxSettings {
        DiscordInboxSettingsProto.settings(in: inboxSettingsProto ?? Data())
    }

    func updateInboxTab(_ tab: InboxTab) async throws {
        try await saveInboxSettings { current in
            DiscordInboxSettingsProto.updatingTab(tab, in: current)
        }
    }

    func updateInboxCollapsed(_ collapsed: Bool, channelID: ChannelID, guildID: GuildID?) async throws {
        try await saveInboxSettings { current in
            DiscordInboxSettingsProto.updatingCollapsed(collapsed, channelID: channelID, guildID: guildID, in: current)
        }
    }
}

private struct InboxMentionDTO: Decodable {
    var id: MessageID?
    var message: MessageDTO?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)).flatMap(MessageID.init)
        message = try? MessageDTO(from: decoder)
    }

    enum CodingKeys: String, CodingKey { case id }
}

extension DiscordRESTProvider {
    func applyInboxSettingsProto(_ encoded: String?, isPartial: Bool) {
        guard let encoded, let data = Data(base64Encoded: encoded) else { return }
        inboxSettingsProto = DiscordSettingsProto.mergingRevisionedSettings(
            data, into: inboxSettingsProto ?? Data(), isPartial: isPartial,
            fieldVersions: &inboxSettingsFieldVersions
        )
        continuation?.yield(.inboxSettingsChanged(DiscordInboxSettingsProto.settings(in: inboxSettingsProto ?? Data())))
    }

    private func saveInboxSettings(_ makePatch: (Data) -> Data) async throws {
        guard let current = inboxSettingsProto else {
            throw ChatProviderError.invalidRequest("Wait for your account settings to finish loading.")
        }
        guard inboxSettingsSaveID == nil else {
            throw ChatProviderError.invalidRequest("An Inbox settings update is already in progress.")
        }
        let saveID = UUID()
        let generation = profileEditingGeneration
        inboxSettingsSaveID = saveID
        defer { if inboxSettingsSaveID == saveID { inboxSettingsSaveID = nil } }
        let response: UserSettingsProtoDTO
        do {
            response = try await patchUserSettings(["settings": .string(makePatch(current).base64EncodedString())], retriesRateLimit: false)
        } catch is UserSettingsRejection {
            guard generation == profileEditingGeneration, inboxSettingsSaveID == saveID else { throw CancellationError() }
            let reloaded = await reloadUserSettings()
            guard generation == profileEditingGeneration, inboxSettingsSaveID == saveID else { throw CancellationError() }
            throw ChatProviderError.invalidRequest(reloaded
                ? "Discord rejected this Inbox settings change. Your saved settings are shown again."
                : "Discord rejected this Inbox settings change, and saved settings could not be refreshed.")
        }
        guard generation == profileEditingGeneration, inboxSettingsSaveID == saveID else { throw CancellationError() }
        applyInboxSettingsProto(response.settings, isPartial: true)
    }
}

public extension ChatProvider {
    func inboxMentions(_ query: InboxMentionQuery, before: MessageID?) async throws -> InboxMentionPage {
        throw ChatProviderError.invalidRequest("Inbox mentions are unavailable.")
    }

    func dismissInboxMention(_ messageID: MessageID) async throws {
        throw ChatProviderError.invalidRequest("Inbox mentions are unavailable.")
    }

    func inboxSettings() async -> InboxSettings { InboxSettings() }

    func updateInboxTab(_ tab: InboxTab) async throws {}

    func updateInboxCollapsed(_ collapsed: Bool, channelID: ChannelID, guildID: GuildID?) async throws {}
}
