import CDave
import Foundation

/// A DAVE client: an MLS member of a voice room's group with a frame encryptor
/// for its own media and decryptors for others', all from upstream libdave's
/// C API. Simulated people are members; the parity suite plays a client with one.
/// One lock serializes every call, since the voice gateway changes the group
/// while the media server encrypts frames.
final class DaveMember: @unchecked Sendable {
    let userID: Snowflake
    private let lock = NSLock()
    private let session: DAVESessionHandle
    private let encryptor: DAVEEncryptorHandle
    private var decryptors: [Snowflake: DAVEDecryptorHandle] = [:]

    init?(userID: Snowflake, groupID: Snowflake, externalSender: Data, recognized: [Snowflake]) {
        guard let session = daveSessionCreate(nil, nil, nil, nil), let encryptor = daveEncryptorCreate() else { return nil }
        self.userID = userID
        self.session = session
        self.encryptor = encryptor
        externalSender.withUnsafeBytes { daveSessionSetExternalSender(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
        daveSessionInit(session, 1, groupID.rawValue, userID.description)
        for other in recognized where other != userID { daveSessionAddRecognizedUser(session, other.description) }
        daveEncryptorSetPassthroughMode(encryptor, false)
    }

    deinit {
        decryptors.values.forEach(daveDecryptorDestroy)
        daveEncryptorDestroy(encryptor)
        daveSessionDestroy(session)
    }

    func recognize(_ userID: Snowflake) { locked { daveSessionAddRecognizedUser(session, userID.description) } }

    func keyPackage() -> Data { locked { Dave.output { daveSessionGetMarshalledKeyPackage(session, $0, $1) } } }

    /// The commit (and welcome, if it adds anyone) for proposals from the external sender.
    func commit(proposals: Data) -> Data {
        locked {
            proposals.withUnsafeBytes { input in
                Dave.output { daveSessionProcessProposals(session, input.bindMemory(to: UInt8.self).baseAddress, input.count, $0, $1) }
            }
        }
    }

    /// Applies a winning commit; false when libdave rejects it.
    @discardableResult
    func apply(commit: Data) -> Bool {
        locked {
            let result = commit.withUnsafeBytes { daveSessionProcessCommit(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
            defer { daveCommitResultDestroy(result) }
            return result != nil && !daveCommitResultIsFailed(result)
        }
    }

    /// Joins from a welcome; false when libdave rejects it.
    @discardableResult
    func join(welcome: Data) -> Bool {
        locked {
            let result = welcome.withUnsafeBytes { daveSessionProcessWelcome(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
            defer { daveWelcomeResultDestroy(result) }
            return result != nil
        }
    }

    /// Switches media to this epoch's keys (the transition executes).
    func useCurrentKey() {
        locked {
            if let ratchet = daveSessionGetKeyRatchet(session, userID.description) {
                daveEncryptorSetKeyRatchet(encryptor, ratchet)
                daveKeyRatchetDestroy(ratchet)
            }
            for (sender, decryptor) in decryptors { install(sender, into: decryptor) }
        }
    }

    /// `sender`'s media frame, or nil when it doesn't decrypt.
    func decrypt(_ frame: Data, from sender: Snowflake, video: Bool) -> Data? {
        locked {
            let decryptor = decryptors[sender] ?? {
                let created = daveDecryptorCreate()
                if let created { install(sender, into: created) }
                decryptors[sender] = created
                return created
            }()
            guard let decryptor else { return nil }
            let type = video ? DAVE_MEDIA_TYPE_VIDEO : DAVE_MEDIA_TYPE_AUDIO
            var output = Data(count: daveDecryptorGetMaxPlaintextByteSize(decryptor, type, frame.count))
            var written = 0
            let result = frame.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { buffer in
                    daveDecryptorDecrypt(decryptor, type, input.bindMemory(to: UInt8.self).baseAddress, input.count,
                                         buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &written)
                }
            }
            return result == DAVE_DECRYPTOR_RESULT_CODE_SUCCESS ? output.prefix(written) : nil
        }
    }

    private func install(_ sender: Snowflake, into decryptor: DAVEDecryptorHandle) {
        guard let ratchet = daveSessionGetKeyRatchet(session, sender.description) else { return }
        daveDecryptorTransitionToPassthroughMode(decryptor, false)
        daveDecryptorTransitionToKeyRatchet(decryptor, ratchet)
        daveKeyRatchetDestroy(ratchet)
    }

    /// A DAVE frame for `frame`, or nil while there is no key yet.
    func encrypt(_ frame: Data, ssrc: UInt32, codec: DAVECodec) -> Data? {
        locked {
            daveEncryptorAssignSsrcToCodec(encryptor, ssrc, codec)
            let type = codec == DAVE_CODEC_OPUS ? DAVE_MEDIA_TYPE_AUDIO : DAVE_MEDIA_TYPE_VIDEO
            var output = Data(count: daveEncryptorGetMaxCiphertextByteSize(encryptor, type, frame.count))
            var written = 0
            let result = frame.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { buffer in
                    daveEncryptorEncrypt(encryptor, type, ssrc, input.bindMemory(to: UInt8.self).baseAddress, input.count,
                                         buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &written)
                }
            }
            return result == DAVE_ENCRYPTOR_RESULT_CODE_SUCCESS ? output.prefix(written) : nil
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// The voice server's side of DAVE: the external sender that proposes adds and
/// removes, from libdave's upstream external sender.
final class DaveExternalSender: @unchecked Sendable {
    private let handle: DAVEExternalSenderHandle

    init?(groupID: Snowflake) {
        guard let handle = daveExternalSenderCreate(groupID.rawValue) else { return nil }
        self.handle = handle
    }

    deinit { daveExternalSenderDestroy(handle) }

    var package: Data { Dave.output { daveExternalSenderGetMarshalledExternalSender(handle, $0, $1) } }

    func proposeAdd(epoch: UInt32, keyPackage: Data) -> Data {
        var copy = [UInt8](keyPackage)
        return Dave.output { daveExternalSenderProposeAdd(handle, epoch, &copy, copy.count, $0, $1) }
    }

    func proposeRemove(epoch: UInt32, leaf: UInt32) -> Data {
        Dave.output { daveExternalSenderProposeRemove(handle, epoch, leaf, $0, $1) }
    }

    /// A client's op 28 payload split into the commit and, when it adds members, the welcome.
    func split(commitWelcome: Data) -> (commit: Data, welcome: Data) {
        var copy = [UInt8](commitWelcome)
        var welcome = Data()
        let commit = Dave.output { commitOut, commitLength in
            welcome = Dave.output { daveExternalSenderSplitCommitWelcome(handle, &copy, copy.count, commitOut, commitLength, $0, $1) }
        }
        return (commit, welcome)
    }
}

enum Dave {
    /// Collects a libdave output buffer and frees it.
    static func output(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, UnsafeMutablePointer<Int>) -> Void) -> Data {
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        body(&pointer, &length)
        guard let pointer else { return Data() }
        defer { daveFree(pointer) }
        return Data(bytes: pointer, count: length)
    }

    /// One proposals message (op 27) from several single-proposal ones: the
    /// append flag, then one TLS vector holding every MLS message.
    static func combine(proposals: [Data]) -> Data {
        let messages = proposals.reduce(into: Data()) { all, proposal in
            let bytes = [UInt8](proposal)
            guard bytes.count > 1, let (_, prefix) = varint(bytes, at: 1) else { return }
            all += bytes[(1 + prefix)...]
        }
        return Data([0]) + encodeVarint(messages.count) + messages
    }

    /// MLS's variable-length integer (RFC 9420 §2.1.2): value and encoded size.
    static func varint(_ bytes: [UInt8], at offset: Int) -> (Int, Int)? {
        guard offset < bytes.count else { return nil }
        let size = 1 << Int(bytes[offset] >> 6)
        guard size <= 4, offset + size <= bytes.count else { return nil }
        let value = bytes[offset ..< offset + size].enumerated().reduce(0) { $0 << 8 | Int($1.offset == 0 ? $1.element & 0x3F : $1.element) }
        return (value, size)
    }

    static func encodeVarint(_ value: Int) -> Data {
        switch value {
        case ..<0x40: Data([UInt8(value)])
        case ..<0x4000: Data([0x40 | UInt8(value >> 8), UInt8(value & 0xFF)])
        default: Data([0x80 | UInt8(value >> 24 & 0x3F), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
        }
    }
}
