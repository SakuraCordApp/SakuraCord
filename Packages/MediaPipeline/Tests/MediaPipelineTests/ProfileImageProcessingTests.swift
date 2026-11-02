import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import libwebp
@testable import MediaPipeline

struct ProfileImageProcessingTests {
    @Test
    func attachmentCompactionRejectsUnsupportedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outputDirectory = directory.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("notes.bin")
        let original = Data(repeating: 42, count: 1_000_000)
        try original.write(to: source)
        await #expect(throws: AttachmentCompactionError.self) {
            try await AttachmentCompactor().compact(source, in: outputDirectory, options: .init())
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path).isEmpty)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test(arguments: [UTType.heic, .png, .gif])
    func attachmentPhotosConvertStillImagesAndPreserveAnimation(type: UTType) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outputDirectory = directory.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("photo").appendingPathExtension(try #require(type.preferredFilenameExtension))
        let context = try #require(CGContext(
            data: nil, width: 3200, height: 1600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: (type == .png ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: type == .png ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: 3200, height: 1600))
        let frame = try #require(context.makeImage())
        let count = type == .gif ? 2 : 1
        let encoder = try #require(CGImageDestinationCreateWithURL(inputURL as CFURL, type.identifier as CFString, count, nil))
        for _ in 0 ..< count {
            CGImageDestinationAddImage(encoder, frame, [
                kCGImagePropertyOrientation: type == .heic ? 6 : 1,
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]
            ] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(encoder))

        let outputURL = try AttachmentPhotoProcessor.prepare(inputURL, in: outputDirectory, options: .init())
        if type == .gif {
            #expect(try Data(contentsOf: outputURL) == Data(contentsOf: inputURL))
            return
        }
        #expect(outputURL.pathExtension == (type == .png ? "png" : "jpg"))
        let source = try #require(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == (type == .heic ? 1280 : 2560))
        #expect(image.height == (type == .heic ? 2560 : 1280))
        if type == .png {
            let colors = try pixels(image)
            #expect((120 ... 136).contains(Int(colors[3])))
        }
    }

    @Test func cameraOrientationIsAppliedBeforeUserCrop() throws {
        let fixture = try animation()
        let source = try #require(CGImageSourceCreateWithData(fixture as CFData, nil))
        let frame = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)?.cropping(to: CGRect(x: 0, y: 0, width: 32, height: 16)))
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, frame, [kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let image = try ProfileImageSource(data: encoded as Data)
        #expect(image.size == CGSize(width: 16, height: 32))
        let output = try ProfileImageProcessor.crop(image, geometry: ProfileImageCropGeometry(naturalSize: image.size, purpose: .avatar))
        let outputSource = try #require(CGImageSourceCreateWithData(output.data as CFData, nil))
        let result = try #require(CGImageSourceCreateImageAtIndex(outputSource, 0, nil))
        #expect(result.width == 16 && result.height == 16)
        let colors = try pixels(result)
        let upper = (4 * 16 + 8) * 4
        let lower = (12 * 16 + 8) * 4
        #expect(colors[upper] > 200 && colors[upper + 1] < 40)
        #expect(colors[lower + 1] > 200 && colors[lower] < 40)
    }

    @Test(arguments: [false, true])
    func imagePipelinePreservesStaticAndGIFOrientation(animated: Bool) throws {
        let fixture = try animation()
        let source = try #require(CGImageSourceCreateWithData(fixture as CFData, nil))
        let encoded = NSMutableData()
        let count = animated ? 2 : 1
        let destination = try #require(CGImageDestinationCreateWithData(encoded, (animated ? UTType.gif : .png).identifier as CFString, count, nil))
        for index in 0 ..< count {
            let image = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        let input = try ProfileImageSource(data: encoded as Data)
        var geometry = ProfileImageCropGeometry(naturalSize: input.size, purpose: .avatar)
        geometry.rotate()
        let output = try ProfileImageProcessor.crop(input, geometry: geometry)
        #expect(output.isAnimated == animated)
        #expect(output.mediaType == (animated ? "image/gif" : "image/png"))
        let result = try #require(CGImageSourceCreateWithData(output.data as CFData, nil))
        #expect(CGImageSourceGetCount(result) == count)
        let frame = try #require(CGImageSourceCreateImageAtIndex(result, 0, nil))
        #expect(frame.width == 32 && frame.height == 32)
        let colors = try pixels(frame)
        let red = (8 * 32 + 24) * 4
        let green = (24 * 32 + 24) * 4
        #expect(colors[red] > 220 && colors[red + 1] < 30)
        #expect(colors[green + 1] > 220 && colors[green] < 30)
    }

    @Test func animatedCropPreservesFramesAndRotatesSelectedPixels() throws {
        let source = try animation()
        let output = try ProfileWebPCropper.crop(source, region: .init(originX: 0, originY: 0, width: 32, height: 16, quarterTurns: 1))
        let imageSource = try #require(CGImageSourceCreateWithData(output as CFData, nil))
        #expect(CGImageSourceGetCount(imageSource) == 2)
        for index in 0 ..< 2 {
            let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, index, nil))
            #expect(image.width == 16 && image.height == 32)
            let colors = try pixels(image)
            let upper = (8 * 16 + 8) * 4
            let lower = (24 * 16 + 8) * 4
            // The selected left/right quadrants become top/bottom after clockwise rotation.
            if index == 0 {
                #expect(colors[upper] > 220 && colors[upper + 1] < 30)
                #expect(colors[lower + 1] > 220 && colors[lower] < 30)
            } else {
                #expect(colors[upper + 2] > 220 && colors[upper] < 30)
                #expect(colors[lower] > 220 && colors[lower + 1] > 220)
            }
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(imageSource, index, nil) as? [CFString: Any])
            let webp = try #require(properties[kCGImagePropertyWebPDictionary] as? [CFString: Any])
            #expect(abs((webp[kCGImagePropertyWebPUnclampedDelayTime] as? Double ?? 0) - 0.1) < 0.001)
        }
    }

    @Test func staticCropKeepsTheSelectedVerticalRegionAndFractionalEdge() throws {
        let width = 600, height = 211
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0 ..< height {
            for column in 0 ..< width {
                let pixel = (row * width + column) * 4
                rgba[pixel + (row < 106 ? 0 : 2)] = 255
                rgba[pixel + 3] = 255
            }
        }
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let frame = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        ))
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, frame, nil)
        #expect(CGImageDestinationFinalize(destination))
        let image = try ProfileImageSource(data: encoded as Data)
        var geometry = ProfileImageCropGeometry(naturalSize: image.size, purpose: .banner)
        let centered = try ProfileImageProcessor.crop(image, geometry: geometry)
        let centeredSource = try #require(CGImageSourceCreateWithData(centered.data as CFData, nil))
        let centeredFrame = try #require(CGImageSourceCreateImageAtIndex(centeredSource, 0, nil))
        // The official canvas leaves the fraction of the first row outside the
        // source transparent; integer output dimensions must not shift the crop.
        #expect(try pixels(centeredFrame)[3] == 172)

        geometry.setZoom(2)
        geometry.setOffset(CGPoint(x: 0, y: 50))
        let panned = try ProfileImageProcessor.crop(image, geometry: geometry)
        let pannedSource = try #require(CGImageSourceCreateWithData(panned.data as CFData, nil))
        let pannedFrame = try #require(CGImageSourceCreateImageAtIndex(pannedSource, 0, nil))
        let colors = try pixels(pannedFrame)
        let center = ((pannedFrame.height / 2) * pannedFrame.width + pannedFrame.width / 2) * 4
        #expect(colors[center] == 255 && colors[center + 2] == 0)
    }

    @Test func rejectsInvalidMediaAndOutOfBoundsCrops() throws {
        #expect(throws: (any Error).self) { try ProfileWebPCropper.crop(Data(), region: .init(originX: 0, originY: 0, width: 1, height: 1)) }
        let source = try animation()
        for region in [ProfilePixelCrop(originX: -1, originY: 0, width: 16, height: 16), .init(originX: 31, originY: 0, width: 2, height: 2), .init(originX: 0, originY: 0, width: 0, height: 16)] {
            #expect(throws: (any Error).self) { try ProfileWebPCropper.crop(source, region: region) }
        }
        var geometry = ProfileImageCropGeometry(naturalSize: CGSize(width: 600, height: 211), purpose: .widgetCover, aspectRatio: 399 / 142)
        geometry.rotate(); geometry.setZoom(1.5); geometry.setOffset(CGPoint(x: 1000, y: -1000))
        #expect(abs(geometry.cropSize.width / geometry.cropSize.height - 399 / 142) < 0.001)
        #expect(geometry.sourceRect.minX >= -1 && geometry.sourceRect.minY >= -1)
    }

    private func animation() throws -> Data {
        var options = WebPAnimEncoderOptions()
        #expect(WebPAnimEncoderOptionsInit(&options) != 0)
        let encoder = try #require(WebPAnimEncoderNew(32, 32, &options))
        defer { WebPAnimEncoderDelete(encoder) }
        var config = WebPConfig()
        #expect(WebPConfigInit(&config) != 0)
        #expect(WebPConfigLosslessPreset(&config, 6) != 0)
        for frame in 0 ..< 2 {
            var rgba = [UInt8](repeating: 255, count: 32 * 32 * 4)
            let palette: [[UInt8]] = frame == 0 ? [[255, 0, 0], [0, 255, 0]] : [[0, 0, 255], [255, 255, 0]]
            for row in 0 ..< 32 {
                for column in 0 ..< 32 {
                    let color = row < 16 ? palette[column < 16 ? 0 : 1] : [UInt8](repeating: 0, count: 3)
                    for channel in 0 ..< 3 { rgba[(row * 32 + column) * 4 + channel] = color[channel] }
                }
            }
            var picture = WebPPicture()
            #expect(WebPPictureInit(&picture) != 0)
            picture.width = 32; picture.height = 32; picture.use_argb = 1
            defer { WebPPictureFree(&picture) }
            #expect(rgba.withUnsafeBufferPointer { WebPPictureImportRGBA(&picture, $0.baseAddress, 128) } != 0)
            #expect(WebPAnimEncoderAdd(encoder, &picture, Int32(frame * 100), &config) != 0)
        }
        #expect(WebPAnimEncoderAdd(encoder, nil, 200, nil) != 0)
        var data = WebPData()
        #expect(WebPAnimEncoderAssemble(encoder, &data) != 0)
        defer { WebPDataClear(&data) }
        return Data(bytes: try #require(data.bytes), count: data.size)
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try data.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }
}
