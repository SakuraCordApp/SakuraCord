import AppKit
import Foundation
import Observation
import SakuraCordModels

nonisolated enum MediaViewerTransitionTiming {
    static let presentationDuration: TimeInterval = 0.22
    static let remoteImageFadeDuration: TimeInterval = 0.10
    static let interactiveDismissalDuration: TimeInterval = 0.24
    static let interactiveCancellationDuration: TimeInterval = 0.28
}

nonisolated enum MediaViewerPinchDismissalThresholdChange: Equatable {
    case willCommit
    case willCancel
}

@MainActor
@Observable
final class MediaViewerInteractionModel {
    nonisolated static let minimumScale: CGFloat = 1
    nonisolated static let maximumScale: CGFloat = 8
    nonisolated static let minimumPinchDismissalMagnification: CGFloat = 0.45
    nonisolated static let pinchDismissalThreshold: CGFloat = 0.65

    private nonisolated static let minimumScaleTolerance: CGFloat = 0.001
    private nonisolated static let pinchDismissalResetThreshold: CGFloat = 0.70

    let itemCount: Int
    private(set) var selection: Int
    private(set) var scale: CGFloat = minimumScale
    private(set) var offset = CGSize.zero
    private(set) var pinchDismissalProgress: CGFloat = 0
    private(set) var pinchDismissalWillCommit = false
    var isSaving = false
    var feedback: MediaViewerFeedback?
    var errorMessage: String?

    init(itemCount: Int, selection: Int) {
        self.itemCount = max(1, itemCount)
        self.selection = min(max(0, selection), max(0, itemCount - 1))
    }

    var canMoveBackward: Bool { itemCount > 1 }
    var canMoveForward: Bool { itemCount > 1 }

    @discardableResult
    func move(_ delta: Int) -> Bool {
        guard itemCount > 1 else { return false }
        let destination = ((selection + delta) % itemCount + itemCount)
            % itemCount
        return select(destination)
    }

    @discardableResult
    func select(_ index: Int) -> Bool {
        let destination = min(max(0, index), itemCount - 1)
        guard destination != selection else { return false }
        selection = destination
        resetZoom()
        return true
    }

    func toggleZoom() {
        if scale > Self.minimumScale + 0.01 {
            resetZoom()
        } else {
            commitScale(2)
        }
    }

    func commitScale(_ value: CGFloat) {
        scale = min(Self.maximumScale, max(Self.minimumScale, value))
        if scale == Self.minimumScale {
            offset = .zero
        } else {
            pinchDismissalProgress = 0
            pinchDismissalWillCommit = false
        }
    }

    func commitOffset(_ value: CGSize) {
        offset = scale > Self.minimumScale ? value : .zero
    }

    func resetZoom() {
        scale = Self.minimumScale
        offset = .zero
        pinchDismissalProgress = 0
        pinchDismissalWillCommit = false
    }

    @discardableResult
    func updatePinchDismissal(
        magnification: CGFloat
    ) -> MediaViewerPinchDismissalThresholdChange? {
        guard canPinchDismiss else {
            pinchDismissalProgress = 0
            pinchDismissalWillCommit = false
            return nil
        }
        let clampedMagnification = min(
            1,
            max(Self.minimumPinchDismissalMagnification, magnification)
        )
        let linearProgress =
            (1 - clampedMagnification)
            / (1 - Self.minimumPinchDismissalMagnification)
        pinchDismissalProgress = linearProgress * linearProgress

        let previousWillCommit = pinchDismissalWillCommit
        pinchDismissalWillCommit = if pinchDismissalWillCommit {
            magnification <= Self.pinchDismissalResetThreshold
        } else {
            magnification <= Self.pinchDismissalThreshold
        }
        guard pinchDismissalWillCommit != previousWillCommit else {
            return nil
        }
        return pinchDismissalWillCommit ? .willCommit : .willCancel
    }

    func shouldCommitPinchDismissal(magnification: CGFloat) -> Bool {
        guard canPinchDismiss else { return false }
        return pinchDismissalWillCommit
            ? magnification <= Self.pinchDismissalResetThreshold
            : magnification <= Self.pinchDismissalThreshold
    }

    func cancelPinchDismissal() {
        pinchDismissalProgress = 0
        pinchDismissalWillCommit = false
    }

    nonisolated static func isAtMinimumScale(_ scale: CGFloat) -> Bool {
        scale <= minimumScale + minimumScaleTolerance
    }

    private var canPinchDismiss: Bool {
        Self.isAtMinimumScale(scale)
    }
}

struct MediaViewerFeedback: Equatable {
    let message: String
}

nonisolated enum MediaViewerLayoutPolicy {
    static func restingFrame(
        availableSize: CGSize,
        horizontalInset: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> CGRect {
        let width = max(1, availableSize.width - horizontalInset * 2)
        let height = max(1, availableSize.height - topInset - bottomInset)
        return CGRect(
            x: horizontalInset,
            y: topInset,
            width: width,
            height: height
        )
    }

    static func fittedSize(
        mediaWidth: Int?,
        mediaHeight: Int?,
        availableSize: CGSize
    ) -> CGSize {
        let availableWidth = max(1, availableSize.width)
        let availableHeight = max(1, availableSize.height)
        guard let mediaWidth,
              let mediaHeight,
              mediaWidth > 0,
              mediaHeight > 0
        else {
            return CGSize(width: availableWidth, height: availableHeight)
        }

        let mediaAspect = CGFloat(mediaWidth) / CGFloat(mediaHeight)
        let availableAspect = availableWidth / availableHeight
        if mediaAspect > availableAspect {
            return CGSize(
                width: availableWidth,
                height: availableWidth / mediaAspect
            )
        }
        return CGSize(
            width: availableHeight * mediaAspect,
            height: availableHeight
        )
    }

    static func imageFrame(
        imageSize: CGSize,
        in frame: CGRect,
        fillsFrame: Bool
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return frame
        }
        let scale = fillsFrame
            ? max(
                frame.width / imageSize.width,
                frame.height / imageSize.height
            )
            : min(
                frame.width / imageSize.width,
                frame.height / imageSize.height
            )
        let size = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        return CGRect(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func clampedOffset(
        _ offset: CGSize,
        scale: CGFloat,
        fittedSize: CGSize,
        availableSize: CGSize
    ) -> CGSize {
        guard scale > 1 else { return .zero }
        let horizontalLimit = max(
            0,
            (fittedSize.width * scale - availableSize.width) / 2
        )
        let verticalLimit = max(
            0,
            (fittedSize.height * scale - availableSize.height) / 2
        )
        return CGSize(
            width: min(horizontalLimit, max(-horizontalLimit, offset.width)),
            height: min(verticalLimit, max(-verticalLimit, offset.height))
        )
    }

    static func transformedImageFrame(
        restingFrame: CGRect,
        fittedSize: CGSize,
        scale: CGFloat,
        offset: CGSize
    ) -> CGRect {
        let transformedSize = CGSize(
            width: fittedSize.width * scale,
            height: fittedSize.height * scale
        )
        return CGRect(
            x: restingFrame.midX + offset.width - transformedSize.width / 2,
            y: restingFrame.midY + offset.height - transformedSize.height / 2,
            width: transformedSize.width,
            height: transformedSize.height
        )
    }

    static func offsetByScrolling(
        _ offset: CGSize,
        scrollingDelta: CGSize,
        scale: CGFloat,
        fittedSize: CGSize,
        availableSize: CGSize
    ) -> CGSize {
        clampedOffset(
            CGSize(
                width: offset.width + scrollingDelta.width,
                height: offset.height + scrollingDelta.height
            ),
            scale: scale,
            fittedSize: fittedSize,
            availableSize: availableSize
        )
    }
}

struct MediaViewerPresentation: Identifiable {
    let id: UUID
    let messageID: MessageID?
    let items: [RichMediaItem]
    let selection: Int
    let authorID: UserID?
    let authorFontID: Int?
    let authorName: String
    let authorAvatarURL: URL?
    let timestamp: Date
    let timelinePreviewImages: [String: NSImage]
    let transitionLink: MediaViewerTransitionLink

    init(
        id: UUID = UUID(),
        messageID: MessageID? = nil,
        items: [RichMediaItem],
        selection: Int,
        authorID: UserID? = nil,
        authorFontID: Int? = nil,
        authorName: String,
        authorAvatarURL: URL?,
        timestamp: Date,
        timelinePreviewImages: [String: NSImage] = [:],
        transitionSources: [String: MediaViewerTransitionSource] = [:]
    ) {
        self.id = id
        self.messageID = messageID
        self.items = items
        self.selection = selection
        self.authorID = authorID
        self.authorFontID = authorFontID
        self.authorName = authorName
        self.authorAvatarURL = authorAvatarURL
        self.timestamp = timestamp
        self.timelinePreviewImages = timelinePreviewImages
        transitionLink = MediaViewerTransitionLink(sources: transitionSources)
    }

    func withTimelineMedia(
        previewImages: [String: NSImage],
        transitionSources: [String: MediaViewerTransitionSource]
    ) -> Self {
        Self(
            id: id,
            messageID: messageID,
            items: items,
            selection: selection,
            authorID: authorID,
            authorFontID: authorFontID,
            authorName: authorName,
            authorAvatarURL: authorAvatarURL,
            timestamp: timestamp,
            timelinePreviewImages: previewImages,
            transitionSources: transitionSources
        )
    }

    /// The shown item's source when it hides itself rather than being
    /// covered. The viewer may have paged away from its first item.
    func uncoveredSourceItemID(showing selectedItemID: String?) -> String? {
        let id = selectedItemID.flatMap { id in items.contains { $0.id == id } ? id : nil } ?? items[selection].id
        return transitionLink.sources[id]?.coversSource == false ? id : nil
    }

    func withTransitionSource(
        _ transitionSource: MediaViewerTransitionSource
    ) -> Self {
        var sources = transitionLink.sources
        sources[transitionSource.itemID] = transitionSource
        return withTimelineMedia(
            previewImages: timelinePreviewImages,
            transitionSources: sources
        )
    }
}

enum MediaViewerPlan {
    static func composerAttachments(
        _ attachments: [ForumPostAttachment],
        selectedAttachmentID: UUID,
        author: User
    ) -> MediaViewerPresentation? {
        let items = attachments.enumerated().map { index, attachment in
            var optimistic = OptimisticAttachmentPresentation.attachment(
                for: attachment.url,
                index: index,
                id: attachment.id.uuidString
            )
            optimistic.filename = attachment.filename
            optimistic.description = attachment.description
            optimistic.isSpoiler = attachment.isSpoiler
            return RichMediaItem(optimistic)
        }
        guard let selection = items.firstIndex(where: {
            $0.id == selectedAttachmentID.uuidString
        }) else { return nil }
        return MediaViewerPresentation(
            items: items,
            selection: selection,
            authorID: author.id,
            authorFontID: author.displayNameStyle?.fontID,
            authorName: author.displayName,
            authorAvatarURL: author.avatarURL,
            timestamp: .now
        )
    }

    static func attachments(
        in message: Message,
        selectedAttachmentID: String,
        isRevealed: (String) -> Bool = { _ in true }
    ) -> MediaViewerPresentation? {
        let items = message.attachments.filter { attachment in
            !attachment.isSpoiler
                || isRevealed(
                    NativeTimelineComponentRevealKey
                        .attachmentComponentID(attachment.id)
                )
        }.map(RichMediaItem.init)
        return presentation(
            items: items,
            selectedID: selectedAttachmentID,
            message: message
        )
    }

    static func linkedImages(
        in message: Message,
        selectedReferenceID: String
    ) -> MediaViewerPresentation? {
        let items = LinkedImagePresentation(content: message.content)
            .images.map { reference in
                RichMediaItem(
                    imageID: reference.id,
                    url: reference.url,
                    previewURL: reference.displayURL == reference.url
                        ? nil
                        : reference.displayURL,
                    title: reference.label
                )
            }
        return presentation(
            items: items,
            selectedID: selectedReferenceID,
            message: message
        )
    }

    static func components(
        in message: Message,
        layouts: [NativeTimelineComponentLayout],
        selectedComponentID: String,
        isRevealed: (String) -> Bool
    ) -> MediaViewerPresentation? {
        let items = layouts.flatMap { layout -> [RichMediaItem] in
            let hiddenContainers = layout.containers.filter {
                $0.isSpoiler && !isRevealed($0.componentID)
            }
            func isVisible(_ frame: CGRect, isSpoiler: Bool, id: String) -> Bool {
                (!isSpoiler || isRevealed(id))
                    && !hiddenContainers.contains(where: {
                        $0.frame.contains(frame)
                    })
            }

            let images: [RichMediaItem] = layout.images.compactMap { region in
                guard isVisible(
                    region.frame,
                    isSpoiler: region.isSpoiler,
                    id: region.componentID
                ) else { return nil }
                return componentItem(
                    id: region.componentID,
                    url: region.openURL,
                    previewURL: region.displayURL,
                    title: region.description,
                    isVideo: false,
                    message: message
                )
            }
            let media: [RichMediaItem] = layout.media.compactMap { region in
                guard isVisible(
                    region.frame,
                    isSpoiler: region.isSpoiler,
                    id: region.componentID
                ) else { return nil }
                return componentItem(
                    id: region.componentID,
                    url: region.openURL,
                    previewURL: region.displayURL,
                    title: region.description,
                    isVideo: region.isVideo,
                    message: message
                )
            }
            let files: [RichMediaItem] = layout.files.compactMap { region in
                guard isVisible(
                    region.frame,
                    isSpoiler: region.isSpoiler,
                    id: region.componentID
                ) else { return nil }
                return componentFileItem(region)
            }
            return images + media + files
        }
        return presentation(
            items: items,
            selectedID: selectedComponentID,
            message: message
        )
    }

    static func embed(
        in message: Message,
        id: String
    ) -> MediaViewerPresentation? {
        guard let embed = message.embeds.first(where: { $0.id == id }),
              let item = RichMediaItem(
                  embed: embed,
                  attachments: message.attachments
              )
        else { return nil }
        return presentation(
            items: [item],
            selectedID: item.id,
            message: message
        )
    }

    private static func presentation(
        items: [RichMediaItem],
        selectedID: String,
        message: Message
    ) -> MediaViewerPresentation? {
        guard let selection = items.firstIndex(where: {
            $0.id == selectedID
        }) else { return nil }
        return MediaViewerPresentation(
            messageID: message.id,
            items: items,
            selection: selection,
            authorID: message.author.id,
            authorFontID: message.author.displayNameStyle?.fontID,
            authorName: message.guildMember?.nickname
                ?? message.author.displayName,
            authorAvatarURL: message.guildMember?.avatarURL
                ?? message.author.avatarURL,
            timestamp: message.timestamp
        )
    }

    private static func componentItem(
        id: String,
        url: URL,
        previewURL: URL,
        title: String,
        isVideo: Bool,
        message: Message
    ) -> RichMediaItem {
        if var item = message.attachments
            .first(where: { $0.url == url })
            .map(RichMediaItem.init)
        {
            item.id = id
            item.title = title
            item.previewURL = previewURL == url ? item.previewURL : previewURL
            return item
        }
        return RichMediaItem(
            componentID: id,
            url: url,
            previewURL: previewURL == url ? nil : previewURL,
            title: title,
            isVideo: isVideo
        )
    }

    /// A file component's item: its message attachment, or the file the
    /// component names, previewed by its kind. A named file of no known type
    /// with an image's extension shows as an image.
    private static func componentFileItem(
        _ region: NativeTimelineComponentLayout.FileRegion
    ) -> RichMediaItem {
        var item = RichMediaItem(region.attachment)
        if item.kind == .file, RichMediaItem.isSupportedImageURL(region.openURL) {
            item.kind = .image(animated: RichMediaItem.isAnimatedImageURL(region.openURL))
        }
        item.id = region.componentID
        item.title = region.title
        item.description = region.description
        return item
    }
}
