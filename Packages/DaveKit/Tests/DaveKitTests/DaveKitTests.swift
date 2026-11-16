@testable import DaveKit
import DaveKitTestSupport
import Foundation
import Testing

private actor TestDelegate: DaveSessionDelegate {
    private(set) var keyPackageCount = 0
    private(set) var lastKeyPackage = Data()
    private(set) var readyTransitionIDs: [UInt16] = []
    private(set) var invalidTransitionIDs: [UInt16] = []
    private(set) var commitWelcome = Data()

    func mlsKeyPackage(keyPackage: Data) async {
        keyPackageCount += 1
        lastKeyPackage = keyPackage
    }

    func readyForTransition(transitionId: UInt16) async {
        readyTransitionIDs.append(transitionId)
    }

    func mlsCommitWelcome(welcome: Data) async { commitWelcome = welcome }
    func mlsInvalidCommitWelcome(transitionId: UInt16) async {
        invalidTransitionIDs.append(transitionId)
    }
}

@Test func `prepare epoch distinguishes new group from protocol version rotation`() async {
    let delegate = TestDelegate()
    let manager = DaveSessionManager(selfUserId: "1", groupId: 10, delegate: delegate)

    await manager.prepareEpoch(epoch: "1", protocolVersion: 1)
    #expect(await delegate.keyPackageCount == 1)
    #expect(await !delegate.lastKeyPackage.isEmpty)

    await manager.prepareEpoch(epoch: "2", protocolVersion: 2)
    #expect(await delegate.keyPackageCount == 1)
    #expect(await delegate.readyTransitionIDs.isEmpty)
}

@Test func `sole member reset executes before the new group exists`() async {
    let delegate = TestDelegate()
    let manager = DaveSessionManager(selfUserId: "1", groupId: 10, delegate: delegate)

    await manager.prepareEpoch(epoch: "1", protocolVersion: 1)
    await manager.prepareTransition(transitionId: 0, protocolVersion: 1)
    #expect(await delegate.keyPackageCount == 1)
}

@Test func `passthrough encryption round trips H 264 frames`() async throws {
    let delegate = TestDelegate()
    let manager = DaveSessionManager(selfUserId: "1", groupId: 10, delegate: delegate)
    await manager.addUser(userId: "2")
    await manager.assignVideoSSRC(43, codec: .h264)
    let frame = Data([0, 0, 0, 1, 0x67, 1, 2, 3, 0, 0, 0, 1, 0x65, 4, 5, 6])

    let encrypted = try await manager.encrypt(ssrc: 43, data: frame, mediaType: .video)
    let decrypted = try await manager.decrypt(userId: "2", data: encrypted, mediaType: .video)

    #expect(encrypted == frame)
    #expect(decrypted == frame)
}

@Test func `passthrough encryption round trips audio frames`() async throws {
    let delegate = TestDelegate()
    let manager = DaveSessionManager(selfUserId: "1", groupId: 10, delegate: delegate)
    await manager.addUser(userId: "2")
    await manager.assignAudioSSRC(42)
    let frame = Data([0xF8, 0xFF, 0xFE])

    let encrypted = try await manager.encrypt(ssrc: 42, data: frame)
    let decrypted = try await manager.decrypt(userId: "2", data: encrypted)

    #expect(DaveSessionManager.maxSupportedProtocolVersion() >= 1)
    #expect(encrypted == frame)
    #expect(decrypted == frame)
}

@Test func `reinstalling a ratchet preserves nonces and replay protection`() throws {
    let encryptor = Encryptor()
    let decryptor = Decryptor()
    let ratchet = KeyRatchet(handle: makeTestKeyRatchet(1))
    encryptor.assign(ssrc: 42, codec: .opus)
    encryptor.setKeyRatchet(keyRatchet: ratchet)
    decryptor.transitionToKeyRatchet(keyRatchet: ratchet)
    let frame = Data([0xF8, 0xFF, 0xFE])
    let first = try encryptor.encrypt(ssrc: 42, data: frame)
    #expect(try decryptor.decrypt(data: first) == frame)

    let sameEpoch = KeyRatchet(handle: makeTestKeyRatchet(1))
    encryptor.setKeyRatchet(keyRatchet: sameEpoch)
    decryptor.transitionToKeyRatchet(keyRatchet: sameEpoch)
    let second = try encryptor.encrypt(ssrc: 42, data: frame)
    #expect(first != second)
    #expect(try decryptor.decrypt(data: second) == frame)
    #expect(throws: DecryptError.self) { try decryptor.decrypt(data: first) }

    let nextEpoch = KeyRatchet(handle: makeTestKeyRatchet(2))
    encryptor.setKeyRatchet(keyRatchet: nextEpoch)
    decryptor.transitionToKeyRatchet(keyRatchet: nextEpoch)
    let third = try encryptor.encrypt(ssrc: 42, data: frame)
    #expect(third != first && third != second)
    #expect(try decryptor.decrypt(data: third) == frame)
}

@Test func `fresh voice sessions discard participants and pending transitions`() async throws {
    let delegate = TestDelegate()
    let manager = DaveSessionManager(selfUserId: "1", groupId: 10, delegate: delegate)
    await manager.addUser(userId: "2")
    await manager.prepareTransition(transitionId: 7, protocolVersion: 0)
    await manager.resetForFreshSession()
    await manager.executeTransition(transitionId: 7)
    let frame = Data([0xF8, 0xFF, 0xFE])
    #expect(try await manager.decrypt(userId: "2", data: frame) == nil)
    await #expect(throws: EncryptError.missingKeyRatchet) {
        try await manager.encrypt(ssrc: 42, data: frame)
    }
}

private enum WelcomeScenario: CaseIterable {
    case valid, wrongGroup, unknownMember
}

@Test(arguments: WelcomeScenario.allCases)
private func `MLS welcomes validate the group and roster and recover with usable keys`(
    scenario: WelcomeScenario
) async throws {
    let sender = try #require(makeTestExternalSender())
    defer { destroyTestExternalSender(sender) }
    let externalPackage = try copiedBytes(testExternalSenderPackage(sender))
    let delegate = TestDelegate()
    let receiver = DaveSessionManager(selfUserId: "2", groupId: 10, delegate: delegate)
    await receiver.resetForFreshSession()
    await receiver.selectProtocol(protocolVersion: 1)
    await receiver.mlsExternalSenderPackage(externalSenderPackage: externalPackage)
    if scenario != .unknownMember { await receiver.addUser(userId: "1") }

    // Each creator uses a real MLS session to commit the receiver's key package.
    func makeWelcome(groupId: UInt64, transitionId: UInt16) async throws -> (DaveSessionManager, Data) {
        let creatorDelegate = TestDelegate()
        let creator = DaveSessionManager(selfUserId: "1", groupId: groupId, delegate: creatorDelegate)
        await creator.resetForFreshSession()
        await creator.selectProtocol(protocolVersion: 1)
        await creator.mlsExternalSenderPackage(externalSenderPackage: externalPackage)
        await creator.addUser(userId: "2")
        let keyPackage = await delegate.lastKeyPackage
        let proposals = try keyPackage.withUnsafeBytes { bytes in
            try copiedBytes(testAddProposal(sender, groupId, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count))
        }
        await creator.mlsProposals(proposals: proposals)
        let combined = await creatorDelegate.commitWelcome
        #expect(!combined.isEmpty)
        let commit = try combined.withUnsafeBytes { bytes in
            try copiedBytes(testCommitWelcomePart(sender, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, false))
        }
        let welcome = try combined.withUnsafeBytes { bytes in
            try copiedBytes(testCommitWelcomePart(sender, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, true))
        }
        await creator.mlsPrepareCommitTransition(transitionId: transitionId, commit: commit)
        #expect(await creatorDelegate.invalidTransitionIDs.isEmpty)
        #expect(await creatorDelegate.readyTransitionIDs == [transitionId])
        await creator.executeTransition(transitionId: transitionId)
        return (creator, welcome)
    }

    var (creator, welcome) = try await makeWelcome(groupId: scenario == .wrongGroup ? 20 : 10, transitionId: 8)
    if scenario != .valid {
        let oldKeyPackage = await delegate.lastKeyPackage
        await receiver.prepareTransition(transitionId: 7, protocolVersion: 0)
        await receiver.mlsWelcome(transitionId: 8, welcome: welcome)
        #expect(await delegate.invalidTransitionIDs == [8])
        #expect(await delegate.keyPackageCount == 2)
        #expect(await delegate.lastKeyPackage != oldKeyPackage)
        #expect(await delegate.readyTransitionIDs == [7])
        await receiver.executeTransition(transitionId: 7)
        await #expect(throws: EncryptError.missingKeyRatchet) {
            try await receiver.encrypt(ssrc: 42, data: Data([0xF8, 0xFF, 0xFE]))
        }
        await receiver.addUser(userId: "1")
        (creator, welcome) = try await makeWelcome(groupId: 10, transitionId: 9)
    }

    let transitionId: UInt16 = scenario == .valid ? 8 : 9
    await receiver.mlsWelcome(transitionId: transitionId, welcome: welcome)
    #expect(await delegate.readyTransitionIDs.last == transitionId)
    #expect(await delegate.invalidTransitionIDs == (scenario == .valid ? [] : [8]))
    #expect(await delegate.keyPackageCount == (scenario == .valid ? 1 : 2))
    await receiver.executeTransition(transitionId: transitionId)
    await creator.assignAudioSSRC(41)
    await receiver.assignAudioSSRC(42)
    let frame = Data([0xF8, 0xFF, 0xFE])
    let outgoing = try await creator.encrypt(ssrc: 41, data: frame)
    let incoming = try await receiver.encrypt(ssrc: 42, data: frame)
    #expect(outgoing != frame && incoming != frame)
    #expect(try await receiver.decrypt(userId: "1", data: outgoing) == frame)
    #expect(try await creator.decrypt(userId: "2", data: incoming) == frame)
}

private func copiedBytes(_ bytes: DaveTestBytes) throws -> Data {
    let pointer = try #require(bytes.data)
    #expect(bytes.count > 0)
    return Data(bytes: pointer, count: bytes.count)
}
