import AppKit
import Combine
import SakuraCordModels
import SwiftUI

@MainActor
final class NativeTimelineCanvasStorage {
    var items: [NativeMessageTimelineItem] = []
    var layouts: [NativeTimelineRowLayout] = []
    var rowHeights: [CGFloat] = []
    var rowOrigins: [CGFloat] = []
    var contentHeight: CGFloat = 0
}

nonisolated final class NativeTimelineAccessibilityElement:
    NSAccessibilityElement
{
    let press: (@MainActor @Sendable () -> Bool)?

    nonisolated init(
        press: (@MainActor @Sendable () -> Bool)? = nil
    ) {
        self.press = press
        super.init()
    }

    nonisolated override func accessibilityActionNames()
        -> [NSAccessibility.Action]
    {
        press == nil ? [] : [.press]
    }

    nonisolated override func accessibilityPerformPress() -> Bool {
        let action = press
        return MainActor.assumeIsolated {
            action?() ?? false
        }
    }

    @MainActor
    func performPressIfAvailable() -> Bool {
        press?() ?? false
    }
}

@MainActor
final class NativeTimelineAccessibilityProxyView: NSView {
    nonisolated let press: (@MainActor @Sendable () -> Bool)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func isAccessibilityElement() -> Bool {
        true
    }

    init(source: NSAccessibilityElement) {
        if let source = source as? NativeTimelineAccessibilityElement {
            press = {
                source.performPressIfAvailable()
            }
        } else {
            press = nil
        }
        super.init(frame: .zero)
        setAccessibilityRole(source.accessibilityRole())
        setAccessibilitySubrole(source.accessibilitySubrole())
        setAccessibilityLabel(source.accessibilityLabel())
        setAccessibilityValue(source.accessibilityValue())
        setAccessibilityHelp(source.accessibilityHelp())
        setAccessibilityIdentifier(source.accessibilityIdentifier())
        setAccessibilityEnabled(source.isAccessibilityEnabled())
        setAccessibilityCustomActions(
            source.accessibilityCustomActions()
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {}

    nonisolated override func accessibilityActionNames()
        -> [NSAccessibility.Action]
    {
        press == nil ? [] : [.press]
    }

    nonisolated override func accessibilityPerformPress() -> Bool {
        let action = press
        return MainActor.assumeIsolated {
            action?() ?? false
        }
    }
}

nonisolated enum NativeTimelineAccessibilityPresentation {
    static func attachmentLabel(_ attachment: Attachment) -> String {
        let label =
            nonblank(attachment.description)
            ?? nonblank(attachment.title)
            ?? attachment.filename
        if attachment.isSpoiler {
            return "Spoiler attachment, \(label)"
        }
        return label
    }

    static func stickerLabel(_ sticker: MessageSticker) -> String {
        nonblank(sticker.description) ?? sticker.name
    }

    static func threadLabel(_ thread: MessageThreadSummary) -> String {
        let replyCount = thread.messageCount
        return "\(thread.name), \(replyCount) "
            + (replyCount == 1 ? "reply" : "replies")
    }

    static func nonblank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated enum NativeTimelineAccessibilityPolicy {
    static func bufferedViewport(
        around viewport: CGRect,
        contentHeight: CGFloat
    ) -> CGRect {
        let minY = max(0, viewport.minY - viewport.height)
        let maxY = min(
            max(minY, contentHeight),
            viewport.maxY + viewport.height
        )
        return CGRect(
            x: 0,
            y: minY,
            width: viewport.width,
            height: max(0, maxY - minY)
        )
    }

    static func showsMessageBody(
        messageID: MessageID,
        editingMessageID: MessageID?
    ) -> Bool {
        messageID != editingMessageID
    }

    static func editingOverlayInsertionIndex(
        in rowIdentifiers: [NativeMessageTimelineItem.Identifier],
        editingItemIdentifier: NativeMessageTimelineItem.Identifier?
    ) -> Int? {
        guard let editingItemIdentifier,
              let rowIndex = rowIdentifiers.firstIndex(
                  of: editingItemIdentifier
              )
        else { return nil }
        return rowIndex + 1
    }
}

nonisolated enum NativeTimelineEditingGeometry {
    static func rowHeight(
        avatarMaxY: CGFloat?,
        contentOriginY: CGFloat,
        contentHeight: CGFloat
    ) -> CGFloat {
        max(
            avatarMaxY ?? 0,
            contentOriginY + contentHeight + 3
        )
    }
}

struct NativeTimelineComponentRevealKey: Hashable {
    let messageID: MessageID
    let componentID: String

    static func attachmentComponentID(_ attachmentID: String) -> String {
        "attachment:\(attachmentID)"
    }

    static func attachment(
        messageID: MessageID,
        attachmentID: String
    ) -> Self {
        Self(
            messageID: messageID,
            componentID: attachmentComponentID(attachmentID)
        )
    }
}

nonisolated enum NativeTimelineTransientRowGeometry {
    static func contentOriginY(
        base: CGFloat,
        heightDelta: CGFloat,
        minimum: CGFloat
    ) -> CGFloat {
        guard base > minimum + 0.5 else { return base }
        return max(minimum, base - heightDelta)
    }

    static func contentHeight(
        base: CGFloat,
        replacementHeight: CGFloat?,
        baseRowHeight: CGFloat?
    ) -> CGFloat {
        base + heightDelta(
            replacementHeight: replacementHeight,
            baseRowHeight: baseRowHeight
        )
    }

    static func rowOrigin(
        base: CGFloat,
        rowIndex: Int,
        replacementIndex: Int?,
        replacementHeight: CGFloat?,
        baseRowHeight: CGFloat?
    ) -> CGFloat {
        guard let replacementIndex, rowIndex > replacementIndex else {
            return base
        }
        return base + heightDelta(
            replacementHeight: replacementHeight,
            baseRowHeight: baseRowHeight
        )
    }

    static func rowHeight(
        base: CGFloat,
        rowIndex: Int,
        replacementIndex: Int?,
        replacementHeight: CGFloat?
    ) -> CGFloat {
        guard rowIndex == replacementIndex, let replacementHeight else {
            return base
        }
        return replacementHeight
    }

    static func heightDelta(
        replacementHeight: CGFloat?,
        baseRowHeight: CGFloat?
    ) -> CGFloat {
        guard let replacementHeight, let baseRowHeight else { return 0 }
        return replacementHeight - baseRowHeight
    }
}

@MainActor
final class NativeTimelineActionCapsuleState: ObservableObject {
    @Published var isReactionPickerPresented = false {
        didSet {
            guard oldValue != isReactionPickerPresented else { return }
            presentationDidChange?(isPresentationActive)
        }
    }

    @Published var isDeleteConfirmationPresented = false {
        didSet {
            guard oldValue != isDeleteConfirmationPresented else { return }
            presentationDidChange?(isPresentationActive)
        }
    }

    var isPresentationActive: Bool {
        isReactionPickerPresented || isDeleteConfirmationPresented
    }

    var presentationDidChange: ((Bool) -> Void)?
}

struct NativeTimelineActionCapsuleOverlay: View {
    let model: AppModel
    let message: Message
    let canEdit: Bool
    let canDelete: Bool
    @ObservedObject var state: NativeTimelineActionCapsuleState
    let jumpToMessage: (() -> Void)?
    let unpinMessage: (() -> Void)?
    let dismissInboxMention: (() -> Void)?
    let retry: (() -> Void)?
    let edit: () -> Void
    let reply: (() -> Void)?
    let forward: (() -> Void)?
    let react: (String) -> Void
    let copy: () -> Void
    let copyLink: () -> Void
    let openThread: (() -> Void)?
    let delete: () -> Void

    var body: some View {
        Group {
            if let jumpToMessage {
                HoverActionPill {
                    HoverActionButton(
                        systemImage: NativeTimelineSearchResultPresentation
                            .jumpToMessageSystemImage,
                        help: "Jump to Message",
                        action: jumpToMessage
                    )
                    if let dismissInboxMention {
                        HoverActionButton(
                            systemImage: "envelope.open",
                            help: "Mark as Read",
                            action: dismissInboxMention
                        )
                    }
                    if let unpinMessage {
                        HoverActionButton(
                            systemImage: "pin.slash",
                            help: "Unpin Message",
                            action: unpinMessage
                        )
                    }
                }
            } else {
                MessageActionCapsule(
                    model: model,
                    message: message,
                    canEdit: canEdit,
                    canDelete: canDelete,
                    isReactionPickerPresented: $state.isReactionPickerPresented,
                    isDeleteConfirmationPresented:
                        $state.isDeleteConfirmationPresented,
                    retry: retry,
                    edit: edit,
                    reply: reply,
                    forward: forward,
                    react: react,
                    copy: copy,
                    copyLink: copyLink,
                    openThread: openThread,
                    delete: delete
                )
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Message actions")
    }
}

struct MediaViewerTransitionSource {
    let itemID: String
    let image: NSImage
    let frameInWindow: CGRect
    let visibleFrameInWindow: CGRect
    let cornerRadius: CGFloat
    let fillsFrame: Bool
}

struct NativeTimelineMediaViewerPresentation: Identifiable {
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
    let transitionSources: [String: MediaViewerTransitionSource]

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
        self.transitionSources = transitionSources
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

    func withTransitionSource(
        _ transitionSource: MediaViewerTransitionSource
    ) -> Self {
        var sources = transitionSources
        sources[transitionSource.itemID] = transitionSource
        return withTimelineMedia(
            previewImages: timelinePreviewImages,
            transitionSources: sources
        )
    }
}

enum NativeTimelineMediaViewerPlan {
    static func composerAttachments(
        _ attachments: [ForumPostAttachment],
        selectedAttachmentID: UUID,
        author: User
    ) -> NativeTimelineMediaViewerPresentation? {
        let items = attachments.enumerated().compactMap { index, attachment -> RichMediaItem? in
            var optimistic = OptimisticAttachmentPresentation.attachment(
                for: attachment.url,
                index: index,
                id: attachment.id.uuidString
            )
            optimistic.filename = attachment.filename
            optimistic.description = attachment.description
            optimistic.isSpoiler = attachment.isSpoiler
            guard optimistic.mediaKind == .image
                    || optimistic.mediaKind == .animatedImage
            else { return nil }
            return RichMediaItem(optimistic)
        }
        guard let selection = items.firstIndex(where: {
            $0.id == selectedAttachmentID.uuidString
        }) else { return nil }
        return NativeTimelineMediaViewerPresentation(
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
    ) -> NativeTimelineMediaViewerPresentation? {
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
    ) -> NativeTimelineMediaViewerPresentation? {
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
    ) -> NativeTimelineMediaViewerPresentation? {
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
                return componentImageFileItem(
                    region,
                    message: message
                )
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
    ) -> NativeTimelineMediaViewerPresentation? {
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
    ) -> NativeTimelineMediaViewerPresentation? {
        guard let selection = items.firstIndex(where: {
            $0.id == selectedID
        }) else { return nil }
        return NativeTimelineMediaViewerPresentation(
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

    private static func componentImageFileItem(
        _ region: NativeTimelineComponentLayout.FileRegion,
        message: Message
    ) -> RichMediaItem? {
        if let attachment = message.attachments.first(where: {
            $0.url == region.openURL
        }) {
            var item = RichMediaItem(attachment)
            guard case .image = item.kind else { return nil }
            item.id = region.componentID
            item.title = region.title
            item.description = region.description
            return item
        }
        guard RichMediaItem.isSupportedImageURL(region.openURL) else {
            return nil
        }
        return RichMediaItem(
            imageID: region.componentID,
            url: region.openURL,
            title: region.title,
            description: region.description
        )
    }
}

final class NativeTimelineBeginningSelectionOverlay: NSImageView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func isAccessibilityElement() -> Bool {
        false
    }
}
