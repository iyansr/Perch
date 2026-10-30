import Foundation
import Testing
@testable import Perch

struct ActivityCenterTests {
    private func freshLog() -> PomodoroLog {
        let name = "perch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return PomodoroLog(defaults: defaults)
    }

    private func activity(
        _ kind: Activity.Kind,
        title: String,
        status: Activity.Status = .running,
        presentation: Activity.Presentation = .persistent,
        updatedAt: Date = Date()
    ) -> Activity {
        Activity(
            id: UUID(), kind: kind, symbol: "circle", title: title, detail: "", status: status,
            progress: .indeterminate, updatedAt: updatedAt, presentation: presentation
        )
    }

    @Test func slotOrderIsAttentionThenTransientThenFinishedThenRunningThenAmbient() {
        let center = ActivityCenter(pomodoroLog: freshLog())
        let old = Date(timeIntervalSinceNow: -60)
        center.show(activity(.conversion(batchID: UUID()), title: "ambient", presentation: .ambient))
        center.show(activity(.timer, title: "running", updatedAt: old))
        center.show(activity(.conversion(batchID: UUID()), title: "done", status: .done, updatedAt: old))
        center.show(activity(.conversion(batchID: UUID()), title: "failed", status: .failed, updatedAt: old))
        center.flash(activity(.hud(.volume), title: "transient", presentation: .transient(.seconds(5))))
        center.show(activity(.agent(source: .claude, sessionID: "a"), title: "blocked", status: .needsAttention, updatedAt: old))

        #expect(center.sorted.map(\.title) == ["blocked", "transient", "failed", "done", "running", "ambient"])
    }

    @Test func newerRunningActivityLeadsAmongEquals() {
        let center = ActivityCenter(pomodoroLog: freshLog())
        center.show(activity(.timer, title: "older", updatedAt: Date(timeIntervalSinceNow: -10)))
        center.show(activity(.timer, title: "newer"))
        #expect(center.sorted.first?.title == "newer")
    }

    @Test func hudFlashesNeverExpandAndAmbientStaysOffHome() {
        let center = ActivityCenter(pomodoroLog: freshLog())
        center.flash(activity(.hud(.volume), title: "volume", presentation: .transient(.seconds(5))))
        center.show(activity(.conversion(batchID: UUID()), title: "weather", presentation: .ambient))
        center.show(activity(.timer, title: "timer"))

        #expect(center.glanceItems.map(\.title) == ["timer", "weather"])
        #expect(center.listedItems.map(\.title) == ["timer"])
    }

    @Test func repeatedFlashResetsTheClockAndKeepsOneRow() async throws {
        let center = ActivityCenter(pomodoroLog: freshLog())
        let duration: Duration = .milliseconds(300)
        let first = center.flash(activity(.hud(.volume), title: "40%", presentation: .transient(duration)))
        try await Task.sleep(for: .milliseconds(200))
        let second = center.flash(activity(.hud(.volume), title: "50%", presentation: .transient(duration)))
        #expect(second == first)
        #expect(center.items.map(\.title) == ["50%"])

        try await Task.sleep(for: .milliseconds(200)) // 400 ms after the first flash, 200 ms after the repeat
        #expect(center.items.count == 1)

        try await Task.sleep(for: .milliseconds(300))
        #expect(center.items.isEmpty)
    }

    @Test func flashesOfDifferentKindsAreSeparateRows() {
        let center = ActivityCenter(pomodoroLog: freshLog())
        center.flash(activity(.hud(.volume), title: "volume", presentation: .transient(.seconds(5))))
        center.flash(activity(.hud(.brightness), title: "brightness", presentation: .transient(.seconds(5))))
        #expect(center.items.count == 2)
    }

    @Test func ambientNeverPulses() {
        let center = ActivityCenter(pomodoroLog: freshLog())
        let ambient = activity(.conversion(batchID: UUID()), title: "weather", presentation: .ambient)
        center.show(ambient)
        center.upsert(id: ambient.id, kind: ambient.kind, symbol: "sun.max", title: "weather", detail: nil, status: .needsAttention)
        center.finish(ambient.id, status: .done)
        #expect(center.completionTick == 0)

        let timer = activity(.timer, title: "timer")
        center.show(timer)
        center.finish(timer.id, status: .done)
        #expect(center.completionTick == 1)
    }

    @Test func pomodoroAdvancesThroughPhasesAndLogsFocusCycles() {
        let log = freshLog()
        let center = ActivityCenter(pomodoroLog: log)
        let id = center.startTimer(.pomodoro)
        #expect(center.items.first?.title == "Focus")
        #expect(center.items.first?.detail == "25 min · 1 of 4")

        center.completePhase(id)
        let rest = center.items.first
        #expect(rest?.title == "Break")
        #expect(rest?.detail == "5 min · 1 of 4")
        #expect(rest?.status == .running)
        #expect(log.cycles() == 1)

        center.completePhase(id) // break over: focus 2
        #expect(center.items.first?.detail == "25 min · 2 of 4")
        #expect(log.cycles() == 1) // breaks do not count

        for _ in 0..<6 { center.completePhase(id) }
        #expect(center.items.first?.status == .done)
        #expect(log.cycles() == 4)
    }

    @Test func singleTimerFinishesAfterItsOnlyPhase() {
        let log = freshLog()
        let center = ActivityCenter(pomodoroLog: log)
        let id = center.startTimer(.single(60))
        center.completePhase(id)
        #expect(center.items.first?.status == .done)
        #expect(log.cycles() == 0)
    }
}

struct PomodoroLogTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func log() -> PomodoroLog {
        let name = "perch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return PomodoroLog(defaults: defaults, calendar: calendar)
    }

    private func day(_ offset: Int, from base: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: base)!
    }

    @Test func streakCountsConsecutiveDaysAndSurvivesUntilTodaysFirstCycle() {
        let log = log()
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 12))!
        log.recordCycle(at: day(-3, from: today))
        log.recordCycle(at: day(-2, from: today))
        log.recordCycle(at: day(-1, from: today))
        #expect(log.streak(asOf: today) == 3) // nothing yet today: yesterday's streak still stands

        log.recordCycle(at: today)
        log.recordCycle(at: today)
        #expect(log.cycles(on: today) == 2)
        #expect(log.streak(asOf: today) == 4)

        #expect(log.streak(asOf: day(2, from: today)) == 0) // a missed day breaks it
    }

    @Test func persistsAcrossInstances() {
        let name = "perch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        PomodoroLog(defaults: defaults).recordCycle()
        #expect(PomodoroLog(defaults: defaults).cycles() == 1)
    }
}
