import Foundation

/// Delegate protocol for handling DaveSession events, to send messages
/// back to the gateway.
public protocol DaveSessionDelegate: AnyObject, Sendable {
    /// Opcode MLS_KEY_PACKAGE (26)
    func mlsKeyPackage(keyPackage: Data) async
    /// Opcode DAVE_PROTOCOL_READY_FOR_TRANSITION (23)
    func readyForTransition(transitionId: UInt16) async
    /// Opcode MLS_COMMIT_WELCOME (28)
    func mlsCommitWelcome(welcome: Data) async
    /// Opcode MLS_INVALID_COMMIT_WELCOME (31)
    func mlsInvalidCommitWelcome(transitionId: UInt16) async
}
