import AppKit
import SakuraCordModels
import SwiftUI

/// Locates the composer text and attachment previews so a sent message can
/// leave the field the way an iMessage bubble does. The timeline owns the
/// animation; the composer only describes where the message starts.
@MainActor
final class ComposerSendTransitionAnchor {
    /// The field's leading padding before its text, matching a bubble's.
    static var fieldLeadingPadding: CGFloat { InterfaceScale.metric(11) }
    static var fieldTrailingPadding: CGFloat { InterfaceScale.metric(4) }

    private final class AttachmentPreview {
        weak var view: NSView?
        var thumbnail: NSImage?
    }

    weak var textView: NSTextView?
    /// The conversation this composer sends to.
    var channelID: ChannelID?
    private var attachmentPreviews: [UUID: AttachmentPreview] = [:]

    func registerAttachmentPreview(_ view: NSView, thumbnail: NSImage?, for id: UUID) {
        let preview = preview(for: id)
        preview.view = view
        preview.thumbnail = thumbnail
    }

    func removeAttachmentPreview(_ view: NSView, for id: UUID) {
        guard attachmentPreviews[id]?.view === view else { return }
        attachmentPreviews[id] = nil
    }

    /// Describes a send of the current draft and staged attachments.
    func source(
        channelID: ChannelID,
        content: String,
        attachments: [ForumPostAttachment],
        uploads: AttachmentUploadProgressStore
    ) -> NativeTimelineSendTransitionSource? {
        fieldSource(
            channelID: channelID,
            content: content,
            text: content.isEmpty ? nil : textSnapshot(),
            attachments: attachments.map { attachmentSnapshot($0, uploadFraction: uploads.preuploadFraction($0.id)) }
        )
    }

    /// Lets the media viewer zoom a staged file out of its tile and back.
    func mediaViewerSource(for attachment: ForumPostAttachment) -> MediaViewerTransitionSource? {
        guard let view = attachmentPreviews[attachment.id]?.view,
              let image = tileImage(for: attachment)
        else { return nil }
        // SwiftUI hosting can report a visible rect beyond the tile itself.
        let visibleRect = view.visibleRect.intersection(view.bounds)
        guard !visibleRect.isEmpty else { return nil }
        return MediaViewerTransitionSource(
            itemID: attachment.id.uuidString,
            image: image,
            frameInWindow: view.convert(view.bounds, to: nil),
            visibleFrameInWindow: view.convert(visibleRect, to: nil),
            cornerRadius: ComposerAttachmentTray.cornerRadius,
            fillsFrame: true,
            coversSource: false
        )
    }

    /// Describes a send that did not come from the draft, such as a GIF,
    /// sticker, poll or dropped file. It leaves from the empty field.
    func fieldSource(channelID: ChannelID) -> NativeTimelineSendTransitionSource? {
        fieldSource(channelID: channelID, content: nil, text: nil, attachments: [])
    }

    private func fieldSource(
        channelID: ChannelID,
        content: String?,
        text: NativeTimelineSendTransitionSource.Text?,
        attachments: [NativeTimelineSendTransitionSource.Attachment?]
    ) -> NativeTimelineSendTransitionSource? {
        guard let textView,
              let window = textView.window
        else { return nil }
        let textArea = textView.enclosingScrollView ?? textView
        let textFrame = textArea.convert(textArea.bounds, to: nil)
        guard textFrame.width > 1, textFrame.height > 1 else { return nil }
        // The bubble starts as the text's part of the field, leaving the
        // field's accessory buttons uncovered.
        let height = max(textFrame.height, ChatChromeMetrics.composerControlHeight)
        let fieldFrame = CGRect(
            x: textFrame.minX - Self.fieldLeadingPadding,
            y: textFrame.midY - height / 2,
            width: textFrame.width + Self.fieldLeadingPadding + Self.fieldTrailingPadding,
            height: height
        )
        return NativeTimelineSendTransitionSource(
            channelID: channelID,
            content: content,
            capturedAt: ProcessInfo.processInfo.systemUptime,
            window: window,
            fieldFrame: fieldFrame,
            text: text,
            attachments: attachments
        )
    }

    private func preview(for id: UUID) -> AttachmentPreview {
        if let preview = attachmentPreviews[id] { return preview }
        let preview = AttachmentPreview()
        attachmentPreviews[id] = preview
        return preview
    }

    /// A staged attachment's tile in flight, with its upload ring. Spoilers
    /// never fly uncovered.
    private func attachmentSnapshot(
        _ attachment: ForumPostAttachment,
        uploadFraction: Double?
    ) -> NativeTimelineSendTransitionSource.Attachment? {
        guard !attachment.isSpoiler,
              let view = attachmentPreviews[attachment.id]?.view,
              view.window === textView?.window,
              view.visibleRect.contains(view.bounds),
              let image = tileImage(for: attachment)
        else { return nil }
        return NativeTimelineSendTransitionSource.Attachment(
            image: image,
            frame: view.convert(view.bounds, to: nil),
            cornerRadius: ComposerAttachmentTray.cornerRadius,
            uploadFraction: uploadFraction,
            ringScale: ComposerAttachmentTray.ringScale
        )
    }

    /// What a staged attachment's tile shows: an image or video thumbnail,
    /// or another file's icon and type.
    private func tileImage(for attachment: ForumPostAttachment) -> NSImage? {
        guard let preview = attachmentPreviews[attachment.id],
              let view = preview.view,
              let window = view.window
        else { return nil }
        let image: NSImage?
        if attachment.isVisualMedia {
            image = preview.thumbnail
        } else {
            let renderer = ImageRenderer(
                content: ComposerAttachmentFileFace(url: attachment.url)
                    .frame(width: view.bounds.width, height: view.bounds.height)
                    .environment(
                        \.colorScheme,
                        view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
                    )
            )
            renderer.scale = window.backingScaleFactor
            image = renderer.nsImage
        }
        guard let image, image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }

    /// Draws the laid-out glyphs rather than caching the view, which would
    /// also capture the insertion point and marked-text decorations.
    private func textSnapshot() -> NativeTimelineSendTransitionSource.Text? {
        guard let textView,
              let window = textView.window,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        guard glyphRange.length > 0 else { return nil }
        let origin = textView.textContainerOrigin
        let usedRect = layoutManager.usedRect(for: textContainer)
            .offsetBy(dx: origin.x, dy: origin.y)
        // Leave room for descenders, emoji and mention pills that overhang
        // their line fragments.
        let drawRect = usedRect.insetBy(dx: -4, dy: -4)
            .intersection(textView.visibleRect)
            .integral
        guard !drawRect.isEmpty else { return nil }
        let firstLine = layoutManager.lineFragmentRect(
            forGlyphAt: glyphRange.location,
            effectiveRange: nil
        )
        let glyphLocation = layoutManager.location(forGlyphAt: glyphRange.location)
        let baseline = CGPoint(
            x: origin.x + firstLine.minX + glyphLocation.x,
            y: origin.y + firstLine.minY + glyphLocation.y
        )
        guard let image = NativeTimelineSendTransitionSnapshot.render(
            size: drawRect.size,
            scale: window.backingScaleFactor,
            draw: {
                NSGraphicsContext.current?.cgContext.translateBy(x: -drawRect.minX, y: -drawRect.minY)
                textView.effectiveAppearance.performAsCurrentDrawingAppearance {
                    layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
                }
            }
        ) else { return nil }
        return NativeTimelineSendTransitionSource.Text(
            image: image,
            frame: textView.convert(drawRect, to: nil),
            baseline: textView.convert(baseline, to: nil)
        )
    }
}

/// Reports where a staged attachment's thumbnail is drawn.
struct ComposerSendTransitionAttachmentReader: NSViewRepresentable {
    let anchor: ComposerSendTransitionAnchor?
    let id: UUID
    /// The tile's decoded image, which flies or zooms in its place.
    let thumbnail: NSImage?

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.anchor = anchor
        view.id = id
        anchor?.registerAttachmentPreview(view, thumbnail: thumbnail, for: id)
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        if view.anchor !== anchor || view.id != id, let previousID = view.id {
            view.anchor?.removeAttachmentPreview(view, for: previousID)
        }
        view.anchor = anchor
        view.id = id
        anchor?.registerAttachmentPreview(view, thumbnail: thumbnail, for: id)
    }

    static func dismantleNSView(_ view: ReaderView, coordinator: ()) {
        if let id = view.id {
            view.anchor?.removeAttachmentPreview(view, for: id)
        }
    }

    final class ReaderView: NSView {
        weak var anchor: ComposerSendTransitionAnchor?
        var id: UUID?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
