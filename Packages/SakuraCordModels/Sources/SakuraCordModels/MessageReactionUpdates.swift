import Foundation

public extension Message {
    /// Carries already-resolved reactor identities across a replacement message
    /// payload without changing the incoming reaction counts or selected state.
    func preservingReactionReactors(from previous: Message) -> Message {
        guard id == previous.id, channelID == previous.channelID else { return self }
        var result = self
        for index in result.reactions.indices {
            guard let previousReaction = previous.reactions.first(where: {
                $0.id == result.reactions[index].id
            }) else {
                continue
            }
            var seen = Set<UserID>()
            result.reactions[index].reactors = Array(
                (result.reactions[index].reactors + previousReaction.reactors)
                    .filter { seen.insert($0.id).inserted }
                    .prefix(min(5, max(0, result.reactions[index].count)))
            )
        }
        return result
    }

    /// Applies one Gateway reaction delta. Current-user add/remove echoes are
    /// state assignments, so they remain idempotent when an optimistic REST
    /// update has already reached the message.
    @discardableResult
    mutating func applyReactionUpdate(
        _ update: MessageReactionUpdate,
        currentUserID: UserID?,
        reactor: ReactionReactor? = nil
    ) -> Bool {
        guard update.channelID == channelID, update.messageID == id else { return false }

        switch update {
        case .add(_, _, let userID, let emoji, let kind):
            return applyReactionAddition(
                userID: userID,
                emoji: emoji,
                kind: kind,
                currentUserID: currentUserID,
                reactor: reactor
            )
        case .remove(_, _, let userID, let emoji, let kind):
            return applyReactionRemoval(
                userID: userID,
                emoji: emoji,
                kind: kind,
                currentUserID: currentUserID
            )
        case .removeAll:
            guard !reactions.isEmpty else { return false }
            reactions.removeAll()
        case .removeEmoji(_, _, let emoji):
            let identity = Reaction(emoji: emoji, count: 0).id
            let originalCount = reactions.count
            reactions.removeAll { $0.id == identity }
            guard reactions.count != originalCount else { return false }
        }
        return true
    }

    private mutating func applyReactionAddition(
        userID: UserID,
        emoji: String,
        kind: MessageReactionKind,
        currentUserID: UserID?,
        reactor: ReactionReactor?
    ) -> Bool {
        let identity = Reaction(emoji: emoji, count: 0).id
        guard let index = reactions.firstIndex(where: { $0.id == identity }) else {
            reactions.append(
                Reaction(
                    emoji: emoji,
                    count: 1,
                    didCurrentUserReact: userID == currentUserID && kind == .normal,
                    didCurrentUserBurstReact: userID == currentUserID && kind == .burst,
                    reactors: reactor.map { [$0] } ?? []
                )
            )
            return true
        }
        if userID == currentUserID {
            switch kind {
            case .normal:
                guard !reactions[index].didCurrentUserReact else { return false }
                reactions[index].didCurrentUserReact = true
            case .burst:
                guard !reactions[index].didCurrentUserBurstReact else { return false }
                reactions[index].didCurrentUserBurstReact = true
            }
        }
        reactions[index].emoji = emoji
        reactions[index].count += 1
        if let reactor,
           reactor.id == userID,
           !reactions[index].reactors.contains(where: { $0.id == reactor.id })
        {
            reactions[index].reactors.append(reactor)
        }
        return true
    }

    private mutating func applyReactionRemoval(
        userID: UserID,
        emoji: String,
        kind: MessageReactionKind,
        currentUserID: UserID?
    ) -> Bool {
        let identity = Reaction(emoji: emoji, count: 0).id
        guard let index = reactions.firstIndex(where: { $0.id == identity }) else {
            return false
        }
        if userID == currentUserID {
            switch kind {
            case .normal:
                guard reactions[index].didCurrentUserReact else { return false }
                reactions[index].didCurrentUserReact = false
            case .burst:
                guard reactions[index].didCurrentUserBurstReact else { return false }
                reactions[index].didCurrentUserBurstReact = false
            }
        }
        reactions[index].count = max(0, reactions[index].count - 1)
        reactions[index].reactors.removeAll { $0.id == userID }
        if reactions[index].reactors.count > reactions[index].count {
            reactions[index].reactors = Array(
                reactions[index].reactors.prefix(reactions[index].count)
            )
        }
        if reactions[index].count == 0 {
            reactions.remove(at: index)
        }
        return true
    }
}
