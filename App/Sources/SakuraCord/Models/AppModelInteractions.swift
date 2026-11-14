import DiscordProtocol
import Foundation
import SakuraCordModels

/// Where a locally shown interaction row belongs and who it speaks for.
struct InteractionRowOrigin {
    let nonce: String
    let channelID: ChannelID
    let guildID: GuildID?
    let application: ApplicationCommandApplication
    let commandName: String?
}

/// Routes nonce-correlated lifecycle events back to their initiating surface.
struct PendingInteractionRecord {
    enum Kind {
        case command(channelID: ChannelID, commandName: String, application: ApplicationCommandApplication)
        case component(ComponentControlKey, channelID: ChannelID, applicationName: String)
        case modalSubmission(channelID: ChannelID, application: ApplicationCommandApplication, formID: String)
    }

    let kind: Kind
    /// Success can precede a returned modal, so finished records linger briefly.
    var isFinished = false
}

extension AppModel {
    static let maximumRetainedInteractionRecords = 64
    /// Discord reports a missed acknowledgement within seconds. This bounds the
    /// local pending state if that event never arrives, without replaying anything.
    static let interactionPendingDeadline: Duration = .seconds(30)

    func trackInteraction(_ record: PendingInteractionRecord, nonce: String) {
        if pendingInteractions.updateValue(record, forKey: nonce) == nil {
            pendingInteractionOrder.append(nonce)
        }
        while pendingInteractionOrder.count > Self.maximumRetainedInteractionRecords {
            let oldest = pendingInteractionOrder.removeFirst()
            consumeInteraction(.failed(nonce: oldest, failure: InteractionFailure(reasonCode: 2)))
            interactionDeadlineTasks.removeValue(forKey: oldest)?.cancel()
            pendingInteractions[oldest] = nil
        }
    }

    /// Start after transport acceptance, so preparing and uploading attachments
    /// cannot consume the application's acknowledgement deadline.
    func startInteractionDeadline(nonce: String) {
        guard pendingInteractions[nonce]?.isFinished == false,
              interactionDeadlineTasks[nonce] == nil else { return }
        let session = accountSession()
        interactionDeadlineTasks[nonce] = Task { [weak self] in
            do { try await Task.sleep(for: Self.interactionPendingDeadline) } catch { return }
            guard let self, isCurrentAccountSession(session),
                  pendingInteractions[nonce]?.isFinished == false else { return }
            consumeInteraction(.failed(
                nonce: nonce,
                failure: InteractionFailure(reasonCode: InteractionFailure.applicationDidNotRespond)
            ))
        }
    }

    func consumeInteraction(_ event: InteractionEvent) {
        switch event {
        case .created:
            break
        case let .succeeded(nonce, _):
            guard let record = finishPendingInteraction(nonce) else { return }
            interactionSucceeded(record, nonce: nonce)
        case let .failed(nonce, failure):
            if commandComposers.contains(where: { $0.failAutocomplete(nonce: nonce, failure: failure) }) { return }
            guard let record = finishPendingInteraction(nonce) else { return }
            interactionFailed(record, nonce: nonce, failure: failure)
        case let .presentModal(modal):
            presentInteractionModal(modal)
        }
    }

    /// Marks a tracked interaction finished; nil when unknown or already settled.
    func finishPendingInteraction(_ nonce: String) -> PendingInteractionRecord? {
        guard var record = pendingInteractions[nonce], !record.isFinished else { return nil }
        interactionDeadlineTasks.removeValue(forKey: nonce)?.cancel()
        record.isFinished = true
        pendingInteractions[nonce] = record
        return record
    }

    private func interactionSucceeded(_ record: PendingInteractionRecord, nonce: String) {
        switch record.kind {
        case let .command(channelID, _, _):
            // A message response already replaced the placeholder; a form or
            // deferred update produces none, so the placeholder goes.
            removeInteractionPlaceholderIfPending(nonce: nonce, channelID: channelID)
        case let .component(key, _, _):
            updateComponentPresentation {
                $0.pendingControls.remove(key)
                $0.pendingMessages.remove(key.messageID)
                $0.errors[key] = nil
            }
        case let .modalSubmission(_, _, formID):
            if let form = interactionModalForm, form.id == formID {
                form.finishSubmitting(rejection: nil)
                interactionModalForm = nil
            }
        }
    }

    private func interactionFailed(_ record: PendingInteractionRecord, nonce: String, failure: InteractionFailure) {
        switch record.kind {
        case let .command(channelID, _, _):
            failInteractionPlaceholder(
                nonce: nonce, channelID: channelID,
                message: Self.commandFailureText(failure)
            )
        case let .component(key, _, applicationName):
            updateComponentPresentation {
                $0.pendingControls.remove(key)
                $0.pendingMessages.remove(key.messageID)
                $0.errors[key] = failure.isMissingAcknowledgement
                    ? "\(applicationName) didn’t respond in time"
                    : failure.message ?? "This interaction failed."
            }
        case let .modalSubmission(channelID, application, _):
            appendInteractionNotice(
                nonce: nonce, channelID: channelID, application: application,
                commandName: nil, message: Self.commandFailureText(failure)
            )
        }
    }

    private func presentInteractionModal(_ modal: InteractionModal) {
        // Only a form opened by this session's own action is presented.
        guard let record = pendingInteractions[modal.openingNonce] else { return }
        _ = finishPendingInteraction(modal.openingNonce)
        switch record.kind {
        case let .command(channelID, _, _):
            removeInteractionPlaceholderIfPending(nonce: modal.openingNonce, channelID: channelID)
        case let .component(key, _, _):
            updateComponentPresentation {
                $0.pendingControls.remove(key)
                $0.pendingMessages.remove(key.messageID)
            }
        case .modalSubmission:
            break
        }
        let form = InteractionModalFormState(modal: modal)
        form.resolveEntityLabels { [weak self] options, kind in
            self?.resolvedDefaultComponentChoices(options, kind: kind, guildID: modal.guildID) ?? options
        }
        interactionModalForm = form
    }

    static func commandFailureText(_ failure: InteractionFailure) -> String {
        if failure.isMissingAcknowledgement || failure.message == nil {
            return "The application did not respond"
        }
        return failure.message ?? "The application did not respond"
    }

    /// Fills metadata a response may omit while its command is still tracked.
    func enrichInteractionResponse(_ message: inout Message) {
        guard let nonce = message.nonce,
              case let .command(_, commandName, application)? = pendingInteractions[nonce]?.kind
        else { return }
        var metadata = message.interactionMetadata ?? MessageInteractionMetadata()
        metadata.name = metadata.name ?? commandName
        metadata.applicationID = metadata.applicationID ?? application.id
        metadata.user = metadata.user ?? snapshot?.currentUser
        message.interactionMetadata = metadata
    }

    // MARK: Command placeholders

    /// Discord shows a local "Sending command…" row, not marked private, until
    /// the app answers.
    func appendInteractionPlaceholder(
        for invocation: ApplicationCommandInvocation
    ) {
        let command = invocation.command
        let message = interactionLocalMessage(
            InteractionRowOrigin(
                nonce: invocation.nonce, channelID: invocation.channelID, guildID: invocation.guildID,
                application: command.application, commandName: command.displayName
            ),
            type: command.type == .chatInput ? .chatInputCommand : .contextMenuCommand,
            content: "Sending command…",
            flags: .loading,
            outboxState: .sending
        )
        appendOutgoingMessage(message)
    }

    func updateInteractionPlaceholder(
        nonce: String, channelID: ChannelID, progress: ApplicationCommandProgress
    ) {
        let content: String = switch progress {
        case .preparing, .submitting, .awaitingResponse: "Sending command…"
        case let .reserving(files): "Preparing \(files) file\(files == 1 ? "" : "s")…"
        case let .uploading(fileName, _, _): "Uploading \(fileName)…"
        }
        mutateInteractionPlaceholder(nonce: nonce, channelID: channelID) { message in
            guard message.outboxState == .sending, message.content != content else { return false }
            message.content = content
            return true
        }
    }

    func failInteractionPlaceholder(nonce: String, channelID: ChannelID, message text: String) {
        mutateInteractionPlaceholder(nonce: nonce, channelID: channelID) { message in
            guard message.outboxState == .sending else { return false }
            message.content = text
            message.flags = [.ephemeral, .localInteractionFailure]
            message.outboxState = .confirmed
            return true
        }
    }

    func removeInteractionPlaceholderIfPending(nonce: String, channelID: ChannelID) {
        guard outgoingState(nonce: nonce, channelID: channelID) == .sending else { return }
        removeOutgoingMessage(nonce: nonce, channelID: channelID)
    }

    func appendInteractionNotice(
        nonce: String, channelID: ChannelID, application: ApplicationCommandApplication,
        commandName: String?, message text: String, isFailure: Bool = true
    ) {
        let guildID = knownRootChannel(channelID)?.guildID
        appendOutgoingMessage(interactionLocalMessage(
            InteractionRowOrigin(
                nonce: nonce, channelID: channelID, guildID: guildID,
                application: application, commandName: commandName
            ),
            type: .reply, content: text, flags: isFailure ? [.ephemeral, .localInteractionFailure] : [.ephemeral], outboxState: .confirmed
        ))
    }

    private func mutateInteractionPlaceholder(
        nonce: String, channelID: ChannelID, _ change: (inout Message) -> Bool
    ) {
        if openThread?.id == channelID,
           let index = threadMessages.firstIndex(where: { $0.nonce == nonce })
        {
            var message = threadMessages[index]
            if change(&message) { threadMessages[index] = message }
            return
        }
        if selectedChannelID == channelID,
           let index = messages.firstIndex(where: { $0.nonce == nonce })
        {
            var message = messages[index]
            guard change(&message) else { return }
            replaceSelectedMessage(message, at: index)
            return
        }
        guard var cached = messageCache[channelID],
              let index = cached.firstIndex(where: { $0.nonce == nonce })
        else { return }
        if change(&cached[index]) { messageCache[channelID] = cached }
    }

    private func interactionLocalMessage(
        _ origin: InteractionRowOrigin,
        type: DiscordMessageType, content: String, flags: MessageFlags, outboxState: OutboxState
    ) -> Message {
        let application = origin.application
        let author = application.id == DiscordBuiltInCommands.application.id
            ? DiscordBuiltInCommands.clyde
            : application.bot ?? User(
            id: application.botID ?? UserID(application.id) ?? UserID(rawValue: 1),
            username: application.name,
            displayName: application.name,
            avatarURL: application.iconURL,
            isBot: true
        )
        return Message(
            id: composer.outbox.nextOptimisticMessageID(),
            channelID: origin.channelID,
            author: author,
            content: content,
            nonce: origin.nonce,
            outboxState: outboxState,
            type: type,
            flags: flags,
            applicationID: ApplicationID(application.id),
            application: application,
            interactionMetadata: origin.commandName.map {
                MessageInteractionMetadata(
                    type: 2, name: $0, user: snapshot?.currentUser, applicationID: application.id
                )
            },
            guildID: origin.guildID
        )
    }

    // MARK: Returned forms

    func dismissInteractionModal() {
        // Cancelling is local; Discord's client sends nothing to the application.
        interactionModalForm = nil
    }

    func submitInteractionModal(_ form: InteractionModalFormState) {
        guard form === interactionModalForm, !form.isSubmitting, form.validate() else { return }
        guard form.isSubmittable else {
            form.failSubmitting("This form contains a field SakuraCord can’t submit yet.")
            return
        }
        form.beginSubmitting()
        let submission = ModalSubmission(modal: form.modal, values: form.submissionValues())
        trackInteraction(
            PendingInteractionRecord(kind: .modalSubmission(
                channelID: form.modal.channelID, application: form.modal.application, formID: form.id
            )),
            nonce: submission.nonce
        )
        let session = accountSession()
        let fileURLs = form.fileURLs
        startAccountChildTask(account: session) { [weak self] _, session in
            guard let self else { return }
            await withAttachmentFileAccess(fileURLs) {
                do {
                    try await session.provider.submitModal(submission)
                    guard isCurrentAccountSession(session) else { return }
                    startInteractionDeadline(nonce: submission.nonce)
                    form.finishSubmitting(rejection: nil)
                    // An accepted submission closes the form; the response follows separately.
                    if interactionModalForm === form { interactionModalForm = nil }
                } catch let rejection as ModalSubmissionRejection {
                    guard isCurrentAccountSession(session) else { return }
                    _ = finishPendingInteraction(submission.nonce)
                    guard interactionModalForm === form else { return }
                    form.finishSubmitting(rejection: rejection)
                } catch {
                    guard isCurrentAccountSession(session) else { return }
                    // Gateway failure can settle the record before transport throws.
                    // The still-present form must recover independently of that record.
                    _ = finishPendingInteraction(submission.nonce)
                    guard interactionModalForm === form else { return }
                    DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
                    form.failSubmitting("Something went wrong. Try again.")
                }
            }
        }
    }
}
