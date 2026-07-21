@testable import DaveKit
import Foundation
import Testing

private actor TestDelegate: DaveSessionDelegate {
    private(set) var keyPackageCount = 0
    private(set) var lastKeyPackage = Data()
    private(set) var readyTransitionIDs: [UInt16] = []

    func mlsKeyPackage(keyPackage: Data) async {
        keyPackageCount += 1
        lastKeyPackage = keyPackage
    }

    func readyForTransition(transitionId: UInt16) async {
        readyTransitionIDs.append(transitionId)
    }

    func mlsCommitWelcome(welcome: Data) async {}
    func mlsInvalidCommitWelcome(transitionId: UInt16) async {}
}

@Test func `prepare epoch distinguishes new group from protocol version rotation`() async {
    let delegate = TestDelegate()
    let manager = DaveSessionManager(selfUserId: "1", groupId: 10, delegate: delegate)

    await manager.prepareEpoch(transitionId: 3, epoch: "1", protocolVersion: 1)
    #expect(await delegate.keyPackageCount == 1)
    #expect(await !delegate.lastKeyPackage.isEmpty)
    #expect(await delegate.readyTransitionIDs.isEmpty)

    await manager.prepareEpoch(transitionId: 44, epoch: "2", protocolVersion: 2)
    #expect(await delegate.keyPackageCount == 1)
    #expect(await delegate.readyTransitionIDs == [44])
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
