import SakuraCordModels
import SwiftUI

nonisolated enum ForwardPreviewMediaKind: Equatable {
    case image(animated: Bool)
    case video
    case audio
    case file
}

nonisolated struct ForwardPreviewMedia: Equatable {
    let url: URL?
    let kind: ForwardPreviewMediaKind
}

nonisolated struct ForwardMessagePreviewPlan: Equatable {
    let content: String?
    let attachmentSummary: String?
    let attachmentSystemImage: String?
    let media: ForwardPreviewMedia?
    let mediaOverflowCount: Int

    var hasAttachmentRow: Bool { attachmentSummary != nil }
    var contentLineLimit: Int { hasAttachmentRow ? 1 : 2 }

    static func make(message: Message) -> Self {
        let directMedia = message.attachments.map { attachment in
            let kind: ForwardPreviewMediaKind = switch attachment.mediaKind {
            case .image: .image(animated: false)
            case .animatedImage: .image(animated: true)
            case .video: .video
            case .audio: .audio
            case .file: .file
            }
            return ForwardPreviewMedia(
                url: attachment.proxyURL ?? attachment.url,
                kind: kind
            )
        }
        let embedMedia = MessageEmbedPresentation.visibleEmbeds(for: message)
            .compactMap(Self.media(for:))
        let componentMedia = message.components.flatMap(Self.media(in:))
        let allMedia = directMedia + embedMedia + componentMedia

        let componentContent = nonEmpty(Self.componentText(in: message.components))
        let content = componentContent
            ?? nonEmpty(Self.inlineHeadingContent(message.content))
            ?? message.embeds.lazy.compactMap {
                nonEmpty($0.title) ?? nonEmpty($0.description)
            }.first

        let summary = Self.summary(directMedia: directMedia)
        let visualMedia = allMedia.filter { media in
            switch media.kind {
            case .image, .video: true
            case .audio, .file: false
            }
        }
        return Self(
            content: content,
            attachmentSummary: summary.text,
            attachmentSystemImage: summary.systemImage,
            media: visualMedia.first,
            mediaOverflowCount: max(0, visualMedia.count - 1)
        )
    }

    private static func summary(
        directMedia: [ForwardPreviewMedia]
    ) -> (text: String?, systemImage: String?) {
        let media = directMedia
        guard !media.isEmpty else { return (nil, nil) }
        let kinds = media.map(\.kind)
        let imageCount = kinds.count { kind in
            if case .image = kind { return true }
            return false
        }
        let videoCount = kinds.count { $0 == .video }
        let audioCount = kinds.count { $0 == .audio }
        let fileCount = kinds.count { $0 == .file }
        if imageCount == media.count {
            return (counted(imageCount, singular: "image"), "photo.on.rectangle.angled")
        }
        if videoCount == media.count {
            return (counted(videoCount, singular: "video"), "video.fill")
        }
        if audioCount == media.count {
            return (counted(audioCount, singular: "audio file"), "waveform")
        }
        if fileCount == media.count {
            return (counted(fileCount, singular: "file"), "doc.fill")
        }
        return (counted(media.count, singular: "attachment"), "paperclip")
    }

    private static func counted(_ count: Int, singular: String) -> String {
        "\(count) \(singular)\(count == 1 ? "" : "s")"
    }

    private static func media(for embed: MessageEmbed) -> ForwardPreviewMedia? {
        if let video = embed.video {
            if let thumbnail = embed.thumbnail {
                let url = thumbnail.proxyURL ?? thumbnail.url
                let animated = url?.pathExtension.lowercased() == "gif"
                return ForwardPreviewMedia(url: url, kind: .image(animated: animated))
            }
            return ForwardPreviewMedia(
                url: video.proxyURL ?? video.url,
                kind: .video
            )
        }
        guard let image = embed.image ?? embed.thumbnail else { return nil }
        let url = image.proxyURL ?? image.url
        let animated = embed.type?.lowercased() == "gifv"
            || url?.pathExtension.lowercased() == "gif"
        return ForwardPreviewMedia(url: url, kind: .image(animated: animated))
    }

    private static func media(in component: MessageComponent) -> [ForwardPreviewMedia] {
        switch component {
        case .actionRow(_, let children), .container(_, _, _, let children):
            children.flatMap(Self.media(in:))
        case .section(_, let children, let accessory):
            children.flatMap(Self.media(in:)) + (accessory.map(Self.media(in:)) ?? [])
        case .thumbnail(_, let value):
            [media(value)]
        case .mediaGallery(_, let items):
            items.map { media($0.media) }
        case .file(_, let value):
            [ForwardPreviewMedia(url: value.proxyURL ?? value.url, kind: .file)]
        case .button, .select, .textDisplay, .separator, .unsupported:
            []
        }
    }

    private static func media(_ value: ComponentMedia) -> ForwardPreviewMedia {
        let contentType = value.contentType?.lowercased() ?? ""
        let url = value.proxyURL ?? value.url
        if contentType.hasPrefix("video/") {
            return ForwardPreviewMedia(url: url, kind: .video)
        }
        let animated = contentType == "image/gif"
            || url?.pathExtension.lowercased() == "gif"
        return ForwardPreviewMedia(url: url, kind: .image(animated: animated))
    }

    private static func componentText(in components: [MessageComponent]) -> String {
        components
            .flatMap(text(in:))
            .map(inlineComponentText)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func inlineComponentText(_ content: String) -> String {
        content
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                var value = line.trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { return nil }
                let markerCount = value.prefix(while: { $0 == "#" }).count
                if markerCount > 0,
                   markerCount <= 6,
                   value.dropFirst(markerCount).first?.isWhitespace == true
                {
                    value = value.dropFirst(markerCount)
                        .trimmingCharacters(in: .whitespaces)
                    return "**\(value)**"
                }
                return value
            }
            .joined(separator: " ")
    }

    private static func inlineHeadingContent(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "#" else { return content }
        return inlineComponentText(content)
    }

    private static func text(in component: MessageComponent) -> [String] {
        switch component {
        case .textDisplay(_, let content): [content]
        case .actionRow(_, let children), .container(_, _, _, let children):
            children.flatMap(Self.text(in:))
        case .section(_, let children, let accessory):
            children.flatMap(Self.text(in:)) + (accessory.map(Self.text(in:)) ?? [])
        case .button, .select, .thumbnail, .mediaGallery, .file, .separator, .unsupported:
            []
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }
}

struct ForwardedMessagePreview: View {
    let model: AppModel
    let message: Message

    private var plan: ForwardMessagePreviewPlan {
        ForwardMessagePreviewPlan.make(message: message)
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.secondary.opacity(0.20))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 6) {
                if let content = plan.content {
                    let resolver = MessageMentionResolver(model: model, message: message)
                    CustomEmojiRichText(
                        model: model,
                        content: content,
                        emojiSize: 22,
                        baseFontSize: 16,
                        maximumNumberOfLines: plan.contentLineLimit,
                        isSelectable: false,
                        foregroundColor: plan.hasAttachmentRow
                            ? .labelColor
                            : .secondaryLabelColor,
                        mentionPresentation: resolver.presentation
                    )
                    .frame(
                        minHeight: 22,
                        maxHeight: CGFloat(plan.contentLineLimit) * 22,
                        alignment: .top
                    )
                    .clipped()
                }
                if let summary = plan.attachmentSummary,
                   let systemImage = plan.attachmentSystemImage
                {
                    HStack(spacing: 6) {
                        Image(systemName: systemImage)
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 20, height: 20)
                        Text(summary)
                            .font(.system(size: 16, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                    .frame(height: 20)
                }
            }
            .padding(.vertical, 4)
            Spacer(minLength: 0)
            if let media = plan.media {
                ForwardPreviewThumbnail(
                    media: media,
                    overflowCount: plan.mediaOverflowCount
                )
            }
        }
        .padding(.leading, 16)
        .frame(minHeight: 30, maxHeight: 56)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Message being forwarded: \(accessibilitySummary)")
    }

    private var accessibilitySummary: String {
        [plan.content, plan.attachmentSummary]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

private struct ForwardPreviewThumbnail: View {
    let media: ForwardPreviewMedia
    let overflowCount: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
            switch media.kind {
            case .image(let animated):
                if let url = media.url {
                    AnimatedRemoteImage(
                        url: url,
                        animates: animated,
                        maximumPixelDimension: 128,
                        contentMode: .fill
                    )
                }
            case .video:
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            case .audio:
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
            case .file:
                Image(systemName: "doc.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if overflowCount > 0 {
                Text("+\(overflowCount)")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(
                        Color(nsColor: .controlBackgroundColor).opacity(0.94),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
            }
        }
        .accessibilityHidden(true)
    }
}
