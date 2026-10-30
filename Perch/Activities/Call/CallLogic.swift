import Foundation

/// What a call app reports about the local user.
nonisolated struct CallState: Equatable {
    var isMuted: Bool
    /// nil when the app shows no camera control (audio-only call).
    var isCameraOn: Bool?
}

/// Pure parsing for call detection, kept apart from AX / AppleScript so it can be tested.
nonisolated enum CallLogic {
    /// Zoom's "Meeting" menu exists only while a meeting window is open, and lists the toggles by their
    /// current action: "Mute audio" / "Unmute audio" and "Start video" / "Stop video"
    /// (English strings from `zoom.us.app/Contents/Resources/en.lproj/Localizable.strings`).
    /// Returns nil when the menu carries no audio item, i.e. no call.
    static func zoomState(menuTitles: [String]) -> CallState? {
        var muted: Bool?
        var camera: Bool?
        for raw in menuTitles {
            let title = normalized(raw)
            if title.hasPrefix("unmute") && title.contains("audio") {
                muted = true
            } else if title.hasPrefix("mute") && title.contains("audio") {
                muted = false
            } else if title.hasPrefix("start") && title.contains("video") {
                camera = false
            } else if title.hasPrefix("stop") && title.contains("video") {
                camera = true
            }
        }
        guard let muted else { return nil }
        return CallState(isMuted: muted, isCameraOn: camera)
    }

    /// Meet labels its toolbar buttons by the action they do: "Turn off microphone (⌘ + d)",
    /// "Turn on camera (⌘ + e)", "Leave call". Without a leave button the page is not in a call.
    /// English UI only.
    static func meetState(ariaLabels: [String]) -> CallState? {
        let labels = ariaLabels.map(normalized)
        guard labels.contains(where: { $0.hasPrefix("leave call") }) else { return nil }
        var muted = false
        var camera: Bool?
        for label in labels {
            if label.hasPrefix("turn on microphone") {
                muted = true
            } else if label.hasPrefix("turn off microphone") {
                muted = false
            } else if label.hasPrefix("turn on camera") {
                camera = false
            } else if label.hasPrefix("turn off camera") {
                camera = true
            }
        }
        return CallState(isMuted: muted, isCameraOn: camera)
    }

    /// A Meet meeting URL (`/abc-defg-hij`, or `/lookup/…`), not the landing page or a post-call screen.
    static func isMeetingURL(_ string: String) -> Bool {
        guard let url = URL(string: string), url.host == "meet.google.com" else { return false }
        let path = url.path
        if path.hasPrefix("/lookup/") { return true }
        let parts = path.dropFirst().split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 3
            && parts.map(\.count) == [3, 4, 3]
            && parts.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isLetter && $0.isLowercase } }
    }

    /// Parses the tab report: one `url<TAB>json-array-of-aria-labels` line per Meet tab.
    /// The first tab that is in a call wins.
    static func meetTab(report: String) -> (url: String, state: CallState)? {
        for line in report.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2,
                  isMeetingURL(String(fields[0])),
                  let data = fields[1].data(using: .utf8),
                  let labels = try? JSONDecoder().decode([String].self, from: data),
                  let state = meetState(ariaLabels: labels)
            else { continue }
            return (String(fields[0]), state)
        }
        return nil
    }

    /// Zoom's leave confirmation offers "Leave meeting" (and "End meeting for all" to a host);
    /// only the former is pressed.
    static func isLeaveButton(_ title: String) -> Bool {
        let title = normalized(title)
        return title.hasPrefix("leave") && !title.contains("end")
    }

    /// Whether an osascript error means Chrome has "Allow JavaScript from Apple Events" off.
    static func isJavaScriptDisabled(stderr: String) -> Bool {
        let text = stderr.lowercased()
        return text.contains("javascript through applescript is turned off")
            || text.contains("allow javascript from apple events")
    }

    /// Whether an osascript error means Perch may not automate the browser (-1743).
    static func isAutomationDenied(stderr: String) -> Bool {
        stderr.contains("-1743") || stderr.lowercased().contains("not authorized")
    }

    static func detail(for state: CallState) -> String {
        var parts = [state.isMuted ? "Muted" : "Mic on"]
        if let camera = state.isCameraOn { parts.append(camera ? "Camera on" : "Camera off") }
        return parts.joined(separator: " · ")
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// The card buttons for a call.
nonisolated enum CallActionID {
    static let mute = "mute"
    static let camera = "camera"
    static let leave = "leave"
}

@MainActor
extension CallLogic {
    static func actions(for state: CallState) -> [ActivityAction] {
        var actions = [
            ActivityAction(
                id: CallActionID.mute,
                title: state.isMuted ? "Unmute" : "Mute",
                symbol: state.isMuted ? "mic.slash.fill" : "mic.fill",
                isOn: state.isMuted
            )
        ]
        if let camera = state.isCameraOn {
            actions.append(ActivityAction(
                id: CallActionID.camera,
                title: camera ? "Camera off" : "Camera on",
                symbol: camera ? "video.fill" : "video.slash.fill",
                isOn: !camera
            ))
        }
        actions.append(ActivityAction(id: CallActionID.leave, title: "Leave", symbol: "phone.down.fill", isDestructive: true))
        return actions
    }
}
