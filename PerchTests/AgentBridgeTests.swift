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
    private func event(_ type: String, session: String = "a", message: String? = nil, request: String? = nil) -> AgentEvent {
        AgentEvent(v: 1, source: .claude, type: type, session: session, cwd: "/Users/me/api-server",
                   message: message, term: terminal, ts: 0, request: request)
    }

    /// Replies the sessions sent to the bridge.
    private final class Answers {
        var all: [String] = []
        func record(_ request: String, _ allow: Bool) { all.append("\(request):\(allow ? "allow" : "deny")") }
    }

    private func awaitingSetup() -> (ActivityCenter, AgentSessions, Answers) {
        let center = ActivityCenter()
        let answers = Answers()
        let sessions = AgentSessions(activities: center, reply: answers.record)
        sessions.handle(event("user_prompt_submit", message: "run it"))
        sessions.handle(event("permission_request", message: "Allow Bash: npm test?", request: "r1"))
        return (center, sessions, answers)
    }

    @Test func awaitedPermissionRequestShowsTheDecisionButtons() {
        let (center, _, answers) = awaitingSetup()
        #expect(center.items.count == 1)
        #expect(center.items[0].status == .needsAttention)
        #expect(center.items[0].decision == PendingDecision(id: "r1"))
        #expect(answers.all.isEmpty)
    }

    @Test func permissionRequestWithoutARequestIdHasNoButtons() {
        let center = ActivityCenter()
        let sessions = AgentSessions(activities: center)
        sessions.handle(event("permission_request", message: "Allow Bash: ls?"))
        #expect(center.items[0].status == .needsAttention)
        #expect(center.items[0].decision == nil)
    }

    @Test func allowAnswersTheHelperClearsTheButtonsAndResumesTheRow() {
        let (center, sessions, answers) = awaitingSetup()
        sessions.answer(request: "r1", allow: true)
        #expect(answers.all == ["r1:allow"])
        #expect(center.items[0].decision == nil)
        #expect(center.items[0].status == .running)
    }

    @Test func denyAnswersTheHelper() {
        let (center, sessions, answers) = awaitingSetup()
        sessions.answer(request: "r1", allow: false)
        #expect(answers.all == ["r1:deny"])
        #expect(center.items[0].decision == nil)
        #expect(center.items[0].status == .running)
    }

    @Test func aSecondAnswerOrAnUnknownRequestDoesNothing() {
        let (_, sessions, answers) = awaitingSetup()
        sessions.answer(request: "other", allow: true)
        sessions.answer(request: "r1", allow: true)
        sessions.answer(request: "r1", allow: false)
        #expect(answers.all == ["r1:allow"])
    }

    @Test func helperGoneClearsTheButtonsAndKeepsTheStatus() {
        let (center, sessions, answers) = awaitingSetup()
        sessions.requestEnded("r1")
        #expect(center.items[0].decision == nil)
        #expect(center.items[0].status == .needsAttention)
        sessions.answer(request: "r1", allow: true) // the card is gone, but a late answer must not reach anyone
        #expect(answers.all.isEmpty)
    }

    @Test func anyLaterEventOfTheSessionClearsTheButtons() {
        let (center, sessions, answers) = awaitingSetup()
        // The user answered in the terminal: the agent runs the tool and reports it.
        sessions.handle(event("post_tool_use", message: "Bash: npm test"))
        #expect(center.items[0].decision == nil)
        #expect(center.items[0].status == .running)
        sessions.answer(request: "r1", allow: true)
        #expect(answers.all.isEmpty)
    }

    @Test func aNewRequestReplacesTheOldButtons() {
        let (center, sessions, answers) = awaitingSetup()
        sessions.handle(event("permission_request", message: "Allow Write?", request: "r2"))
        #expect(center.items[0].decision == PendingDecision(id: "r2"))
        sessions.answer(request: "r1", allow: true)
        #expect(answers.all.isEmpty)
        sessions.answer(request: "r2", allow: true)
        #expect(answers.all == ["r2:allow"])
    }

    @Test func otherSessionsKeepTheirButtons() {
        let (center, sessions, _) = awaitingSetup()
        sessions.handle(event("user_prompt_submit", session: "b"))
        #expect(center.items.first { $0.decision != nil }?.decision == PendingDecision(id: "r1"))
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
        try runPerch(arguments, stdin: stdin, socket: socket, environment: [:])
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

    /// Starts `perch event --await` on the claude PermissionRequest fixture, off the main actor.
    private func startAwaiting(socket: URL, timeout: String = "10") throws -> Task<(status: Int32, stdout: Data, elapsed: TimeInterval), Error> {
        let payload = try fixture("claude-PermissionRequest")
        return Task.detached {
            try runPerch(["event", "--source", "claude", "--await"], stdin: payload, socket: socket,
                         environment: [AgentReply.awaitEnvironmentKey: timeout])
        }
    }

    @Test func awaitingHookPrintsTheAllowDecisionByteForByte() async throws {
        let socket = socketPath()
        let received = Received()
        let bridge = AgentBridge(socketURL: socket) { received.append($0) }
        try bridge.start()
        defer { bridge.stop() }

        let cli = try startAwaiting(socket: socket)
        let event = try #require(try await received.wait(count: 1).first)
        #expect(event.type == "permission_request")
        let request = try #require(event.request)
        bridge.reply(request: request, allow: true)

        let result = try await cli.value
        #expect(result.status == 0)
        #expect(result.stdout == (try fixture("claude-PermissionRequest-reply")))
        #expect(result.elapsed < 5)
    }

    @Test func awaitingHookPrintsTheDenyDecisionWithoutInterrupt() async throws {
        let socket = socketPath()
        let received = Received()
        let bridge = AgentBridge(socketURL: socket) { received.append($0) }
        try bridge.start()
        defer { bridge.stop() }

        let cli = try startAwaiting(socket: socket)
        let event = try #require(try await received.wait(count: 1).first)
        bridge.reply(request: try #require(event.request), allow: false)

        let result = try await cli.value
        #expect(result.status == 0)
        let expected = #"{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "deny", "message": "Denied from Perch"}}}"# + "\n"
        #expect(result.stdout == Data(expected.utf8))
        #expect(!String(decoding: result.stdout, as: UTF8.self).contains("interrupt"))
    }

    @Test func awaitingHookPrintsNothingWhenNobodyAnswersInTime() async throws {
        let socket = socketPath()
        let received = Received()
        let ended = Collector<String>()
        let bridge = AgentBridge(socketURL: socket, onRequestEnded: { ended.append($0) }) { received.append($0) }
        try bridge.start()
        defer { bridge.stop() }

        let result = try await startAwaiting(socket: socket, timeout: "0.4").value
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.elapsed >= 0.35)
        #expect(result.elapsed < 5)

        // The helper hung up: the bridge reports the request so the app can drop its buttons.
        let request = try #require(try await received.wait(count: 1).first?.request)
        #expect(try await ended.wait(count: 1) == [request])
    }

    @Test func awaitingHookPrintsNothingWithoutAnApp() throws {
        let socket = socketPath()
        let payload = try fixture("claude-PermissionRequest")
        let missing = try runPerch(["event", "--source", "claude", "--await"], stdin: payload, socket: socket,
                                   environment: [AgentReply.awaitEnvironmentKey: "10"])
        #expect(missing.status == 0)
        #expect(missing.stdout.isEmpty)
        #expect(missing.elapsed < 1)

        makeStaleSocket(at: socket)
        defer { try? FileManager.default.removeItem(at: socket) }
        let refused = try runPerch(["event", "--source", "claude", "--await"], stdin: payload, socket: socket,
                                   environment: [AgentReply.awaitEnvironmentKey: "10"])
        #expect(refused.status == 0)
        #expect(refused.stdout.isEmpty)
        #expect(refused.elapsed < 1)
    }

    @Test func awaitingHookPrintsNothingWhenPerchQuitsMidRequest() async throws {
        let socket = socketPath()
        let received = Received()
        let bridge = AgentBridge(socketURL: socket) { received.append($0) }
        try bridge.start()

        let cli = try startAwaiting(socket: socket)
        _ = try await received.wait(count: 1)
        bridge.stop()

        let result = try await cli.value
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.elapsed < 5) // EOF ends the wait; it does not sit out the 10 s timeout
    }

    @Test func hookWithoutAwaitSendsNoRequestAndDoesNotWait() async throws {
        let socket = socketPath()
        let received = Received()
        let bridge = AgentBridge(socketURL: socket) { received.append($0) }
        try bridge.start()
        defer { bridge.stop() }
        let result = try run(["event", "--source", "claude"], stdin: try fixture("claude-PermissionRequest"), socket: socket)
        #expect(result.stdout.isEmpty)
        #expect(result.elapsed < 1)
        #expect(try await received.wait(count: 1).first?.request == nil)
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

/// Talks to the bridge the way `perch event --await` does, without the helper.
struct AgentBridgeRequestTests {
    private func socketPath() -> URL {
        URL(filePath: NSTemporaryDirectory()).appending(path: "p-\(UUID().uuidString.prefix(8)).sock")
    }

    private func connect(to url: URL) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: url.path.utf8)
            buffer[url.path.utf8.count] = 0
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(result == 0)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return descriptor
    }

    private func send(_ event: AgentEvent, on descriptor: Int32) throws {
        let line = try #require(event.encodedLine())
        _ = line.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    }

    /// Everything the bridge wrote until it closed the connection (or 2 s passed).
    private func readAll(from descriptor: Int32) -> Data {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count <= 0 { return data }
            data.append(contentsOf: chunk[..<count])
        }
    }

    private func permissionRequest(_ request: String?) -> AgentEvent {
        AgentEvent(v: 1, source: .claude, type: "permission_request", session: "s", message: "Allow Bash: ls?",
                   ts: 0, request: request)
    }

    @Test func replyReachesTheClientThatAskedAndClosesItsConnection() async throws {
        let socket = socketPath()
        let received = Collector<AgentEvent>()
        let ended = Collector<String>()
        let bridge = AgentBridge(socketURL: socket, onRequestEnded: { ended.append($0) }) { received.append($0) }
        try bridge.start()
        defer { bridge.stop() }

        let first = try connect(to: socket)
        let second = try connect(to: socket)
        defer { close(first); close(second) }
        try send(permissionRequest("one"), on: first)
        try send(permissionRequest("two"), on: second)
        #expect(try await received.wait(count: 2).count == 2)

        bridge.reply(request: "two", allow: false)
        let line = readAll(from: second)
        #expect(try JSONDecoder().decode(AgentReply.self, from: line) == AgentReply(request: "two", allow: false))
        #expect(line.last == 0x0A)

        bridge.reply(request: "one", allow: true)
        #expect(try JSONDecoder().decode(AgentReply.self, from: readAll(from: first)) == AgentReply(request: "one", allow: true))

        // Answered requests are not "ended".
        #expect(try await ended.wait(count: 1, timeout: 0.2).isEmpty)
    }

    @Test func aClientThatHangsUpBeforeTheAnswerEndsItsRequest() async throws {
        let socket = socketPath()
        let received = Collector<AgentEvent>()
        let ended = Collector<String>()
        let bridge = AgentBridge(socketURL: socket, onRequestEnded: { ended.append($0) }) { received.append($0) }
        try bridge.start()
        defer { bridge.stop() }

        let client = try connect(to: socket)
        try send(permissionRequest("gone"), on: client)
        _ = try await received.wait(count: 1)
        close(client)
        #expect(try await ended.wait(count: 1) == ["gone"])

        bridge.reply(request: "gone", allow: true) // nobody is listening: no crash, no second report
        #expect(try await ended.wait(count: 2, timeout: 0.2) == ["gone"])
    }

    @Test func eventsWithoutARequestKeepNoConnectionOpenForReplies() async throws {
        let socket = socketPath()
        let received = Collector<AgentEvent>()
        let ended = Collector<String>()
        let bridge = AgentBridge(socketURL: socket, onRequestEnded: { ended.append($0) }) { received.append($0) }
        try bridge.start()
        defer { bridge.stop() }

        let client = try connect(to: socket)
        defer { close(client) }
        try send(permissionRequest(nil), on: client)
        _ = try await received.wait(count: 1)
        bridge.reply(request: "anything", allow: true)
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #expect(readAll(from: client).isEmpty)
        #expect(try await ended.wait(count: 1, timeout: 0.2).isEmpty)
    }

    @Test func requestsAreTheOnlyThingTheWireAddsToAnEvent() throws {
        let plain = try #require(permissionRequest(nil).encodedLine())
        #expect(!String(decoding: plain, as: UTF8.self).contains("\"request\":"))
        let asked = try #require(permissionRequest("r").encodedLine())
        #expect(try JSONDecoder().decode(AgentEvent.self, from: asked).request == "r")
        #expect(AgentReply.awaitSeconds == 110)
        #expect(HookInstaller.permissionTimeout > Int(AgentReply.awaitSeconds))
    }
}

/// Values the bridge delivered on its own queue.
nonisolated private final class Collector<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [Element] = []

    func append(_ element: Element) {
        lock.withLock { elements.append(element) }
    }

    func wait(count: Int, timeout: TimeInterval = 2) async throws -> [Element] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = lock.withLock { elements }
            if snapshot.count >= count { return snapshot }
            try await Task.sleep(for: .milliseconds(20))
        }
        return lock.withLock { elements }
    }
}

private typealias Received = Collector<AgentEvent>

/// Runs the embedded `perch` helper off the main actor, so a test can drive the bridge while it waits.
nonisolated private func runPerch(
    _ arguments: [String], stdin: Data, socket: URL, environment: [String: String]
) throws -> (status: Int32, stdout: Data, elapsed: TimeInterval) {
    let process = Process()
    process.executableURL = Bundle.main.bundleURL.appending(path: "Contents/Helpers/perch")
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment
        .merging(["PERCH_SOCKET": socket.path]) { $1 }
        .merging(environment) { $1 }
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
