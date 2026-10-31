import Foundation
import Testing
@testable import Perch

@MainActor
struct NowPlayingSourceTests {
    @Test func pausedMediaExpiresDespiteRepeatedSnapshotsAndReturnsOnPlayback() {
        let suite = "NowPlayingSourceTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let center = ActivityCenter()
        var now = Date(timeIntervalSince1970: 1_000)
        let source = NowPlayingSource(center: center, settings: settings, now: { now })
        var snapshot = MediaSnapshot(bundleID: "test.player", title: "Track", artist: "Artist", album: "Album",
                                     isPlaying: false, duration: 600, elapsed: 10, elapsedAt: now, rate: 0)
        source.apply(snapshot)
        now.addTimeInterval(299)
        source.apply(snapshot)
        #expect(center.items.count == 1)
        now.addTimeInterval(1)
        source.refreshVisibility()
        #expect(center.items.isEmpty)
        source.apply(snapshot)
        #expect(center.items.isEmpty)
        snapshot.isPlaying = true
        source.apply(snapshot)
        #expect(center.items.first?.media?.isPlaying == true)
        now.addTimeInterval(1_000)
        source.refreshVisibility()
        #expect(center.items.first?.media?.isPlaying == true)
        source.apply(nil)
        #expect(center.items.isEmpty)
    }

    @Test func changingTimeoutUsesOriginalPauseTimeAndPersists() {
        let suite = "NowPlayingSourceTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let center = ActivityCenter()
        var now = Date(timeIntervalSince1970: 1_000)
        let source = NowPlayingSource(center: center, settings: settings, now: { now })
        let snapshot = MediaSnapshot(bundleID: "test.player", title: "Track", artist: "Artist", album: "Album",
                                     isPlaying: false, duration: 600, elapsed: 10, elapsedAt: now, rate: 0)
        source.apply(snapshot)
        now.addTimeInterval(120)
        settings.mediaInactivityMinutes = 1
        source.refreshVisibility()
        #expect(center.items.isEmpty)
        settings.mediaInactivityMinutes = 3
        source.refreshVisibility()
        #expect(center.items.first?.media?.title == "Track")
        #expect(AppSettings(defaults: defaults).mediaInactivityMinutes == 3)
        now.addTimeInterval(60)
        source.refreshVisibility()
        #expect(center.items.isEmpty)
        source.stop()
        settings.mediaInactivityMinutes = 60
        source.refreshVisibility()
        #expect(center.items.isEmpty)
    }

    @Test func aNewPauseGetsItsOwnDeadline() {
        let suite = "NowPlayingSourceTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = ActivityCenter()
        var now = Date(timeIntervalSince1970: 1_000)
        let source = NowPlayingSource(center: center, settings: AppSettings(defaults: defaults), now: { now })
        var snapshot = MediaSnapshot(bundleID: "test.player", title: "Track", artist: "Artist", album: "Album",
                                     isPlaying: false, duration: 600, elapsed: 10, elapsedAt: now, rate: 0)
        source.apply(snapshot)
        now.addTimeInterval(300)
        source.refreshVisibility()
        #expect(center.items.isEmpty)
        snapshot.isPlaying = true
        source.apply(snapshot)
        now.addTimeInterval(30)
        snapshot.isPlaying = false
        source.apply(snapshot)
        now.addTimeInterval(299)
        source.refreshVisibility()
        #expect(center.items.first?.media?.isPlaying == false)
        now.addTimeInterval(1)
        source.refreshVisibility()
        #expect(center.items.isEmpty)
    }
}
