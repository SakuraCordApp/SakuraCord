import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ProfileImageSource: Hashable, Sendable {
    public let data: Data
    public let mediaType: String
    public let size: CGSize
    public let frameCount: Int
    public let orientation: UInt32
    public let originalMD5: String
    public var isAnimated: Bool { frameCount > 1 }

    public init(data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source), let uniformType = UTType(type as String),
              let mediaType = uniformType.preferredMIMEType,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { throw ProfileImageProcessingError.invalidImage }
        self.data = data
        self.mediaType = mediaType
        let rawOrientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        orientation = (1 ... 8).contains(rawOrientation) ? rawOrientation : 1
        let swapsDimensions = (5 ... 8).contains(orientation)
        size = CGSize(width: swapsDimensions ? height : width, height: swapsDimensions ? width : height)
        frameCount = CGImageSourceGetCount(source)
        originalMD5 = Insecure.MD5.hash(data: data).hexString
    }
}

public struct ProfileProcessedImage: Sendable {
    public let data: Data
    public let mediaType: String
    public let isAnimated: Bool
}

public enum ProfileImageProcessor {
    public static func crop(_ image: ProfileImageSource, geometry: ProfileImageCropGeometry) throws -> ProfileProcessedImage {
        try Task.checkCancellation()
        guard image.size == geometry.naturalSize else { throw ProfileImageProcessingError.invalidCrop }
        if image.isAnimated, image.mediaType == "image/webp" {
            return ProfileProcessedImage(data: try ProfileWebPCropper.crop(image.data, region: geometry.animatedRegion), mediaType: "image/webp", isAnimated: true)
        }
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil) else { throw ProfileImageProcessingError.invalidImage }
        let animatedGIF = image.isAnimated && image.mediaType == "image/gif"
        let output = NSMutableData()
        let count = animatedGIF ? image.frameCount : 1
        let type = animatedGIF ? UTType.gif : .png
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, count, nil) else { throw ProfileImageProcessingError.encodingFailed }
        if animatedGIF, let properties = CGImageSourceCopyProperties(source, nil) {
            CGImageDestinationSetProperties(destination, properties)
        }
        for index in 0 ..< count {
            try Task.checkCancellation()
            let decoded: CGImage?
            if image.orientation != 1 {
                decoded = CGImageSourceCreateThumbnailAtIndex(source, index, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(image.size.width, image.size.height)
                ] as CFDictionary)
            } else { decoded = CGImageSourceCreateImageAtIndex(source, index, nil) }
            guard let frame = decoded else { throw ProfileImageProcessingError.invalidImage }
            let cropped = try render(frame, geometry: geometry, animated: animatedGIF)
            CGImageDestinationAddImage(destination, cropped, animatedGIF ? CGImageSourceCopyPropertiesAtIndex(source, index, nil) : nil)
        }
        guard CGImageDestinationFinalize(destination) else { throw ProfileImageProcessingError.encodingFailed }
        return ProfileProcessedImage(data: output as Data, mediaType: animatedGIF ? "image/gif" : "image/png", isAnimated: animatedGIF)
    }

    private static func render(_ image: CGImage, geometry: ProfileImageCropGeometry, animated: Bool) throws -> CGImage {
        let region = geometry.animatedRegion
        let source = animated ? CGRect(x: region.originX, y: region.originY, width: region.width, height: region.height) : geometry.sourceRect
        let size = animated ? CGSize(width: region.width, height: region.height) : geometry.outputSize
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0, source.width > 0, source.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ProfileImageProcessingError.invalidCrop }
        context.interpolationQuality = .low
        context.translateBy(x: 0, y: Double(height))
        context.scaleBy(x: 1, y: -1)
        context.clip(to: CGRect(origin: .zero, size: size))
        let scaleX = size.width / source.width
        let scaleY = size.height / source.height
        context.translateBy(x: -source.minX * scaleX, y: (Double(image.height) - source.minY) * scaleY)
        context.scaleBy(x: scaleX, y: -scaleY)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw ProfileImageProcessingError.encodingFailed }
        return result
    }
}
