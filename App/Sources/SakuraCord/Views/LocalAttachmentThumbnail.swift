import AppKit
import MediaPipeline
import SwiftUI
import UniformTypeIdentifiers

struct LocalAttachmentThumbnail: View {
    let url: URL
    var maximumPixelDimension = 256
    var cachedImage: NSImage?
    var preservesImageAspectRatio = false
    var imageCornerRadius: CGFloat = 0
    var onImageLoaded: ((NSImage) -> Void)?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.clear
            if let displayImage {
                if preservesImageAspectRatio {
                    Image(nsImage: displayImage)
                        .resizable()
                        .scaledToFit()
                        .clipShape(
                            RoundedRectangle(cornerRadius: imageCornerRadius, style: .continuous)
                        )
                } else {
                    Image(nsImage: displayImage)
                        .resizable()
                        .scaledToFill()
                        .clipShape(
                            RoundedRectangle(cornerRadius: imageCornerRadius, style: .continuous)
                        )
                }
            } else if isImageFile {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .scaledToFit()
                    .padding(14)
            }
        }
        .clipped()
        .task(id: "\(url.absoluteString)#\(maximumPixelDimension)") {
            if let cachedImage {
                image = cachedImage
                return
            }
            image = nil
            guard isImageFile else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            guard let data = try? await SharedMediaDataLoader.shared.data(for: url),
                  !Task.isCancelled
            else { return }
            let decoded = await Task.detached(priority: .userInitiated) {
                try? DecodedAnimatedImage(
                    data: data,
                    maximumPixelDimension: maximumPixelDimension
                )
            }.value
            guard !Task.isCancelled else { return }
            let loadedImage: NSImage
            if let firstFrame = decoded?.frames.first {
                loadedImage = NSImage(cgImage: firstFrame, size: .zero)
            } else {
                guard let fallbackImage = NSImage(data: data) else { return }
                loadedImage = fallbackImage
            }
            image = loadedImage
            onImageLoaded?(loadedImage)
        }
    }

    private var displayImage: NSImage? {
        cachedImage ?? image
    }

    private var isImageFile: Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }
}
