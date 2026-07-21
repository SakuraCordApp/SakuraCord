import CLibdave
import Foundation

class Decryptor {
    private let decryptorHandle: DAVEDecryptorHandle

    init() {
        decryptorHandle = daveDecryptorCreate()
    }

    deinit {
        daveDecryptorDestroy(self.decryptorHandle)
    }

    func transitionToKeyRatchet(keyRatchet: KeyRatchet) {
        daveDecryptorTransitionToKeyRatchet(decryptorHandle, keyRatchet.handle)
    }

    func transitionToPassthroughMode(enabled: Bool) {
        daveDecryptorTransitionToPassthroughMode(decryptorHandle, enabled)
    }

    func decrypt(data: Data, mediaType: DaveMediaType = .audio) throws(DecryptError) -> Data {
        let capacity = daveDecryptorGetMaxPlaintextByteSize(
            decryptorHandle,
            mediaType.nativeValue,
            data.count
        )
        var decryptedData = Data(count: max(capacity, data.count))
        var outputLength = 0

        let result = decryptedData.withUnsafeMutableBytes { decryptedData in
            data.withUnsafeBytes { data in
                let decryptedData = decryptedData.bindMemory(to: UInt8.self)
                let data = data.bindMemory(to: UInt8.self)

                return daveDecryptorDecrypt(
                    self.decryptorHandle,
                    mediaType.nativeValue,
                    data.baseAddress!,
                    data.count,
                    decryptedData.baseAddress!,
                    decryptedData.count,
                    &outputLength
                )
            }
        }

        if let error = DecryptError(rawValue: result) {
            throw error
        }

        decryptedData.removeSubrange(outputLength ..< decryptedData.count)
        return decryptedData
    }
}

public enum DecryptError: Error {
    case decryptionFailure
    case missingKeyRatchet
    case invalidNonce
    case missingCryptor
    case unknown

    init?(rawValue: DAVEDecryptorResultCode) {
        switch rawValue {
        case DAVE_DECRYPTOR_RESULT_CODE_SUCCESS:
            return nil
        case DAVE_DECRYPTOR_RESULT_CODE_DECRYPTION_FAILURE:
            self = .decryptionFailure
        case DAVE_DECRYPTOR_RESULT_CODE_MISSING_KEY_RATCHET:
            self = .missingKeyRatchet
        case DAVE_DECRYPTOR_RESULT_CODE_INVALID_NONCE:
            self = .invalidNonce
        case DAVE_DECRYPTOR_RESULT_CODE_MISSING_CRYPTOR:
            self = .missingCryptor
        default:
            self = .unknown
        }
    }
}
