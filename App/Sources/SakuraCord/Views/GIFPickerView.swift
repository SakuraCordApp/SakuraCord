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
    static func requiresWebVideoPlayback(
        _ url: URL,
        declaredKind: GIFMediaKind? = nil
    ) -> Bool {
        declaredKind == .video
            || ["webm", "mp4"].contains(url.pathExtension.lowercased())
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
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: GIFMasonryLayout.spacing),
                    GridItem(.flexible(), spacing: GIFMasonryLayout.spacing),
                ],
                spacing: GIFMasonryLayout.spacing
            ) {
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
                ForEach(model.gifCategories) { category in
                    GIFCategoryButton(
                        title: category.name,
                        systemImage: nil,
                        previewURL: category.previewURL
                    ) {
                        query = category.query
                    }
                }
            }
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

    private var resultsPage: some View {
        GeometryReader { geometry in
            let available = max(1, geometry.size.width - 24 - GIFMasonryLayout.spacing)
            let columnWidth = available / 2
            let columns = GIFMasonryLayout.columns(
                for: visibleResults,
                columnWidth: columnWidth
            )
            ScrollView {
                HStack(alignment: .top, spacing: GIFMasonryLayout.spacing) {
                    GIFMasonryColumn(
                        items: columns.leading,
                        width: columnWidth,
                        favorites: favoriteURLs,
                        mutatingURL: model.gifFavoriteMutationURL,
                        choose: choose,
                        toggleFavorite: toggleFavorite
                    )
                    GIFMasonryColumn(
                        items: columns.trailing,
                        width: columnWidth,
                        favorites: favoriteURLs,
                        mutatingURL: model.gifFavoriteMutationURL,
                        choose: choose,
                        toggleFavorite: toggleFavorite
                    )
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.hidden)
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
                    AnimatedRemoteImage(
                        url: previewURL,
                        animates: true,
                        maximumPixelDimension: 420,
                        contentMode: .fill
                    )
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
            .frame(height: 102)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

private struct GIFMasonryColumn: View {
    let items: [GIFMasonryItem]
    let width: CGFloat
    let favorites: Set<URL>
    let mutatingURL: URL?
    let choose: (GIFSearchResult) -> Void
    let toggleFavorite: (GIFSearchResult) -> Void

    var body: some View {
        LazyVStack(spacing: GIFMasonryLayout.spacing) {
            ForEach(items) { item in
                GIFPickerCell(
                    gif: item.result,
                    isFavorite: favorites.contains(item.result.url),
                    isMutatingFavorite: mutatingURL == item.result.url,
                    choose: { choose(item.result) },
                    toggleFavorite: { toggleFavorite(item.result) }
                )
                .frame(width: width, height: item.height)
            }
        }
    }
}

private struct GIFPickerCell: View {
    let gif: GIFSearchResult
    let isFavorite: Bool
    let isMutatingFavorite: Bool
    let choose: () -> Void
    let toggleFavorite: () -> Void

    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: choose) {
                ZStack {
                    Color.primary.opacity(0.07)
                    GIFPickerMedia(gif: gif)
                    Color.white.opacity(hovering ? 0.12 : 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: toggleFavorite) {
                Group {
                    if isMutatingFavorite {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .foregroundStyle(isFavorite ? .yellow : .white)
                .frame(width: 28, height: 28)
                .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isMutatingFavorite)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .padding(7)
            .help(isFavorite ? "Remove from favourites" : "Add to favourites")
        }
        .clipShape(ConcentricRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            ConcentricRectangle(cornerRadius: 11, style: .continuous)
                .stroke(
                    .white.opacity(hovering ? 0.48 : 0.07),
                    lineWidth: hovering ? 1.5 : 1
                )
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(gif.title)
    }
}

private struct GIFPickerMedia: View {
    let gif: GIFSearchResult

    @State private var isVisible = false
    @State private var failedNativePreview = false

    var body: some View {
        ZStack {
            if let fallbackURL = staticFallbackURL {
                StaticRemoteImage(
                    url: fallbackURL,
                    maximumPixelDimension: 520,
                    contentMode: .fit
                )
            }
            if let animatedURL = gif.previewURL ?? gif.mediaURL {
                if let fallbackVideoURL {
                    LoopingRemoteVideo(
                        url: fallbackVideoURL,
                        isPlaying: isVisible,
                        contentMode: .fit
                    )
                } else if GIFPickerMediaPolicy.requiresWebVideoPlayback(
                    animatedURL,
                    declaredKind: animatedURL == gif.mediaURL
                        ? gif.mediaKind
                        : nil
                ) {
                    LoopingRemoteVideo(
                        url: animatedURL,
                        isPlaying: isVisible,
                        contentMode: .fit
                    )
                } else {
                    AnimatedRemoteImage(
                        url: animatedURL,
                        animates: true,
                        maximumPixelDimension: 520,
                        contentMode: .fit,
                        onFailure: {
                            failedNativePreview = true
                        }
                    )
                }
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    private var fallbackVideoURL: URL? {
        guard failedNativePreview,
              let mediaURL = gif.mediaURL,
              GIFPickerMediaPolicy.requiresWebVideoPlayback(
                  mediaURL,
                  declaredKind: gif.mediaKind
              )
        else { return nil }
        return mediaURL
    }

    private var staticFallbackURL: URL? {
        let candidate = gif.thumbnailURL ?? gif.previewURL ?? gif.mediaURL
        guard let candidate,
              !GIFPickerMediaPolicy.requiresWebVideoPlayback(
                  candidate,
                  declaredKind: candidate == gif.mediaURL
                      ? gif.mediaKind
                      : nil
              )
        else { return nil }
        return candidate
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
