import AppKit
import SakuraCordModels

struct NativeTimelineRowActions {
    var loadEarlier: () -> Void
    var openMessage: ((Message) -> Void)?
    var openReply: (MessageID) -> Void
    var reply: ((Message) -> Void)?
    var forward: ((Message) -> Void)?
    var retry: (Message) -> Void
    var edit: (Message, String) -> Void
    var markUnread: (Message) -> Void
    var delete: (Message) -> Void
    var togglePin: (Message) -> Void
    var discardFailed: (Message) -> Void
    var react: (String, Message) -> Void
    var openThread: (MessageThreadSummary) -> Void
    var submitComponent: (
        Message,
        String,
        ComponentInteractionKind,
        [String]
    ) -> Void
    var checkForUpdates: () -> Void
    var openSettings: (SettingsDeepLinkDestination) -> Void
    var applyTheme: (SakuraCordSharedTheme) -> Void

    init(
        loadEarlier: @escaping () -> Void,
        openMessage: ((Message) -> Void)? = nil,
        openReply: @escaping (MessageID) -> Void,
        reply: ((Message) -> Void)?,
        forward: ((Message) -> Void)? = nil,
        retry: @escaping (Message) -> Void,
        edit: @escaping (Message, String) -> Void,
        markUnread: @escaping (Message) -> Void,
        delete: @escaping (Message) -> Void,
        togglePin: @escaping (Message) -> Void = { _ in },
        react: @escaping (String, Message) -> Void,
        openThread: @escaping (MessageThreadSummary) -> Void,
        submitComponent: @escaping (
            Message,
            String,
            ComponentInteractionKind,
            [String]
        ) -> Void,
        discardFailed: @escaping (Message) -> Void = { _ in },
        checkForUpdates: @escaping () -> Void = {},
        openSettings: @escaping (SettingsDeepLinkDestination) -> Void = { _ in },
        applyTheme: @escaping (SakuraCordSharedTheme) -> Void = { _ in }
    ) {
        self.loadEarlier = loadEarlier
        self.openMessage = openMessage
        self.openReply = openReply
        self.reply = reply
        self.forward = forward
        self.retry = retry
        self.edit = edit
        self.markUnread = markUnread
        self.delete = delete
        self.togglePin = togglePin
        self.discardFailed = discardFailed
        self.react = react
        self.openThread = openThread
        self.submitComponent = submitComponent
        self.checkForUpdates = checkForUpdates
        self.openSettings = openSettings
        self.applyTheme = applyTheme
    }
}

extension NativeMessageTimelineCoordinator {
    static func makeActions(
        from parent: NativeMessageTimelineView
    ) -> NativeTimelineRowActions {
        return NativeTimelineRowActions(
            loadEarlier: parent.loadEarlier,
            openMessage: parent.conversation.activatesMessageOnClick
                ? { [weak model = parent.model] message in
                    guard let model else { return }
                    switch parent.conversation {
                    case .search:
                        model.navigateToSearchResult(message)
                    case .pins:
                        model.dismissPinnedMessages()
                        model.navigateToPinnedResult(message)
                    case .inbox:
                        model.navigateToInboxResult(message)
                    case .channel, .thread, .resource:
                        break
                    }
                }
                : nil,
            openReply: parent.openReply,
            reply: parent.conversation.supportsReply
                ? { [weak model = parent.model] message in
                    model?.reply(to: message)
                }
                : nil,
            forward: parent.model.supportedCapabilities.contains(.messageForwarding)
                ? { [weak model = parent.model] message in
                    model?.presentForwarding(message)
                }
                : nil,
            retry: { [weak model = parent.model] message in
                guard let model else { return }
                Task { await model.retrySending(message) }
            },
            edit: { [weak model = parent.model] message, content in
                guard let model else { return }
                Task { await model.edit(message, content: content) }
            },
            markUnread: { [weak model = parent.model] message in
                guard let model else { return }
                model.markMessageAndFollowingUnread(message)
            },
            delete: { [weak model = parent.model] message in
                guard let model else { return }
                Task { await model.delete(message) }
            },
            togglePin: { [weak model = parent.model] message in
                model?.togglePinnedState(for: message)
            },
            react: { [weak model = parent.model] emoji, message in
                guard let model else { return }
                Task { await model.toggleReaction(emoji, on: message) }
            },
            openThread: { [weak model = parent.model] thread in
                model?.open(thread)
            },
            submitComponent: { [weak model = parent.model] message, customID, kind, values in
                guard let model else { return }
                Task {
                    await model.submitComponent(
                        on: message,
                        customID: customID,
                        kind: kind,
                        values: values
                    )
                }
            },
            discardFailed: { [weak model = parent.model] message in
                model?.discardFailedOutgoingMessage(message)
            },
            checkForUpdates: {
                AppDelegate.current?.updateController.checkForUpdates()
            },
            openSettings: { destination in
                SettingsNavigationRouter.shared.open(
                    page: destination.page,
                    section: destination.section,
                    controlID: destination.controlID
                )
                parent.openSettings()
            },
            applyTheme: { [weak model = parent.model] sharedTheme in
                SakuraCordThemeStore.shared.apply(sharedTheme.theme)
                guard let model else { return }
                var appearance = model.appearanceSettings
                appearance.colorScheme = sharedTheme.appearance
                appearance.windowOpacity = sharedTheme.windowOpacity
                model.applyAppearanceSettings(appearance)
            }
        )
    }

}
