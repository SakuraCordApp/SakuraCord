import Foundation
import SakuraCordModels

extension MockMessageFixtureBuilder {
    func showcaseSystemMessages() -> [Message] {
        let types: [(DiscordMessageType, String)] = [
            (.recipientAdd, ""), (.recipientRemove, ""),
            (.channelNameChange, "Design crew"), (.channelIconChange, ""),
            (.channelPinnedMessage, ""), (.userJoin, ""),
            (.guildBoost, ""), (.guildBoostTier1, ""), (.guildBoostTier2, ""), (.guildBoostTier3, ""),
            (.channelFollowAdd, ""), (.threadCreated, "Rich message feedback"),
            (.guildInviteReminder, ""), (.stageStart, ""), (.stageEnd, ""),
            (.stageSpeaker, ""), (.stageTopic, "Native app design"),
            (.friendRequestAccepted, "Hello! Looking forward to comparing notes."),
        ]
        var result = [showcaseMessage(600, content: "# System messages and calls")]
        result += types.enumerated().map { index, sample in
            showcaseMessage(UInt64(601 + index), author: index.isMultiple(of: 2) ? rowan : nova, content: sample.1) {
                $0.type = sample.0
                $0.mentionedUsers = [theo]
                if sample.0 == .channelPinnedMessage {
                    $0.messageReference = .init(type: .reply, messageID: MessageID(rawValue: 600_501), channelID: $0.channelID, guildID: auroraID)
                }
                if sample.0 == .threadCreated { $0.thread = showcaseThread }
            }
        }
        result += [
            showcaseMessage(625, author: theo) { $0.type = .call; $0.call = MessageCall(participantIDs: [theo.id]) },
            showcaseMessage(626, author: nova) {
                $0.type = .call
                $0.call = MessageCall(participantIDs: [nova.id, maya.id], endedAt: $0.timestamp.addingTimeInterval(125))
            },
            showcaseMessage(627, author: theo) {
                $0.type = .call
                $0.call = MessageCall(participantIDs: [theo.id], endedAt: $0.timestamp.addingTimeInterval(32))
            },
        ]
        return result
    }

    func showcasePolls() -> [Message] {
        let answers = [
            PollAnswer(id: 1, text: "Mountains", emoji: EmojiReference(name: "🏔️")),
            PollAnswer(id: 2, text: "Coast", emoji: EmojiReference(name: "🌊")),
            PollAnswer(id: 3, text: "City walk", emoji: EmojiReference(name: "🏙️")),
        ]
        return [
            showcaseMessage(550, content: "# Polls"),
            showcaseMessage(551) {
                $0.poll = MessagePoll(question: "Where should we go?", answers: answers, expiry: now.addingTimeInterval(86_400), results: PollResults())
                $0.hasPoll = true
            },
            showcaseMessage(552, author: nova) {
                $0.poll = MessagePoll(question: "Choose every place you like", answers: answers, expiry: now.addingTimeInterval(3_600), allowsMultipleAnswers: true,
                                     results: PollResults(answerCounts: [.init(id: 1, count: 5, meVoted: true), .init(id: 2, count: 3), .init(id: 3, count: 2, meVoted: true)]))
                $0.hasPoll = true
            },
            showcaseMessage(553) {
                $0.poll = MessagePoll(question: "The final plan", answers: answers, expiry: now.addingTimeInterval(-60),
                                     results: PollResults(isFinalized: true, answerCounts: [.init(id: 1, count: 8), .init(id: 2, count: 3), .init(id: 3, count: 1)]))
                $0.hasPoll = true
            },
            showcaseMessage(554) {
                $0.type = .pollResult
                $0.messageReference = .init(type: .reply, messageID: MessageID(rawValue: 600_553), channelID: $0.channelID, guildID: auroraID)
                $0.embeds = [MessageEmbed(id: "showcase-poll-result", type: "poll_result", fields: [
                    .init(name: "poll_question_text", value: "The final plan"),
                    .init(name: "victor_answer_text", value: "Mountains"),
                    .init(name: "victor_answer_votes", value: "8"),
                    .init(name: "total_votes", value: "12"),
                ])]
            },
        ]
    }
}
