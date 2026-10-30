import AppKit

/// Brings an agent's terminal forward: the app always, and for Terminal and iTerm the tab whose tty matches.
/// Tab selection uses AppleScript, so macOS asks for Automation permission on first use; if the user declines,
/// activating the app is all that happens.
enum TerminalFocuser {
    private static let scriptQueue = DispatchQueue(label: "perch.terminal-focuser")

    private static let bundleIDs: [String: String] = [
        "Apple_Terminal": "com.apple.Terminal",
        "iTerm.app": "com.googlecode.iterm2",
        "WezTerm": "com.github.wez.wezterm",
        "ghostty": "com.mitchellh.ghostty",
        "vscode": "com.microsoft.VSCode",
        "cursor": "com.todesktop.230313mzl4w4u92",
        "WarpTerminal": "dev.warp.Warp-Stable",
    ]

    /// The launching app's bundle ID when the shell recorded it; otherwise mapped from `TERM_PROGRAM`.
    static func bundleID(for terminal: AgentTerminal) -> String? {
        if let bundle = terminal.bundle, !bundle.isEmpty { return bundle }
        return terminal.program.flatMap { bundleIDs[$0] }
    }

    static func focus(_ terminal: AgentTerminal) {
        guard let bundleID = bundleID(for: terminal),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return }
        NSApp.yieldActivation(to: app)
        app.activate()

        guard let tty = terminal.tty, tty.wholeMatch(of: #/\/dev\/ttys?\d+/#) != nil,
              let source = tabScript(bundleID: bundleID, tty: tty)
        else { return }
        scriptQueue.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }

    private static func tabScript(bundleID: String, tty: String) -> String? {
        switch bundleID {
        case "com.apple.Terminal":
            """
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
        case "com.googlecode.iterm2":
            """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                tell t to select
                                tell s to select
                                activate
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        default:
            nil
        }
    }
}
