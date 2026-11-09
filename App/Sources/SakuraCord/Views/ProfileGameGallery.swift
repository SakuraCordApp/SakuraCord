import SakuraCordModels
import SwiftUI

struct ProfileGameGallery: View {
    let game: ProfileGame
    let present: (NativeTimelineMediaViewerPresentation) -> Void
    @State private var selectedIndex = 0
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    private var items: [RichMediaItem] {
        let trailers = (game.metadata?.trailers ?? []).compactMap { trailer -> RichMediaItem? in
            let base = "https://cdn.discordapp.com/app-assets/\(trailer.applicationID)/store/\(trailer.id)"
            let size = Self.supportedSize(Double(trailer.width) * displayScale)
            guard let url = URL(string: "\(base).mp4?size=\(size)"),
                  let preview = URL(string: "\(base).webp?size=\(size)") else { return nil }
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
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = components.host else { return url }
        var query = components.queryItems ?? []
        let size = String(Self.supportedSize(112 * displayScale))
        if ["images-ext-1.discordapp.net", "images-ext-2.discordapp.net"].contains(host), components.path.hasPrefix("/external/") {
            query.removeAll { ["format", "width", "height", "keep_aspect_ratio"].contains($0.name) }
            query += [URLQueryItem(name: "width", value: size), URLQueryItem(name: "height", value: size),
                      URLQueryItem(name: "keep_aspect_ratio", value: "true"), URLQueryItem(name: "format", value: "webp")]
        } else if host == "cdn.discordapp.com" || host == "media.discordapp.net" {
            query.removeAll { $0.name == "size" }
            query.append(URLQueryItem(name: "size", value: size))
        } else { return url }
        components.queryItems = query
        return components.url ?? url
    }

    static func supportedSize(_ size: Double) -> Int {
        [16, 20, 22, 24, 28, 32, 40, 44, 48, 56, 60, 64, 80, 96, 100, 128, 160, 240, 256, 300, 320, 480, 512, 600, 640, 1024, 1280, 1536, 2048, 3072, 4096].first { Double($0) >= size } ?? 4096
    }

    private func expand(_ index: Int) {
        present(NativeTimelineMediaViewerPresentation(items: items, selection: index, authorName: game.name,
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
