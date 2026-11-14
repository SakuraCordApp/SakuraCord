import AppKit
import SakuraCordModels

/// Warm only the current profile's visible artwork, using the same bounded caches as its views.
@MainActor
enum ProfilePreviewPreparation {
    static func preload(_ profile: UserProfile) async {
        await withTaskGroup(of: Void.self) { group in
            var sources = Set(profile.effect?.animations.map(\.sourceURL) ?? [])
            sources.formUnion([profile.effect?.reducedMotionURL, profile.effect?.staticURL, profile.effect?.thumbnailURL, profile.bannerURL].compactMap { $0 })
            sources.formUnion(widgetImageURLs(in: profile))
            for url in sources {
                group.addTask { await preload(url, maximumPixelDimension: nil) }
            }
            if let url = profile.bannerURL {
                group.addTask { await preload(url, maximumPixelDimension: ProfileBannerLayout.maximumPixelDimension) }
            }
            if let url = profile.user.nameplate?.staticURL {
                group.addTask { await preload(url, maximumPixelDimension: 512) }
            }
            // Match the hero and customization-card avatar renderers' cache keys.
            for size in [CGFloat(70), CGFloat(80)] {
                if let url = profile.avatarURL {
                    let pixels = AvatarView(name: "", url: url, size: size).requestedPixelDimension
                    group.addTask { await preloadAvatar(url, maximumPixelDimension: pixels) }
                }
                if let url = profile.user.avatarDecorationURL {
                    let pixels = DecoratedAvatarView(name: "", avatarURL: nil, decorationURL: url, size: size).decorationPixelDimension
                    group.addTask { await preload(url, maximumPixelDimension: pixels) }
                }
            }
            for layer in profile.frame?.layers ?? [] {
                group.addTask { await preload(layer.staticURL, maximumPixelDimension: 2048) }
            }
            let theme = ProfileThemeState()
            await theme.load(theme.source(for: profile, scale: NSScreen.main?.backingScaleFactor ?? 2, allowsTheme: true))
        }
    }

    private static func widgetImageURLs(in profile: UserProfile) -> Set<URL> {
        var urls = Set<URL>()
        for widget in profile.widgets ?? [] {
            switch widget.content {
            case let .personal(personal):
                for section in personal.sections {
                    switch section {
                    case let .cover(cover):
                        if let url = cover.image?.url { urls.insert(url) }
                    case let .fields(fields):
                        urls.formUnion(fields.compactMap { $0.image?.url })
                    }
                }
            case let .games(_, games):
                let ids = Set(games.map(\.id))
                urls.formUnion((profile.widgetResources?.games ?? []).filter { ids.contains($0.id) }.compactMap(\.coverURL))
            case let .application(id):
                urls.formUnion(applicationImageURLs(id: id, resources: profile.widgetResources))
            case .unrecognized: break
            }
        }
        return urls
    }

    private static func applicationImageURLs(id: String, resources: ProfileWidgetResources?) -> Set<URL> {
        guard let configuration = resources?.applications.first(where: { $0.applicationID == id && $0.isPublished }) else { return [] }
        let data = resources?.identities.first { $0.id == id }?.data ?? [:]
        var urls = Set([configuration.applicationIconURL].compactMap { $0 })
        for key in ["widget_top", "widget_bottom"] {
            for fields in configuration.surfaces[key]?.components.values ?? [:].values {
                for field in fields.values {
                    if case let .image(url, _, _) = field.resolve(data: data) { urls.insert(url) }
                }
            }
        }
        return urls
    }

    private static func preloadAvatar(_ url: URL, maximumPixelDimension: Int) async {
        guard !Task.isCancelled else { return }
        if UserAvatarPresentation.shouldDecodeAnimation(for: url) {
            await preload(url, maximumPixelDimension: maximumPixelDimension)
        } else {
            _ = await SharedDecodedImageLoader.shared.image(for: url, maximumPixelDimension: maximumPixelDimension, priority: .prefetch)
        }
    }

    private static func preload(_ url: URL, maximumPixelDimension: Int?) async {
        guard !Task.isCancelled,
              let image = try? await SharedAnimatedImageLoader.shared.image(for: url, maximumPixelDimension: maximumPixelDimension),
              !Task.isCancelled else { return }
        AnimatedRemoteImageDisplayCache.shared.insert(image, for: url, maximumPixelDimension: maximumPixelDimension)
    }
}
