import Foundation
import os

/// Resolves public Discord application metadata, icon CDN URLs, and application assets for rich presence rendering.
public actor DiscordApplicationMetadataResolver {
    public static let shared = DiscordApplicationMetadataResolver()

    private let logger = Logger(subsystem: "dev.sakuracord", category: "DiscordApplicationMetadataResolver")
    private let session: URLSession

    private var appIconCache: [String: String] = [
        "363445589247131668": "f2b60e350a2097289b3b0b877495e55f", // Roblox
        "1123683254248148992": "cd57894a530060bdddb89b0dbde38e95", // Modrinth
        "383226320970055681": "db3133f34f68553148f3a65c1f4633aa", // Visual Studio Code
    ]

    private var appAssetsCache: [String: [String: String]] = [
        "1123683254248148992": [
            "modrinth_simple": "1137523392250130612",
            "128x128_2x": "1137523957952684050",
        ]
    ]

    private var inFlightIconTasks: [String: Task<URL?, Never>] = [:]
    private var inFlightAssetTasks: [String: Task<[String: String]?, Never>] = [:]

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Resolves the icon CDN URL for an application ID.
    public func resolveIconURL(for applicationID: String) async -> URL? {
        guard !applicationID.isEmpty, applicationID.allSatisfy(\.isNumber) else { return nil }

        if let iconHash = appIconCache[applicationID] {
            return URL(string: "https://cdn.discordapp.com/app-icons/\(applicationID)/\(iconHash).png?size=128")
        }

        if let inFlight = inFlightIconTasks[applicationID] {
            return await inFlight.value
        }

        let task = Task<URL?, Never> { [weak self, session, logger] in
            guard let url = URL(string: "https://discord.com/api/v9/applications/\(applicationID)/rpc") else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let iconHash = json["icon"] as? String, !iconHash.isEmpty else {
                    return nil
                }
                await self?.cacheIcon(for: applicationID, hash: iconHash)
                return URL(string: "https://cdn.discordapp.com/app-icons/\(applicationID)/\(iconHash).png?size=128")
            } catch {
                logger.debug("Failed to resolve application icon for \(applicationID): \(error.localizedDescription)")
                return nil
            }
        }

        inFlightIconTasks[applicationID] = task
        let result = await task.value
        inFlightIconTasks.removeValue(forKey: applicationID)
        return result
    }

    /// Resolves the artwork URL for an application and asset key (either an asset ID, asset name, or nil).
    public func resolveArtworkURL(applicationID: String, assetKey: String?) async -> URL? {
        guard !applicationID.isEmpty, applicationID.allSatisfy(\.isNumber) else { return nil }

        if let assetKey, !assetKey.isEmpty {
            if assetKey.hasPrefix("http://") || assetKey.hasPrefix("https://") {
                return URL(string: assetKey)
            }
            if assetKey.allSatisfy(\.isNumber) {
                return URL(string: "https://cdn.discordapp.com/app-assets/\(applicationID)/\(assetKey).png")
            }

            if let assetID = await resolveAssetID(applicationID: applicationID, assetName: assetKey) {
                return URL(string: "https://cdn.discordapp.com/app-assets/\(applicationID)/\(assetID).png")
            }
            return nil
        }

        return await resolveIconURL(for: applicationID)
    }

    /// Resolves an asset name (e.g. "modrinth_simple") to its Discord asset snowflake ID.
    public func resolveAssetID(applicationID: String, assetName: String) async -> String? {
        guard !applicationID.isEmpty, applicationID.allSatisfy(\.isNumber) else { return nil }

        if let cachedMap = appAssetsCache[applicationID], let assetID = cachedMap[assetName] {
            return assetID
        }

        if let inFlight = inFlightAssetTasks[applicationID] {
            let map = await inFlight.value
            return map?[assetName]
        }

        let task = Task<[String: String]?, Never> { [weak self, session, logger] in
            guard let url = URL(string: "https://discord.com/api/v9/oauth2/applications/\(applicationID)/assets") else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                      let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    return nil
                }
                var map: [String: String] = [:]
                for item in list {
                    if let name = item["name"] as? String, let id = item["id"] as? String {
                        map[name] = id
                    }
                }
                await self?.cacheAssets(for: applicationID, map: map)
                return map
            } catch {
                logger.debug("Failed to resolve assets for application \(applicationID): \(error.localizedDescription)")
                return nil
            }
        }

        inFlightAssetTasks[applicationID] = task
        let map = await task.value
        inFlightAssetTasks.removeValue(forKey: applicationID)
        return map?[assetName]
    }

    private func cacheIcon(for applicationID: String, hash: String) {
        appIconCache[applicationID] = hash
    }

    private func cacheAssets(for applicationID: String, map: [String: String]) {
        appAssetsCache[applicationID] = map
    }
}
