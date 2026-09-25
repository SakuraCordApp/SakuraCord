import AppKit

enum NativeTimelineCompactTimestampMetrics {
    static var font: NSFont {
        .preferredFont(forTextStyle: .caption2)
    }

    private static var cachedWidth: (key: String, width: CGFloat)?

    static func width(settings: InterfaceSettingsSnapshot) -> CGFloat {
        let locale = Locale.autoupdatingCurrent
        let key = "\(locale.identifier):\(locale.hourCycle):\(settings.timestampFormat):\(settings.includesTimestampSeconds):\(font.pointSize)"
        if let cachedWidth, cachedWidth.key == key { return cachedWidth.width }
        // Measure every hour once, so changing digit counts and day periods
        // never shift the message column between rows or clip hovered times.
        let width = (0 ..< 24).map { hour in
            let text = InterfaceTimestampFormatter.text(
                for: Date(timeIntervalSince1970: Double(hour * 3600 + 59 * 60 + 59)),
                format: settings.timestampFormat,
                includesSeconds: settings.includesTimestampSeconds,
                locale: locale,
                timeZone: TimeZone(secondsFromGMT: 0)!
            )
            return (text as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        cachedWidth = (key, ceil(width))
        return ceil(width)
    }
}

nonisolated enum NativeTimelineMessageMenuAction: Equatable {
    case jumpToMessage
    case retrySending
    case addReaction
    case reply
    case forward
    case markUnread
    case dismissInboxMention
    case endPoll
    case toggleTranslation
    case editMessage
    case pinMessage
    case unpinMessage
    case copyText
    case copyLink
    case copyMessageID
    case copyAuthorID
    case deleteMessage
    case discardFailedMessage
}

nonisolated enum NativeTimelineSearchResultPresentation {
    static let jumpToMessageSystemImage = "arrow.forward.to.line"
}

nonisolated enum NativeTimelineMessageMenuEntry: Equatable {
    case action(
        NativeTimelineMessageMenuAction,
        title: String,
        systemImage: String,
        isDestructive: Bool = false
    )
    case separator
}

nonisolated enum NativeTimelineMessageMenuPolicy {
    static func entries(
        canEdit: Bool,
        canDelete: Bool,
        canRetry: Bool,
        canReply: Bool,
        canEndPoll: Bool = false,
        canForward: Bool = false,
        canPin: Bool = false,
        isPinned: Bool = false,
        translationTitle: String? = nil,
        context: NativeTimelineMessageInteractionContext = .conversation
    ) -> [NativeTimelineMessageMenuEntry] {
        if context == .searchResult {
            return resultEntries(
                canDelete: canDelete,
                canPin: canPin,
                isPinned: isPinned,
                includesMarkUnread: true
            )
        }
        if context == .inboxResult || context == .inboxMention {
            var result = resultEntries(canDelete: canDelete, canPin: canPin, isPinned: isPinned, includesMarkUnread: false)
            if context == .inboxMention {
                result.insert(.action(.dismissInboxMention, title: "Mark as Read", systemImage: "envelope.open"), at: 1)
            }
            return result
        }
        if context == .pinnedResult {
            return resultEntries(
                canDelete: canDelete,
                canPin: canPin,
                isPinned: true,
                includesMarkUnread: false
            )
        }

        var entries = conversationEntries(
            canEdit: canEdit,
            canDelete: canDelete,
            canRetry: canRetry,
            canReply: canReply,
            canForward: canForward,
            canPin: canPin,
            isPinned: isPinned
        )
        if canEndPoll {
            entries.insert(.action(.endPoll, title: "End Poll Now", systemImage: "stop.circle"), at: min(3, entries.count))
        }
        if let translationTitle, !canRetry {
            entries.insert(
                .action(.toggleTranslation, title: translationTitle, systemImage: "translate"),
                at: entries.firstIndex(of: .separator) ?? entries.count
            )
        }
        return entries
    }

    private static func conversationEntries(
        canEdit: Bool,
        canDelete: Bool,
        canRetry: Bool,
        canReply: Bool,
        canForward: Bool,
        canPin: Bool,
        isPinned: Bool
    ) -> [NativeTimelineMessageMenuEntry] {
        if canRetry {
            return [
                .action(
                    .retrySending,
                    title: "Retry Send",
                    systemImage: "arrow.clockwise"
                ),
                .separator,
                .action(
                    .copyText,
                    title: "Copy Text",
                    systemImage: "doc.on.doc"
                ),
                .separator,
                .action(
                    .discardFailedMessage,
                    title: "Delete Message…",
                    systemImage: "trash",
                    isDestructive: true
                ),
            ]
        }

        var result: [NativeTimelineMessageMenuEntry] = []
        result.append(.action(
            .addReaction,
            title: "Add Reaction",
            systemImage: SakuraCordSystemSymbol.emojiFaceGrinning
        ))
        if canReply {
            result.append(.action(
                .reply,
                title: "Reply",
                systemImage: "arrowshape.turn.up.left"
            ))
        }
        if canForward {
            result.append(.action(
                .forward,
                title: "Forward",
                systemImage: "arrowshape.turn.up.right"
            ))
        }
        if canEdit {
            result.append(.action(
                .editMessage,
                title: "Edit Message",
                systemImage: "pencil"
            ))
        }
        if canPin {
            result.append(.action(
                isPinned ? .unpinMessage : .pinMessage,
                title: isPinned ? "Unpin Message" : "Pin Message",
                systemImage: isPinned ? "pin.slash" : "pin"
            ))
        }
        result.append(.action(
            .markUnread,
            title: "Mark Unread",
            systemImage: "envelope.badge"
        ))
        result.append(.separator)
        result.append(.action(
            .copyText,
            title: "Copy Text",
            systemImage: "doc.on.doc"
        ))
        result.append(.action(
            .copyLink,
            title: "Copy Link",
            systemImage: "link"
        ))
        result.append(.action(
            .copyMessageID,
            title: "Copy Message ID",
            systemImage: "number.square.fill"
        ))
        if canDelete {
            result.append(.separator)
            result.append(.action(
                .deleteMessage,
                title: "Delete Message…",
                systemImage: "trash",
                isDestructive: true
            ))
        }
        return result
    }

    private static func resultEntries(
        canDelete: Bool,
        canPin: Bool,
        isPinned: Bool,
        includesMarkUnread: Bool
    ) -> [NativeTimelineMessageMenuEntry] {
        var result: [NativeTimelineMessageMenuEntry] = [
            .action(
                .jumpToMessage,
                title: "Jump to Message",
                systemImage: NativeTimelineSearchResultPresentation
                    .jumpToMessageSystemImage
            ),
        ]
        if includesMarkUnread {
            result.append(.action(
                .markUnread,
                title: "Mark Unread",
                systemImage: "envelope.badge"
            ))
        }
        if canPin {
            result.append(.action(
                isPinned ? .unpinMessage : .pinMessage,
                title: isPinned ? "Unpin Message" : "Pin Message",
                systemImage: isPinned ? "pin.slash" : "pin"
            ))
        }
        result.append(.separator)
        result.append(contentsOf: [
            .action(
                .copyText,
                title: "Copy Text",
                systemImage: "doc.on.doc"
            ),
            .action(
                .copyLink,
                title: "Copy Link",
                systemImage: "link"
            ),
            .action(
                .copyMessageID,
                title: "Copy Message ID",
                systemImage: "number.square.fill"
            ),
            .action(
                .copyAuthorID,
                title: "Copy Message Author ID",
                systemImage: "number.square.fill"
            ),
        ])
        if canDelete {
            result.append(contentsOf: [
                .separator,
                .action(
                    .deleteMessage,
                    title: "Delete Message…",
                    systemImage: "trash",
                    isDestructive: true
                ),
            ])
        }
        return result
    }
}
