import Foundation
import OSLog
import SakuraCordModels

struct StickerPickerPresentationState {
    var stickersByGuild: [GuildID: [MessageSticker]] = [:]
    var standardStickerPacks: [StickerPack] = []
    var userSettings = StickerUserSettings()
    var isLoading = false
    var errorMessage: String?
    var sendingStickerID: String?
}

nonisolated enum StickerSendRoute: Equatable {
    case native
    case fakeNitroUpload
}

nonisolated enum StickerSendPolicy {
    static func route(
        for sticker: MessageSticker,
        currentGuildID: GuildID?,
        premiumType: Int
    ) -> StickerSendRoute {
        if sticker.guildID == nil || sticker.guildID == currentGuildID || premiumType > 0 {
            return .native
        }
        return .fakeNitroUpload
    }
}

extension MessageSticker {
    var pickerMediaURL: URL? {
        if format == .lottie {
            return URL(string: "https://discord.com/stickers/\(id).json")
        }
        return URL(
            string: "https://media.discordapp.net/stickers/\(id).webp?size=240&quality=lossless"
        )
    }

    var pickerImageLink: URL? {
        URL(string: "https://media.discordapp.net/stickers/\(id).webp?size=320&quality=lossless")
    }
}

extension AppModel {
    static let stickerPickerLogger = Logger(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "StickerPicker"
    )

    var stickersByGuild: [GuildID: [MessageSticker]] {
        get { stickerPickerState.stickersByGuild }
        set { stickerPickerState.stickersByGuild = newValue }
    }

    var standardStickerPacks: [StickerPack] {
        get { stickerPickerState.standardStickerPacks }
        set { stickerPickerState.standardStickerPacks = newValue }
    }

    var stickerUserSettings: StickerUserSettings {
        get { stickerPickerState.userSettings }
        set { stickerPickerState.userSettings = newValue }
    }

    var isLoadingStickerPicker: Bool {
        get { stickerPickerState.isLoading }
        set { stickerPickerState.isLoading = newValue }
    }

    var stickerPickerErrorMessage: String? {
        get { stickerPickerState.errorMessage }
        set { stickerPickerState.errorMessage = newValue }
    }

    var sendingStickerID: String? {
        get { stickerPickerState.sendingStickerID }
        set { stickerPickerState.sendingStickerID = newValue }
    }

    func consumeStickerEvent(_ event: ClientEvent) {
        switch event {
        case .stickerUserSettingsChanged(let settings):
            stickerUserSettings = settings
        case .stickersChanged(let guildID, let stickers):
            stickersByGuild[guildID] = stickers
        default:
            break
        }
    }

    func loadStickerPicker() async {
        guard !isLoadingStickerPicker else { return }
        let session = accountSession()
        isLoadingStickerPicker = true
        stickerPickerErrorMessage = nil
        defer {
            if isCurrentAccountSession(session) { isLoadingStickerPicker = false }
        }
        do {
            async let settings = session.provider.stickerUserSettings()
            async let packs = session.provider.standardStickerPacks()
            let guilds = snapshot?.guilds ?? []
            var guildStickers: [GuildID: [MessageSticker]] = [:]
            for guild in guilds {
                guard !Task.isCancelled else { return }
                guildStickers[guild.id] = try await session.provider.stickers(in: guild.id)
            }
            let (loadedSettings, loadedPacks) = try await (settings, packs)
            guard isCurrentAccountSession(session) else { return }
            stickerUserSettings = loadedSettings
            standardStickerPacks = loadedPacks
            stickersByGuild.merge(guildStickers) { _, newer in newer }
        } catch {
            guard isCurrentAccountSession(session), !Task.isCancelled else { return }
            stickerPickerErrorMessage = error.localizedDescription
            Self.stickerPickerLogger.error(
                "Catalog load failed: \(String(reflecting: error), privacy: .public)"
            )
        }
    }

    @discardableResult
    func setStickerFavorite(stickerID: String, isFavorite: Bool) async -> Bool {
        let session = accountSession()
        do {
            let settings = try await session.provider.setStickerFavorite(
                stickerID,
                isFavorite: isFavorite
            )
            guard isCurrentAccountSession(session) else { return false }
            stickerUserSettings = settings
            return true
        } catch {
            guard isCurrentAccountSession(session) else { return false }
            stickerPickerErrorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func sendStickerFromPicker(_ sticker: MessageSticker) async -> Bool {
        guard sendingStickerID == nil else { return false }
        sendingStickerID = sticker.id
        defer { sendingStickerID = nil }

        let route = StickerSendPolicy.route(
            for: sticker,
            currentGuildID: selectedGuildID,
            premiumType: snapshot?.currentUser.premiumType ?? 0
        )
        let sent: Bool
        switch route {
        case .native:
            sent = await sendSticker(sticker)
        case .fakeNitroUpload:
            sent = await sendStickerAsUpload(sticker)
        }
        guard sent else { return false }
        await recordStickerUse(sticker.id)
        return true
    }

    private func recordStickerUse(_ stickerID: String) async {
        let session = accountSession()
        guard let settings = try? await session.provider.recordStickerUse(stickerID),
              isCurrentAccountSession(session)
        else { return }
        stickerUserSettings = settings
    }

    private func sendStickerAsUpload(_ sticker: MessageSticker) async -> Bool {
        let session = accountSession()
        guard let channelID = selectedChannelID,
              let remoteURL = sticker.pickerImageLink,
              isCurrentAccountSession(session)
        else { return false }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appending(path: "sakuracord-sticker-\(sticker.id)-\(UUID().uuidString)")
            .appendingPathExtension("webp")
        do {
            let (data, response) = try await URLSession.shared.data(from: remoteURL)
            guard let http = response as? HTTPURLResponse,
                  (200 ..< 300).contains(http.statusCode),
                  !data.isEmpty
            else {
                throw URLError(.badServerResponse)
            }
            try data.write(to: temporaryURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            let draft = SendMessageDraft(
                channelID: channelID,
                content: "",
                attachmentURLs: [temporaryURL]
            )
            let message = try await session.provider.send(draft)
            guard isCurrentAccountSession(session) else { return false }
            let reconciled = reconcileVisibleOrCached(message)
            journalAuthoritativeMessageUpsert(reconciled)
            completeConversationReadingAndAdvance(channelID: channelID)
            return true
        } catch {
            guard isCurrentAccountSession(session) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }
}
