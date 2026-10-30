import Testing
import Foundation
@testable import Perch

struct TimerCommandTests {
    @Test func parsesCompoundDuration() {
        #expect(TimerCommand.parse("t 1h30m") == .single(5400))
    }

    @Test func bareNumberIsMinutes() {
        #expect(TimerCommand.parse("t 25") == .single(1500))
        #expect(TimerCommand.parse("t 25m") == .single(1500))
        #expect(TimerCommand.parse("t 90s") == .single(90))
    }

    @Test func zeroIsRejected() {
        #expect(TimerCommand.parse("t 0") == nil)
    }

    @Test func overTwentyFourHoursIsRejected() {
        #expect(TimerCommand.parse("t 25h") == nil)
        #expect(TimerCommand.parse("t 24h") == .single(86400))
    }

    @Test func pomodoroIsFourFocusPhasesWithBreaks() {
        let plan = TimerCommand.parse("t pomo")
        #expect(plan == TimerCommand.parse("t Pomodoro"))
        #expect(plan?.cycleCount == 4)
        #expect(plan?.phases.count == 8)
        #expect(plan?.phases.first == .init(kind: .focus, duration: 1500))
        #expect(plan?.phases[1] == .init(kind: .rest, duration: 300))
        #expect(plan?.cycle(at: 3) == 2) // second break belongs to cycle 2
    }

    @Test func malformedInputIsRejected() {
        #expect(TimerCommand.parse("t") == nil)
        #expect(TimerCommand.parse("t ") == nil)
        #expect(TimerCommand.parse("t abc") == nil)
        #expect(TimerCommand.parse("t 5x") == nil)
        #expect(TimerCommand.parse("25m") == nil)
    }
}

struct CalculatorTests {
    @Test func multiplies() {
        #expect(Calculator.evaluate("24*7") == 168)
    }

    @Test func respectsPrecedenceAndParens() {
        #expect(Calculator.evaluate("(3+4)^2") == 49)
        #expect(Calculator.evaluate("2+3*4") == 14)
    }

    @Test func bareNumberIsNotACalculation() {
        #expect(Calculator.evaluate("42") == nil)
    }

    @Test func invalidInputIsRejected() {
        #expect(Calculator.evaluate("") == nil)
        #expect(Calculator.evaluate("2+") == nil)
        #expect(Calculator.evaluate("safari") == nil)
        #expect(Calculator.evaluate("1/0") == nil) // infinite result
    }
}

struct UnitConverterTests {
    @Test func kilometersToMiles() throws {
        let result = try #require(UnitConverter.convert("5 km to mi"))
        #expect(abs(result.value - 3.10686) < 0.0001)
        #expect(result.symbol == "mi")
    }

    @Test func mismatchedDimensionsAreRejected() {
        #expect(UnitConverter.convert("5 km to kg") == nil)
    }

    @Test func unknownOrMalformedIsRejected() {
        #expect(UnitConverter.convert("5 km") == nil)
        #expect(UnitConverter.convert("km to mi") == nil)
        #expect(UnitConverter.convert("5 foo to mi") == nil)
    }
}

struct PerchCommandTests {
    @Test func matchesTitleAndAliases() {
        #expect(PerchCommand.matches("clipboard").first == .clipboardHistory)
        #expect(PerchCommand.matches("clip").first == .clipboardHistory)
        #expect(PerchCommand.matches("preferences").first == .settings)
        #expect(PerchCommand.matches("exit").first == .quit)
    }

    @Test func exactTitleOutranksFuzzyMatches() {
        #expect(PerchCommand.matches("settings").first == .settings)
        #expect(PerchCommand.matches("search files").first == .searchFiles)
    }

    @Test func unrelatedQueryMatchesNothing() {
        #expect(PerchCommand.matches("zzqx").isEmpty)
    }

    /// "pr" spells across "Quit Perch" only as a subsequence; ↵ on it must not quit the app.
    @Test func looseSubsequenceDoesNotMatch() {
        #expect(!PerchCommand.matches("pr").contains(.quit))
    }
}

/// Keys are persisted in settings; a key must keep naming the same item across launches.
struct LauncherItemTests {
    @Test func keysRoundTrip() {
        let pane = SystemSettingsPane.all[0]
        let items: [LauncherItem] = [
            .app(URL(fileURLWithPath: "/Applications/Visual Studio Code.app")),
            .setting(pane),
        ] + PerchCommand.allCases.map(LauncherItem.command)
        for item in items {
            #expect(LauncherItem(key: item.key) == item)
        }
    }

    @Test func keysMatchSearchResultIDs() {
        #expect(LauncherItem.command(.quit).key == SearchResult.command(.quit).id)
        let pane = SystemSettingsPane.all[0]
        #expect(LauncherItem.setting(pane).key == SearchResult.setting(pane).id)
    }

    @Test func unknownKeysAreRejected() {
        #expect(LauncherItem(key: "command:launchRockets") == nil)
        #expect(LauncherItem(key: "setting:com.example.missing") == nil)
        #expect(LauncherItem(key: "app:") == nil)
        #expect(LauncherItem(key: "file:/tmp/x") == nil)
        #expect(LauncherItem(key: "no-colon") == nil)
    }
}
