import Foundation
import Observation

/// Connect / disconnect state of Claude Code and Codex, shown in onboarding and Settings.
/// Every write goes through a reviewed `PendingChange`: the user sees the diff before anything is written.
@Observable
final class AgentConnections {
    static let shared = AgentConnections()

    /// Agents Perch can connect, in display order.
    static let agents: [AgentSource] = [.claude, .codex]
    /// Newest major version the hook format was checked against (Claude Code 2.1.312, codex-cli 0.164.0).
    static let testedMajorVersion: [AgentSource: Int] = [.claude: 2, .codex: 0]

    enum Status: Equatable {
        case disconnected
        /// Perch entries exist but point at another copy of Perch or miss events.
        case needsReconnect
        /// Perch's own entries, from before the permission buttons: `PermissionRequest` has the old command or timeout.
        case needsUpdate
        /// Written, but Codex runs new hooks only after the user approves them in Codex.
        case awaitingApproval
        case connected
    }

    struct PendingChange: Equatable {
        let agent: AgentSource
        let isRemoval: Bool
        let newData: Data
        let diff: [UnifiedDiff.Line]
        let path: String
        /// Rewrites hooks Perch already installed ("Update Perch's hooks") instead of adding them.
        var isUpdate = false
    }

    private(set) var statuses: [AgentSource: Status] = [:]
    /// `--version` output, e.g. "2.1.312"; nil until checked or when the CLI is not on PATH.
    private(set) var versions: [AgentSource: String] = [:]
    private(set) var errors: [AgentSource: String] = [:]
    var pending: PendingChange?

    @ObservationIgnored private let home: URL
    @ObservationIgnored private let helperPath: String
    @ObservationIgnored private var checkedVersions = false

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        helperPath: String = Bundle.main.bundleURL.appending(path: "Contents/Helpers/perch").path
    ) {
        self.home = home
        self.helperPath = helperPath
    }

    func target(for agent: AgentSource) -> HookTarget {
        agent == .codex ? .codex(home: home) : .claude(home: home)
    }

    func status(of agent: AgentSource) -> Status { statuses[agent] ?? .disconnected }

    /// The agent's CLI answered `--version`, or its config folder exists.
    func isInstalled(_ agent: AgentSource) -> Bool {
        versions[agent] != nil
            || FileManager.default.fileExists(atPath: target(for: agent).fileURL.deletingLastPathComponent().path)
    }

    /// Newer major version than Perch was tested with.
    func isUntested(_ agent: AgentSource) -> Bool {
        guard let version = versions[agent], let tested = Self.testedMajorVersion[agent],
              let major = version.split(separator: ".").first.flatMap({ Int($0) })
        else { return false }
        return major > tested
    }

    /// Re-reads the config files; the first call also checks the agents' versions in the background.
    func refresh() {
        for agent in Self.agents { statuses[agent] = computeStatus(agent) }
        guard !checkedVersions else { return }
        checkedVersions = true
        for agent in Self.agents {
            Task.detached(priority: .utility) {
                let version = await Self.detectVersion(of: agent == .claude ? "claude" : "codex")
                await MainActor.run { [weak self] in
                    if let version { self?.versions[agent] = version }
                }
            }
        }
    }

    // MARK: Connect / disconnect

    func prepareConnect(_ agent: AgentSource) {
        let target = target(for: agent)
        let old = HookInstaller.read(target)
        do {
            let new = try HookInstaller.installing(
                into: old,
                events: target.events,
                helperPath: helperPath,
                source: agent
            )
            errors[agent] = nil
            pending = PendingChange(
                agent: agent,
                isRemoval: false,
                newData: new,
                diff: UnifiedDiff.lines(old: old.map { String(decoding: $0, as: UTF8.self) } ?? "", new: String(decoding: new, as: UTF8.self)),
                path: displayPath(target.fileURL),
                isUpdate: statuses[agent] == .needsUpdate
            )
        } catch {
            errors[agent] = "Could not read \(displayPath(target.fileURL)): \(error)"
        }
    }

    func prepareDisconnect(_ agent: AgentSource) {
        let target = target(for: agent)
        guard let old = HookInstaller.read(target) else { return }
        do {
            let new = try HookInstaller.removing(from: old)
            errors[agent] = nil
            pending = PendingChange(
                agent: agent,
                isRemoval: true,
                newData: new,
                diff: UnifiedDiff.lines(old: String(decoding: old, as: UTF8.self), new: String(decoding: new, as: UTF8.self)),
                path: displayPath(target.fileURL)
            )
        } catch {
            errors[agent] = "Could not read \(displayPath(target.fileURL)): \(error)"
        }
    }

    func confirmPending() {
        guard let change = pending else { return }
        pending = nil
        do {
            try HookInstaller.write(change.newData, to: target(for: change.agent))
            errors[change.agent] = nil
        } catch {
            errors[change.agent] = "Could not write \(change.path): \(error.localizedDescription)"
        }
        refresh()
    }

    func cancelPending() {
        pending = nil
    }

    // MARK: Status

    private func computeStatus(_ agent: AgentSource) -> Status {
        let target = target(for: agent)
        let data = HookInstaller.read(target)
        let installed = HookInstaller.installedCommands(in: data)
        guard !installed.isEmpty else { return .disconnected }
        let timeouts = HookInstaller.installedTimeouts(in: data)

        enum Entry { case current, outdated, other }
        // An entry written before the permission buttons existed has the plain command and a 5 s timeout under
        // `PermissionRequest`, so the agent would kill a helper that waits for the answer.
        func entry(_ event: String) -> Entry {
            let awaiting = HookInstaller.awaitingEvents.contains(event)
            let current = HookInstaller.command(helperPath: helperPath, source: agent, event: event)
            let plain = HookInstaller.command(helperPath: helperPath, source: agent)
            if installed[event] == [current] {
                return !awaiting || timeouts[event] == [HookInstaller.permissionTimeout] ? .current : .outdated
            }
            return awaiting && installed[event] == [plain] ? .outdated : .other
        }
        let entries = target.events.map(entry)
        if entries.contains(.other) { return .needsReconnect }
        if entries.contains(.outdated) { return .needsUpdate }
        if agent == .codex {
            let config = try? String(contentsOf: home.appending(path: ".codex/config.toml"), encoding: .utf8)
            var indexes: [String: Int] = [:]
            for event in target.events { indexes[event] = HookInstaller.perchGroupIndex(in: data, event: event) }
            guard Self.codexTrusts(config: config ?? "", hooksPath: target.fileURL.path, groupIndexes: indexes) else {
                return .awaitingApproval
            }
        }
        return .connected
    }

    /// Codex records approved hooks in config.toml as `[hooks.state."<hooks.json>:<event>:<group>:<hook>"]`.
    /// Perch never writes these; the user approves the hooks in Codex.
    nonisolated static func codexTrusts(config: String, hooksPath: String, groupIndexes: [String: Int]) -> Bool {
        guard !groupIndexes.isEmpty else { return false }
        return groupIndexes.allSatisfy { event, group in
            config.contains("[hooks.state.\"\(hooksPath):\(AgentEvent.snakeCase(event)):\(group):0\"]")
        }
    }

    private func displayPath(_ url: URL) -> String {
        let path = url.path
        return path.hasPrefix(home.path) ? "~" + path.dropFirst(home.path.count) : path
    }

    /// `<name> --version` through a login shell, so the user's PATH applies. Gives up after 2 s.
    nonisolated private static func detectVersion(of name: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(filePath: "/bin/zsh")
                process.arguments = ["-lc", "\(name) --version"]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { process.terminate() }
                }
                process.waitUntilExit()
                let text = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
                guard process.terminationStatus == 0,
                      let match = text.firstMatch(of: #/\d+(\.\d+)+/#)
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(match.output.0))
            }
        }
    }
}
