import AppKit
import CommonCrypto
import DiscordProtocol
import Foundation
import Security

nonisolated struct DiscordImportAccount: Identifiable, Sendable {
    let id: String
    let username: String
    let avatarURL: URL?
    fileprivate let encryptedSession: String
}

enum DiscordAccountImporter {
    private static let bookmarkKey = "dev.sakuracord.discord-import-directory"

    static func accounts(excluding savedAccountIDs: Set<String>) async throws -> [DiscordImportAccount] {
        let home = try userHomeDirectory()
        let directories = ["discord", "Discord"].map {
            home.appending(path: "Library/Application Support/\($0)/Local Storage/leveldb").resolvingSymlinksInPath()
        }
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var stale = false
            if let directory = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                        relativeTo: nil, bookmarkDataIsStale: &stale),
               directories.contains(where: { $0.standardizedFileURL.path == directory.standardizedFileURL.path }),
               directory.startAccessingSecurityScopedResource() {
                defer { directory.stopAccessingSecurityScopedResource() }
                do {
                    if stale { try saveAccess(to: directory) }
                    return try await readAccounts(at: directory, excluding: savedAccountIDs)
                } catch let error as CocoaError where error.code == .fileReadNoPermission {
                    UserDefaults.standard.removeObject(forKey: bookmarkKey)
                }
            }
        }
        let directory = try locateDatabase(in: directories)
        do {
            return try await readAccounts(at: directory, excluding: savedAccountIDs)
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            // A sandbox exception does not grant TCC access to another app's
            // data. Ask macOS for scoped consent at the already located folder.
            let authorizedDirectory = try await authorizeAccess(to: directory)
            let scoped = authorizedDirectory.startAccessingSecurityScopedResource()
            defer { if scoped { authorizedDirectory.stopAccessingSecurityScopedResource() } }
            let accounts = try await readAccounts(at: authorizedDirectory, excluding: savedAccountIDs)
            try saveAccess(to: authorizedDirectory)
            return accounts
        }
    }

    private static func saveAccess(to directory: URL) throws {
        let bookmark = try directory.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
    }

    private static func authorizeAccess(to directory: URL) async throws -> URL {
        try Task.checkCancellation()
        let panel = NSOpenPanel()
        panel.title = "Allow Discord account import"
        panel.message = "Allow SakuraCord to read saved accounts from this Discord folder. This access will be remembered."
        panel.prompt = "Allow Access"
        panel.directoryURL = directory
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        let response = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let completion: (NSApplication.ModalResponse) -> Void = { continuation.resume(returning: $0) }
                if let window = NSApp.keyWindow {
                    panel.beginSheetModal(for: window, completionHandler: completion)
                } else {
                    panel.begin(completionHandler: completion)
                }
            }
        } onCancel: {
            Task { @MainActor in panel.cancel(nil) }
        }
        try Task.checkCancellation()
        guard response == .OK, let selected = panel.url else { throw ImportError.accessCancelled }
        guard selected.resolvingSymlinksInPath().standardizedFileURL.path == directory.standardizedFileURL.path else { throw ImportError.wrongDirectory }
        return selected
    }

    @concurrent private static func readAccounts(
        at directory: URL, excluding savedAccountIDs: Set<String>
    ) async throws -> [DiscordImportAccount] {
        let keys = Set(["tokens", "MultiAccountStore"].map(storageKey))
        let values = try DiscordLocalStorageReader.read(directory: directory, keys: keys)
        try Task.checkCancellation()
        return try decodeAccounts(values: values, excluding: savedAccountIDs)
    }

    nonisolated private static func locateDatabase(in directories: [URL]) throws -> URL {
        for directory in directories {
            do {
                _ = try FileManager.default.attributesOfItem(atPath: directory.appending(path: "CURRENT").path)
                return directory
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                continue
            } catch {
                throw ImportError.storageUnreadable
            }
        }
        throw ImportError.storageNotFound
    }

    nonisolated private static func userHomeDirectory() throws -> URL {
        // Foundation's home-directory APIs resolve to our sandbox container.
        // The POSIX account record locates the external, entitlement-scoped data.
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let capacity = max(16_384, Int(sysconf(_SC_GETPW_R_SIZE_MAX)))
        var buffer = [CChar](repeating: 0, count: capacity)
        return try buffer.withUnsafeMutableBufferPointer { bytes in
            guard getpwuid_r(getuid(), &record, bytes.baseAddress, bytes.count, &result) == 0,
                  result != nil, let path = record.pw_dir else { throw ImportError.storageNotFound }
            return URL(fileURLWithFileSystemRepresentation: path, isDirectory: true, relativeTo: nil)
        }
    }

    nonisolated static func storageKey(_ name: String) -> Data {
        Data(("_https://discord.com\0\u{1}" + name).utf8)
    }

    nonisolated static func decodeAccounts(
        values: [Data: Data], excluding savedAccountIDs: Set<String> = []
    ) throws -> [DiscordImportAccount] {
        guard let tokensData = values[storageKey("tokens")],
              let tokens = try decodeValue(tokensData) as? [String: String]
        else { throw ImportError.noAccounts }
        var names: [String: String] = [:]
        var avatars: [String: URL] = [:]
        if let metadata = values[storageKey("MultiAccountStore")],
           let store = try decodeValue(metadata) as? [String: Any],
           let state = store["_state"] as? [String: Any],
           let users = state["users"] as? [[String: Any]] {
            for user in users {
                if let id = user["id"] as? String, let username = user["username"] as? String {
                    names[id] = username
                    avatars[id] = avatarURL(user: user, id: id)
                }
            }
        }
        let accounts = tokens.compactMap { id, value -> DiscordImportAccount? in
            guard !id.isEmpty, id.utf8.allSatisfy({ (48 ... 57).contains($0) }),
                  value.hasPrefix("dQw4w9WgXcQ:"), value.count <= 8192 else { return nil }
            return DiscordImportAccount(
                id: id, username: names[id] ?? "Discord account \(id)",
                avatarURL: avatars[id], encryptedSession: value
            )
        }
        guard !accounts.isEmpty else { throw ImportError.noAccounts }
        return accounts.filter { !savedAccountIDs.contains($0.id) }
            .sorted { $0.username.localizedStandardCompare($1.username) == .orderedAscending }
    }

    nonisolated private static func avatarURL(user: [String: Any], id: String) -> URL? {
        if !id.isEmpty, id.utf8.allSatisfy({ (48 ... 57).contains($0) }),
           let hash = user["avatar"] as? String {
            let hex = hash.hasPrefix("a_") ? String(hash.dropFirst(2)) : hash
            if hex.count == 32, hex.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }) {
                return URL(string: "https://cdn.discordapp.com/avatars/\(id)/\(hash).webp?size=128&animated=false")
            }
        }
        return DiscordProfileImageAssets.defaultAvatarURL(userID: id, discriminator: user["discriminator"] as? String)
    }

    nonisolated private static func decodeValue(_ data: Data) throws -> Any {
        guard let marker = data.first, marker <= 1,
              let value = String(data: data.dropFirst(), encoding: marker == 1 ? .isoLatin1 : .utf16LittleEndian)
        else { throw ImportError.unsupported }
        return try JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)
    }

    @concurrent static func credential(for account: DiscordImportAccount) async throws -> PendingDiscordCredential {
        try Task.checkCancellation()
        var password = try keychainPassword()
        defer { password.resetBytes(in: password.indices) }
        var token = try decrypt(account.encryptedSession, password: password)
        defer { token.resetBytes(in: token.indices) }
        try Task.checkCancellation()
        return try PendingDiscordCredential(token, expectedAccountID: account.id)
    }

    nonisolated private static func keychainPassword() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "discord Safe Storage",
            kSecAttrAccount as String: "discord Key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        // One read can produce two system prompts: the item's decrypt ACL,
        // then its signing-partition ACL. macOS's first "Always Allow" action
        // records both grants; "Allow" authorizes each only for this access.
        // Do not retry the read or modify Discord's ACLs to suppress a prompt.
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecUserCanceled { throw CancellationError() }
            throw ImportError.keychain(status)
        }
        return data
    }

    // Electron 42 / Chromium 148 OSCrypt's macOS v10 format. These legacy
    // parameters belong to Discord's source format, not SakuraCord persistence.
    nonisolated static func decrypt(_ encrypted: String, password: Data) throws -> Data {
        guard encrypted.hasPrefix("dQw4w9WgXcQ:"),
              let data = Data(base64Encoded: String(encrypted.dropFirst(12))),
              data.starts(with: Data("v10".utf8)), data.count > 3,
              (data.count - 3).isMultiple(of: kCCBlockSizeAES128)
        else { throw ImportError.unsupported }
        var key = Data(count: kCCKeySizeAES128)
        defer { key.resetBytes(in: key.indices) }
        let salt = Data("saltysalt".utf8)
        let derivation = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        password.count, saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                        keyBytes.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128
                    )
                }
            }
        }
        guard derivation == kCCSuccess else { throw ImportError.unsupported }
        let payload = Data(data.dropFirst(3))
        let iv = Data(repeating: 32, count: kCCBlockSizeAES128)
        var output = Data(count: payload.count + kCCBlockSizeAES128)
        let capacity = output.count
        var count = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    payload.withUnsafeBytes { payloadBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, kCCKeySizeAES128, ivBytes.baseAddress,
                                payloadBytes.baseAddress, payload.count, outputBytes.baseAddress, capacity, &count)
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            output.resetBytes(in: output.indices)
            throw ImportError.unsupported
        }
        output.count = count
        guard output.count > 20, output.count <= 4096,
              output.allSatisfy({ (33 ... 126).contains($0) }) else {
            output.resetBytes(in: output.indices)
            throw ImportError.unsupported
        }
        return output
    }

    nonisolated enum ImportError: LocalizedError {
        case noAccounts
        case storageNotFound
        case accessCancelled
        case wrongDirectory
        case storageUnreadable
        case unsupported
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noAccounts:
                "No saved Discord accounts were found on this Mac. Open the Discord desktop app and sign in, then try again."
            case .storageNotFound:
                "Discord's account data could not be located. Open the Discord desktop app, then try again."
            case .accessCancelled:
                "Access wasn't allowed. Try again to allow access to your saved Discord accounts."
            case .wrongDirectory:
                "Please allow access to the Discord folder opened by SakuraCord."
            case .storageUnreadable:
                "SakuraCord couldn't read Discord's saved accounts. Check macOS access permissions, then try again."
            case .unsupported:
                "This Discord session could not be imported. Sign in to Discord again, then retry."
            case let .keychain(status):
                "macOS could not unlock Discord's saved session (Keychain error \(status)). Allow SakuraCord access when macOS asks."
            }
        }
    }
}
