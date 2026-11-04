import Foundation

/// An event as the Calendar page needs it; `CalendarStore` fills it from EventKit.
nonisolated struct CalendarEvent: Identifiable, Equatable {
    /// Recurring events share one item identifier, so the start disambiguates occurrences.
    let id: String
    let title: String
    let start: Date
    /// For all-day events this is midnight after the last day (EventKit's convention).
    let end: Date
    let isAllDay: Bool
    let location: String?
    let notes: String?
    let url: URL?
    let calendarTitle: String
    /// sRGB components of the calendar's color.
    let color: RGB

    struct RGB: Equatable {
        var red: Double, green: Double, blue: Double
    }

    /// The call link found in the url, notes or location.
    var meetingLink: (service: MeetingLink.Service, url: URL)? {
        MeetingLink.find(url: url, notes: notes, location: location)
    }

}

/// A timed event positioned on one day's timeline.
nonisolated struct PlacedEvent: Identifiable, Equatable {
    let event: CalendarEvent
    /// Minutes from midnight, clamped to the visible window.
    let startMinute: Int
    let endMinute: Int
    let lane: Int
    let laneCount: Int

    var id: String { event.id }
}

/// What the Calendar page shows for one day.
nonisolated struct DayAgenda: Equatable {
    var allDay: [CalendarEvent] = []
    /// Events that end before the timeline's first hour; listed beside it instead of dropped.
    var early: [CalendarEvent] = []
    var placed: [PlacedEvent] = []

    var isEmpty: Bool { allDay.isEmpty && early.isEmpty && placed.isEmpty }
    var count: Int { allDay.count + early.count + placed.count }
}

nonisolated enum CalendarLogic {
    /// The timeline starts here; anything that ends earlier is "early".
    static let firstHour = 6
    static let lastHour = 24

    /// Events overlapping `day`, all-day first, then by start. Overnight and multi-day events appear on every day they touch.
    static func events(_ events: [CalendarEvent], on day: Date, calendar: Calendar) -> [CalendarEvent] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return events
            .filter { $0.start < end && $0.end > start }
            .sorted {
                if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
                return ($0.start, $0.end) < ($1.start, $1.end)
            }
    }

    /// Splits a day into all-day bars, the early group and lane-packed timeline blocks.
    static func agenda(_ events: [CalendarEvent], on day: Date, calendar: Calendar) -> DayAgenda {
        let start = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let dayEvents = Self.events(events, on: day, calendar: calendar)
        var agenda = DayAgenda()
        var timed: [(event: CalendarEvent, start: Int, end: Int)] = []
        for event in dayEvents {
            if event.isAllDay {
                agenda.allDay.append(event)
                continue
            }
            let from = event.start <= start ? 0 : minuteOfDay(event.start, calendar: calendar)
            let to = event.end >= dayEnd ? 24 * 60 : minuteOfDay(event.end, calendar: calendar)
            if to <= firstHour * 60 {
                agenda.early.append(event)
            } else {
                // A zero-length event still gets a visible sliver.
                let clampedStart = max(from, firstHour * 60)
                timed.append((event, clampedStart, max(to, clampedStart + 15)))
            }
        }
        agenda.placed = packLanes(timed)
        return agenda
    }

    /// Wall-clock minutes, so a DST switch does not shift blocks by an hour.
    static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// Greedy interval colouring: each overlapping cluster shares one lane count so blocks line up.
    static func packLanes(_ items: [(event: CalendarEvent, start: Int, end: Int)]) -> [PlacedEvent] {
        let sorted = items.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var result: [PlacedEvent] = []
        var cluster: [(event: CalendarEvent, start: Int, end: Int, lane: Int)] = []
        var laneEnds: [Int] = []
        var clusterEnd = Int.min

        func flush() {
            for item in cluster {
                result.append(PlacedEvent(event: item.event, startMinute: item.start, endMinute: item.end,
                                          lane: item.lane, laneCount: laneEnds.count))
            }
            cluster.removeAll()
            laneEnds.removeAll()
            clusterEnd = Int.min
        }

        for item in sorted {
            if !cluster.isEmpty, item.start >= clusterEnd { flush() }
            let lane = laneEnds.firstIndex { $0 <= item.start } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(item.end) } else { laneEnds[lane] = item.end }
            cluster.append((item.event, item.start, item.end, lane))
            clusterEnd = max(clusterEnd, item.end)
        }
        flush()
        return result
    }

    /// "9:00 AM" or "09:00", per Settings › General › 24-hour time rather than the region's default.
    static func time(_ date: Date, hour24: Bool) -> String {
        (hour24 ? hour24Formatter : hour12Formatter).string(from: date)
    }

    /// Hour-axis label: "6 AM" or "06:00".
    static func hourLabel(_ hour: Int, hour24: Bool) -> String {
        let h = hour % 24
        return hour24 ? String(format: "%02d:00", h) : "\(h % 12 == 0 ? 12 : h % 12) \(h < 12 ? "AM" : "PM")"
    }

    private static let hour24Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let hour12Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        // AM/PM, matching the hour axis, whatever the region calls them.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// "11:00 AM – 12:00 PM", or the part inside `day` for overnight events ("Starts 11:30 PM", "Ends 12:30 AM").
    static func rangeLabel(_ event: CalendarEvent, on day: Date, calendar: Calendar, hour24: Bool) -> String {
        if event.isAllDay { return "All day" }
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        if event.start < start, event.end > end { return "All day" }
        if event.start < start { return "Ends \(time(event.end, hour24: hour24))" }
        if event.end > end { return "Starts \(time(event.start, hour24: hour24))" }
        return "\(time(event.start, hour24: hour24)) – \(time(event.end, hour24: hour24))"
    }

    /// "1 hr 30 min", or the day count for all-day events.
    static func durationLabel(_ event: CalendarEvent, calendar: Calendar) -> String {
        if event.isAllDay {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: event.start), to: calendar.startOfDay(for: event.end)).day ?? 1
            return days <= 1 ? "All day" : "\(days) days"
        }
        let minutes = Int(event.end.timeIntervalSince(event.start) / 60)
        let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    /// "in 52 min", "Now, ends in 20 min", or nil when it is a day or more away or already over.
    static func relativeLabel(_ event: CalendarEvent, now: Date) -> String? {
        guard !event.isAllDay else { return nil }
        let toStart = Int((event.start.timeIntervalSince(now) / 60).rounded())
        let toEnd = Int((event.end.timeIntervalSince(now) / 60).rounded())
        guard toEnd > 0 else { return nil }
        func span(_ minutes: Int) -> String {
            let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
            if hours == 0 { return "\(rest) min" }
            return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
        }
        if toStart <= 0 { return "Now, ends in \(span(toEnd))" }
        return toStart < 24 * 60 ? "in \(span(toStart))" : nil
    }

    /// The event the detail strip shows by default. Today: the first timed event not yet over, else nothing once
    /// everything has finished (an all-day event only on a day without timed ones). Other days: the first timed event.
    static func defaultSelection(in agenda: DayAgenda, isToday: Bool, now: Date) -> CalendarEvent? {
        let timed = (agenda.early + agenda.placed.map(\.event)).sorted { $0.start < $1.start }
        if isToday { return timed.first { $0.end > now } ?? (timed.isEmpty ? agenda.allDay.first : nil) }
        return timed.first ?? agenda.allDay.first
    }

    /// Moves by `months`, clamping the day so 31 January + 1 month is 28 February.
    static func addingMonths(_ months: Int, to date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .month, value: months, to: date) ?? date
    }
}
