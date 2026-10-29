import Testing
import Foundation
@testable import Perch

struct TimerCommandTests {
    @Test func parsesCompoundDuration() {
        #expect(TimerCommand.parse("t 1h30m") == 5400)
    }

    @Test func bareNumberIsMinutes() {
        #expect(TimerCommand.parse("t 25") == 1500)
        #expect(TimerCommand.parse("t 25m") == 1500)
        #expect(TimerCommand.parse("t 90s") == 90)
    }

    @Test func zeroIsRejected() {
        #expect(TimerCommand.parse("t 0") == nil)
    }

    @Test func overTwentyFourHoursIsRejected() {
        #expect(TimerCommand.parse("t 25h") == nil)
        #expect(TimerCommand.parse("t 24h") == 86400)
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
