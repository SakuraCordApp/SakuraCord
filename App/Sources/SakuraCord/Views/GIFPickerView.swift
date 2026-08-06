import SakuraCordModels
import SwiftUI

nonisolated enum GIFPickerPage: Equatable {
    case landing
    case favorites
    case trending
    case search(String)

    var returnsToLandingOnEscape: Bool {
        self != .landing
    }
}

nonisolated struct GIFMasonryItem: Identifiable {
    let result: GIFSearchResult
    let height: CGFloat
    let ordinal: Int

    var id: String { result.id }
}

nonisolated struct GIFMasonryColumns {
    let leading: [GIFMasonryItem]
    let trailing: [GIFMasonryItem]
}

nonisolated enum GIFMasonryLayout {
    static let spacing: CGFloat = 10

    static func columns(
        for results: [GIFSearchResult],
        columnWidth: CGFloat
    ) -> GIFMasonryColumns {
        var leading: [GIFMasonryItem] = []
        var trailing: [GIFMasonryItem] = []
        var leadingHeight: CGFloat = 0
        var trailingHeight: CGFloat = 0

        for (ordinal, result) in results.enumerated() {
            let width = CGFloat(max(1, result.width ?? 1))
            let sourceHeight = CGFloat(max(1, result.height ?? 1))
            let height = columnWidth * sourceHeight / width
            let item = GIFMasonryItem(
                result: result,
                height: height,
                ordinal: ordinal
            )
            if leadingHeight <= trailingHeight {
                leading.append(item)
                leadingHeight += height + spacing
            } else {
                trailing.append(item)
                trailingHeight += height + spacing
            }
        }
        return GIFMasonryColumns(leading: leading, trailing: trailing)
    }
}

nonisolated enum GIFPickerMediaPolicy {
    private static let videoExtensions = ["webm", "mp4"]

    static func isVideo(
        _ url: URL,
        declaredKind: GIFMediaKind? = nil
    ) -> Bool {
        declaredKind == .video
            || videoExtensions.contains(url.pathExtension.lowercased())
    }

    static func nativeAnimationURL(for gif: GIFSearchResult) -> URL? {
        nativeAnimationURLs(for: gif).first
    }

    static func nativeAnimationURLs(for gif: GIFSearchResult) -> [URL] {
        var candidates: [URL] = []
        for candidate in [gif.previewURL, gif.mediaURL].compactMap(\.self) {
            if isVideo(
                candidate,
                declaredKind: candidate == gif.mediaURL ? gif.mediaKind : nil
            ) {
                if let alternate = alternateURL(
                    for: candidate,
                    pathExtension: "gif",
                    tenorFormatSuffix: "AM"
                ) {
                    candidates.append(alternate)
                }
            } else {
                candidates.append(candidate)
            }
        }
        return candidates.reduce(into: []) { unique, candidate in
            if !unique.contains(candidate) { unique.append(candidate) }
        }
    }

    static func nativeVideoURL(for gif: GIFSearchResult) -> URL? {
        guard let source = gif.mediaURL,
              isVideo(source, declaredKind: gif.mediaKind)
        else { return nil }
        switch source.pathExtension.lowercased() {
        case "webm":
            return alternateURL(
                for: source,
                pathExtension: "mp4",
                tenorFormatSuffix: tenorMP4Suffix(for: source)
            )
        case "mp4", "":
            return source
        default:
            return nil
        }
    }

    static func staticFallbackURL(for gif: GIFSearchResult) -> URL? {
        let candidates = [gif.thumbnailURL, gif.previewURL, gif.mediaURL]
            .compactMap(\.self)
        return candidates.first { candidate in
            !isVideo(
                candidate,
                declaredKind: candidate == gif.mediaURL ? gif.mediaKind : nil
            )
        }
    }

    private static func tenorMP4Suffix(for url: URL) -> String? {
        guard isTenor(url),
              let mediaID = mediaID(in: url)
        else { return nil }
        if mediaID.hasSuffix("P3") { return "P1" }
        if mediaID.hasSuffix("P4") { return "P2" }
        return "Po"
    }

    private static func alternateURL(
        for source: URL,
        pathExtension: String,
        tenorFormatSuffix: String?
    ) -> URL? {
        guard var components = URLComponents(
            url: source,
            resolvingAgainstBaseURL: false
        ) else { return nil }
        var pathComponents = components.percentEncodedPath.split(
            separator: "/",
            omittingEmptySubsequences: true
        ).map(String.init)
        guard !pathComponents.isEmpty else { return nil }

        if let tenorFormatSuffix,
           isTenor(source),
           pathComponents.count >= 2
        {
            let mediaIndex = pathComponents.index(before: pathComponents.endIndex - 1)
            let mediaID = pathComponents[mediaIndex]
            if knownTenorVideoSuffixes.contains(where: mediaID.hasSuffix) {
                pathComponents[mediaIndex] = String(mediaID.dropLast(2))
                    + tenorFormatSuffix
            }
        }

        let filename = pathComponents[pathComponents.index(before: pathComponents.endIndex)]
        guard let alternateFilename = ((filename as NSString)
            .deletingPathExtension as NSString)
            .appendingPathExtension(pathExtension)
        else { return nil }
        pathComponents[pathComponents.index(before: pathComponents.endIndex)] =
            alternateFilename
        components.percentEncodedPath = "/" + pathComponents.joined(separator: "/")
        return components.url
    }

    private static let knownTenorVideoSuffixes = [
        "Ps", "P3", "P4", "Po", "P1", "P2",
    ]

    private static func mediaID(in url: URL) -> String? {
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return nil }
        return components[components.index(before: components.endIndex - 1)]
    }

    private static func isTenor(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "tenor.com"
            || host.hasSuffix(".tenor.com")
            || host == "tenor.co"
            || host.hasSuffix(".tenor.co")
    }
}

struct GIFPickerView: View {
    let model: AppModel
    let dismiss: () -> Void

    @State private var page: GIFPickerPage = .landing
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GIFPickerHeader(
                text: $query,
                showsBackButton: page != .landing,
                back: showLanding
            )
            .padding(12)

            Divider()

            if page == .landing {
                landing
            } else {
                resultsPage
            }
        }
        .frame(width: ChatChromeMetrics.emojiPickerWidth, height: 420)
        .task {
            model.loadGIFPicker()
        }
        .onChange(of: query, handleQueryChange)
        .onExitCommand(perform: handleEscapeCommand)
    }

    private func handleQueryChange(_ oldValue: String, _ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            if case .search = page { page = .landing }
            return
        }
        page = .search(normalized)
        model.searchGIFs(normalized)
    }

    private var landing: some View {
        ScrollView {
            Grid(
                horizontalSpacing: GIFMasonryLayout.spacing,
                verticalSpacing: GIFMasonryLayout.spacing
            ) {
                GridRow {
                    GIFCategoryButton(
                        title: "Favourites",
                        systemImage: "star.fill",
                        previewURL: model.favoriteGIFs.first?.previewURL
                    ) {
                        page = .favorites
                    }
                    GIFCategoryButton(
                        title: "Trending GIFs",
                        systemImage: "arrow.up.right",
                        previewURL: model.gifTrendingPreviewURL
                    ) {
                        page = .trending
                        model.searchGIFs("")
                    }
                }
                ForEach(categoryRowStarts, id: \.self) { start in
                    GridRow {
                        categoryButton(model.gifCategories[start])
                        if model.gifCategories.indices.contains(start + 1) {
                            categoryButton(model.gifCategories[start + 1])
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity, minHeight: 102)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
        .scrollIndicators(.hidden)
        .overlay {
            if model.isLoadingGIFPicker, model.gifCategories.isEmpty {
                ProgressView().controlSize(.small)
            } else if let error = model.gifErrorMessage, model.gifCategories.isEmpty {
                GIFPickerStatus(message: error, retry: model.loadGIFPicker)
            }
        }
    }

    private var categoryRowStarts: [Int] {
        Array(stride(from: 0, to: model.gifCategories.count, by: 2))
    }

    private func categoryButton(_ category: GIFPickerCategory) -> some View {
        GIFCategoryButton(
            title: category.name,
            systemImage: nil,
            previewURL: category.previewURL
        ) {
            query = category.query
        }
    }

    private var resultsPage: some View {
        GeometryReader { geometry in
            let available = max(1, geometry.size.width - 24 - GIFMasonryLayout.spacing)
            let columnWidth = available / 2
            GIFPickerNativeGrid(
                results: visibleResults,
                columnWidth: columnWidth,
                favorites: favoriteURLs,
                mutatingURL: model.gifFavoriteMutationURL,
                choose: choose,
                toggleFavorite: toggleFavorite
            )
            .overlay {
                if model.isLoadingGIFs, visibleResults.isEmpty {
                    ProgressView().controlSize(.small)
                } else if let error = model.gifErrorMessage, visibleResults.isEmpty {
                    GIFPickerStatus(message: error, retry: retryCurrentPage)
                } else if visibleResults.isEmpty {
                    ContentUnavailableView(
                        page == .favorites ? "No favourite GIFs" : "No GIFs found",
                        systemImage: page == .favorites ? "star" : "rectangle.stack"
                    )
                }
            }
        }
    }

    private var visibleResults: [GIFSearchResult] {
        switch page {
        case .favorites:
            model.favoriteGIFs
        case .trending, .search:
            model.gifResults
        case .landing:
            []
        }
    }

    private var favoriteURLs: Set<URL> {
        Set(model.favoriteGIFs.map(\.url))
    }

    private func showLanding() {
        query = ""
        page = .landing
    }

    private func handleEscapeCommand() {
        if page.returnsToLandingOnEscape {
            showLanding()
        } else {
            dismiss()
        }
    }

    private func retryCurrentPage() {
        switch page {
        case .landing, .favorites:
            model.loadGIFPicker()
        case .trending:
            model.searchGIFs("")
        case let .search(value):
            model.searchGIFs(value)
        }
    }

    private func choose(_ gif: GIFSearchResult) {
        Task {
            if await model.sendGIF(gif) { dismiss() }
        }
    }

    private func toggleFavorite(_ gif: GIFSearchResult) {
        model.setGIFFavorite(gif, isFavorite: !favoriteURLs.contains(gif.url))
    }
}

private struct GIFPickerHeader: View {
    @Binding var text: String
    let showsBackButton: Bool
    let back: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if showsBackButton {
                Button(action: back) {
                    ZStack {
                        Color.clear
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(width: 38, height: 38)
                    .contentShape(
                        ConcentricRectangle(cornerRadius: 12, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .glassEffect(
                    .regular.interactive(),
                    in: ConcentricRectangle(cornerRadius: 12, style: .continuous)
                )
                .help("All GIF categories")
            }
            GIFPickerSearchField(text: $text)
        }
    }
}

private struct GIFPickerSearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search GIFs", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 38)
        .glassEffect(
            .regular.interactive(),
            in: ConcentricRectangle(cornerRadius: 12, style: .continuous)
        )
        .task { isFocused = true }
    }
}

private struct GIFCategoryButton: View {
    let title: String
    let systemImage: String?
    let previewURL: URL?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Color.primary.opacity(0.06)
                if let previewURL {
                    ZStack {
                        // Keep a decoded first frame mounted underneath the
                        // animation so categories never flash empty while the
                        // animated representation is loading or reconnecting.
                        StaticRemoteImage(
                            url: previewURL,
                            maximumPixelDimension: 420,
                            contentMode: .fill
                        )
                        AnimatedRemoteImage(
                            url: previewURL,
                            maximumPixelDimension: 420,
                            contentMode: .fill
                        )
                    }
                    .scaleEffect(hovering ? 1.04 : 1)
                    .blur(radius: hovering ? 4 : 0)
                    .opacity(0.78)
                }
                Color.black.opacity(hovering ? 0.28 : 0.40)
                VStack(spacing: 5) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 20, weight: .bold))
                    }
                    Text(title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.65), radius: 4, y: 1)
            }
            .frame(maxWidth: .infinity, minHeight: 102, maxHeight: 102)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .clipShape(ConcentricRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            ConcentricRectangle(cornerRadius: 13, style: .continuous)
                .stroke(.white.opacity(hovering ? 0.20 : 0.08), lineWidth: 1)
        }
        .scaleEffect(hovering ? 1.012 : 1)
        .animation(.snappy(duration: 0.16), value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct GIFPickerStatus: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button("Try Again", action: retry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(20)
    }
}
