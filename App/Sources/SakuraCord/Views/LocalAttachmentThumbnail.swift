import AppKit
import MediaPipeline
import SwiftUI
import UniformTypeIdentifiers

struct LocalAttachmentThumbnail: View {
    let url: URL
    var maximumPixelDimension = 256
    var cachedImage: NSImage?
    var onImageLoaded: ((NSImage) -> Void)?
    @State private var image: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.clear
            if let displayImage {
                Image(nsImage: displayImage)
                    .resizable()
                    .scaledToFill()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                if isVideoFile {
                    Image(systemName: "play.fill")
                        .font(.interfaceSystem(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: InterfaceScale.metric(30), height: InterfaceScale.metric(30))
                        .background(.black.opacity(0.55), in: Circle())
                }
            } else if isImageFile {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .scaledToFit()
                    .padding(InterfaceScale.metric(14))
                    .transition(.opacity)
            }
        }
        .clipped()
        .task(id: "\(url.absoluteString)#\(maximumPixelDimension)") {
            if let cachedImage {
                image = cachedImage
                return
            }
            image = nil
            guard isImageFile || isVideoFile else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            if isVideoFile {
                guard let frame = await LocalVideo.frame(
                    at: url,
                    maximumPixelDimension: maximumPixelDimension
                ),
                    !Task.isCancelled
                else { return }
                let loadedImage = NSImage(cgImage: frame, size: .zero)
                reveal(loadedImage)
                return
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
            reveal(loadedImage)
        }
    }

    /// A decoded preview fades in over its placeholder instead of popping.
    private func reveal(_ loadedImage: NSImage) {
        withAnimation(.smooth(duration: 0.28)) {
            image = loadedImage
        }
        onImageLoaded?(loadedImage)
    }

    private var displayImage: NSImage? {
        cachedImage ?? image
    }

    private var isImageFile: Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    private var isVideoFile: Bool {
        LocalVideo.isVideo(url)
    }
}
