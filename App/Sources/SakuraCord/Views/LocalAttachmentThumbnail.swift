import AppKit
import AVFoundation
import MediaPipeline
import SwiftUI
import UniformTypeIdentifiers

struct LocalAttachmentThumbnail: View {
    let url: URL
    var maximumPixelDimension = 256
    var cachedImage: NSImage?
    var preservesImageAspectRatio = false
    var imageCornerRadius: CGFloat = 0
    var animatesImageAppearance = false
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
                            ConcentricRectangle(cornerRadius: imageCornerRadius, style: .continuous)
                        )
                        .modifier(AttachmentImageReveal(isEnabled: animatesImageAppearance && isImageFile))
                } else {
                    Image(nsImage: displayImage)
                        .resizable()
                        .scaledToFill()
                        .clipShape(
                            ConcentricRectangle(cornerRadius: imageCornerRadius, style: .continuous)
                        )
                        .modifier(AttachmentImageReveal(isEnabled: animatesImageAppearance && isImageFile))
                }
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
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .scaledToFit()
                    .padding(InterfaceScale.metric(14))
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
                guard let frame = await Self.videoFrame(
                    at: url,
                    maximumPixelDimension: maximumPixelDimension
                ),
                    !Task.isCancelled
                else { return }
                let loadedImage = NSImage(cgImage: frame, size: .zero)
                image = loadedImage
                onImageLoaded?(loadedImage)
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

    private var isVideoFile: Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
    }

    /// Video files keep showing their Finder icon until this frame is ready,
    /// so an undecodable file never leaves a spinner behind.
    private nonisolated static func videoFrame(
        at url: URL,
        maximumPixelDimension: Int
    ) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: maximumPixelDimension,
            height: maximumPixelDimension
        )
        return try? await generator.image(at: .zero).image
    }
}

private struct AttachmentImageReveal: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false
    let isEnabled: Bool

    private var progress: CGFloat {
        isEnabled && !reduceMotion && !hasAppeared ? 0 : 1
    }

    func body(content: Content) -> some View {
        content
            .animation(isEnabled && !reduceMotion ? .easeOut(duration: 0.18) : nil) { image in
                image.opacity(progress)
            }
            .blur(radius: InterfaceScale.metric(3) * (1 - progress))
            .offset(y: InterfaceScale.metric(6) * (1 - progress))
            .mask {
                AttachmentImageRevealMask(progress: progress)
            }
            .onAppear {
                guard !hasAppeared else { return }
                // Start when the decoded image appears, rather than when loading begins.
                withAnimation(isEnabled && !reduceMotion ? .smooth(duration: 0.28) : nil) {
                    hasAppeared = true
                }
            }
    }
}

@Animatable
private struct AttachmentImageRevealMask: View {
    var progress: CGFloat

    var body: some View {
        let feather: CGFloat = 0.18
        let edge = 1 - progress * (1 + feather)
        // Move the feather fully above the image so the finished preview stays opaque.
        LinearGradient(
            colors: [.clear, .black],
            startPoint: UnitPoint(x: 0.5, y: edge),
            endPoint: UnitPoint(x: 0.5, y: edge + feather)
        )
    }
}
