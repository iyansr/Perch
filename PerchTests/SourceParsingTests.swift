import Foundation
import Testing
@testable import Perch

private final class FixtureToken {}

private func fixtureURL(_ name: String, _ ext: String) throws -> URL {
    try #require(Bundle(for: FixtureToken.self).url(forResource: name, withExtension: ext))
}

struct AdapterStreamTests {
    private func lines() throws -> [Data] {
        let text = try String(contentsOf: try fixtureURL("adapter-stream", "jsonl"), encoding: .utf8)
        return text.split(separator: "\n").map { Data($0.utf8) }
    }

    @Test func fullPayloadThenDiffsThenNothingPlaying() throws {
        let lines = try lines()
        var stream = AdapterStream()

        let applied = stream.apply(line: lines[0])
        #expect(applied)
        let playing = try #require(stream.snapshot)
        #expect(playing.bundleID == "com.spotify.client")
        #expect(playing.title == "Teardrop")
        #expect(playing.artist == "Massive Attack")
        #expect(playing.isPlaying)
        #expect(playing.duration == 330)
        #expect(playing.elapsed == 155)
        #expect(playing.elapsedAt == Date(timeIntervalSince1970: 1_793_350_000))
        #expect(playing.artworkData != nil)

        // A diff updates only its keys; the title survives.
        stream.apply(line: lines[1])
        let paused = try #require(stream.snapshot)
        #expect(paused.title == "Teardrop")
        #expect(!paused.isPlaying)
        #expect(paused.elapsed == 161.5)

        // null removes a key.
        stream.apply(line: lines[2])
        #expect(stream.snapshot?.artist == "")
        #expect(stream.snapshot?.artworkData == nil)

        // A non-diff payload replaces everything; web players report their browser as parent.
        stream.apply(line: lines[3])
        let web = try #require(stream.snapshot)
        #expect(web.bundleID == "com.apple.Safari")
        #expect(web.duration == nil) // 0 means unknown

        stream.apply(line: lines[4])
        #expect(stream.snapshot == nil)
    }

    @Test func nonDataLinesAreIgnored() {
        var stream = AdapterStream()
        let garbage = stream.apply(line: Data("not json".utf8))
        let error = stream.apply(line: Data(#"{"type":"error"}"#.utf8))
        #expect(!garbage)
        #expect(!error)
    }

    @Test func untitledMediaStillCounts() {
        var stream = AdapterStream()
        stream.apply(line: Data(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.QuickTimePlayerX","playing":true}}"#.utf8))
        #expect(stream.snapshot?.bundleID == "com.apple.QuickTimePlayerX")
        #expect(stream.snapshot?.title == "")
    }

    @Test func positionExtrapolatesOnlyWhilePlaying() {
        let start = Date(timeIntervalSince1970: 1000)
        var media = NowPlaying(
            bundleID: "x", title: "t", artist: "", album: "", isPlaying: true, duration: 100,
            elapsed: 10, elapsedAt: start, rate: 1, artwork: nil, tint: nil
        )
        #expect(media.position(at: start.addingTimeInterval(5)) == 15)
        #expect(media.position(at: start.addingTimeInterval(500)) == 100) // clamped to the duration
        media.isPlaying = false
        #expect(media.position(at: start.addingTimeInterval(5)) == 10)
    }
}

struct AppleScriptPlayersTests {
    @Test func parsesQueryOutputWithEitherDecimalSeparator() {
        let output = ["paused", "Song", "Artist", "Album", "245,5", "12.25", ""].joined(separator: "\u{1F}") + "\n"
        let snapshot = AppleScriptPlayers.parse(output, bundleID: "com.apple.Music")
        #expect(snapshot?.title == "Song")
        #expect(snapshot?.isPlaying == false)
        #expect(snapshot?.duration == 245.5)
        #expect(snapshot?.elapsed == 12.25)
        #expect(snapshot?.artworkData == nil)
    }

    @Test func stoppedOrUntitledIsNothing() {
        #expect(AppleScriptPlayers.parse("stopped\n", bundleID: "com.apple.Music") == nil)
        let untitled = ["playing", "", "", "", "0", "0", ""].joined(separator: "\u{1F}")
        #expect(AppleScriptPlayers.parse(untitled, bundleID: "com.apple.Music") == nil)
    }
}

struct DeviceBatteryTests {
    private func properties(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: try fixtureURL(name, "plist"))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func airPodsReportEachPartAndTheLowestWornOneLeads() throws {
        let components = DeviceBattery.components(from: try properties("battery-airpods-pro"))
        #expect(components == [
            .init(part: .left, percent: 80),
            .init(part: .right, percent: 75),
            .init(part: .case, percent: 50),
        ])
        let device = DeviceBattery(address: "a", name: "AirPods Pro", symbol: "airpodspro", components: components)
        #expect(device.level == 0.75) // the case is not worn
        #expect(device.summary == "L 80% · R 75% · Case 50%")
    }

    @Test func hidAccessoryReportsOneBattery() throws {
        let properties = try properties("battery-magic-keyboard")
        let components = DeviceBattery.components(from: properties)
        #expect(components == [.init(part: .main, percent: 64)])
        #expect(DeviceBattery.normalize(address: properties["DeviceAddress"] as? String ?? "") == "c0-44-42-da-ad-0a")
        #expect(DeviceBattery.normalize(address: "C0:44:42:DA:AD:0A") == "c0-44-42-da-ad-0a")
    }

    @Test func caseAloneStillCounts() {
        let device = DeviceBattery(address: "a", name: "AirPods", symbol: "airpods",
                                   components: DeviceBattery.components(from: ["BatteryPercentCase": 30]))
        #expect(device.level == 0.3)
    }

    @Test func zeroMeansNotReported() {
        #expect(DeviceBattery.components(from: ["BatteryPercentSingle": 0, "BatteryPercent": 0]).isEmpty)
    }

    @Test func symbolFromNameThenClass() {
        #expect(DeviceBattery.symbol(name: "Iyan’s AirPods Pro", majorClass: 0x04) == "airpodspro")
        #expect(DeviceBattery.symbol(name: "Magic Keyboard", majorClass: 0x05) == "keyboard")
        #expect(DeviceBattery.symbol(name: "soundcore A25i", majorClass: 0x04) == "headphones")
    }
}
