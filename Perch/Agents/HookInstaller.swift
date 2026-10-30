import Foundation

/// One agent config file Perch adds hooks to.
nonisolated struct HookTarget: Sendable {
    let agent: AgentSource
    /// `~/.claude/settings.json` or `~/.codex/hooks.json`.
    let fileURL: URL
    /// Hook events Perch subscribes to, in the agent's PascalCase spelling.
    let events: [String]

    static func claude(home: URL) -> HookTarget {
        HookTarget(
            agent: .claude,
            fileURL: home.appending(path: ".claude/settings.json", directoryHint: .notDirectory),
            events: ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Notification",
                     "PostToolUse", "Stop", "StopFailure", "SessionEnd"]
        )
    }

    /// Codex has no `Notification` or `StopFailure`; `Interrupt` ends a turn the user cancelled.
    static func codex(home: URL) -> HookTarget {
        HookTarget(
            agent: .codex,
            fileURL: home.appending(path: ".codex/hooks.json", directoryHint: .notDirectory),
            events: ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse",
                     "Stop", "Interrupt", "SessionEnd"]
        )
    }
}

/// Adds and removes Perch's entries in an agent's hook config without touching anything else.
///
/// - Every existing hook stays, in place. Perch's group is appended after the others in each event array, so
///   the indexes Codex keys its hook trust on (`hooks.json:<event>:<group>:<hook>`) do not shift.
/// - Perch's entries are recognised by `marker` in their command, so installing twice is a no-op
///   and removing touches only Perch's entries.
/// - The command is guarded: it does nothing when the Perch helper is gone, so uninstalling Perch never breaks an agent.
nonisolated enum HookInstaller {
    static let marker = "Perch.app/Contents/Helpers/perch"
    /// Seconds. The helper gives up on the socket after 200 ms; this only bounds a pathological hang.
    static let timeout = 5
    private static let toolEvents: Set<String> = ["PermissionRequest", "PostToolUse", "PreToolUse"]

    enum InstallError: Error, CustomStringConvertible {
        case notAnObject(String)
        var description: String {
            switch self {
            case let .notAnObject(what): "\(what) is not a JSON object"
            }
        }
    }

    /// `P='…/perch'; [ -x "$P" ] && "$P" event --source claude || true`
    static func command(helperPath: String, source: AgentSource) -> String {
        let quoted = "'" + helperPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "P=\(quoted); [ -x \"$P\" ] && \"$P\" event --source \(source.rawValue) || true"
    }

    // MARK: Pure transforms

    /// The config with Perch's hooks for `events`; Perch entries under any other event are removed.
    /// An existing Perch entry with a different command (the app moved) is updated in place.
    static func installing(into data: Data?, events: [String], command: String) throws -> Data {
        var root = try parseRoot(data)
        guard case var .object(rootMembers) = root else { throw InstallError.notAnObject("The file") }

        var hooks: [JSONMember] = []
        let hooksIndex = rootMembers.firstIndex { $0.key == "hooks" }
        if let hooksIndex {
            guard case let .object(existing) = rootMembers[hooksIndex].value else { throw InstallError.notAnObject("\"hooks\"") }
            hooks = existing
        }

        // Stale Perch entries under events no longer subscribed to.
        hooks = hooks.compactMap { member in
            guard !events.contains(member.key) else { return member }
            return strippingPerch(member)
        }

        for event in events {
            let group = perchGroup(event: event, command: command)
            if let index = hooks.firstIndex(where: { $0.key == event }) {
                guard case var .array(groups) = hooks[index].value else { continue } // foreign shape: leave alone
                if let existing = groups.firstIndex(where: containsPerch) {
                    groups[existing] = updatingCommand(of: groups[existing], to: command)
                } else {
                    groups.append(group)
                }
                hooks[index].value = .array(groups)
            } else {
                hooks.append(JSONMember(key: event, value: .array([group])))
            }
        }

        if let hooksIndex {
            rootMembers[hooksIndex].value = .object(hooks)
        } else {
            rootMembers.append(JSONMember(key: "hooks", value: .object(hooks)))
        }
        root = .object(rootMembers)
        return serialize(root, like: data)
    }

    /// The config without Perch's entries. Groups, event arrays and the `hooks` object that only held
    /// Perch's entries are removed with them.
    static func removing(from data: Data) throws -> Data {
        let root = try parseRoot(data)
        guard case var .object(rootMembers) = root,
              let hooksIndex = rootMembers.firstIndex(where: { $0.key == "hooks" }),
              case let .object(hooks) = rootMembers[hooksIndex].value
        else { return data }
        guard hooks.contains(where: { containsPerch($0.value) }) else { return data }

        let remaining = hooks.compactMap(strippingPerch)
        if remaining.isEmpty {
            rootMembers.remove(at: hooksIndex)
        } else {
            rootMembers[hooksIndex].value = .object(remaining)
        }
        return serialize(.object(rootMembers), like: data)
    }

    /// Commands of Perch's entries, by event.
    static func installedCommands(in data: Data?) -> [String: [String]] {
        guard let data, let root = try? parseRoot(data), case let .object(hooks)? = root["hooks"] else { return [:] }
        var result: [String: [String]] = [:]
        for member in hooks {
            for group in member.value.arrayValue ?? [] {
                for entry in group["hooks"]?.arrayValue ?? [] {
                    if let command = entry["command"]?.stringValue, command.contains(marker) {
                        result[member.key, default: []].append(command)
                    }
                }
            }
        }
        return result
    }

    /// Index of Perch's group in `event`'s array; Codex keys hook trust on it.
    static func perchGroupIndex(in data: Data?, event: String) -> Int? {
        guard let data, let root = try? parseRoot(data) else { return nil }
        return root["hooks"]?[event]?.arrayValue?.firstIndex(where: containsPerch)
    }

    // MARK: Files

    /// Reads the config the way `write` will modify it: through symlinks (dotfile managers link these files).
    static func read(_ target: HookTarget) -> Data? {
        try? Data(contentsOf: target.fileURL.resolvingSymlinksInPath())
    }

    /// Backs up the current file to `<file>.perch-backup-<timestamp>`, then writes `data` atomically,
    /// keeping the original permissions. Returns the backup URL (nil when there was no file).
    @discardableResult
    static func write(_ data: Data, to target: HookTarget, now: Date = Date()) throws -> URL? {
        let fileManager = FileManager.default
        let url = target.fileURL.resolvingSymlinksInPath()
        var backup: URL?
        var permissions: Any?
        if fileManager.fileExists(atPath: url.path) {
            permissions = try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions]
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            var candidate = url.deletingLastPathComponent()
                .appending(path: url.lastPathComponent + ".perch-backup-" + formatter.string(from: now))
            var suffix = 2
            while fileManager.fileExists(atPath: candidate.path) {
                candidate = url.deletingLastPathComponent()
                    .appending(path: url.lastPathComponent + ".perch-backup-" + formatter.string(from: now) + "-\(suffix)")
                suffix += 1
            }
            try fileManager.copyItem(at: url, to: candidate)
            backup = candidate
        } else {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try data.write(to: url, options: .atomic)
        if let permissions { try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        return backup
    }

    // MARK: Helpers

    private static func parseRoot(_ data: Data?) throws -> JSONValue {
        guard let data, data.contains(where: { ![0x20, 0x0A, 0x0D, 0x09].contains($0) }) else { return .object([]) }
        return try JSONValue.parse(data)
    }

    /// Keeps the file's trailing-newline convention; a new file gets one.
    private static func serialize(_ root: JSONValue, like original: Data?) -> Data {
        let endsWithNewline = original.map { $0.isEmpty || $0.last == 0x0A } ?? true
        return Data((root.formatted() + (endsWithNewline ? "\n" : "")).utf8)
    }

    private static func perchGroup(event: String, command: String) -> JSONValue {
        var members: [JSONMember] = []
        if toolEvents.contains(event) { members.append(JSONMember(key: "matcher", value: .string("*"))) }
        members.append(JSONMember(key: "hooks", value: .array([.object([
            JSONMember(key: "type", value: .string("command")),
            JSONMember(key: "command", value: .string(command)),
            JSONMember(key: "timeout", value: .number(String(timeout))),
        ])])))
        return .object(members)
    }

    private static func isPerchEntry(_ entry: JSONValue) -> Bool {
        entry["command"]?.stringValue?.contains(marker) ?? false
    }

    /// True for a group (or an event array) holding a Perch entry.
    private static func containsPerch(_ value: JSONValue) -> Bool {
        if let groups = value.arrayValue { return groups.contains(where: containsPerch) }
        return value["hooks"]?.arrayValue?.contains(where: isPerchEntry) ?? false
    }

    private static func updatingCommand(of group: JSONValue, to command: String) -> JSONValue {
        guard case var .object(members) = group,
              let index = members.firstIndex(where: { $0.key == "hooks" }),
              case let .array(entries) = members[index].value
        else { return group }
        members[index].value = .array(entries.map { entry in
            guard isPerchEntry(entry), case var .object(fields) = entry,
                  let commandIndex = fields.firstIndex(where: { $0.key == "command" })
            else { return entry }
            fields[commandIndex].value = .string(command)
            return .object(fields)
        })
        return .object(members)
    }

    /// The event without Perch's entries; nil when nothing else is left in it.
    private static func strippingPerch(_ member: JSONMember) -> JSONMember? {
        guard case let .array(groups) = member.value, groups.contains(where: containsPerch) else { return member }
        let kept: [JSONValue] = groups.compactMap { group in
            guard containsPerch(group), case var .object(fields) = group,
                  let index = fields.firstIndex(where: { $0.key == "hooks" }),
                  case let .array(entries) = fields[index].value
            else { return group }
            let others = entries.filter { !isPerchEntry($0) }
            guard !others.isEmpty else { return nil }
            fields[index].value = .array(others)
            return .object(fields)
        }
        return kept.isEmpty ? nil : JSONMember(key: member.key, value: .array(kept))
    }
}
