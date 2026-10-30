import AppKit
import PDFKit
import QuickLookThumbnailing
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

/// A file that is not media, text, or audio, previewed in the media viewer:
/// a PDF in PDFKit, and anything else Quick Look can draw. A message's file
/// is fetched into a private cache first, never into Downloads; a file Quick
/// Look can't draw shows a page that offers to download it.
struct MediaViewerFile: View {
    let item: RichMediaItem
    let download: () -> Void
    @State private var phase = Phase.fetching(0)

    enum Phase {
        case fetching(Double)
        case pdf(PDFDocument)
        case quickLook(URL)
        case unavailable
    }

    var body: some View {
        Group {
            switch phase {
            case let .fetching(fraction):
                MediaViewerFilePage(item: item) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(SakuraCordAccentColor.color)
                        .frame(width: InterfaceScale.metric(220))
                        .accessibilityLabel("Loading preview")
                }
            case let .pdf(document):
                MediaViewerPDF(document: document)
                    .modifier(MediaViewerDocumentFrame())
            case let .quickLook(url):
                MediaViewerQuickLook(url: url)
                    .modifier(MediaViewerDocumentFrame())
            case .unavailable:
                MediaViewerFilePage(item: item) {
                    Text("No preview available")
                        .font(.interface(.callout))
                        .foregroundStyle(.secondary)
                    Button("Download", systemImage: "arrow.down.to.line", action: download)
                        .buttonStyle(.glassProminent)
                        .tint(SakuraCordAccentColor.color)
                        .controlSize(.large)
                }
            }
        }
        .task(id: item.url) {
            phase = .fetching(0)
            phase = await Self.preview(of: item) { fraction in phase = .fetching(fraction) }
        }
    }

    /// Fetches the file unless it is already on disk, then picks how to show it.
    private static func preview(of item: RichMediaItem, progress: @escaping @MainActor (Double) -> Void) async -> Phase {
        let type = MediaViewerFilePolicy.contentType(title: item.title, sourceURL: item.url)
        // Archives, disk images, programs, and unknown data have no preview
        // worth fetching them for.
        guard let type, !type.isDynamic,
              ![.archive, .diskImage, .executable, .application].contains(where: type.conforms(to:))
        else { return .unavailable }
        let file: URL
        do {
            file = item.url.isFileURL ? item.url : try await MediaViewerPreviewCache.file(for: item, progress: progress)
        } catch {
            return .unavailable
        }
        guard !Task.isCancelled else { return .unavailable }
        if type.conforms(to: .pdf) {
            return PDFDocument(url: file).map(Phase.pdf) ?? .unavailable
        }
        return await canQuickLook(file) ? .quickLook(file) : .unavailable
    }

    /// Quick Look draws a thumbnail for every kind of file it can preview,
    /// and only an icon for the rest.
    private static func canQuickLook(_ file: URL) async -> Bool {
        let request = QLThumbnailGenerator.Request(
            fileAt: file, size: CGSize(width: 64, height: 64), scale: 1, representationTypes: .thumbnail
        )
        return (try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)) != nil
    }
}

/// A file's icon, name, and size above what the viewer can do with it.
struct MediaViewerFilePage<Accessory: View>: View {
    let item: RichMediaItem
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        VStack(spacing: InterfaceScale.metric(14)) {
            Image(nsImage: Self.icon(for: item))
                .resizable()
                .frame(width: InterfaceScale.metric(88), height: InterfaceScale.metric(88))
                .accessibilityHidden(true)
            VStack(spacing: InterfaceScale.metric(3)) {
                Text(item.title)
                    .font(.interface(.title3).weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                Text(MediaViewerDetails.fileDetail(item))
                    .font(.interface(.callout).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            accessory()
                .padding(.top, InterfaceScale.metric(4))
        }
        .padding(InterfaceScale.metric(30))
        .frame(width: InterfaceScale.metric(400))
        .glassEffect(.regular, in: .rect(cornerRadius: MediaViewerStage.contentCornerRadius))
    }

    private static func icon(for item: RichMediaItem) -> NSImage {
        NSWorkspace.shared.icon(for: MediaViewerFilePolicy.contentType(title: item.title, sourceURL: item.url) ?? .data)
    }
}

/// A document laid out like the viewer's text files: as wide as it reads
/// well and as tall as the stage.
private struct MediaViewerDocumentFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: InterfaceScale.metric(960), maxHeight: .infinity)
            .background(.black.opacity(0.35))
            .clipShape(.rect(cornerRadius: MediaViewerStage.contentCornerRadius))
    }
}

private struct MediaViewerPDF: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .clear
        view.pageShadowsEnabled = true
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard view.document !== document else { return }
        view.document = document
    }
}

private struct MediaViewerQuickLook: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard (view.previewItem as? URL) != url else { return }
        view.previewItem = url as NSURL
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

/// Files fetched to preview, kept apart from Downloads in the app's caches,
/// where the system may reclaim them. Only the newest few are kept.
@MainActor
enum MediaViewerPreviewCache {
    private nonisolated static let directory = URL.cachesDirectory.appending(path: "AttachmentPreviews", directoryHint: .isDirectory)
    private nonisolated static let maximumFiles = 8

    static func file(for item: RichMediaItem, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let folder = directory.appending(path: item.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? item.id)
        let destination = folder.appending(path: MediaViewerFilePolicy.suggestedFilename(title: item.title, sourceURL: item.url))
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let source = await MediaViewerActionService.resolveRemoteURL?(item.url) ?? item.url
        let downloaded = try await AttachmentDownloadStore.download(source) { fraction in
            Task { @MainActor in progress(fraction) }
        }
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: downloaded, to: destination)
            prune(keeping: folder)
        }.value
        return destination
    }

    /// Removes all but the newest folders.
    private nonisolated static func prune(keeping kept: URL) {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let dated = folders.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (folder, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(maximumFiles) where folder != kept {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
