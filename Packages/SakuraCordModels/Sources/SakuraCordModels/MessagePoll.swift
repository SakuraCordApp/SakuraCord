import Foundation

public struct PollAnswer: Identifiable, Codable, Hashable, Sendable {
    public var id: Int
    public var text: String
    public var emoji: EmojiReference?

    public init(id: Int, text: String, emoji: EmojiReference? = nil) {
        self.id = id
        self.text = text
        self.emoji = emoji
    }
}

public struct PollAnswerCount: Codable, Hashable, Sendable {
    public var id: Int
    public var count: Int
    public var meVoted: Bool

    public init(id: Int, count: Int, meVoted: Bool = false) {
        self.id = id
        self.count = max(0, count)
        self.meVoted = meVoted
    }
}

public struct PollResults: Codable, Hashable, Sendable {
    public var isFinalized: Bool
    public var answerCounts: [PollAnswerCount]

    public init(isFinalized: Bool = false, answerCounts: [PollAnswerCount] = []) {
        self.isFinalized = isFinalized
        self.answerCounts = answerCounts
    }
}

public struct MessagePoll: Codable, Hashable, Sendable {
    public var question: String
    public var answers: [PollAnswer]
    public var expiry: Date?
    public var allowsMultipleAnswers: Bool
    public var layoutType: Int
    public var results: PollResults?

    public init(
        question: String, answers: [PollAnswer], expiry: Date?,
        allowsMultipleAnswers: Bool = false, layoutType: Int = 1, results: PollResults? = nil
    ) {
        self.question = question
        self.answers = answers
        self.expiry = expiry
        self.allowsMultipleAnswers = allowsMultipleAnswers
        self.layoutType = layoutType
        self.results = results
    }

    public var totalVotes: Int { results?.answerCounts.reduce(0) { $0 + $1.count } ?? 0 }
    public var selectedAnswerIDs: Set<Int> { Set(results?.answerCounts.filter(\.meVoted).map(\.id) ?? []) }
    public func count(for answerID: Int) -> Int { results?.answerCounts.first { $0.id == answerID }?.count ?? 0 }
    public func isClosed(at date: Date = .now) -> Bool { results?.isFinalized == true || expiry.map { $0 <= date } == true }

    /// Gateway finalization is broadcast, so its `me_voted` values are not personalized.
    /// Omitted results mean unknown, and must not erase an already known tally.
    public mutating func merge(_ incoming: Self, preservingSelection: Bool = false) {
        let previous = results
        self = incoming
        if incoming.results == nil || (previous?.isFinalized == true && incoming.results?.isFinalized != true) {
            results = previous
        } else if preservingSelection, incoming.results?.isFinalized == true, let previous {
            let selected = Set(previous.answerCounts.filter(\.meVoted).map(\.id))
            if var tally = results {
                for index in tally.answerCounts.indices {
                    tally.answerCounts[index].meVoted = selected.contains(tally.answerCounts[index].id)
                }
                results = tally
            }
        }
    }

    public mutating func applyVote(answerID: Int, isAddition: Bool, isCurrentUser: Bool) {
        guard results?.isFinalized != true, answers.contains(where: { $0.id == answerID }) else { return }
        guard var tally = results else { return }
        if let index = tally.answerCounts.firstIndex(where: { $0.id == answerID }) {
            if isCurrentUser, tally.answerCounts[index].meVoted == isAddition { return }
            tally.answerCounts[index].count = max(0, tally.answerCounts[index].count + (isAddition ? 1 : -1))
            if isCurrentUser { tally.answerCounts[index].meVoted = isAddition }
        } else if isAddition {
            tally.answerCounts.append(PollAnswerCount(id: answerID, count: 1, meVoted: isCurrentUser))
        }
        results = tally
    }
}

/// Ordered operations also reconcile messages retained outside the provider's bounded cache.
public enum MessagePollUpdate: Equatable, Sendable {
    case snapshot(MessagePoll, preservingSelection: Bool)
    case vote(answerID: Int, isAddition: Bool, isCurrentUser: Bool)

    /// The current user's vote operations that replace `selected` with `target`.
    public static func currentUserSelection(from selected: Set<Int>, to target: Set<Int>) -> [Self] {
        selected.subtracting(target).sorted().map { .vote(answerID: $0, isAddition: false, isCurrentUser: true) }
            + target.subtracting(selected).sorted().map { .vote(answerID: $0, isAddition: true, isCurrentUser: true) }
    }

    public func apply(to message: inout Message) {
        switch self {
        case .snapshot(let incoming, let preservingSelection):
            if message.poll == nil { message.poll = incoming } else { message.poll?.merge(incoming, preservingSelection: preservingSelection) }
            message.hasPoll = true
        case .vote(let answerID, let isAddition, let isCurrentUser):
            message.poll?.applyVote(answerID: answerID, isAddition: isAddition, isCurrentUser: isCurrentUser)
        }
    }
}

public struct PollDraft: Equatable, Sendable {
    public static let durations = [1, 4, 8, 24, 72, 168, 336]
    public var question: String
    public var answers: [PollAnswer]
    public var durationHours: Int
    public var allowsMultipleAnswers: Bool

    public init(question: String = "", answers: [PollAnswer] = [.init(id: 1, text: ""), .init(id: 2, text: "")], durationHours: Int = 24, allowsMultipleAnswers: Bool = false) {
        self.question = question
        self.answers = answers
        self.durationHours = durationHours
        self.allowsMultipleAnswers = allowsMultipleAnswers
    }

    public var submittedAnswers: [PollAnswer] {
        answers.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public var validationError: String? {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.utf16.count <= 300 else { return "Enter a question of up to 300 characters." }
        guard (1 ... 10).contains(submittedAnswers.count), answers.count <= 10 else { return "Add up to 10 answers." }
        guard answers.allSatisfy({
            let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (!text.isEmpty || $0.emoji == nil) && text.utf16.count <= 55
        }) else { return "Each answer needs text of up to 55 characters." }
        guard Self.durations.contains(durationHours) else { return "Choose a poll duration." }
        return nil
    }

    public func preview(at date: Date = .now) -> MessagePoll {
        MessagePoll(question: question.trimmingCharacters(in: .whitespacesAndNewlines), answers: submittedAnswers.enumerated().map {
                        .init(id: $0.offset + 1, text: $0.element.text.trimmingCharacters(in: .whitespacesAndNewlines), emoji: $0.element.emoji)
                    },
                    expiry: date.addingTimeInterval(Double(durationHours) * 3600),
                    allowsMultipleAnswers: allowsMultipleAnswers, results: PollResults())
    }
}

public struct PollResultSummary: Equatable, Sendable {
    public var question: String
    public var winner: String?
    public var winnerVotes: Int
    public var totalVotes: Int
}

public extension Message {
    var pollResultSummary: PollResultSummary? {
        guard type == .pollResult, let embed = embeds.first(where: { $0.type == "poll_result" }) else { return nil }
        func field(_ name: String) -> String? { embed.fields.first { $0.name == name }?.value }
        return PollResultSummary(question: field("poll_question_text") ?? "Poll",
                                 winner: field("victor_answer_text"),
                                 winnerVotes: Int(field("victor_answer_votes") ?? "") ?? 0,
                                 totalVotes: Int(field("total_votes") ?? "") ?? 0)
    }
}
