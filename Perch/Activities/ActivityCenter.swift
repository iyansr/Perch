import AppKit
import Observation
import SwiftUI

/// One long-running thing shown in the pill's shared live-activity slot.
struct Activity: Identifiable, Equatable {
    enum Status: Equatable {
        case running, needsAttention, done, failed
    }

    enum Progress: Equatable {
        case indeterminate
        case fraction(Double)
        case countdown(start: Date, end: Date)
        case paused(remaining: TimeInterval, total: TimeInterval)
    }

    enum Kind: Equatable {
        case timer
        case conversion(batchID: UUID)
    }

    let id: UUID
    let kind: Kind
    var symbol: String
    var title: String
    var detail: String
    var status: Status
    var progress: Progress
    var updatedAt: Date
    /// Files the activity produced; the glance card offers to reveal them in Finder.
    var outputs: [URL] = []

    /// Lower is more urgent; finished and blocked items surface before running ones.
    var urgency: Int {
        switch status {
        case .needsAttention: 0
        case .failed: 1
        case .done: 2
        case .running: 3
        }
    }
}

/// Shared queue of live activities. Owned by the app, so activities outlive the panel.
@Observable
final class ActivityCenter {
    static let autoDismissDelay: Duration = .seconds(8)

    private(set) var items: [Activity] = []
    /// Bumps whenever an activity finishes; views animate on it.
    private(set) var completionTick = 0

    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    /// Most urgent first, then most recent.
    var sorted: [Activity] {
        items.sorted { lhs, rhs in
            lhs.urgency != rhs.urgency ? lhs.urgency < rhs.urgency : lhs.updatedAt > rhs.updatedAt
        }
    }

    // MARK: Timers

    @discardableResult
    func startTimer(duration: TimeInterval) -> UUID {
        let now = Date()
        let end = now.addingTimeInterval(duration)
        let activity = Activity(
            id: UUID(),
            kind: .timer,
            symbol: "timer",
            title: "Timer",
            detail: TimerCommand.label(for: duration),
            status: .running,
            progress: .countdown(start: now, end: end),
            updatedAt: now
        )
        // The pill widens for the activity; animate it as a morph, like the other state changes.
        withAnimation(NotchMotion.expand) { items.append(activity) }
        scheduleCompletion(of: activity.id, at: end)
        return activity.id
    }

    func pause(_ id: UUID) {
        guard let index = index(of: id), case let .countdown(start, end) = items[index].progress else { return }
        tasks.removeValue(forKey: id)?.cancel()
        items[index].progress = .paused(remaining: max(0, end.timeIntervalSinceNow), total: end.timeIntervalSince(start))
    }

    func resume(_ id: UUID) {
        guard let index = index(of: id), case let .paused(remaining, total) = items[index].progress else { return }
        let end = Date().addingTimeInterval(remaining)
        items[index].progress = .countdown(start: end.addingTimeInterval(-total), end: end)
        scheduleCompletion(of: id, at: end)
    }

    // MARK: Fraction-progress activities

    /// Starts a running activity with a determinate progress ring, e.g. an image-conversion batch.
    /// Finish it with `finish(_:status:)`.
    @discardableResult
    func startProgress(id: UUID = UUID(), kind: Activity.Kind, symbol: String, title: String, detail: String) -> UUID {
        let activity = Activity(
            id: id,
            kind: kind,
            symbol: symbol,
            title: title,
            detail: detail,
            status: .running,
            progress: .fraction(0),
            updatedAt: Date()
        )
        withAnimation(NotchMotion.expand) { items.append(activity) }
        return id
    }

    /// Updates a progress activity in place. `nil` arguments leave that field unchanged.
    func updateProgress(_ id: UUID, fraction: Double? = nil, detail: String? = nil, outputs: [URL]? = nil) {
        guard let index = index(of: id) else { return }
        if let fraction { items[index].progress = .fraction(min(max(fraction, 0), 1)) }
        if let detail { items[index].detail = detail }
        if let outputs { items[index].outputs = outputs }
    }

    // MARK: Lifecycle

    func finish(_ id: UUID, status: Activity.Status) {
        guard let index = index(of: id) else { return }
        items[index].status = status
        items[index].progress = .fraction(1)
        items[index].updatedAt = Date()
        completionTick += 1
        if AppSettings.shared.playsSounds {
            NSSound(named: status == .failed ? "Basso" : "Glass")?.play()
        }
        tasks[id]?.cancel()
        tasks[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.autoDismissDelay)
            guard !Task.isCancelled else { return }
            self?.dismiss(id)
        }
    }

    func dismiss(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        withAnimation(NotchMotion.collapse) { items.removeAll { $0.id == id } }
    }

    private func scheduleCompletion(of id: UUID, at end: Date) {
        tasks[id]?.cancel()
        tasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.finish(id, status: .done)
        }
    }

    private func index(of id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }
}
