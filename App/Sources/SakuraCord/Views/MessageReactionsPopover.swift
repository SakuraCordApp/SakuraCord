import AppKit
import SakuraCordModels
import SwiftUI

struct MessageReactionsPopover: View {
    let model: AppModel
    let message: Message
    let dismiss: () -> Void
    @State private var selectedReactionID: String?
    @State private var reactionSnapshot: [Reaction]?
    @State private var pager = MessagePeoplePager<String>()

    private var reactions: [Reaction] {
        reactionSnapshot ?? (model.retainedMessage(channelID: message.channelID, messageID: message.id) ?? message).reactions
    }

    private var selectedReaction: Reaction? {
        reactions.first { $0.id == selectedReactionID } ?? reactions.first
    }

    var body: some View {
        MessagePeoplePopover(
            model: model, message: message, selection: selectedReaction?.id, count: selectedReaction?.count,
            pager: pager, emptyTitle: "No Reactions", errorTitle: "Couldn't Load Reactions", systemImage: "face.smiling",
            sidebarWidth: 112, displayedUsers: displayedUsers,
            fetch: { provider, reactionID, after in
                guard let reaction = reactions.first(where: { $0.id == reactionID }) else { throw CancellationError() }
                return try await provider.reactionUsers(for: reaction.emoji, messageID: message.id,
                                                        channelID: message.channelID, after: after, limit: 100)
            },
            header: {
                Text("Reactions").font(.interface(.headline))
            },
            categories: {
                ForEach(reactions) { reaction in
                    Button { selectedReactionID = reaction.id } label: {
                        HStack(spacing: InterfaceScale.metric(10)) {
                            MessageReactionEmoji(
                                reaction: reaction,
                                url: MessageReactionPresentation.emojiURL(for: reaction, customEmojiURLsByID: model.customEmojiURLsByID),
                                size: InterfaceScale.metric(24)
                            )
                            Text(String(reaction.count)).font(.interface(.callout).weight(.medium)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(InterfaceScale.metric(10)).frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PopoverRowButtonStyle(isSelected: selectedReaction?.id == reaction.id))
                    .accessibilityLabel("\(MessageReactionPresentation.emojiName(for: reaction)), \(reaction.count) reactions")
                    .accessibilityAddTraits(selectedReaction?.id == reaction.id ? .isSelected : [])
                }
            }
        )
        .onReceive(NotificationCenter.default.publisher(for: .sakuracordMessageRowsDidChange, object: model)) { _ in refreshReactions() }
        .onReceive(NotificationCenter.default.publisher(for: .sakuracordMessageReactionDidChange, object: model)) { notification in
            guard let update = notification.userInfo?["update"] as? MessageReactionUpdate,
                  update.messageID == message.id, update.channelID == message.channelID else { return }
            if let id = update.reactionID { pager.invalidate(id) } else { pager.reset() }
            refreshReactions()
        }
        .onChange(of: model.currentUser?.id) { _, _ in dismiss() }
    }

    private func refreshReactions() {
        guard let current = model.retainedMessage(channelID: message.channelID, messageID: message.id) else {
            dismiss()
            return
        }
        reactionSnapshot = current.reactions
        if !reactions.contains(where: { $0.id == selectedReactionID }) { selectedReactionID = reactions.first?.id }
    }

    private func displayedUsers(_ users: [User]) -> [User] {
        guard let reaction = selectedReaction, let me = model.currentUser else { return users }
        let others = users.filter { $0.id != me.id }
        return reaction.didCurrentUserReact || reaction.didCurrentUserBurstReact ? [me] + others : others
    }
}

extension NativeTimelineCanvasView {
    @discardableResult
    func showMessageReactions(_ message: Message) -> Bool {
        guard let model, window != nil,
              let anchor = messageReactionPopoverAnchor(for: message) else { return false }
        reactionDetailsPopover?.close()
        reactionDetailsMessageID = message.id
        reactionDetailsPopover = presentMessagePeoplePopover(relativeTo: anchor, followsTimelineScroll: true) { popover in
            MessageReactionsPopover(model: model, message: message, dismiss: { [weak popover] in popover?.close() })
        }
        return reactionDetailsPopover?.isShown == true
    }
}
