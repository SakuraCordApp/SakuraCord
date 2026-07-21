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
