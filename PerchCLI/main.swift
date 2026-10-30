import Darwin
import Foundation

// `perch` — the bridge between coding agents and Perch.app.
//
//   perch event --source claude|codex   Hook command: reads the hook JSON on stdin, forwards a summary.
//   perch watch -- <cmd> [args…]         Runs <cmd>, reports start and exit; exits with <cmd>'s code.
//
// `event` runs inside agent hooks, so it fails open: it always exits 0, prints nothing, and gives up on
// the socket after 200 ms. Perch not running, no socket, bad input: the agent never notices.

private let socketTimeoutMilliseconds: Int32 = 200
private let shellNames: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "xonsh"]

signal(SIGPIPE, SIG_IGN)

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "event":
    runEvent(Array(arguments.dropFirst()))
case "watch":
    runWatch(Array(arguments.dropFirst()))
default:
    FileHandle.standardError.write(Data("""
    usage: perch event --source claude|codex   (hook command; reads the hook JSON on stdin)
           perch watch -- <command> [arguments…]

    """.utf8))
    exit(64)
}

// MARK: event

private func runEvent(_ arguments: [String]) -> Never {
    // Drain stdin first, whatever happens next, so the agent never blocks writing the payload.
    let payload = FileHandle.standardInput.readDataToEndOfFile()
    guard let index = arguments.firstIndex(of: "--source"),
          arguments.indices.contains(index + 1),
          let source = AgentSource(rawValue: arguments[index + 1]),
          let event = AgentEvent.fromHook(payload, source: source, term: currentTerminal()),
          let line = event.encodedLine()
    else { exit(0) }
    _ = send(line)
    exit(0)
}

// MARK: watch

private func runWatch(_ arguments: [String]) -> Never {
    var command = arguments
    if command.first == "--" { command.removeFirst() }
    guard !command.isEmpty else {
        FileHandle.standardError.write(Data("usage: perch watch -- <command> [arguments…]\n".utf8))
        exit(64)
    }

    let session = "watch-\(getpid())"
    let label = AgentEvent.condense(command.joined(separator: " "))
    let terminal = currentTerminal(launchedFromShell: true)
    let cwd = FileManager.default.currentDirectoryPath
    let started = Date()

    func report(_ type: String, exitCode: Int32? = nil) {
        let event = AgentEvent(
            v: AgentEvent.currentVersion, source: .watch, type: type, session: session, cwd: cwd,
            message: label, term: terminal, ts: Date().timeIntervalSince1970,
            exitCode: exitCode, duration: exitCode == nil ? nil : Date().timeIntervalSince(started)
        )
        if let line = event.encodedLine() { _ = send(line) }
    }

    report("start")
    let code = spawnAndWait(command)
    report("exit", exitCode: code)
    exit(code)
}

/// Runs the command with inherited stdio. Perch ignores ^C while it waits; the child gets it from the terminal
/// and its exit is still reported. Returns the exit code, `128 + signal` when killed, 127 when it cannot start.
private func spawnAndWait(_ command: [String]) -> Int32 {
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var defaults = sigset_t()
    sigemptyset(&defaults)
    sigaddset(&defaults, SIGINT)
    sigaddset(&defaults, SIGQUIT)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF))

    signal(SIGINT, SIG_IGN)
    signal(SIGQUIT, SIG_IGN)

    let argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let result = posix_spawnp(&pid, command[0], nil, &attributes, argv, environ)
    guard result == 0 else {
        FileHandle.standardError.write(Data("perch: \(command[0]): \(String(cString: strerror(result)))\n".utf8))
        return 127
    }

    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 {
        if errno != EINTR { return 1 }
    }
    let signalNumber = status & 0x7F
    return signalNumber == 0 ? (status >> 8) & 0xFF : 128 + signalNumber
}

// MARK: Terminal

/// TERM_PROGRAM, the terminal app's bundle ID, the tty and the user's shell, found by walking up the process tree.
/// Hooks get stdin as a pipe, so the tty comes from the nearest ancestor that has a controlling terminal.
/// - Parameter launchedFromShell: `perch watch` runs straight from the user's shell, so its parent is that shell.
private func currentTerminal(launchedFromShell: Bool = false) -> AgentTerminal {
    let environment = ProcessInfo.processInfo.environment
    let chain = ancestors(of: getppid())

    var tty = ttyname(STDIN_FILENO).map { String(cString: $0) }
    if tty == nil, let device = chain.lazy.map(\.terminalDevice).first(where: { $0 != -1 }),
       let name = devname(device, S_IFCHR) {
        tty = "/dev/" + String(cString: name)
    }

    // A hook runs as `sh -c …` under the agent; the user's shell is the first shell above the agent itself.
    let shell: ProcessInfoEntry?
    if launchedFromShell {
        shell = chain.first.flatMap { shellNames.contains($0.name) ? $0 : nil }
    } else {
        let agentIndex = chain.firstIndex { !shellNames.contains($0.name) }
        shell = agentIndex.flatMap { index in chain[(index + 1)...].first { shellNames.contains($0.name) } }
    }

    return AgentTerminal(
        program: environment["TERM_PROGRAM"],
        bundle: environment["__CFBundleIdentifier"],
        tty: tty,
        pid: shell?.pid
    )
}

private struct ProcessInfoEntry {
    let pid: pid_t
    let parent: pid_t
    let name: String
    let terminalDevice: dev_t
}

/// `pid` and its ancestors up to (not including) launchd, nearest first.
private func ancestors(of pid: pid_t) -> [ProcessInfoEntry] {
    var chain: [ProcessInfoEntry] = []
    var current = pid
    while current > 1, chain.count < 32, let entry = processEntry(current) {
        chain.append(entry)
        current = entry.parent
    }
    return chain
}

private func processEntry(_ pid: pid_t) -> ProcessInfoEntry? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let name = withUnsafeBytes(of: info.kp_proc.p_comm) { buffer in
        String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
    return ProcessInfoEntry(
        pid: pid,
        parent: info.kp_eproc.e_ppid,
        name: name,
        terminalDevice: info.kp_eproc.e_tdev
    )
}

// MARK: Socket

/// Writes `line` to Perch's socket (`PERCH_SOCKET` overrides the path, for tests).
/// Gives up after 200 ms in total; never blocks the caller longer.
private func send(_ line: Data) -> Bool {
    let path = ProcessInfo.processInfo.environment["PERCH_SOCKET"] ?? AgentEvent.socketURL.path
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else { return false }

    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    var one: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)

    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: path.utf8)
        buffer[path.utf8.count] = 0
    }
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(socketTimeoutMilliseconds) * 1_000_000
    func remaining() -> Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= deadline ? 0 : Int32((deadline - now) / 1_000_000)
    }

    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if connected != 0 {
        guard errno == EINPROGRESS, wait(for: Int16(POLLOUT), on: descriptor, milliseconds: remaining()) else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { return false }
    }

    return line.withUnsafeBytes { buffer -> Bool in
        var offset = 0
        while offset < buffer.count {
            let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
            if written > 0 {
                offset += written
            } else if written < 0, errno == EAGAIN || errno == EINTR {
                guard wait(for: Int16(POLLOUT), on: descriptor, milliseconds: remaining()) else { return false }
            } else {
                return false
            }
        }
        return true
    }
}

private func wait(for events: Int16, on descriptor: Int32, milliseconds: Int32) -> Bool {
    guard milliseconds > 0 else { return false }
    var request = pollfd(fd: descriptor, events: events, revents: 0)
    return poll(&request, 1, milliseconds) > 0 && request.revents & events != 0
}
