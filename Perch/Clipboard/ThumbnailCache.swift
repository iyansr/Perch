import AppKit
import ImageIO

/// Downsampled image derivatives for the clipboard list, cached in memory.
/// Rows use a 256 px derivative; the selected row's inline preview uses a 900 px one.
/// The full bitmap is never decoded: `CGImageSourceCreateThumbnailAtIndex` scales while decoding.
nonisolated final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    static let rowPixels = 256
    static let previewPixels = 900

    // NSCache is thread-safe.
    private let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 120
        return cache
    }()
    private let sizes = NSCache<NSString, NSValue>()

    /// Cached derivative, if already decoded.
    func cached(path: String, maxPixel: Int) -> NSImage? {
        images.object(forKey: Self.key(path, maxPixel))
    }

    /// Decodes off the caller's thread when it is not cached yet.
    func image(path: String, maxPixel: Int) async -> NSImage? {
        if let hit = cached(path: path, maxPixel: maxPixel) { return hit }
        return await Task.detached(priority: .userInitiated) { [self] in
            decode(path: path, maxPixel: maxPixel)
        }.value
    }

    /// Pixel size from the file header; no bitmap decode.
    func pixelSize(path: String) -> CGSize? {
        let key = path as NSString
        if let hit = sizes.object(forKey: key) { return hit.sizeValue }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0
        else { return nil }
        let size = CGSize(width: width, height: height)
        sizes.setObject(NSValue(size: size), forKey: key)
        return size
    }

    private func decode(path: String, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        images.setObject(image, forKey: Self.key(path, maxPixel), cost: cgImage.width * cgImage.height * 4)
        return image
    }

    private static func key(_ path: String, _ maxPixel: Int) -> NSString {
        "\(maxPixel)|\(path)" as NSString
    }
}
