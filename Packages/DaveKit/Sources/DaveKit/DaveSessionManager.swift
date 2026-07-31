import CLibdave
import Foundation
import OSLog

private let daveProtocolLogger = Logger(subsystem: "dev.sakuracord.SakuraCord", category: "DAVE")

public actor DaveSessionManager {
    // MARK: - Constants

    private static let initialTransitionID: UInt16 = 0
    private static let disabledProtocolVersion = 0
    private static let mlsNewGroupExpectedEpoch = "1"

    /// Static property initializer to set up logging only once, even across multiple instances
    private static let setupLogging: Void = {
        daveSetLogSinkCallback(logSyncCallback)
    }()

    // MARK: - Properties

    private let selfUserId: String
    private let groupId: UInt64

    private let session: DaveSession
    private let encryptor: Encryptor
    private var decryptors: [String: Decryptor] = [:]

    private var lastPreparedTransitionVersion: UInt16 = 0
    private var preparedTransitions: [UInt16: UInt16] = [:]

    private weak let delegate: (any DaveSessionDelegate)?

    // MARK: - Initializer

    public init(
        selfUserId: String,
        groupId: UInt64,
        delegate: DaveSessionDelegate
    ) {
        self.selfUserId = selfUserId
        self.groupId = groupId
        self.delegate = delegate

        _ = Self.setupLogging

        session = DaveSession()
        encryptor = Encryptor()
        encryptor.setPassthroughMode(enabled: true)
    }

    // MARK: - Static (informational) Methods

    public nonisolated static func maxSupportedProtocolVersion() -> UInt16 {
        daveMaxSupportedProtocolVersion()
    }

    // MARK: - User Management

    public func addUser(userId: String) {
        guard decryptors[userId] == nil else { return }
        decryptors[userId] = Decryptor()
        setupKeyRatchetForUser(userId: userId, protocolVersion: lastPreparedTransitionVersion)
        daveProtocolLogger.info("DAVE participant added; participantCount=\(self.decryptors.count)")
    }

    public func removeUser(userId: String) {
        decryptors.removeValue(forKey: userId)
    }

    // MARK: - Encryption / Decryption

    public func encrypt(
        ssrc: UInt32,
        data: Data,
        mediaType: DaveMediaType = .audio
    ) throws(EncryptError) -> Data {
        try encryptor.encrypt(ssrc: ssrc, data: data, mediaType: mediaType)
    }

    public func assignAudioSSRC(_ ssrc: UInt32) {
        encryptor.assign(ssrc: ssrc, codec: .opus)
    }

    public func assignVideoSSRC(_ ssrc: UInt32, codec: DaveCodec) {
        encryptor.assign(ssrc: ssrc, codec: codec)
    }

    public func decrypt(
        userId: String,
        data: Data,
        mediaType: DaveMediaType = .audio
    ) throws(DecryptError) -> Data? {
        guard let decryptor = decryptors[userId] else {
            daveProtocolLogger.warning("DAVE decrypt skipped because participant ratchet is unavailable")
            return nil
        }

        return try decryptor.decrypt(data: data, mediaType: mediaType)
    }

    // MARK: - Incoming Voice Gateway Requests

    /// Opcode SELECT_PROTOCOL_ACK (1)
    public func selectProtocol(protocolVersion: UInt16) async {
        daveProtocolLogger.info("DAVE protocol selected; version=\(protocolVersion)")
        if protocolVersion > Self.disabledProtocolVersion {
            await prepareEpoch(
                transitionId: Self.initialTransitionID,
                epoch: Self.mlsNewGroupExpectedEpoch,
                protocolVersion: protocolVersion
            )
        } else {
            await prepareTransition(
                transitionId: Self.initialTransitionID,
                protocolVersion: protocolVersion
            )
            executeTransition(transitionId: Self.initialTransitionID)
        }
    }

    /// Opcode DAVE_PROTOCOL_PREPARE_TRANSITION (21)
    public func prepareTransition(transitionId: UInt16, protocolVersion: UInt16) async {
        daveProtocolLogger.info(
            "DAVE transition prepared; id=\(transitionId), version=\(protocolVersion), participants=\(self.decryptors.count)"
        )
        for userId in decryptors.keys {
            setupKeyRatchetForUser(userId: userId, protocolVersion: protocolVersion)
        }

        if transitionId == Self.initialTransitionID {
            setupKeyRatchetForEncryptor(protocolVersion: protocolVersion)
        } else {
            preparedTransitions[transitionId] = protocolVersion
        }

        lastPreparedTransitionVersion = protocolVersion

        if transitionId != Self.initialTransitionID {
            await delegate?.readyForTransition(transitionId: transitionId)
        }
    }

    /// Opcode DAVE_PROTOCOL_EXECUTE_TRANSITION (22)
    public func executeTransition(transitionId: UInt16) {
        guard let protocolVersion = preparedTransitions.removeValue(forKey: transitionId) else {
            daveProtocolLogger.warning("DAVE execute ignored because transition was not prepared; id=\(transitionId)")
            return
        }

        if protocolVersion == Self.disabledProtocolVersion {
            session.reset()
        }

        setupKeyRatchetForEncryptor(protocolVersion: protocolVersion)
        daveProtocolLogger.info("DAVE transition executed; id=\(transitionId), version=\(protocolVersion)")
    }

    /// Opcode DAVE_PROTOCOL_PREPARE_EPOCH (24)
    public func prepareEpoch(
        transitionId: UInt16,
        epoch: String,
        protocolVersion: UInt16
    ) async {
        guard let epochNumber = UInt64(epoch), epochNumber > 0 else { return }
        daveProtocolLogger.info(
            "DAVE epoch preparation; id=\(transitionId), epoch=\(epoch, privacy: .public), version=\(protocolVersion)"
        )

        if epoch == Self.mlsNewGroupExpectedEpoch {
            session.initialize(version: protocolVersion, groupId: groupId, selfUserId: selfUserId)
            let keyPackage = session.getKeyPackage()
            daveProtocolLogger.info("DAVE key package generated; bytes=\(keyPackage.count)")
            await delegate?.mlsKeyPackage(keyPackage: keyPackage)
            return
        }

        // Epochs after the initial MLS group retain the existing group state.
        // Only the DAVE protocol context and media ratchets transition.
        session.setProtocolVersion(protocolVersion)
        await prepareTransition(transitionId: transitionId, protocolVersion: protocolVersion)
    }

    /// Opcode MLS_EXTERNAL_SENDER_PACKAGE (25)
    public func mlsExternalSenderPackage(externalSenderPackage: Data) {
        daveProtocolLogger.info("DAVE external sender received; bytes=\(externalSenderPackage.count)")
        session.setExternalSenderPackage(externalSenderPackage: externalSenderPackage)
    }

    /// Opcode MLS_PROPOSALS (27)
    public func mlsProposals(proposals: Data) async {
        daveProtocolLogger.info("DAVE proposals received; bytes=\(proposals.count)")
        let welcome = session.processProposals(proposals: proposals, knownUserIds: knownUserIds)
        if let welcome {
            await delegate?.mlsCommitWelcome(welcome: welcome)
        }
    }

    /// Opcode MLS_PREPARE_COMMIT_TRANSITION (29)
    public func mlsPrepareCommitTransition(transitionId: UInt16, commit: Data) async {
        daveProtocolLogger.info("DAVE commit received; id=\(transitionId), bytes=\(commit.count)")
        let commit = session.processCommit(commit: commit)

        guard let commit, !commit.isFailed else {
            await delegate?.mlsInvalidCommitWelcome(transitionId: transitionId)
            await selectProtocol(protocolVersion: session.getProtocolVersion())
            return
        }

        if commit.isIgnored {
            return
        }

        await prepareTransition(transitionId: transitionId, protocolVersion: session.getProtocolVersion())
    }

    /// Opcode MLS_WELCOME (30)
    public func mlsWelcome(transitionId: UInt16, welcome: Data) async {
        daveProtocolLogger.info("DAVE welcome received; id=\(transitionId), bytes=\(welcome.count)")
        let welcome = session.processWelcome(
            welcome: welcome,
            knownUserIds: knownUserIds
        )
        guard welcome != nil else {
            await delegate?.mlsInvalidCommitWelcome(transitionId: transitionId)
            await delegate?.mlsKeyPackage(keyPackage: session.getKeyPackage())
            return
        }

        await prepareTransition(
            transitionId: transitionId,
            protocolVersion: session.getProtocolVersion()
        )
    }

    // MARK: - Private Methods

    private var knownUserIds: [String] {
        Array(decryptors.keys) + [selfUserId]
    }

    private func setupKeyRatchetForEncryptor(protocolVersion: UInt16) {
        if protocolVersion == Self.disabledProtocolVersion {
            encryptor.setPassthroughMode(enabled: true)
            return
        }

        encryptor.setPassthroughMode(enabled: false)
        encryptor.setKeyRatchet(keyRatchet: session.getKeyRatchet(userId: selfUserId))
    }

    private func setupKeyRatchetForUser(userId: String, protocolVersion: UInt16) {
        guard let decryptor = decryptors[userId] else {
            return
        }

        if protocolVersion == Self.disabledProtocolVersion {
            decryptor.transitionToPassthroughMode(enabled: true)
            return
        }

        decryptor.transitionToPassthroughMode(enabled: false)
        decryptor.transitionToKeyRatchet(keyRatchet: session.getKeyRatchet(userId: userId))
    }
}
