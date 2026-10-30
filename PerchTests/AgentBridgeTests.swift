import Foundation
import Testing
@testable import Perch

private final class FixtureToken {}

/// Real hook payloads captured on this machine (Claude Code 2.1.312, codex-cli 0.164.0).
private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle(for: FixtureToken.self).url(forResource: name, withExtension: "json"))
    return try Data(contentsOf: url)
}

private let terminal = AgentTerminal(program: "Apple_Terminal", bundle: nil, tty: "/dev/ttys004", pid: 42)

struct AgentEventTests {
    @Test func claudePermissionRequestBecomesAShortQuestion() throws {
        let event = try #require(AgentEvent.fromHook(try fixture("claude-PermissionRequest"), source: .claude, term: terminal))
        #expect(event.type == "permission_request")
        #expect(event.session == "00c9d480-458d-4d3b-9fd2-774d1dc70382")
        #expect(event.cwd == "/private/tmp/perch-cap")
        #expect(event.message == "Allow Bash: rtk ls?")
        #expect(event.term == terminal)
        #expect(AgentSessions.transition(for: event) == .status(.needsAttention))
    }

    @Test func toolOutputNeverLeavesTheCLI() throws {
        for name in ["claude-PostToolUse", "codex-PostToolUse"] {
            let data = try fixture(name)
            let source: AgentSource = name.hasPrefix("claude") ? .claude : .codex
            let event = try #require(AgentEvent.fromHook(data, source: source, term: nil))
            let line = try #require(event.encodedLine())
            // The payload carries the tool's whole output; the forwarded line keeps only the summary.
            #expect(line.count < 400)
            #expect(event.type == "post_tool_use")
            #expect(AgentSessions.transition(for: event) == .status(.running))
        }
        let read = try #require(AgentEvent.fromHook(try fixture("claude-PostToolUse"), source: .claude, term: nil))
        #expect(read.message == "Read: /private/tmp/perch-cap/settings.json")
    }

    @Test func everyCapturedPayloadMapsToItsStatus() throws {
        let expected: [String: AgentSessions.Transition] = [
            "claude-SessionStart": .track, "codex-SessionStart": .track,
            "claude-UserPromptSubmit": .status(.running), "codex-UserPromptSubmit": .status(.running),
            "claude-Stop": .status(.done), "codex-Stop": .status(.done),
            "claude-SessionEnd": .dismiss, "codex-SessionEnd": .dismiss,
        ]
        for (name, transition) in expected {
            let source: AgentSource = name.hasPrefix("claude") ? .claude : .codex
            let event = try #require(AgentEvent.fromHook(try fixture(name), source: source, term: nil), "\(name)")
            #expect(AgentSessions.transition(for: event) == transition, "\(name)")
        }
        let stop = try #require(AgentEvent.fromHook(try fixture("codex-Stop"), source: .codex, term: nil))
        #expect(stop.message == "done")
    }

    @Test func remainingEventsMapPerThePlan() {
        func event(_ type: String, exitCode: Int32? = nil) -> AgentEvent {
            AgentEvent(v: 1, source: .watch, type: type, session: "s", ts: 0, exitCode: exitCode)
        }
        #expect(AgentSessions.transition(for: event("notification")) == .status(.needsAttention))
        #expect(AgentSessions.transition(for: event("stop_failure")) == .status(.failed))
        #expect(AgentSessions.transition(for: event("interrupt")) == .status(.done))
        #expect(AgentSessions.transition(for: event("start")) == .status(.running))
        #expect(AgentSessions.transition(for: event("exit", exitCode: 0)) == .status(.done))
        #expect(AgentSessions.transition(for: event("exit", exitCode: 2)) == .status(.failed))
        #expect(AgentSessions.transition(for: event("pre_compact")) == .ignore)
    }

    @Test func eventNamesNormaliseToSnakeCase() {
        #expect(AgentEvent.snakeCase("PermissionRequest") == "permission_request")
        #expect(AgentEvent.snakeCase("permission_request") == "permission_request")
        #expect(AgentEvent.snakeCase("Stop") == "stop")
    }

    @Test func payloadsWithoutAnEventNameAreDropped() {
        #expect(AgentEvent.fromHook(Data("not json".utf8), source: .claude, term: nil) == nil)
        #expect(AgentEvent.fromHook(Data(#"{"session_id":"x"}"#.utf8), source: .claude, term: nil) == nil)
        #expect(AgentEvent.fromHook(Data("[1,2]".utf8), source: .claude, term: nil) == nil)
    }

    @Test func longMessagesAreCondensedToOneLine() throws {
        let prompt = String(repeating: "word\n", count: 100)
        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit", "session_id": "s", "prompt": prompt,
        ])
        let event = try #require(AgentEvent.fromHook(data, source: .claude, term: nil))
        let message = try #require(event.message)
        #expect(message.count == AgentEvent.maxMessageLength)
        #expect(!message.contains("\n"))
        #expect(message.hasSuffix("…"))
    }
}

struct AgentSessionsTests {
    private func event(_ type: String, session: String = "a", message: String? = nil) -> AgentEvent {
        AgentEvent(v: 1, source: .claude, type: type, session: session, cwd: "/Users/me/api-server",
                   message: message, term: terminal, ts: 0)
    }

    @Test func oneSessionKeepsOneRowThroughItsLifecycle() {
        let center = ActivityCenter()
        let sessions = AgentSessions(activities: center)

        sessions.handle(event("session_start"))
        #expect(center.items.isEmpty) // an idle agent is not "running"

        sessions.handle(event("user_prompt_submit", message: "fix the tests"))
        sessions.handle(event("permission_request", message: "Allow Bash: npm test?"))
        #expect(center.items.count == 1)
        let row = center.items[0]
        #expect(row.status == .needsAttention)
        #expect(row.title == "Claude · api-server")
        #expect(row.detail == "Allow Bash: npm test?")
        #expect(row.terminal == terminal)

        sessions.handle(event("post_tool_use", message: "Bash: npm test"))
        #expect(center.items.first?.status == .running)
        sessions.handle(event("stop", message: "All green"))
        #expect(center.items.count == 1)
        #expect(center.items.first?.status == .done)

        sessions.handle(event("session_end"))
        #expect(center.items.isEmpty)
    }

    @Test func separateSessionsGetSeparateRows() {
        let center = ActivityCenter()
        let sessions = AgentSessions(activities: center)
        sessions.handle(event("user_prompt_submit", session: "a"))
        sessions.handle(event("user_prompt_submit", session: "b"))
        #expect(center.items.count == 2)
    }

    @Test func eventWithoutTextKeepsThePreviousDetail() {
        let center = ActivityCenter()
        let sessions = AgentSessions(activities: center)
        sessions.handle(event("user_prompt_submit", message: "refactor"))
        sessions.handle(event("post_tool_use", message: nil))
        #expect(center.items.first?.detail == "refactor")
    }

    @Test func silentSessionsAreDroppedAfterThirtyMinutes() {
        let clock = TestClock()
        let center = ActivityCenter()
        let sessions = AgentSessions(activities: center, now: { clock.now })
        sessions.handle(event("user_prompt_submit", session: "old"))
        clock.advance(10 * 60)
        sessions.handle(event("user_prompt_submit", session: "new"))

        clock.advance(20 * 60) // "old" silent for exactly 30 min: kept
        sessions.pruneIdle()
        #expect(center.items.count == 2)

        clock.advance(1)
        sessions.pruneIdle()
        #expect(center.items.map(\.title).count == 1)
    }

    @Test func watchExitSummarisesCodeAndDuration() {
        let ok = AgentEvent(v: 1, source: .watch, type: "exit", session: "w", cwd: "/x/app", message: "npm test",
                            ts: 0, exitCode: 0, duration: 75)
        #expect(AgentSessions.detail(for: ok) == "Finished in 1m 15s")
        #expect(AgentSessions.title(for: ok) == "npm · app")
        var failed = ok
        failed.exitCode = 1
        failed.duration = 3.4
        #expect(AgentSessions.detail(for: failed) == "Exit 1 after 3s")
    }
}

/// Runs the real `perch` helper embedded in the test host app.
struct PerchCLITests {
    private var helper: URL { Bundle.main.bundleURL.appending(path: "Contents/Helpers/perch") }

    private func socketPath() -> URL {
        URL(filePath: NSTemporaryDirectory()).appending(path: "p-\(UUID().uuidString.prefix(8)).sock")
    }

    private func run(_ arguments: [String], stdin: Data, socket: URL) throws -> (status: Int32, stdout: Data, elapsed: TimeInterval) {
        let process = Process()
        process.executableURL = helper
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["PERCH_SOCKET": socket.path]) { $1 }
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        let start = Date()
        try process.run()
        input.fileHandleForWriting.write(stdin)
        try input.fileHandleForWriting.close()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, stdout, Date().timeIntervalSince(start))
    }

    @Test func hookFailsOpenWhenPerchIsNotListening() throws {
        let socket = socketPath()
        let payload = try fixture("claude-PermissionRequest")

        // No socket file at all.
        let missing = try run(["event", "--source", "claude"], stdin: payload, socket: socket)
        #expect(missing.status == 0)
        #expect(missing.stdout.isEmpty)
        #expect(missing.elapsed < 1)

        // A stale socket file from a crashed Perch: bound once, nobody listening.
        makeStaleSocket(at: socket)
        defer { try? FileManager.default.removeItem(at: socket) }
        let refused = try run(["event", "--source", "claude"], stdin: payload, socket: socket)
        #expect(refused.status == 0)
        #expect(refused.stdout.isEmpty)
        #expect(refused.elapsed < 1)
    }

    @Test func hookIgnoresGarbageAndUnknownSources() throws {
        let socket = socketPath()
        for arguments in [["event", "--source", "claude"], ["event", "--source", "gemini"], ["event"]] {
            let result = try run(arguments, stdin: Data("{not json".utf8), socket: socket)
            #expect(result.status == 0)
            #expect(result.stdout.isEmpty)
        }
    }

    @Test func hookEventReachesTheBridgeThatReplacedAStaleSocket() async throws {
        let socket = socketPath()
        makeStaleSocket(at: socket)
        let received = Received()
        let bridge = AgentBridge(socketURL: socket) { received.append($0) }
        try bridge.start()
        defer { bridge.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: socket.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        let result = try run(["event", "--source", "claude"], stdin: try fixture("claude-PermissionRequest"), socket: socket)
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)

        let events = try await received.wait(count: 1)
        #expect(events.first?.type == "permission_request")
        #expect(events.first?.source == .claude)
        #expect(events.first?.message == "Allow Bash: rtk ls?")
    }

    @Test func watchReportsStartAndExitAndForwardsTheCode() async throws {
        let socket = socketPath()
        let received = Received()
        let bridge = AgentBridge(socketURL: socket) { received.append($0) }
        try bridge.start()
        defer { bridge.stop() }

        let result = try run(["watch", "--", "/bin/sh", "-c", "exit 3"], stdin: Data(), socket: socket)
        #expect(result.status == 3)

        let events = try await received.wait(count: 2)
        #expect(events.map(\.type) == ["start", "exit"])
        #expect(events.last?.exitCode == 3)
        #expect(events.last?.source == .watch)
        #expect(events.first?.session == events.last?.session)
    }
}

/// Events the bridge delivered on its own queue.
private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentEvent] = []

    func append(_ event: AgentEvent) {
        lock.withLock { events.append(event) }
    }

    func wait(count: Int, timeout: TimeInterval = 2) async throws -> [AgentEvent] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = lock.withLock { events }
            if snapshot.count >= count { return snapshot }
            try await Task.sleep(for: .milliseconds(20))
        }
        return lock.withLock { events }
    }
}

private func makeStaleSocket(at url: URL) {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: url.path.utf8)
        buffer[url.path.utf8.count] = 0
    }
    _ = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    close(descriptor)
}
