import SakuraCordModels
import SwiftUI

struct ProfileGameGallery: View {
    let game: ProfileGame
    let present: (MediaViewerPresentation) -> Void
    @State private var selectedIndex = 0
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    private var items: [RichMediaItem] {
        let trailers = (game.metadata?.trailers ?? []).compactMap { trailer -> RichMediaItem? in
            let assetID = "store/\(trailer.id)"
            let size = DiscordCDN.supportedSize(atLeast: Double(trailer.width) * displayScale)
            guard let url = DiscordCDN.applicationAsset(trailer.applicationID, assetID: assetID, fileExtension: "mp4", size: size),
                  let preview = DiscordCDN.applicationAsset(trailer.applicationID, assetID: assetID, fileExtension: "webp", size: size)
            else { return nil }
            return RichMediaItem(
                id: trailer.id,
                media: MessageEmbedMedia(url: url, proxyURL: preview, width: trailer.width, height: trailer.height, contentType: "video/mp4"),
                fallbackTitle: game.name
            )
        }
        let screenshots = (game.metadata?.screenshots ?? []).map { url in
            RichMediaItem(id: url.absoluteString, media: MessageEmbedMedia(url: url, contentType: "image/webp"), fallbackTitle: game.name)
        }
        return trailers + screenshots
    }

    var body: some View {
        if !items.isEmpty {
            VStack(spacing: InterfaceScale.metric(10)) {
                let index = min(selectedIndex, items.count - 1)
                let item = items[index]
                Group {
                    if item.kind == .video {
                        ViewerAVPlayer(url: item.url, autoplays: !reducesMotion, mutesOnStart: true, showsFullScreenToggleButton: true)
                    } else {
                        Button { expand(index) } label: {
                            ProfileWidgetImageView(url: item.url, contentMode: .fill)
                        }.buttonStyle(.plain).pointerStyle(.zoomIn).accessibilityLabel("Expand Screenshot")
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(.black.opacity(0.2))
                .clipShape(.rect(cornerRadius: ProfileGameMetrics.cardRadius))
                if items.count > 1 {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            HStack(spacing: InterfaceScale.metric(8)) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                                    ProfileGameGalleryThumbnail(url: thumbnail(item), isVideo: item.kind == .video, isSelected: index == offset) {
                                        selectedIndex = offset
                                    }
                                    .id(offset)
                                    .accessibilityLabel("\(item.kind == .video ? "Trailer" : "Screenshot") \(offset + 1)")
                                }
                            }
                        }
                        .scrollIndicators(.never)
                        .onChange(of: selectedIndex) { _, value in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(value, anchor: .center) } }
                    }
                }
            }
            .onChange(of: game.id) { _, _ in selectedIndex = 0 }
        }
    }

    private func thumbnail(_ item: RichMediaItem) -> URL {
        let url = item.kind == .video ? item.previewURL ?? item.url : item.url
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = components.host else { return url }
        let size = String(DiscordCDN.supportedSize(atLeast: 112 * displayScale))
        let resized: URL? = if ["images-ext-1.discordapp.net", "images-ext-2.discordapp.net"].contains(host), components.path.hasPrefix("/external/") {
            DiscordCDN.editingQuery(
                of: url, removing: ["format", "width", "height", "keep_aspect_ratio"],
                adding: [URLQueryItem(name: "width", value: size), URLQueryItem(name: "height", value: size),
                         URLQueryItem(name: "keep_aspect_ratio", value: "true"), URLQueryItem(name: "format", value: "webp")]
            )
        } else if host == "cdn.discordapp.com" || host == "media.discordapp.net" {
            DiscordCDN.editingQuery(of: url, removing: ["size"], adding: [URLQueryItem(name: "size", value: size)])
        } else { nil }
        return resized ?? url
    }

    private func expand(_ index: Int) {
        present(MediaViewerPresentation(items: items, selection: index, authorName: game.name,
                                                      authorAvatarURL: game.iconURL, timestamp: game.metadata?.releaseDate ?? .now))
    }
}

private struct ProfileGameGalleryThumbnail: View {
    let url: URL
    let isVideo: Bool
    let isSelected: Bool
    let select: () -> Void
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ProfileGameMetrics.thumbnailRadius)
        Button(action: select) {
            ProfileWidgetImageView(url: url, animates: false, contentMode: .fill)
                .frame(width: InterfaceScale.metric(112), height: InterfaceScale.metric(63))
                .clipped()
                .overlay {
                    if isVideo {
                        Image(systemName: "play.fill")
                            .font(.interfaceSystem(size: 11, weight: .bold)).foregroundStyle(.white)
                            .frame(width: InterfaceScale.metric(26), height: InterfaceScale.metric(26))
                            .background(.black.opacity(0.5), in: .circle)
                    }
                }
                .clipShape(shape)
                .opacity(isSelected || isHovered ? 1 : 0.55)
                .overlay { if isSelected { shape.strokeBorder(SakuraCordAccentColor.color, lineWidth: 2) } }
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onModalHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
