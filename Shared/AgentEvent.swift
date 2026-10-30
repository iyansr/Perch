import Foundation

// Compiled into both the app and the `perch` CLI. One JSON object per line over `AgentEvent.socketURL`.

/// Who sent an event.
nonisolated enum AgentSource: String, Codable, Sendable, CaseIterable {
    case claude, codex
    /// `perch watch -- <cmd>`.
    case watch

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .watch: "Command"
        }
    }
}

/// Where the agent runs, so the app can bring its terminal tab forward.
nonisolated struct AgentTerminal: Codable, Equatable, Sendable {
    /// `TERM_PROGRAM`, e.g. `Apple_Terminal`, `iTerm.app`, `vscode`.
    var program: String?
    /// `__CFBundleIdentifier` that macOS sets for processes an app launches; the most precise app hint.
    var bundle: String?
    /// Controlling terminal of the agent, e.g. `/dev/ttys004`.
    var tty: String?
    /// The interactive shell the agent was started from.
    var pid: Int32?
}

nonisolated struct AgentEvent: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maxMessageLength = 160

    /// Format version; the app ignores events newer than it understands.
    var v: Int
    var source: AgentSource
    /// Hook event in snake_case (`permission_request`, `stop`, …) or `start` / `exit` for `perch watch`.
    var type: String
    var session: String
    var cwd: String?
    /// Short, single-line text for the activity detail.
    var message: String?
    var term: AgentTerminal?
    /// Seconds since 1970.
    var ts: Double
    /// `perch watch` only.
    var exitCode: Int32?
    /// `perch watch` only, seconds.
    var duration: Double?
    /// `perch event --await` only: the sender keeps the connection open and waits for an `AgentReply` with this id.
    var request: String?

    enum CodingKeys: String, CodingKey {
        case v, source, type, session, cwd, message, term, ts, request
        case exitCode = "exit_code"
        case duration
    }

    /// `~/Library/Application Support/Perch/perch.sock`.
    static var socketURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Perch/perch.sock", directoryHint: .notDirectory)
    }

    /// One line of the wire format, newline included.
    func encodedLine() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(self) else { return nil }
        data.append(0x0A)
        return data
    }

    /// Builds an event from a Claude Code / Codex hook payload (stdin of the hook command).
    /// Only the few fields the app shows are kept; tool output and file contents never leave the CLI.
    /// Returns nil when the payload is not a JSON object with a `hook_event_name`.
    static func fromHook(_ data: Data, source: AgentSource, term: AgentTerminal?, now: Date = Date()) -> AgentEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["hook_event_name"] as? String, !name.isEmpty
        else { return nil }
        let type = snakeCase(name)
        return AgentEvent(
            v: currentVersion,
            source: source,
            type: type,
            session: object["session_id"] as? String ?? "default",
            cwd: object["cwd"] as? String,
            message: summary(type: type, payload: object).map(condense),
            term: term,
            ts: now.timeIntervalSince1970
        )
    }

    /// `PermissionRequest` → `permission_request`; snake_case input is returned unchanged.
    static func snakeCase(_ name: String) -> String {
        var result = ""
        for (index, character) in name.enumerated() {
            if character.isUppercase, index > 0, result.last != "_" { result.append("_") }
            result.append(contentsOf: character.lowercased())
        }
        return result
    }

    private static func summary(type: String, payload: [String: Any]) -> String? {
        let tool = payload["tool_name"] as? String
        let input = payload["tool_input"] as? [String: Any]
        let subject = ["command", "file_path", "url", "pattern", "description"]
            .lazy.compactMap { input?[$0] as? String }.first
        switch type {
        case "permission_request":
            guard let tool else { return "Needs permission" }
            return subject.map { "Allow \(tool): \($0)?" } ?? "Allow \(tool)?"
        case "post_tool_use":
            guard let tool else { return nil }
            return subject.map { "\(tool): \($0)" } ?? tool
        case "user_prompt_submit":
            return payload["prompt"] as? String
        case "stop":
            return payload["last_assistant_message"] as? String ?? "Finished"
        case "stop_failure":
            return payload["error"] as? String ?? payload["message"] as? String ?? "Stopped with an error"
        case "session_start":
            return "Session started"
        case "interrupt":
            return "Interrupted"
        default:
            return payload["message"] as? String
        }
    }

    /// Collapses whitespace to single spaces and caps the length.
    static func condense(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard words.count > maxMessageLength else { return words }
        return String(words.prefix(maxMessageLength - 1)) + "…"
    }
}

/// The app's answer to an `AgentEvent` that carried a `request`; one JSON line back on the same connection.
nonisolated struct AgentReply: Codable, Equatable, Sendable {
    /// How long `perch event --await` waits for the answer. Claude Code's hook timeout (120 s) stays above it.
    static let awaitSeconds: TimeInterval = 110
    /// `perch event --await` waits this many seconds instead when set (tests).
    static let awaitEnvironmentKey = "PERCH_AWAIT_TIMEOUT"

    var v = AgentEvent.currentVersion
    var request: String
    var allow: Bool

    /// One line of the wire format, newline included.
    func encodedLine() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(self) else { return nil }
        data.append(0x0A)
        return data
    }

    /// What the hook prints so the agent takes the answer: a `PermissionRequest` decision.
    /// Deny never sets `interrupt`, so the agent carries on and may try something else.
    var hookOutput: String {
        let decision = allow ? #"{"behavior": "allow"}"# : #"{"behavior": "deny", "message": "Denied from Perch"}"#
        return #"{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": \#(decision)}}"# + "\n"
    }
}
