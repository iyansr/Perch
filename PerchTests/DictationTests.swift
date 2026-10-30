import AVFoundation
import Speech
import Testing
@testable import Perch

struct DictationTranscriptTests {
    @Test func shortTextPassesThroughWithWhitespaceCollapsed() {
        #expect(DictationTranscript.tail("  hello \n  world  ") == "hello world")
        #expect(DictationTranscript.tail("") == "")
    }

    @Test func longTextKeepsTheEndWithinTheLimit() {
        let text = "the quick brown fox jumps over the lazy dog and keeps running far away"
        let tail = DictationTranscript.tail(text, limit: 40)
        #expect(tail.count <= 40)
        #expect(tail.hasPrefix("…"))
        #expect(tail.hasSuffix("keeps running far away"))
    }

    @Test func aWordCutInHalfIsDroppedWhole() {
        // "…" + last 17 characters would start mid-word ("lf hotel lazy dog"); the partial word goes.
        let tail = DictationTranscript.tail("alpha bravo charlie delta echo foxtrot golf hotel lazy dog", limit: 18)
        #expect(tail == "…hotel lazy dog")
        #expect(tail.count <= 18)
    }

    @Test func aCutOnAWordBoundaryKeepsTheWord() {
        // The last 9 characters are "bbbb cccc"; the cut falls right after a space.
        let tail = DictationTranscript.tail("aaaa bbbb cccc", limit: 10)
        #expect(tail == "…bbbb cccc")
    }

    @Test func oneLongWordIsCutByCharacter() {
        let tail = DictationTranscript.tail(String(repeating: "x", count: 100), limit: 10)
        #expect(tail == "…" + String(repeating: "x", count: 9))
    }

    @Test func textWithoutSpacesIsCutByCharacter() {
        let tail = DictationTranscript.tail("今日はいい天気ですね散歩に行きましょう", limit: 8)
        #expect(tail == "…に行きましょう")
    }

    @Test func finalTextIsTrimmed() {
        #expect(DictationTranscript.final(" Hello, world. \n") == "Hello, world.")
        #expect(DictationTranscript.final("  \n ") == "")
    }
}

struct DictationLevelTests {
    @Test func rmsOfKnownSamples() {
        let silence: [Float] = [0, 0, 0, 0]
        let square: [Float] = [0.5, -0.5, 0.5, -0.5]
        let ramp: [Float] = [1, 0, -1, 0]
        #expect(silence.withUnsafeBufferPointer { DictationLevel.rms($0) } == 0)
        #expect(abs(square.withUnsafeBufferPointer { DictationLevel.rms($0) } - 0.5) < 1e-9)
        #expect(abs(ramp.withUnsafeBufferPointer { DictationLevel.rms($0) } - 0.5.squareRoot()) < 1e-9)
        #expect([Float]().withUnsafeBufferPointer { DictationLevel.rms($0) } == 0)
    }

    @Test func decibelScaleMapsToUnitRange() {
        #expect(DictationLevel.normalized(rms: 0) == 0)
        #expect(DictationLevel.normalized(rms: 1e-5) == 0)        // −100 dB: below the floor
        #expect(DictationLevel.normalized(rms: 1) == 1)           // 0 dB: above the ceiling
        #expect(abs(DictationLevel.normalized(rms: pow(10, -30.0 / 20)) - 0.5) < 1e-9) // −30 dB: middle of −50…−10
        #expect(abs(DictationLevel.normalized(rms: pow(10, -50.0 / 20))) < 1e-9)
        #expect(abs(DictationLevel.normalized(rms: pow(10, -10.0 / 20)) - 1) < 1e-9)
    }

    @Test func loudernessNeverLowersTheBar() {
        var previous = -1.0
        for step in stride(from: 0.0, through: 1.0, by: 0.01) {
            let value = DictationLevel.normalized(rms: step)
            #expect(value >= previous)
            #expect((0...1).contains(value))
            previous = value
        }
    }

    @Test func bufferLevelReadsTheFirstChannel() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        buffer.frameLength = 8
        for index in 0..<8 { buffer.floatChannelData![0][index] = index.isMultiple(of: 2) ? 0.1 : -0.1 }
        // 0.1 RMS = −20 dB → (−20 + 50) / 40 = 0.75
        #expect(abs(DictationLevel.level(of: buffer) - 0.75) < 1e-6)
    }

    @Test func smoothingRisesFasterThanItFalls() {
        let up = DictationLevel.smoothed(previous: 0, next: 1)
        let down = DictationLevel.smoothed(previous: 1, next: 0)
        #expect(abs(up - 0.6) < 1e-9)
        #expect(abs(down - 0.8) < 1e-9)
        #expect(DictationLevel.smoothed(previous: 0.4, next: 0.4) == 0.4)
    }

    @Test func smoothingConvergesToASteadyInput() {
        var level = 0.0
        for _ in 0..<60 { level = DictationLevel.smoothed(previous: level, next: 0.7) }
        #expect(abs(level - 0.7) < 1e-6)
    }

    @Test func quantizingHidesInvisibleChanges() {
        #expect(DictationLevel.quantized(0.501) == DictationLevel.quantized(0.504))
        #expect(DictationLevel.quantized(-0.2) == 0)
        #expect(DictationLevel.quantized(1.4) == 1)
    }

    @Test func peakMeterKeepsTheLoudestSinceTheLastTake() {
        let meter = PeakMeter()
        meter.record(0.2)
        meter.record(0.9)
        meter.record(0.4)
        #expect(meter.take() == 0.9)
        #expect(meter.take() == 0)
        meter.record(0.3)
        #expect(meter.take() == 0.3)
    }

    @Test func updatesRunAtAboutFifteenHertz() {
        #expect(abs(1 / DictationLevel.updateInterval - 15) < 1e-9)
    }
}

struct DictationPermissionTests {
    @Test func microphoneIsTheOnlyPermission() {
        #expect(DictationError.permissionProblem(microphone: .denied) == .microphoneDenied)
        #expect(DictationError.permissionProblem(microphone: .notDetermined) == .microphoneDenied)
        #expect(DictationError.permissionProblem(microphone: .restricted) == .microphoneDenied)
        #expect(DictationError.permissionProblem(microphone: .authorized) == nil)
    }

    @Test func failureLinesAreShort() {
        let all: [DictationError] = [.microphoneDenied, .noInput, .noModel, .unsupportedLocale, .interrupted]
        for error in all { #expect(error.message.count <= 40) }
        #expect(DictationError.engine("Custom").message == "Custom")
    }
}
