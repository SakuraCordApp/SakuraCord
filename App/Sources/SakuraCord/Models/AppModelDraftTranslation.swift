import Foundation

extension AppModel {
    /// The translation strip to show above a composer, if any.
    func draftTranslation(for destination: MessageComposerDestination) -> DraftTranslation? {
        guard let state = translation.drafts[destination] else { return nil }
        if state.phase == .showingOriginal {
            return state.translated != nil && draft(in: destination) == state.original ? state : nil
        }
        return state
    }

    func canTranslateDraft(in destination: MessageComposerDestination) -> Bool {
        guard !isDraftTranslationBlocked(in: destination) else { return false }
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
        let text = draft(in: destination)
        let language = translation.settings.draftLanguage
        if isDraftTranslationBlocked(in: destination) {
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
        guard !isDraftTranslationBlocked(in: destination),
              var state = translation.drafts[destination], state.phase == .translated else { return }
        // Keep edits made to the translated draft for the next toggle.
        state.translated = draft(in: destination)
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

    /// Native Undo and Redo publish ordinary text edits, so keep the toggle
    /// state and translated edits synchronized with the actual composer text.
    func reconcileDraftTranslationText(_ text: String, in destination: MessageComposerDestination) {
        guard var state = translation.drafts[destination],
              state.phase == .translated || state.phase == .showingOriginal else { return }
        let previous = state
        if text == state.original {
            state.phase = .showingOriginal
        } else if state.phase == .translated || text == state.translated {
            state.phase = .translated
            state.translated = text
        }
        if state != previous { translation.drafts[destination] = state }
    }

    private func isDraftTranslationBlocked(in destination: MessageComposerDestination) -> Bool {
        let command = commandComposer(for: destination)
        return !translation.settings.isEnabled
            || command.activeCommand != nil || command.isPickerPresented
            || (destination == .thread && threadCreation?.isSubmitting == true)
    }

    private func draftTranslationRefusal(for destination: MessageComposerDestination) -> LocalTranslationError? {
        guard translation.settings.isEnabled else { return .disabled }
        let text = draft(in: destination)
        let command = commandComposer(for: destination)
        if command.activeCommand != nil || command.isPickerPresented { return .slashCommand }
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
        guard !isDraftTranslationBlocked(in: destination),
              draftRevision(for: destination) == state.requestRevision,
              draft(in: destination) == state.original,
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

    private func draftRevision(for destination: MessageComposerDestination) -> UInt64 {
        destination == .channel ? composer.draftRevision : composer.threadDraftRevision
    }

    private func setDraftText(_ value: String, for destination: MessageComposerDestination) {
        translation.draftEditIDs[destination] = UUID()
        updateDraft(value, in: destination)
    }
}
