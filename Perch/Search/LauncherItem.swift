import Foundation

/// Something the launcher lists that can also carry a global shortcut and be hidden from the launcher:
/// an application, a System Settings pane, or a built-in command.
enum LauncherItem: Hashable {
    case app(URL)
    case setting(SystemSettingsPane)
    case command(PerchCommand)

    /// Stable key for settings storage and hotkey ids; matches `SearchResult.id` for the same row.
    var key: String {
        switch self {
        case let .app(url): "app:\(url.path)"
        case let .setting(pane): "setting:\(pane.identifier)"
        case let .command(command): "command:\(command.rawValue)"
        }
    }

    /// Parses `key`; nil for unknown prefixes, panes or commands (e.g. from an older or newer Perch).
    init?(key: String) {
        guard let colon = key.firstIndex(of: ":") else { return nil }
        let value = String(key[key.index(after: colon)...])
        switch key[..<colon] {
        case "app":
            guard !value.isEmpty else { return nil }
            self = .app(URL(fileURLWithPath: value))
        case "setting":
            guard let pane = SystemSettingsPane.all.first(where: { $0.identifier == value }) else { return nil }
            self = .setting(pane)
        case "command":
            guard let command = PerchCommand(rawValue: value) else { return nil }
            self = .command(command)
        default:
            return nil
        }
    }
}
