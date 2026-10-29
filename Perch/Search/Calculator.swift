import Foundation

/// Inline math answers (`24*7`, `(3+4)^2`, `10 ÷ 4`). Recursive descent; no NSExpression (it traps on bad input).
nonisolated enum Calculator {
    private static let allowed = Set("0123456789.+-*/^%()x×÷ ")

    static func evaluate(_ input: String) -> Double? {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty,
              text.allSatisfy(allowed.contains),
              text.contains(where: \.isNumber),
              Double(text) == nil // a bare number is not a calculation
        else { return nil }

        var parser = Parser(text
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "x", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .filter { $0 != " " })
        guard let value = parser.expression(), parser.isAtEnd, value.isFinite else { return nil }
        return value
    }

    /// Integers without a decimal point; otherwise up to `maxFractionDigits` fraction digits.
    static func format(_ value: Double, maxFractionDigits: Int = 10) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = maxFractionDigits
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private struct Parser {
        private let chars: [Character]
        private var position = 0

        init(_ text: String) { chars = Array(text) }

        var isAtEnd: Bool { position == chars.count }

        // expression = term (('+' | '-') term)*
        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                position += 1
                guard let rhs = term() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        // term = power (('*' | '/' | '%') power)*
        private mutating func term() -> Double? {
            guard var value = power() else { return nil }
            while let op = peek(), op == "*" || op == "/" || op == "%" {
                position += 1
                guard let rhs = power() else { return nil }
                switch op {
                case "*": value *= rhs
                case "/": value /= rhs
                default: value = value.truncatingRemainder(dividingBy: rhs)
                }
            }
            return value
        }

        // power = unary ('^' power)?   (right-associative)
        private mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            guard peek() == "^" else { return base }
            position += 1
            guard let exponent = power() else { return nil }
            return pow(base, exponent)
        }

        // unary = ('-' | '+') unary | primary
        private mutating func unary() -> Double? {
            if let op = peek(), op == "-" || op == "+" {
                position += 1
                guard let value = unary() else { return nil }
                return op == "-" ? -value : value
            }
            return primary()
        }

        // primary = number | '(' expression ')'
        private mutating func primary() -> Double? {
            if peek() == "(" {
                position += 1
                guard let value = expression(), peek() == ")" else { return nil }
                position += 1
                return value
            }
            let start = position
            while let c = peek(), c.isNumber || c == "." { position += 1 }
            return start == position ? nil : Double(String(chars[start..<position]))
        }

        private func peek() -> Character? {
            position < chars.count ? chars[position] : nil
        }
    }
}
