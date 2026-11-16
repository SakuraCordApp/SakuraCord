import Foundation

public enum ProfileImagePurpose: Hashable, Sendable {
    case avatar, banner, widgetCover, widgetField

    public var aspectRatio: Double { self == .banner ? 17 / 6 : self == .widgetCover ? 16 / 9 : 1 }
    public var maximumSize: CGSize {
        switch self {
        case .avatar, .widgetField: CGSize(width: 1024, height: 1024)
        case .banner: CGSize(width: 2400, height: 848)
        case .widgetCover: CGSize(width: 2400, height: 1350)
        }
    }
}

/// Geometry follows the official editor's displayed-image math, including its
/// floating-point crop coordinates and separate static/animated pixel rounding.
public struct ProfileImageCropGeometry: Hashable, Sendable {
    public let naturalSize: CGSize
    public let purpose: ProfileImagePurpose
    public let aspectRatio: Double
    public let viewportHeight: Double
    public let imageSize: CGSize
    public let cropSize: CGSize

    public init(naturalSize: CGSize, purpose: ProfileImagePurpose, viewportHeight: Double = 350, aspectRatio: Double? = nil) {
        self.naturalSize = naturalSize
        self.purpose = purpose
        self.viewportHeight = viewportHeight
        self.aspectRatio = aspectRatio.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? purpose.aspectRatio
        let initial = CGSize(width: naturalSize.width / naturalSize.height * viewportHeight, height: viewportHeight)
        imageSize = Self.fitted(initial, aspectRatio: self.aspectRatio)
        cropSize = Self.cropSize(imageSize, originalHeight: initial.height, purpose: purpose, aspectRatio: self.aspectRatio)
    }

    public var displayedSize: CGSize {
        let adjustment = aspectRatio != 1 && imageSize.width / imageSize.height > aspectRatio ? cropSize.height / imageSize.height : 1
        return CGSize(width: imageSize.width * adjustment, height: imageSize.height * adjustment)
    }
    public var sourceRect: CGRect {
        // HTMLImageElement.width/height expose rounded integer CSS dimensions.
        let displayed = CGSize(width: displayedSize.width.rounded(), height: displayedSize.height.rounded())
        let scale = naturalSize.width / displayed.width
        return CGRect(x: (displayed.width / 2 - cropSize.width / 2) * scale,
                      y: (displayed.height / 2 - cropSize.height / 2) * scale,
                      width: cropSize.width * scale, height: cropSize.height * scale)
    }
    public var animatedRegion: ProfilePixelCrop {
        let source = sourceRect
        let originX = max(0, Int(floor(source.minX + 0.5)))
        let originY = max(0, Int(floor(source.minY + 0.5)))
        return ProfilePixelCrop(originX: originX, originY: originY, width: min(Int(floor(source.width + 0.5)), Int(naturalSize.width) - originX),
                                height: min(Int(floor(source.height + 0.5)), Int(naturalSize.height) - originY))
    }
    public var outputSize: CGSize {
        let scale = naturalSize.width / displayedSize.width.rounded()
        return CGSize(width: min(cropSize.width * scale, purpose.maximumSize.width),
                      height: min(cropSize.height * scale, purpose.maximumSize.height))
    }

    private static func fitted(_ size: CGSize, aspectRatio: Double) -> CGSize {
        guard aspectRatio != 1 else { return size }
        let width = min(size.width, 432)
        let height = size.width > 432 ? 432 / size.width * size.height : size.height
        guard size.width / size.height >= aspectRatio else { return CGSize(width: width, height: height) }
        let targetHeight = 432 / aspectRatio
        return CGSize(width: targetHeight / height * width, height: targetHeight)
    }
    private static func cropSize(_ size: CGSize, originalHeight: Double, purpose: ProfileImagePurpose, aspectRatio: Double) -> CGSize {
        guard aspectRatio != 1 else {
            let edge = min(size.width, size.height)
            return CGSize(width: edge, height: edge)
        }
        let width = min(size.width, 432)
        let height = width * (1 / aspectRatio)
        return CGSize(width: width, height: purpose == .widgetCover ? min(height, originalHeight) : height)
    }
}
