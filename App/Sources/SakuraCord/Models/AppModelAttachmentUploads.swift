import Foundation
import SakuraCordModels

struct OversizedAttachmentPrompt: Identifiable {
    let id = UUID()
    let fileURL: URL
    let fileSize: Int64
    let discordLimit: Int64
    let premiumType: Int
    let destination: MessageComposerDestination
    let channelID: ChannelID

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
            premiumType: snapshot?.currentUser.premiumType ?? 0
        )
    }

    func attachmentURLsWithinDiscordLimit(
        _ urls: [URL],
        offeringExternalUploadFor destination: MessageComposerDestination? = nil
    ) -> [URL] {
        guard !urls.isEmpty else { return [] }
        let premiumType = snapshot?.currentUser.premiumType ?? 0
        let limit = DiscordAttachmentUploadPolicy.maximumFileSize(premiumType: premiumType)
        var accepted: [URL] = []
        var oversized: [(URL, Int64)] = []

        for url in urls {
            guard let size = attachmentFileSize(at: url) else {
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
        if let destination,
           let channelID = conversationChannelID(for: destination)
        {
            for (url, size) in oversized {
                enqueueOversizedAttachmentPrompt(
                    OversizedAttachmentPrompt(
                        fileURL: url,
                        fileSize: size,
                        discordLimit: limit,
                        premiumType: premiumType,
                        destination: destination,
                        channelID: channelID
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

    func dismissOversizedAttachmentPrompt() {
        oversizedAttachmentPrompt = nil
        presentNextOversizedAttachmentPrompt()
    }

    func uploadOversizedAttachment(
        _ prompt: OversizedAttachmentPrompt,
        using service: ExternalAttachmentHostingService
    ) {
        guard prompt.availableServices.contains(service),
              conversationChannelID(for: prompt.destination) == prompt.channelID
        else { return }

        oversizedAttachmentPrompt = nil
        externalAttachmentUploadPresentation = ExternalAttachmentUploadPresentation(
            fileName: prompt.fileURL.lastPathComponent,
            service: service
        )
        externalAttachmentUploadTask?.cancel()
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
                guard conversationChannelID(for: prompt.destination) == prompt.channelID else {
                    throw ExternalAttachmentUploadError.conversationChanged(link)
                }
                appendExternalAttachmentLink(link, to: prompt.destination)
            } catch is CancellationError {
                // Cancellation is an explicit no-send action.
            } catch {
                errorMessage = "The (service.displayName) upload failed: \(error.localizedDescription)"
            }
            externalAttachmentUploadPresentation = nil
            externalAttachmentUploadTask = nil
            presentNextOversizedAttachmentPrompt()
        }
    }

    func cancelExternalAttachmentUpload() {
        externalAttachmentUploadTask?.cancel()
        externalAttachmentUploadTask = nil
        externalAttachmentUploadPresentation = nil
        presentNextOversizedAttachmentPrompt()
    }

    func oversizedAttachmentMessage(_ prompt: OversizedAttachmentPrompt) -> String {
        var message = oversizedAttachmentExplanation(
            fileName: prompt.fileURL.lastPathComponent,
            fileSize: prompt.fileSize,
            limit: prompt.discordLimit
        )
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

    private func attachmentFileSize(at url: URL) -> Int64? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init)
    }

    private func enqueueOversizedAttachmentPrompt(_ prompt: OversizedAttachmentPrompt) {
        if oversizedAttachmentPrompt == nil,
           externalAttachmentUploadPresentation == nil
        {
            oversizedAttachmentPrompt = prompt
        } else {
            queuedOversizedAttachmentPrompts.append(prompt)
        }
    }

    private func presentNextOversizedAttachmentPrompt() {
        guard oversizedAttachmentPrompt == nil,
              externalAttachmentUploadPresentation == nil,
              !queuedOversizedAttachmentPrompts.isEmpty
        else { return }
        oversizedAttachmentPrompt = queuedOversizedAttachmentPrompts.removeFirst()
    }

    private func conversationChannelID(
        for destination: MessageComposerDestination
    ) -> ChannelID? {
        switch destination {
        case .channel: selectedChannelID
        case .thread: openThread?.id
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
            maximum = "10 MB"
        case DiscordAttachmentUploadPolicy.basicAndClassicLimit:
            maximum = "50 MB"
        case DiscordAttachmentUploadPolicy.nitroLimit:
            maximum = "500 MB"
        default:
            maximum = formatter.string(fromByteCount: limit)
        }
        return "\(fileName) is \(size), which exceeds your Discord upload limit of \(maximum) per file. It was not attached."
    }
}
