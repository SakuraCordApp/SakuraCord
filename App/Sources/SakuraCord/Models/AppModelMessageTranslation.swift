import Foundation
import SakuraCordModels

extension AppModel {
    func canTranslateMessage(_ message: Message) -> Bool {
        translation.settings.isEnabled
            && message.outboxState != .failed
            && !message.type.hasGeneratedContent
            && !message.flags.contains(.isComponentsV2)
            && TranslationTokenProtector(message.content).hasTranslatableText
    }

    /// The context-menu title for a message, or `nil` when it cannot be translated.
    func messageTranslationMenuTitle(for message: Message) -> String? {
        guard canTranslateMessage(message) else { return nil }
        return translation.messages.visibleEntry(for: message) == nil ? "Translate Message" : "Show Original"
    }

    func messageTranslationPresentation(for message: Message) -> MessageTranslationEntry? {
        translation.messages.visibleEntry(for: message)
    }

    func toggleMessageTranslation(_ message: Message) {
        guard canTranslateMessage(message) else { return }
        let language = translation.settings.messageLanguage
        if var entry = translation.messages[message.id],
           entry.sourceContent == message.content, entry.language == language {
            if entry.isVisible {
                hideMessageTranslation(message)
                return
            }
            if case .translated = entry.status {
                entry.isVisible = true
                translation.messages.set(entry, for: message.id)
                publishMessageTranslationChange(message)
                return
            }
        }
        startMessageTranslation(message, into: language)
    }

    /// Handles the caption link below a translation: hide it, or dismiss an error.
    func performMessageTranslationCaptionAction(_ message: Message) {
        hideMessageTranslation(message)
    }

    func clearMessageTranslations() {
        for task in translation.messageTasks.values { task.cancel() }
        translation.messageTasks.removeAll()
        guard !translation.messages.isEmpty else { return }
        translation.messages.removeAll()
        invalidateTimelinePresentation()
    }

    private func hideMessageTranslation(_ message: Message) {
        guard var entry = translation.messages[message.id] else { return }
        switch entry.status {
        case .translated:
            entry.isVisible = false
            translation.messages.set(entry, for: message.id)
        case .loading, .failed:
            translation.messageTasks.removeValue(forKey: message.id)?.cancel()
            translation.messages.remove(message.id)
        }
        publishMessageTranslationChange(message)
    }

    private func startMessageTranslation(_ message: Message, into language: String) {
        let content = message.content
        let requestID = UUID()
        let settings = translation.settings
        let evicted = translation.messages.set(
            MessageTranslationEntry(sourceContent: content, language: language, status: .loading, requestID: requestID),
            for: message.id
        )
        for id in evicted { translation.removeMessage(id) }
        if !evicted.isEmpty { invalidateTimelinePresentation() }
        publishMessageTranslationChange(message)
        translation.messageTasks[message.id]?.cancel()
        let session = accountSession()
        let state = translation
        state.messageTasks[message.id] = Task { [weak self] in
            let status: MessageTranslationEntry.Status
            do {
                let result = try await state.translator.translate(.init(text: content, targetLanguage: language))
                status = .translated(result)
            } catch is CancellationError {
                guard let self, state.messages[message.id]?.requestID == requestID else { return }
                state.removeMessage(message.id)
                publishMessageTranslationChange(message)
                return
            } catch {
                status = .failed(AppleTranslationCoordinator.mappedError(error).localizedDescription)
            }
            guard let self, !Task.isCancelled, isCurrentAccountSession(session),
                  state.settings == settings,
                  var entry = state.messages[message.id], entry.requestID == requestID,
                  entry.sourceContent == content, entry.status == .loading else { return }
            state.messageTasks[message.id] = nil
            entry.status = status
            state.messages.set(entry, for: message.id)
            publishMessageTranslationChange(message)
        }
    }

    func translatedMessageText(_ message: Message) -> String? {
        guard let entry = translation.messages.visibleEntry(for: message),
              case let .translated(result) = entry.status else { return nil }
        return result.text
    }

    func invalidateMessageTranslation(_ id: MessageID, content: String? = nil) {
        guard let entry = translation.messages[id], entry.sourceContent != content else { return }
        translation.removeMessage(id)
        invalidateTimelinePresentation()
    }

    /// Relayouts the affected row. Rows that may also live in the recent
    /// conversation layout cache need the global presentation revision.
    private func publishMessageTranslationChange(_ message: Message) {
        let inChannel = selectedMessageIDs.contains(message.id)
        let inThread = threadMessages.contains { $0.id == message.id }
        guard inChannel || inThread, messageCache[message.channelID] == nil else {
            invalidateTimelinePresentation()
            return
        }
        if inChannel { publishMessageRowsUpdate(changedMessageIDs: [message.id]) }
        if inThread { publishThreadMessageRowsPresentationUpdate(changedMessageIDs: [message.id]) }
    }
}
