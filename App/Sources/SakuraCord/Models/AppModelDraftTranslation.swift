import Foundation

extension AppModel {
    /// The translation strip to show above a composer, if any.
    func draftTranslation(for destination: MessageComposerDestination) -> DraftTranslation? {
        guard let state = translation.drafts[destination] else { return nil }
        if state.phase == .showingOriginal {
            return state.translated != nil && draftText(for: destination) == state.original ? state : nil
        }
        return state
    }

    func canTranslateDraft(in destination: MessageComposerDestination) -> Bool {
        if let state = draftTranslation(for: destination) {
            switch state.phase {
            case .translating: return false
            case .translated, .showingOriginal: return true
            case .failed: break
            }
        }
        return draftTranslationRefusal(for: destination) == nil
    }

    /// Translates the draft, or toggles between the original and its translation
    /// while the original is unchanged.
    func translateDraft(in destination: MessageComposerDestination) {
        guard translation.settings.isEnabled else { return }
        let text = draftText(for: destination)
        let language = translation.settings.draftLanguage
        if destination == .channel, commandComposer.activeCommand != nil || commandComposer.isPickerPresented {
            translation.resetDraft(destination)
            return
        }
        if var state = translation.drafts[destination] {
            switch state.phase {
            case .translating:
                return
            case .translated:
                showOriginalDraft(in: destination)
                return
            case .showingOriginal:
                if let translated = state.translated, text == state.original, state.language == language {
                    state.phase = .translated
                    translation.drafts[destination] = state
                    setDraftText(translated, for: destination)
                    return
                }
            case .failed:
                break
            }
        }
        if let refusal = draftTranslationRefusal(for: destination) {
            translation.drafts[destination] = DraftTranslation(
                original: text, language: language, phase: .failed(refusal.localizedDescription)
            )
            return
        }
        startDraftTranslation(text, into: language, for: destination)
    }

    func showOriginalDraft(in destination: MessageComposerDestination) {
        guard var state = translation.drafts[destination], state.phase == .translated else { return }
        // Keep edits made to the translated draft for the next toggle.
        state.translated = draftText(for: destination)
        state.phase = .showingOriginal
        translation.drafts[destination] = state
        setDraftText(state.original, for: destination)
    }

    /// Closes the strip and keeps whatever text the composer currently holds.
    func dismissDraftTranslation(in destination: MessageComposerDestination) {
        translation.resetDraft(destination)
    }

    func resetAllTranslations() {
        translation.resetAll()
        clearMessageTranslations()
    }

    private func draftTranslationRefusal(for destination: MessageComposerDestination) -> LocalTranslationError? {
        guard translation.settings.isEnabled else { return .disabled }
        let text = draftText(for: destination)
        if destination == .channel, commandComposer.activeCommand != nil || commandComposer.isPickerPresented {
            return .slashCommand
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") { return .slashCommand }
        return TranslationTokenProtector(text).hasTranslatableText ? nil : .emptyText
    }

    private func startDraftTranslation(
        _ text: String,
        into language: String,
        for destination: MessageComposerDestination
    ) {
        let requestID = UUID()
        let settings = translation.settings
        let channelID = destination == .channel ? selectedChannelID : openThread?.id
        translation.draftTasks[destination]?.cancel()
        translation.drafts[destination] = DraftTranslation(
            original: text, language: language, phase: .translating,
            requestRevision: draftRevision(for: destination), requestID: requestID
        )
        let session = accountSession()
        let state = translation
        state.draftTasks[destination] = Task { [weak self] in
            let outcome: Result<String, any Error>
            do {
                let result = try await state.translator.translate(.init(text: text, targetLanguage: language))
                outcome = .success(result.text)
            } catch is CancellationError {
                if state.drafts[destination]?.requestID == requestID { state.resetDraft(destination) }
                return
            } catch {
                outcome = .failure(AppleTranslationCoordinator.mappedError(error))
            }
            guard let self, !Task.isCancelled, isCurrentAccountSession(session),
                  state.settings == settings, state.drafts[destination]?.requestID == requestID,
                  (destination == .channel ? selectedChannelID : openThread?.id) == channelID else { return }
            finishDraftTranslation(outcome, for: destination)
        }
    }

    private func finishDraftTranslation(_ outcome: Result<String, any Error>, for destination: MessageComposerDestination) {
        translation.draftTasks[destination] = nil
        guard var state = translation.drafts[destination], state.phase == .translating else { return }
        // A result for text the user has since changed would overwrite their edits.
        guard draftRevision(for: destination) == state.requestRevision,
              draftText(for: destination) == state.original,
              draftTranslationRefusal(for: destination) == nil
        else {
            translation.drafts[destination] = nil
            return
        }
        switch outcome {
        case let .success(translated):
            state.translated = translated
            state.phase = .translated
            translation.drafts[destination] = state
            setDraftText(translated, for: destination)
        case let .failure(error):
            state.phase = .failed(error.localizedDescription)
            translation.drafts[destination] = state
        }
    }

    private func draftText(for destination: MessageComposerDestination) -> String {
        destination == .channel ? draft : threadDraft
    }

    private func draftRevision(for destination: MessageComposerDestination) -> UInt64 {
        destination == .channel ? composer.draftRevision : composer.threadDraftRevision
    }

    private func setDraftText(_ value: String, for destination: MessageComposerDestination) {
        translation.draftEditIDs[destination] = UUID()
        switch destination {
        case .channel: updateDraft(value)
        case .thread: updateThreadDraft(value)
        }
    }
}
