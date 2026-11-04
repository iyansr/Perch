import AppKit
import EventKit
import Observation

/// Calendar page state: the selected day, the loaded events, and Calendar access.
/// Events load for a fixed window around today (a year back, a year ahead) off the main thread, are indexed by day,
/// and reload on `EKEventStoreChanged`. Every per-day read (ribbon dots, timeline) is a dictionary lookup.
@Observable
final class CalendarStore {
    static let shared = CalendarStore()

    enum Access: Equatable {
        case granted, needed, denied
    }

    /// Days either side of today the ribbon covers.
    static let windowDays = 365

    private(set) var access: Access = .needed
    private(set) var calendar = Calendar.current
    /// Every day the ribbon shows, oldest first. Built once per activation, not per render.
    private(set) var days: [Date] = []
    /// The day shown in the timeline. Always a start-of-day.
    var selectedDay: Date
    /// Bumped when something moves the selection; the ribbon scrolls the selected day to its centre.
    private(set) var scrollRequest = 0

    /// Events overlapping each start-of-day; multi-day and overnight events are listed under every day they touch.
    @ObservationIgnored private var byDay: [Date: [CalendarEvent]] = [:]
    @ObservationIgnored private var dotsByDay: [Date: [CalendarEvent.RGB]] = [:]
    /// Bumped when `byDay` changes, so views reading the index re-render.
    private(set) var revision = 0

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var changeObserver: NSObjectProtocol?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init() {
        selectedDay = Calendar.current.startOfDay(for: Date())
    }

    var today: Date { calendar.startOfDay(for: Date()) }
    var firstDay: Date { days.first ?? today }
    var lastDay: Date { days.last ?? today }

    /// Call when the page appears: resets to today, then loads (asking for access the first time).
    func activate() {
        calendar = Calendar.current
        days = Self.days(around: today, calendar: calendar)
        select(today, scroll: true)
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            access = .granted
            beginObserving()
            reload()
        case .notDetermined:
            access = .needed
            Task { [weak self] in
                guard let self else { return }
                let granted = (try? await store.requestFullAccessToEvents()) ?? false
                access = granted ? .granted : .denied
                if granted {
                    beginObserving()
                    reload()
                }
            }
        default:
            access = .denied
        }
    }

    func deactivate() {
        loadTask?.cancel()
        loadTask = nil
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
    }

    func select(_ day: Date, scroll: Bool = false) {
        let clamped = min(max(calendar.startOfDay(for: day), firstDay), lastDay)
        guard clamped != selectedDay || scroll else { return }
        selectedDay = clamped
        if scroll { scrollRequest += 1 }
    }

    func step(days: Int) {
        select(calendar.date(byAdding: .day, value: days, to: selectedDay) ?? selectedDay, scroll: true)
    }

    func openSettings() {
        if let url = SourcePermission.Kind.calendar.settingsURL { NSWorkspace.shared.open(url) }
    }

    func agenda(on day: Date) -> DayAgenda {
        _ = revision
        return CalendarLogic.agenda(byDay[day] ?? [], on: day, calendar: calendar)
    }

    /// Calendar colors of up to three distinct calendars with events that day, for the ribbon dots.
    func dots(on day: Date) -> [CalendarEvent.RGB] {
        _ = revision
        return dotsByDay[day] ?? []
    }

    func eventCount(inMonthOf day: Date) -> Int {
        _ = revision
        guard let month = calendar.dateInterval(of: .month, for: day) else { return 0 }
        var ids = Set<String>()
        var date = month.start
        while date < month.end {
            for event in byDay[date] ?? [] { ids.insert(event.id) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        return ids.count
    }

    /// Replaces the loaded events and rebuilds the per-day index.
    func apply(_ events: [CalendarEvent]) {
        var index: [Date: [CalendarEvent]] = [:]
        for event in events {
            // Every day from the start's to the last one the event reaches; ending exactly at midnight does not reach the next.
            var day = calendar.startOfDay(for: event.start)
            while true {
                index[day, default: []].append(event)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next < event.end else { break }
                day = next
            }
        }
        var dots: [Date: [CalendarEvent.RGB]] = [:]
        for (day, list) in index {
            var seen: [CalendarEvent.RGB] = []
            for event in CalendarLogic.events(list, on: day, calendar: calendar) where !seen.contains(event.color) {
                seen.append(event.color)
                if seen.count == 3 { break }
            }
            dots[day] = seen
        }
        byDay = index
        dotsByDay = dots
        revision += 1
    }

    private static func days(around today: Date, calendar: Calendar) -> [Date] {
        (-windowDays...windowDays).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    private func beginObserving() {
        guard changeObserver == nil else { return }
        changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// Expanding two years of recurrences takes long enough to drop frames, so the fetch runs off the main actor.
    private func reload() {
        let start = firstDay
        let end = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
        // EKEventStore is not Sendable, but fetching from it on a background queue is the documented use.
        nonisolated(unsafe) let store = store
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let events = await Task.detached(priority: .userInitiated) {
                Self.fetch(store: store, start: start, end: end)
            }.value
            guard !Task.isCancelled, let self else { return }
            apply(events)
        }
    }

    private nonisolated static func fetch(store: EKEventStore, start: Date, end: Date) -> [CalendarEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .map(event)
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    private nonisolated static func event(_ event: EKEvent) -> CalendarEvent {
        let rgb = (event.calendar.color ?? .systemGray).usingColorSpace(.sRGB)
        return CalendarEvent(
            id: "\(event.calendarItemIdentifier)|\(event.startDate.timeIntervalSince1970)",
            title: event.title?.isEmpty == false ? event.title : "Untitled event",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location?.isEmpty == false ? event.location : nil,
            notes: event.notes?.isEmpty == false ? event.notes : nil,
            url: event.url,
            calendarTitle: event.calendar.title,
            color: .init(red: Double(rgb?.redComponent ?? 0.6), green: Double(rgb?.greenComponent ?? 0.6), blue: Double(rgb?.blueComponent ?? 0.6))
        )
    }
}
