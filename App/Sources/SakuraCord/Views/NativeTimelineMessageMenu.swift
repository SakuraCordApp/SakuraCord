import AppKit
import SakuraCordModels

nonisolated enum NativeTimelineMessageMenuAction: Equatable {
    case jumpToMessage
    case retrySending
    case addReaction
    case viewReactions
    case reply
    case forward
    case createThread
    case viewThread
    case markUnread
    case dismissInboxMention
    case endPoll
    case copyTranslation
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
        isFailed: Bool = false,
        canReply: Bool,
        canEndPoll: Bool = false,
        canForward: Bool = false,
        threadAction: NativeTimelineMessageMenuAction? = nil,
        canPin: Bool = false,
        isPinned: Bool = false,
        translationTitle: String? = nil,
        canCopyTranslation: Bool = false,
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

        var entries = canRetry || isFailed ? failedEntries(canRetry: canRetry) : conversationEntries(
            canEdit: canEdit,
            canDelete: canDelete,
            canReply: canReply,
            canForward: canForward,
            threadAction: threadAction,
            canPin: canPin,
            isPinned: isPinned
        )
        if canEndPoll {
            entries.insert(.action(.endPoll, title: "End Poll Now", systemImage: "stop.circle"), at: min(3, entries.count))
        }
        if let translationTitle, !canRetry, !isFailed {
            entries.insert(
                .action(.toggleTranslation, title: translationTitle, systemImage: "translate"),
                at: messageActionsEnd(in: entries)
            )
        }
        if canCopyTranslation {
            entries.insert(.action(.copyTranslation, title: "Copy Translation", systemImage: "doc.on.doc"),
                           at: messageActionsEnd(in: entries))
        }
        return entries
    }

    private static func messageActionsEnd(in entries: [NativeTimelineMessageMenuEntry]) -> Int {
        guard let copyIndex = entries.firstIndex(where: {
            if case .action(.copyText, _, _, _) = $0 { return true }
            return false
        }) else { return entries.count }
        return entries[..<copyIndex].lastIndex(of: .separator) ?? copyIndex
    }

    private static func failedEntries(canRetry: Bool) -> [NativeTimelineMessageMenuEntry] {
        var entries: [NativeTimelineMessageMenuEntry] = []
        if canRetry {
            entries.append(.action(
                .retrySending,
                title: "Retry Send",
                systemImage: "arrow.clockwise"
            ))
            entries.append(.separator)
        }
        entries += [
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
        return entries
    }

    private static func conversationEntries(
        canEdit: Bool,
        canDelete: Bool,
        canReply: Bool,
        canForward: Bool,
        threadAction: NativeTimelineMessageMenuAction?,
        canPin: Bool,
        isPinned: Bool
    ) -> [NativeTimelineMessageMenuEntry] {
        var result: [NativeTimelineMessageMenuEntry] = []
        result.append(.action(
            .addReaction,
            title: "Add Reaction",
            systemImage: "emoji.face.grinning.and.plus"
        ))
        result.append(.action(
            .viewReactions,
            title: "View Reactions",
            systemImage: SakuraCordSystemSymbol.emojiFaceGrinning
        ))
        result.append(.separator)
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
        // The first-party menu offers Create Thread after Forward; a message
        // that already has a thread opens it instead.
        switch threadAction {
        case .createThread?:
            result.append(.action(.createThread, title: "Create Thread", systemImage: SakuraCordSystemSymbol.thread))
        case .viewThread?:
            result.append(.action(.viewThread, title: "View Thread", systemImage: SakuraCordSystemSymbol.thread))
        default:
            break
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
            title: "Copy Message Link",
            systemImage: "link"
        ))
        result.append(.action(
            .copyMessageID,
            title: "Copy Message ID",
            systemImage: "number.sign"
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
                title: "Copy Message Link",
                systemImage: "link"
            ),
            .action(
                .copyMessageID,
                title: "Copy Message ID",
                systemImage: "number.sign"
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

extension NativeTimelineCanvasView {
    func actionItem(
        _ title: String,
        systemImage: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> NSMenuItem {
        ContextMenuItemSupport.item(title, systemImage: systemImage, isDestructive: isDestructive) { [weak self] in
            guard let self, !self.sendTransitionBlocksInteractions else { return }
            action()
        }
    }

    func requestDelete(_ message: Message) {
        guard let window, let actions else { return }
        requestDelete(
            message,
            in: window,
            perform: actions.delete
        )
    }

    func requestDiscardFailed(_ message: Message) {
        guard let window, let actions else { return }
        requestDelete(
            message,
            in: window,
            perform: actions.discardFailed
        )
    }

    private func requestDelete(
        _ message: Message,
        in window: NSWindow,
        perform delete: @escaping (Message) -> Void
    ) {
        removeActionCapsule()
        if MessageDeleteConfirmationPolicy.isBypassed(
            by: NSEvent.modifierFlags
        ) {
            delete(message)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete this message?"
        alert.informativeText = "This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Message")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        // Do not order a sheet synchronously from a SwiftUI-hosted button
        // transaction. AppKit can throw while remote media views are being
        // reconciled during that same update group.
        Task { @MainActor [weak self, weak window] in
            await Task.yield()
            guard let self, let window, self.window === window,
                  window.attachedSheet == nil
            else { return }
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                delete(message)
            }
        }
    }
}
