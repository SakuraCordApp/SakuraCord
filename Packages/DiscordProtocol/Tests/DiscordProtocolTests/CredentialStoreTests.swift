@testable import DiscordProtocol
import Foundation
import Testing

@Test func `worktree builds isolate keychain credentials from the primary app`() {
    #expect(
        CredentialServiceName.resolve(bundleIdentifier: "dev.sakuracord.SakuraCord")
            == CredentialServiceName.primary
    )
    #expect(
        CredentialServiceName.resolve(bundleIdentifier: nil)
            == CredentialServiceName.primary
    )

    let worktreeIdentifier = "dev.sakuracord.SakuraCord.worktree.wauthenticated-audi"
    #expect(
        CredentialServiceName.resolve(bundleIdentifier: worktreeIdentifier)
            == "\(CredentialServiceName.primary).\(worktreeIdentifier)"
    )
}

@Test func `insecure debug file credentials use private permissions and round trip`() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = InsecureDebugFileCredentialStore(directory: directory)
    let credential = Data("debug-secret".utf8)

    let handle = try await store.store(credential, accountID: "123456789")

    #expect(try await store.handles() == [handle])
    #expect(try await store.credential(for: handle) == credential)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    let fileAttributes = try FileManager.default.attributesOfItem(
        atPath: directory.appendingPathComponent("123456789.credential").path
    )
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    try await store.remove(handle)
    #expect(try await store.handles().isEmpty)
}

@Test func `insecure debug migration copies keychain credential only once`() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let local = InsecureDebugFileCredentialStore(directory: directory)
    let source = CredentialStoreSpy(credentials: ["42": Data("migrated".utf8)])
    let store = InsecureDebugMigratingCredentialStore(local: local, keychain: source)

    #expect(try await store.handles() == [CredentialHandle(accountID: "42")])
    #expect(try await store.handles() == [CredentialHandle(accountID: "42")])
    #expect(await source.handleReads == 1)
    #expect(try await store.credential(for: CredentialHandle(accountID: "42")) == Data("migrated".utf8))
}

private actor CredentialStoreSpy: CredentialStore {
    private var credentials: [String: Data]
    private(set) var handleReads = 0

    init(credentials: [String: Data]) {
        self.credentials = credentials
    }

    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        credentials[accountID] = credential
        return CredentialHandle(accountID: accountID)
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        guard let credential = credentials[handle.accountID] else {
            throw InsecureDebugCredentialError.invalidAccountID
        }
        return credential
    }

    func remove(_ handle: CredentialHandle) async throws {
        credentials.removeValue(forKey: handle.accountID)
    }

    func handles() async throws -> [CredentialHandle] {
        handleReads += 1
        return credentials.keys.sorted().map(CredentialHandle.init(accountID:))
    }
}
