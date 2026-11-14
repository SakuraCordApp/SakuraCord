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

    /// Deletes through `action`, after confirming unless Shift is held.
    func requestDelete(_ message: Message, through action: KeyPath<NativeTimelineRowActions, (Message) -> Void> = \.delete) {
        guard let window, let delete = actions?[keyPath: action] else { return }
        removeActionCapsule()
        if NSEvent.modifierFlags.contains(.shift) {
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

extension NativeTimelineCanvasView {
    override func menu(for event: NSEvent) -> NSMenu? {
        dismissHoverLabel()
        guard !overlayBlocksInteractions, !glideBlocksPointer else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard let index = hitRowIndex(at: point.y),
              case let .message(row, _, _) = items[index]
        else { return nil }
        let interactionMode = MessageOutboxPresentation.interactionMode(
            for: row.message
        )
        guard interactionMode.allowsMessageContextMenu else { return nil }
        let localPoint = CGPoint(
            x: point.x,
            y: point.y - displayedRowOrigin(at: index)
        )
        if let menu = userContextMenu(for: row, index: index, localPoint: localPoint) {
            return menu
        }
        let imageItem = NativeTimelineImageContextMenuPlan.item(
            in: row.message,
            layout: layouts[index],
            at: localPoint,
            isRevealed: spoilerRevealStore.isMediaRevealed(in: row.message.id)
        )
        let gif = NativeTimelineGIFContextMenuPlan.result(
            in: row.message,
            layout: layouts[index],
            at: localPoint
        )
        if interactionMode.allowsMediaContextMenu,
           let gif
        {
            return GIFContextMenuBuilder.make(
                actions: gifContextMenuActions(for: gif)
            )
        }
        if interactionMode.allowsMediaContextMenu,
           let imageItem
        {
            return MediaImageContextMenuBuilder.make(
                actions: imageContextMenuActions(for: imageItem)
            )
        }
        guard let actions,
              NativeTimelineHoverHitTesting.contains(
                  point,
                  rowOrigin: displayedRowOrigin(at: index),
                  highlightFrame: layouts[index].highlightFrame
              )
        else { return nil }
        guard let menu = messageContextMenu(
            for: row,
            at: index,
            targetsAuthor: NativeTimelineAuthorProfileGeometry.hitFrame(
                at: localPoint,
                avatarFrame: layouts[index].avatarFrame,
                authorFrame: layouts[index].authorFrame
            ) != nil,
            lookupPoint: point,
            actions: actions,
            failedMediaActions: interactionMode == .failed
                ? imageItem.map(imageContextMenuActions(for:))
                : nil
        ) else { return nil }
        prependTextLinkActions(to: menu, row: row, index: index, localPoint: localPoint)
        return menu
    }

    /// `targetsAuthor` offers user commands instead of message commands in
    /// the Apps submenu, as when the author's avatar or name was clicked.
    func messageContextMenu(
        for row: MessageRowPresentation,
        at index: Int,
        targetsAuthor: Bool,
        lookupPoint: CGPoint? = nil,
        actions: NativeTimelineRowActions,
        failedMediaActions: MediaImageContextMenuActions?
    ) -> NSMenu? {
        guard MessageOutboxPresentation.interactionMode(for: row.message).allowsMessageContextMenu else { return nil }
        let canEdit = model?.canEditMessage(row.message) == true
        let canDelete = model?.canDeleteMessage(row.message) == true
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let lookupPoint, let lookup = dictionaryLookupAction(at: lookupPoint, usesSelection: true) {
            menu.addItem(actionItem("Look Up", systemImage: "character.book.closed", action: lookup))
            menu.addItem(.separator())
        }
        var insertedFailedMediaActions = false
        for entry in NativeTimelineMessageMenuPolicy.entries(
            canEdit: canEdit,
            canDelete: canDelete,
            canRetry: row.message.canRetrySending,
            isFailed: row.message.outboxState == .failed,
            canReply: actions.reply != nil
                && model?.guildTimeoutUntil(in: row.message.channelID, guildID: row.message.guildID) == nil
                && MessageReplyPresentationPolicy.allowsReplyAction(
                    for: row.message
                ),
            canEndPoll: row.message.outboxState == .confirmed && row.message.author.id == model?.currentUser?.id && row.message.poll?.isClosed() == false,
            canForward: actions.forward != nil && model?.canForward(row.message) == true,
            threadAction: row.message.thread != nil
                ? .viewThread
                : (model?.canCreateThread(from: row.message) == true ? .createThread : nil),
            canPin: model?.canManagePins(for: row.message) == true,
            isPinned: row.message.isPinned,
            translationTitle: row.isResource ? nil : model?.messageTranslationMenuTitle(for: row.message),
            canCopyTranslation: !row.isResource && model?.translatedMessageText(row.message) != nil,
            context: messageInteractionContext
        ) {
            guard case let .action(
                action,
                title,
                systemImage,
                isDestructive
            ) = entry
            else {
                menu.addItem(.separator())
                if !insertedFailedMediaActions,
                   let failedMediaActions
                {
                    MediaImageContextMenuBuilder.appendImageActions(
                        to: menu,
                        actions: failedMediaActions,
                        includesLinkActions: false
                    )
                    menu.addItem(.separator())
                    insertedFailedMediaActions = true
                }
                continue
            }
            if case .addReaction = action, model?.canCreateReactions(on: row.message) != true { continue }
            let handler = messageMenuHandler(
                action: action,
                row: row,
                index: index,
                actions: actions
            )
            menu.addItem(
                actionItem(
                    title,
                    systemImage: systemImage,
                    isDestructive: isDestructive,
                    action: handler
                )
            )
        }
        appendApplicationCommandMenu(to: menu, row: row, targetsAuthor: targetsAuthor)
        return menu
    }

    private func userContextMenu(
        for row: MessageRowPresentation, index: Int, localPoint: CGPoint
    ) -> NSMenu? {
        guard let model, row.message.outboxState == .confirmed else { return nil }
        let message = row.message
        let textHit = textPointerHit(in: layouts[index], point: localPoint)
        if let textHit, let spoilerRange = textHit.hit.spoilerRange,
           let key = textSpoilerRevealKey(itemIdentifier: items[index].identifier,
                                         region: textHit.region, rangeLocation: spoilerRange.location),
           !spoilerRevealStore.isTextRevealed(key) { return nil }
        let user: User?
        if NativeTimelineAuthorProfileGeometry.hitFrame(at: localPoint,
            avatarFrame: layouts[index].avatarFrame, authorFrame: layouts[index].authorFrame) != nil {
            user = message.author
        } else if let mention = textHit?.hit.mention,
                  mention.isInteractive, case let .user(userID) = mention.target {
            user = model.systemMessageUser(userID: userID, sourceMessage: message)
        } else if let url = textHit?.hit.url, case let .profile(userID) = SystemMessagePresentation.Action(url: url) {
            user = model.systemMessageUser(userID: userID, sourceMessage: message)
        } else { return nil }
        guard let user else { return nil }
        return UserContextMenu.make(for: user,
            context: .init(guildID: model.messagePresentationGuildID(for: message), channelID: message.channelID,
                           isLocalIdentity: user.id == message.author.id && (message.webhookID != nil || DiscordBuiltInCommands.isClydeMessage(message))), model: model)
    }

    /// Discord's Apps submenu: message commands for the message, or user
    /// commands when the author's avatar or name was right-clicked.
    private func appendApplicationCommandMenu(
        to menu: NSMenu,
        row: MessageRowPresentation,
        targetsAuthor: Bool
    ) {
        let message = row.message
        guard let model, messageInteractionContext == .conversation,
              message.outboxState == .confirmed, !message.flags.contains(.ephemeral),
              model.supportsCapability(.slashCommands)
        else { return }
        let type: ApplicationCommandType = targetsAuthor ? .user : .message
        let targetID = targetsAuthor ? message.author.id.description : message.id.description
        let destination = model.commandDestination(in: message.channelID)
        model.ensureApplicationCommandsLoaded(in: destination)
        let commandComposer = model.commandComposer(for: destination)
        guard !commandComposer.contextMenuCommands(of: type).isEmpty
            || commandComposer.isLoading
        else { return }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        // Rebuilt whenever the submenu opens, so a catalog that finishes
        // loading while the menu is up replaces the loading row.
        let populator = ApplicationCommandAppsMenuPopulator(model: model, type: type, targetID: targetID, channelID: message.channelID)
        submenu.delegate = populator
        let apps = NSMenuItem(title: "Apps", action: nil, keyEquivalent: "")
        ContextMenuItemSupport.configure(apps, title: "Apps", systemImage: SakuraCordSystemSymbol.applicationCommands)
        apps.submenu = submenu
        apps.representedObject = populator
        // Discord puts Apps at the end of the reply/pin group, before Mark Unread.
        let insertion = menu.items.firstIndex { $0.title == "Mark Unread" } ?? 0
        menu.insertItem(apps, at: insertion)
    }

    func messageMenuHandler(
        action: NativeTimelineMessageMenuAction,
        row: MessageRowPresentation,
        index: Int,
        actions: NativeTimelineRowActions
    ) -> () -> Void {
        switch action {
        case .jumpToMessage, .retrySending, .reply, .forward, .viewThread, .markUnread, .pinMessage, .unpinMessage:
            actions.messageMenuHandler(for: action, message: row.message)
        case .copyTranslation, .copyText, .copyLink, .copyMessageID, .copyAuthorID:
            copyMessageMenuHandler(for: action, message: row.message)
        case .addReaction:
            { [weak self] in self?.showReactionPicker(forMessageRow: row.message) }
        case .viewReactions:
            { [weak self] in self?.showMessageReactions(row.message) }
        case .createThread:
            { [weak model] in model?.beginThreadCreation(from: row.message) }
        case .dismissInboxMention:
            { [weak model] in model?.dismissInboxMention(row.message) }
        case .endPoll:
            { [weak self] in self?.requestEndPoll(row.message) }
        case .toggleTranslation:
            { [weak model] in model?.toggleMessageTranslation(row.message) }
        case .editMessage:
            { [weak self] in self?.beginEditing(row: row, at: index) }
        case .deleteMessage, .discardFailedMessage:
            { [weak self] in
                self?.requestDelete(row.message, through: action == .deleteMessage ? \.delete : \.discardFailed)
            }
        }
    }

    private func copyMessageMenuHandler(
        for action: NativeTimelineMessageMenuAction,
        message: Message
    ) -> () -> Void {
        switch action {
        case .copyTranslation:
            { [weak model] in
                if let text = model?.translatedMessageText(message) { Pasteboard.copy(text) }
            }
        case .copyText:
            { Pasteboard.copy(message.content) }
        case .copyLink:
            { [weak self] in
                guard let self else { return }
                Pasteboard.copy(self.messageLink(for: message))
            }
        case .copyMessageID:
            { Pasteboard.copy(message.id.description) }
        case .copyAuthorID:
            { Pasteboard.copy(message.author.id.description) }
        default:
            {}
        }
    }

    func imageContextMenuActions(
        for item: RichMediaItem
    ) -> MediaImageContextMenuActions {
        MediaImageContextMenuActions(
            copyImage: { [weak self] in
                Task { @MainActor [weak self] in
                    do {
                        try await MediaViewerActionService.copyImage(
                            from: item.url
                        )
                    } catch {
                        self?.presentActionError(error)
                    }
                }
            },
            save: MediaSaveMenuActions(
                saveAs: { [weak self] in
                    self?.saveMedia(item, to: .saveAs)
                },
                saveToDefaultFolder: { [weak self] in
                    self?.saveMedia(item, to: .defaultFolder)
                }
            ),
            copyLink: {
                Pasteboard.copy(item.url.absoluteString)
            },
            openLink: {
                MediaViewerActionService.openInBrowser(item.url)
            }
        )
    }

    private func saveMedia(
        _ item: RichMediaItem,
        to destination: MediaSaveDestination
    ) {
        Task { @MainActor [weak self] in
            do {
                _ = try await MediaViewerActionService.save(
                    item,
                    to: destination
                )
            } catch {
                self?.presentActionError(error)
            }
        }
    }

    func gifContextMenuActions(
        for gif: GIFSearchResult
    ) -> GIFContextMenuActions {
        let isFavorite = model?.favoriteGIFs.contains(where: {
            $0.url == gif.url
        }) == true
        return GIFContextMenuActions(
            isFavorite: isFavorite,
            isFavoriteMutationPending: model?.gifFavoriteMutationURL != nil,
            toggleFavorite: { [weak self] in
                self?.model?.setGIFFavorite(
                    gif,
                    isFavorite: !isFavorite
                )
            },
            copyMediaLink: {
                Pasteboard.copy(gif.url.absoluteString)
            }
        )
    }
}

extension NativeTimelineRowActions {
    /// The message menu actions the timeline's host performs.
    func messageMenuHandler(for action: NativeTimelineMessageMenuAction, message: Message) -> () -> Void {
        switch action {
        case .jumpToMessage:
            { openMessage?(message) }
        case .retrySending:
            { retry(message) }
        case .reply:
            { reply?(message) }
        case .forward:
            { forward?(message) }
        case .viewThread:
            {
                guard let thread = message.thread else { return }
                openThread(thread)
            }
        case .markUnread:
            { markUnread(message) }
        case .pinMessage, .unpinMessage:
            { togglePin(message) }
        default:
            {}
        }
    }
}
