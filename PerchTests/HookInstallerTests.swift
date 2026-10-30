import Foundation
import Testing
@testable import Perch

/// Shaped like this machine's real configs: other tools' hooks (Orca, Superset, Clowder, cux), matchers,
/// timeouts, unrelated settings, unicode and escapes. Written in the agents' own 2-space format.
private let claudeSettings = #"""
{
  "model": "opus",
  "env": {
    "GREETING": "héllo \"world\"\n"
  },
  "permissions": {
    "allow": [
      "Bash(ls:*)"
    ],
    "deny": []
  },
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "[ -n \"$SUPERSET_HOME_DIR\" ] && [ -x \"$SUPERSET_HOME_DIR/hooks/notify.sh\" ] && SUPERSET_HOOK_HARNESS=claude \"$SUPERSET_HOME_DIR/hooks/notify.sh\" || true"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "cux hook stop",
            "timeout": 10
          }
        ]
      },
      {
        "hooks": [
          {
            "type": "command",
            "command": "[ -x \"$HOME/.clowder/agent-hooks/agent-hook.sh\" ] && \"$HOME/.clowder/agent-hooks/agent-hook.sh\" claude || true",
            "timeout": 10
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "rtk hook claude"
          }
        ]
      }
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "~/.orca/agent-hooks/claude-statusline.sh",
    "padding": 0
  },
  "cleanupPeriodDays": 1e2
}

"""#

private let codexHooks = #"""
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "if [ -x '/Users/me/.orca/agent-hooks/codex-hook.sh' ]; then /bin/sh '/Users/me/.orca/agent-hooks/codex-hook.sh'; fi",
            "timeout": 10
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "[ -x \"$HOME/.clowder/agent-hooks/agent-hook.sh\" ] && \"$HOME/.clowder/agent-hooks/agent-hook.sh\" codex || true",
            "timeout": 10
          }
        ]
      }
    ]
  }
}

"""#

private let helper = "/Applications/Perch.app/Contents/Helpers/perch"

struct HookInstallerTests {
    private let claude = HookTarget.claude(home: URL(filePath: "/tmp/home"))
    private let codex = HookTarget.codex(home: URL(filePath: "/tmp/home"))

    private func install(_ text: String, _ target: HookTarget, helperPath: String = helper) throws -> Data {
        try HookInstaller.installing(
            into: Data(text.utf8),
            events: target.events,
            command: HookInstaller.command(helperPath: helperPath, source: target.agent)
        )
    }

    private func json(_ data: Data) throws -> JSONValue { try JSONValue.parse(data) }

    @Test func untouchedFilesRoundTripByteForByte() throws {
        for text in [claudeSettings, codexHooks] {
            #expect(try json(Data(text.utf8)).formatted() + "\n" == text)
        }
    }

    @Test func installAppendsAfterThirdPartyHooksAndKeepsThemIntact() throws {
        let original = try json(Data(claudeSettings.utf8))
        let installed = try json(try install(claudeSettings, claude))

        // Everything outside "hooks" is unchanged, in order.
        guard case let .object(before) = original, case let .object(after) = installed else { Issue.record(); return }
        #expect(before.map(\.key) == after.map(\.key))
        for member in before where member.key != "hooks" {
            #expect(installed[member.key] == member.value)
        }

        // Each existing event keeps its groups at the same indexes; Perch's group comes last.
        for event in ["PermissionRequest", "Stop", "PreToolUse"] {
            let old = try #require(original["hooks"]?[event]?.arrayValue)
            let new = try #require(installed["hooks"]?[event]?.arrayValue)
            if claude.events.contains(event) {
                #expect(Array(new.dropLast()) == old)
                #expect(new.last?["hooks"]?.arrayValue?.first?["command"]?.stringValue?.contains(HookInstaller.marker) == true)
            } else {
                #expect(new == old)
            }
        }
        #expect(HookInstaller.installedCommands(in: try install(claudeSettings, claude)).keys.sorted() == claude.events.sorted())
    }

    @Test func toolEventsMatchEveryTool() throws {
        let installed = try json(try install(claudeSettings, claude))
        #expect(installed["hooks"]?["PermissionRequest"]?.arrayValue?.last?["matcher"] == .string("*"))
        #expect(installed["hooks"]?["Stop"]?.arrayValue?.last?["matcher"] == nil)
    }

    @Test func secondInstallIsANoOp() throws {
        for (text, target) in [(claudeSettings, claude), (codexHooks, codex)] {
            let once = try install(text, target)
            let twice = try HookInstaller.installing(
                into: once, events: target.events,
                command: HookInstaller.command(helperPath: helper, source: target.agent)
            )
            #expect(once == twice)
        }
    }

    @Test func uninstallRestoresTheOriginalBytes() throws {
        for (text, target) in [(claudeSettings, claude), (codexHooks, codex)] {
            let removed = try HookInstaller.removing(from: try install(text, target))
            #expect(String(decoding: removed, as: UTF8.self) == text)
        }
    }

    @Test func uninstallOfAFileWithoutPerchChangesNothing() throws {
        let data = Data(claudeSettings.utf8)
        #expect(try HookInstaller.removing(from: data) == data)
    }

    @Test func movedAppUpdatesTheCommandInPlace() throws {
        let first = try install(codexHooks, codex)
        let moved = try HookInstaller.installing(
            into: first, events: codex.events,
            command: HookInstaller.command(helperPath: "/Users/me/Apps/Perch.app/Contents/Helpers/perch", source: .codex)
        )
        // Same group index, so Codex's trust key for the group stays put (its hash changes, so Codex asks again).
        #expect(HookInstaller.perchGroupIndex(in: moved, event: "Stop") == HookInstaller.perchGroupIndex(in: first, event: "Stop"))
        let commands = HookInstaller.installedCommands(in: moved).values.flatMap(\.self)
        #expect(commands.allSatisfy { $0.contains("/Users/me/Apps/") })
        #expect(HookInstaller.installedCommands(in: moved)["Stop"]?.count == 1)
    }

    @Test func installIntoMissingOrEmptyFile() throws {
        let command = HookInstaller.command(helperPath: helper, source: .codex)
        for input in [nil, Data(), Data("\n".utf8)] {
            let data = try HookInstaller.installing(into: input, events: codex.events, command: command)
            #expect(HookInstaller.installedCommands(in: data).count == codex.events.count)
            #expect(String(decoding: try HookInstaller.removing(from: data), as: UTF8.self) == "{}\n")
        }
    }

    @Test func malformedFilesAreRefused() {
        #expect(throws: (any Error).self) { try install("{ \"hooks\": [", claude) }
        #expect(throws: (any Error).self) { try install("[]", claude) }
        #expect(throws: (any Error).self) { try install(#"{"hooks": "nope"}"#, claude) }
    }

    @Test func commandIsGuardedAndQuoted() {
        let command = HookInstaller.command(helperPath: "/Users/o'neil/Perch.app/Contents/Helpers/perch", source: .claude)
        #expect(command == #"P='/Users/o'\''neil/Perch.app/Contents/Helpers/perch'; [ -x "$P" ] && "$P" event --source claude || true"#)
    }

    @Test func guardedCommandIsANoOpWithoutPerch() throws {
        let command = HookInstaller.command(helperPath: "/nonexistent/Perch.app/Contents/Helpers/perch", source: .claude)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", command]
        let output = Pipe()
        process.standardOutput = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }

    @Test func codexTrustNeedsEveryPerchGroupApproved() {
        let path = "/Users/me/.codex/hooks.json"
        let indexes = ["SessionStart": 2, "Stop": 1]
        let approved = """
        [hooks.state."\(path):session_start:2:0"]
        trusted_hash = "sha256:aa"

        [hooks.state."\(path):stop:1:0"]
        trusted_hash = "sha256:bb"
        """
        #expect(AgentConnections.codexTrusts(config: approved, hooksPath: path, groupIndexes: indexes))
        let partly = "[hooks.state.\"\(path):stop:1:0\"]\n"
        #expect(!AgentConnections.codexTrusts(config: partly, hooksPath: path, groupIndexes: indexes))
        // A third-party hook trusted at another index is not Perch's.
        let other = "[hooks.state.\"\(path):session_start:0:0\"]\n[hooks.state.\"\(path):stop:1:0\"]\n"
        #expect(!AgentConnections.codexTrusts(config: other, hooksPath: path, groupIndexes: indexes))
    }
}

struct HookInstallerFileTests {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "perch-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        return home
    }

    @Test func writeBacksUpThenReplacesKeepingPermissions() throws {
        let home = try makeHome(); defer { try? FileManager.default.removeItem(at: home) }
        let target = HookTarget.claude(home: home)
        try Data(claudeSettings.utf8).write(to: target.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.fileURL.path)

        let new = try HookInstaller.installing(
            into: HookInstaller.read(target), events: target.events,
            command: HookInstaller.command(helperPath: helper, source: .claude)
        )
        let backup = try #require(try HookInstaller.write(new, to: target, now: Date(timeIntervalSince1970: 0)))

        #expect(backup.lastPathComponent.hasPrefix("settings.json.perch-backup-"))
        #expect(try String(contentsOf: backup, encoding: .utf8) == claudeSettings)
        #expect(HookInstaller.read(target) == new)
        let mode = try FileManager.default.attributesOfItem(atPath: target.fileURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        // Same second again: a second backup, not an overwrite of the first.
        let second = try #require(try HookInstaller.write(new, to: target, now: Date(timeIntervalSince1970: 0)))
        #expect(second != backup)
    }

    @Test func writeFollowsASymlinkedConfig() throws {
        let home = try makeHome(); defer { try? FileManager.default.removeItem(at: home) }
        let target = HookTarget.claude(home: home)
        let real = home.appending(path: "dotfiles-settings.json")
        try Data(claudeSettings.utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: target.fileURL, withDestinationURL: real)

        let new = try HookInstaller.installing(
            into: HookInstaller.read(target), events: target.events,
            command: HookInstaller.command(helperPath: helper, source: .claude)
        )
        try HookInstaller.write(new, to: target)

        let link = try FileManager.default.destinationOfSymbolicLink(atPath: target.fileURL.path)
        #expect(link == real.path)
        #expect(try Data(contentsOf: real) == new)
    }

    @Test func connectionStatusFollowsTheFile() throws {
        let home = try makeHome(); defer { try? FileManager.default.removeItem(at: home) }
        let connections = AgentConnections(home: home, helperPath: helper)
        connections.refresh()
        #expect(connections.status(of: .claude) == .disconnected)

        connections.prepareConnect(.claude)
        let change = try #require(connections.pending)
        #expect(change.diff.contains { $0.kind == .added })
        #expect(!change.diff.contains { $0.kind == .removed })
        connections.confirmPending()
        #expect(connections.status(of: .claude) == .connected)

        // Codex: written, but not connected until Codex records the user's approval.
        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        connections.prepareConnect(.codex)
        connections.confirmPending()
        #expect(connections.status(of: .codex) == .awaitingApproval)

        // Another copy of Perch: reconnect needed.
        let other = AgentConnections(home: home, helperPath: "/elsewhere/Perch.app/Contents/Helpers/perch")
        other.refresh()
        #expect(other.status(of: .claude) == .needsReconnect)

        connections.prepareDisconnect(.claude)
        connections.confirmPending()
        #expect(connections.status(of: .claude) == .disconnected)
    }
}
