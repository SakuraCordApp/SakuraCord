import Foundation
import SakuraCordModels

enum AttachmentComposerContext: Equatable {
    case conversation(ChannelID)
    case threadCreation(UUID)
}

struct OversizedAttachmentPrompt: Identifiable {
    enum Stage { case compaction, externalUpload }
    let id = UUID()
    let fileURL: URL
    let fileSize: Int64
    let discordLimit: Int64
    let premiumType: Int
    let destination: MessageComposerDestination
    let context: AttachmentComposerContext
    var stage: Stage = .externalUpload
    var compactionOutcome: String?

    func externalUpload(after outcome: String? = nil) -> Self {
        Self(fileURL: fileURL, fileSize: fileSize, discordLimit: discordLimit,
             premiumType: premiumType, destination: destination, context: context,
             stage: .externalUpload, compactionOutcome: outcome)
    }

    var availableServices: [ExternalAttachmentHostingService] {
        ExternalAttachmentHostingService.allCases.filter {
            $0.canUpload(fileURL: fileURL, size: fileSize)
        }
    }
}

struct ExternalAttachmentUploadPresentation: Equatable {
    let fileName: String
    let service: ExternalAttachmentHostingService
}

extension AppModel {
    var discordAttachmentLimit: Int64 {
        DiscordAttachmentUploadPolicy.maximumFileSize(
            premiumType: currentUser?.premiumType ?? 0
        )
    }

    func attachmentURLsWithinDiscordLimit(
        _ urls: [URL],
        offeringExternalUploadFor destination: MessageComposerDestination? = nil
    ) async -> [URL] {
        let urls = uploadableFileURLs(urls)
        guard !urls.isEmpty else { return [] }
        let generation = accountSessionGeneration
        let context = attachmentComposerContext(for: destination ?? .channel)
        let checkedFiles: [UploadPrivacyPreparation.CheckedFile]
        do {
            checkedFiles = try await uploadPrivacyPreparation.checkSelection(urls)
        } catch {
            guard generation == accountSessionGeneration,
                  attachmentComposerContext(for: destination ?? .channel) == context,
                  !Task.isCancelled, !(error is CancellationError) else { return [] }
            errorMessage = error.localizedDescription
            return []
        }
        guard generation == accountSessionGeneration,
              attachmentComposerContext(for: destination ?? .channel) == context,
              !Task.isCancelled else { return [] }
        let premiumType = snapshot?.currentUser.premiumType ?? 0
        let limit = DiscordAttachmentUploadPolicy.maximumFileSize(premiumType: premiumType)
        var accepted: [URL] = []
        var oversized: [(URL, Int64)] = []

        for file in checkedFiles {
            let url = file.url
            guard let size = file.uploadSize else {
                // Preserve the existing error path for unreadable or disappearing files.
                accepted.append(url)
                continue
            }
            if DiscordAttachmentUploadPolicy.allows(
                fileSize: size,
                premiumType: premiumType
            ) {
                accepted.append(url)
            } else {
                oversized.append((url, size))
            }
        }

        guard !oversized.isEmpty else { return accepted }
        if let destination, let context {
            for (url, size) in oversized {
                enqueueOversizedAttachmentPrompt(
                    OversizedAttachmentPrompt(
                        fileURL: url,
                        fileSize: size,
                        discordLimit: limit,
                        premiumType: premiumType,
                        destination: destination,
                        context: context,
                        stage: .compaction
                    )
                )
            }
        } else if let first = oversized.first {
            errorMessage = oversizedAttachmentExplanation(
                fileName: first.0.lastPathComponent,
                fileSize: first.1,
                limit: limit
            )
        }
        return accepted
    }

    /// Skips folders like Discord, which reports an error only when no file
    /// remains, and rejects the whole batch when any file is empty.
    func uploadableFileURLs(_ urls: [URL]) -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        let files = urls.compactMap { url -> (url: URL, size: Int?)? in
            let values = try? url.resourceValues(forKeys: keys)
            return values?.isDirectory == true ? nil : (url, values?.fileSize)
        }
        if files.isEmpty, !urls.isEmpty {
            errorMessage = "That file type is not supported."
        }
        guard !files.contains(where: { $0.size == 0 }) else {
            errorMessage = "File cannot be empty."
            return []
        }
        return files.map(\.url)
    }

    func dismissOversizedAttachmentPrompt(id expectedID: UUID? = nil) {
        guard let prompt = oversizedAttachmentPrompt else { return }
        if let expectedID, prompt.id != expectedID { return }
        if prompt.stage == .compaction {
            skipAttachmentCompaction(prompt)
            return
        }
        oversizedAttachmentPrompt = nil
        presentNextOversizedAttachmentPrompt()
        pruneOwnedPromisedAttachmentFiles()
    }

    func uploadOversizedAttachment(
        _ prompt: OversizedAttachmentPrompt,
        using service: ExternalAttachmentHostingService
    ) {
        guard prompt.stage == .externalUpload,
              prompt.availableServices.contains(service),
              isComposerDropEligible(prompt.destination),
              attachmentComposerContext(for: prompt.destination) == prompt.context
        else { return }

        externalAttachmentUploadTask?.cancel()
        if let externalAttachmentUploadFileURL {
            endUsingOwnedPromisedFiles([externalAttachmentUploadFileURL])
        }
        externalAttachmentUploadFileURL = nil
        externalAttachmentUploadGeneration &+= 1
        let generation = externalAttachmentUploadGeneration
        beginUsingOwnedPromisedFiles([prompt.fileURL])
        externalAttachmentUploadFileURL = prompt.fileURL
        if oversizedAttachmentPrompt?.id == prompt.id {
            oversizedAttachmentPrompt = nil
        }
        externalAttachmentUploadPresentation = ExternalAttachmentUploadPresentation(
            fileName: prompt.fileURL.lastPathComponent,
            service: service
        )
        externalAttachmentUploadTask = Task { [weak self] in
            guard let self else { return }
            let accessed = prompt.fileURL.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    prompt.fileURL.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let link = try await externalAttachmentUploader.upload(
                    fileURL: prompt.fileURL,
                    using: service
                )
                try Task.checkCancellation()
                guard externalAttachmentUploadGeneration == generation else { return }
                guard attachmentComposerContext(for: prompt.destination) == prompt.context else {
                    throw ExternalAttachmentUploadError.conversationChanged(link)
                }
                appendExternalAttachmentLink(link, to: prompt.destination)
            } catch is CancellationError {
                // Cancellation is an explicit no-send action.
            } catch {
                guard externalAttachmentUploadGeneration == generation else { return }
                errorMessage = "The \(service.displayName) upload failed: \(error.localizedDescription)"
            }
            guard externalAttachmentUploadGeneration == generation else { return }
            externalAttachmentUploadPresentation = nil
            externalAttachmentUploadTask = nil
            externalAttachmentUploadFileURL = nil
            endUsingOwnedPromisedFiles([prompt.fileURL])
            presentNextOversizedAttachmentPrompt()
        }
    }

    func cancelExternalAttachmentUpload() {
        externalAttachmentUploadGeneration &+= 1
        externalAttachmentUploadTask?.cancel()
        externalAttachmentUploadTask = nil
        externalAttachmentUploadPresentation = nil
        if let externalAttachmentUploadFileURL {
            endUsingOwnedPromisedFiles([externalAttachmentUploadFileURL])
        }
        externalAttachmentUploadFileURL = nil
        presentNextOversizedAttachmentPrompt()
    }

    func adoptPromisedFileBatch(_ batch: ComposerPromisedFileBatch) -> [URL] {
        let directory = batch.directory.standardizedFileURL
        guard ComposerPromisedFileStorage.isManagedDirectory(directory) else {
            batch.discard()
            return []
        }
        let adoptedURLs = batch.urls.compactMap {
            ComposerPromisedFileStorage.approvedRegularFile($0, in: directory)
        }
        for url in adoptedURLs {
            promisedAttachmentDirectoryByFileURL[url] = directory
        }
        if adoptedURLs.isEmpty {
            batch.discard()
        }
        return adoptedURLs
    }

    func beginUsingOwnedPromisedFiles(_ urls: [URL]) {
        promisedAttachmentFilesInFlight.formUnion(
            urls.map(\.standardizedFileURL).filter {
                promisedAttachmentDirectoryByFileURL[$0] != nil
            }
        )
    }

    func endUsingOwnedPromisedFiles(_ urls: [URL]) {
        promisedAttachmentFilesInFlight.subtract(
            urls.map(\.standardizedFileURL)
        )
        pruneOwnedPromisedAttachmentFiles()
    }

    func pruneOwnedPromisedAttachmentFiles() {
        var retainedFileURLs = Set(
            (channelComposerAttachments + threadComposerAttachments)
                .map { $0.url.standardizedFileURL }
        )
        retainedFileURLs.formUnion(
            queuedOversizedAttachmentPrompts.map {
                $0.fileURL.standardizedFileURL
            }
        )
        if let oversizedAttachmentPrompt {
            retainedFileURLs.insert(
                oversizedAttachmentPrompt.fileURL.standardizedFileURL
            )
        }
        if let source = attachmentCompactionPresentation?.fileURL {
            retainedFileURLs.insert(source.standardizedFileURL)
        }
        if let source = externalAttachmentUploadFileURL {
            retainedFileURLs.insert(source.standardizedFileURL)
        }
        retainedFileURLs.formUnion(
            composer.outbox.draftsByNonce.values.lazy
                .flatMap(\.attachmentURLs)
                .map(\.standardizedFileURL)
        )
        retainedFileURLs.formUnion(commandComposers.flatMap(\.attachmentURLs).map(\.standardizedFileURL))
        retainedFileURLs.formUnion(promisedAttachmentFilesInFlight)

        let staleFileURLs = promisedAttachmentDirectoryByFileURL.keys.filter {
            !retainedFileURLs.contains($0)
        }
        let candidateDirectories = Set(staleFileURLs.compactMap {
            promisedAttachmentDirectoryByFileURL.removeValue(forKey: $0)
        })
        let retainedDirectories = Set(promisedAttachmentDirectoryByFileURL.values)
        for directory in candidateDirectories where !retainedDirectories.contains(directory) {
            ComposerPromisedFileStorage.removeDirectory(directory)
        }
    }

    func releaseAllOwnedPromisedFiles() {
        let directories = Set(promisedAttachmentDirectoryByFileURL.values)
        promisedAttachmentDirectoryByFileURL.removeAll()
        promisedAttachmentFilesInFlight.removeAll()
        externalAttachmentUploadFileURL = nil
        for directory in directories {
            ComposerPromisedFileStorage.removeDirectory(directory)
        }
    }

    func oversizedAttachmentMessage(_ prompt: OversizedAttachmentPrompt) -> String {
        var message = oversizedAttachmentExplanation(
            fileName: prompt.fileURL.lastPathComponent,
            fileSize: prompt.fileSize,
            limit: prompt.discordLimit
        )
        if let outcome = prompt.compactionOutcome { message += "\n\n" + outcome }
        if prompt.availableServices.contains(.catbox) {
            message += "\n\nCatbox is a third-party host and keeps uploads permanently."
        }
        if prompt.availableServices.contains(.litterbox) {
            message += "\n\nLitterbox is a third-party host; this upload will expire after 24 hours."
        }
        if prompt.availableServices.isEmpty {
            message += "\n\nThis file is not eligible for the configured third-party hosts."
        } else {
            message += " The returned HTTPS link will be added to your draft for you to review and send."
        }
        return message
    }

    func attachmentFileSize(at url: URL) -> Int64? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init)
    }

    private func enqueueOversizedAttachmentPrompt(_ prompt: OversizedAttachmentPrompt) {
        queuedOversizedAttachmentPrompts.append(prompt)
        presentNextOversizedAttachmentPrompt()
    }

    func presentNextOversizedAttachmentPrompt() {
        guard oversizedAttachmentPrompt == nil,
              externalAttachmentUploadPresentation == nil,
              attachmentCompactionPresentation == nil,
              !queuedOversizedAttachmentPrompts.isEmpty
        else { return }
        let prompt = queuedOversizedAttachmentPrompts.removeFirst()
        routeOversizedAttachment(prompt)
    }

    func attachmentComposerContext(
        for destination: MessageComposerDestination
    ) -> AttachmentComposerContext? {
        switch destination {
        case .channel: selectedChannelID.map(AttachmentComposerContext.conversation)
        case .thread:
            if let creation = threadCreation {
                .threadCreation(creation.identity)
            } else {
                openThread.map { .conversation($0.id) }
            }
        }
    }

    private func appendExternalAttachmentLink(
        _ link: URL,
        to destination: MessageComposerDestination
    ) {
        let value = link.absoluteString
        switch destination {
        case .channel:
            updateDraft(appending(value, to: draft))
        case .thread:
            threadDraft = appending(value, to: threadDraft)
        }
    }

    private func appending(_ value: String, to draft: String) -> String {
        guard !draft.isEmpty else { return value }
        return draft.last?.isWhitespace == true ? draft + value : draft + " " + value
    }

    private func oversizedAttachmentExplanation(
        fileName: String,
        fileSize: Int64,
        limit: Int64
    ) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let size = formatter.string(fromByteCount: fileSize)
        let maximum: String
        switch limit {
        case DiscordAttachmentUploadPolicy.baseLimit:
            maximum = "20 MB"
        case DiscordAttachmentUploadPolicy.basicAndClassicLimit:
            maximum = "50 MB"
        case DiscordAttachmentUploadPolicy.nitroLimit:
            maximum = "1 GB"
        default:
            maximum = formatter.string(fromByteCount: limit)
        }
        return "\(fileName) is \(size), which exceeds your Discord upload limit of \(maximum) per file. It was not attached."
    }
}
