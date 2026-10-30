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
        /// A 0…1 bar: volume, brightness, battery percent.
        case level(Double)
        /// Now playing: bars that move while playback runs and rest while paused.
        case waveform(playing: Bool)
    }

    enum Kind: Equatable {
        case timer
        case conversion(batchID: UUID)
        case agent(source: AgentSource, sessionID: String)
        case nowPlaying(bundleID: String)
        case hud(HUDKind)
        case deviceBattery(address: String)
        case meeting(eventID: String)
        case privacy(PrivacySensor)
        case download(path: String)
    }

    enum HUDKind: Equatable {
        case volume, brightness, keyboardBacklight, capsLock
    }

    /// Hardware that shows a chip while any app uses it.
    enum PrivacySensor: Equatable {
        case camera, microphone
    }

    /// How long an activity may hold the slot.
    enum Presentation: Equatable {
        /// Stays until its source ends it.
        case persistent
        /// Shows for the duration, then drops; a repeat of the same kind resets the clock.
        case transient(Duration)
        /// Shown only when nothing else is in the slot; never pulses.
        case ambient
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
    /// Terminal an agent runs in; the glance card offers to bring it forward.
    var terminal: AgentTerminal?
    var presentation: Presentation = .persistent
    /// The plan a timer runs and which phase of it is current.
    var timerRun: TimerRun?
    /// Track, artwork and position of a now-playing activity.
    var media: NowPlaying?
    /// Connected devices with their charge; the connecting device first.
    var batteries: [DeviceBattery] = []
    /// A two-button question (agent permission request) the card answers; nil once answered or abandoned.
    var decision: PendingDecision?
    /// Primary link the card opens, e.g. a meeting's join URL.
    var link: ActivityLink?

    /// Lower holds the slot first: blocked > transient > failed > done > running > ambient.
    /// A transient flash (volume change) preempts the pill; whatever it covered returns when it drops.
    var rank: Int {
        if status == .needsAttention { return 0 }
        switch presentation {
        case .transient: return 1
        case .ambient: return 5
        case .persistent: break
        }
        switch status {
        case .needsAttention: return 0
        case .failed: return 2
        case .done: return 3
        case .running: return 4
        }
    }

    var isHUD: Bool {
        if case .hud = kind { true } else { false }
    }
}

/// Which phase of a timer plan an activity is in.
struct TimerRun: Equatable {
    let plan: TimerPlan
    var phaseIndex: Int

    var phase: TimerPlan.Phase { plan.phases[phaseIndex] }
    var isLastPhase: Bool { phaseIndex == plan.phases.count - 1 }
}

/// A question the activity's card answers with two buttons (Deny / Allow).
/// `id` routes the answer back to whoever asked, through `DecisionRouter`.
struct PendingDecision: Equatable {
    let id: String
    var declineTitle = "Deny"
    var acceptTitle = "Allow"
}

/// A link the card offers as its main action ("Join").
struct ActivityLink: Equatable {
    let title: String
    let url: URL
}

/// Delivers a decision card's answer to the component that asked (the agent bridge).
final class DecisionRouter {
    static let shared = DecisionRouter()

    /// Set by the owner of pending requests; called with the decision id and whether it was accepted.
    var onAnswer: ((_ id: String, _ accepted: Bool) -> Void)?

    func answer(_ decision: PendingDecision, accepted: Bool) {
        onAnswer?(decision.id, accepted)
    }
}

/// Shared queue of live activities. Owned by the app, so activities outlive the panel.
@Observable
final class ActivityCenter {
    static let autoDismissDelay: Duration = .seconds(8)

    private(set) var items: [Activity] = []
    /// Bumps whenever an activity finishes or needs attention; views pulse on it.
    private(set) var completionTick = 0

    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let pomodoroLog: PomodoroLog

    init(pomodoroLog: PomodoroLog = .shared) {
        self.pomodoroLog = pomodoroLog
    }

    /// Most urgent first (see `Activity.rank`), then most recent.
    var sorted: [Activity] {
        items.sorted { lhs, rhs in
            lhs.rank != rhs.rank ? lhs.rank < rhs.rank : lhs.updatedAt > rhs.updatedAt
        }
    }

    /// What hovering the pill expands into: HUD flashes have nothing to show, so they never expand.
    var glanceItems: [Activity] {
        sorted.filter { !$0.isHUD }
    }

    /// Home's Activity module and its badge: no HUD flashes, no ambient items.
    var listedItems: [Activity] {
        glanceItems.filter { $0.presentation != .ambient }
    }

    // MARK: Timers

    @discardableResult
    func startTimer(_ plan: TimerPlan) -> UUID {
        let now = Date()
        let run = TimerRun(plan: plan, phaseIndex: 0)
        let end = now.addingTimeInterval(run.phase.duration)
        var activity = Activity(
            id: UUID(),
            kind: .timer,
            symbol: Self.symbol(for: run),
            title: Self.title(for: run),
            detail: Self.detail(for: run),
            status: .running,
            progress: .countdown(start: now, end: end),
            updatedAt: now
        )
        activity.timerRun = run
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

    /// A timer phase ran out: the next phase starts, or the whole timer finishes.
    /// A completed Pomodoro focus phase counts toward today's cycles.
    func completePhase(_ id: UUID) {
        guard let index = index(of: id), var run = items[index].timerRun else {
            finish(id, status: .done)
            return
        }
        if run.plan.isPomodoro, run.phase.kind == .focus { pomodoroLog.recordCycle() }
        guard !run.isLastPhase else {
            finish(id, status: .done)
            return
        }
        run.phaseIndex += 1
        let now = Date()
        let end = now.addingTimeInterval(run.phase.duration)
        items[index].timerRun = run
        items[index].symbol = Self.symbol(for: run)
        items[index].title = Self.title(for: run)
        items[index].detail = Self.detail(for: run)
        items[index].progress = .countdown(start: now, end: end)
        items[index].updatedAt = now
        completionTick += 1
        if AppSettings.shared.playsSounds { NSSound(named: "Glass")?.play() }
        scheduleCompletion(of: id, at: end)
    }

    private static func symbol(for run: TimerRun) -> String {
        guard run.plan.isPomodoro else { return "timer" }
        return run.phase.kind == .focus ? "brain.head.profile" : "cup.and.saucer.fill"
    }

    private static func title(for run: TimerRun) -> String {
        guard run.plan.isPomodoro else { return "Timer" }
        return run.phase.kind == .focus ? "Focus" : "Break"
    }

    /// "25 min", or "25 min · 2 of 4" inside a Pomodoro.
    private static func detail(for run: TimerRun) -> String {
        let duration = TimerCommand.label(for: run.phase.duration)
        guard run.plan.isPomodoro else { return duration }
        return "\(duration) · \(run.plan.cycle(at: run.phaseIndex)) of \(run.plan.cycleCount)"
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

    // MARK: Source-owned activities

    /// Inserts `activity`, or replaces the one with its id, without finish feedback.
    /// For sources that own their activity's whole state (now playing).
    func show(_ activity: Activity) {
        if let index = index(of: activity.id) {
            items[index] = activity
        } else {
            withAnimation(NotchMotion.expand) { items.append(activity) }
        }
    }

    /// Shows a `.transient` activity for its duration. A flash of the same kind already on screen
    /// is updated in place and its clock restarts, so holding a volume key keeps one bar up.
    @discardableResult
    func flash(_ activity: Activity) -> UUID {
        guard case let .transient(duration) = activity.presentation else {
            show(activity)
            return activity.id
        }
        let id: UUID
        if let index = items.firstIndex(where: { $0.kind == activity.kind && $0.presentation == activity.presentation }) {
            id = items[index].id
            items[index].symbol = activity.symbol
            items[index].title = activity.title
            items[index].detail = activity.detail
            items[index].progress = activity.progress
            items[index].batteries = activity.batteries
            items[index].updatedAt = activity.updatedAt
        } else {
            id = activity.id
            withAnimation(NotchMotion.hudIn) { items.append(activity) }
        }
        tasks[id]?.cancel()
        tasks[id] = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismiss(id, animation: NotchMotion.hudOut)
        }
        return id
    }

    // MARK: Upserted activities

    /// Creates or updates the activity `id` in place, so repeated events (e.g. one agent session) share one row.
    /// Reaching `.done`/`.failed` plays the finish feedback and schedules the auto-dismiss; going back to
    /// `.running`/`.needsAttention` cancels a pending dismiss. Entering `.needsAttention` pulses the pill.
    func upsert(
        id: UUID,
        kind: Activity.Kind,
        symbol: String,
        title: String,
        detail: String?,
        status: Activity.Status,
        terminal: AgentTerminal? = nil
    ) {
        let previous = index(of: id).map { items[$0].status }
        if let index = index(of: id) {
            items[index].symbol = symbol
            items[index].title = title
            if let detail { items[index].detail = detail }
            if let terminal { items[index].terminal = terminal }
            items[index].updatedAt = Date()
        } else {
            var activity = Activity(
                id: id,
                kind: kind,
                symbol: symbol,
                title: title,
                detail: detail ?? "",
                status: .running,
                progress: .indeterminate,
                updatedAt: Date()
            )
            activity.terminal = terminal
            withAnimation(NotchMotion.expand) { items.append(activity) }
        }

        guard status != previous || previous == nil else { return }
        switch status {
        case .done, .failed:
            finish(id, status: status)
        case .running, .needsAttention:
            guard let index = index(of: id) else { return }
            tasks.removeValue(forKey: id)?.cancel()
            items[index].status = status
            // A spinner reads as "working"; a full amber ring reads as "waiting for you".
            items[index].progress = status == .needsAttention ? .fraction(1) : .indeterminate
            if status == .needsAttention, items[index].presentation != .ambient {
                completionTick += 1
                if AppSettings.shared.playsSounds { NSSound(named: "Ping")?.play() }
            }
        }
    }

    // MARK: Lifecycle

    func finish(_ id: UUID, status: Activity.Status) {
        guard let index = index(of: id) else { return }
        items[index].status = status
        items[index].progress = .fraction(1)
        items[index].updatedAt = Date()
        // Ambient items sit behind everything else; they never call attention to themselves.
        if items[index].presentation != .ambient {
            completionTick += 1
            if AppSettings.shared.playsSounds {
                NSSound(named: status == .failed ? "Basso" : "Glass")?.play()
            }
        }
        tasks[id]?.cancel()
        tasks[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.autoDismissDelay)
            guard !Task.isCancelled else { return }
            self?.dismiss(id)
        }
    }

    /// Attaches or clears a decision; the row keeps its status (a cleared request stays `needsAttention`).
    func setDecision(_ id: UUID, _ decision: PendingDecision?) {
        guard let index = index(of: id) else { return }
        items[index].decision = decision
    }

    /// Edits a source-owned activity in place, without finish feedback.
    func update(_ id: UUID, _ change: (inout Activity) -> Void) {
        guard let index = index(of: id) else { return }
        change(&items[index])
    }

    func dismiss(_ id: UUID, animation: Animation = NotchMotion.collapse) {
        tasks.removeValue(forKey: id)?.cancel()
        withAnimation(animation) { items.removeAll { $0.id == id } }
    }

    private func scheduleCompletion(of id: UUID, at end: Date) {
        tasks[id]?.cancel()
        tasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.completePhase(id)
        }
    }

    private func index(of id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }
}
