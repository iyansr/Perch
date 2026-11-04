import Testing
import Foundation
@testable import Perch

struct CalendarLogicTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func event(_ id: String, _ start: Date, _ end: Date, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, title: id, start: start, end: end, isAllDay: allDay, location: nil, notes: nil, url: nil,
                      calendarTitle: "Work", color: .init(red: 0, green: 0.5, blue: 1))
    }

    @Test func overlappingEventsShareLanesAndSequentialOnesDoNot() {
        let events = [
            event("a", date(11, 4, 9), date(11, 4, 10)),
            event("b", date(11, 4, 9, 30), date(11, 4, 10, 30)),
            event("c", date(11, 4, 13), date(11, 4, 14)),
        ]
        let placed = CalendarLogic.agenda(events, on: date(11, 4), calendar: calendar).placed
        let byID = Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0) })
        #expect(byID["a"]?.lane == 0 && byID["b"]?.lane == 1)
        #expect(byID["a"]?.laneCount == 2 && byID["b"]?.laneCount == 2)
        #expect(byID["c"]?.lane == 0 && byID["c"]?.laneCount == 1)
    }

    @Test func overnightEventAppearsOnBothDaysClippedToEachDay() {
        let race = event("race", date(11, 6, 23, 30), date(11, 7, 0, 30))
        let first = CalendarLogic.agenda([race], on: date(11, 6), calendar: calendar)
        #expect(first.placed.first?.startMinute == 23 * 60 + 30)
        #expect(first.placed.first?.endMinute == 24 * 60)
        let second = CalendarLogic.agenda([race], on: date(11, 7), calendar: calendar)
        #expect(second.placed.first?.startMinute == 0)
        #expect(second.placed.first?.endMinute == 30)
        #expect(CalendarLogic.rangeLabel(race, on: date(11, 6), calendar: calendar, hour24: true).hasPrefix("Starts"))
        #expect(CalendarLogic.rangeLabel(race, on: date(11, 7), calendar: calendar, hour24: true).hasPrefix("Ends"))
    }

    @Test func timelineOpensAtSixUnlessSomethingEarlierNeedsShowing() {
        let late = CalendarLogic.agenda([event("late", date(11, 4, 9), date(11, 4, 10))], on: date(11, 4), calendar: calendar)
        #expect(CalendarLogic.openingMinute(for: late, nowMinute: nil) == 6 * 60)
        let early = CalendarLogic.agenda([event("race", date(11, 4, 2), date(11, 4, 3))], on: date(11, 4), calendar: calendar)
        #expect(CalendarLogic.openingMinute(for: early, nowMinute: nil) == 90)
        #expect(CalendarLogic.openingMinute(for: late, nowMinute: 3 * 60) == 2 * 60)
        #expect(CalendarLogic.openingMinute(for: early, nowMinute: 0) == 0)
        // Late evening with a 2 AM event: now stays in view rather than the early event.
        #expect(CalendarLogic.openingMinute(for: early, nowMinute: 21 * 60 + 13) == 4 * 60 + 13)
    }

    @Test func multiDayAllDayEventCoversEachDayButNotTheExclusiveEnd() {
        let offsite = event("offsite", date(11, 17), date(11, 20), allDay: true)
        #expect(CalendarLogic.agenda([offsite], on: date(11, 19), calendar: calendar).allDay.count == 1)
        #expect(CalendarLogic.agenda([offsite], on: date(11, 20), calendar: calendar).isEmpty)
        #expect(CalendarLogic.durationLabel(offsite, calendar: calendar) == "3 days")
    }

    @Test func defaultSelectionOnTodayIsNextUnfinishedThenNothing() {
        let events = [
            event("done", date(11, 4, 8), date(11, 4, 9)),
            event("running", date(11, 4, 9), date(11, 4, 10)),
            event("next", date(11, 4, 13), date(11, 4, 14)),
        ]
        let agenda = CalendarLogic.agenda(events, on: date(11, 4), calendar: calendar)
        #expect(CalendarLogic.defaultSelection(in: agenda, isToday: true, now: date(11, 4, 9, 41))?.id == "running")
        #expect(CalendarLogic.defaultSelection(in: agenda, isToday: true, now: date(11, 4, 11))?.id == "next")
        #expect(CalendarLogic.defaultSelection(in: agenda, isToday: true, now: date(11, 4, 20)) == nil)
        #expect(CalendarLogic.defaultSelection(in: agenda, isToday: false, now: date(11, 4, 20))?.id == "done")
    }

    @Test func relativeLabelCoversUpcomingRunningAndOver() {
        let meeting = event("m", date(11, 4, 11), date(11, 4, 12))
        #expect(CalendarLogic.relativeLabel(meeting, now: date(11, 4, 9, 41)) == "in 1 hr 19 min")
        #expect(CalendarLogic.relativeLabel(meeting, now: date(11, 4, 11, 40)) == "Now, ends in 20 min")
        #expect(CalendarLogic.relativeLabel(meeting, now: date(11, 4, 12, 1)) == nil)
        #expect(CalendarLogic.relativeLabel(meeting, now: date(11, 2, 11)) == nil)
    }

    @Test func timesFollowTheChosenClockNotTheRegion() {
        // Local time, like the app: the formatter reads the Mac's time zone.
        let local = Calendar.current
        let start = local.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 20))!
        let meeting = event("m", start, start.addingTimeInterval(9000))
        #expect(CalendarLogic.rangeLabel(meeting, on: start, calendar: local, hour24: true) == "20:00 – 22:30")
        #expect(CalendarLogic.rangeLabel(meeting, on: start, calendar: local, hour24: false) == "8:00 PM – 10:30 PM")
        #expect(CalendarLogic.hourLabel(6, hour24: true) == "06:00")
        #expect(CalendarLogic.hourLabel(24, hour24: true) == "00:00")
        #expect(CalendarLogic.hourLabel(12, hour24: false) == "12 PM")
        #expect(CalendarLogic.hourLabel(24, hour24: false) == "12 AM")
    }

    @Test func addingMonthsClampsTheDay() {
        let jan31 = calendar.date(from: DateComponents(year: 2027, month: 1, day: 31))!
        let result = CalendarLogic.addingMonths(1, to: jan31, calendar: calendar)
        #expect(calendar.dateComponents([.month, .day], from: result) == DateComponents(month: 2, day: 28))
    }
}

@MainActor
struct CalendarStoreIndexTests {
    @Test func indexListsEventsOnEveryDayTheyTouchButNotTheDayAfterAMidnightEnd() {
        let store = CalendarStore()
        let calendar = Calendar.current
        func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }
        func event(_ id: String, _ start: Date, _ end: Date, allDay: Bool = false) -> CalendarEvent {
            CalendarEvent(id: id, title: id, start: start, end: end, isAllDay: allDay, location: nil, notes: nil, url: nil,
                          calendarTitle: "Work", color: .init(red: 0, green: 0.5, blue: 1))
        }
        store.apply([
            event("race", date(6, 23, 30), date(7, 0, 30)),
            event("offsite", date(17), date(20), allDay: true),
        ])
        #expect(store.agenda(on: date(6)).placed.map(\.id) == ["race"])
        #expect(store.agenda(on: date(7)).placed.map(\.id) == ["race"])
        #expect(store.agenda(on: date(19)).allDay.map(\.id) == ["offsite"])
        #expect(store.agenda(on: date(20)).isEmpty)
        #expect(store.dots(on: date(18)).count == 1)
        #expect(store.eventCount(inMonthOf: date(1)) == 2)
    }
}
