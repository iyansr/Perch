import Darwin
import Foundation

/// What a listening process is, judged from its executable and arguments.
nonisolated struct DevServerKind: Equatable, Sendable {
    /// Framework or runtime ("Next.js", "Vite", "PostgreSQL"), else the executable's name.
    let name: String
    /// Serves HTTP, so opening it in the browser makes sense; false for databases and caches.
    let isWeb: Bool
}

/// A process of the current user that listens on TCP and looks like something the user started for development.
nonisolated struct DevServer: Identifiable, Equatable, Sendable {
    let pid: pid_t
    /// Process start time (µs since 1970). A pid can be reused; stopping checks this first.
    let startTime: UInt64
    /// Listening ports, ascending, without duplicates (IPv4 and IPv6 sockets on one port count once).
    let ports: [Int]
    let kind: DevServerKind
    /// Working directory; nil when it says nothing about a project (`/`, the home folder).
    let directory: String?
    /// Full command line, for the tooltip.
    let command: String

    var id: pid_t { pid }
    var port: Int { ports[0] }

    var project: String? {
        directory.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    var url: URL? {
        kind.isWeb ? URL(string: "http://localhost:\(port)") : nil
    }
}

/// Decides which listening processes are dev servers. Pure, so the rules are testable without live processes.
nonisolated enum DevServerClassifier {
    /// Runtimes and servers that are listed wherever they are installed: python.org's Python runs from
    /// `Python.app`, Xcode's from `Xcode.app`, and both would otherwise fall under the app-bundle rule.
    private static let runtimes: [String: DevServerKind] = [
        "node": .init(name: "Node.js", isWeb: true),
        "bun": .init(name: "Bun", isWeb: true),
        "deno": .init(name: "Deno", isWeb: true),
        "python": .init(name: "Python", isWeb: true),
        "ruby": .init(name: "Ruby", isWeb: true),
        "php": .init(name: "PHP", isWeb: true),
        "java": .init(name: "Java", isWeb: true),
        "beam.smp": .init(name: "Elixir", isWeb: true),
        "dotnet": .init(name: ".NET", isWeb: true),
        "postgres": .init(name: "PostgreSQL", isWeb: false),
        "redis-server": .init(name: "Redis", isWeb: false),
        "mysqld": .init(name: "MySQL", isWeb: false),
        "mariadbd": .init(name: "MariaDB", isWeb: false),
        "mongod": .init(name: "MongoDB", isWeb: false),
    ]

    /// Frameworks, recognised by a path component of the command line (`node_modules/.bin/next` → `next`).
    /// First match wins, so specific tools come before the generic ones they run on.
    private static let frameworks: [(component: String, kind: DevServerKind)] = [
        ("next", .init(name: "Next.js", isWeb: true)),
        ("nuxt", .init(name: "Nuxt", isWeb: true)),
        ("nuxi", .init(name: "Nuxt", isWeb: true)),
        ("astro", .init(name: "Astro", isWeb: true)),
        ("remix", .init(name: "Remix", isWeb: true)),
        ("svelte-kit", .init(name: "SvelteKit", isWeb: true)),
        ("storybook", .init(name: "Storybook", isWeb: true)),
        ("expo", .init(name: "Expo", isWeb: true)),
        ("react-native", .init(name: "Metro", isWeb: true)),
        ("react-scripts", .init(name: "Create React App", isWeb: true)),
        ("ng", .init(name: "Angular", isWeb: true)),
        ("wrangler", .init(name: "Wrangler", isWeb: true)),
        ("vite", .init(name: "Vite", isWeb: true)),
        ("webpack", .init(name: "webpack", isWeb: true)),
        ("webpack-dev-server", .init(name: "webpack", isWeb: true)),
        ("parcel", .init(name: "Parcel", isWeb: true)),
        ("nest", .init(name: "NestJS", isWeb: true)),
        ("manage.py", .init(name: "Django", isWeb: true)),
        ("uvicorn", .init(name: "Uvicorn", isWeb: true)),
        ("gunicorn", .init(name: "Gunicorn", isWeb: true)),
        ("flask", .init(name: "Flask", isWeb: true)),
        ("jupyter", .init(name: "Jupyter", isWeb: true)),
        ("http.server", .init(name: "Python HTTP", isWeb: true)),
        ("rails", .init(name: "Rails", isWeb: true)),
        ("puma", .init(name: "Rails", isWeb: true)),
        ("artisan", .init(name: "Laravel", isWeb: true)),
        ("hugo", .init(name: "Hugo", isWeb: true)),
        ("jekyll", .init(name: "Jekyll", isWeb: true)),
    ]

    /// Coding agents and their helpers: stopping one would break a running agent session.
    private static let agents: Set<String> = [
        "claude", "claude-code", "codex", "opencode", "gemini", "gemini-cli", "cursor-agent",
        "amp", "aider", "copilot", "omp", "perch",
    ]

    /// Folders that hold system services, vendor agents and helpers rather than anything run from a project.
    private static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/"]

    /// The server's kind, or nil when the process is an app, a system service or an agent helper.
    /// - Parameters:
    ///   - executable: absolute path of the process image.
    ///   - arguments: argv, including argv[0].
    ///   - home: the user's home folder, so `~/Library` counts as system.
    static func classify(executable: String, arguments: [String], home: String) -> DevServerKind? {
        let name = baseName(executable)
        let binary = name.lowercased()
        let commandNames = ([executable] + arguments.prefix(3)).map(baseName)
        if commandNames.contains(where: agents.contains) { return nil }
        if arguments.contains(where: isAgentPackage) { return nil }

        let runtime = runtimes[binary] ?? (binary.hasPrefix("python") ? runtimes["python"] : nil)
        if runtime == nil {
            if executable.contains(".app/Contents/") { return nil }
            if systemPrefixes.contains(where: executable.hasPrefix) { return nil }
            if executable.hasPrefix(home + "/Library/") { return nil }
        }

        // argv[0] counts too: Next.js renames its server process to "next-server (v15.1.0)".
        let components = Set(arguments.flatMap { $0.split(separator: "/").map(String.init) })
        if components.contains(where: { $0.hasPrefix("next-server") }) { return .init(name: "Next.js", isWeb: true) }
        if let framework = frameworks.first(where: { components.contains($0.component) }) {
            return framework.kind
        }
        return runtime ?? DevServerKind(name: name, isWeb: true)
    }

    /// `/usr/local/bin/node` → `node`; npm's `bun.exe` shim → `bun`.
    static func baseName(_ path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name.hasSuffix(".exe") ? String(name.dropLast(4)) : name
    }

    private static func isAgentPackage(_ argument: String) -> Bool {
        argument.contains("@anthropic-ai/claude-code") || argument.contains("@openai/codex")
            || argument.contains("@google/gemini-cli")
    }

    /// The working directory when it names a project.
    static func projectDirectory(_ directory: String?, home: String) -> String? {
        guard let directory, !directory.isEmpty, directory != "/", directory != home else { return nil }
        return directory
    }
}

/// Reads listening sockets through libproc: no `lsof` process, no admin rights.
/// Only the current user's processes are inspected; the kernel hides other users' sockets anyway.
nonisolated enum DevServerScanner {
    static func scan() -> [DevServer] {
        let uid = getuid()
        let me = getpid()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return allPIDs().compactMap { pid -> DevServer? in
            guard pid > 0, pid != me, let info = bsdInfo(pid), info.pbi_uid == uid else { return nil }
            let ports = listeningPorts(pid)
            guard !ports.isEmpty, let executable = executablePath(pid) else { return nil }
            let arguments = self.arguments(pid)
            guard let kind = DevServerClassifier.classify(executable: executable, arguments: arguments, home: home) else {
                return nil
            }
            return DevServer(
                pid: pid,
                startTime: startTime(info),
                ports: ports,
                kind: kind,
                directory: DevServerClassifier.projectDirectory(workingDirectory(pid), home: home),
                command: arguments.isEmpty ? executable : arguments.joined(separator: " ")
            )
        }
        .sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// Sends SIGTERM, waits up to `grace` for the process to exit, then SIGKILL.
    /// Does nothing when the pid now belongs to a different process.
    /// - Returns: true when the process is gone.
    static func stop(_ server: DevServer, grace: Duration = .seconds(3)) async -> Bool {
        guard isSameProcess(server) else { return true }
        guard kill(server.pid, SIGTERM) == 0 else { return errno == ESRCH }
        let deadline = ContinuousClock.now + grace
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            if !isSameProcess(server) { return true }
        }
        guard kill(server.pid, SIGKILL) == 0 else { return errno == ESRCH }
        try? await Task.sleep(for: .milliseconds(200))
        return !isSameProcess(server)
    }

    /// Still running, not yet reaped zombie, and the same process that was listed (start time matches).
    private static func isSameProcess(_ server: DevServer) -> Bool {
        guard let info = bsdInfo(server.pid) else { return false }
        return info.pbi_status != UInt32(SZOMB) && startTime(info) == server.startTime
    }

    // MARK: libproc

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 32) // headroom for processes started meanwhile
        let count = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.stride))
        }
        return count > 0 ? Array(pids.prefix(Int(count))) : []
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func startTime(_ info: proc_bsdinfo) -> UInt64 {
        info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    private static func listeningPorts(_ pid: pid_t) -> [Int] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
        guard filled > 0 else { return [] }
        var ports = Set<Int>()
        let socketSize = Int32(MemoryLayout<socket_fdinfo>.stride)
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var socket = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, socketSize) == socketSize,
                  socket.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = socket.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            // insi_lport holds the port in network byte order in its low 16 bits.
            ports.insert(Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))))
        }
        return ports.sorted()
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4) // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    private static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// argv from `KERN_PROCARGS2`: argc, the exec path, NUL padding, then argc NUL-terminated strings.
    private static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 } // exec path
        while index < size, buffer[index] == 0 { index += 1 } // padding
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let end = buffer[index..<size].firstIndex(of: 0) ?? size
            arguments.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return arguments
    }
}

/// The listed servers, refreshed while the Dev Servers page is showing.
@Observable
final class DevServerMonitor {
    static let shared = DevServerMonitor()

    private(set) var servers: [DevServer] = []
    /// Servers being stopped, so their rows show progress and can't be stopped twice.
    private(set) var stopping: Set<pid_t> = []
    /// Set after the first scan, so the page can tell "none running" from "not looked yet".
    private(set) var hasScanned = false
    /// Bumped when a stop finishes; a scan that began before it may still list the stopped server.
    @ObservationIgnored private var generation = 0

    func refresh() async {
        let started = generation
        let servers = await Self.scan()
        guard generation == started else { return }
        self.servers = servers
        hasScanned = true
    }

    func stop(_ server: DevServer) async {
        guard stopping.insert(server.pid).inserted else { return }
        _ = await Self.stop(server)
        generation += 1
        await refresh()
        stopping.remove(server.pid)
    }

    @concurrent private static func scan() async -> [DevServer] {
        DevServerScanner.scan()
    }

    @concurrent private static func stop(_ server: DevServer) async -> Bool {
        await DevServerScanner.stop(server)
    }
}
