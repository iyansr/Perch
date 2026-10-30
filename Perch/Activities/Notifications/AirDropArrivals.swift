import CoreServices
import Foundation

/// Files AirDrop saved into Downloads. A transfer from a device on the same Apple ID (or a contact set to
/// auto-accept) never asks, so no "would like to share" notification exists; the only trace is the file
/// itself, which sharingd quarantines with its own name: `0081;6abb88a7;sharingd;<UUID>`
/// (flags; hex seconds since 1970; agent; event). Files of one transfer share the timestamp.
nonisolated enum AirDropQuarantine {
    static let attribute = "com.apple.quarantine"
    static let agent = "sharingd"

    /// The transfer time, when `value` is a quarantine string written by sharingd.
    static func transferDate(_ value: String) -> (key: String, date: Date)? {
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 3, fields[2] == agent, let seconds = UInt64(fields[1], radix: 16) else { return nil }
        return (String(fields[1]), Date(timeIntervalSince1970: TimeInterval(seconds)))
    }
}

/// Watches ~/Downloads and reports each finished AirDrop transfer once, as a group of files.
final class AirDropArrivals {
    struct Transfer: Equatable {
        /// The shared quarantine timestamp; stable for the files of one transfer.
        let key: String
        let files: [URL]
    }

    /// Files quarantined longer ago than this when first seen are old, not arriving.
    static let freshness: TimeInterval = 120
    /// A transfer is reported once no file has joined it for this long.
    static let settle: TimeInterval = 1.5

    private let folder: URL
    private let onTransfer: (Transfer) -> Void
    private var stream: FSEventStreamRef?
    private var known: Set<String> = []
    private var building: [String: (files: [URL], lastAdded: Date)] = [:]
    private var settleTimer: Timer?

    init(folder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"),
         onTransfer: @escaping (Transfer) -> Void) {
        self.folder = folder
        self.onTransfer = onTransfer
    }

    func start() {
        guard stream == nil else { return }
        known = Set(names())
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let arrivals = Unmanaged<AirDropArrivals>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { arrivals.scan() }
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        settleTimer?.invalidate()
        settleTimer = nil
        building.removeAll()
        known.removeAll()
    }

    /// Picks up new sharingd-quarantined files; reports transfers that have settled.
    func scan(now: Date = Date()) {
        for name in names() where !known.contains(name) {
            known.insert(name)
            let url = folder.appendingPathComponent(name)
            guard let value = DownloadProbe.readAttribute(AirDropQuarantine.attribute, of: url)
                    .flatMap({ String(data: $0, encoding: .utf8) }),
                  let transfer = AirDropQuarantine.transferDate(value),
                  now.timeIntervalSince(transfer.date) < Self.freshness
            else { continue }
            building[transfer.key, default: ([], now)].files.append(url)
            building[transfer.key]?.lastAdded = now
        }
        flush(now: now)
    }

    /// Reports transfers whose last file arrived at least `settle` ago; waits for the rest.
    func flush(now: Date = Date()) {
        for (key, entry) in building where now.timeIntervalSince(entry.lastAdded) >= Self.settle {
            building[key] = nil
            onTransfer(Transfer(key: key, files: entry.files.sorted { $0.lastPathComponent < $1.lastPathComponent }))
        }
        settleTimer?.invalidate()
        settleTimer = nil
        guard !building.isEmpty, stream != nil else { return }
        settleTimer = Timer.scheduledTimer(withTimeInterval: Self.settle, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }
    }
}
