import Foundation

/// Runs the bundled `mediaremote-adapter.pl` under `/usr/bin/perl`, which macOS still lets read
/// MediaRemote (since 15.4 our own process gets nothing). Kept in one file so a macOS update that
/// breaks it again is contained here; `NowPlayingSource` then falls back to AppleScript.
final class MediaRemoteAdapter {
    /// MediaRemote command IDs the script's `send` accepts.
    enum Command: Int {
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    private static let perl = URL(fileURLWithPath: "/usr/bin/perl")

    private let directory: URL
    private var process: Process?
    private var stopping = false

    /// nil when the app bundle lacks the adapter (e.g. a build without the script phase).
    init?(bundle: Bundle = .main) {
        guard let directory = bundle.resourceURL?.appendingPathComponent("MediaRemoteAdapter"),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("mediaremote-adapter.pl").path),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("MediaRemoteAdapter.framework").path)
        else { return nil }
        self.directory = directory
    }

    /// Streams state changes to `onUpdate` on the main queue. `onFailure` fires once if the
    /// script exits on its own with an error, meaning MediaRemote is no longer reachable this way.
    func start(onUpdate: @escaping @MainActor (MediaSnapshot?) -> Void, onFailure: @escaping @MainActor () -> Void) {
        guard process == nil else { return }
        stopping = false
        reapOrphanedStream()
        let process = makeProcess(["stream", "--micros", "--debounce=50", "--allow-missing-title"])
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        // Artwork arrives base64-encoded inside a line, so a line can span many reads.
        let reader = StreamReader { snapshot in
            DispatchQueue.main.async { onUpdate(snapshot) }
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                reader.append(data)
            }
        }
        // `stream` runs until terminated, so any exit we did not ask for means the adapter broke.
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.stopping else { return }
                self.process = nil
                onFailure()
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            NSLog("Perch: media adapter failed to launch: \(error)")
            onFailure()
        }
    }

    /// A stream outlives Perch when Perch is killed (no `applicationWillTerminate`); it only exits on
    /// the next write into the dead pipe. Stop any left over from this bundle before starting another.
    private func reapOrphanedStream() {
        let reaper = Process()
        reaper.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        reaper.arguments = ["-f", directory.appendingPathComponent("mediaremote-adapter.pl").path + " .* stream"]
        reaper.standardOutput = FileHandle.nullDevice
        reaper.standardError = FileHandle.nullDevice
        try? reaper.run()
        reaper.waitUntilExit()
    }

    func stop() {
        stopping = true
        process?.terminate()
        process = nil
    }

    func send(_ command: Command) {
        runOnce(["send", String(command.rawValue)])
    }

    func seek(to position: TimeInterval) {
        runOnce(["seek", String(Int64(max(0, position) * 1_000_000))])
    }

    private func runOnce(_ arguments: [String]) {
        let process = makeProcess(arguments)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private func makeProcess(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = Self.perl
        process.arguments = [
            directory.appendingPathComponent("mediaremote-adapter.pl").path,
            directory.appendingPathComponent("MediaRemoteAdapter.framework").path,
        ] + arguments
        return process
    }
}

/// Splits the script's stdout into lines and folds each into the stream state.
/// `FileHandle` calls `append` serially on one background queue, so no locking is needed.
private nonisolated final class StreamReader: @unchecked Sendable {
    private var buffer = Data()
    private var stream = AdapterStream()
    private let onSnapshot: (MediaSnapshot?) -> Void

    init(onSnapshot: @escaping (MediaSnapshot?) -> Void) {
        self.onSnapshot = onSnapshot
    }

    func append(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty, stream.apply(line: line) { onSnapshot(stream.snapshot) }
        }
    }
}
