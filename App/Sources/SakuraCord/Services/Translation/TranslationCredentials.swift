import DiscordProtocol
import Foundation
import Security

nonisolated protocol TranslationAPIKeyStoring: Sendable {
    func apiKey(for provider: TranslationProvider) async throws -> String?
    func setAPIKey(_ key: String?, for provider: TranslationProvider) async throws
}

/// Keeps translation API keys in the Keychain under their own service so they
/// never appear as saved Discord accounts and are never part of settings exports.
nonisolated struct KeychainTranslationAPIKeyStore: TranslationAPIKeyStoring {
    static let service = "dev.sakuracord.SakuraCord.translation"

    private let store: KeychainCredentialStore

    init(service: String = Self.service) {
        store = KeychainCredentialStore(service: service)
    }

    func apiKey(for provider: TranslationProvider) async throws -> String? {
        do {
            let data = try await store.credential(for: CredentialHandle(accountID: provider.rawValue))
            return String(data: data, encoding: .utf8)
        } catch let error as KeychainError where error.status == errSecItemNotFound {
            return nil
        }
    }

    func setAPIKey(_ key: String?, for provider: TranslationProvider) async throws {
        let handle = CredentialHandle(accountID: provider.rawValue)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            try await store.remove(handle)
            return
        }
        _ = try await store.store(Data(key.utf8), accountID: handle.accountID)
    }
}

actor InMemoryTranslationAPIKeyStore: TranslationAPIKeyStoring {
    private var keys: [TranslationProvider: String] = [:]

    init(_ keys: [TranslationProvider: String] = [:]) {
        self.keys = keys
    }

    func apiKey(for provider: TranslationProvider) -> String? {
        keys[provider]
    }

    func setAPIKey(_ key: String?, for provider: TranslationProvider) {
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        keys[provider] = key?.isEmpty == false ? key : nil
    }
}
