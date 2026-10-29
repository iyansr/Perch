import Testing
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import Perch

struct ImageConverterTests {
    // MARK: Naming

    @Test func suffixes() {
        let free: (String) -> Bool = { _ in false }
        #expect(ImageConverter.outputName(stem: "photo", action: .jpg, ext: "jpg", isTaken: free) == "photo.jpg")
        #expect(ImageConverter.outputName(stem: "photo", action: .webp, ext: "webp", isTaken: free) == "photo.webp")
        #expect(ImageConverter.outputName(stem: "photo", action: .compress, ext: "jpeg", isTaken: free) == "photo-compressed.jpeg")
        #expect(ImageConverter.outputName(stem: "photo", action: .resize50, ext: "png", isTaken: free) == "photo-50.png")
    }

    @Test func collisionsCountUpFromTwo() {
        func name(_ action: ConversionAction, ext: String, taken: Set<String>) -> String {
            ImageConverter.outputName(stem: "photo", action: action, ext: ext, isTaken: { taken.contains($0) })
        }
        #expect(name(.jpg, ext: "jpg", taken: ["photo.jpg"]) == "photo 2.jpg")
        #expect(name(.jpg, ext: "jpg", taken: ["photo.jpg", "photo 2.jpg"]) == "photo 3.jpg")
        #expect(name(.compress, ext: "jpg", taken: ["photo-compressed.jpg"]) == "photo-compressed 2.jpg")
        // An unrelated suffix does not collide.
        #expect(name(.resize50, ext: "jpg", taken: ["photo.jpg", "photo-compressed.jpg"]) == "photo-50.jpg")
    }

    @Test func planAvoidsExistingFilesAndNamesClaimedInTheSameBatch() throws {
        try withTempDirectory { dir in
            let png = dir.appendingPathComponent("a.png")
            let jpeg = dir.appendingPathComponent("a.jpeg")
            try writeFixture(patternImage(width: 16, height: 16), as: .png, to: png)
            try writeFixture(patternImage(width: 16, height: 16), as: .jpeg, to: jpeg)

            // Two inputs with the same stem both want `a.webp`.
            let webp = ImageConverter.plan(.webp, for: [png, jpeg])
            #expect(webp.jobs.map(\.destination.lastPathComponent) == ["a.webp", "a 2.webp"])

            // A PNG → PNG "conversion" collides with its own original.
            let again = ImageConverter.plan(.png, for: [png])
            #expect(again.jobs.map(\.destination.lastPathComponent) == ["a 2.png"])
        }
    }

    @Test func resizeAndCompressKeepTheSourceExtension() throws {
        try withTempDirectory { dir in
            let jpeg = dir.appendingPathComponent("photo.jpeg")
            try writeFixture(patternImage(width: 16, height: 16), as: .jpeg, to: jpeg)

            #expect(ImageConverter.plan(.resize50, for: [jpeg]).jobs.map(\.destination.lastPathComponent) == ["photo-50.jpeg"])
            #expect(ImageConverter.plan(.compress, for: [jpeg]).jobs.map(\.destination.lastPathComponent) == ["photo-compressed.jpeg"])
            // A format change from `.jpeg` lands on the canonical `.jpg`, so it does not collide with the original.
            #expect(ImageConverter.plan(.jpg, for: [jpeg]).jobs.map(\.destination.lastPathComponent) == ["photo.jpg"])
        }
    }

    // MARK: Planning

    @Test func nonImagesAreSkipped() throws {
        try withTempDirectory { dir in
            let text = dir.appendingPathComponent("notes.txt")
            try Data("hello".utf8).write(to: text)
            let png = dir.appendingPathComponent("a.png")
            try writeFixture(patternImage(width: 8, height: 8), as: .png, to: png)

            #expect(!ImageConverter.isConvertibleImage(text))
            #expect(!ImageConverter.isConvertibleImage(dir))
            #expect(!ImageConverter.isConvertibleImage(dir.appendingPathComponent("missing.png")))
            #expect(ImageConverter.isConvertibleImage(png))

            let plan = ImageConverter.plan(.jpg, for: [text, png])
            #expect(plan.skipped == 1)
            #expect(plan.jobs.count == 1)
        }
    }

    @Test func unwritableFolderFallsBackToDownloads() throws {
        try withTempDirectory { dir in
            let locked = dir.appendingPathComponent("locked", isDirectory: true)
            let downloads = dir.appendingPathComponent("downloads", isDirectory: true)
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            let png = locked.appendingPathComponent("a.png")
            try writeFixture(patternImage(width: 8, height: 8), as: .png, to: png)

            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
            guard !FileManager.default.isWritableFile(atPath: locked.path) else { return } // running as root

            let plan = ImageConverter.plan(.jpg, for: [png], downloadsDirectory: downloads)
            #expect(plan.usedDownloads)
            let job = try #require(plan.jobs.first)
            #expect(job.destination == downloads.appendingPathComponent("a.jpg"))
            try job.perform()
            #expect(FileManager.default.fileExists(atPath: job.destination.path))
        }
    }

    // MARK: Pipeline

    @Test func heicToJPGIsValidJPEGWithSamePixelSize() throws {
        try withTempDirectory { dir in
            let heic = dir.appendingPathComponent("fixture.heic")
            try writeFixture(patternImage(width: 320, height: 240), as: .heic, to: heic)

            let job = try #require(ImageConverter.plan(.jpg, for: [heic]).jobs.first)
            try job.perform()

            #expect(job.destination.lastPathComponent == "fixture.jpg")
            let data = try Data(contentsOf: job.destination)
            #expect(Array(data.prefix(3)) == [0xFF, 0xD8, 0xFF])
            #expect(Array(data.suffix(2)) == [0xFF, 0xD9])
            #expect(typeIdentifier(of: job.destination) == UTType.jpeg.identifier)
            let size = try #require(pixelSize(of: job.destination))
            #expect(size.width == 320 && size.height == 240)
        }
    }

    @Test func conversionNeverTouchesTheOriginal() throws {
        try withTempDirectory { dir in
            let heic = dir.appendingPathComponent("a.heic")
            let png = dir.appendingPathComponent("b.png")
            try writeFixture(patternImage(width: 64, height: 48), as: .heic, to: heic)
            try writeFixture(patternImage(width: 64, height: 48), as: .png, to: png)
            let before = [try sha256(heic), try sha256(png)]

            for action in ConversionAction.allCases {
                let plan = ImageConverter.plan(action, for: [heic, png])
                #expect(plan.jobs.count == 2)
                for job in plan.jobs {
                    try job.perform()
                    #expect(FileManager.default.fileExists(atPath: job.destination.path))
                    #expect(job.destination != job.source)
                }
            }

            let after = [try sha256(heic), try sha256(png)]
            #expect(after == before)
        }
    }

    @Test func resizeHalvesBothSides() throws {
        try withTempDirectory { dir in
            let png = dir.appendingPathComponent("a.png")
            try writeFixture(patternImage(width: 320, height: 240), as: .png, to: png)

            let job = try #require(ImageConverter.plan(.resize50, for: [png]).jobs.first)
            try job.perform()

            #expect(job.destination.lastPathComponent == "a-50.png")
            let size = try #require(pixelSize(of: job.destination))
            #expect(size.width == 160 && size.height == 120)
        }
    }

    @Test func orientationIsAppliedToThePixels() throws {
        try withTempDirectory { dir in
            let jpeg = dir.appendingPathComponent("rotated.jpg")
            // Stored 40 × 20 with EXIF orientation 6 (rotate 90° clockwise): displays as 20 × 40.
            try writeFixture(patternImage(width: 40, height: 20), as: .jpeg, to: jpeg, orientation: 6)
            let stored = try #require(pixelSize(of: jpeg))
            #expect(stored.width == 40 && stored.height == 20)
            #expect(orientation(of: jpeg) == 6)

            for action in [ConversionAction.png, .webp, .heic] {
                let job = try #require(ImageConverter.plan(action, for: [jpeg]).jobs.first)
                try job.perform()
                let size = try #require(pixelSize(of: job.destination))
                #expect(size.width == 20 && size.height == 40, "\(action)")
                #expect((orientation(of: job.destination) ?? 1) == 1, "\(action)")
            }
        }
    }

    @Test func webPOutputIsValidAndKeepsSize() throws {
        try withTempDirectory { dir in
            let png = dir.appendingPathComponent("a.png")
            try writeFixture(patternImage(width: 128, height: 96), as: .png, to: png)

            let job = try #require(ImageConverter.plan(.webp, for: [png]).jobs.first)
            try job.perform()

            let data = try Data(contentsOf: job.destination)
            #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
            #expect(String(decoding: data[8..<12], as: UTF8.self) == "WEBP")
            let size = try #require(pixelSize(of: job.destination))
            #expect(size.width == 128 && size.height == 96)
        }
    }

    @Test func jpegFlattensTransparencyOntoWhite() throws {
        try withTempDirectory { dir in
            let png = dir.appendingPathComponent("clear.png")
            try writeFixture(patternImage(width: 32, height: 32, transparent: true), as: .png, to: png)

            let job = try #require(ImageConverter.plan(.jpg, for: [png]).jobs.first)
            try job.perform()

            let pixel = try #require(firstPixel(of: job.destination))
            #expect(pixel.allSatisfy { $0 >= 250 })
        }
    }

    @Test func compressShrinksJPEGAndKeepsItsMetadata() throws {
        try withTempDirectory { dir in
            let jpeg = dir.appendingPathComponent("shot.jpg")
            try writeFixture(patternImage(width: 256, height: 256), as: .jpeg, to: jpeg, quality: 0.99, dateTimeOriginal: "2024:01:02 03:04:05")

            let job = try #require(ImageConverter.plan(.compress, for: [jpeg]).jobs.first)
            try job.perform()

            #expect(job.destination.lastPathComponent == "shot-compressed.jpg")
            #expect(typeIdentifier(of: job.destination) == UTType.jpeg.identifier)
            let before = try fileSize(jpeg)
            let after = try fileSize(job.destination)
            #expect(after < before)
            #expect(dateTimeOriginal(of: job.destination) == "2024:01:02 03:04:05")
        }
    }

    // MARK: Fixtures

    private func withTempDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("perch-convert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir)
    }

    /// A detailed, deterministic gradient so lossy quality visibly changes the file size.
    private func patternImage(width: Int, height: Int, transparent: Bool = false) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        if !transparent {
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    pixels[i] = UInt8(x * 255 / max(width - 1, 1))
                    pixels[i + 1] = UInt8(y * 255 / max(height - 1, 1))
                    pixels[i + 2] = UInt8((x ^ y) & 0xFF)
                    pixels[i + 3] = 255
                }
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    private struct FixtureError: Error { let type: UTType }

    private func writeFixture(
        _ image: CGImage,
        as type: UTType,
        to url: URL,
        orientation: Int? = nil,
        quality: Double = 0.9,
        dateTimeOriginal: String? = nil
    ) throws {
        guard let sink = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw FixtureError(type: type)
        }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        if let dateTimeOriginal {
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: dateTimeOriginal]
        }
        CGImageDestinationAddImage(sink, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(sink) else { throw FixtureError(type: type) }
    }

    private func properties(of url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }

    /// Stored pixel size, before any orientation tag.
    private func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let props = properties(of: url),
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    private func orientation(of url: URL) -> Int? {
        properties(of: url)?[kCGImagePropertyOrientation] as? Int
    }

    private func dateTimeOriginal(of url: URL) -> String? {
        let exif = properties(of: url)?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        return exif?[kCGImagePropertyExifDateTimeOriginal] as? String
    }

    private func typeIdentifier(of url: URL) -> String? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceGetType($0) as String? }
    }

    /// RGBA of the top-left pixel after decoding into sRGB.
    private func firstPixel(of url: URL) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? rgba : nil
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.size] as? Int)
    }
}
