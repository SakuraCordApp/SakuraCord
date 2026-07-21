import CLibdave
import Foundation

class Encryptor {
    private let encryptorHandle: DAVEEncryptorHandle

    init() {
        encryptorHandle = daveEncryptorCreate()
    }

    deinit {
        daveEncryptorDestroy(self.encryptorHandle)
    }

    func setKeyRatchet(keyRatchet: KeyRatchet) {
        daveEncryptorSetKeyRatchet(encryptorHandle, keyRatchet.handle)
    }

    func setPassthroughMode(enabled: Bool) {
        daveEncryptorSetPassthroughMode(encryptorHandle, enabled)
    }

    func assign(ssrc: UInt32, codec: DaveCodec) {
        daveEncryptorAssignSsrcToCodec(encryptorHandle, ssrc, codec.nativeValue)
    }

    func encrypt(
        ssrc: UInt32,
        data: Data,
        mediaType: DaveMediaType = .audio
    ) throws(EncryptError) -> Data {
        let capacity = daveEncryptorGetMaxCiphertextByteSize(
            encryptorHandle,
            mediaType.nativeValue,
            data.count
        )
        var encryptedData = Data(count: max(capacity, data.count))
        var outputLength = 0

        let result = encryptedData.withUnsafeMutableBytes { encryptedData in
            data.withUnsafeBytes { data in
                let encryptedData = encryptedData.bindMemory(to: UInt8.self)
                let data = data.bindMemory(to: UInt8.self)

                return daveEncryptorEncrypt(
                    self.encryptorHandle,
                    mediaType.nativeValue,
                    ssrc,
                    data.baseAddress!,
                    data.count,
                    encryptedData.baseAddress!,
                    encryptedData.count,
                    &outputLength
                )
            }
        }

        if let error = EncryptError(rawValue: result) {
            throw error
        }

        encryptedData.removeSubrange(outputLength ..< encryptedData.count)
        return encryptedData
    }
}

private extension DaveCodec {
    var nativeValue: DAVECodec {
        let value: UInt32 = switch self {
        case .opus: 1
        case .vp8: 2
        case .vp9: 3
        case .h264: 4
        case .h265: 5
        case .av1: 6
        }
        return DAVECodec(rawValue: value)!
    }
}

extension DaveMediaType {
    var nativeValue: MediaType {
        switch self {
        case .audio: .audio
        case .video: .video
        }
    }
}

public enum EncryptError: Error {
    case encryptionFailure
    case missingKeyRatchet
    case missingCryptor
    case tooManyAttempts
    case unknown

    init?(rawValue: DAVEEncryptorResultCode) {
        switch rawValue {
        case DAVE_ENCRYPTOR_RESULT_CODE_SUCCESS:
            return nil
        case DAVE_ENCRYPTOR_RESULT_CODE_ENCRYPTION_FAILURE:
            self = .encryptionFailure
        case DAVE_ENCRYPTOR_RESULT_CODE_MISSING_KEY_RATCHET:
            self = .missingKeyRatchet
        case DAVE_ENCRYPTOR_RESULT_CODE_MISSING_CRYPTOR:
            self = .missingCryptor
        case DAVE_ENCRYPTOR_RESULT_CODE_TOO_MANY_ATTEMPTS:
            self = .tooManyAttempts
        default:
            self = .unknown
        }
    }
}
