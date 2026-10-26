import SakuraCordModels
import SwiftUI

struct PollVotersView: View {
    let model: AppModel
    let message: Message
    let dismiss: () -> Void
    @State private var selectedAnswerID: Int
    @State private var pager = MessagePeoplePager<Int>()
    @State private var pollSnapshot: MessagePoll?

    init(model: AppModel, message: Message, initialAnswerID: Int, dismiss: @escaping () -> Void) {
        self.model = model
        self.message = message
        self.dismiss = dismiss
        _selectedAnswerID = State(initialValue: initialAnswerID)
    }

    private var poll: MessagePoll? {
        pollSnapshot ?? model.retainedMessage(channelID: message.channelID, messageID: message.id)?.poll ?? message.poll
    }

    var body: some View {
        MessagePeoplePopover(
            model: model, message: message, selection: selectedAnswerID, count: count,
            pager: pager, emptyTitle: "No Votes", errorTitle: "Couldn't Load Voters", systemImage: "chart.bar",
            displayedUsers: displayedUsers,
            fetch: { provider, answerID, after in
                try await provider.pollVoters(messageID: message.id, channelID: message.channelID,
                                              answerID: answerID, after: after, limit: 100)
            },
            header: {
                VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                    Text(poll?.question ?? "Poll").font(.interface(.headline)).lineLimit(2)
                    if let poll {
                        Text(summary(poll)).font(.interface(.callout)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            },
            categories: {
                if let poll {
                    ForEach(poll.answers) { answer in
                        Button { selectedAnswerID = answer.id } label: { PollVotersAnswerRow(answer: answer, poll: poll) }
                            .buttonStyle(PopoverRowButtonStyle(isSelected: selectedAnswerID == answer.id))
                            .accessibilityAddTraits(selectedAnswerID == answer.id ? .isSelected : [])
                    }
                }
            }
        )
        .onReceive(NotificationCenter.default.publisher(for: .sakuracordMessageRowsDidChange, object: model)) { _ in
            pollSnapshot = model.retainedMessage(channelID: message.channelID, messageID: message.id)?.poll
        }
        .onChange(of: model.currentUser?.id) { _, _ in dismiss() }
    }

    /// The current user's pending vote is shown before Discord lists it.
    private func displayedUsers(_ users: [User]) -> [User] {
        guard let poll, poll.results != nil, let me = model.currentUser else { return users }
        let others = users.filter { $0.id != me.id }
        return poll.selectedAnswerIDs.contains(selectedAnswerID) ? [me] + others : others
    }

    private func summary(_ poll: MessagePoll) -> String {
        let votes = poll.results == nil ? "Votes unavailable" : poll.totalVotes == 1 ? "1 vote" : "\(poll.totalVotes) votes"
        if poll.isClosed() { return "\(votes) · Final results" }
        guard let expiry = poll.expiry else { return votes }
        return "\(votes) · Ends \(expiry.formatted(.relative(presentation: .named)))"
    }

    private var count: Int? {
        guard let poll, poll.results != nil else { return nil }
        return poll.count(for: selectedAnswerID)
    }
}

private struct PollVotersAnswerRow: View {
    let answer: PollAnswer
    let poll: MessagePoll

    var body: some View {
        let count = poll.count(for: answer.id)
        let fraction = poll.totalVotes > 0 ? Double(count) / Double(poll.totalVotes) : 0
        let voted = poll.selectedAnswerIDs.contains(answer.id)
        HStack(spacing: InterfaceScale.metric(10)) {
            if let emoji = answer.emoji { PollAnswerEmoji(emoji: emoji, size: InterfaceScale.metric(20)) }
            VStack(alignment: .leading, spacing: InterfaceScale.metric(6)) {
                HStack(alignment: .firstTextBaseline, spacing: InterfaceScale.metric(6)) {
                    Text(answer.text).font(.interface(.callout).weight(.medium)).lineLimit(2)
                    if voted {
                        Image(systemName: "checkmark.circle.fill").font(.interface(.caption))
                            .foregroundStyle(SakuraCordAccentColor.color)
                            .accessibilityLabel("You voted")
                    }
                    Spacer(minLength: InterfaceScale.metric(4))
                    Text(poll.results == nil ? "—" : "\(count)").font(.interface(.callout).weight(.semibold)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Capsule().fill(.quaternary).frame(height: InterfaceScale.metric(4)).overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        Capsule().fill(voted ? SakuraCordAccentColor.color : .secondary)
                            .frame(width: geometry.size.width * fraction)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, InterfaceScale.metric(10)).padding(.vertical, InterfaceScale.metric(9))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(ConcentricRectangle(cornerRadius: InterfaceScale.metric(16)))
        .animation(.snappy, value: fraction)
        .accessibilityElement(children: .combine)
        .accessibilityValue(poll.results == nil ? "Votes unavailable" : count == 1 ? "1 vote" : "\(count) votes")
    }
}

/// A poll answer's custom or Unicode emoji.
struct PollAnswerEmoji: View {
    let emoji: EmojiReference
    let size: CGFloat

    var body: some View {
        Group {
            if let url = emoji.imageURL(size: 64) {
                AnimatedRemoteImage(url: url, animates: false, contentMode: .fit, usesSwiftUIRendering: true)
            } else {
                // Color emoji ink is about 1.15× the point size and sits slightly
                // above the line box's center; this matches image emoji (measured).
                Text(emoji.name).font(.system(size: size * 0.85)).fixedSize().offset(y: size / 80)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
