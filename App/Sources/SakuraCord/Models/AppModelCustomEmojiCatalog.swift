import Foundation
import OSLog
import SakuraCordModels

extension AppModel {
    func requestOrderedCustomEmojiUpdate() {
        orderedCustomEmojiUpdateGeneration &+= 1
        let generation = orderedCustomEmojiUpdateGeneration
        orderedCustomEmojiUpdateTask?.cancel()
        if emojisByGuild.isEmpty {
            orderedCustomEmojiUpdateTask = nil
            updateOrderedCustomEmojis()
            return
        }
        orderedCustomEmojiUpdateTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.orderedCustomEmojiUpdateGeneration == generation
            else { return }
            if self.launchMode == .normal, AppScrollActivity.isActive {
                self.orderedCustomEmojiUpdateTask = nil
                self.requestOrderedCustomEmojiUpdate()
                return
            }
            let emojisByGuild = self.emojisByGuild
            let guildOrder = self.serverRailItems.flatMap { item -> [GuildID] in
                switch item {
                case .guild(let id): [id]
                case .folder(let folder): folder.guildIDs
                }
            }
            let previousOrderedEmojis = self.orderedCustomEmojis
            let previousImageURLsByID = self.customEmojiURLsByID
            let observesAppScrollWorkGate = self.launchMode == .normal
            let worker = Task.detached(priority: .utility) {
                let signposter = OSSignposter(
                    subsystem: "dev.sakuracord.SakuraCord",
                    category: "PointsOfInterest"
                )
                let interval = signposter.beginInterval(
                    "CustomEmojiCatalogPreparation"
                )
                defer {
                    signposter.endInterval(
                        "CustomEmojiCatalogPreparation",
                        interval
                    )
                }
                return DiscordCustomEmojiCatalog.prepare(
                    emojisByGuild: emojisByGuild,
                    guildOrder: guildOrder,
                    previousOrderedEmojis: previousOrderedEmojis,
                    previousImageURLsByID: previousImageURLsByID,
                    cancellationCheck: {
                        Task.isCancelled
                            || (observesAppScrollWorkGate
                                && AppScrollWorkGate.isActive)
                    }
                )
            }
            let prepared = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  self.orderedCustomEmojiUpdateGeneration == generation
            else { return }
            orderedCustomEmojiUpdateTask = nil
            guard let prepared else {
                self.requestOrderedCustomEmojiUpdate()
                return
            }
            AppPerformanceSignposts.measureSync(
                "CustomEmojiCatalogPublication"
            ) {
                if let orderedEmojis = prepared.orderedEmojis {
                    self.orderedCustomEmojis = orderedEmojis
                }
                if let imageURLsByID = prepared.imageURLsByID {
                    self.customEmojiURLsByID = imageURLsByID
                }
            }
        }
    }

    func updateOrderedCustomEmojis() {
        let guildOrder = serverRailItems.flatMap { item -> [GuildID] in
            switch item {
            case .guild(let id): [id]
            case .folder(let folder): folder.guildIDs
            }
        }
        let value = DiscordCustomEmojiCatalog.ordered(
            emojisByGuild: emojisByGuild,
            guildOrder: guildOrder
        )
        if orderedCustomEmojis != value {
            orderedCustomEmojis = value
        }
        let imageURLsByID = DiscordCustomEmojiCatalog.imageURLsByID(from: value)
        if customEmojiURLsByID != imageURLsByID {
            customEmojiURLsByID = imageURLsByID
        }
    }
}
