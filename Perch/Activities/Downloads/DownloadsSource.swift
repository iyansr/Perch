import AppKit
import CoreServices
import SwiftUI

/// Recognises in-progress downloads in a folder and reads how far along they are.
nonisolated enum DownloadProbe {
    /// Partial-file suffixes: Chrome, Firefox, Safari (a bundle).
    static let partialSuffixes = [".crdownload", ".part", ".download"]
    /// Finder and other `NSProgress`-publishing copiers set this on the file being written.
    static let progressAttribute = "com.apple.progress.fractionCompleted"

    /// `report.pdf.crdownload` → `report.pdf`; nil for names that are not partial downloads.
    static func finalName(forPartial name: String) -> String? {
        for suffix in partialSuffixes where name.count > suffix.count && name.lowercased().hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return nil
    }

    /// The xattr holds the fraction as ASCII text, e.g. `0.4231`.
    static func fraction(attribute data: Data) -> Double? {
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)),
              let value = Double(text), value.isFinite
        else { return nil }
        return min(max(value, 0), 1)
    }

    /// Safari keeps byte counts in the `.download` bundle's Info.plist.
    static func safariProgress(info: [String: Any]) -> (received: Int64, total: Int64?) {
        let received = (info["DownloadEntryProgressBytesSoFar"] as? NSNumber)?.int64Value ?? 0
        let total = (info["DownloadEntryProgressTotalToLoad"] as? NSNumber)?.int64Value
        return (received, total.flatMap { $0 > 0 ? $0 : nil })
    }

    static func readAttribute(_ name: String, of url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
            return read > 0 ? data.prefix(read) : nil
        }
    }
}

/// Downloads landing in ~/Downloads as progress activities; the finished one offers Reveal in Finder.
/// Watches the folder with FSEvents (file-level, so xattr and size changes arrive too).
final class DownloadsSource: ActivitySource {
    static let id = "downloads"
    static let info = ActivitySourceInfo(
        title: "Downloads",
        detail: "Progress of files arriving in Downloads from Safari, Chrome, Firefox or a Finder copy. macOS may ask once for access to the Downloads folder.",
        symbol: "arrow.down.circle.fill",
        tint: .cyan,
        permission: nil
    )

    /// Partial files older than this when first seen are leftovers from a crashed download.
    private static let freshness: TimeInterval = 120
    /// A download with no change for this long is treated as abandoned.
    private static let stallLimit: TimeInterval = 300

    private struct Tracked {
        let activityID: UUID
        let finalURL: URL
        var lastChange: Date
        var signature: String
    }

    private let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    private weak var center: ActivityCenter?
    private var stream: FSEventStreamRef?
    private var tracked: [URL: Tracked] = [:]
    private var stallTimer: Timer?

    func start(center: ActivityCenter) {
        self.center = center
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let source = Unmanaged<DownloadsSource>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { source.rescan() }
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
        stallTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        rescan()
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        stallTimer?.invalidate()
        stallTimer = nil
        for item in tracked.values { center?.dismiss(item.activityID) }
        tracked.removeAll()
    }

    private func rescan() {
        guard let center else { return }
        let now = Date()
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        var seen = Set<URL>()

        for url in entries {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let modified = values?.contentModificationDate ?? .distantPast
            let progressAttribute = DownloadProbe.readAttribute(DownloadProbe.progressAttribute, of: url)
            let finalName = DownloadProbe.finalName(forPartial: url.lastPathComponent)
                ?? (progressAttribute != nil ? url.lastPathComponent : nil)
            guard let finalName else { continue }
            seen.insert(url)

            let (fraction, detail) = progress(of: url, attribute: progressAttribute, size: values?.fileSize)
            let signature = "\(detail)|\(fraction ?? -1)"
            if var item = tracked[url] {
                if item.signature != signature {
                    item.signature = signature
                    item.lastChange = now
                    tracked[url] = item
                    center.update(item.activityID) { activity in
                        activity.detail = detail
                        activity.progress = fraction.map { .fraction($0) } ?? .indeterminate
                    }
                } else if now.timeIntervalSince(item.lastChange) > Self.stallLimit {
                    center.dismiss(item.activityID)
                    tracked[url] = nil
                }
                continue
            }
            guard now.timeIntervalSince(modified) < Self.freshness else { continue }
            let item = Tracked(activityID: UUID(), finalURL: folder.appendingPathComponent(finalName), lastChange: now, signature: signature)
            tracked[url] = item
            center.show(Activity(
                id: item.activityID, kind: .download(path: url.path), symbol: "arrow.down.circle.fill",
                title: finalName, detail: detail, status: .running,
                progress: fraction.map { .fraction($0) } ?? .indeterminate, updatedAt: now
            ))
        }

        // Gone partials: renamed to the final name (done) or deleted (cancelled). A Finder copy keeps
        // its name and drops out of `seen` once its progress attribute is removed, so it lands here too.
        for (url, item) in tracked where !seen.contains(url) {
            tracked[url] = nil
            if FileManager.default.fileExists(atPath: item.finalURL.path) {
                center.updateProgress(item.activityID, fraction: 1, detail: "Downloaded", outputs: [item.finalURL])
                center.finish(item.activityID, status: .done)
            } else {
                center.dismiss(item.activityID)
            }
        }
    }

    private func progress(of url: URL, attribute: Data?, size: Int?) -> (Double?, String) {
        if let attribute, let fraction = DownloadProbe.fraction(attribute: attribute) {
            return (fraction, "\(Int((fraction * 100).rounded()))%")
        }
        if url.pathExtension.lowercased() == "download",
           let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist")) as? [String: Any] {
            let (received, total) = DownloadProbe.safariProgress(info: info)
            let receivedText = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
            guard let total else { return (nil, receivedText) }
            let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            return (Double(received) / Double(total), "\(receivedText) of \(totalText)")
        }
        // Chrome/Firefox write the file sparse and publish no total: size so far, no fraction.
        return (nil, size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "Downloading")
    }
}
