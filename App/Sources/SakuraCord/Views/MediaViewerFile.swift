import AppKit
import PDFKit
import QuickLookThumbnailing
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

/// A file that is not media, text, or audio, previewed in the media viewer:
/// a PDF in PDFKit, and anything else Quick Look can draw. A message's file
/// is fetched into a temporary file first, never into Downloads, which later
/// visits reuse; a file Quick Look can't draw shows a page that offers to
/// download it.
struct MediaViewerFile: View {
    let item: RichMediaItem
    let download: () -> Void
    @State private var phase = Phase.fetching(0)
    /// The file the current preview is for, so a file left for another
    /// can't overwrite it.
    @State private var request: URL?

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
            let url = item.url
            request = url
            phase = .fetching(0)
            let preview = await Self.preview(of: item) { fraction in
                if request == url, case .fetching = phase { phase = .fetching(fraction) }
            }
            guard !Task.isCancelled, request == url else { return }
            phase = preview
        }
    }

    /// The type a file's own name gives it, which a Discord link ends in; a
    /// display title may not.
    static func type(of item: RichMediaItem) -> UTType? {
        UTType(filenameExtension: item.url.pathExtension)
            ?? MediaViewerFilePolicy.contentType(title: item.title, sourceURL: item.url)
    }

    /// The file type's Finder icon, as its timeline card shows it.
    static func icon(for item: RichMediaItem) -> NSImage {
        NSWorkspace.shared.icon(for: type(of: item) ?? .data)
    }

    /// Fetches the file unless it is already on disk, then picks how to show
    /// it.
    private static func preview(
        of item: RichMediaItem,
        progress: @escaping @MainActor (Double) -> Void
    ) async -> Phase {
        // Archives, disk images, programs, and unknown data have no preview
        // worth fetching them for.
        guard let type = type(of: item), !type.isDynamic,
              ![.archive, .diskImage, .executable, .application].contains(where: type.conforms(to:))
        else { return .unavailable }
        let file = item.url.isFileURL ? item.url : try? await MediaViewerPreviewFile.file(for: item, progress: progress)
        guard let file, !Task.isCancelled else { return .unavailable }
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
            Image(nsImage: MediaViewerFile.icon(for: item))
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

/// Messages' files fetched to preview, each in its own temporary folder
/// under its own name, which Quick Look reads its type from. A file stays
/// for the session, so reopening its preview doesn't fetch it again, until
/// newer previews push it out; launch clears what a previous session left.
@MainActor
enum MediaViewerPreviewFile {
    /// A file's fetch, and the previews waiting for it, the latest of
    /// which shows its progress.
    @MainActor
    private final class Preview {
        let url: URL
        var file: Task<URL, any Error>!
        var waiters: Set<UUID> = []
        var isFetched = false
        var progress: @MainActor (Double) -> Void

        init(url: URL, progress: @escaping @MainActor (Double) -> Void) {
            self.url = url
            self.progress = progress
        }
    }

    /// Kept previews by the file's link, newest last.
    private static var previews: [Preview] = []
    private static let maximumFiles = 8

    private nonisolated static var root: URL {
        URL.temporaryDirectory.appending(path: "AttachmentPreviews", directoryHint: .isDirectory)
    }

    /// The file's temporary copy, from an earlier or ongoing fetch if there
    /// is one. A fetch every preview left before it finished stops.
    static func file(for item: RichMediaItem, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let preview: Preview
        if let index = previews.firstIndex(where: { $0.url == item.url }) {
            preview = previews.remove(at: index)
            preview.progress = progress
        } else {
            preview = Preview(url: item.url, progress: progress)
            preview.file = Task { try await fetch(item) { preview.progress($0) } }
        }
        previews.append(preview)
        while previews.count > maximumFiles {
            discard(previews.removeFirst().file)
        }
        let waiter = UUID()
        preview.waiters.insert(waiter)
        defer { preview.waiters.remove(waiter) }
        do {
            let file = try await withTaskCancellationHandler {
                try await preview.file.value
            } onCancel: {
                Task { @MainActor in
                    preview.waiters.remove(waiter)
                    guard preview.waiters.isEmpty, !preview.isFetched else { return }
                    previews.removeAll { $0 === preview }
                    discard(preview.file)
                }
            }
            preview.isFetched = true
            return file
        } catch {
            previews.removeAll { $0 === preview }
            throw error
        }
    }

    private static func fetch(_ item: RichMediaItem, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let source = await MediaViewerActionService.resolveRemoteURL?(item.url) ?? item.url
        let downloaded = try await AttachmentDownloadStore.download(source) { fraction in
            Task { @MainActor in progress(fraction) }
        }
        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let destination = folder.appending(path: item.url.lastPathComponent)
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: downloaded, to: destination)
        }.value
        return destination
    }

    /// Stops a fetch, then removes the copy it made, if any, and its folder.
    private static func discard(_ file: Task<URL, any Error>) {
        file.cancel()
        Task.detached(priority: .utility) {
            guard let folder = try? await file.value.deletingLastPathComponent() else { return }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    nonisolated static func removeAbandonedFilesAtStartup() {
        try? FileManager.default.removeItem(at: root)
    }
}
