import Foundation
import Testing
@testable import Perch

struct MeetingLinkTests {
    @Test func eventURLWinsWhenItIsACallLink() {
        let found = MeetingLink.find(
            url: URL(string: "https://meet.google.com/abc-defg-hij"),
            notes: "Backup: https://zoom.us/j/111",
            location: nil
        )
        #expect(found?.service == .meet)
        #expect(found?.url.absoluteString == "https://meet.google.com/abc-defg-hij")
    }

    @Test func linksAreFoundInNotesThenLocation() {
        let notes = """
        Join Zoom Meeting
        https://us02web.zoom.us/j/81234567890?pwd=QWErty.1

        Meeting ID: 812 3456 7890
        """
        #expect(MeetingLink.find(url: nil, notes: notes, location: "Room 4")?.url.absoluteString
            == "https://us02web.zoom.us/j/81234567890?pwd=QWErty.1")

        let teams = MeetingLink.find(
            url: URL(string: "https://example.com/agenda"), // not a call link: ignored
            notes: "Agenda attached",
            location: "Microsoft Teams Meeting <https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=x>"
        )
        #expect(teams?.service == .teams)
        #expect(teams?.url.absoluteString.hasSuffix("context=x") == true) // stops at the closing ">"

        #expect(MeetingLink.find(url: nil, notes: "https://acme.webex.com/meet/jdoe", location: nil)?.service == .webex)
        #expect(MeetingLink.find(url: nil, notes: "Lunch at the usual place", location: "Cafe") == nil)
    }

    @Test func zoomLinksOpenTheApp() {
        let app = MeetingLink.zoomAppURL(for: URL(string: "https://us02web.zoom.us/j/81234567890?pwd=abc&uname=x")!)
        #expect(app?.absoluteString == "zoommtg://zoom.us/join?confno=81234567890&pwd=abc")
        #expect(MeetingLink.zoomAppURL(for: URL(string: "https://zoom.us/my/jdoe")!) == nil) // personal room: keep the web link
        #expect(MeetingLink.zoomAppURL(for: URL(string: "https://meet.google.com/abc-defg-hij")!) == nil)
    }
}

struct MeetingScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_793_350_000)

    private func event(_ id: String, startsIn minutes: Double, length: Double = 30, allDay: Bool = false, skipped: Bool = false) -> MeetingEvent {
        let start = now.addingTimeInterval(minutes * 60)
        return MeetingEvent(id: id, title: id, start: start, end: start.addingTimeInterval(length * 60), url: nil,
                            notes: nil, location: nil, isAllDay: allDay, isSkipped: skipped)
    }

    @Test func nextSkipsAllDayDeclinedAndLongStartedEvents() {
        let events = [
            event("offsite", startsIn: -60, length: 600, allDay: true),
            event("declined", startsIn: 5, skipped: true),
            event("started ten minutes ago", startsIn: -10),
            event("standup", startsIn: 20),
            event("1:1", startsIn: 90),
        ]
        #expect(MeetingSchedule.next(in: events, now: now)?.id == "standup")
    }

    @Test func aMeetingStaysJoinableForFiveMinutesAfterItStarts() {
        let late = event("late", startsIn: -4)
        #expect(MeetingSchedule.next(in: [late], now: now)?.id == "late")
        #expect(MeetingSchedule.next(in: [event("gone", startsIn: -6)], now: now) == nil)
    }

    @Test func eventsBeyondTheHorizonStayOff() {
        #expect(MeetingSchedule.next(in: [event("tomorrow", startsIn: 13 * 60)], now: now) == nil)
    }

    @Test func turnsImminentTenMinutesBefore() {
        let standup = event("standup", startsIn: 20)
        #expect(MeetingSchedule.phase(of: standup, now: now) == .upcoming)
        #expect(MeetingSchedule.nextChange(for: standup, now: now) == standup.start.addingTimeInterval(-600))
        let soon = now.addingTimeInterval(10 * 60)
        #expect(MeetingSchedule.phase(of: standup, now: soon) == .imminent)
        #expect(MeetingSchedule.nextChange(for: standup, now: soon) == standup.start.addingTimeInterval(300))
    }
}

struct DownloadProbeTests {
    @Test func partialNamesMapToTheirFinalName() {
        #expect(DownloadProbe.finalName(forPartial: "report.pdf.crdownload") == "report.pdf")
        #expect(DownloadProbe.finalName(forPartial: "setup.dmg.part") == "setup.dmg")
        #expect(DownloadProbe.finalName(forPartial: "Movie.mov.download") == "Movie.mov")
        #expect(DownloadProbe.finalName(forPartial: "notes.txt") == nil)
        #expect(DownloadProbe.finalName(forPartial: ".part") == nil) // nothing left once stripped
    }

    @Test func progressAttributeIsTextFraction() {
        #expect(DownloadProbe.fraction(attribute: Data("0.4231".utf8)) == 0.4231)
        #expect(DownloadProbe.fraction(attribute: Data("1.0000002\0".utf8)) == 1) // clamped, NUL-terminated
        #expect(DownloadProbe.fraction(attribute: Data("nan".utf8)) == nil)
    }

    @Test func safariInfoGivesBytes() {
        let progress = DownloadProbe.safariProgress(info: [
            "DownloadEntryProgressBytesSoFar": 1_048_576,
            "DownloadEntryProgressTotalToLoad": 4_194_304,
        ])
        #expect(progress.received == 1_048_576)
        #expect(progress.total == 4_194_304)
        #expect(DownloadProbe.safariProgress(info: ["DownloadEntryProgressTotalToLoad": -1]).total == nil)
    }

    @Test func readsTheProgressAttributeFromAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perch-xattr-\(UUID().uuidString)")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(DownloadProbe.readAttribute(DownloadProbe.progressAttribute, of: url) == nil)
        let value = Data("0.5".utf8)
        let status = url.withUnsafeFileSystemRepresentation { path in
            value.withUnsafeBytes { setxattr(path, DownloadProbe.progressAttribute, $0.baseAddress, value.count, 0, 0) }
        }
        #expect(status == 0)
        let read = try #require(DownloadProbe.readAttribute(DownloadProbe.progressAttribute, of: url))
        #expect(DownloadProbe.fraction(attribute: read) == 0.5)
    }
}
