import CLibdave
import Foundation

class DaveSession {
    private let sessionHandle: DAVESessionHandle
    init() {
        sessionHandle = daveSessionCreate(nil, nil, { _, _, _ in }, nil)
    }

    deinit {
        daveSessionDestroy(self.sessionHandle)
    }

    func getKeyRatchet(userId: String) -> KeyRatchet {
        KeyRatchet(handle: daveSessionGetKeyRatchet(sessionHandle, userId))
    }

    func reset() {
        daveSessionReset(sessionHandle)
    }

    func setProtocolVersion(_ version: UInt16) {
        daveSessionSetProtocolVersion(sessionHandle, version)
    }

    func setExternalSenderPackage(externalSenderPackage: Data) {
        externalSenderPackage.withUnsafeBytes { externalSenderPackage in
            let externalSenderPackage = externalSenderPackage.bindMemory(to: UInt8.self)
            daveSessionSetExternalSender(
                self.sessionHandle,
                externalSenderPackage.baseAddress,
                externalSenderPackage.count
            )
        }
    }

    func initialize(version: UInt16, groupId: UInt64, selfUserId: String) {
        daveSessionInit(sessionHandle, version, groupId, selfUserId)
    }

    func getKeyPackage() -> Data {
        var outputLength = 0
        var data: UnsafeMutablePointer<UInt8>?
        daveSessionGetMarshalledKeyPackage(
            sessionHandle,
            &data,
            &outputLength
        )

        guard let data else { return Data() }
        defer { daveFree(data) }
        return Data(bytes: data, count: outputLength)
    }

    func getProtocolVersion() -> UInt16 {
        daveSessionGetProtocolVersion(sessionHandle)
    }

    func processProposals(proposals: Data, knownUserIds: [String]) -> Data? {
        var welcomeData: UnsafeMutablePointer<UInt8>?
        var welcomeDataLength = 0
        withCStringArray(knownUserIds) { knownUserIds in
            proposals.withUnsafeBytes { proposals in
                let proposals = proposals.bindMemory(to: UInt8.self)
                daveSessionProcessProposals(
                    self.sessionHandle,
                    proposals.baseAddress,
                    proposals.count,
                    knownUserIds.baseAddress,
                    knownUserIds.count,
                    &welcomeData,
                    &welcomeDataLength
                )
            }
        }

        guard let welcomeData else { return nil }
        defer { daveFree(welcomeData) }
        return Data(bytes: welcomeData, count: welcomeDataLength)
    }

    func processWelcome(welcome: Data, knownUserIds: [String]) -> Welcome? {
        let result = withCStringArray(knownUserIds) { knownUserIds in
            welcome.withUnsafeBytes { welcome in
                let welcome = welcome.bindMemory(to: UInt8.self)
                return daveSessionProcessWelcome(
                    self.sessionHandle,
                    welcome.baseAddress,
                    welcome.count,
                    knownUserIds.baseAddress,
                    knownUserIds.count
                )
            }
        }

        if let result {
            return Welcome(handle: result)
        } else {
            return nil
        }
    }

    func processCommit(commit: Data) -> Commit? {
        let handle = commit.withUnsafeBytes { commit in
            let commit = commit.bindMemory(to: UInt8.self)
            return daveSessionProcessCommit(
                self.sessionHandle,
                commit.baseAddress!,
                commit.count
            )
        }

        if let handle {
            return Commit(handle: handle)
        } else {
            return nil
        }
    }

    private func withCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutableBufferPointer<UnsafePointer<CChar>?>) -> Result
    ) -> Result {
        let storage = strings.map { strdup($0) }
        defer { storage.forEach { free($0) } }
        var pointers: [UnsafePointer<CChar>?] = storage.map { pointer in
            pointer.map { UnsafePointer<CChar>($0) }
        }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer)
        }
    }
}
