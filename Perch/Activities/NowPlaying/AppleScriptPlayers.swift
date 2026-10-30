import AppKit
import Foundation

/// Fallback when the MediaRemote adapter is broken: Music and Spotify announce changes through
/// distributed notifications, and AppleScript reads the details and sends the controls.
/// Needs Automation permission per app (asked on first query). Players are only queried while
/// running, because `tell application` would launch them.
final class AppleScriptPlayers {
    nonisolated struct Player: Sendable {
        let bundleID: String
        let notification: String
        /// Returns state, title, artist, album, duration (s), position (s), artwork (file path or URL),
        /// separated by U+001F; or "stopped".
        let query: String
    }

    static let music = Player(
        bundleID: "com.apple.Music",
        notification: "com.apple.Music.playerInfo",
        query: """
        tell application id "com.apple.Music"
            set s to player state as string
            if s is "stopped" then return "stopped"
            set t to current track
            set art to ""
            try
                set p to (POSIX path of (path to temporary items)) & "perch-music-artwork"
                set f to open for access (POSIX file p) with write permission
                set eof f to 0
                write (raw data of artwork 1 of t) to f
                close access f
                set art to p
            end try
            set sep to character id 31
            return s & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & (duration of t) & sep & player position & sep & art
        end tell
        """
    )

    static let spotify = Player(
        bundleID: "com.spotify.client",
        notification: "com.spotify.client.PlaybackStateChanged",
        query: """
        tell application id "com.spotify.client"
            set s to player state as string
            if s is "stopped" then return "stopped"
            set t to current track
            set sep to character id 31
            return s & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & ((duration of t) / 1000) & sep & player position & sep & (artwork url of t)
        end tell
        """
    )

    enum Command {
        case togglePlayPause, nextTrack, previousTrack
        case seek(TimeInterval)

        var script: String {
            switch self {
            case .togglePlayPause: "playpause"
            case .nextTrack: "next track"
            case .previousTrack: "previous track"
            case let .seek(position): "set player position to \(max(0, position))"
            }
        }
    }

    private let players = [music, spotify]
    private let queue = DispatchQueue(label: "perch.applescript-players")
    private var observers: [NSObjectProtocol] = []
    private var onUpdate: ((MediaSnapshot?) -> Void)?
    /// Last reported state per player; the newest playing one wins.
    private var states: [String: MediaSnapshot] = [:]

    func start(onUpdate: @escaping (MediaSnapshot?) -> Void) {
        self.onUpdate = onUpdate
        let center = DistributedNotificationCenter.default()
        for player in players {
            observers.append(center.addObserver(forName: Notification.Name(player.notification), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(player) }
            })
            refresh(player)
        }
    }

    func stop() {
        observers.forEach(DistributedNotificationCenter.default().removeObserver)
        observers.removeAll()
        onUpdate = nil
        states.removeAll()
    }

    func send(_ command: Command, to bundleID: String) {
        guard Self.isRunning(bundleID) else { return }
        let script = "tell application id \"\(bundleID)\" to \(command.script)"
        queue.async { _ = Self.run(script) }
    }

    private func refresh(_ player: Player) {
        guard Self.isRunning(player.bundleID) else {
            update(player.bundleID, nil)
            return
        }
        queue.async { [weak self] in
            let snapshot = Self.run(player.query).flatMap { Self.parse($0, bundleID: player.bundleID) }
            DispatchQueue.main.async { self?.update(player.bundleID, snapshot) }
        }
    }

    private func update(_ bundleID: String, _ snapshot: MediaSnapshot?) {
        states[bundleID] = snapshot
        let current = states.values.first { $0.isPlaying } ?? states.values.first
        onUpdate?(current)
    }

    /// Parses the query's output; artwork is a file path (Music) or an http URL (Spotify).
    nonisolated static func parse(_ output: String, bundleID: String) -> MediaSnapshot? {
        let fields = output.trimmingCharacters(in: .newlines).components(separatedBy: "\u{1F}")
        guard fields.count >= 7, !fields[1].isEmpty else { return nil }
        // AppleScript formats reals with the user's decimal separator.
        let number = { (text: String) in Double(text.replacingOccurrences(of: ",", with: ".")) }
        let artwork = fields[6]
        let artworkData: Data? = if artwork.hasPrefix("http"), let url = URL(string: artwork) {
            try? Data(contentsOf: url)
        } else if !artwork.isEmpty {
            try? Data(contentsOf: URL(fileURLWithPath: artwork))
        } else {
            nil
        }
        return MediaSnapshot(
            bundleID: bundleID,
            title: fields[1],
            artist: fields[2],
            album: fields[3],
            isPlaying: fields[0] == "playing",
            duration: number(fields[4]),
            elapsed: number(fields[5]) ?? 0,
            elapsedAt: Date(),
            rate: 1,
            artworkData: artworkData
        )
    }

    private nonisolated static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// `osascript` rather than `NSAppleScript`, which must stay on the main thread.
    private nonisolated static func run(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
