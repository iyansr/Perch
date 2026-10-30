import AppKit
import EventKit
import SwiftUI

/// The fields of a calendar event the meeting activity needs.
nonisolated struct MeetingEvent: Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let url: URL?
    let notes: String?
    let location: String?
    let isAllDay: Bool
    /// Declined by the user, or cancelled by the organiser.
    let isSkipped: Bool
}

/// When the next meeting shows, and how loudly.
nonisolated enum MeetingSchedule {
    /// Ambient until this long before the start, then it holds the pill with a Join button.
    static let lead: TimeInterval = 10 * 60
    /// Still offered this long after the start, for joining late.
    static let grace: TimeInterval = 5 * 60
    /// Events further out than this stay off the pill.
    static let horizon: TimeInterval = 12 * 3600

    enum Phase: Equatable {
        case upcoming, imminent
    }

    /// The meeting to show: the earliest timed, attended event that has not passed its grace period.
    static func next(in events: [MeetingEvent], now: Date) -> MeetingEvent? {
        events
            .filter { !$0.isAllDay && !$0.isSkipped && $0.start.addingTimeInterval(grace) > now && $0.end > now }
            .filter { $0.start.timeIntervalSince(now) <= horizon }
            .min { $0.start < $1.start }
    }

    static func phase(of event: MeetingEvent, now: Date) -> Phase {
        event.start.timeIntervalSince(now) <= lead ? .imminent : .upcoming
    }

    /// Next moment the shown state changes on its own (imminent, or dropping off after the grace period).
    static func nextChange(for event: MeetingEvent, now: Date) -> Date {
        let imminent = event.start.addingTimeInterval(-lead)
        return imminent > now ? imminent : event.start.addingTimeInterval(grace)
    }
}

/// The next calendar meeting: ambient beside the notch until 10 minutes before, then it asks for
/// attention with a Join button. Needs full Calendar access.
final class MeetingSource: ActivitySource {
    static let id = "meeting"
    static let info = ActivitySourceInfo(
        title: "Next Meeting",
        detail: "Your next event when nothing else is showing; ten minutes before, a Join button for Zoom, Meet, Teams or Webex.",
        symbol: "calendar",
        tint: .red,
        permission: .calendar
    )

    private let store = EKEventStore()
    private let activityID = UUID()
    private weak var center: ActivityCenter?
    private var shown: (event: MeetingEvent, phase: MeetingSchedule.Phase)?
    private var timer: Timer?
    private var changeObserver: NSObjectProtocol?
    private var isRunning = false

    func start(center: ActivityCenter) {
        self.center = center
        isRunning = true
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            begin()
        case .notDetermined:
            let store = store
            Task { [weak self] in
                guard let granted = try? await store.requestFullAccessToEvents(), granted, let self, isRunning else { return }
                begin()
            }
        default:
            break // denied or write-only: Settings shows the fix
        }
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
        shown = nil
        center?.dismiss(activityID)
    }

    private func begin() {
        changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        guard isRunning else { return }
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-MeetingSchedule.grace),
            end: now.addingTimeInterval(MeetingSchedule.horizon),
            calendars: nil
        )
        let events = store.events(matching: predicate).map { Self.meetingEvent($0) }
        guard let event = MeetingSchedule.next(in: events, now: now) else {
            shown = nil
            center?.dismiss(activityID)
            schedule(at: now.addingTimeInterval(15 * 60)) // a new invite fires EKEventStoreChanged sooner
            return
        }
        publish(event, now: now)
        // Ambient detail says "at 14:30", so only phase changes need a refresh.
        schedule(at: MeetingSchedule.nextChange(for: event, now: now))
    }

    private func publish(_ event: MeetingEvent, now: Date) {
        guard let center else { return }
        let phase = MeetingSchedule.phase(of: event, now: now)
        let link = MeetingLink.find(url: event.url, notes: event.notes, location: event.location)
        let activityLink = link.map { ActivityLink(title: "Join", url: Self.preferredURL($0.url)) }
        let time = event.start.formatted(date: .omitted, time: .shortened)
        let previous = shown
        shown = (event, phase)

        switch phase {
        case .upcoming:
            var activity = Activity(
                id: activityID, kind: .meeting(eventID: event.id), symbol: "calendar", title: event.title,
                detail: time, status: .running, progress: .indeterminate, updatedAt: now,
                presentation: .ambient
            )
            activity.link = activityLink
            center.show(activity)
        case .imminent:
            guard previous?.event != event || previous?.phase != .imminent else { return }
            let detail = [time, link?.service.title].compactMap { $0 }.joined(separator: " · ")
            if previous?.event.id != event.id { center.dismiss(activityID, animation: NotchMotion.hudOut) }
            // Persistent first, so the attention ping and pulse are not suppressed as ambient.
            center.update(activityID) { $0.presentation = .persistent }
            center.upsert(id: activityID, kind: .meeting(eventID: event.id), symbol: "video.fill", title: event.title,
                          detail: detail, status: .needsAttention)
            center.update(activityID) { activity in
                activity.presentation = .persistent
                activity.link = activityLink
                activity.progress = .countdown(start: now, end: max(event.start, now.addingTimeInterval(1)))
            }
        }
    }

    private func schedule(at date: Date) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(1, date.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Zoom links open the app directly when it is installed.
    private static func preferredURL(_ url: URL) -> URL {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "us.zoom.xos") != nil,
              let app = MeetingLink.zoomAppURL(for: url)
        else { return url }
        return app
    }

    /// Opens the event in Calendar.
    static func showInCalendar(eventID: String) {
        let encoded = eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventID
        if let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func meetingEvent(_ event: EKEvent) -> MeetingEvent {
        let declined = event.attendees?.first { $0.isCurrentUser }?.participantStatus == .declined
        return MeetingEvent(
            id: event.calendarItemIdentifier,
            title: event.title?.isEmpty == false ? event.title : "Untitled event",
            start: event.startDate,
            end: event.endDate,
            url: event.url,
            notes: event.notes,
            location: event.location,
            isAllDay: event.isAllDay,
            isSkipped: declined || event.status == .canceled
        )
    }
}
