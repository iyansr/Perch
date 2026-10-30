import Foundation

/// JSON that keeps object key order and number spelling, so editing an agent's config file changes only
/// the entries Perch touches. Prints in the 2-space style Claude Code and Codex write themselves
/// (`JSON.stringify(value, null, 2)`), so an untouched file round-trips byte for byte.
nonisolated indirect enum JSONValue: Equatable, Sendable {
    case object([JSONMember])
    case array([JSONValue])
    case string(String)
    /// The literal as written (`10`, `1.50`, `2e3`); never reformatted.
    case number(String)
    case bool(Bool)
    case null

    subscript(key: String) -> JSONValue? {
        guard case let .object(members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    var stringValue: String? {
        if case let .string(value) = self { value } else { nil }
    }

    var arrayValue: [JSONValue]? {
        if case let .array(values) = self { values } else { nil }
    }
}

nonisolated struct JSONMember: Equatable, Sendable {
    var key: String
    var value: JSONValue
}

nonisolated extension JSONValue {
    struct ParseError: Error, CustomStringConvertible {
        let offset: Int
        let reason: String
        var description: String { "Invalid JSON at byte \(offset): \(reason)" }
    }

    static func parse(_ data: Data) throws -> JSONValue {
        var parser = Parser(bytes: Array(data))
        parser.skipWhitespace()
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw parser.error("trailing content") }
        return value
    }

    /// Pretty-printed with 2-space indentation and `": "`, non-ASCII left as is.
    func formatted() -> String {
        var output = ""
        write(to: &output, indent: 0)
        return output
    }

    private func write(to output: inout String, indent: Int) {
        switch self {
        case let .object(members):
            guard !members.isEmpty else { output += "{}"; return }
            output += "{\n"
            for (index, member) in members.enumerated() {
                output += String(repeating: "  ", count: indent + 1)
                Self.writeString(member.key, to: &output)
                output += ": "
                member.value.write(to: &output, indent: indent + 1)
                output += index == members.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: "  ", count: indent) + "}"
        case let .array(values):
            guard !values.isEmpty else { output += "[]"; return }
            output += "[\n"
            for (index, value) in values.enumerated() {
                output += String(repeating: "  ", count: indent + 1)
                value.write(to: &output, indent: indent + 1)
                output += index == values.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: "  ", count: indent) + "]"
        case let .string(value):
            Self.writeString(value, to: &output)
        case let .number(literal):
            output += literal
        case let .bool(value):
            output += value ? "true" : "false"
        case .null:
            output += "null"
        }
    }

    private static func writeString(_ value: String, to output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case _ where scalar.value < 0x20:
                output += String(format: "\\u%04x", scalar.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}

private nonisolated struct Parser {
    let bytes: [UInt8]
    var index = 0

    func error(_ reason: String) -> JSONValue.ParseError {
        JSONValue.ParseError(offset: index, reason: reason)
    }

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
    }

    mutating func value() throws -> JSONValue {
        guard index < bytes.count else { throw error("unexpected end") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default: return .number(try number())
        }
    }

    private mutating func object() throws -> JSONValue {
        index += 1
        var members: [JSONMember] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected key") }
            let key = try string()
            skipWhitespace()
            try expect(":")
            skipWhitespace()
            members.append(JSONMember(key: key, value: try value()))
            skipWhitespace()
            guard index < bytes.count else { throw error("unexpected end") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            try expect("}")
            return .object(members)
        }
    }

    private mutating func array() throws -> JSONValue {
        index += 1
        var values: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(values) }
        while true {
            skipWhitespace()
            values.append(try value())
            skipWhitespace()
            guard index < bytes.count else { throw error("unexpected end") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            try expect("]")
            return .array(values)
        }
    }

    private mutating func string() throws -> String {
        index += 1 // opening quote
        var scalars = String.UnicodeScalarView()
        var raw: [UInt8] = []
        func flush() throws {
            guard !raw.isEmpty else { return }
            guard let text = String(bytes: raw, encoding: .utf8) else { throw error("invalid UTF-8") }
            scalars.append(contentsOf: text.unicodeScalars)
            raw.removeAll(keepingCapacity: true)
        }
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                try flush()
                return String(scalars)
            case UInt8(ascii: "\\"):
                try flush()
                index += 1
                guard index < bytes.count else { throw error("unexpected end") }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code), index + 1 < bytes.count,
                       bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        index += 2
                        let low = try hex4()
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                default:
                    throw error("bad escape")
                }
            default:
                guard byte >= 0x20 else { throw error("control character in string") }
                raw.append(byte)
                index += 1
            }
        }
        throw error("unterminated string")
    }

    private mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count,
              let text = String(bytes: bytes[index..<index + 4], encoding: .ascii),
              let value = UInt32(text, radix: 16)
        else { throw error("bad \\u escape") }
        index += 4
        return value
    }

    private mutating func number() throws -> String {
        let start = index
        let allowed = Set("+-0123456789.eE".utf8)
        while index < bytes.count, allowed.contains(bytes[index]) { index += 1 }
        let literal = String(decoding: bytes[start..<index], as: UTF8.self)
        guard !literal.isEmpty, Double(literal) != nil else { throw JSONValue.ParseError(offset: start, reason: "bad value") }
        return literal
    }

    private mutating func literal(_ word: String) throws {
        let utf8 = Array(word.utf8)
        guard index + utf8.count <= bytes.count, Array(bytes[index..<index + utf8.count]) == utf8 else {
            throw error("bad literal")
        }
        index += utf8.count
    }

    private mutating func expect(_ character: Character) throws {
        guard index < bytes.count, bytes[index] == character.asciiValue else { throw error("expected \(character)") }
        index += 1
    }
}
