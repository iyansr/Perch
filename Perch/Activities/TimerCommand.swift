import Foundation

/// Parses `t 25m`, `t 1h30m`, `t 90s`, `t 5` (minutes) into a duration.
nonisolated enum TimerCommand {
    static let maxDuration: TimeInterval = 24 * 3600

    static func parse(_ query: String) -> TimeInterval? {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard text.hasPrefix("t ") else { return nil }
        let spec = text.dropFirst(2).filter { !$0.isWhitespace }
        guard !spec.isEmpty else { return nil }

        if let minutes = Double(spec) {
            return valid(minutes * 60)
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
        return valid(total)
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
