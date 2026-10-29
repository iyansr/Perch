import AppKit
import ImageIO
import os
import UniformTypeIdentifiers

/// What a batch will do, resolved up front so output names never collide inside the batch.
nonisolated struct ConversionPlan: Sendable {
    var jobs: [ConversionJob] = []
    /// Inputs that are not readable images.
    var skipped = 0
    var usedDownloads = false
}

/// Converts dropped images. One `run` is one batch and one `Activity` with a determinate ring.
final class ImageConverter {
    nonisolated static let maxConcurrent = 4
    private nonisolated static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Perch", category: "Convert")

    private let activities: ActivityCenter

    init(activities: ActivityCenter) {
        self.activities = activities
    }

    /// True when the file's type conforms to `public.image` and ImageIO can decode it.
    nonisolated static func isConvertibleImage(_ url: URL) -> Bool {
        openImageSource(url) != nil
    }

    /// Starts a batch and returns immediately; the returned id is the batch's Activity id.
    /// Encoding runs on detached tasks, at most `maxConcurrent` at a time. When the batch ends, Finder reveals the outputs.
    @discardableResult
    func run(_ action: ConversionAction, on urls: [URL]) -> UUID {
        let id = UUID()
        let total = urls.count
        guard total > 0 else { return id }

        activities.startProgress(
            id: id,
            kind: .conversion(batchID: id),
            symbol: action.symbol,
            title: Self.title(for: action),
            detail: Self.runningDetail(done: 0, total: total)
        )

        Task.detached(priority: .userInitiated) { [weak self] in
            let clock = ContinuousClock()
            let started = clock.now
            let plan = Self.plan(action, for: urls)

            var done = plan.skipped
            var failed = plan.skipped
            var outputs: [(index: Int, url: URL)] = []
            if done > 0 { await self?.report(id, done: done, total: total) }

            await withTaskGroup(of: (Int, Result<URL, Error>).self) { group in
                var cursor = 0
                var running = 0
                while cursor < plan.jobs.count || running > 0 {
                    while running < Self.maxConcurrent, cursor < plan.jobs.count {
                        let index = cursor
                        let job = plan.jobs[index]
                        group.addTask { (index, Self.perform(job)) }
                        cursor += 1
                        running += 1
                    }
                    guard let (index, result) = await group.next() else { break }
                    running -= 1
                    done += 1
                    switch result {
                    case let .success(url): outputs.append((index, url))
                    case .failure: failed += 1
                    }
                    await self?.report(id, done: done, total: total)
                }
            }

            let revealed = outputs.sorted { $0.index < $1.index }.map(\.url)
            Self.log.info("batch \(action.rawValue, privacy: .public): \(revealed.count) ok, \(failed) failed in \(clock.now - started, privacy: .public)")
            await self?.complete(id, action: action, outputs: revealed, failed: failed, usedDownloads: plan.usedDownloads)
        }
        return id
    }

    // MARK: Main-actor activity updates

    private func report(_ id: UUID, done: Int, total: Int) {
        activities.updateProgress(id, fraction: Double(done) / Double(total), detail: Self.runningDetail(done: done, total: total))
    }

    private func complete(_ id: UUID, action: ConversionAction, outputs: [URL], failed: Int, usedDownloads: Bool) {
        let detail = Self.summary(action, converted: outputs.count, failed: failed, usedDownloads: usedDownloads)
        activities.updateProgress(id, detail: detail, outputs: outputs)
        activities.finish(id, status: outputs.isEmpty ? .failed : .done)
        if !outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
        }
    }

    // MARK: Planning

    /// Resolves output location, format and name for every input. Pure apart from reading the file system.
    /// `downloadsDirectory` is injectable for tests.
    nonisolated static func plan(_ action: ConversionAction, for urls: [URL], downloadsDirectory: URL? = nil) -> ConversionPlan {
        let fileManager = FileManager.default
        let downloads = downloadsDirectory
            ?? fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")

        var plan = ConversionPlan()
        var claimed = Set<String>()
        for url in urls {
            guard let imageSource = openImageSource(url) else {
                plan.skipped += 1
                continue
            }
            let sourceFormat = CGImageSourceGetType(imageSource)
                .flatMap { UTType($0 as String) }
                .flatMap { ConversionFormat(type: $0) }
            let (format, quality) = ConversionJob.target(for: action, source: sourceFormat)

            var folder = url.deletingLastPathComponent()
            if !fileManager.isWritableFile(atPath: folder.path) {
                folder = downloads
                plan.usedDownloads = true
            }

            let name = outputName(
                stem: url.deletingPathExtension().lastPathComponent,
                action: action,
                ext: outputExtension(for: url, action: action, format: format),
                isTaken: { candidate in
                    let path = folder.appendingPathComponent(candidate).path
                    return claimed.contains(path.lowercased()) || fileManager.fileExists(atPath: path)
                }
            )
            let destination = folder.appendingPathComponent(name)
            claimed.insert(destination.path.lowercased())
            plan.jobs.append(ConversionJob(source: url, destination: destination, action: action, format: format, quality: quality))
        }
        return plan
    }

    /// `stem-<suffix>.<ext>`; a taken name gets ` 2`, ` 3`, … appended to the stem part (`photo 2.jpg`).
    /// Suffixes: `-compressed` (Compress), `-50` (Resize 50%), none for a format change.
    nonisolated static func outputName(stem: String, action: ConversionAction, ext: String, isTaken: (String) -> Bool) -> String {
        let base = stem + action.suffix
        var candidate = "\(base).\(ext)"
        var counter = 2
        while isTaken(candidate) {
            candidate = "\(base) \(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    /// Resize and Compress keep the source's own extension (`.jpeg` stays `.jpeg`) when the format is unchanged.
    private nonisolated static func outputExtension(for url: URL, action: ConversionAction, format: ConversionFormat) -> String {
        let sourceExtension = url.pathExtension
        guard action == .resize50 || action == .compress,
              !sourceExtension.isEmpty,
              let sourceType = UTType(filenameExtension: sourceExtension),
              ConversionFormat(type: sourceType) == format
        else { return format.fileExtension }
        return sourceExtension
    }

    private nonisolated static func openImageSource(_ url: URL) -> CGImageSource? {
        guard url.isFileURL,
              let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
              type.conforms(to: .image),
              let imageSource = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(imageSource) > 0
        else { return nil }
        return imageSource
    }

    // MARK: Execution

    private nonisolated static func perform(_ job: ConversionJob) -> Result<URL, Error> {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            try job.perform()
            log.info("\(job.source.lastPathComponent) → \(job.destination.lastPathComponent) in \(clock.now - started, privacy: .public)")
            return .success(job.destination)
        } catch {
            log.error("\(job.source.lastPathComponent) failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    // MARK: Text

    private static func title(for action: ConversionAction) -> String {
        switch action {
        case .png, .jpg, .webp, .heic: "Converting to \(action.title)"
        case .resize50: "Resizing images"
        case .compress: "Compressing images"
        }
    }

    private static func runningDetail(done: Int, total: Int) -> String {
        "\(done) of \(total)"
    }

    private static func summary(_ action: ConversionAction, converted: Int, failed: Int, usedDownloads: Bool) -> String {
        var parts: [String] = []
        if converted > 0 { parts.append("\(converted) \(action.pastTense)") }
        if failed > 0 { parts.append("\(failed) failed") }
        if converted > 0, usedDownloads { parts.append("saved to Downloads") }
        return parts.joined(separator: " · ")
    }
}
