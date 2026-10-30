import AppKit
import Foundation

/// The track the system reports as playing, with enough timing to extrapolate the position locally.
struct NowPlaying: Equatable {
    /// App that reports the media (a browser for web players).
    var bundleID: String
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    var duration: TimeInterval?
    /// Position at `elapsedAt`; `position(at:)` extrapolates from it.
    var elapsed: TimeInterval
    var elapsedAt: Date
    var rate: Double
    var artwork: NSImage?
    /// Average artwork colour; tints the music card.
    var tint: NSColor?

    func position(at date: Date) -> TimeInterval {
        guard isPlaying else { return elapsed }
        let position = elapsed + date.timeIntervalSince(elapsedAt) * (rate > 0 ? rate : 1)
        return duration.map { min(position, $0) } ?? position
    }

    /// Same track, ignoring position and play state: a change resets the activity's ordering time.
    func isSameTrack(as other: NowPlaying) -> Bool {
        bundleID == other.bundleID && title == other.title && artist == other.artist && album == other.album
    }

    static func == (lhs: NowPlaying, rhs: NowPlaying) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.title == rhs.title && lhs.artist == rhs.artist && lhs.album == rhs.album
            && lhs.isPlaying == rhs.isPlaying && lhs.duration == rhs.duration && lhs.elapsed == rhs.elapsed
            && lhs.elapsedAt == rhs.elapsedAt && lhs.rate == rhs.rate
            && lhs.artwork === rhs.artwork && lhs.tint == rhs.tint
    }
}

/// One now-playing state as read from a player, before artwork is decoded.
nonisolated struct MediaSnapshot: Equatable {
    var bundleID: String
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    var duration: TimeInterval?
    var elapsed: TimeInterval
    var elapsedAt: Date
    var rate: Double
    var artworkData: Data?
}

/// Folds `mediaremote-adapter.pl stream --micros` output into the current state.
/// Each line is `{"type":"data","diff":Bool,"payload":{…}}`; a diff payload updates the last full one,
/// a `null` value removes its key, and an empty full payload means nothing is playing.
nonisolated struct AdapterStream {
    private var payload: [String: Any] = [:]

    /// Applies one output line. Returns false when the line is not adapter data (ignored).
    @discardableResult
    mutating func apply(line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "data",
              let update = object["payload"] as? [String: Any]
        else { return false }
        if object["diff"] as? Bool == true {
            for (key, value) in update {
                if value is NSNull { payload.removeValue(forKey: key) } else { payload[key] = value }
            }
        } else {
            payload = update
        }
        return true
    }

    /// The current track, or nil when no player reports one. Untitled media (QuickTime, some web
    /// video) comes through with an empty title; the source names it after the app.
    var snapshot: MediaSnapshot? {
        guard let bundleID = payload["parentApplicationBundleIdentifier"] as? String ?? payload["bundleIdentifier"] as? String
        else { return nil }
        let micros = { (key: String) in (payload[key] as? NSNumber).map { $0.doubleValue / 1_000_000 } }
        let rate = (payload["playbackRate"] as? NSNumber)?.doubleValue
        return MediaSnapshot(
            bundleID: bundleID,
            title: payload["title"] as? String ?? "",
            artist: payload["artist"] as? String ?? "",
            album: payload["album"] as? String ?? "",
            isPlaying: payload["playing"] as? Bool ?? false,
            duration: micros("durationMicros").flatMap { $0 > 0 ? $0 : nil },
            elapsed: micros("elapsedTimeMicros") ?? 0,
            elapsedAt: micros("timestampEpochMicros").map { Date(timeIntervalSince1970: $0) } ?? Date(),
            rate: rate ?? 1,
            artworkData: (payload["artworkData"] as? String).flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
        )
    }
}
