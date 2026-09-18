import Foundation

enum ComposerReturnAction: Equatable {
    case send
    case newline
    case inputMethod

    nonisolated static func decide(
        sendWithReturn: Bool,
        shift: Bool,
        command: Bool,
        hasMarkedText: Bool
    ) -> Self {
        if hasMarkedText {
            return .inputMethod
        }
        if shift {
            return .newline
        }
        if sendWithReturn || command {
            return .send
        }
        return .newline
    }
}

enum MessageEditInputPolicy {
    nonisolated static let sendsWithReturn = true

    nonisolated static func submission(from text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    nonisolated static func returnAction(
        shift: Bool,
        command: Bool,
        hasMarkedText: Bool
    ) -> ComposerReturnAction {
        ComposerReturnAction.decide(
            sendWithReturn: sendsWithReturn,
            shift: shift,
            command: command,
            hasMarkedText: hasMarkedText
        )
    }
}
