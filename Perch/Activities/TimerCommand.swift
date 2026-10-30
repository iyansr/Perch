import Foundation

/// What a timer runs: one countdown, or a Pomodoro cycle of focus and break phases.
nonisolated struct TimerPlan: Equatable, Hashable {
    struct Phase: Equatable, Hashable {
        enum Kind: Equatable, Hashable {
            case focus, rest
        }

        let kind: Kind
        let duration: TimeInterval
    }

    let phases: [Phase]
    let isPomodoro: Bool

    static func single(_ duration: TimeInterval) -> TimerPlan {
        TimerPlan(phases: [Phase(kind: .focus, duration: duration)], isPomodoro: false)
    }

    /// 25 min focus, 5 min break, four times.
    static let pomodoro = TimerPlan(
        phases: Array(repeating: [Phase(kind: .focus, duration: 25 * 60), Phase(kind: .rest, duration: 5 * 60)], count: 4)
            .flatMap { $0 },
        isPomodoro: true
    )

    /// Number of focus phases; Pomodoro's "of 4".
    var cycleCount: Int { phases.filter { $0.kind == .focus }.count }

    /// 1-based cycle the phase at `index` belongs to.
    func cycle(at index: Int) -> Int {
        phases.prefix(index + 1).filter { $0.kind == .focus }.count
    }

    /// "25 min", or "Pomodoro · 4 × 25 min".
    var label: String {
        guard isPomodoro, let focus = phases.first(where: { $0.kind == .focus }) else {
            return TimerCommand.label(for: phases.first?.duration ?? 0)
        }
        return "Pomodoro · \(cycleCount) × \(TimerCommand.label(for: focus.duration))"
    }
}

/// Parses `t 25m`, `t 1h30m`, `t 90s`, `t 5` (minutes), and `t pomodoro` / `t pomo`.
nonisolated enum TimerCommand {
    static let maxDuration: TimeInterval = 24 * 3600

    static func parse(_ query: String) -> TimerPlan? {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard text.hasPrefix("t ") else { return nil }
        let spec = text.dropFirst(2).filter { !$0.isWhitespace }
        guard !spec.isEmpty else { return nil }

        if spec == "pomo" || spec == "pomodoro" { return .pomodoro }

        if let minutes = Double(spec) {
            return valid(minutes * 60).map(TimerPlan.single)
        }

        var total: TimeInterval = 0
        var number = ""
        for character in spec {
            if character.isNumber || character == "." {
                number.append(character)
                continue
            }
            guard let value = Double(number) else { return nil }
            switch character {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            default: return nil
            }
            number = ""
        }
        guard number.isEmpty else { return nil }
        return valid(total).map(TimerPlan.single)
    }

    /// "25 min", "1 h 30 min", "45 s".
    static func label(for duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        let parts = [(seconds / 3600, "h"), (seconds % 3600 / 60, "min"), (seconds % 60, "s")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? "0 s" : parts.joined(separator: " ")
    }

    /// "4:59", "1:02:03".
    static func clock(_ remaining: TimeInterval) -> String {
        let seconds = max(0, Int(remaining.rounded(.up)))
        let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private static func valid(_ duration: TimeInterval) -> TimeInterval? {
        duration >= 1 && duration <= maxDuration ? duration : nil
    }
}

/// Completed Pomodoro focus phases per calendar day, for the Timer module's count and streak.
@Observable
final class PomodoroLog {
    static let shared = PomodoroLog()
    private static let key = "perch.pomodoroCycles"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let calendar: Calendar
    /// "yyyy-MM-dd" → completed focus phases that day.
    private(set) var counts: [String: Int]

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
        counts = defaults.dictionary(forKey: Self.key) as? [String: Int] ?? [:]
    }

    func recordCycle(at date: Date = Date()) {
        counts[dayKey(date), default: 0] += 1
        defaults.set(counts, forKey: Self.key)
    }

    func cycles(on date: Date = Date()) -> Int {
        counts[dayKey(date)] ?? 0
    }

    /// Consecutive days with at least one cycle, ending today (or yesterday, so the streak survives until today's first cycle).
    func streak(asOf date: Date = Date()) -> Int {
        var day = calendar.startOfDay(for: date)
        if cycles(on: day) == 0 {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var streak = 0
        while cycles(on: day) > 0 {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    private func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
