import Foundation

final class StatusRecoveryResponseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var response: (@Sendable () -> Void)?
    private var captured = false
    private var released = false
    var didCapture: Bool { lock.withLock { captured } }
    func capture(_ value: @escaping @Sendable () -> Void) {
        let run = lock.withLock {
            captured = true
            if released { return true }
            response = value
            return false
        }
        if run { value() }
    }
    func release() {
        let value = lock.withLock {
            released = true
            let value = response
            response = nil
            return value
        }
        value?()
    }
}

/// The existing serialized response queue owns each gate with its response;
/// there is no separately mutable global gate shared by later requests.
struct SettingsProtocolReply: Sendable {
    let status: Int
    let body: String
    let gate: StatusRecoveryResponseGate?

    init(_ status: Int, _ body: String, gate: StatusRecoveryResponseGate? = nil) {
        self.status = status
        self.body = body
        self.gate = gate
    }
}

extension DirectMessageURLProtocol {
    func completeResponse(status: Int, body: String) {
        respond(status: status, body: Data(body.utf8), headers: nil)
    }
}
