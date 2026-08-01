import Foundation
import Security

public struct CredentialHandle: Hashable, Sendable {
    public let accountID: String
    public init(accountID: String) {
        self.accountID = accountID
    }
}

public protocol CredentialStore: Sendable {
    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle
    func credential(for handle: CredentialHandle) async throws -> Data
    func remove(_ handle: CredentialHandle) async throws
    func handles() async throws -> [CredentialHandle]
}

public actor KeychainCredentialStore: CredentialStore {
    private let service: String
    public init(service: String? = nil) {
        self.service = service ?? CredentialServiceName.resolve(
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    public func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: accountID]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = credential
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return CredentialHandle(accountID: accountID)
    }

    public func credential(for handle: CredentialHandle) async throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: handle.accountID, kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return data
    }

    public func remove(_ handle: CredentialHandle) async throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: handle.accountID]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    public func handles() async throws -> [CredentialHandle] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        let dictionaries: [[String: Any]] = if let values = items as? [[String: Any]] {
            values
        } else if let value = items as? [String: Any] {
            [value]
        } else {
            []
        }
        return dictionaries.compactMap { value in
            (value[kSecAttrAccount as String] as? String).map(CredentialHandle.init(accountID:))
        }
    }
}

public actor InsecureDebugFileCredentialStore: CredentialStore {
    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? Self.defaultDirectory(fileManager: fileManager)
    }

    public func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        let fileURL = try credentialURL(accountID: accountID)
        try prepareDirectory()
        try credential.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        return CredentialHandle(accountID: accountID)
    }

    public func credential(for handle: CredentialHandle) async throws -> Data {
        try Data(contentsOf: credentialURL(accountID: handle.accountID))
    }

    public func remove(_ handle: CredentialHandle) async throws {
        let fileURL = try credentialURL(accountID: handle.accountID)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    public func handles() async throws -> [CredentialHandle] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "credential" }
        .compactMap { url in
            let accountID = url.deletingPathExtension().lastPathComponent
            return Self.isValidAccountID(accountID)
                ? CredentialHandle(accountID: accountID)
                : nil
        }
        .sorted { $0.accountID < $1.accountID }
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func credentialURL(accountID: String) throws -> URL {
        guard Self.isValidAccountID(accountID) else {
            throw InsecureDebugCredentialError.invalidAccountID
        }
        return directory.appendingPathComponent("\(accountID).credential", isDirectory: false)
    }

    private static func isValidAccountID(_ accountID: String) -> Bool {
        !accountID.isEmpty && accountID.allSatisfy(\.isNumber)
    }

    private static func defaultDirectory(fileManager: FileManager) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("SakuraCord", isDirectory: true)
            .appendingPathComponent("InsecureDebugCredentials", isDirectory: true)
    }
}

public actor InsecureDebugMigratingCredentialStore: CredentialStore {
    private let local: any CredentialStore
    private let keychain: any CredentialStore
    private var didAttemptMigration = false

    public init(
        local: any CredentialStore = InsecureDebugFileCredentialStore(),
        keychain: any CredentialStore = KeychainCredentialStore()
    ) {
        self.local = local
        self.keychain = keychain
    }

    public func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        try await local.store(credential, accountID: accountID)
    }

    public func credential(for handle: CredentialHandle) async throws -> Data {
        try await local.credential(for: handle)
    }

    public func remove(_ handle: CredentialHandle) async throws {
        try await local.remove(handle)
        try await keychain.remove(handle)
    }

    public func handles() async throws -> [CredentialHandle] {
        let localHandles = try await local.handles()
        guard localHandles.isEmpty, !didAttemptMigration else { return localHandles }
        didAttemptMigration = true
        let keychainHandles = try await keychain.handles()
        for handle in keychainHandles {
            var credential = try await keychain.credential(for: handle)
            do {
                _ = try await local.store(credential, accountID: handle.accountID)
                credential.resetBytes(in: credential.indices)
            } catch {
                credential.resetBytes(in: credential.indices)
                throw error
            }
        }
        return try await local.handles()
    }
}

public enum InsecureDebugCredentialError: LocalizedError, Sendable {
    case invalidAccountID

    public var errorDescription: String? {
        "The debug credential account identifier is invalid."
    }
}

public nonisolated enum CredentialServiceName {
    public static let primary = "dev.sakuracord.SakuraCord.session"

    public static func resolve(bundleIdentifier: String?) -> String {
        guard let bundleIdentifier,
              bundleIdentifier.hasPrefix("dev.sakuracord.SakuraCord.worktree.")
        else {
            return primary
        }
        return "\(primary).\(bundleIdentifier)"
    }
}

public struct KeychainError: LocalizedError, Sendable {
    public let status: OSStatus
    public var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
}
