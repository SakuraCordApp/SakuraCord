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

@Test func `pending credential persists once under the gateway ready account`() async throws {
    let value = Data("pending-session-credential-value".utf8)
    let pending = try PendingDiscordCredential(value)
    let store = CredentialStoreSpy(credentials: [:])

    let handle = try await pending.persist(to: store, accountID: "123456789012345678")

    #expect(handle == CredentialHandle(accountID: "123456789012345678"))
    #expect(try await store.credential(for: handle) == value)
    await #expect(throws: PendingDiscordCredentialError.unavailable) {
        try await pending.value()
    }
}

@Test func `concurrent pending credential persistence admits only one keychain write`() async throws {
    let pending = try PendingDiscordCredential(
        Data("pending-session-credential-value".utf8)
    )
    let store = SuspendedCredentialStore()
    let first = Task {
        try await pending.persist(to: store, accountID: "123456789012345678")
    }
    await store.waitUntilStoreStarts()

    await #expect(throws: PendingDiscordCredentialError.unavailable) {
        try await pending.persist(to: store, accountID: "123456789012345678")
    }

    await store.releaseStore()
    #expect(try await first.value == CredentialHandle(accountID: "123456789012345678"))
    #expect(await store.storeCount == 1)
}

@Test func `invalid ready account does not consume the pending credential`() async throws {
    let value = Data("pending-session-credential-value".utf8)
    let pending = try PendingDiscordCredential(value)
    let store = CredentialStoreSpy(credentials: [:])

    await #expect(throws: PendingDiscordCredentialError.invalidAccountID) {
        try await pending.persist(to: store, accountID: "not-a-snowflake")
    }
    let handle = try await pending.persist(to: store, accountID: "123456789012345678")
    #expect(try await store.credential(for: handle) == value)
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

private actor SuspendedCredentialStore: CredentialStore {
    private(set) var storeCount = 0
    private var storeStarted = false
    private var storeReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var storeContinuation: CheckedContinuation<Void, Never>?

    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        storeCount += 1
        storeStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if !storeReleased {
            await withCheckedContinuation { storeContinuation = $0 }
        }
        return CredentialHandle(accountID: accountID)
    }

    func waitUntilStoreStarts() async {
        if storeStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseStore() {
        storeReleased = true
        storeContinuation?.resume()
        storeContinuation = nil
    }

    func credential(for handle: CredentialHandle) async throws -> Data { Data() }
    func remove(_ handle: CredentialHandle) async throws {}
    func handles() async throws -> [CredentialHandle] { [] }
}
