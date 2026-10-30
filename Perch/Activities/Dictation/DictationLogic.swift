import AVFoundation
import Speech
import os

/// Text handling for the dictation card and the final insertion.
nonisolated enum DictationTranscript {
    /// Characters of the live transcript the card shows.
    static let visibleLimit = 40

    /// The end of the transcript for the one-line card: whitespace collapsed, at most `limit` characters
    /// including a leading "…" when the start was cut. A word cut in half is dropped whole.
    static func tail(_ text: String, limit: Int = visibleLimit) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit, limit > 1 else { return flat }
        let cut = flat.index(flat.endIndex, offsetBy: -(limit - 1))
        var tail = flat[cut...]
        let cutMidWord = !flat[flat.index(before: cut)].isWhitespace && tail.first != " "
        if cutMidWord, let space = tail.firstIndex(of: " ") {
            tail = tail[tail.index(after: space)...]
        } else if tail.first == " " {
            tail = tail.dropFirst()
        }
        return "…" + tail
    }

    /// What gets typed into the front app: the transcript without surrounding whitespace.
    static func final(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Microphone input level, from raw samples to the 0…1 the bars show.
nonisolated enum DictationLevel {
    /// The card's bars refresh this often; the audio callback runs faster and only feeds a `PeakMeter`.
    static let updateInterval: TimeInterval = 1.0 / 15.0
    /// RMS at or below this many dBFS reads as silence (0).
    static let floorDB: Double = -50
    /// RMS at or above this many dBFS reads as full scale (1). Speech at arm's length sits around −30…−15.
    static let ceilingDB: Double = -10

    static func rms(_ samples: UnsafeBufferPointer<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for sample in samples { sum += Double(sample) * Double(sample) }
        return (sum / Double(samples.count)).squareRoot()
    }

    /// Linear RMS (0…1 full scale) to a 0…1 bar height on a dB scale.
    static func normalized(rms: Double) -> Double {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels - floorDB) / (ceilingDB - floorDB), 0), 1)
    }

    /// First channel of a float buffer; other sample formats read as silence.
    static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        return normalized(rms: rms(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
    }

    /// Fast attack, slow release: bars jump up with the voice and fall back gently.
    static func smoothed(previous: Double, next: Double, attack: Double = 0.6, release: Double = 0.2) -> Double {
        previous + (next - previous) * (next > previous ? attack : release)
    }

    /// Rounded to 1/50 so a change too small to see does not rewrite the activity.
    static func quantized(_ level: Double) -> Double {
        (min(max(level, 0), 1) * 50).rounded() / 50
    }
}

/// Loudest level the audio callback saw since the UI last asked. Written from the audio thread, read from main.
nonisolated final class PeakMeter: Sendable {
    private let peak = OSAllocatedUnfairLock(initialState: 0.0)

    func record(_ level: Double) {
        peak.withLock { $0 = max($0, level) }
    }

    /// The peak since the last call, then back to zero.
    func take() -> Double {
        peak.withLock { value in
            defer { value = 0 }
            return value
        }
    }
}

/// Why dictation cannot run, as the short line the failed card shows.
nonisolated enum DictationError: Error, Equatable {
    case microphoneDenied
    case speechDenied
    case noInput
    case noModel
    case unsupportedLocale
    case interrupted
    case engine(String)

    var message: String {
        switch self {
        case .microphoneDenied: "Microphone access is off"
        case .speechDenied: "Speech Recognition access is off"
        case .noInput: "No microphone found"
        case .noModel: "Speech model unavailable"
        case .unsupportedLocale: "Language not supported"
        case .interrupted: "Microphone changed"
        case let .engine(text): text
        }
    }

    /// The first missing permission, or nil when dictation may start. Speech Recognition only matters to the
    /// `SFSpeechRecognizer` engine; the macOS 26 analyzer needs none.
    static func permissionProblem(
        microphone: AVAuthorizationStatus,
        speech: SFSpeechRecognizerAuthorizationStatus,
        needsSpeech: Bool
    ) -> DictationError? {
        if microphone != .authorized { return .microphoneDenied }
        if needsSpeech, speech != .authorized { return .speechDenied }
        return nil
    }
}
