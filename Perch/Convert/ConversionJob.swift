import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import libwebp

/// An image format Perch can write.
nonisolated enum ConversionFormat: Sendable {
    case png, jpeg, heic, webp

    var type: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .webp: .webP
        }
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        case .webp: "webp"
        }
    }

    /// The format of an existing file, when Perch can write that format back.
    init?(type: UTType) {
        if type.conforms(to: .png) {
            self = .png
        } else if type.conforms(to: .jpeg) {
            self = .jpeg
        } else if type.conforms(to: .heic) || type.conforms(to: .heif) {
            self = .heic
        } else if type.conforms(to: .webP) {
            self = .webp
        } else {
            return nil
        }
    }
}

nonisolated enum ConversionError: LocalizedError {
    case unreadable
    case encodingFailed(ConversionFormat)
    case tooLargeForWebP

    var errorDescription: String? {
        switch self {
        case .unreadable: "The image could not be read."
        case let .encodingFailed(format): "The image could not be encoded as \(format.fileExtension)."
        case .tooLargeForWebP: "WebP supports at most 16383 px per side."
        }
    }
}

/// One file in a batch: decode → (resize) → encode → write. Everything here is pure and thread-safe,
/// so `ImageConverter` runs jobs off the main actor.
nonisolated struct ConversionJob: Sendable {
    static let webPMaxDimension = 16383

    let source: URL
    let destination: URL
    let action: ConversionAction
    let format: ConversionFormat
    /// Lossy quality in 0…1; `nil` for lossless PNG.
    let quality: Double?

    /// Output format and quality for an action. Resize and Compress keep the source format, falling back to
    /// PNG when Perch cannot write it. Compress cannot make PNG lossy, so PNG is re-encoded without metadata.
    static func target(for action: ConversionAction, source: ConversionFormat?) -> (format: ConversionFormat, quality: Double?) {
        switch action {
        case .png: return (.png, nil)
        case .jpg: return (.jpeg, 0.85)
        case .webp: return (.webp, 0.8)
        case .heic: return (.heic, 0.8)
        case .resize50, .compress:
            let format = source ?? .png
            if format == .png { return (.png, nil) }
            if action == .compress { return (format, 0.6) }
            return (format, format == .jpeg ? 0.85 : 0.8)
        }
    }

    /// Reads `source` (read-only), writes `destination`. Never overwrites an existing file.
    func perform() throws {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, sourceOptions),
              CGImageSourceGetCount(imageSource) > 0
        else { throw ConversionError.unreadable }

        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
        let longSide = max(
            properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
            properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        )

        // The thumbnail API applies the EXIF orientation to the pixels, which formats like WebP cannot carry as
        // a tag. At the full long side it does not scale, so every action goes through it.
        var thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if action == .resize50 {
            guard longSide > 0 else { throw ConversionError.unreadable }
            thumbnailOptions[kCGImageSourceThumbnailMaxPixelSize] = max(1, Int((Double(longSide) / 2).rounded()))
        } else if longSide > 0 {
            thumbnailOptions[kCGImageSourceThumbnailMaxPixelSize] = longSide
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary) else {
            throw ConversionError.unreadable
        }

        let data = try encode(image, sourceProperties: properties)
        try Self.writeWithoutOverwriting(data, to: destination)
    }

    /// Writes next to the target and renames into place: `moveItem` fails when the name is taken, and
    /// `Data.write` cannot combine `.atomic` with `.withoutOverwriting`.
    private static func writeWithoutOverwriting(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).perch-tmp")
        do {
            try data.write(to: temporary)
            try FileManager.default.moveItem(at: temporary, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    // MARK: Encoding

    private func encode(_ image: CGImage, sourceProperties: [CFString: Any]) throws -> Data {
        if format == .webp {
            return try Self.webPData(image, quality: quality ?? 0.8)
        }

        let pixels = format == .jpeg ? Self.flattenedOnWhite(image) : image
        let output = NSMutableData()
        guard let sink = CGImageDestinationCreateWithData(output, format.type.identifier as CFString, 1, nil) else {
            throw ConversionError.encodingFailed(format)
        }
        // A CGImage carries no metadata, so Compress on PNG strips it by simply not passing any.
        var options: [CFString: Any] = (action == .compress && format == .png) ? [:] : Self.carriedMetadata(sourceProperties)
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(sink, pixels, options as CFDictionary)
        guard CGImageDestinationFinalize(sink) else { throw ConversionError.encodingFailed(format) }
        return output as Data
    }

    /// EXIF, TIFF, GPS and IPTC from the source, minus what the re-encode invalidates (orientation is baked
    /// into the pixels, pixel dimensions may have changed).
    private static func carriedMetadata(_ properties: [CFString: Any]) -> [CFString: Any] {
        var carried: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let value = properties[key] { carried[key] = value }
        }
        if var tiff = carried[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = nil
            carried[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = carried[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            carried[kCGImagePropertyExifDictionary] = exif
        }
        return carried
    }

    /// JPEG has no alpha; composite onto white instead of letting the encoder pick a background.
    private static func flattenedOnWhite(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        let space: CGColorSpace
        if let own = image.colorSpace, own.model == .rgb {
            space = own
        } else {
            space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    /// Lossy WebP through libwebp. ImageIO cannot write WebP.
    private static func webPData(_ image: CGImage, quality: Double) throws -> Data {
        let width = image.width
        let height = image.height
        guard width <= webPMaxDimension, height <= webPMaxDimension else { throw ConversionError.tooLargeForWebP }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ConversionError.encodingFailed(.webp) }

        // CGContext only produces premultiplied RGBA; libwebp expects straight alpha.
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: break
        default:
            rgba.withUnsafeMutableBufferPointer { pixels in
                var i = 0
                while i < pixels.count {
                    let alpha = Int(pixels[i + 3])
                    if alpha != 0, alpha != 255 {
                        for channel in 0..<3 {
                            pixels[i + channel] = UInt8(min(255, (Int(pixels[i + channel]) * 255 + alpha / 2) / alpha))
                        }
                    }
                    i += 4
                }
            }
        }

        var encoded: UnsafeMutablePointer<UInt8>?
        let size = rgba.withUnsafeBufferPointer { pixels in
            WebPEncodeRGBA(pixels.baseAddress, Int32(width), Int32(height), Int32(width * 4), Float(quality * 100), &encoded)
        }
        guard size > 0, let encoded else { throw ConversionError.encodingFailed(.webp) }
        defer { WebPFree(encoded) }
        return Data(bytes: encoded, count: size)
    }
}
