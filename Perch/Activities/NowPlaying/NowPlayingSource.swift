import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// System-wide now playing: one persistent activity while any player reports a track.
/// Reads through `MediaRemoteAdapter`; if that breaks, Music and Spotify via AppleScript.
final class NowPlayingSource: ActivitySource {
    static let id = "nowPlaying"
    static let info = ActivitySourceInfo(
        title: "Now Playing",
        detail: "Artwork and a waveform beside the notch; hover for controls and the scrubber.",
        symbol: "music.note",
        tint: .pink,
        permission: nil
    )

    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    private let activityID = UUID()
    private weak var center: ActivityCenter?
    private var adapter: MediaRemoteAdapter?
    private var fallback: AppleScriptPlayers?
    private(set) var current: NowPlaying?
    /// Decoded artwork for the last artwork bytes, so position updates do not decode again.
    private var artworkCache: (data: Data, image: NSImage?, tint: NSColor?)?
    /// When the current track first showed; orders the activity against other running ones.
    private var trackStartedAt = Date()

    func start(center: ActivityCenter) {
        self.center = center
        if let adapter = MediaRemoteAdapter() {
            self.adapter = adapter
            adapter.start(onUpdate: { [weak self] in self?.apply($0) }, onFailure: { [weak self] in self?.useFallback() })
        } else {
            useFallback()
        }
    }

    func stop() {
        adapter?.stop()
        adapter = nil
        fallback?.stop()
        fallback = nil
        current = nil
        artworkCache = nil
        center?.dismiss(activityID)
    }

    // MARK: Controls

    func togglePlayPause() {
        guard var media = current else { return }
        if let fallback {
            fallback.send(.togglePlayPause, to: media.bundleID)
        } else {
            adapter?.send(.togglePlayPause)
        }
        // Answer the click now; the player's own update follows.
        media.elapsed = media.position(at: Date())
        media.elapsedAt = Date()
        media.isPlaying.toggle()
        publish(media)
    }

    func nextTrack() {
        guard let media = current else { return }
        if let fallback { fallback.send(.nextTrack, to: media.bundleID) } else { adapter?.send(.nextTrack) }
    }

    func previousTrack() {
        guard let media = current else { return }
        if let fallback { fallback.send(.previousTrack, to: media.bundleID) } else { adapter?.send(.previousTrack) }
    }

    func seek(to position: TimeInterval) {
        guard var media = current else { return }
        if let fallback { fallback.send(.seek(position), to: media.bundleID) } else { adapter?.seek(to: position) }
        media.elapsed = position
        media.elapsedAt = Date()
        publish(media)
    }

    func openPlayer() {
        guard let bundleID = current?.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Updates

    private func useFallback() {
        guard fallback == nil else { return }
        NSLog("Perch: MediaRemote adapter unavailable; now playing falls back to AppleScript for Music and Spotify.")
        adapter?.stop()
        adapter = nil
        let fallback = AppleScriptPlayers()
        self.fallback = fallback
        fallback.start { [weak self] in self?.apply($0) }
    }

    private func apply(_ snapshot: MediaSnapshot?) {
        guard let snapshot else {
            current = nil
            center?.dismiss(activityID)
            return
        }
        let (artwork, tint) = decodeArtwork(snapshot.artworkData)
        let media = NowPlaying(
            bundleID: snapshot.bundleID,
            title: snapshot.title.isEmpty ? Self.appName(snapshot.bundleID) : snapshot.title,
            artist: snapshot.artist,
            album: snapshot.album,
            isPlaying: snapshot.isPlaying,
            duration: snapshot.duration,
            elapsed: snapshot.elapsed,
            elapsedAt: snapshot.elapsedAt,
            rate: snapshot.rate,
            artwork: artwork,
            tint: tint
        )
        if let current, current.isSameTrack(as: media) {} else { trackStartedAt = Date() }
        publish(media)
    }

    private static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return "Now Playing" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func publish(_ media: NowPlaying) {
        current = media
        var activity = Activity(
            id: activityID,
            kind: .nowPlaying(bundleID: media.bundleID),
            symbol: "music.note",
            title: media.title,
            detail: media.artist,
            status: .running,
            progress: .waveform(playing: media.isPlaying),
            updatedAt: trackStartedAt
        )
        activity.media = media
        center?.show(activity)
    }

    private func decodeArtwork(_ data: Data?) -> (NSImage?, NSColor?) {
        guard let data else { return (nil, nil) }
        if let cache = artworkCache, cache.data == data { return (cache.image, cache.tint) }
        let image = NSImage(data: data)
        let tint = image.map { Self.averageColor(of: $0) } ?? nil
        artworkCache = (data, image, tint)
        return (image, tint)
    }

    private static func averageColor(of image: NSImage) -> NSColor? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cgImage)
        let filter = CIFilter.areaAverage()
        filter.inputImage = input
        filter.extent = input.extent
        guard let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: nil)
        return NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }
}
