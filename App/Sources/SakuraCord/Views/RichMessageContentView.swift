import AppKit
import AVKit
import Lottie
import MessageRendering
import SakuraCordModels
import SwiftUI

enum DiscordRichMessageMetrics {
    static let maximumWidth: CGFloat = 520
    static let cardCornerRadius: CGFloat = 8
    static let cardPadding: CGFloat = 12
}

nonisolated enum DiscordFittingWidthPlan {
    static func width(ideal: CGFloat, available: CGFloat?, maximum: CGFloat) -> CGFloat {
        min(max(0, ideal), max(0, available ?? maximum), maximum)
    }
}

struct DiscordFittingWidthLayout: Layout {
    let maximumWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let idealSize = subview.sizeThatFits(.unspecified)
        let width = DiscordFittingWidthPlan.width(
            ideal: idealSize.width,
            available: proposal.width,
            maximum: maximumWidth
        )
        let fittedSize = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: fittedSize.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

struct RichMessageContentView: View {
    let model: AppModel
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.type.hasGeneratedContent {
                SystemMessageContentView(message: message)
            }
            if message.flags.contains(.isComponentsV2) {
                MessageComponentsView(model: model, message: message)
            } else {
                if !message.type.hasGeneratedContent, !visibleContent.isEmpty {
                    DiscordMessageContentView(
                        model: model,
                        message: message,
                        content: visibleContent,
                        textOpacity: MessageOutboxPresentation.textOpacity(
                            for: message.outboxState
                        )
                    )
                }
                if !message.attachments.isEmpty {
                    MediaGalleryView(items: message.attachments.map(RichMediaItem.init))
                        .opacity(
                            MessageOutboxPresentation.mediaOpacity(for: message.outboxState)
                        )
                }
                ForEach(message.embeds.filter { MessageEmbedPresentation.kind(for: $0) != .hidden }) { embed in
                    MessageEmbedView(model: model, message: message, embed: embed, attachments: message.attachments)
                }
                if !message.components.isEmpty {
                    MessageComponentsView(model: model, message: message)
                }
            }
            if !message.stickers.isEmpty {
                MessageStickersView(stickers: message.stickers)
            }
            if let thread = message.thread {
                MessageThreadSummaryView(thread: thread, open: { model.open(thread) })
            }
        }
    }

    private var visibleContent: String {
        MessageEmbedPresentation.visibleMessageContent(message.content, embeds: message.embeds)
    }
}

enum MessageEmbedPresentationKind: Equatable {
    case hidden, bareMedia, card
}

enum MessageEmbedPresentation {
    static func kind(for embed: MessageEmbed) -> MessageEmbedPresentationKind {
        let type = embed.type?.lowercased()
        if type == "gifv" || type == "image" {
            return embed.image != nil || embed.video != nil ? .bareMedia : .hidden
        }
        let hasMedia = embed.image != nil || embed.video != nil
        let hasCardContent = embed.author != nil || embed.title != nil || embed.description != nil
            || !embed.fields.isEmpty || embed.footer != nil || embed.thumbnail != nil
        if !hasMedia, !hasCardContent {
            return .hidden
        }
        if hasMedia, !hasCardContent, embed.provider == nil {
            return .bareMedia
        }
        return .card
    }

    static func visibleMessageContent(_ content: String, embeds: [MessageEmbed]) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let rawURL = trimmed.hasPrefix("<") && trimmed.hasSuffix(">")
            ? String(trimmed.dropFirst().dropLast()) : trimmed
        guard let contentURL = URL(string: rawURL), contentURL.scheme != nil else { return content }
        let replacesLink = embeds.contains { embed in
            kind(for: embed) == .bareMedia && embed.url == contentURL
        }
        return replacesLink ? "" : content
    }
}

private struct SystemMessageContentView: View {
    let message: Message

    var body: some View {
        Label {
            Text(label)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
        }
        .font(.body)
        .accessibilityLabel(label)
    }

    private var label: String {
        let author = message.author.displayName
        switch message.type {
        case .recipientAdd:
            return "\(author) added someone to the conversation."
        case .recipientRemove:
            return "\(author) removed someone from the conversation."
        case .call:
            return "\(author) started a call."
        case .channelNameChange:
            return message.content.isEmpty
                ? "\(author) changed the channel name."
                : "\(author) changed the channel name to \(message.content)."
        case .channelIconChange:
            return "\(author) changed the channel icon."
        case .channelPinnedMessage:
            return "\(author) pinned a message to this channel."
        case .userJoin:
            return "Yay you made it, \(author)!"
        case .guildBoost:
            return "\(author) boosted the server!"
        case .guildBoostTier1:
            return "\(author) boosted the server to Level 1!"
        case .guildBoostTier2:
            return "\(author) boosted the server to Level 2!"
        case .guildBoostTier3:
            return "\(author) boosted the server to Level 3!"
        case .channelFollowAdd:
            return "\(author) added a followed channel."
        case .threadCreated:
            return "\(author) started a thread: \(message.content.isEmpty ? "Thread" : message.content)"
        case .guildInviteReminder:
            return "Wondering who to invite? Start by inviting anyone who can help this server grow."
        case .stageStart:
            return "\(author) started a Stage."
        case .stageEnd:
            return "\(author) ended the Stage."
        case .stageSpeaker:
            return "\(author) is now a speaker."
        case .stageTopic:
            return message.content.isEmpty ? "The Stage topic changed." : "Stage topic: \(message.content)"
        default:
            return message.content.isEmpty ? "Discord system message" : message.content
        }
    }

    private var icon: String {
        switch message.type {
        case .userJoin: "arrow.right"
        case .guildBoost, .guildBoostTier1, .guildBoostTier2, .guildBoostTier3: "sparkles"
        case .channelPinnedMessage: "pin.fill"
        case .call: "phone.fill"
        default: "info.circle.fill"
        }
    }

    private var iconColor: Color {
        message.type == .userJoin ? .green : .secondary
    }
}

struct RichMediaItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case image(animated: Bool)
        case video, audio, file
    }

    var id: String
    var url: URL
    var previewURL: URL?
    var title: String
    var description: String?
    var width: Int?
    var height: Int?
    var size: Int
    var kind: Kind
    var isSpoiler: Bool
    var autoplaysInline: Bool

    init(_ attachment: Attachment) {
        id = attachment.id
        url = attachment.url
        previewURL = attachment.proxyURL
        title = attachment.title ?? attachment.filename
        description = attachment.description
        width = attachment.width
        height = attachment.height
        size = attachment.size
        isSpoiler = attachment.isSpoiler
        autoplaysInline = false
        kind =
            switch attachment.mediaKind {
            case .image: .image(animated: false)
            case .animatedImage: .image(animated: true)
            case .video: .video
            case .audio: .audio
            case .file: .file
            }
    }

    init(
        id: String, media: MessageEmbedMedia, fallbackTitle: String,
        autoplaysInline: Bool = false
    ) {
        self.id = id
        url = media.url ?? URL(string: "about:blank")!
        previewURL = media.proxyURL
        title = fallbackTitle
        description = media.description
        width = media.width
        height = media.height
        size = 0
        let pathExtension = media.url?.pathExtension.lowercased()
        if media.contentType?.hasPrefix("video/") == true {
            kind = .video
        } else {
            kind = .image(
                animated: media.flags & 1 != 0 || pathExtension == "gif" || pathExtension == "apng"
            )
        }
        isSpoiler = false
        self.autoplaysInline = autoplaysInline
    }

    init(id: String, media: ComponentMedia, fallbackTitle: String) {
        self.init(
            id: id,
            media: MessageEmbedMedia(
                url: media.url, proxyURL: media.proxyURL, width: media.width, height: media.height,
                description: media.description, contentType: media.contentType,
                placeholder: media.placeholder, placeholderVersion: media.placeholderVersion,
                flags: media.flags ?? 0
            ),
            fallbackTitle: fallbackTitle
        )
        isSpoiler = media.isSpoiler
    }

    var aspectRatio: CGFloat {
        guard let width, let height, width > 0, height > 0 else { return 16 / 9 }
        return CGFloat(width) / CGFloat(height)
    }

    var intrinsicSize: CGSize? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }
}

struct MediaGalleryView: View {
    let items: [RichMediaItem]
    @State private var selection: Int?

    var body: some View {
        MediaMosaicLayout(spacing: 4) {
            ForEach(items.enumerated(), id: \.element.id) { index, item in
                MediaTile(item: item) { selection = index }
                    .layoutValue(key: MediaAspectRatioKey.self, value: item.aspectRatio)
                    .layoutValue(key: MediaIntrinsicSizeKey.self, value: item.intrinsicSize ?? .zero)
            }
        }
        .frame(maxWidth: 500, alignment: .leading)
        .sheet(isPresented: Binding(get: { selection != nil }, set: {
            if !$0 {
                selection = nil
            }
        })) {
            if let selection {
                MediaViewer(items: items, selection: selection) { self.selection = nil }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Media gallery, \(items.count) items")
    }
}

private nonisolated struct MediaAspectRatioKey: LayoutValueKey {
    static let defaultValue: CGFloat = 16 / 9
}

private nonisolated struct MediaIntrinsicSizeKey: LayoutValueKey {
    static let defaultValue = CGSize.zero
}

struct MediaMosaicLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(500, max(180, proposal.width ?? 500))
        let frames = frames(width: width, subviews: subviews)
        return CGSize(
            width: frames.map(\.maxX).max() ?? width,
            height: frames.map(\.maxY).max() ?? 0
        )
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        for (index, frame) in frames(width: bounds.width, subviews: subviews).enumerated()
            where subviews.indices.contains(index)
        {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let count = subviews.count
        guard count > 0 else { return [] }
        let ratios = subviews.map { $0[MediaAspectRatioKey.self] }
        let intrinsicSizes = subviews.map { $0[MediaIntrinsicSizeKey.self] }
        return MediaGalleryPlan.frames(
            count: count, width: width, aspectRatios: ratios, intrinsicSizes: intrinsicSizes,
            spacing: spacing
        )
    }
}

nonisolated enum MediaGalleryPlan {
    static func rowCounts(for count: Int) -> [Int] {
        switch count {
        case ...0: []
        case 1: [1]
        case 2: [2]
        case 3: [1, 2]
        case 4: [2, 2]
        case 5: [2, 3]
        case 6: [3, 3]
        case 7: [1, 3, 3]
        case 8: [2, 3, 3]
        case 9: [3, 3, 3]
        case 10: [1, 3, 3, 3]
        default: stride(from: 0, to: count, by: 3).map { min(3, count - $0) }
        }
    }

    static func frames(
        count: Int, width: CGFloat, aspectRatios: [CGFloat], intrinsicSizes: [CGSize] = [],
        spacing: CGFloat
    ) -> [CGRect]
    {
        guard count > 0 else { return [] }
        if count == 1 {
            if let intrinsicSize = intrinsicSizes.first,
               intrinsicSize.width > 0, intrinsicSize.height > 0
            {
                let scale = min(1, width / intrinsicSize.width, 350 / intrinsicSize.height)
                return [
                    CGRect(
                        x: 0, y: 0, width: intrinsicSize.width * scale,
                        height: intrinsicSize.height * scale
                    )
                ]
            }
            let ratio = max(0.2, min(12, aspectRatios.first ?? 16 / 9))
            let fittedWidth = min(width, 350 * ratio)
            let fittedHeight = min(350, fittedWidth / ratio)
            return [CGRect(x: 0, y: 0, width: fittedWidth, height: max(80, fittedHeight))]
        }
        if count == 3 {
            let height = min(300, max(190, width * 0.62))
            let heroWidth = (width - spacing) * 0.64
            let stackWidth = width - spacing - heroWidth
            return [
                CGRect(x: 0, y: 0, width: heroWidth, height: height),
                CGRect(x: heroWidth + spacing, y: 0, width: stackWidth, height: (height - spacing) / 2),
                CGRect(
                    x: heroWidth + spacing, y: (height + spacing) / 2, width: stackWidth,
                    height: (height - spacing) / 2
                )
            ]
        }
        var result: [CGRect] = []
        var y: CGFloat = 0
        for (rowIndex, columns) in rowCounts(for: count).enumerated() {
            let tileWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let hero = columns == 1 && (count == 7 || count == 10) && rowIndex == 0
            let height = hero ? min(240, max(150, width * 0.44)) : min(175, max(92, tileWidth * 0.72))
            for column in 0 ..< columns {
                result.append(
                    CGRect(x: CGFloat(column) * (tileWidth + spacing), y: y, width: tileWidth, height: height)
                )
            }
            y += height + spacing
        }
        return result
    }
}

private struct MediaTile: View {
    let item: RichMediaItem
    let open: () -> Void
    @State private var isRevealed = false
    @State private var isVisible = false

    var body: some View {
        Button(action: revealOrOpen) {
            ZStack {
                preview
                if item.isSpoiler, !isRevealed {
                    Rectangle().fill(.ultraThinMaterial)
                    Label("Spoiler", systemImage: "eye.slash.fill").font(.headline)
                }
                if case .video = item.kind, !item.autoplaysInline {
                    Image(systemName: "play.circle.fill").font(.system(size: 36)).shadow(radius: 3)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.description ?? item.title)
        .accessibilityLabel(item.description ?? item.title)
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            guard isVisible != visible else { return }
            isVisible = visible
        }
    }

    @ViewBuilder private var preview: some View {
        switch item.kind {
        case let .image(animated):
            AnimatedRemoteImage(
                url: item.previewURL ?? item.url,
                animates: isVisible && (!item.isSpoiler || isRevealed),
                isLooping: animated
            )
        case .video:
            if item.autoplaysInline {
                InlineLoopingVideo(
                    url: item.url,
                    isPlaying: isVisible && (!item.isSpoiler || isRevealed)
                )
            } else {
                Image(systemName: "film").resizable().scaledToFit().padding(30).foregroundStyle(.secondary)
            }
        case .audio:
            Label(item.title, systemImage: "waveform").padding()
        case .file:
            VStack(spacing: 8) {
                Image(systemName: "doc").font(.largeTitle)
                Text(item.title).lineLimit(2)
            }.padding()
        }
    }

    private func revealOrOpen() {
        if item.isSpoiler, !isRevealed {
            isRevealed = true
        } else {
            open()
        }
    }
}

private struct InlineLoopingVideo: NSViewRepresentable {
    let url: URL
    let isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("reduceAnimatedMedia") private var reduceAnimatedMedia = false

    func makeNSView(context: Context) -> PassiveAVPlayerView {
        let view = PassiveAVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ view: PassiveAVPlayerView, context: Context) {
        let shouldPlay = AnimatedMediaPlaybackPolicy.shouldPlay(
            isVisible: isPlaying,
            reduceMotion: reduceMotion,
            reduceAnimatedMedia: reduceAnimatedMedia
        )
        guard context.coordinator.url != url else {
            if shouldPlay {
                context.coordinator.player?.play()
            } else {
                context.coordinator.player?.pause()
            }
            return
        }
        context.coordinator.stop()
        view.player = nil
        guard shouldPlay else { return }
        let player = AVQueuePlayer()
        player.isMuted = true
        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        context.coordinator.url = url
        context.coordinator.player = player
        context.coordinator.looper = looper
        view.player = player
        player.play()
    }

    static func dismantleNSView(_ view: PassiveAVPlayerView, coordinator: Coordinator) {
        coordinator.stop()
        view.player = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var url: URL?
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?

        func stop() {
            player?.pause()
            player?.removeAllItems()
            looper = nil
            player = nil
            url = nil
        }
    }
}

private final class PassiveAVPlayerView: AVPlayerView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

private struct MediaViewer: View {
    let items: [RichMediaItem]
    @State var selection: Int
    let close: () -> Void
    @State private var imageScale: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(items[selection].title).font(.headline).lineLimit(1)
                Spacer()
                Text("\(selection + 1) of \(items.count)").foregroundStyle(.secondary)
                ShareLink(item: items[selection].url) { Image(systemName: "square.and.arrow.up") }.help(
                    "Share or copy link"
                )
                Link(destination: items[selection].url) { Image(systemName: "arrow.up.right.square") }.help(
                    "Open media"
                )
                Button(action: close) { Image(systemName: "xmark") }.keyboardShortcut(.cancelAction).help(
                    "Close"
                )
            }
            .buttonStyle(.borderless)
            .padding()
            Divider()
            ZStack {
                Color.black.opacity(0.92)
                viewerContent
                HStack {
                    Button {
                        move(-1)
                    } label: {
                        Image(systemName: "chevron.left.circle.fill").font(.largeTitle)
                    }.disabled(selection == 0)
                    Spacer()
                    Button {
                        move(1)
                    } label: {
                        Image(systemName: "chevron.right.circle.fill").font(.largeTitle)
                    }.disabled(selection == items.count - 1)
                }.buttonStyle(.plain).padding()
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .onKeyPress(.leftArrow) {
            move(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            move(1)
            return .handled
        }
        .accessibilityLabel(
            "\(items[selection].description ?? items[selection].title), item \(selection + 1) of \(items.count)"
        )
    }

    @ViewBuilder private var viewerContent: some View {
        let item = items[selection]
        switch item.kind {
        case let .image(animated):
            AnimatedRemoteImage(url: item.url, isLooping: animated)
                .scaleEffect(imageScale)
                .gesture(MagnifyGesture().onChanged { imageScale = max(0.5, min(6, $0.magnification)) })
                .padding(50)
        case .video, .audio:
            ViewerAVPlayer(url: item.url).padding(50)
        case .file:
            Link(destination: item.url) { Label("Open \(item.title)", systemImage: "doc") }.font(.title2)
        }
    }

    private func move(_ delta: Int) {
        selection = min(items.count - 1, max(0, selection + delta))
        imageScale = 1
        NSAccessibility.post(
            element: NSApplication.shared, notification: .announcementRequested,
            userInfo: [.announcement: "Item \(selection + 1) of \(items.count)"]
        )
    }
}

private struct ViewerAVPlayer: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.player?.pause()
        let player = AVPlayer(url: url)
        context.coordinator.url = url
        context.coordinator.player = player
        view.player = player
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.player?.pause()
        view.player = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var url: URL?
        var player: AVPlayer?
    }
}

private struct MessageEmbedView: View {
    let model: AppModel
    let message: Message
    let embed: MessageEmbed
    let attachments: [Attachment]

    @ViewBuilder var body: some View {
        switch MessageEmbedPresentation.kind(for: embed) {
        case .hidden:
            EmptyView()
        case .bareMedia:
            if let mediaItem {
                MediaGalleryView(items: [mediaItem])
            }
        case .card:
            MessageEmbedCard(
                model: model,
                message: message,
                embed: embed,
                mediaItem: mediaItem
            )
        }
    }

    private var mediaItem: RichMediaItem? {
        guard var media = embed.image ?? embed.video else { return nil }
        if let raw = media.url?.absoluteString, raw.hasPrefix("attachment://"),
           let attachment = attachments.first(where: {
               $0.filename == String(raw.dropFirst("attachment://".count))
           })
        {
            return RichMediaItem(attachment)
        }
        guard media.url != nil else { return nil }
        if embed.video != nil {
            media.contentType = "video/unknown"
            if media.width == nil {
                media.width = embed.thumbnail?.width ?? embed.image?.width
            }
            if media.height == nil {
                media.height = embed.thumbnail?.height ?? embed.image?.height
            }
        }
        return RichMediaItem(
            id: "\(embed.id)-media", media: media, fallbackTitle: embed.title ?? "Embed media",
            autoplaysInline: embed.type?.lowercased() == "gifv"
        )
    }
}

private struct MessageEmbedCard: View {
    let model: AppModel
    let message: Message
    let embed: MessageEmbed
    let mediaItem: RichMediaItem?

    var body: some View {
        DiscordFittingWidthLayout(maximumWidth: DiscordRichMessageMetrics.maximumWidth) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(accentColor)
                    .frame(width: 4)
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .top, spacing: 12) {
                        MessageEmbedTextColumn(model: model, message: message, embed: embed)
                        Spacer(minLength: 0)
                        if let thumbnail = embed.thumbnail {
                            MessageEmbedThumbnail(media: thumbnail, title: embed.title)
                        }
                    }
                    if let mediaItem {
                        MediaGalleryView(items: [mediaItem])
                    }
                    if embed.footer != nil || embed.timestamp != nil {
                        MessageEmbedFooterLine(footer: embed.footer, timestamp: embed.timestamp)
                    }
                }
                .padding(DiscordRichMessageMetrics.cardPadding)
            }
            .background(Color.secondary.opacity(0.08))
            .clipShape(
                RoundedRectangle(
                    cornerRadius: DiscordRichMessageMetrics.cardCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: DiscordRichMessageMetrics.cardCornerRadius,
                    style: .continuous
                )
                .strokeBorder(Color.primary.opacity(0.08))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var accentColor: Color {
        guard let value = embed.color else { return .secondary.opacity(0.5) }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

private struct MessageEmbedTextColumn: View {
    let model: AppModel
    let message: Message
    let embed: MessageEmbed

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let author = embed.author {
                MessageEmbedAuthorLine(author: author)
            }
            if let title = embed.title {
                linkedText(title, destination: embed.url)
                    .font(.headline)
            }
            if let description = embed.description {
                CustomEmojiRichText(
                    model: model,
                    content: description,
                    emojiSize: 18,
                    mentionPresentation: MessageMentionResolver(model: model, message: message).presentation
                )
            }
            if !embed.fields.isEmpty {
                EmbedFieldsView(model: model, message: message, fields: embed.fields)
            }
            if let provider = embed.provider?.name {
                Text(provider)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func linkedText(_ value: String, destination: URL?) -> some View {
        if let destination {
            Link(value, destination: destination)
        } else {
            Text(value)
        }
    }
}

private struct MessageEmbedAuthorLine: View {
    let author: MessageEmbedAuthor

    var body: some View {
        HStack(spacing: 6) {
            if let iconURL = author.proxyIconURL ?? author.iconURL {
                AnimatedRemoteImage(
                    url: iconURL,
                    isLooping: false,
                    fallbackSystemImage: "person.crop.circle"
                )
                    .frame(width: 20, height: 20)
                    .clipShape(Circle())
            }
            if let destination = author.url {
                Link(author.name, destination: destination)
            } else {
                Text(author.name)
            }
        }
        .font(.caption.weight(.semibold))
    }
}

private struct MessageEmbedThumbnail: View {
    let media: MessageEmbedMedia
    let title: String?

    var body: some View {
        if let url = media.proxyURL ?? media.url {
            AnimatedRemoteImage(url: url, isLooping: false, fallbackSystemImage: "photo")
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help(media.description ?? title ?? "Embed thumbnail")
                .accessibilityLabel(media.description ?? title ?? "Embed thumbnail")
        }
    }
}

private struct MessageEmbedFooterLine: View {
    let footer: MessageEmbedFooter?
    let timestamp: Date?

    var body: some View {
        HStack(spacing: 5) {
            if let iconURL = footer.flatMap({ $0.proxyIconURL ?? $0.iconURL }) {
                AnimatedRemoteImage(
                    url: iconURL,
                    isLooping: false,
                    fallbackSystemImage: "photo.circle"
                )
                    .frame(width: 18, height: 18)
                    .clipShape(Circle())
            }
            if let footer {
                Text(footer.text)
            }
            if let timestamp {
                if footer != nil {
                    Text("•")
                }
                Text(timestamp, style: .time)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct EmbedFieldsView: View {
    let model: AppModel
    let message: Message
    let fields: [MessageEmbedField]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            ForEach(EmbedFieldLayoutPlan.rows(for: fields)) { row in
                GridRow {
                    ForEach(row.fields) { field in
                        fieldView(field)
                            .gridCellColumns(field.isInline ? 1 : 3)
                    }
                }
            }
        }
    }

    private func fieldView(_ field: MessageEmbedField) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.name).font(.caption.bold())
            CustomEmojiRichText(
                model: model, content: field.value, emojiSize: 16,
                mentionPresentation: MessageMentionResolver(model: model, message: message).presentation
            ).font(.caption)
        }
    }
}

nonisolated struct EmbedFieldLayoutRow: Identifiable, Equatable {
    let id: Int
    let fields: [MessageEmbedField]
}

nonisolated enum EmbedFieldLayoutPlan {
    static func rows(for fields: [MessageEmbedField]) -> [EmbedFieldLayoutRow] {
        var rows: [EmbedFieldLayoutRow] = []
        var inlineFields: [MessageEmbedField] = []

        func flushInlineFields() {
            while !inlineFields.isEmpty {
                let rowFields = Array(inlineFields.prefix(3))
                rows.append(EmbedFieldLayoutRow(id: rowFields[0].id, fields: rowFields))
                inlineFields.removeFirst(rowFields.count)
            }
        }

        for field in fields {
            if field.isInline {
                inlineFields.append(field)
                if inlineFields.count == 3 {
                    flushInlineFields()
                }
            } else {
                flushInlineFields()
                rows.append(EmbedFieldLayoutRow(id: field.id, fields: [field]))
            }
        }
        flushInlineFields()
        return rows
    }
}

private struct MessageComponentsView: View {
    let model: AppModel
    let message: Message
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(message.components) {
                ComponentNodeView(model: model, message: message, component: $0)
            }
            if let error = model.componentError(for: message.id) {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
            }
        }
    }
}

private struct ComponentNodeView: View {
    let model: AppModel
    let message: Message
    let component: MessageComponent
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch component {
        case let .actionRow(_, children):
            HStack(spacing: 8) {
                ForEach(children) { ComponentNodeView(model: model, message: message, component: $0) }
            }
        case let .button(_, style, label, emoji, customID, url, _, disabled):
            if let url {
                DiscordComponentButton(
                    style: style ?? .link, label: label, emoji: emoji, showsExternalLink: true,
                    action: { openURL(url) }
                )
            } else {
                DiscordComponentButton(
                    style: style, label: label, emoji: emoji, showsExternalLink: false,
                    action: { activate(customID, kind: .button) }
                )
                .disabled(
                    disabled || style == .premium || !model.supportsCapability(.components)
                        || customID == nil
                        || customID.map {
                            model.isComponentPending(messageID: message.id, customID: $0)
                        } == true
                )
                .help(componentButtonHelp(style: style))
            }
        case let .select(_, kind, customID, placeholder, _, _, disabled, options, _):
            DiscordComponentSelect(
                placeholder: placeholder ?? "Select an option…", options: options,
                isDisabled: disabled || !model.supportsCapability(.components)
                    || model.isComponentPending(messageID: message.id, customID: customID)
                    || options.isEmpty
            ) { option in
                activate(customID, kind: interactionKind(kind), values: [option.value])
            }
        case let .section(_, children, accessory):
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    ForEach(children) { ComponentNodeView(model: model, message: message, component: $0) }
                }
                if let accessory {
                    ComponentNodeView(model: model, message: message, component: accessory)
                }
            }
        case let .textDisplay(_, content):
            CustomEmojiRichText(
                model: model, content: content, emojiSize: 18,
                mentionPresentation: MessageMentionResolver(model: model, message: message).presentation
            )
        case let .thumbnail(_, media):
            if let item = resolve(media, id: component.id) {
                ComponentThumbnailView(item: item)
            } else {
                unavailableMediaLabel
            }
        case let .mediaGallery(_, items): MediaGalleryView(items: items.compactMap(resolve))
        case let .file(_, media):
            if let item = resolve(media, id: component.id) {
                ComponentFileAttachment(item: item)
            } else {
                unavailableMediaLabel
            }
        case let .separator(_, divider, spacing):
            if divider {
                Divider().padding(.vertical, spacing == 2 ? 6 : 1)
            } else {
                Color.clear.frame(height: spacing == 2 ? 12 : 6)
            }
        case let .container(_, accent, spoiler, children):
            DiscordComponentContainerView(
                model: model, message: message, accent: accent, spoiler: spoiler, children: children
            )
        case let .unsupported(_, type, label):
            Label(label ?? "Unsupported component \(type)", systemImage: "questionmark.square.dashed")
                .font(.caption).foregroundStyle(.secondary).accessibilityLabel(
                    "Unsupported message component"
                )
        }
    }

    private var unavailableMediaLabel: some View {
        Label("Media unavailable", systemImage: "photo.badge.exclamationmark")
            .foregroundStyle(.secondary)
    }

    private func resolve(_ gallery: ComponentGalleryItem) -> RichMediaItem? {
        resolve(gallery.media, id: gallery.id)
    }

    private func resolve(_ media: ComponentMedia, id: String) -> RichMediaItem? {
        if let name = media.attachmentName,
           let attachment = message.attachments.first(where: { $0.filename == name || $0.id == name })
        {
            var item = RichMediaItem(attachment)
            if let description = media.description {
                item.description = description
            }
            item.isSpoiler = item.isSpoiler || media.isSpoiler
            return item
        }
        guard media.url != nil else { return nil }
        return RichMediaItem(
            id: id, media: media,
            fallbackTitle: media.description ?? "Component media"
        )
    }

    private func activate(_ customID: String?, kind: ComponentInteractionKind, values: [String] = []) {
        guard let customID else { return }
        Task {
            await model.submitComponent(on: message, customID: customID, kind: kind, values: values)
        }
    }

    private func interactionKind(_ kind: ComponentSelectKind) -> ComponentInteractionKind {
        switch kind {
        case .string: .stringSelect
        case .user: .userSelect
        case .role: .roleSelect
        case .mentionable: .mentionableSelect
        case .channel: .channelSelect
        }
    }

    private func componentButtonHelp(style: ComponentButtonStyle?) -> String {
        if style == .premium {
            return "Premium purchases are unavailable in SakuraCord"
        }
        if !model.supportsCapability(.components) {
            return "Message interactions are unavailable for this account session"
        }
        return ""
    }
}

nonisolated enum DiscordComponentContainerAppearance {
    struct RGB: Equatable {
        let red: Double
        let green: Double
        let blue: Double
    }

    static func accent(_ value: UInt32?) -> RGB? {
        guard let value else { return nil }
        return RGB(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

nonisolated enum DiscordComponentContainerLayoutPlan {
    static func width(
        idealContent: CGFloat,
        available: CGFloat?,
        maximum: CGFloat,
        padding: CGFloat,
        hasAccent: Bool
    ) -> CGFloat {
        let fixedWidth = padding * 2 + (hasAccent ? 4 : 0)
        return DiscordFittingWidthPlan.width(
            ideal: idealContent + fixedWidth,
            available: available,
            maximum: maximum
        )
    }
}

struct DiscordComponentContainerLayout: Layout {
    let maximumWidth: CGFloat
    let padding: CGFloat
    let hasAccent: Bool

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let content = subviews.last else { return .zero }
        let idealContent = content.sizeThatFits(.unspecified)
        let width = DiscordComponentContainerLayoutPlan.width(
            idealContent: idealContent.width,
            available: proposal.width,
            maximum: maximumWidth,
            padding: padding,
            hasAccent: hasAccent
        )
        let contentSize = content.sizeThatFits(
            ProposedViewSize(width: contentWidth(for: width), height: nil)
        )
        return CGSize(width: width, height: contentSize.height + padding * 2)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let content = subviews.last else { return }
        if hasAccent, let accent = subviews.first, subviews.count > 1 {
            accent.place(
                at: bounds.origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: 4, height: bounds.height)
            )
        }
        let leading = hasAccent ? 4 : 0
        content.place(
            at: CGPoint(x: bounds.minX + CGFloat(leading) + padding, y: bounds.minY + padding),
            anchor: .topLeading,
            proposal: ProposedViewSize(
                width: contentWidth(for: bounds.width),
                height: max(0, bounds.height - padding * 2)
            )
        )
    }

    private func contentWidth(for width: CGFloat) -> CGFloat {
        max(0, width - padding * 2 - (hasAccent ? 4 : 0))
    }
}

private struct DiscordComponentContainerView: View {
    let model: AppModel
    let message: Message
    let accent: UInt32?
    let spoiler: Bool
    let children: [MessageComponent]
    @State private var spoilerRevealed = false

    var body: some View {
        DiscordComponentContainerLayout(
            maximumWidth: DiscordRichMessageMetrics.maximumWidth,
            padding: DiscordRichMessageMetrics.cardPadding,
            hasAccent: accentRGB != nil
        ) {
            if let accentRGB {
                Rectangle()
                    .fill(Color(red: accentRGB.red, green: accentRGB.green, blue: accentRGB.blue))
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(children) {
                    ComponentNodeView(model: model, message: message, component: $0)
                }
            }
        }
        .background(Color.primary.opacity(0.055))
        .clipShape(
            RoundedRectangle(
                cornerRadius: DiscordRichMessageMetrics.cardCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: DiscordRichMessageMetrics.cardCornerRadius,
                style: .continuous
            )
            .strokeBorder(Color.primary.opacity(0.13))
        }
        .overlay {
            if spoiler, !spoilerRevealed {
                Button("Reveal spoiler") { spoilerRevealed = true }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.ultraThinMaterial)
            }
        }
    }

    private var accentRGB: DiscordComponentContainerAppearance.RGB? {
        DiscordComponentContainerAppearance.accent(accent)
    }
}

private struct ComponentThumbnailView: View {
    let item: RichMediaItem
    @State private var isRevealed = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if item.isSpoiler, !isRevealed {
                isRevealed = true
            } else {
                openURL(item.url)
            }
        } label: {
            ZStack {
                AnimatedRemoteImage(
                    url: item.previewURL ?? item.url,
                    isLooping: false,
                    fallbackSystemImage: "photo"
                )
                if item.isSpoiler, !isRevealed {
                    Rectangle().fill(.ultraThinMaterial)
                    Image(systemName: "eye.slash.fill")
                }
            }
            .frame(width: 80, height: 80)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(item.description ?? item.title)
        .accessibilityLabel(item.description ?? item.title)
    }
}

private struct ComponentFileAttachment: View {
    let item: RichMediaItem
    @State private var isRevealed = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        DiscordFittingWidthLayout(maximumWidth: DiscordRichMessageMetrics.maximumWidth) {
            Button {
                if item.isSpoiler, !isRevealed {
                    isRevealed = true
                } else {
                    openURL(item.url)
                }
            } label: {
                ZStack {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            if let description = item.description, !description.isEmpty {
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 12)
                        Image(systemName: "arrow.down.circle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)

                    if item.isSpoiler, !isRevealed {
                        RoundedRectangle(
                            cornerRadius: DiscordRichMessageMetrics.cardCornerRadius,
                            style: .continuous
                        )
                        .fill(.ultraThinMaterial)
                        Label("Spoiler", systemImage: "eye.slash.fill")
                            .font(.callout.weight(.semibold))
                    }
                }
                .background(Color.primary.opacity(0.055))
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: DiscordRichMessageMetrics.cardCornerRadius,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: DiscordRichMessageMetrics.cardCornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(Color.primary.opacity(0.13))
                }
            }
            .buttonStyle(.plain)
            .help(item.isSpoiler && !isRevealed ? "Reveal spoiler" : "Open \(item.title)")
            .accessibilityLabel(item.isSpoiler && !isRevealed ? "Reveal spoiler file" : "Open \(item.title)")
        }
    }
}

private struct MessageStickersView: View {
    let stickers: [MessageSticker]
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(stickers) { sticker in
                if let url = sticker.mediaURL {
                    Group {
                        if sticker.format == .lottie {
                            RemoteLottieSticker(url: url)
                        } else {
                            AnimatedRemoteImage(url: url, isLooping: true)
                        }
                    }
                        .frame(width: 112, height: 112)
                        .clipped()
                        .help(sticker.name)
                        .accessibilityLabel(sticker.name)
                } else {
                    Label(sticker.name, systemImage: "face.dashed")
                }
            }
        }
    }
}

private struct RemoteLottieSticker: View {
    let url: URL
    @State private var animation: LottieAnimation?

    var body: some View {
        Group {
            if let animation {
                LottieStickerCanvas(animation: animation)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task(id: url) {
            animation = await LottieAnimation.loadedFrom(url: url)
        }
    }
}

private struct LottieStickerCanvas: NSViewRepresentable {
    let animation: LottieAnimation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> LottieStickerContainer {
        LottieStickerContainer(animation: animation)
    }

    func updateNSView(_ view: LottieStickerContainer, context: Context) {
        view.display(animation, reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_ view: LottieStickerContainer, coordinator: ()) {
        view.animationView.stop()
    }
}

private final class LottieStickerContainer: NSView {
    let animationView: LottieAnimationView

    init(animation: LottieAnimation) {
        animationView = LottieAnimationView(animation: animation)
        super.init(frame: .zero)
        animationView.contentMode = .scaleAspectFit
        animationView.loopMode = .loop
        animationView.frame = bounds
        animationView.autoresizingMask = [.width, .height]
        addSubview(animationView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        animationView.frame = bounds
        animationView.needsLayout = true
        animationView.layoutSubtreeIfNeeded()
    }

    func display(_ animation: LottieAnimation, reduceMotion: Bool) {
        if animationView.animation !== animation {
            animationView.animation = animation
        }
        animationView.loopMode = .loop
        if reduceMotion {
            animationView.pause()
            animationView.currentProgress = 0
        } else if !animationView.isAnimationPlaying {
            animationView.play()
        }
    }
}

private struct MessageThreadSummaryView: View {
    let thread: MessageThreadSummary
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack {
                Image(systemName: "bubble.left.and.bubble.right")
                VStack(alignment: .leading) {
                    Text(thread.name).font(.subheadline.weight(.semibold))
                    Text("\(thread.messageCount) replies · \(thread.memberCount) participants").font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
            }.padding(9).frame(maxWidth: 500).background(
                Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)
            )
        }.buttonStyle(.plain).accessibilityElement(children: .combine).accessibilityLabel(
            "Open thread \(thread.name), \(thread.messageCount) replies"
        )
    }
}
