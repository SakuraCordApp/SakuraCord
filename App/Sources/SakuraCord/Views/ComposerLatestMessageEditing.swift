import AppKit
import SakuraCordModels

nonisolated enum ComposerLatestMessageEditingPolicy {
    static func shouldRequest(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        composerIsEmpty: Bool
    ) -> Bool {
        let disallowed: NSEvent.ModifierFlags = [
            .shift, .command, .option, .control,
        ]
        return keyCode == 126
            && modifierFlags.isDisjoint(with: disallowed)
            && composerIsEmpty
    }

    static func messageID(
        in messages: [Message],
        currentUserID: UserID?
    ) -> MessageID? {
        guard let currentUserID else { return nil }
        return messages.last(where: {
            $0.author.id == currentUserID && !$0.hasPoll && !$0.flags.contains(.voiceMessage)
        })?.id
    }
}

extension ComposerView {
    func editLatestMessage() -> Bool {
        let messages = model.messages(in: conversation)
        guard let messageID = ComposerLatestMessageEditingPolicy.messageID(
            in: messages,
            currentUserID: model.currentUser?.id
        ) else { return false }
        onEditMessage(messageID)
        return true
    }
}
