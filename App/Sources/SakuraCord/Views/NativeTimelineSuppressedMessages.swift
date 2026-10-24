import AppKit
import SakuraCordModels

/// A run of consecutive blocked or ignored messages. The header owns the run's
/// day and unread separators in both states, so revealing it only adds rows.
nonisolated struct SuppressedMessageGroup: Equatable {
    let messageIDs: [MessageID]
    let reason: UserContentSuppression
    let isRevealed: Bool
    let day: Date?
    let isUnreadBoundary: Bool
    let contextTitle: String?

    var id: MessageID { messageIDs[0] }
    var label: String { reason.countLabel(messageIDs.count) }
    var actionTitle: String { isRevealed ? "Hide" : "Show" }
}

/// The header reads like a system message: a symbol in the avatar column,
/// secondary copy, and an emphasized action that underlines on hover.
nonisolated struct NativeTimelineSuppressedHeaderLayout: Equatable {
    static var contentHeight: CGFloat { InterfaceScale.metric(28) }
    static let fontSize: CGFloat = 13

    /// Full width, like every other timeline highlight.
    let highlightFrame: CGRect
    let iconFrame: CGRect
    let textFrame: CGRect
    let toggleFrame: CGRect

    static func make(group: SuppressedMessageGroup, width: CGFloat, originY: CGFloat) -> Self {
        let lineHeight = MessageRowLayoutMetrics.compactContentHeight
        let lineY = originY + (contentHeight - lineHeight) / 2
        let horizontalInset = group.contextTitle == nil ? MessageRowLayoutMetrics.horizontalInset : 22
        let textX = horizontalInset + MessageRowLayoutMetrics.avatarDiameter + InterfaceScale.metric(20)
        let textWidth = max(0, width - textX - horizontalInset)
        let prefixWidth = ceil(prefix(for: group).size().width)
        let toggleWidth = ceil(toggle(for: group, isHovered: false).size().width)
        let visiblePrefixWidth = min(prefixWidth, max(0, textWidth - toggleWidth))
        let labelWidth = prefixWidth <= visiblePrefixWidth ? prefixWidth : max(0, visiblePrefixWidth - InterfaceScale.metric(4))
        return Self(
            highlightFrame: CGRect(x: 0, y: originY, width: width, height: contentHeight),
            iconFrame: CGRect(
                x: horizontalInset + InterfaceScale.metric(36), y: lineY,
                width: InterfaceScale.metric(16), height: lineHeight
            ),
            textFrame: CGRect(x: textX, y: lineY, width: labelWidth, height: lineHeight),
            toggleFrame: CGRect(
                x: textX + visiblePrefixWidth, y: lineY - InterfaceScale.metric(2),
                width: toggleWidth, height: lineHeight + InterfaceScale.metric(4)
            )
        )
    }

    static func label(for group: SuppressedMessageGroup) -> NSAttributedString {
        let value = NSMutableAttributedString(attributedString: prefix(for: group))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        value.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: value.length))
        return value
    }

    private static func prefix(for group: SuppressedMessageGroup) -> NSAttributedString {
        let context = group.contextTitle.map { "\($0) · " } ?? ""
        return NSAttributedString(string: "\(context)\(group.label) — ", attributes: [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    static func toggle(for group: SuppressedMessageGroup, isHovered: Bool) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        if isHovered { attributes[.underlineStyle] = NativeTimelineLinkAppearance.hoverUnderlineStyle }
        return NSAttributedString(string: group.actionTitle, attributes: attributes)
    }
}

nonisolated extension NativeTimelineRowPainter {
    static func drawSuppressedHeader(
        _ group: SuppressedMessageGroup,
        layout: NativeTimelineSuppressedHeaderLayout,
        isToggleHovered: Bool
    ) {
        systemSymbol(group.reason.systemImage, in: layout.iconFrame, color: .secondaryLabelColor, inset: 1)
        NativeTimelineSuppressedHeaderLayout.label(for: group)
            .draw(in: layout.textFrame)
        NativeTimelineSuppressedHeaderLayout.toggle(for: group, isHovered: isToggleHovered)
            .draw(in: layout.toggleFrame.insetBy(dx: 0, dy: InterfaceScale.metric(2)))
    }

    /// One area spans a header and its revealed rows, in the timeline's
    /// striped highlight style with a neutral tint.
    static func drawSuppressedHighlight(_ frame: CGRect) {
        guard frame.height > 0 else { return }
        drawStripedHighlight(in: frame, color: .secondaryLabelColor, backgroundAlpha: 0.07)
    }
}

extension NativeMessageTimelineCoordinator {
    func messageItems(_ rows: [MessageRowPresentation], from parent: NativeMessageTimelineView) -> [NativeMessageTimelineItem] {
        let model = parent.model
        let state = model.ignoredUsers
        var result: [NativeMessageTimelineItem] = []
        result.reserveCapacity(rows.count)
        var index = 0
        while index < rows.count {
            let row = rows[index]
            guard let reason = model.messageSuppressionReason(row.message) else {
                result.append(messageItem(protectSuppressedReply(row, model: model), from: parent))
                index += 1
                continue
            }
            let isRevealed = state.revealedMessageIDs.contains(row.id)
            let isCollapsing = state.collapsingMessageIDs.contains(row.id)
            var end = index + 1
            while end < rows.count, !rows[end].startsDay,
                  rows[end].id != parent.unreadMessageID,
                  rows[end].message.channelID == row.message.channelID,
                  model.messageSuppressionReason(rows[end].message) == reason,
                  state.collapsingMessageIDs.contains(rows[end].id) == isCollapsing,
                  state.revealedMessageIDs.contains(rows[end].id) == isRevealed { end += 1 }
            let run = rows[index ..< end]
            let ids = run.map(\.id)
            // Resolves the conversation's first-row day override.
            let startsDay = messageItem(row, from: parent).messageRow?.startsDay ?? row.startsDay
            result.append(.suppressedMessages(.init(
                messageIDs: ids, reason: reason, isRevealed: isRevealed,
                day: startsDay ? row.message.timestamp : nil,
                isUnreadBoundary: parent.unreadMessageID == row.id,
                contextTitle: row.searchContext?.sectionTitle
            )))
            // A closing run keeps its rows until the motion ends.
            if isRevealed || isCollapsing {
                for (offset, row) in run.enumerated() {
                    result.append(revealedItem(
                        row, startsRun: offset == 0, endsRun: offset == run.count - 1, from: parent
                    ))
                }
            }
            index = end
        }
        return result
    }

    /// Revealed rows sit inside the header's area, so they start and end their
    /// own groups and leave separators to the header.
    private func revealedItem(
        _ row: MessageRowPresentation,
        startsRun: Bool,
        endsRun: Bool,
        from parent: NativeMessageTimelineView
    ) -> NativeMessageTimelineItem {
        let protected = protectSuppressedReply(row, model: parent.model)
        return .message(
            protected.adjusted(
                startsGroup: startsRun || protected.startsGroup,
                endsGroup: endsRun || protected.endsGroup,
                startsDay: false
            ),
            isUnreadBoundary: false,
            isHighlighted: parent.selectedMessageID == row.id
        )
    }

    private func protectSuppressedReply(_ row: MessageRowPresentation, model: AppModel) -> MessageRowPresentation {
        guard var preview = row.replyPreview,
              let reason = model.userSuppressionReason(preview.author.id) else { return row }
        preview.content = reason.replyPlaceholder
        preview.mediaKind = nil
        return row.adjusted(replyPreview: preview)
    }
}

extension MessageRowPresentation {
    func adjusted(
        startsGroup: Bool? = nil,
        endsGroup: Bool? = nil,
        startsDay: Bool? = nil,
        replyPreview: MessageReplyPreview? = nil
    ) -> MessageRowPresentation {
        let startsGroup = startsGroup ?? self.startsGroup
        let endsGroup = endsGroup ?? self.endsGroup
        let startsDay = startsDay ?? self.startsDay
        guard startsGroup != self.startsGroup || endsGroup != self.endsGroup
                || startsDay != self.startsDay || (replyPreview != nil && replyPreview != self.replyPreview)
        else { return self }
        return MessageRowPresentation(
            message: message, startsGroup: startsGroup, endsGroup: endsGroup,
            startsDay: startsDay, replyPreview: replyPreview ?? self.replyPreview, isReplyAvailable: isReplyAvailable,
            textPlan: textPlan, searchContext: searchContext,
            pinnedAt: pinnedAt, isResource: isResource
        )
    }
}
